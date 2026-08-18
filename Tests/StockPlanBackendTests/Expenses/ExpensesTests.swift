import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Expenses & Reports Service Tests", .serialized)
struct ExpensesTests {
    private struct MinimalExpensePayload: Content {
        let title: String
        let amount: Double
        let pillar: BudgetPillar
        let occurredOn: String
    }

    private struct MinimalBudgetPlanItemPayload: Content {
        let snapshotId: String
        let title: String
        let plannedAmount: Double
        let pillar: BudgetPillar
    }

    private func withExpensesApp(_ test: @escaping (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func registerTestUser(app: Application) async throws -> String {
        let identifier = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "exp_user_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "exp_\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            let response = try res.content.decode(AuthResponse.self)
            token = response.token
        })
        return token
    }

    @Test("Expenses, budget, and reports are isolated per authenticated user")
    func expensesBudgetAndReportsAreUserIsolated() async throws {
        try await withExpensesApp { app in
            let ownerToken = try await registerTestUser(app: app)
            let otherToken = try await registerTestUser(app: app)

            var expenseId = ""
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Owner rent",
                        amount: 1200,
                        pillar: .fundamentals,
                        occurredOn: "2026-07-02"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                expenseId = try res.content.decode(ExpenseResponse.self).id
            })

            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let expenses = try res.content.decode([ExpenseResponse].self)
                #expect(expenses.isEmpty)
            })

            try await app.testing().test(.GET, "v1/reports/expenses?granularity=month&from=2026-07-01&to=2026-07-31", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let reports = try res.content.decode([BudgetMonthSummaryResponse].self)
                #expect(reports.isEmpty)
            })

            try await app.testing().test(.PATCH, "v1/expenses/\(expenseId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Cross-user edit",
                        amount: 1,
                        pillar: .fun,
                        occurredOn: "2026-07-03"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden || res.status == .notFound)
            })

            try await app.testing().test(.DELETE, "v1/expenses/\(expenseId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden || res.status == .notFound)
            })

            try await app.testing().test(.GET, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let expenses = try res.content.decode([ExpenseResponse].self)
                #expect(expenses.count == 1)
                #expect(expenses[0].title == "Owner rent")
            })
        }
    }

    @Test("Monthly report aggregation")
    func monthlyReportAggregation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            // 1. Create a snapshot
            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                let reqBody = BudgetSnapshotRequest(monthStart: "2025-11-01", netSalary: 3000, targetShares: [:])
                try req.content.encode(reqBody)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let snap = try res.content.decode(BudgetSnapshotResponse.self)
                snapshotId = snap.id
            })

            // 2. Add some expenses
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                let expense = ExpenseRequest(title: "Lunch", amount: 20, pillar: .fun, occurredOn: "2025-11-05")
                try req.content.encode(expense)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            // 3. Fetch report
            try await app.testing().test(.GET, "v1/reports/expenses?granularity=month&from=2025-11-01&to=2025-11-30", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let reports = try res.content.decode([BudgetMonthSummaryResponse].self)
                #expect(reports.count == 1)
                #expect(reports[0].actual == 20.0)
                #expect(reports[0].myActual == 20.0)
                #expect(reports[0].partnerActual == 0.0)
                #expect(reports[0].pillarActuals["fun"] == 20.0)
            })
        }
    }

    @Test("Saving expense in a month without snapshot auto-creates snapshot and reports include it")
    func expenseAutoCreatesSnapshotForMonth() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            // Seed a template month so salary/targets can be carried forward.
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetSnapshotRequest(
                        monthStart: "2026-04-01",
                        netSalary: 4200,
                        targetShares: [
                            BudgetPillar.fundamentals.rawValue: 0.5,
                            BudgetPillar.futureYou.rawValue: 0.3,
                            BudgetPillar.fun.rawValue: 0.2,
                        ]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Rent",
                        amount: 700,
                        pillar: .fundamentals,
                        occurredOn: "2026-05-08"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/budget/snapshots?year=2026&month=5", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let snapshots = try res.content.decode([BudgetSnapshotResponse].self)
                #expect(snapshots.count == 1)
                #expect(snapshots[0].monthStart == "2026-05-01")
                #expect(snapshots[0].netSalary == 4200)
            })

            try await app.testing().test(.GET, "v1/reports/overview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let overview = try res.content.decode(ReportsOverviewResponse.self)
                #expect(overview.latestMonthSummary != nil)
                #expect(overview.latestMonthSummary?.monthStart == "2026-05-01")
                #expect(overview.latestMonthSummary?.actual == 700)
                #expect(overview.cashFlow.contains { $0.monthStart == "2026-05-01" && $0.expenses == 700 })
                #expect(!overview.latestPillarSummaries.isEmpty)
            })
        }
    }

    @Test("Custom pillars are accepted and included in reports")
    func customPillarReporting() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            let customPillar = try #require(BudgetPillar(rawValue: "Nuclear Theme"))

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetSnapshotRequest(
                        monthStart: "2026-06-01",
                        netSalary: 5000,
                        targetShares: [customPillar.rawValue: 0.10]
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Nuclear ETF DCA",
                        plannedAmount: 500,
                        pillar: customPillar
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let item = try res.content.decode(BudgetPlanItemResponse.self)
                #expect(item.pillar == customPillar)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Uranium miner buy",
                        amount: 300,
                        pillar: customPillar,
                        occurredOn: "2026-06-10"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let expense = try res.content.decode(ExpenseResponse.self)
                #expect(expense.pillar == customPillar)
            })

            try await app.testing().test(.GET, "v1/reports/expenses?granularity=month&from=2026-06-01&to=2026-06-30", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let reports = try res.content.decode([BudgetMonthSummaryResponse].self)
                #expect(reports.count == 1)
                #expect(reports[0].pillarPlans[customPillar.rawValue] == 500)
                #expect(reports[0].pillarActuals[customPillar.rawValue] == 300)
            })

            try await app.testing().test(.GET, "v1/reports/overview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let overview = try res.content.decode(ReportsOverviewResponse.self)
                #expect(overview.latestPillarSummaries.contains(where: { $0.pillar == customPillar }))
            })
        }
    }

    @Test("Monthly reports include split household totals")
    func monthlyReportSplitAggregation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2025-11-01", netSalary: 3000, targetShares: [:]))
            }, afterResponse: { res async throws in
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Rent",
                        plannedAmount: 1000,
                        pillar: .fundamentals,
                        splitMode: .shared,
                        userSharePercent: 60
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Rent",
                        amount: 1000,
                        pillar: .fundamentals,
                        occurredOn: "2025-11-03",
                        splitMode: .shared,
                        userSharePercent: 60
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/reports/expenses?granularity=month", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let reports = try res.content.decode([BudgetMonthSummaryResponse].self)
                #expect(reports.count == 1)
                #expect(reports[0].planned == 1000)
                #expect(reports[0].actual == 1000)
                #expect(reports[0].myPlanned == 600)
                #expect(reports[0].partnerPlanned == 400)
                #expect(reports[0].myActual == 600)
                #expect(reports[0].partnerActual == 400)
                #expect(reports[0].myPillarActuals["fundamentals"] == 600)
                #expect(reports[0].partnerPillarPlans["fundamentals"] == 400)
            })
        }
    }

    @Test("Creating expense defaults split fields when omitted")
    func createExpenseDefaultsSplitFieldsWhenOmitted() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    MinimalExpensePayload(
                        title: "Supermarket run",
                        amount: 120.50,
                        pillar: .fundamentals,
                        occurredOn: "2026-05-08"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let expense = try res.content.decode(ExpenseResponse.self)
                #expect(expense.splitMode == .personal)
                #expect(expense.userSharePercent == 100)
            })
        }
    }

    @Test("Creating plan item defaults split fields when omitted")
    func createPlanItemDefaultsSplitFieldsWhenOmitted() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2026-05-01", netSalary: 3000, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    MinimalBudgetPlanItemPayload(
                        snapshotId: snapshotId,
                        title: "Rent",
                        plannedAmount: 1200,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let item = try res.content.decode(BudgetPlanItemResponse.self)
                #expect(item.splitMode == .personal)
                #expect(item.userSharePercent == 100)
            })
        }
    }

    @Test("Household partner profile can be saved")
    func householdPartnerProfile() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            try await app.testing().test(.PUT, "v1/expenses/partner", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(HouseholdPartnerProfileRequest(displayName: "Ana"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(HouseholdPartnerProfileResponse.self)
                #expect(response.displayName == "Ana")
            })

            try await app.testing().test(.GET, "v1/expenses/partner", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(HouseholdPartnerProfileResponse.self)
                #expect(response.displayName == "Ana")
            })
        }
    }

    @Test("Creating expense rejects invalid linked plan item id format")
    func expenseRejectsInvalidLinkedPlanItemIdFormat() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Groceries",
                        amount: 45,
                        pillar: .fundamentals,
                        occurredOn: "2025-11-03",
                        linkedPlanItemId: "not-a-uuid"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Reports overview aggregates portfolio and cash flow data")
    func reportsOverviewAggregation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                let reqBody = BudgetSnapshotRequest(
                    monthStart: "2025-11-01",
                    netSalary: 3000,
                    targetShares: ["fundamentals": 0.5, "futureYou": 0.2, "fun": 0.3]
                )
                try req.content.encode(reqBody)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Groceries",
                        plannedAmount: 900,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Groceries",
                        amount: 650,
                        pillar: .fundamentals,
                        occurredOn: "2025-11-03"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Concert",
                        amount: 120,
                        pillar: .fun,
                        occurredOn: "2025-11-08"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/reports/overview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let overview = try res.content.decode(ReportsOverviewResponse.self)
                #expect(overview.monthlySummaries.count == 1)
                #expect(overview.yearlySummaries.count == 1)
                #expect(overview.latestMonthSummary?.salary == 3000)
                #expect(overview.latestMonthSummary?.actual == 770)
                #expect(overview.cashFlow.count == 1)
                #expect(overview.cashFlow[0].income == 3000)
                #expect(overview.cashFlow[0].expenses == 770)
                #expect(overview.cashFlow[0].net == 2230)
                #expect(overview.latestPillarSummaries.count == 3)
                #expect(overview.latestPillarSummaries.first(where: { $0.pillar == .fundamentals })?.plannedAmount == 900)
                #expect(overview.latestPillarSummaries.first(where: { $0.pillar == .fundamentals })?.actualAmount == 650)
                #expect(overview.latestPillarSummaries.first(where: { $0.pillar == .fun })?.unplannedActualAmount == 120)
            })
        }
    }

    @Test("Creating plan items and expenses respects percentage allocation details")
    func percentageAllocationDetails() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2025-12-01", netSalary: 5000, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            // Add pillar (Budget Plan Item)
            var planItemId = ""
            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Mortgage",
                        plannedAmount: 2000,
                        pillar: .fundamentals,
                        splitMode: .shared,
                        userSharePercent: 35
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let item = try res.content.decode(BudgetPlanItemResponse.self)
                #expect(item.splitMode == .shared)
                #expect(item.userSharePercent == 35)
                planItemId = item.id
            })

            // Add expense related to pillar
            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Mortgage Payment",
                        amount: 2000,
                        pillar: .fundamentals,
                        occurredOn: "2025-12-05",
                        linkedPlanItemId: planItemId,
                        splitMode: .shared,
                        userSharePercent: 35
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let dict = try res.content.decode(ExpenseResponse.self)
                #expect(dict.splitMode == .shared)
                #expect(dict.userSharePercent == 35)
                #expect(dict.linkedPlanItemId == planItemId)
            })
        }
    }

    @Test("Report suggestions endpoint returns deterministic rule-based items")
    func reportSuggestionsDeterministic() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2026-03-01", netSalary: 3000, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Core Living",
                        plannedAmount: 1000,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Core Living",
                        amount: 1400,
                        pillar: .fundamentals,
                        occurredOn: "2026-03-05"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Unplanned Weekend",
                        amount: 350,
                        pillar: .fun,
                        occurredOn: "2026-03-12"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/reports/suggestions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportSuggestionsResponse.self)
                #expect(payload.suggestions.isEmpty == false)
                #expect(payload.suggestions.contains(where: { $0.category == .overspend }))
                #expect(payload.suggestions.contains(where: { $0.category == .unplannedSpend }))
            })
        }
    }

    @Test("Dismissed suggestions are hidden from subsequent suggestion fetches")
    func dismissSuggestionPersists() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)

            var snapshotId = ""
            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(BudgetSnapshotRequest(monthStart: "2026-04-01", netSalary: 2800, targetShares: [:]))
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                snapshotId = try res.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Essentials",
                        plannedAmount: 900,
                        pillar: .fundamentals
                    )
                )
            }, afterResponse: { _ async throws in })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Essentials",
                        amount: 1300,
                        pillar: .fundamentals,
                        occurredOn: "2026-04-06"
                    )
                )
            }, afterResponse: { _ async throws in })

            var suggestionId = ""
            try await app.testing().test(.GET, "v1/reports/suggestions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let payload = try res.content.decode(ReportSuggestionsResponse.self)
                suggestionId = try #require(payload.suggestions.first?.id)
            })

            try await app.testing().test(
                .POST,
                "v1/reports/suggestions/\(suggestionId)/dismiss",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let success = try res.content.decode(APISuccess.self)
                    #expect(success.success == true)
                }
            )

            try await app.testing().test(.GET, "v1/reports/suggestions", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                let payload = try res.content.decode(ReportSuggestionsResponse.self)
                #expect(payload.suggestions.contains(where: { $0.id == suggestionId }) == false)
            })
        }
    }

    @Test("Reports overview falls back to stock positions when statistics are empty")
    func reportsOverviewIncludesStockPositions() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            let positions = [
                StockRequest(symbol: "AAPL", shares: 2, buyPrice: 150, buyDate: "2026-01-01", notes: nil),
                StockRequest(symbol: "MSFT", shares: 1, buyPrice: 300, buyDate: "2026-01-02", notes: nil),
                StockRequest(symbol: "NVDA", shares: 3, buyPrice: 100, buyDate: "2026-01-03", notes: nil),
            ]

            for position in positions {
                try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(position)
                }, afterResponse: { res async throws in
                    #expect(res.status == .created)
                })
            }

            try await app.testing().test(.GET, "v1/reports/overview", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let overview = try res.content.decode(ReportsOverviewResponse.self)
                #expect(overview.portfolioStatistics.totalPositions == 3)
                #expect(overview.portfolioStatistics.totalMarketValue == 900)
                #expect(overview.portfolioStatistics.stockAllocations.count == 3)
                #expect(overview.portfolioStatistics.stockSummaries.contains { $0.symbol == "AAPL" })
            })
        }
    }

    @Test("Budget drift calculates category breach and lost investment capital")
    func budgetDriftCalculation() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            var snapshotId = ""

            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetSnapshotRequest(
                        monthStart: "2026-07-01",
                        netSalary: 4000,
                        targetShares: [:],
                        currencyCode: "EUR",
                        categoryDriftThreshold: 15,
                        totalDriftThreshold: 10
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
                snapshotId = try response.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Dining Out",
                        plannedAmount: 150,
                        pillar: .fun,
                        thresholdOverride: 15,
                        reallocationEligible: true
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })

            try await app.testing().test(.POST, "v1/budget/items", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetPlanItemRequest(
                        snapshotId: snapshotId,
                        title: "Monthly Investments",
                        plannedAmount: 500,
                        pillar: .futureYou,
                        allocationKind: .investmentContribution
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })

            try await app.testing().test(.POST, "v1/expenses", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    ExpenseRequest(
                        title: "Dining Out",
                        amount: 210,
                        pillar: .fun,
                        occurredOn: "2026-07-15"
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })

            try await app.testing().test(.GET, "v1/budget/snapshots/\(snapshotId)/drift", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let dashboard = try response.content.decode(BudgetDriftDashboard.self)
                let dining = try #require(dashboard.categories.first { $0.title == "Dining Out" })
                #expect(dining.actualAmount == 210)
                #expect(dining.driftAmount == 60)
                #expect(dining.driftPercent == 40)
                #expect(dining.level == .red)
                #expect(dashboard.investmentContributionTarget == 500)
                #expect(dashboard.lostInvestmentCapital == 60)
                #expect(dashboard.totalLevel == .red)
            })
        }
    }

    @Test("Budget alert policy updates thresholds and alert switches")
    func budgetAlertPolicyUpdate() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            var snapshotId = ""

            try await app.testing().test(.POST, "v1/budget/snapshots", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetSnapshotRequest(
                        monthStart: "2026-07-01",
                        netSalary: 4000,
                        targetShares: [:]
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
                snapshotId = try response.content.decode(BudgetSnapshotResponse.self).id
            })

            try await app.testing().test(.PUT, "v1/budget/snapshots/\(snapshotId)/alert-policy", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    BudgetAlertPolicy(
                        categoryThreshold: 22,
                        totalThreshold: 8,
                        alertsEnabled: false,
                        alertOnUnbudgeted: false
                    )
                )
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let snapshot = try response.content.decode(BudgetSnapshotResponse.self)
                #expect(snapshot.categoryDriftThreshold == 22)
                #expect(snapshot.totalDriftThreshold == 8)
                #expect(snapshot.alertsEnabled == false)
                #expect(snapshot.alertOnUnbudgeted == false)
                #expect(snapshot.revision == 1)
            })
        }
    }

    @Test("Reallocation updates the investment target for the selected portfolio only")
    func reallocationRoutesByPortfolio() async throws {
        try await withExpensesApp { app in
            _ = try await registerTestUser(app: app)
            let user = try #require(try await User.query(on: app.db).first())
            let userId = try user.requireID()
            let sourceId = UUID()
            let targetId = UUID()
            let expenseItemId = UUID()
            let firstPortfolioId = UUID()
            let selectedPortfolioId = UUID()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let sourceMonth = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
            let targetMonth = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))

            let firstPortfolio = PortfolioList(
                id: firstPortfolioId,
                userId: userId,
                name: "Long term"
            )
            let selectedPortfolio = PortfolioList(
                id: selectedPortfolioId,
                userId: userId,
                name: "Retirement"
            )
            try await firstPortfolio.create(on: app.db)
            try await selectedPortfolio.create(on: app.db)

            let source = BudgetSnapshot(
                id: sourceId,
                userID: userId,
                monthStart: sourceMonth,
                netSalary: 4000,
                targetShares: [:],
                currencyCode: "EUR"
            )
            let target = BudgetSnapshot(
                id: targetId,
                userID: userId,
                monthStart: targetMonth,
                netSalary: 4000,
                targetShares: [:],
                currencyCode: "EUR"
            )
            try await source.create(on: app.db)
            try await target.create(on: app.db)

            let sourceExpense = BudgetPlanItem(
                id: expenseItemId,
                snapshotID: sourceId,
                userID: userId,
                title: "Dining Out",
                plannedAmount: 150,
                pillar: .fun,
                reallocationEligible: true
            )
            let targetExpense = BudgetPlanItem(
                snapshotID: targetId,
                userID: userId,
                title: "Dining Out",
                plannedAmount: 150,
                pillar: .fun,
                reallocationEligible: true
            )
            let firstInvestment = BudgetPlanItem(
                snapshotID: targetId,
                userID: userId,
                title: "Long-term investments",
                plannedAmount: 300,
                pillar: .futureYou,
                allocationKind: .investmentContribution,
                destinationPortfolioListId: firstPortfolioId
            )
            let selectedInvestment = BudgetPlanItem(
                snapshotID: targetId,
                userID: userId,
                title: "Retirement investments",
                plannedAmount: 500,
                pillar: .futureYou,
                allocationKind: .investmentContribution,
                destinationPortfolioListId: selectedPortfolioId
            )
            try await sourceExpense.create(on: app.db)
            try await targetExpense.create(on: app.db)
            try await firstInvestment.create(on: app.db)
            try await selectedInvestment.create(on: app.db)

            let preview = BudgetReallocationPreviewRequest(
                snapshotId: sourceId.uuidString,
                expectedRevision: 0,
                adjustments: [
                    BudgetReallocationAdjustment(planItemId: expenseItemId.uuidString, amount: 60),
                ],
                portfolioListId: selectedPortfolioId.uuidString
            )
            let request = Request(application: app, on: app.eventLoopGroup.next())
            let event = try await BudgetingEngineService(req: request).commit(
                userId: userId,
                request: BudgetReallocationCommitRequest(
                    requestId: UUID().uuidString,
                    preview: preview
                )
            )
            #expect(event.portfolioListId == selectedPortfolioId.uuidString)
            #expect(event.freedCapital == 60)

            let refreshedFirst = try #require(try await BudgetPlanItem.find(firstInvestment.requireID(), on: app.db))
            let refreshedSelected = try #require(try await BudgetPlanItem.find(selectedInvestment.requireID(), on: app.db))
            #expect(refreshedFirst.plannedAmount == 300)
            #expect(refreshedSelected.plannedAmount == 560)
        }
    }

    @Test("Budget templates persist their item collection as JSON")
    func budgetTemplatePersistence() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            let template = BudgetTemplateRequest(
                name: "Balanced month",
                items: [
                    BudgetTemplateItem(
                        title: "Groceries",
                        plannedAmount: 400,
                        pillar: .fundamentals,
                        reallocationEligible: true
                    ),
                ]
            )

            try await app.testing().test(.POST, "v1/budget/templates", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(template)
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let saved = try response.content.decode(BudgetTemplateResponse.self)
                #expect(saved.name == template.name)
                #expect(saved.items == template.items)
            })

            try await app.testing().test(.GET, "v1/budget/templates", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let saved = try response.content.decode([BudgetTemplateResponse].self)
                #expect(saved.count == 1)
                #expect(saved.first?.items == template.items)
            })
        }
    }

    @Test("DCA capacity persists a ticker and reports leftover spend as units when a quote exists")
    func dcaCapacityPersistsSymbol() async throws {
        try await withExpensesApp { app in
            let token = try await registerTestUser(app: app)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let monthStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
            let user = try #require(try await User.query(on: app.db).first())
            let userId = try user.requireID()
            let snapshot = BudgetSnapshot(
                userID: userId,
                monthStart: monthStart,
                netSalary: 4000,
                targetShares: [:],
                currencyCode: "EUR"
            )
            try await snapshot.create(on: app.db)
            let snapshotId = try snapshot.requireID()
            try await BudgetPlanItem(
                snapshotID: snapshotId,
                userID: userId,
                title: "Monthly Investments",
                plannedAmount: 500,
                pillar: .futureYou,
                allocationKind: .investmentContribution
            ).create(on: app.db)
            try await BudgetPlanItem(
                snapshotID: snapshotId,
                userID: userId,
                title: "Dining Out",
                plannedAmount: 150,
                pillar: .fun
            ).create(on: app.db)
            try await Expense(
                userID: userId,
                title: "Dining Out",
                amount: 210,
                pillar: .fun,
                occurredOn: #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
            ).create(on: app.db)

            try await app.testing().test(.PUT, "v1/budget/dca-capacity", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(UpdateDcaSymbolRequest(symbol: "vwce"))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let capacity = try response.content.decode(SpendToUnitsCapacity.self)
                #expect(capacity.symbol == "VWCE")
                #expect(capacity.resolvedFrom == .preference)
                #expect(capacity.surplusAmount == 440)
                #expect(capacity.disclaimer.contains("Not an order"))
                #expect(capacity.categories.contains { $0.title == "Dining Out" && $0.overspendAmount == 60 })
            })

            try await app.testing().test(.PUT, "v1/budget/dca-capacity", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(UpdateDcaSymbolRequest(symbol: "nope!"))
            }, afterResponse: { response async throws in
                #expect(response.status == .badRequest)
            })
        }
    }
}

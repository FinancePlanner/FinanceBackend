import Fluent
import Foundation
import StockPlanShared
import Vapor

struct BudgetingEngineController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let budget = protected.grouped("budget")
        let read = budget.grouped(ScopeRequirementMiddleware(.expensesRead))
        let write = budget.grouped(ScopeRequirementMiddleware(.expensesWrite))
        read.get("snapshots", ":snapshotId", "drift", use: drift)
        read.get("dca-capacity", use: dcaCapacity)
        write.put("dca-capacity", use: updateDcaCapacity)
        read.get("discipline", use: discipline)
        write.put("snapshots", ":snapshotId", "alert-policy", use: updatePolicy)
        write.patch("snapshots", ":snapshotId", "items", use: bulkUpdate)
        write.post("reallocations", "preview", use: preview)
        write.post("reallocations", use: commit)
        read.get("reallocations", use: history)
        read.get("templates", use: templates)
        write.post("templates", use: createTemplate)
        write.put("templates", ":templateId", use: updateTemplate)
        write.delete("templates", ":templateId", use: deleteTemplate)
        write.post("templates", ":templateId", "apply", use: applyTemplate)
    }

    @Sendable func drift(req: Request) async throws -> BudgetDriftDashboard {
        let user = try req.auth.require(SessionToken.self).userId
        return try await BudgetingEngineService(req: req).dashboard(userId: user, snapshotId: id(req, "snapshotId"))
    }

    @Sendable func dcaCapacity(req: Request) async throws -> SpendToUnitsCapacity {
        let user = try req.auth.require(SessionToken.self).userId
        return try await BudgetingEngineService(req: req).spendToUnits(userId: user)
    }

    @Sendable func updateDcaCapacity(req: Request) async throws -> SpendToUnitsCapacity {
        let user = try req.auth.require(SessionToken.self).userId
        let payload = try req.content.decode(UpdateDcaSymbolRequest.self)
        return try await BudgetingEngineService(req: req).updateDcaSymbol(userId: user, symbol: payload.symbol)
    }

    @Sendable func discipline(req: Request) async throws -> BudgetDisciplineSummary {
        let user = try req.auth.require(SessionToken.self).userId
        let date: Date = {
            guard let raw = req.query[String.self, at: "through"] else { return Date() }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: raw) ?? Date()
        }()
        return try await BudgetingEngineService(req: req).discipline(userId: user, through: date, months: req.query[Int.self, at: "months"] ?? 6)
    }

    @Sendable func updatePolicy(req: Request) async throws -> BudgetSnapshotResponse {
        let user = try req.auth.require(SessionToken.self).userId; let snapshotId = try id(req, "snapshotId")
        let policy = try req.content.decode(BudgetAlertPolicy.self)
        guard policy.categoryThreshold.isFinite, policy.totalThreshold.isFinite,
              (0 ... 1000).contains(policy.categoryThreshold), (0 ... 1000).contains(policy.totalThreshold)
        else { throw Abort(.badRequest) }
        guard let snapshot = try await BudgetSnapshot.query(on: req.db).filter(\.$id == snapshotId).filter(\.$user.$id == user).first()
        else { throw Abort(.notFound) }
        snapshot.categoryDriftThreshold = policy.categoryThreshold; snapshot.totalDriftThreshold = policy.totalThreshold
        snapshot.alertsEnabled = policy.alertsEnabled; snapshot.alertOnUnbudgeted = policy.alertOnUnbudgeted; snapshot.revision += 1
        try await snapshot.update(on: req.db)
        return BudgetSnapshotResponse(id: snapshotId.uuidString, monthStart: BudgetingEngineService.dateString(snapshot.monthStart),
                                      netSalary: snapshot.netSalary, targetShares: snapshot.targetShares, currencyCode: snapshot.currencyCode,
                                      categoryDriftThreshold: snapshot.categoryDriftThreshold, totalDriftThreshold: snapshot.totalDriftThreshold,
                                      alertsEnabled: snapshot.alertsEnabled, alertOnUnbudgeted: snapshot.alertOnUnbudgeted, revision: snapshot.revision)
    }

    @Sendable func bulkUpdate(req: Request) async throws -> BudgetDriftDashboard {
        let user = try req.auth.require(SessionToken.self).userId
        try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).bulkUpdate(userId: user, snapshotId: id(req, "snapshotId"), request: req.content.decode(BudgetBulkPlanItemUpdateRequest.self))
    }

    @Sendable func preview(req: Request) async throws -> BudgetReallocationPreviewResponse {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).preview(userId: user, request: req.content.decode(BudgetReallocationPreviewRequest.self), on: req.db)
    }

    @Sendable func commit(req: Request) async throws -> BudgetReallocationEventResponse {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).commit(userId: user, request: req.content.decode(BudgetReallocationCommitRequest.self))
    }

    @Sendable func history(req: Request) async throws -> [BudgetReallocationEventResponse] {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).history(userId: user)
    }

    @Sendable func templates(req: Request) async throws -> [BudgetTemplateResponse] {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).listTemplates(userId: user)
    }

    @Sendable func createTemplate(req: Request) async throws -> BudgetTemplateResponse {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).createTemplate(userId: user, request: req.content.decode(BudgetTemplateRequest.self))
    }

    @Sendable func updateTemplate(req: Request) async throws -> BudgetTemplateResponse {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).updateTemplate(userId: user, id: id(req, "templateId"), request: req.content.decode(BudgetTemplateRequest.self))
    }

    @Sendable func deleteTemplate(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        try await BudgetingEngineService(req: req).deleteTemplate(userId: user, id: id(req, "templateId")); return .noContent
    }

    @Sendable func applyTemplate(req: Request) async throws -> BudgetDriftDashboard {
        let user = try req.auth.require(SessionToken.self).userId; try await requirePro(req, user: user, feature: .smartSuggestions)
        return try await BudgetingEngineService(req: req).applyTemplate(userId: user, id: id(req, "templateId"), request: req.content.decode(BudgetTemplateApplyRequest.self))
    }

    private func id(_ req: Request, _ name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else { throw Abort(.badRequest) }; return id
    }

    private func requirePro(_ req: Request, user: UUID, feature: BillingFeature) async throws {
        try await req.usageCounterService.requirePremium(feature, userId: user, on: req.db)
    }
}

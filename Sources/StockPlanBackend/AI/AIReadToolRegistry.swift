import Foundation
import StockPlanShared
import Vapor

/// Authenticated identity captured by the server. It is never model-visible.
struct AIToolContext: Sendable {
    let userId: UUID
}

/// Trusted, read-only tools shared by every AI surface. Identity is bound by
/// the server through `AIToolContext`; none of these schemas accepts a user id.
enum AIReadToolRegistry {
    static func toolDefinitions() -> [OpenAITool] {
        [
            tool(
                "get_financial_overview",
                "The user's complete dashboard: live portfolio value and performance plus savings, cash buffer, budget streak, watchlist count, and financial-health score."
            ),
            tool("list_expenses", "List the user's expenses, optionally restricted to a calendar month.", [
                "month": OpenAIParameter(type: "integer", description: "Calendar month 1-12. Use with year."),
                "year": OpenAIParameter(type: "integer", description: "Four-digit calendar year. Use with month."),
                "limit": OpenAIParameter(type: "integer", description: "Maximum rows, from 1 to 200."),
            ]),
            tool("get_expense_report", "All available monthly expense and budget reports, including actual, planned, salary, savings, and pillar totals."),
            tool("get_spending_report", "Recent monthly expense and budget reports.", [
                "months": OpenAIParameter(type: "integer", description: "Number of recent months, from 1 to 24."),
            ]),
            tool("get_budget_planning", "Current-month target, planned, actual, and unplanned amounts for every budget pillar."),
            tool("get_current_inflation", "Latest trusted inflation snapshot with source and as-of date.", macroCountryProperties, required: ["country"]),
            tool("get_economy_snapshot", "Latest trusted growth, labor-market, recession-risk, and policy-rate snapshot with source and as-of date.", macroCountryProperties, required: ["country"]),
            tool("get_policy_watch", "Latest trusted central-bank, inflation-target, rates, and policy-stance snapshot with source and as-of date.", macroCountryProperties, required: ["country"]),
            tool("get_quote", "Latest market quote for a symbol.", [
                "symbol": OpenAIParameter(type: "string", description: "Ticker, for example AAPL."),
            ], required: ["symbol"]),
            tool("search_symbols", "Search stocks and ETFs by name or ticker.", [
                "query": OpenAIParameter(type: "string", description: "Company, fund, or ticker search text."),
            ], required: ["query"]),
            tool("get_insights", "Latest first-party market-sentiment insights summary."),
        ]
    }

    static func contains(_ name: String) -> Bool {
        toolNames.contains(name)
    }

    static func execute(
        name: String,
        arguments: String,
        context: AIToolContext,
        on req: Request
    ) async throws -> String {
        let args = parseArgs(arguments)
        switch name {
        case "get_financial_overview":
            async let dashboard = req.application.dashboardService.dashboard(
                userId: context.userId, req: req, on: req.db
            )
            async let insights = req.application.dashboardService.insights(
                userId: context.userId, req: req, on: req.db
            )
            return try await encode(FinancialOverview(dashboard: dashboard, insights: insights))

        case "list_expenses":
            let range = expenseDateRange(args)
            let result = try await req.expensesService.getExpenses(
                userId: context.userId,
                from: range?.from,
                to: range?.to,
                limit: min(max(intArg(args, "limit") ?? 50, 1), 200),
                cursor: nil,
                on: req.db
            )
            return try encode(result.items)

        case "get_expense_report":
            return try await encode(req.expensesService.getMonthlyReports(
                userId: context.userId, from: nil, to: nil, on: req.db
            ))

        case "get_spending_report":
            let reports = try await req.expensesService.getMonthlyReports(
                userId: context.userId, from: nil, to: nil, on: req.db
            )
            let count = min(max(intArg(args, "months") ?? 6, 1), 24)
            return try encode(Array(reports.suffix(count)))

        case "get_budget_planning":
            return try await encode(req.expensesService.getPillarPlanningSummaries(
                userId: context.userId, monthStart: currentMonthStart(), on: req.db
            ))

        case "get_current_inflation":
            return try await encode(req.application.macroService.currentInflation(
                country: macroCountry(args), on: req
            ))

        case "get_economy_snapshot":
            return try await encode(req.application.macroService.economy(
                country: macroCountry(args), on: req
            ))

        case "get_policy_watch":
            return try await encode(req.application.macroService.policyWatch(
                country: macroCountry(args), on: req
            ))

        case "get_quote":
            guard let symbol = stringArg(args, "symbol") else {
                return #"{"error":"missing symbol"}"#
            }
            return try await encode(req.application.marketDataService.quote(symbol: symbol, on: req))

        case "search_symbols":
            guard let query = stringArg(args, "query") else {
                return #"{"error":"missing query"}"#
            }
            return try await encode(req.application.marketDataService.search(query: query, on: req))

        case "get_insights":
            let summary = try await req.application.insightsService.summary(days: 7, on: req.db)
            return try "{\"untrusted_data\":" + encode(summary) + "}"

        default:
            return #"{"error":"unknown read tool"}"#
        }
    }

    static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: OpenAIParameter] = [:],
        required: [String] = []
    ) -> OpenAITool {
        OpenAITool(function: OpenAIFunctionDef(
            name: name,
            description: description,
            parameters: OpenAIJSONSchema(properties: properties, required: required)
        ))
    }

    static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func stringArg(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func doubleArg(_ args: [String: Any], _ key: String) -> Double? {
        if let value = args[key] as? Double {
            return value
        }
        if let value = args[key] as? Int {
            return Double(value)
        }
        if let value = args[key] as? String {
            return Double(value)
        }
        return nil
    }

    static func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int {
            return value
        }
        if let value = args[key] as? Double {
            return Int(value)
        }
        if let value = args[key] as? String {
            return Int(value)
        }
        return nil
    }

    static func boolArg(_ args: [String: Any], _ key: String) -> Bool? {
        if let value = args[key] as? Bool {
            return value
        }
        if let value = args[key] as? String {
            return value.lowercased() == "true"
        }
        return nil
    }

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private struct FinancialOverview: Encodable {
        let dashboard: DashboardResponse
        let insights: DashboardInsightsResponse
    }

    private static let macroCountryProperties = [
        "country": OpenAIParameter(
            type: "string",
            description: "Region code: US, BR, PT, ES, DE, FR, IT, or EA. Ask the user when their intended region is unclear.",
            enumValues: MacroCountry.allCases.map(\.rawValue)
        ),
    ]

    private static let toolNames = Set(toolDefinitions().map(\.function.name))

    private static func macroCountry(_ args: [String: Any]) throws -> MacroCountry {
        guard let country = MacroCountry(query: stringArg(args, "country")) else {
            throw Abort(.badRequest, reason: "country must be US, BR, PT, ES, DE, FR, IT, or EA")
        }
        return country
    }

    private static func expenseDateRange(_ args: [String: Any]) -> (from: Date, to: Date)? {
        guard let month = intArg(args, "month"), (1 ... 12).contains(month),
              let year = intArg(args, "year"), (2000 ... 2100).contains(year)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let from = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: from),
              let to = calendar.date(byAdding: .day, value: -1, to: nextMonth)
        else { return nil }
        return (from, to)
    }

    private static func currentMonthStart() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: components) ?? Date()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

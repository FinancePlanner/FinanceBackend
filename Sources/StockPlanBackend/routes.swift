import Fluent
import FluentSQL
import Foundation
import Redis
import RediStack
import Vapor

private struct HealthResponse: Content {
    let status: String
}

private struct HealthCheckResponse: Content {
    let status: String
    let checks: [String: HealthCheck]
    let version: String
    let environment: String
}

private struct HealthCheck: Content {
    let status: String
    let message: String?
    let latencyMs: Double?
}

func routes(_ app: Application) throws {
    let api = app.grouped("v1")

    app.get("health") { _ async -> HealthResponse in
        HealthResponse(status: "ok")
    }

    app.get("health", "live") { _ async -> HealthResponse in
        HealthResponse(status: "ok")
    }

    app.get("health", "ready") { req async -> Response in
        let readiness = await makeReadinessResponse(req)
        let response = Response(status: readiness.status == "not_ready" ? .serviceUnavailable : .ok)
        try? response.content.encode(readiness)
        return response
    }

    api.get { _ async in
        "It works!"
    }

    api.get("hello") { _ async -> String in
        "Hello, world!"
    }

    try registerOpenAPIDocsRoutes(app)
    try app.register(collection: FinnhubWebhookController())
    try app.register(collection: PlaidWebhookController())
    try app.register(collection: BankCallbackController())
    try app.register(collection: RevenueCatWebhookController())
    try app.register(collection: SharingController())
    // Only mounted when a bot token is configured, and it authenticates via a
    // secret header rather than a session — Telegram cannot present one.
    if app.telegramConfiguration?.usesWebhook == true {
        try app.register(collection: TelegramWebhookController())
    }

    // RFC 8414 authorization-server metadata lives at the root well-known path.
    try app.register(collection: WellKnownController())

    try api.register(collection: MessagingController())
    try api.register(collection: AuthController(environment: app.environment))
    try api.register(collection: PersonalAccessTokenController())
    try api.register(collection: TokenIntrospectionController())
    try api.register(collection: OAuthServerController())
    try api.register(collection: BillingController())
    try api.register(collection: StockController())
    // Rate limit market data endpoints (quotes, search) to protect third-party API quotas.
    let marketRateLimit = RateLimitMiddleware(limit: 100, interval: 60, keyPrefix: "ratelimit:market")
    try api.grouped(marketRateLimit).register(collection: MarketDataController())
    try api.register(collection: ScenarioController())
    if goalPlanningRoutesEnabled() {
        try api.register(collection: GoalPlanningController())
    }
    try api.register(collection: WealthAutomationController())

    // Macro / inflation endpoints (Nowflation parity). Rate limit similar to market data.
    let macroRateLimit = RateLimitMiddleware(limit: 80, interval: 60, keyPrefix: "ratelimit:macro")
    try api.grouped(macroRateLimit).register(collection: MacroController())
    try api.register(collection: PortfolioController())
    try api.register(collection: PortfolioManagementController())
    try api.register(collection: RebalancingController())
    try api.register(collection: RetirementController())
    try api.register(collection: AdvancedReportingController())
    // Broker connect/sync hit third-party APIs and mutate stored credentials; rate limit
    // per-user and dedupe retried POSTs (OAuth callback, manual sync) via idempotency keys.
    let brokerRateLimit = RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:broker")
    try api.grouped(brokerRateLimit, IdempotencyMiddleware(keyPrefix: "idempotency:broker"))
        .register(collection: BrokerController())
    try api.register(collection: StatisticsController())
    try api.register(collection: NewsController())
    try api.register(collection: DashboardController())
    try api.register(collection: UserProfileController())
    try api.register(collection: EarningsController())
    try api.register(collection: FeedbackController())
    try api.register(collection: CryptoController())
    // Rate limit AI insight endpoints (LLM calls) to protect cost + provider quotas.
    let aiRateLimit = RateLimitMiddleware(limit: 20, interval: 60, keyPrefix: "ratelimit:ai")
    try api.grouped(aiRateLimit).register(collection: AIInsightsController())
    try api.grouped(aiRateLimit).register(collection: AIChatController())
    try api.grouped(aiRateLimit).register(collection: AIAssistantController())
    // Rate limited too: verification makes an outbound call per request.
    try api.grouped(aiRateLimit).register(collection: AIProviderCredentialController())
    try api.register(collection: BudgetController())
    try api.register(collection: BudgetingEngineController())
    try api.register(collection: ExpensesController())
    let financingRateLimit = RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:financing")
    try api.grouped(financingRateLimit).register(collection: FinancingController())
    // Receipt OCR is a paid vision call; rate-limit it. QR parsing is cheap but
    // shares the group for simplicity.
    let receiptsRateLimit = RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:receipts")
    try api.grouped(receiptsRateLimit).register(collection: ReceiptsController())
    // Spreadsheet import parses a user-supplied file and may spend an AI call
    // per upload, so it gets a tighter limit than the rest of expenses (which
    // is registered with none at all). Idempotency is opt-in via the header and
    // matters on commit, where a retry must not double-insert.
    let spreadsheetImportRateLimit = RateLimitMiddleware(
        limit: 10, interval: 60, keyPrefix: "ratelimit:expense-import"
    )
    try api.grouped(spreadsheetImportRateLimit, IdempotencyMiddleware(keyPrefix: "idempotency:expense-import"))
        .register(collection: ExpenseImportController())
    // Bank connect/sync hit the aggregator API; rate-limit and dedupe retried POSTs.
    let bankRateLimit = RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:banks")
    try api.grouped(bankRateLimit, IdempotencyMiddleware(keyPrefix: "idempotency:banks"))
        .register(collection: BankController())
    try api.register(collection: ReportsController())
    try api.register(collection: GoalsController())
    try api.register(collection: UserActivityController())
    try api.register(collection: BadgeController())
    try api.register(collection: AssetsController())
    try api.register(collection: TaxController())
    try api.register(collection: PushNotificationsController())
    try api.register(collection: DataExportController(exportService: app.dataExportService))
    try api.register(collection: ExportFileController(exportService: app.dataExportService))
    // Rate limit Hermes-backed insights (reads hit Postgres, but keep parity with market data).
    let insightsRateLimit = RateLimitMiddleware(limit: 60, interval: 60, keyPrefix: "ratelimit:insights")
    try api.grouped(insightsRateLimit).register(collection: InsightsController())
}

private func goalPlanningRoutesEnabled() -> Bool {
    guard let value = Environment.get("GOAL_PLANNING_ENABLED")?.lowercased() else { return true }
    return !["0", "false", "no", "off"].contains(value)
}

private func makeReadinessResponse(_ req: Request) async -> HealthCheckResponse {
    var checks: [String: HealthCheck] = [:]
    checks["database"] = await databaseHealthCheck(req)
    checks["redis"] = await redisHealthCheck(req)
    checks["mailer"] = mailerHealthCheck(req)
    checks["apns"] = apnsHealthCheck(req)
    checks["marketData"] = marketDataHealthCheck(req)
    checks["hermes"] = hermesHealthCheck(req)
    checks["macro"] = await macroHealthCheck(req)

    let hasFailure = checks.values.contains { $0.status == "unhealthy" }
    let hasWarning = checks.values.contains { $0.status == "degraded" }
    let status = hasFailure ? "not_ready" : (hasWarning ? "degraded" : "ready")

    return HealthCheckResponse(
        status: status,
        checks: checks,
        version: Environment.get("APP_VERSION") ?? Environment.get("GIT_SHA") ?? "unknown",
        environment: req.application.environment.name
    )
}

private func databaseHealthCheck(_ req: Request) async -> HealthCheck {
    let start = DispatchTime.now()
    guard let sql = req.db(.psql) as? any SQLDatabase else {
        return HealthCheck(status: "unhealthy", message: "PostgreSQL database is not configured.", latencyMs: nil)
    }
    do {
        try await sql.raw("SELECT 1").run()
        return HealthCheck(status: "healthy", message: nil, latencyMs: elapsedMilliseconds(since: start))
    } catch {
        req.logger.error("health.ready database failed error_type=\(String(reflecting: type(of: error)))")
        return HealthCheck(
            status: "unhealthy",
            message: "Database check failed.",
            latencyMs: elapsedMilliseconds(since: start)
        )
    }
}

private func redisHealthCheck(_ req: Request) async -> HealthCheck {
    let start = DispatchTime.now()
    guard req.application.redis.configuration != nil else {
        return HealthCheck(status: "skipped", message: "REDIS_URL is not configured.", latencyMs: nil)
    }
    do {
        _ = try await req.application.redis.send(command: "PING", with: [])
        return HealthCheck(status: "healthy", message: nil, latencyMs: elapsedMilliseconds(since: start))
    } catch {
        req.logger.error("health.ready redis failed error_type=\(String(reflecting: type(of: error)))")
        return HealthCheck(
            status: "unhealthy",
            message: "Redis check failed.",
            latencyMs: elapsedMilliseconds(since: start)
        )
    }
}

private func mailerHealthCheck(_ req: Request) -> HealthCheck {
    let mfaEnabled = envBoolForHealth("AUTH_MFA_ENABLED", default: req.application.environment == .production)
    let hasResend = !(Environment.get("RESEND_API_KEY") ?? "").isEmpty
        && !(Environment.get("RESEND_FROM_EMAIL") ?? "").isEmpty
    if mfaEnabled, !hasResend {
        return HealthCheck(status: "unhealthy", message: "MFA is enabled but Resend is not configured.", latencyMs: nil)
    }
    return HealthCheck(status: hasResend ? "healthy" : "skipped", message: hasResend ? nil : "Email delivery is disabled.", latencyMs: nil)
}

private func apnsHealthCheck(_ req: Request) -> HealthCheck {
    if req.application.pushNotificationSender is NoopPushNotificationSender {
        return HealthCheck(status: "skipped", message: "APNS is disabled; push delivery is unavailable.", latencyMs: nil)
    }

    guard let config = APNSBootstrapConfiguration.fromEnvironment(app: req.application) else {
        return HealthCheck(status: "skipped", message: "APNS is not configured; push delivery is disabled.", latencyMs: nil)
    }

    do {
        try config.validatePrivateKey()
        return HealthCheck(status: "healthy", message: nil, latencyMs: nil)
    } catch {
        req.logger.error("health.ready apns failed error_type=\(String(reflecting: type(of: error)))")
        return HealthCheck(status: "unhealthy", message: "APNS private key could not be parsed.", latencyMs: nil)
    }
}

private func marketDataHealthCheck(_: Request) -> HealthCheck {
    let hasFinnhub = !(Environment.get("FINNHUB_API_KEY") ?? "").isEmpty
    let hasIBKR = !(Environment.get("IBKR_API_BASE_URL") ?? "").isEmpty
    let hasFMP = !(Environment.get("FMP_API_KEY") ?? "").isEmpty
    if hasFinnhub || hasIBKR || hasFMP {
        return HealthCheck(status: "healthy", message: nil, latencyMs: nil)
    }
    return HealthCheck(status: "degraded", message: "No live market-data provider is configured.", latencyMs: nil)
}

private func hermesHealthCheck(_ req: Request) -> HealthCheck {
    guard req.application.insightsProvider.isEnabled else {
        return HealthCheck(status: "skipped", message: "HERMES_BASE_URL is not configured; insights sync is disabled.", latencyMs: nil)
    }

    let interval = Environment.get("HERMES_SYNC_INTERVAL_SECONDS").flatMap(Double.init(_:)) ?? 900
    guard let lastSuccess = req.application.insightsSyncStatus.lastSuccessAt else {
        return HealthCheck(status: "degraded", message: "Hermes sync has not completed yet.", latencyMs: nil)
    }
    // Degraded (never unhealthy) when the last successful sync is older than
    // three intervals — Hermes is a non-critical upstream.
    if Date().timeIntervalSince(lastSuccess) > interval * 3 {
        return HealthCheck(status: "degraded", message: "Hermes sync is stale.", latencyMs: nil)
    }
    return HealthCheck(status: "healthy", message: nil, latencyMs: nil)
}

private func macroHealthCheck(_ req: Request) async -> HealthCheck {
    let registry = req.application.macroProviderRegistry
    let countries = registry.enabledCountries
    guard !countries.isEmpty else {
        return HealthCheck(status: "skipped", message: "No macro providers configured; macro refresh is disabled.", latencyMs: nil)
    }

    let usCadence = Environment.get("MACRO_US_REFRESH_SECONDS").flatMap(Double.init(_:)) ?? 21600
    let intlCadence = Environment.get("MACRO_INTL_REFRESH_SECONDS").flatMap(Double.init(_:)) ?? 86400
    // DB-backed freshness so a restart doesn't reset countries to "never".
    let dbFreshness = await (try? req.application.macroRepository.freshness(on: req.db)) ?? [:]

    var stale: [String] = []
    let now = Date()
    for country in countries {
        let cadence = country == .us ? usCadence : intlCadence
        let inMemory = req.application.macroSyncStatus.lastSuccessAt(country)
        let lastSuccess = [inMemory, dbFreshness[country.rawValue]].compactMap(\.self).max()
        guard let lastSuccess else {
            stale.append("\(country.rawValue) (never)")
            continue
        }
        if now.timeIntervalSince(lastSuccess) > cadence * 3 {
            let hours = Int(now.timeIntervalSince(lastSuccess) / 3600)
            stale.append("\(country.rawValue) (\(hours)h)")
        }
    }

    // Degraded, never unhealthy — macro upstreams are non-critical.
    guard stale.isEmpty else {
        return HealthCheck(status: "degraded", message: "Macro data stale: \(stale.joined(separator: ", ")).", latencyMs: nil)
    }
    return HealthCheck(status: "healthy", message: nil, latencyMs: nil)
}

private func elapsedMilliseconds(since start: DispatchTime) -> Double {
    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return (Double(elapsed) / 1_000_000).rounded() / 1000
}

private func envBoolForHealth(_ key: String, default defaultValue: Bool) -> Bool {
    guard let rawValue = Environment.get(key)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return defaultValue
    }

    switch rawValue {
    case "1", "true", "yes", "y", "on":
        return true
    case "0", "false", "no", "n", "off":
        return false
    default:
        return defaultValue
    }
}

private func registerOpenAPIDocsRoutes(_ app: Application) throws {
    guard shouldExposeOpenAPIDocs(app) else {
        return
    }

    app.get("openapi.yaml") { _ async throws -> Response in
        guard let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml") else {
            throw Abort(.notFound, reason: "openapi.yaml is not bundled (check Package.swift resources)")
        }

        let data = try Data(contentsOf: url)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/yaml; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    app.get("docs") { _ async throws -> Response in
        let html = """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>StockPlanBackend API Docs</title>
            <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
          </head>
          <body>
            <div id="swagger-ui"></div>
            <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
            <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-standalone-preset.js"></script>
            <script>
              window.onload = () => {
                window.ui = SwaggerUIBundle({
                  url: '/openapi.yaml',
                  dom_id: '#swagger-ui',
                  presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
                  layout: 'BaseLayout'
                });
              };
            </script>
          </body>
        </html>
        """

        let res = Response(status: .ok)
        res.headers.contentType = .html
        res.body = .init(string: html)
        return res
    }
}

private func shouldExposeOpenAPIDocs(_ app: Application) -> Bool {
    envBoolForHealth("API_DOCS_ENABLED", default: app.environment != .production)
}

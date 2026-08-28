import APNS
import APNSCore
import Fluent
import FluentPostgresDriver
import FluentSQL
import JWT
import JWTKit
import NIOSSL
import Redis
import StockPlanShared
import Vapor
import VaporAPNS

/// configures your application
public func configure(_ app: Application) async throws {
    try ProductionConfiguration.validate(for: app)

    if app.environment == .testing {
        app.logger.logLevel = .warning
    }

    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.traceAutoPropagation = true
    app.routes.defaultMaxBodySize = "10mb"
    // Clear all default middleware (then, add back route logging)
    app.middleware = .init()
    let allowedOrigins = try ProductionConfiguration.allowedOrigins(
        from: Environment.get("ALLOWED_ORIGINS"),
        isProduction: app.environment == .production
    )
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .any(allowedOrigins), // In production, this should be more restricted.
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // cors middleware should come before default error middleware using `at: .beginning`
    app.middleware.use(cors, at: .beginning)
    // Add Vary: Origin for correct CDN caching when CORS is enabled.
    app.middleware.use(VaryHeaderMiddleware())
    app.middleware.use(SecurityHeadersMiddleware(includeHSTS: app.environment == .production))
    // Enable response compression (gzip/deflate) with 1KB threshold
    app.http.server.configuration.responseCompression = .enabled(initialByteBufferCapacity: 1024)
    app.middleware.use(ResponseCompressionMiddleware(override: .useDefault))
    app.middleware.use(APIErrorMiddleware())
    app.middleware.use(BillingErrorMiddleware())

    app.middleware.use(RequestLoggingMiddleware())
    // Add custom error handling middleware first.
    app.middleware.use(TracingMiddleware())

    // Configure global JSON decoder and encoder
    ContentConfiguration.global.use(decoder: JSONDecoder.backendAPI, for: .json)
    ContentConfiguration.global.use(encoder: JSONEncoder.backendAPI, for: .json)

    // === Prometheus Metrics (lightweight custom exporter) ===
    // Enabled by env PROMETHEUS_ENABLED=1 (off by default)
    if envBool("PROMETHEUS_ENABLED", default: false) {
        // Register HTTP metrics middleware early (before route logging)
        app.middleware.use(HTTPMetricsMiddleware(), at: .beginning)

        // Register business metrics service (singleton)
        app.businessMetrics = BusinessMetrics.shared

        // Expose /metrics endpoint
        try app.register(collection: MetricsController())
    }

    if envBool("OBS_TRACES_ENABLED", default: false) {
        let serviceName = Environment.get("OBS_SERVICE_NAME") ?? "StockPlanBackend"
        let environmentName = Environment.get("OBS_ENVIRONMENT") ?? app.environment.name
        let endpoint = Environment.get("OBS_OTLP_ENDPOINT") ?? "not-configured"
        app.logger.info(
            "observability.tracing enabled service=\(serviceName) environment=\(environmentName) otlp_endpoint=\(endpoint)"
        )
    }

    try await configurePersistence(app)
    try await configureAuthStack(app)

    let ibkrBaseURL = Environment.get("IBKR_API_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let ibkrOAuthConfiguration = try IBKROAuthConfiguration.fromEnvironment()
    let ibkrConnectMode = try IBKRConnectMode.fromEnvironment(hasOAuthConfiguration: ibkrOAuthConfiguration != nil)
    app.stocksRepository = DatabaseStocksRepository()
    app.brokersRepository = DatabaseBrokersRepository()
    app.brokersService = DefaultBrokersService(
        repo: app.brokersRepository,
        ibkrGatewayClient: IBKRBrokerGatewayClient(
            baseURL: ibkrBaseURL ?? "http://localhost:5000/v1/api",
            defaultCurrency: Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"
        ),
        ibkrOAuthClient: ibkrOAuthConfiguration.map(IBKROAuthClient.init(config:)),
        ibkrConnectMode: ibkrConnectMode,
        tokenVault: app.tokenEncryptionService
    )
    app.receiptOCRProvider = ReceiptOCRProviderBootstrap.fromEnvironment(app: app)
    app.spreadsheetAnalysisProvider = SpreadsheetAnalysisProviderBootstrap.fromEnvironment(app: app)

    configureBankProviders(app)
    app.marketDataRepository = DatabaseMarketDataRepository()
    let configuredMarketProvider = Environment.get("MARKET_PROVIDER")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let finnhubAPIKey = Environment.get("FINNHUB_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let fmpAPIKey = Environment.get("FMP_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let marketProviderKind = MarketDataProviderKind.select(
        configuredMarketProvider: configuredMarketProvider,
        hasFinnhubAPIKey: finnhubAPIKey?.isEmpty == false,
        hasIBKRBaseURL: ibkrBaseURL?.isEmpty == false
    )
    let marketProvider: any MarketDataProvider
    switch marketProviderKind {
    case .finnhub:
        marketProvider = FinnhubMarketDataProvider(apiKey: finnhubAPIKey ?? "")
    case .ibkr:
        marketProvider = IBKRMarketDataProvider(baseURL: ibkrBaseURL ?? "")
    case .disabled:
        if configuredMarketProvider == "finnhub" {
            app.logger.warning("MARKET_PROVIDER=finnhub but FINNHUB_API_KEY is not configured; market data disabled.")
        } else if configuredMarketProvider == "ibkr" {
            app.logger.warning("MARKET_PROVIDER=ibkr but IBKR_API_BASE_URL is not configured; market data disabled.")
        }
        marketProvider = DisabledMarketDataProvider()
    }

    let fmpProvider: (any FMPMarketDataProvider & CryptoDataProvider)? = if let fmpAPIKey, !fmpAPIKey.isEmpty {
        LiveFMPMarketDataProvider(apiKey: fmpAPIKey)
    } else {
        nil
    }

    app.marketDataService = DefaultMarketDataService(
        provider: marketProvider,
        fmpProvider: fmpProvider,
        cacheConfig: MarketDataCacheConfig.fromEnvironment(),
        fmpAccessTier: FMPAccessTier.fromEnvironment()
    )
    app.portfolioValuationService = DefaultPortfolioValuationService()
    app.statisticsRepository = DatabaseStatisticsRepository()
    app.statisticsService = DefaultStatisticsService(repo: app.statisticsRepository)
    app.newsRepository = DatabaseNewsRepository()
    let newsProvider: (any NewsProvider)? = if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        FinnhubNewsProvider(apiKey: finnhubAPIKey)
    } else {
        nil
    }
    app.marketNewsArchiveService = DefaultMarketNewsArchiveService(
        provider: newsProvider,
        fmpProvider: app.marketDataService.fmpProvider
    )
    app.newsService = DefaultNewsService(repo: app.newsRepository, provider: newsProvider)
    app.dashboardRepository = DatabaseDashboardRepository()
    app.dashboardService = DefaultDashboardService(
        repo: app.dashboardRepository,
        statisticsRepo: app.statisticsRepository
    )
    app.whyMovedService = DefaultWhyMovedService(statisticsRepo: app.statisticsRepository)
    app.userProfileRepository = DatabaseUserProfileRepository(encryptionService: app.userPIIEncryptionService)
    app.userProfileService = DefaultUserProfileService(repo: app.userProfileRepository)
    app.pushDeviceService = DatabasePushDeviceService()
    app.earningsNotificationPreferenceService = DatabaseEarningsNotificationPreferenceService()
    app.earningsNotificationEvaluator = DefaultEarningsNotificationEvaluator()
    // Data Export service setup
    app.dataExportRepository = DatabaseDataExportRepository()
    app.exportService = ExportService(repository: app.dataExportRepository, application: app)
    app.dataExportService = DefaultDataExportService(repository: app.dataExportRepository, exporter: app.exportService)
    try configureTaxOptimization(app)
    app.taxReportGenerator = TaxReportGenerator()
    let premiumEmails = Set(
        (Environment.get("BILLING_PREMIUM_EMAILS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    )
    app.entitlementResolver = DefaultEntitlementResolver(environment: app.environment, premiumEmails: premiumEmails)
    app.usageCounterService = DefaultUsageCounterService(entitlementResolver: app.entitlementResolver)
    app.portfolioAccessService = PortfolioAccessService(entitlementResolver: app.entitlementResolver)
    app.rebalancingService = DefaultRebalancingService()
    let advancedReportStoragePath = Environment.get("ADVANCED_REPORT_STORAGE_PATH")
        ?? app.directory.workingDirectory + "storage/advanced-reports"
    app.advancedReportStorage = LocalAdvancedReportStorage(rootDirectory: advancedReportStoragePath)
    let reportSigningSecret = Environment.get("REPORT_DOWNLOAD_SIGNING_SECRET")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if app.environment == .production, reportSigningSecret.count < 32 {
        throw Abort(
            .internalServerError,
            reason: "REPORT_DOWNLOAD_SIGNING_SECRET must contain at least 32 characters in production."
        )
    }
    app.reportDownloadSigner = ReportDownloadSigner(
        secret: reportSigningSecret.isEmpty ? "development-report-signing-secret-change-me" : reportSigningSecret
    )
    app.billingContextService = DefaultBillingContextService(
        entitlementResolver: app.entitlementResolver,
        usageCounterService: app.usageCounterService,
        trialService: app.trialService
    )
    app.thesisWatchService = DefaultThesisWatchService(billingContextService: app.billingContextService)
    app.billingService = DefaultBillingService()
    try validateBillingSecrets(app)
    app.targetAlertEvaluator = DefaultTargetAlertEvaluator()

    try configureAPNS(app)

    let earningsProvider: any EarningsProvider = if let finnhubAPIKey, !finnhubAPIKey.isEmpty {
        FinnhubEarningsProvider(apiKey: finnhubAPIKey)
    } else {
        DisabledEarningsProvider()
    }
    app.earningsService = DefaultEarningsService(provider: earningsProvider)

    if let fmpProvider {
        app.cryptoService = DefaultCryptoService(provider: fmpProvider)
    } else {
        app.logger.warning("FMP_API_KEY is not configured; using MockCryptoDataProvider for market data.")
        app.cryptoService = DefaultCryptoService(provider: MockCryptoDataProvider())
    }

    // AI insights (educational, Pro-gated). Backend proxy to OpenAI; key never
    // leaves the server. Boots disabled when no key is configured.
    // Plan-based routing: free users reach only zero-cost slugs, Pro leads with
    // the paid model and keeps the free floor beneath it. Nil when
    // AI_PLAN_ROUTING_ENABLED is off, which restores the single legacy chain.
    let aiModelRouter = makeAIModelRouter(app)
    app.aiModelRouter = aiModelRouter
    // The Pro chain is the system default: background and aggregate work is not
    // attributed to a user whose plan could pick for it.
    let openAIChatClient = aiModelRouter?.pro ?? makeOpenAIChatClient(app)
    app.openAIChatClient = openAIChatClient
    app.aiInsightsService = DefaultAIInsightsService(client: openAIChatClient)
    // Same client as the insight cards: both are Pro-gated, so both stay on
    // the Pro chain rather than being plan-routed.
    app.aiViewSummaryService = DefaultAIViewSummaryService(client: openAIChatClient)
    // In-app conversational assistant (Pro-gated, first-party only). Shares the
    // OpenAI client; tools execute in-process against the user's own data.
    app.aiChatService = DefaultAIChatService(client: openAIChatClient)

    app.insightsRepository = DatabaseInsightsRepository()
    app.insightsSyncStatus = InsightsSyncStatus()

    // Hermes (self-hosted, over Tailscale) is primary; DeepAPI takes over when a
    // Hermes call throws. See makeInsightsProvider for the env contract.
    let insightsProvider = makeInsightsProvider(app)
    app.insightsProvider = insightsProvider
    // Scraped/pulled ticker set is derived at sync time from users' holdings +
    // watchlist, capped at N. HERMES_TRACKED_TICKERS stays as an optional
    // always-include pin list.
    let tickerLimit = Environment.get("HERMES_TRACKED_TICKERS_LIMIT").flatMap(Int.init(_:)) ?? 25
    let pinnedTickers = (Environment.get("HERMES_TRACKED_TICKERS") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        .filter { !$0.isEmpty }
    app.insightsService = DefaultInsightsService(
        repo: app.insightsRepository,
        provider: insightsProvider,
        tickerLimit: tickerLimit,
        pinnedTickers: pinnedTickers
    )

    // Telegram. A missing bot token disables the whole feature: no route is
    // mounted and no poller runs, so a deployment without one behaves exactly
    // as it did before the bot existed.
    let telegramConfiguration = TelegramConfiguration.resolve(
        TelegramConfiguration.load(),
        environment: app.environment,
        logger: app.logger
    )
    app.telegramConfiguration = telegramConfiguration
    if let telegramConfiguration {
        // Registered in both modes: a webhook deployment still runs turns
        // detached, and they must not outlive the application.
        app.lifecycle.use(TelegramTurnDrain())
        // Also both modes. The menu has nothing to do with how updates arrive,
        // and living on the poller meant production never published one.
        app.lifecycle.use(TelegramCommandMenu(
            client: TelegramClient(token: telegramConfiguration.botToken)
        ))
    }
    if let telegramConfiguration, !telegramConfiguration.usesWebhook {
        app.lifecycle.use(TelegramPoller(client: TelegramClient(token: telegramConfiguration.botToken)))
    }

    // MARK: Retail sentiment

    //
    // Reads never touch a provider — the query service is Postgres-only, same
    // as insights — so a scraping outage costs freshness, never latency.
    app.sentimentRepository = DatabaseSentimentRepository()
    app.sentimentSyncStatus = SentimentSyncStatus()
    let sentimentWindowDays = Environment.get("SENTIMENT_WINDOW_DAYS").flatMap(Int.init(_:)) ?? 7
    app.sentimentQueryService = DefaultSentimentQueryService(
        repo: app.sentimentRepository,
        marketDataService: app.marketDataService,
        windowDays: sentimentWindowDays
    )

    app.sentimentIndexSeeder = SentimentIndexSeeder(
        sentimentRepo: app.sentimentRepository,
        fmpAPIKey: Environment.get("FMP_API_KEY"),
        // Explicit override wins over the FMP fetch. Index membership changes
        // several times a year, so neither is hardcoded.
        overrideSymbols: (Environment.get("SENTIMENT_SP500_SYMBOLS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    )

    let sentimentResolver = SentimentUniverseResolver(
        insightsRepo: app.insightsRepository,
        sentimentRepo: app.sentimentRepository,
        pinnedSymbols: pinnedTickers,
        userTierLimit: Environment.get("SENTIMENT_USER_TIER_LIMIT").flatMap(Int.init(_:)) ?? 500,
        trendingTierLimit: Environment.get("SENTIMENT_TRENDING_TIER_LIMIT").flatMap(Int.init(_:)) ?? 50
    )

    // Themes are the only paid-per-symbol step, so they are skipped entirely
    // when no chat client is configured rather than failing the run.
    let themeService: (any SentimentThemeGenerating)? = app.openAIChatClient is DisabledOpenAIChatClient
        ? nil
        : DefaultSentimentThemeService(
            client: app.openAIChatClient,
            maxPosts: Environment.get("SENTIMENT_THEME_POSTS").flatMap(Int.init(_:)) ?? 40,
            maxThemes: 5
        )

    app.sentimentAggregationService = DefaultSentimentAggregationService(
        provider: insightsProvider,
        insightsRepo: app.insightsRepository,
        sentimentRepo: app.sentimentRepository,
        resolver: sentimentResolver,
        themeService: themeService,
        windowDays: sentimentWindowDays,
        batchSize: Environment.get("SENTIMENT_BATCH_SIZE").flatMap(Int.init(_:)) ?? 20,
        postsPerSymbol: Environment.get("SENTIMENT_POSTS_PER_SYMBOL").flatMap(Int.init(_:)) ?? 100,
        maxThemeSymbols: Environment.get("SENTIMENT_MAX_THEME_SYMBOLS").flatMap(Int.init(_:)) ?? 150
    )

    let cleanupIntervalMinutes = Environment.get("AUTH_TOKEN_CLEANUP_INTERVAL_MINUTES").flatMap(Int.init(_:)) ?? 60
    app.lifecycle.use(AuthTokenCleanup(interval: TimeInterval(cleanupIntervalMinutes * 60)))
    app.lifecycle.use(IBKRSyncJob())
    app.lifecycle.use(BankSyncJob())
    let apnsAlertPollSeconds = Environment.get("APNS_ALERT_POLL_SECONDS").flatMap(Int64.init(_:)) ?? 300
    app.lifecycle.use(TargetAlertPoller(intervalSeconds: apnsAlertPollSeconds))
    if envBool("REBALANCING_ALERTS_ENABLED", default: true) {
        let interval = Environment.get("REBALANCING_ALERT_POLL_SECONDS").flatMap(Int64.init(_:)) ?? 300
        app.lifecycle.use(RebalancingAlertPoller(intervalSeconds: interval))
    }
    let earningsAlertPollSeconds = Environment.get("EARNINGS_ALERT_POLL_SECONDS").flatMap(Int64.init(_:)) ?? 86400
    app.lifecycle.use(EarningsNotificationPoller(intervalSeconds: earningsAlertPollSeconds))
    let taxProjectionPollSeconds = Int64(Environment.get("TAX_PROJECTION_POLL_SECONDS") ?? "86400") ?? 86400
    app.lifecycle.use(TaxProjectionPoller(intervalSeconds: taxProjectionPollSeconds))
    let taxReportStoragePath = Environment.get("TAX_REPORT_STORAGE_PATH")
        ?? app.directory.workingDirectory + "storage/tax-reports"
    app.taxReportStorage = LocalTaxReportStorage(rootDirectory: taxReportStoragePath)
    let taxReportGenerationPollSeconds = Int64(Environment.get("TAX_REPORT_GENERATION_POLL_SECONDS") ?? "10") ?? 10
    app.lifecycle.use(TaxReportGenerationPoller(intervalSeconds: taxReportGenerationPollSeconds))
    let taxReportCleanupSeconds = Int64(Environment.get("TAX_REPORT_CLEANUP_INTERVAL_SECONDS") ?? "3600") ?? 3600
    app.lifecycle.use(TaxReportCleanupJob(intervalSeconds: taxReportCleanupSeconds))
    app.lifecycle.use(TrialExpirationJob())
    // Data Export cleanup (expire files after 7 days)
    app.lifecycle.use(DataExportCleanupJob(repository: app.dataExportRepository, interval: 86400))
    let hermesSyncSeconds = Environment.get("HERMES_SYNC_INTERVAL_SECONDS").flatMap(Int64.init(_:)) ?? 900
    app.lifecycle.use(HermesSyncJob(intervalSeconds: hermesSyncSeconds))
    // Daily roll-up, built on an hourly tick so a restart cannot skip the day.
    app.lifecycle.use(SentimentAggregationJob(
        targetHourUTC: Environment.get("SENTIMENT_AGGREGATION_HOUR_UTC").flatMap(Int.init(_:)) ?? 5
    ))
    app.lifecycle.use(SentimentRetentionJob(
        postRetentionDays: Environment.get("SENTIMENT_POST_RETENTION_DAYS").flatMap(Int.init(_:)) ?? 90,
        dailyRetentionDays: Environment.get("SENTIMENT_DAILY_RETENTION_DAYS").flatMap(Int.init(_:)) ?? 730
    ))
    let thesisWatchSyncSeconds = Int64(Environment.get("THESIS_WATCH_SYNC_SECONDS").flatMap(Int.init(_:)) ?? 900)
    let thesisWatchSymbolsPerSync = Environment.get("THESIS_WATCH_SYMBOLS_PER_SYNC").flatMap(Int.init(_:)) ?? 30
    app.lifecycle.use(ThesisWatchIngestionJob(
        intervalSeconds: thesisWatchSyncSeconds,
        maxSymbolsPerRun: thesisWatchSymbolsPerSync
    ))
    app.lifecycle.use(ThesisWatchNotificationPoller(intervalSeconds: thesisWatchSyncSeconds))
    app.lifecycle.use(ScenarioRunWorker(
        intervalSeconds: Environment.get("SCENARIO_WORKER_INTERVAL_SECONDS").flatMap(Int64.init) ?? 2,
        maxConcurrent: Environment.get("SCENARIO_WORKER_MAX_CONCURRENT").flatMap(Int.init) ?? 2
    ))
    app.lifecycle.use(MarketHistoryIngestionJob(
        intervalSeconds: Environment.get("SCENARIO_HISTORY_REFRESH_SECONDS").flatMap(Int64.init) ?? 86400
    ))
    app.lifecycle.use(ScenarioRetentionJob())
    app.lifecycle.use(AIAssistantRetentionJob())
    // Import sessions hold encrypted spreadsheet contents for an hour;
    // clients delete on cancel, this guarantees it when they can't.
    app.lifecycle.use(ExpenseImportRetentionJob())
    app.lifecycle.use(AIDailyTipJob())
    app.lifecycle.use(AdvancedReportWorker(
        gotenbergBaseURL: Environment.get("GOTENBERG_BASE_URL") ?? "http://gotenberg:3000",
        intervalSeconds: Environment.get("ADVANCED_REPORT_WORKER_INTERVAL_SECONDS").flatMap(Int64.init) ?? 10
    ))
    app.lifecycle.use(AdvancedReportRetentionJob(
        intervalSeconds: Environment.get("ADVANCED_REPORT_CLEANUP_INTERVAL_SECONDS").flatMap(Int64.init) ?? 3600
    ))
    app.lifecycle.use(WealthAutomationDailyJob(
        intervalSeconds: Environment.get("WEALTH_AUTOMATION_INTERVAL_SECONDS").flatMap(Int64.init) ?? 86400,
        rebalanceCooldownSeconds: Environment.get("WEALTH_AUTOMATION_REBALANCE_COOLDOWN_SECONDS")
            .flatMap(Int64.init) ?? 604_800
    ))
    configureGoalPlanningJob(app)

    // Macro / inflation (Nowflation parity). FRED is the keystone provider:
    // without FRED_API_KEY the US (and intl fallback) stay disabled while
    // Eurostat/IBGE still serve PT/EA/BR.
    let macroEnabled = envBool("MACRO_ENABLED", default: true)
    let fredAPIKey = Environment.get("FRED_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let nowflationBaseURL = Environment.get("NOWFLATION_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let nowflationSnapshotPath = Environment.get("NOWFLATION_SNAPSHOT_PATH")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let nowflation = NowflationEnrichment(baseURL: nowflationBaseURL, snapshotPath: nowflationSnapshotPath)
    let macroPlan = MacroProviderPlanSelection.plan(
        macroEnabled: macroEnabled,
        hasFREDKey: !fredAPIKey.isEmpty,
        nowflationConfigured: nowflation.isEnabled
    )
    app.macroRepository = DatabaseMacroRepository()
    app.macroSyncStatus = MacroSyncStatus()
    let fredProvider: FREDMacroProvider? = fredAPIKey.isEmpty ? nil : FREDMacroProvider(apiKey: fredAPIKey)
    app.macroProviderRegistry = MacroProviderRegistry.build(
        plan: macroPlan,
        fred: fredProvider,
        eurostat: EurostatMacroProvider(),
        ibge: IBGEMacroProvider(),
        nowflation: nowflation,
        extraEnrichments: [
            SeekingAlphaEnrichment(flagEnabled: envBool("MACRO_ENRICHMENT_SEEKING_ALPHA_ENABLED", default: false)),
            InvestingComEnrichment(flagEnabled: envBool("MACRO_ENRICHMENT_INVESTING_ENABLED", default: false)),
        ]
    )
    app.macroService = DefaultMacroService(
        repository: app.macroRepository,
        registry: app.macroProviderRegistry,
        allowStubFallback: envBool("MACRO_ALLOW_STUB_FALLBACK", default: app.environment != .production),
        fredHub: fredProvider,
        bcbHub: BCBSgsProvider()
    )
    let macroTickSeconds = Environment.get("MACRO_REFRESH_INTERVAL_SECONDS").flatMap(Int64.init(_:)) ?? 3600
    let macroUSRefreshSeconds = Environment.get("MACRO_US_REFRESH_SECONDS").flatMap(Double.init(_:)) ?? 21600
    let macroIntlRefreshSeconds = Environment.get("MACRO_INTL_REFRESH_SECONDS").flatMap(Double.init(_:)) ?? 86400
    app.lifecycle.use(MacroRefreshJob(
        tickIntervalSeconds: macroTickSeconds,
        usRefreshSeconds: macroUSRefreshSeconds,
        intlRefreshSeconds: macroIntlRefreshSeconds
    ))

    registerMigrations(app)

    // register routes
    try routes(app)
}

/// Registers the read-only bank aggregators. Plaid (US) and GoCardless (EU)
/// each enable only when their credentials are configured.
private func configureBankProviders(_ app: Application) {
    var bankProviders: [any BankProvider] = []
    if let plaidConfig = PlaidConfiguration.fromEnvironment() {
        bankProviders.append(PlaidProvider(client: PlaidClient(config: plaidConfig)))
        app.plaidConfiguration = plaidConfig
    } else {
        app.logger.warning("Plaid is disabled. Configure PLAID_CLIENT_ID and PLAID_SECRET to enable US bank sync.")
    }
    if let gcConfig = GoCardlessConfiguration.fromEnvironment() {
        bankProviders.append(GoCardlessProvider(client: GoCardlessClient(config: gcConfig)))
    } else {
        app.logger.warning("GoCardless is disabled. Configure GOCARDLESS_SECRET_ID and GOCARDLESS_SECRET_KEY to enable EU bank sync.")
    }
    app.bankProviderRegistry = BankProviderRegistry(providers: bankProviders)
}

private func configureTaxOptimization(_ app: Application) throws {
    let validatedJurisdictions = Set(
        (Environment.get("TAX_VALIDATED_JURISDICTIONS") ?? "")
            .split(separator: ",")
            .compactMap { TaxJurisdiction(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased()) }
    )
    app.taxService = try DefaultTaxService(
        rules: TaxRuleRegistry(validatedJurisdictions: validatedJurisdictions),
        catalog: TaxOptimizationCatalog.bundled(),
        isV2Enabled: envBool("TAX_OPTIMIZATION_V2", default: true)
    )
}

private func configureGoalPlanningJob(_ app: Application) {
    guard envBool("GOAL_PLANNING_ENABLED", default: true),
          envBool("GOAL_EVALUATOR_ENABLED", default: true)
    else { return }
    let interval = Environment.get("GOAL_EVALUATOR_INTERVAL_SECONDS").flatMap(Int64.init) ?? 86400
    app.lifecycle.use(GoalPlanningDailyJob(intervalSeconds: interval))
}

/// Fail-fast validation of billing secrets at boot.
///
/// A missing `REVENUECAT_WEBHOOK_SECRET` makes `/webhooks/revenuecat` return 503 for every
/// delivery, silently dropping purchase events so paying users are never granted pro. A missing
/// `REVENUECAT_API_KEY` breaks the `/billing/restore` recovery path. In production we refuse to
/// boot so the misconfiguration surfaces at deploy time instead of as lost revenue; elsewhere we
/// log a loud warning.
func validateBillingSecrets(_ app: Application) throws {
    let apiKey = (Environment.get("REVENUECAT_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    let webhookSecret = (Environment.get("REVENUECAT_WEBHOOK_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    let hmacSecret = (Environment.get("REVENUECAT_HMAC_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")

    var missing: [String] = []
    if apiKey.isEmpty {
        missing.append("REVENUECAT_API_KEY")
    }
    if webhookSecret.isEmpty, hmacSecret.isEmpty {
        missing.append("REVENUECAT_WEBHOOK_SECRET or REVENUECAT_HMAC_SECRET")
    }

    guard !missing.isEmpty else { return }

    let list = missing.joined(separator: ", ")
    if app.environment == .production {
        app.logger.critical("Missing required billing secrets: \(list). Refusing to boot.")
        throw Abort(.internalServerError, reason: "Missing required billing secrets: \(list).")
    } else {
        app.logger.warning("Billing secrets not configured: \(list). RevenueCat webhooks and restore will not work.")
    }
}

func configureAPNS(_ app: Application) throws {
    guard let apnsConfig = APNSBootstrapConfiguration.fromEnvironment(app: app) else {
        app.pushNotificationSender = NoopPushNotificationSender()
        return
    }

    do {
        try apnsConfig.validatePrivateKey()
        try app.apns.configure(
            .jwt(
                privateKey: .loadFrom(string: apnsConfig.privateKeyP8),
                keyIdentifier: apnsConfig.keyID,
                teamIdentifier: apnsConfig.teamID
            )
        )
        app.pushNotificationSender = APNSPushNotificationSender(topic: apnsConfig.topic)
    } catch {
        guard app.environment != .production else {
            throw error
        }

        app.logger.warning(
            "APNS is disabled because APNS_PRIVATE_KEY_P8 could not be parsed in \(app.environment.name): \(String(describing: error))"
        )
        app.pushNotificationSender = NoopPushNotificationSender()
    }
}

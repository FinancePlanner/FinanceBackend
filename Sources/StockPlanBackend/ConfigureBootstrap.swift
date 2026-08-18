import Fluent
import FluentPostgresDriver
import FluentSQL
import JWT
import JWTKit
import Redis
import Vapor

func configurePersistence(_ app: Application) async throws {
    let isTesting = app.environment == .testing
    let databaseHost = isTesting
        ? (Environment.get("TEST_DATABASE_HOST")
            ?? Environment.get("DATABASE_HOST")
            ?? "127.0.0.1")
        : (Environment.get("DATABASE_HOST") ?? "localhost")
    let databasePort = isTesting
        ? (Environment.get("TEST_DATABASE_PORT").flatMap(Int.init(_:))
            ?? Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
            ?? 5432)
        : (Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber)
    let databaseUsername = isTesting
        ? (Environment.get("TEST_DATABASE_USERNAME")
            ?? Environment.get("DATABASE_USERNAME")
            ?? "vapor_username")
        : (Environment.get("DATABASE_USERNAME") ?? "vapor_username")
    let databasePassword = isTesting
        ? (Environment.get("TEST_DATABASE_PASSWORD")
            ?? Environment.get("DATABASE_PASSWORD")
            ?? "vapor_password")
        : (Environment.get("DATABASE_PASSWORD") ?? "vapor_password")
    let databaseName = isTesting
        ? (Environment.get("TEST_DATABASE_NAME")
            ?? Environment.get("DATABASE_NAME")
            ?? "vapor_database")
        : (Environment.get("DATABASE_NAME") ?? "vapor_database")
    let testDatabaseSchema: String? = {
        guard isTesting else { return nil }
        if let configured = Environment.get("TEST_DATABASE_SCHEMA")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configured.isEmpty
        {
            return configured.replacingOccurrences(
                of: #"[^a-zA-Z0-9_]"#,
                with: "_",
                options: .regularExpression
            )
        }

        return "stockplan_test_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_").lowercased())"
    }()

    var postgresConfiguration = try SQLPostgresConfiguration(
        hostname: databaseHost,
        port: databasePort,
        username: databaseUsername,
        password: databasePassword,
        database: databaseName,
        tls: .prefer(.init(configuration: .clientDefault))
    )
    if let testDatabaseSchema {
        postgresConfiguration.searchPath = [testDatabaseSchema]
    }

    app.databases.use(
        DatabaseConfigurationFactory.postgres(configuration: postgresConfiguration),
        as: .psql
    )

    if let testDatabaseSchema,
       let sqlDatabase = app.db(.psql) as? any SQLDatabase
    {
        try await sqlDatabase.raw("CREATE SCHEMA IF NOT EXISTS \(unsafeRaw: testDatabaseSchema)").run()
    }

    if isTesting {
        app.logger.info("Redis disabled in testing environment.")
    } else if let redisURL = Environment.get("REDIS_URL"), !redisURL.isEmpty {
        do {
            app.redis.configuration = try RedisConfiguration(url: redisURL)
            // Idempotency for mutations — clients set Idempotency-Key header.
            // Caches POST/PUT/DELETE responses in Redis (24h TTL). No-op for other methods or missing header.
            app.middleware.use(IdempotencyMiddleware(ttl: 86400))
        } catch {
            app.logger.warning("Redis disabled: could not parse/configure REDIS_URL. error=\(error)")
        }
    } else {
        app.logger.warning("Redis disabled: REDIS_URL not set. IdempotencyMiddleware disabled")
    }
}

func configureAuthStack(_ app: Application) async throws {
    let jwtSecret = Environment.get("JWT_SECRET") ?? "dev-secret"
    await app.jwt.keys.add(hmac: HMACKey(from: jwtSecret), digestAlgorithm: .sha256)
    app.userPIIEncryptionService = try UserPIIEncryptionBootstrap.fromEnvironment(app: app)
    app.tokenEncryptionService = try TokenEncryptionBootstrap.fromEnvironment(app: app)
    app.authRepository = DatabaseAuthRepository(encryptionService: app.userPIIEncryptionService)
    var oauthProviders: [OAuthProvider: any OAuthProviderClient] = [:]
    var oauthWebProviders: [OAuthProvider: any OAuthProviderClient] = [:]
    if let appleConfig = AppleOAuthProviderClient.Config.fromEnvironment() {
        oauthProviders[.apple] = AppleOAuthProviderClient(config: appleConfig)
    } else {
        app.logger.warning("Apple OAuth is disabled. Configure OAUTH_APPLE_CLIENT_ID, OAUTH_APPLE_TEAM_ID, OAUTH_APPLE_KEY_ID, and OAUTH_APPLE_PRIVATE_KEY.")
    }
    if let googleConfig = GoogleOAuthProviderClient.Config.fromEnvironment() {
        oauthProviders[.google] = GoogleOAuthProviderClient(config: googleConfig)
    } else {
        app.logger.warning("Google OAuth is disabled. Configure OAUTH_GOOGLE_CLIENT_ID (and optionally OAUTH_GOOGLE_CLIENT_SECRET for Web/confidential clients).")
    }
    // Web (browser) Google sign-in needs a "Web application" OAuth client, since iOS
    // client types cannot register https redirect URIs. When configured, https redirects
    // use this client; native iOS custom-scheme redirects keep using OAUTH_GOOGLE_CLIENT_ID.
    if let googleWebConfig = GoogleOAuthProviderClient.Config.fromEnvironment(
        clientIDKey: "OAUTH_GOOGLE_WEB_CLIENT_ID",
        clientSecretKey: "OAUTH_GOOGLE_WEB_CLIENT_SECRET"
    ) {
        oauthWebProviders[.google] = GoogleOAuthProviderClient(config: googleWebConfig)
    } else {
        app.logger.warning("Google Web OAuth is not configured. Browser Google sign-in will reuse OAUTH_GOOGLE_CLIENT_ID, which fails for iOS-type clients. Set OAUTH_GOOGLE_WEB_CLIENT_ID and OAUTH_GOOGLE_WEB_CLIENT_SECRET.")
    }
    if let xConfig = XOAuthProviderClient.Config.fromEnvironment() {
        oauthProviders[.x] = XOAuthProviderClient(config: xConfig)
    } else {
        app.logger.warning("X OAuth is disabled. Configure OAUTH_X_CLIENT_ID (and optionally OAUTH_X_CLIENT_SECRET).")
    }
    let mfaEnabled = envBool("AUTH_MFA_ENABLED", default: app.environment == .production)
    let mfaAllowLegacyBypass = envBool("AUTH_MFA_ALLOW_LEGACY_BYPASS", default: app.environment != .production)
    let mfaConfig = AuthMFAConfig(
        enabled: mfaEnabled,
        allowLegacyBypass: mfaAllowLegacyBypass,
        codeTTLSeconds: Environment.get("AUTH_MFA_CODE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 300,
        maxVerifyAttempts: Environment.get("AUTH_MFA_MAX_VERIFY_ATTEMPTS").flatMap(Int.init(_:)) ?? 5,
        resendCooldownSeconds: Environment.get("AUTH_MFA_RESEND_COOLDOWN_SECONDS").flatMap(Int.init(_:)) ?? 30,
        maxResends: Environment.get("AUTH_MFA_MAX_RESENDS").flatMap(Int.init(_:)) ?? 3,
        bypassEmails: envEmailSet("AUTH_MFA_BYPASS_EMAILS")
    )
    app.authService = DefaultAuthService(
        repo: app.authRepository,
        oauthProviders: oauthProviders,
        oauthWebProviders: oauthWebProviders,
        mfaConfig: mfaConfig,
        trialService: app.trialService
    )
    let webAuthnConfig = WebAuthnConfig.fromEnvironment(logger: app.logger)
    if webAuthnConfig == nil {
        app.logger.warning("WebAuthn is disabled. Configure WEBAUTHN_RP_ID and WEBAUTHN_ORIGINS.")
    }
    app.webAuthnService = DefaultWebAuthnService(
        config: webAuthnConfig,
        authService: app.authService
    )
    let resendAPIKey = Environment.get("RESEND_API_KEY")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resendFromEmail = Environment.get("RESEND_FROM_EMAIL")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resendBaseURLRaw = Environment.get("RESEND_BASE_URL")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !resendAPIKey.isEmpty, !resendFromEmail.isEmpty {
        let resendBaseURL = URL(string: resendBaseURLRaw ?? "") ?? URL(string: "https://api.resend.com")!
        app.mailer = ResendMailerService(
            apiKey: resendAPIKey,
            fromEmail: resendFromEmail,
            baseURL: resendBaseURL
        )
    } else {
        if mfaEnabled, app.environment == .production {
            throw Abort(
                .internalServerError,
                reason: "MFA is enabled but RESEND_API_KEY and RESEND_FROM_EMAIL are not configured."
            )
        }
        app.mailer = ConsoleMailerService()
    }
}

func registerMigrations(_ app: Application) {
    app.migrations.add(CreateUser())
    app.migrations.add(AddAccountLockoutAndVerificationFields())
    app.migrations.add(AddUserProfileFields())
    app.migrations.add(DeleteFirstNameLastName())
    app.migrations.add(AddUserProfileMetadataFields())
    app.migrations.add(CreateGoal())
    app.migrations.add(AddGoalStatusFields())
    app.migrations.add(CreateAccount())
    app.migrations.add(CreateInstrument())
    app.migrations.add(CreateTransaction())
    app.migrations.add(CreateLot())
    app.migrations.add(CreatePosition())
    app.migrations.add(CreateCashBalance())
    app.migrations.add(CreateDividend())
    app.migrations.add(CreateFxRate())
    app.migrations.add(CreatePrice())
    app.migrations.add(CreatePasswordResetToken())
    app.migrations.add(AddPasswordResetTokenAttemptFields())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreateMFAChallenge())
    app.migrations.add(CreateOAuthTables())
    app.migrations.add(AddOAuthFlowPurposeAndUserID())
    app.migrations.add(CreateWebAuthnTables())
    app.migrations.add(CreateWebAuthnRegisterChallenges())
    app.migrations.add(CreateStock())
    app.migrations.add(AddAssetCategoryToStocks())
    app.migrations.add(AddImportSourceFieldsToStocks())
    app.migrations.add(CreateWatchlistItem())
    app.migrations.add(AddWatchlistMetadataFields())
    app.migrations.add(AddPortfolioAndWatchlistLists())
    app.migrations.add(CreateNewsItem())
    app.migrations.add(CreateResearchNote())
    app.migrations.add(CreateTarget())
    app.migrations.add(AddTargetAlertFields())
    app.migrations.add(CreatePushDevice())
    app.migrations.add(CreateEarningsNotificationPreference())
    app.migrations.add(CreateEarningsNotificationDelivery())
    app.migrations.add(CreatePriceHistory())
    app.migrations.add(CreateQuoteCache())
    app.migrations.add(AddQuoteFields())
    app.migrations.add(CreateSearchCache())
    app.migrations.add(CreateStatisticsSnapshot())
    app.migrations.add(CreateBrokerConnection())
    app.migrations.add(AddBrokerOAuthFlowAndConnectionMetadata())
    app.migrations.add(CreateMarketNewsArchive())
    app.migrations.add(AddImageURLToMarketNewsArchive())
    app.migrations.add(CreateThesisWatchTables())
    app.migrations.add(AddUserScopedQueryIndexes())
    app.migrations.add(AddQuoteCacheLookupIndex())
    app.migrations.add(CreateStockValuation())
    app.migrations.add(CreateProfileCache())
    app.migrations.add(CreateBasicFinancialsCache())
    app.migrations.add(CreateAnalystEstimatesCache())
    app.migrations.add(CreateFinancialGrowthCache())
    app.migrations.add(CreateRatiosTTMCache())
    app.migrations.add(CreateRatiosCache())
    app.migrations.add(AddDatabaseOptimizations())
    app.migrations.add(CreateFeedback())
    app.migrations.add(CreateCryptoPortfolioItem())
    app.migrations.add(CreateExpensesTables())
    app.migrations.add(AddBudgetAlertThreshold())
    app.migrations.add(AddExpenseSharingFields())
    app.migrations.add(ConvertBudgetPillarEnumToString())
    app.migrations.add(CreateExpenseCategoryTable())
    app.migrations.add(CreateRecurringTemplatesTable())
    app.migrations.add(CreateFinancingTables())
    app.migrations.add(AddExpenseCurrencyFields())
    app.migrations.add(CreateReportSuggestionDismissals())
    app.migrations.add(AddHouseholdPartnerDisplayNameToUsers())
    app.migrations.add(AddEncryptedUserProfileFields())
    app.migrations.add(AddTrialFields())
    // Must exist before BackfillEncryptedUserProfileFields: that job loads the
    // current User model, which now selects dca_symbol.
    app.migrations.add(AddDcaSymbolToUsers())
    app.migrations.add(BackfillEncryptedUserProfileFields())
    app.migrations.add(CreateUserActivity())
    app.migrations.add(AddNewsViewedActivityType())
    app.migrations.add(AddReferenceKeyToUserActivity())
    app.migrations.add(CreateUserBadge())
    app.migrations.add(CreateBillingTables())
    app.migrations.add(AddSubscriptionPlanChangeFields())
    app.migrations.add(CreateTrialWarning())
    app.migrations.add(CreateCoupons())
    app.migrations.add(AddCouponGrantType())
    app.migrations.add(CreateCouponRedemptions())
    app.migrations.add(CreateDataExport())
    app.migrations.add(CreateInsightEvent())
    app.migrations.add(CreateSentimentSnapshot())
    app.migrations.add(CreateTickerSentimentPost())
    app.migrations.add(CreateNetWorthSnapshot())
    app.migrations.add(CreateMacroTables())
    app.migrations.add(CreatePersonalAccessTokens())
    app.migrations.add(CreateOAuthServerTables())
    app.migrations.add(CreateTaxOptimizationTables())
    app.migrations.add(AddInstrumentMarketAdmissionFields())
    app.migrations.add(AddInstrumentMarketAdmissionEvidence())
    app.migrations.add(AddInstrumentFundClassification())
    app.migrations.add(CreateTaxLossCarryforwardLedger())
    app.migrations.add(CreateGermanyStockLossLedger())
    app.migrations.add(CreateGermanyStockLossApplications())
    app.migrations.add(CreateGermanyGeneralLossLedger())
    app.migrations.add(CreateGermanyFundAnnualHoldings())
    app.migrations.add(CreateGermanyFundAdvanceAllocations())
    app.migrations.add(AddTaxReportRetryFields())
    app.migrations.add(CreateScenarioPlanningTables())
    app.migrations.add(ExpandFinancialGoalPlanning())
    app.migrations.add(CreateHoldingRiskProfiles())
    app.migrations.add(CreateMarketPriceBars())
    app.migrations.add(EncryptBrokerConnectionTokens())
    app.migrations.add(CreateBankTables())
    app.migrations.add(CreateAIAssistantTables())
    app.migrations.add(AddAIActionAuditUniqueness())
    app.migrations.add(CreatePortfolioManagementAndReportingTables())
    app.migrations.add(CreateWealthAutomationTables())
    app.migrations.add(CreateBudgetingEngineTables())
    app.migrations.add(CreateRebalancingTables())
    app.migrations.add(ExpandTaxOptimizationV2())
    app.migrations.add(SeedTaxReplacementCatalogInstruments())
    app.migrations.add(CreateBankLinkFlow())
    app.migrations.add(CreateExpenseImportSessions())
    app.migrations.add(CreateUserAIProviderCredentials())
}

func envBool(_ key: String, default defaultValue: Bool) -> Bool {
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

func envEmailSet(_ key: String) -> Set<String> {
    guard let rawValue = Environment.get(key) else {
        return []
    }

    return Set(
        rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    )
}

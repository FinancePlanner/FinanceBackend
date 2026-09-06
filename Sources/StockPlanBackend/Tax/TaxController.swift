import Fluent
import Foundation
import StockPlanShared
import Vapor

struct TaxController: RouteCollection {
    private struct TaxQuery: Content {
        let jurisdiction: TaxJurisdiction?
        let taxYear: Int?
    }

    private struct MarketAdmissionRequest: Content {
        let status: TaxMarketAdmissionStatus
    }

    private struct FundAnnualInputQuery: Content {
        let accountId: UUID
        let instrumentId: UUID
        let calculationYear: Int
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let tax = protected.grouped("tax")
        let read = tax.grouped(ScopeRequirementMiddleware(.taxRead))
        let write = tax.grouped(ScopeRequirementMiddleware(.taxWrite))

        read.get("capabilities", use: capabilities)
        read.get("dashboard", use: dashboard)
        read.get("loss-carryforwards", use: lossCarryforwards)
        read.get("profile", use: getProfile)
        read.get("profile", "context", use: getProfileContext)
        read.get("funds", "annual-inputs", use: getFundAnnualInput)
        read.get("scenarios", ":scenarioId", use: getScenario)
        read.get("action-plans", use: listActionPlans)
        read.get("action-plans", ":actionPlanId", use: getActionPlan)
        read.get("notifications", use: getNotificationPreferences)
        read.get("filing", "preview", use: filingPreview)
        read.get("reports", use: listReports)
        read.get("reports", ":reportId", use: getReport)
        read.get("reports", ":reportId", "download", use: downloadReport)

        write.put("profile", use: saveProfile)
        write.put("instruments", ":instrumentId", "market-admission", use: saveMarketAdmission)
        write.put("instruments", ":instrumentId", "fund-classification", use: saveFundClassification)
        write.put("funds", "annual-inputs", use: saveFundAnnualInput)
        write.post("scenarios", use: createScenario)
        write.post("action-plans", use: createActionPlan)
        write.patch("action-plans", ":actionPlanId", use: transitionActionPlan)
        write.post("location-scenarios", use: createLocationScenario)
        write.post("placement-plans", use: createPlacementPlan)
        write.post("opportunities", ":opportunityId", "dismiss", use: dismissOpportunity)
        write.delete("opportunities", ":opportunityId", "dismiss", use: restoreOpportunity)
        write.put("notifications", use: saveNotificationPreferences)
        write.post("reports", use: createReport)
    }

    private func lossCarryforwards(req: Request) async throws -> TaxLossCarryforwardLedgerResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(TaxQuery.self)
        let jurisdiction = query.jurisdiction ?? .unitedStates
        let taxYear = query.taxYear ?? Calendar.current.component(.year, from: Date())
        switch jurisdiction {
        case .germany:
            return try await GermanyStockLossLedger().response(
                userId: session.userId,
                asOfTaxYear: taxYear,
                on: req.db
            )
        case .portugal, .spain, .unitedStates:
            // Shared carryforward table is used for PT Category G, ES estimates, and US
            // short/long carryovers when populated by the rule engines.
            return try await PortugalLossCarryforwardLedger().response(
                userId: session.userId,
                jurisdiction: jurisdiction,
                asOfTaxYear: taxYear,
                on: req.db
            )
        case .france, .italy:
            // FR/IT capital-gains rule packs are not production-ready; never return a
            // Portugal-shaped ledger that could be misread as filing-ready carryovers.
            return emptyLossCarryforwardLedger(jurisdiction: jurisdiction, asOfTaxYear: taxYear)
        }
    }

    private func emptyLossCarryforwardLedger(
        jurisdiction: TaxJurisdiction,
        asOfTaxYear: Int
    ) -> TaxLossCarryforwardLedgerResponse {
        let currency = jurisdiction == .unitedStates ? "USD" : "EUR"
        return TaxLossCarryforwardLedgerResponse(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            jurisdiction: jurisdiction,
            asOfTaxYear: asOfTaxYear,
            totalAvailable: TaxMoney(amount: 0, currency: currency),
            balances: []
        )
    }

    @Sendable
    private func capabilities(req: Request) throws -> TaxCapabilitiesResponse {
        _ = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(TaxQuery.self)
        return req.application.taxService.capabilities(taxYear: query.taxYear ?? currentTaxYear())
    }

    @Sendable
    private func getProfile(req: Request) async throws -> TaxProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(TaxQuery.self)
        let jurisdiction = query.jurisdiction ?? .unitedStates
        let taxYear = query.taxYear ?? currentTaxYear()
        guard let profile = try await req.application.taxService.profile(
            userId: session.userId,
            jurisdiction: jurisdiction,
            taxYear: taxYear,
            on: req.db
        ) else { throw Abort(.notFound, reason: "Tax profile not found.") }
        return profile
    }

    @Sendable
    private func getProfileContext(req: Request) async throws -> TaxProfileContextResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(TaxQuery.self)
        return try await req.application.taxService.profileContext(
            userId: session.userId,
            jurisdiction: query.jurisdiction ?? .unitedStates,
            taxYear: query.taxYear ?? currentTaxYear(),
            on: req.db
        )
    }

    @Sendable
    private func saveProfile(req: Request) async throws -> TaxProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let payload = try req.content.decode(TaxProfileRequest.self)
        guard (2020 ... currentTaxYear() + 1).contains(payload.taxYear) else {
            throw Abort(.unprocessableEntity, reason: "Tax year is outside the supported range.")
        }
        return try await req.application.taxService.saveProfile(userId: session.userId, request: payload, on: req.db)
    }

    @Sendable
    private func saveMarketAdmission(req: Request) async throws -> TaxInstrumentMarketOption {
        let session = try req.auth.require(SessionToken.self)
        guard let rawID = req.parameters.get("instrumentId"),
              let instrumentID = UUID(uuidString: rawID)
        else { throw Abort(.badRequest, reason: "Invalid instrument id.") }
        let payload = try req.content.decode(MarketAdmissionRequest.self)
        if payload.status != .unknown,
           req.headers.first(name: "X-Tax-Evidence-Attested")?.lowercased() != "true"
        {
            throw Abort(
                .unprocessableEntity,
                reason: "Verify market admission against a broker statement or official listing before classification."
            )
        }
        return try await req.application.taxService.saveMarketAdmission(
            userId: session.userId,
            instrumentId: instrumentID,
            status: payload.status,
            on: req.db
        )
    }

    @Sendable
    private func saveFundClassification(req: Request) async throws -> TaxInstrumentMarketOption {
        let session = try req.auth.require(SessionToken.self)
        guard let rawID = req.parameters.get("instrumentId"),
              let instrumentID = UUID(uuidString: rawID)
        else { throw Abort(.badRequest, reason: "Invalid instrument id.") }
        let payload = try req.content.decode(TaxFundClassificationRequest.self)
        return try await req.application.taxService.saveFundClassification(
            userId: session.userId,
            instrumentId: instrumentID,
            classification: payload.classification,
            on: req.db
        )
    }

    @Sendable
    private func saveFundAnnualInput(req: Request) async throws -> TaxFundAdvanceLumpSumResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let payload = try req.content.decode(TaxFundAnnualInputRequest.self)
        return try await GermanyFundAnnualInputService().save(
            userId: session.userId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    private func getFundAnnualInput(req: Request) async throws -> TaxFundAdvanceLumpSumResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(FundAnnualInputQuery.self)
        guard let response = try await GermanyFundAnnualInputService().get(
            userId: session.userId,
            accountId: query.accountId,
            instrumentId: query.instrumentId,
            calculationYear: query.calculationYear,
            on: req.db
        ) else { throw Abort(.notFound, reason: "Annual fund input not found.") }
        return response
    }

    @Sendable
    private func dashboard(req: Request) async throws -> TaxDashboardResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(TaxQuery.self)
        let jurisdiction = query.jurisdiction ?? .unitedStates
        let response = try await req.application.taxService.dashboard(
            userId: session.userId,
            jurisdiction: jurisdiction,
            taxYear: query.taxYear ?? currentTaxYear(),
            on: req.db
        )
        let entitlement = try await req.entitlementResolver.resolve(userId: session.userId, on: req.db)
        guard !entitlement.isPro else { return response }
        return TaxDashboardResponse(
            generatedAt: response.generatedAt,
            taxYear: response.taxYear,
            jurisdiction: response.jurisdiction,
            ruleVersion: response.ruleVersion,
            isStale: response.isStale,
            profileComplete: response.profileComplete,
            summary: response.summary,
            opportunities: [],
            unsupportedValue: response.unsupportedValue,
            assumptions: response.assumptions + ["Upgrade to Pro to review individual opportunities and run scenarios."],
            disclaimer: response.disclaimer,
            catalogVersion: response.catalogVersion,
            taxDrag: response.taxDrag,
            locationOpportunities: []
        )
    }

    @Sendable
    private func createScenario(req: Request) async throws -> TaxScenarioResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let query = try req.query.decode(TaxQuery.self)
        let payload = try req.content.decode(TaxScenarioRequest.self)
        return try await req.application.taxService.createScenario(
            userId: session.userId,
            request: payload,
            jurisdiction: query.jurisdiction ?? .unitedStates,
            on: req.db
        )
    }

    @Sendable
    private func getScenario(req: Request) async throws -> TaxScenarioResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        guard let rawID = req.parameters.get("scenarioId"),
              let id = UUID(uuidString: rawID),
              let response = try await req.application.taxService.scenario(userId: session.userId, id: id, on: req.db)
        else { throw Abort(.notFound, reason: "Tax scenario not found.") }
        return response
    }

    @Sendable
    private func createActionPlan(req: Request) async throws -> TaxActionPlanResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let payload = try req.content.decode(TaxActionPlanRequest.self)
        return try await req.application.taxService.createActionPlan(userId: session.userId, request: payload, on: req.db)
    }

    @Sendable
    private func listActionPlans(req: Request) async throws -> [TaxActionPlanResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        return try await req.application.taxService.actionPlans(userId: session.userId, on: req.db)
    }

    @Sendable
    private func getActionPlan(req: Request) async throws -> TaxActionPlanResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        guard let rawID = req.parameters.get("actionPlanId"),
              let id = UUID(uuidString: rawID),
              let response = try await req.application.taxService.actionPlan(
                  userId: session.userId,
                  id: id,
                  on: req.db
              )
        else { throw Abort(.notFound, reason: "Tax action plan not found.") }
        return response
    }

    @Sendable
    private func transitionActionPlan(req: Request) async throws -> TaxActionPlanResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        guard let rawID = req.parameters.get("actionPlanId"),
              let id = UUID(uuidString: rawID)
        else { throw Abort(.badRequest, reason: "Invalid tax action plan id.") }
        let payload = try req.content.decode(TaxActionPlanTransitionRequest.self)
        return try await req.application.taxService.transitionActionPlan(
            userId: session.userId,
            id: id,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    private func createLocationScenario(req: Request) async throws -> TaxLocationScenarioResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let query = try req.query.decode(TaxQuery.self)
        let payload = try req.content.decode(TaxLocationScenarioRequest.self)
        return try await req.application.taxService.createLocationScenario(
            userId: session.userId,
            request: payload,
            jurisdiction: query.jurisdiction ?? .unitedStates,
            on: req.db
        )
    }

    @Sendable
    private func createPlacementPlan(req: Request) async throws -> TaxActionPlanResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let payload = try req.content.decode(TaxPlacementPlanRequest.self)
        return try await req.application.taxService.createPlacementPlan(
            userId: session.userId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    private func dismissOpportunity(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        guard let opportunityID = req.parameters.get("opportunityId"), !opportunityID.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid tax opportunity id.")
        }
        let query = try req.query.decode(TaxQuery.self)
        try await req.application.taxService.dismissOpportunity(
            userId: session.userId,
            opportunityId: opportunityID,
            jurisdiction: query.jurisdiction ?? .unitedStates,
            taxYear: query.taxYear ?? currentTaxYear(),
            on: req.db
        )
        return .noContent
    }

    @Sendable
    private func restoreOpportunity(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        guard let opportunityID = req.parameters.get("opportunityId"), !opportunityID.isEmpty else {
            throw Abort(.badRequest, reason: "Invalid tax opportunity id.")
        }
        let query = try req.query.decode(TaxQuery.self)
        try await req.application.taxService.restoreOpportunity(
            userId: session.userId,
            opportunityId: opportunityID,
            taxYear: query.taxYear ?? currentTaxYear(),
            on: req.db
        )
        return .noContent
    }

    @Sendable
    private func getNotificationPreferences(req: Request) async throws -> TaxNotificationPreferences {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        return try await req.application.taxService.notificationPreferences(userId: session.userId, on: req.db)
    }

    @Sendable
    private func saveNotificationPreferences(req: Request) async throws -> TaxNotificationPreferences {
        let session = try req.auth.require(SessionToken.self)
        try await requireTaxPro(req, userId: session.userId)
        let payload = try req.content.decode(TaxNotificationPreferences.self)
        return try await req.application.taxService.saveNotificationPreferences(userId: session.userId, request: payload, on: req.db)
    }

    /// GET /v1/tax/filing/preview?taxYear= — the annual filing pack as JSON,
    /// same numbers the generated report will carry. Pro-gated like reports.
    @Sendable
    private func filingPreview(req: Request) async throws -> FilingPackPreviewResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let taxYear = req.query[Int.self, at: "taxYear"], taxYear >= 2000, taxYear <= 2100 else {
            throw Abort(.badRequest, reason: "taxYear is required.")
        }
        try await requireFilingPackAccess(req, userId: session.userId, taxYear: taxYear)
        return try await FilingPackService().preview(userId: session.userId, taxYear: taxYear, on: req)
    }

    private func createReport(req: Request) async throws -> TaxReportResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(TaxReportRequest.self)
        if payload.kind == .annualFilingPack {
            // The pack is what a per-year purchase buys, so it is exempt from
            // the monthly report quota; every other kind stays Pro-only.
            try await requireFilingPackAccess(req, userId: session.userId, taxYear: payload.taxYear)
        } else {
            try await requireTaxPro(req, userId: session.userId)
            try await req.usageCounterService.enforceResourceLimit(
                .reportGenerations,
                userId: session.userId,
                currentCount: TaxReport.query(on: req.db)
                    .filter(\.$userId == session.userId)
                    .filter(\.$status ~~ ["pending", "retry", "generating", "ready"])
                    .count(),
                adding: 1,
                on: req.db
            )
        }
        let model = TaxReport()
        model.userId = session.userId
        model.taxYear = payload.taxYear
        model.kind = payload.kind.rawValue
        model.format = payload.format.rawValue
        model.status = "pending"
        model.attemptCount = 0
        model.nextAttemptAt = Date()
        try await model.create(on: req.db)
        try await req.usageCounterService.incrementUsage(.reportGenerations, userId: session.userId, by: 1, on: req.db)
        return reportResponse(model)
    }

    @Sendable
    private func listReports(req: Request) async throws -> [TaxReportResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await TaxReport.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$createdAt, .descending)
            .all()
            .map(reportResponse)
    }

    @Sendable
    private func getReport(req: Request) async throws -> TaxReportResponse {
        let report = try await ownedReport(req, requiresPro: false)
        return reportResponse(report)
    }

    @Sendable
    private func downloadReport(req: Request) async throws -> Response {
        let report = try await ownedReport(req)
        guard report.status == "ready", let path = report.filePath else {
            throw Abort(.conflict, reason: "Tax report is not ready.")
        }
        if let expiresAt = report.expiresAt, expiresAt <= Date() {
            throw Abort(.gone, reason: "Tax report has expired.")
        }
        guard req.application.taxReportStorage.exists(at: path) else {
            req.logger.warning("tax_report.download_missing report_id=\(report.id?.uuidString ?? "unknown")")
            throw Abort(.gone, reason: "Tax report is no longer available.")
        }
        let response = req.fileio.streamFile(at: path)
        let format = TaxReportFormat(rawValue: report.format) ?? .csv
        response.headers.contentType = format == .pdf ? .pdf : .init(type: "text", subType: "csv", parameters: ["charset": "utf-8"])
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"norviq-tax-\(report.taxYear)-\(report.kind).\(format.rawValue)\""
        )
        return response
    }

    private func ownedReport(_ req: Request, requiresPro: Bool = true) async throws -> TaxReport {
        let session = try req.auth.require(SessionToken.self)
        guard let rawID = req.parameters.get("reportId"),
              let id = UUID(uuidString: rawID),
              let report = try await TaxReport.query(on: req.db)
              .filter(\.$id == id)
              .filter(\.$userId == session.userId)
              .first()
        else { throw Abort(.notFound, reason: "Tax report not found.") }
        if requiresPro {
            if report.kind == TaxReportKind.annualFilingPack.rawValue {
                try await requireFilingPackAccess(req, userId: session.userId, taxYear: report.taxYear)
            } else {
                try await requireTaxPro(req, userId: session.userId)
            }
        }
        return report
    }

    private func requireTaxPro(_ req: Request, userId: UUID) async throws {
        try await req.usageCounterService.requirePremium(.taxOptimization, userId: userId, on: req.db)
    }

    /// Pro, or a purchased pack for exactly this tax year. The upgrade error
    /// is rethrown untouched so clients keep seeing the same 402/403 paywall.
    private func requireFilingPackAccess(_ req: Request, userId: UUID, taxYear: Int) async throws {
        do {
            try await requireTaxPro(req, userId: userId)
        } catch let upgrade as BillingUpgradeRequiredError {
            guard try await TaxPackEntitlementService().hasEntitlement(userId: userId, taxYear: taxYear, on: req.db) else {
                throw upgrade
            }
        }
    }
}

private func reportResponse(_ model: TaxReport) -> TaxReportResponse {
    TaxReportResponse(
        id: model.id!.uuidString,
        taxYear: model.taxYear,
        kind: TaxReportKind(rawValue: model.kind) ?? .transactionWorkpaper,
        format: TaxReportFormat(rawValue: model.format) ?? .csv,
        status: model.status,
        createdAt: taxISODate(model.createdAt ?? Date()),
        expiresAt: model.expiresAt.map(taxISODate),
        downloadPath: model.status == "ready" ? "/v1/tax/reports/\(model.id!.uuidString)/download" : nil
    )
}

private func currentTaxYear() -> Int {
    Calendar(identifier: .gregorian).component(.year, from: Date())
}

private func taxISODate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

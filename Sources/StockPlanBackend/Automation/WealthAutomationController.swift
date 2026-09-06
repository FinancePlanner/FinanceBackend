import Fluent
import Foundation
import StockPlanShared
import Vapor

struct WealthAutomationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let planningRead = protected.grouped(ScopeRequirementMiddleware(.planningRead))
        let planningWrite = protected.grouped(ScopeRequirementMiddleware(.planningWrite))

        planningRead.group("net-worth-forecasts") { forecasts in
            forecasts.get(use: listForecasts)
            forecasts.get("defaults", use: forecastDefaults)
            forecasts.group(":forecastID") { forecast in
                forecast.get(use: getForecast)
                forecast.get("runs", "latest", use: latestForecastRun)
            }
        }
        planningWrite.group("net-worth-forecasts") { forecasts in
            forecasts.post(use: createForecast)
            forecasts.group(":forecastID") { forecast in
                forecast.put(use: updateForecast)
                forecast.delete(use: deleteForecast)
                forecast.post("runs", use: runForecast)
            }
        }

        // Smart screens read and write watchlists, so they are gated on the
        // watchlist domain rather than planning.
        let screensRead = protected.grouped(ScopeRequirementMiddleware(.watchlistRead))
        let screensWrite = protected.grouped(ScopeRequirementMiddleware(.watchlistWrite))
        screensRead.group("watchlist", "screens") { screens in
            screens.get("catalog", use: screenCatalog)
            screens.get(use: listScreens)
            screens.group(":screenID") { screen in
                screen.get(use: getScreen)
                screen.get("history", use: screenHistory)
            }
        }
        screensWrite.group("watchlist", "screens") { screens in
            screens.post(use: createScreen)
            screens.group(":screenID") { screen in
                screen.put(use: updateScreen)
                screen.delete(use: deleteScreen)
                screen.post("evaluate", use: evaluateScreen)
            }
        }

        planningRead.group("portfolio", "lists", ":portfolioListId", "rebalancing-policy") { policy in
            policy.get(use: getRebalancingPolicy)
            policy.get("events", use: rebalanceEvents)
        }
        planningWrite.group("portfolio", "lists", ":portfolioListId", "rebalancing-policy") { policy in
            policy.put(use: upsertRebalancingPolicy)
            policy.delete(use: deleteRebalancingPolicy)
            policy.post("preview", use: previewRebalancingPolicy)
            policy.post("events", ":eventID", "confirm", use: confirmRebalanceEvent)
            policy.post("events", ":eventID", "dismiss", use: dismissRebalanceEvent)
        }

        protected.grouped(ScopeRequirementMiddleware(.notificationsRead))
            .get("notifications", "inbox", use: notificationInbox)
        protected.grouped(ScopeRequirementMiddleware(.notificationsWrite))
            .group("notifications", "inbox") { inbox in
                inbox.post("read-all", use: readAllNotifications)
                inbox.put(":eventID", "read", use: updateNotificationReadState)
            }
    }

    // MARK: Forecasts

    @Sendable
    private func listForecasts(req: Request) async throws -> [NetWorthForecastDefinition] {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        return try await NetWorthForecastModel.owned(by: userId, on: req.db)
            .sort(\.$createdAt, .descending).all().map(forecastResponse)
    }

    @Sendable
    private func createForecast(req: Request) async throws -> NetWorthForecastDefinition {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        guard let portfolioListId = req.query[UUID.self, at: "portfolio_list_id"] else {
            throw Abort(.badRequest, reason: "portfolio_list_id is required.")
        }
        try await requirePortfolio(portfolioListId, userId: userId, on: req.db)
        guard try await NetWorthForecastModel.owned(by: userId, on: req.db)
            .filter(\.$portfolioListId == portfolioListId).first() == nil
        else {
            throw Abort(.conflict, reason: "This portfolio already has a forecast.")
        }
        let input = try req.content.decode(NetWorthForecastUpsertRequest.self)
        try validateForecast(input, portfolioListId: portfolioListId)
        let model = NetWorthForecastModel(userId: userId, portfolioListId: portfolioListId, input: input)
        try await model.create(on: req.db)
        return forecastResponse(model)
    }

    @Sendable
    private func getForecast(req: Request) async throws -> NetWorthForecastDefinition {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        return try await forecastResponse(ownedForecast(req, userId: userId))
    }

    @Sendable
    private func updateForecast(req: Request) async throws -> NetWorthForecastDefinition {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        let model = try await ownedForecast(req, userId: userId)
        let input = try req.content.decode(NetWorthForecastUpsertRequest.self)
        try validateForecast(input, portfolioListId: model.portfolioListId)
        model.apply(input)
        try await model.update(on: req.db)
        return forecastResponse(model)
    }

    @Sendable
    private func deleteForecast(req: Request) async throws -> HTTPStatus {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        try await ownedForecast(req, userId: userId).delete(on: req.db)
        return .noContent
    }

    @Sendable
    private func forecastDefaults(req: Request) async throws -> NetWorthForecastDefaults {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        let currency = (req.query[String.self, at: "currency"] ?? "EUR").uppercased()
        return try await cashFlowDefaults(userId: userId, currency: currency, on: req.db)
    }

    @Sendable
    private func runForecast(req: Request) async throws -> NetWorthForecastRun {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        let forecast = try await ownedForecast(req, userId: userId)
        let forecastId = try forecast.requireID()
        let defaults = try await cashFlowDefaults(userId: userId, currency: forecast.baseCurrency, on: req.db)
        let assumptions = NetWorthForecastDefaults(
            baseCurrency: forecast.baseCurrency,
            monthlyIncome: forecast.monthlyIncomeOverride ?? defaults.monthlyIncome,
            monthlySpending: forecast.monthlySpendingOverride ?? defaults.monthlySpending,
            cashFlowSource: forecast.monthlyIncomeOverride != nil || forecast.monthlySpendingOverride != nil ? .manual : defaults.cashFlowSource,
            includedFinancing: defaults.includedFinancing,
            warnings: defaults.warnings
        )
        let startingValue = try await forecastStartingValue(forecast: forecast, userId: userId, req: req)
        let seed = req.query[UInt64.self, at: "seed"] ?? UInt64.random(in: .min ... .max)
        let spec = NetFlowSimulationSpec(
            initialValue: startingValue,
            monthlyIncome: assumptions.monthlyIncome,
            monthlySpending: assumptions.monthlySpending,
            annualIncomeGrowth: forecast.annualIncomeGrowth,
            annualSpendingGrowth: forecast.annualSpendingGrowth,
            annualReturn: 0.07,
            annualVolatility: 0.16,
            annualInflation: forecast.inflationAssumption,
            horizonMonths: forecast.horizonMonths,
            pathCount: forecast.pathCount,
            seed: seed,
            targetAmount: forecast.targetAmount
        )
        let simulation = await Task.detached(priority: .userInitiated) { ScenarioEngine().simulateNetFlow(spec) }.value
        let now = Date()
        let timeline = simulation.bands.map { band in
            NetWorthForecastPoint(
                id: String(band.month),
                month: band.month,
                date: forecastMonth(band.month, from: now),
                monthlyIncome: assumptions.monthlyIncome * pow(1 + forecast.annualIncomeGrowth, Double(max(0, band.month - 1)) / 12),
                monthlySpending: assumptions.monthlySpending * pow(1 + forecast.annualSpendingGrowth, Double(max(0, band.month - 1)) / 12),
                bands: [
                    .init(percentile: 10, value: band.p10), .init(percentile: 25, value: band.p25),
                    .init(percentile: 50, value: band.p50), .init(percentile: 75, value: band.p75),
                    .init(percentile: 90, value: band.p90),
                ]
            )
        }
        let run = NetWorthForecastRunModel()
        run.userId = userId
        run.$forecast.id = forecastId
        run.status = NetWorthForecastRunStatus.completed.rawValue
        run.startingValue = startingValue
        run.assumptions = try WealthAutomationCoding.json(assumptions)
        run.timeline = try WealthAutomationCoding.json(["timeline": timeline])
        run.targetProbability = simulation.goalProbability
        run.seed = String(seed)
        run.completedAt = Date()
        try await run.create(on: req.db)
        return try forecastRunResponse(run)
    }

    @Sendable
    private func latestForecastRun(req: Request) async throws -> NetWorthForecastRun {
        let userId = try await authorize(req, feature: .netWorthForecasting)
        let forecast = try await ownedForecast(req, userId: userId)
        guard let forecastId = forecast.id,
              let run = try await NetWorthForecastRunModel.query(on: req.db)
              .filter(\.$userId == userId).filter(\.$forecast.$id == forecastId)
              .sort(\.$createdAt, .descending).first() else { throw Abort(.notFound) }
        return try forecastRunResponse(run)
    }

    // MARK: Screens

    @Sendable
    private func screenCatalog(req: Request) async throws -> [ScreenMetricDescriptor] {
        _ = try await authorize(req, feature: .smartScreening)
        return WatchlistScreenEvaluator.catalog
    }

    @Sendable
    private func listScreens(req: Request) async throws -> [WatchlistScreen] {
        let userId = try await authorize(req, feature: .smartScreening)
        return try await WatchlistScreenModel.owned(by: userId, on: req.db)
            .sort(\.$createdAt, .descending).all().map(screenResponse)
    }

    @Sendable
    private func createScreen(req: Request) async throws -> WatchlistScreen {
        let userId = try await authorize(req, feature: .smartScreening)
        let input = try req.content.decode(WatchlistScreenUpsertRequest.self)
        try await validateScreen(input, userId: userId, on: req.db)
        let model = WatchlistScreenModel()
        try apply(input, to: model, userId: userId)
        try await model.create(on: req.db)
        return try screenResponse(model)
    }

    @Sendable
    private func getScreen(req: Request) async throws -> WatchlistScreen {
        let userId = try await authorize(req, feature: .smartScreening)
        return try await screenResponse(ownedScreen(req, userId: userId))
    }

    @Sendable
    private func updateScreen(req: Request) async throws -> WatchlistScreen {
        let userId = try await authorize(req, feature: .smartScreening)
        let model = try await ownedScreen(req, userId: userId)
        let input = try req.content.decode(WatchlistScreenUpsertRequest.self)
        try await validateScreen(input, userId: userId, on: req.db)
        try apply(input, to: model, userId: userId)
        model.lastEvaluatedAt = nil
        try await WatchlistScreenEvaluationModel.query(on: req.db).filter(\.$screen.$id == model.requireID()).delete()
        try await model.update(on: req.db)
        return try screenResponse(model)
    }

    @Sendable
    private func deleteScreen(req: Request) async throws -> HTTPStatus {
        let userId = try await authorize(req, feature: .smartScreening)
        try await ownedScreen(req, userId: userId).delete(on: req.db)
        return .noContent
    }

    @Sendable
    private func evaluateScreen(req: Request) async throws -> WatchlistScreenEvaluation {
        let userId = try await authorize(req, feature: .smartScreening)
        let screen = try await ownedScreen(req, userId: userId)
        return try await evaluate(screen: screen, userId: userId, sendsAlerts: false, req: req)
    }

    @Sendable
    private func screenHistory(req: Request) async throws -> [WatchlistScreenEvaluation] {
        let userId = try await authorize(req, feature: .smartScreening)
        let screen = try await ownedScreen(req, userId: userId)
        let values = try await WatchlistScreenEvaluationModel.query(on: req.db)
            .filter(\.$userId == userId).filter(\.$screen.$id == screen.requireID())
            .sort(\.$evaluatedAt, .descending).limit(30).all()
        return try values.map(screenEvaluationResponse)
    }

    // MARK: Rebalancing

    @Sendable
    private func getRebalancingPolicy(req: Request) async throws -> RebalancingPolicy {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        guard let model = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
            .filter(\.$portfolioListId == portfolioListId).first() else { throw Abort(.notFound) }
        return try rebalancingPolicyResponse(model)
    }

    @Sendable
    private func upsertRebalancingPolicy(req: Request) async throws -> RebalancingPolicy {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        let input = try req.content.decode(RebalancingPolicyUpsertRequest.self)
        let validation = RebalancingPolicy(
            id: "validation", portfolioListId: portfolioListId.uuidString,
            baseCurrency: input.baseCurrency,
            cadence: input.cadence, driftThreshold: input.driftThreshold, targets: input.targets, enabled: input.enabled
        )
        do { try validation.validate() } catch { throw Abort(.badRequest, reason: "Invalid rebalancing policy: \(error)") }
        let model = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
            .filter(\.$portfolioListId == portfolioListId).first() ?? RebalancingPolicyModel()
        model.userId = userId
        model.portfolioListId = portfolioListId
        model.baseCurrency = input.baseCurrency.uppercased()
        model.cadence = input.cadence.rawValue
        model.driftThreshold = input.driftThreshold
        model.targets = try WealthAutomationCoding.json(["targets": input.targets])
        model.enabled = input.enabled
        try await model.save(on: req.db)
        return try rebalancingPolicyResponse(model)
    }

    @Sendable
    private func deleteRebalancingPolicy(req: Request) async throws -> HTTPStatus {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        guard let model = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
            .filter(\.$portfolioListId == portfolioListId).first() else { throw Abort(.notFound) }
        try await model.delete(on: req.db)
        return .noContent
    }

    @Sendable
    private func previewRebalancingPolicy(req: Request) async throws -> RebalancePreview {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        guard let model = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
            .filter(\.$portfolioListId == portfolioListId).first() else { throw Abort(.notFound) }
        return try await makeRebalancePreview(model: model, userId: userId, req: req)
    }

    @Sendable
    private func rebalanceEvents(req: Request) async throws -> [RebalanceEvent] {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        guard let policy = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
            .filter(\.$portfolioListId == portfolioListId).first() else { return [] }
        return try await RebalanceEventModel.query(on: req.db)
            .filter(\.$userId == userId).filter(\.$policy.$id == policy.requireID())
            .sort(\.$createdAt, .descending).all().map(rebalanceEventResponse)
    }

    @Sendable
    private func confirmRebalanceEvent(req: Request) async throws -> RebalanceEvent {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        guard let eventId = req.parameters.get("eventID", as: UUID.self),
              let policy = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
              .filter(\.$portfolioListId == portfolioListId).first(),
              let event = try await RebalanceEventModel.query(on: req.db)
              .filter(\.$id == eventId).filter(\.$userId == userId)
              .filter(\.$policy.$id == policy.requireID()).first() else { throw Abort(.notFound) }
        guard event.status == RebalanceEventStatus.pending.rawValue else { throw Abort(.conflict) }
        let now = Date()
        event.status = RebalanceEventStatus.confirmed.rawValue
        event.confirmedAt = now
        policy.lastConfirmedAt = now
        try await req.db.transaction { db in
            try await event.update(on: db)
            try await policy.update(on: db)
        }
        return try rebalanceEventResponse(event)
    }

    @Sendable
    private func dismissRebalanceEvent(req: Request) async throws -> RebalanceEvent {
        let (userId, portfolioListId) = try await rebalanceContext(req)
        guard let eventId = req.parameters.get("eventID", as: UUID.self),
              let policy = try await RebalancingPolicyModel.owned(by: userId, on: req.db)
              .filter(\.$portfolioListId == portfolioListId).first(),
              let event = try await RebalanceEventModel.query(on: req.db)
              .filter(\.$id == eventId).filter(\.$userId == userId)
              .filter(\.$policy.$id == policy.requireID()).first() else { throw Abort(.notFound) }
        guard event.status == RebalanceEventStatus.pending.rawValue else { throw Abort(.conflict) }
        event.status = RebalanceEventStatus.dismissed.rawValue
        event.dismissedAt = Date()
        try await event.update(on: req.db)
        return try rebalanceEventResponse(event)
    }

    // MARK: Inbox

    @Sendable
    private func notificationInbox(req: Request) async throws -> NotificationInboxPage {
        let session = try req.auth.require(SessionToken.self)
        let unreadOnly = req.query[Bool.self, at: "unread"] ?? false
        let kind = req.query[String.self, at: "kind"]
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 100)
        var query = NotificationEventModel.query(on: req.db).filter(\.$userId == session.userId)
        if unreadOnly {
            query = query.filter(\.$readAt == nil)
        }
        if let kind {
            guard NotificationEventKind(rawValue: kind) != nil else {
                throw Abort(.badRequest, reason: "Invalid notification kind.")
            }
            query = query.filter(\.$kind == kind)
        }
        let rawCursor = req.query[String.self, at: "cursor"]
        if rawCursor != nil {
            guard let cursor = NotificationListCursor.parse(rawCursor) else {
                throw Abort(.badRequest, reason: "Invalid notification cursor.")
            }
            if let cursorId = cursor.id {
                query.group(.or) { group in
                    group.filter(\.$createdAt < cursor.createdAt)
                    group.group(.and) { tie in
                        tie.filter(\.$createdAt == cursor.createdAt)
                        tie.filter(\.$id < cursorId)
                    }
                }
            } else {
                query.filter(\.$createdAt < cursor.createdAt)
            }
        }
        let page = try await query.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit + 1).all()
        let hasMore = page.count > limit
        let events = Array(page.prefix(limit))
        let nextCursor: String? = hasMore ? events.last.flatMap { event in
            guard let createdAt = event.createdAt, let id = event.id else { return nil }
            return NotificationListCursor.encode(createdAt: createdAt, id: id)
        } : nil
        let unreadCount = try await NotificationEventModel.query(on: req.db)
            .filter(\.$userId == session.userId).filter(\.$readAt == nil).count()
        return NotificationInboxPage(
            items: events.compactMap(notificationResponse),
            unreadCount: unreadCount,
            nextCursor: nextCursor
        )
    }

    @Sendable
    private func updateNotificationReadState(req: Request) async throws -> NotificationInboxItem {
        let session = try req.auth.require(SessionToken.self)
        guard let eventId = req.parameters.get("eventID", as: UUID.self),
              let event = try await NotificationEventModel.query(on: req.db)
              .filter(\.$id == eventId).filter(\.$userId == session.userId).first() else { throw Abort(.notFound) }
        let input = try req.content.decode(NotificationReadRequest.self)
        event.readAt = input.read ? Date() : nil
        try await event.update(on: req.db)
        guard let response = notificationResponse(event) else { throw Abort(.internalServerError) }
        return response
    }

    @Sendable
    private func readAllNotifications(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let events = try await NotificationEventModel.query(on: req.db)
            .filter(\.$userId == session.userId).filter(\.$readAt == nil).all()
        let now = Date()
        try await req.db.transaction { db in
            for event in events {
                event.readAt = now; try await event.update(on: db)
            }
        }
        return .noContent
    }

    // MARK: Helpers

    private func authorize(_ req: Request, feature: BillingFeature) async throws -> UUID {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(feature, userId: session.userId, on: req.db)
        return session.userId
    }

    private func requirePortfolio(_ id: UUID, userId: UUID, on db: any Database) async throws {
        guard try await PortfolioList.query(on: db).filter(\.$id == id).filter(\.$userId == userId).first() != nil else {
            throw Abort(.notFound, reason: "Portfolio not found.")
        }
    }

    private func ownedForecast(_ req: Request, userId: UUID) async throws -> NetWorthForecastModel {
        guard let id = req.parameters.get("forecastID", as: UUID.self),
              let model = try await NetWorthForecastModel.owned(by: userId, on: req.db)
              .filter(\.$id == id).first() else { throw Abort(.notFound) }
        return model
    }

    private func forecastResponse(_ model: NetWorthForecastModel) -> NetWorthForecastDefinition {
        .init(
            id: model.id?.uuidString ?? "",
            portfolioListId: model.portfolioListId.uuidString,
            name: model.name,
            baseCurrency: model.baseCurrency,
            horizonMonths: model.horizonMonths,
            includeCash: model.includeCash,
            includeCrypto: model.includeCrypto,
            annualIncomeGrowth: model.annualIncomeGrowth,
            annualSpendingGrowth: model.annualSpendingGrowth,
            inflationAssumption: model.inflationAssumption,
            monthlyIncomeOverride: model.monthlyIncomeOverride,
            monthlySpendingOverride: model.monthlySpendingOverride,
            targetAmount: model.targetAmount,
            pathCount: model.pathCount,
            createdAt: WealthAutomationCoding.timestamp(model.createdAt),
            updatedAt: WealthAutomationCoding.timestamp(model.updatedAt)
        )
    }

    private func validateForecast(_ input: NetWorthForecastUpsertRequest, portfolioListId: UUID) throws {
        let value = NetWorthForecastDefinition(
            id: "validation", portfolioListId: portfolioListId.uuidString,
            name: input.name, baseCurrency: input.baseCurrency, horizonMonths: input.horizonMonths,
            includeCash: input.includeCash, includeCrypto: input.includeCrypto,
            annualIncomeGrowth: input.annualIncomeGrowth, annualSpendingGrowth: input.annualSpendingGrowth,
            inflationAssumption: input.inflationAssumption, monthlyIncomeOverride: input.monthlyIncomeOverride,
            monthlySpendingOverride: input.monthlySpendingOverride, targetAmount: input.targetAmount,
            pathCount: input.pathCount
        )
        do { try value.validate() } catch { throw Abort(.badRequest, reason: "Invalid forecast: \(error)") }
    }

    private func cashFlowDefaults(userId: UUID, currency: String, on db: any Database) async throws -> NetWorthForecastDefaults {
        let financing = try await FinancingService().forecastBudgetContext(userId: userId, on: db)
        if financing.netMonthlyIncome != nil || financing.baselineSpending > 0 {
            return .init(
                baseCurrency: currency,
                monthlyIncome: financing.netMonthlyIncome ?? 0,
                monthlySpending: financing.baselineSpending + financing.existingFinancingPayments,
                cashFlowSource: .plannedBudget,
                includedFinancing: financing.existingFinancingPayments,
                warnings: financing.netMonthlyIncome == nil ? ["No planned net income is available."] : []
            )
        }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .month, value: -3, to: Date()) ?? Date.distantPast
        let expenses = try await Expense.query(on: db)
            .filter(\.$user.$id == userId).filter(\.$occurredOn >= start).all()
        let spending = expenses.reduce(0) { $0 + $1.amount * $1.userSharePercent / 100 } / 3
        return .init(
            baseCurrency: currency,
            monthlyIncome: 0,
            monthlySpending: spending,
            cashFlowSource: .trailingActuals,
            warnings: ["No planned budget was found; spending uses the trailing three-month average."]
        )
    }

    private func forecastStartingValue(
        forecast: NetWorthForecastModel,
        userId: UUID,
        req: Request
    ) async throws -> Double {
        let cryptoIds = forecast.includeCrypto ? try await CryptoPortfolioItem.query(on: req.db)
            .filter(\.$userId == userId).all().compactMap(\.id) : []
        let snapshot = try await ScenarioSnapshotCaptureService().capture(
            portfolioListId: forecast.portfolioListId,
            userId: userId,
            baseCurrency: forecast.baseCurrency,
            cryptoHoldingIds: cryptoIds,
            req: req
        )
        let holdings = snapshot.payload.values["holdings"]?.array ?? []
        return holdings.compactMap(\.object).reduce(0) { total, item in
            let category = item["asset_category"]?.string
            if category == "cash", !forecast.includeCash {
                return total
            }
            if category == "crypto", !forecast.includeCrypto {
                return total
            }
            return total + (item["value_in_base_currency"]?.number ?? 0)
        }
    }

    private func forecastRunResponse(_ model: NetWorthForecastRunModel) throws -> NetWorthForecastRun {
        let assumptions = try WealthAutomationCoding.decode(NetWorthForecastDefaults.self, from: model.assumptions)
        let envelope = try WealthAutomationCoding.decode(ForecastTimelineEnvelope.self, from: model.timeline)
        return .init(
            id: model.id?.uuidString ?? "",
            forecastId: model.$forecast.id.uuidString,
            status: NetWorthForecastRunStatus(rawValue: model.status) ?? .failed,
            startingValue: model.startingValue,
            assumptions: assumptions,
            timeline: envelope.timeline,
            targetProbability: model.targetProbability,
            seed: UInt64(model.seed),
            failureReason: model.failureReason,
            createdAt: WealthAutomationCoding.timestamp(model.createdAt) ?? "",
            completedAt: WealthAutomationCoding.timestamp(model.completedAt)
        )
    }

    private func forecastMonth(_ month: Int, from date: Date) -> String {
        let value = Calendar(identifier: .gregorian).date(byAdding: .month, value: month, to: date) ?? date
        return ISO8601DateFormatter().string(from: value)
    }

    private func ownedScreen(_ req: Request, userId: UUID) async throws -> WatchlistScreenModel {
        guard let id = req.parameters.get("screenID", as: UUID.self),
              let model = try await WatchlistScreenModel.owned(by: userId, on: req.db)
              .filter(\.$id == id).first() else { throw Abort(.notFound) }
        return model
    }

    private func validateScreen(_ input: WatchlistScreenUpsertRequest, userId: UUID, on db: any Database) async throws {
        let validation = WatchlistScreen(
            id: "validation", name: input.name,
            watchlistListIds: input.watchlistListIds, logicalOperator: input.logicalOperator,
            groups: input.groups, alertsEnabled: input.alertsEnabled
        )
        do { try validation.validate() } catch { throw Abort(.badRequest, reason: "Invalid screen: \(error)") }
        let listIds = input.watchlistListIds.compactMap(UUID.init(uuidString:))
        guard listIds.count == Set(input.watchlistListIds).count else { throw Abort(.badRequest, reason: "Invalid watchlist id.") }
        let ownedCount = try await WatchlistList.query(on: db)
            .filter(\.$userId == userId).filter(\.$id ~~ listIds).count()
        guard ownedCount == listIds.count else { throw Abort(.notFound, reason: "Watchlist not found.") }
        let catalog = Dictionary(uniqueKeysWithValues: WatchlistScreenEvaluator.catalog.map { ($0.id, $0) })
        for condition in input.groups.flatMap(\.conditions) {
            guard let descriptor = catalog[condition.metric],
                  descriptor.supportedPeriods.contains(condition.period),
                  descriptor.supportedComparisons.contains(condition.comparison),
                  !(condition.period == .ttm && [.improving, .deteriorating].contains(condition.comparison))
            else {
                throw Abort(.badRequest, reason: "Unsupported metric, period, or comparison.")
            }
        }
    }

    private func apply(_ input: WatchlistScreenUpsertRequest, to model: WatchlistScreenModel, userId: UUID) throws {
        model.userId = userId
        model.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.watchlistListIds = input.watchlistListIds.compactMap(UUID.init(uuidString:))
        model.logicalOperator = input.logicalOperator.rawValue
        model.groups = try WealthAutomationCoding.json(ScreenGroupsEnvelope(groups: input.groups))
        model.alertsEnabled = input.alertsEnabled
    }

    private func screenResponse(_ model: WatchlistScreenModel) throws -> WatchlistScreen {
        let envelope = try WealthAutomationCoding.decode(ScreenGroupsEnvelope.self, from: model.groups)
        return .init(
            id: model.id?.uuidString ?? "", name: model.name,
            watchlistListIds: model.watchlistListIds.map(\.uuidString),
            logicalOperator: ScreenLogicalOperator(rawValue: model.logicalOperator) ?? .all,
            groups: envelope.groups, alertsEnabled: model.alertsEnabled,
            lastEvaluatedAt: WealthAutomationCoding.timestamp(model.lastEvaluatedAt),
            createdAt: WealthAutomationCoding.timestamp(model.createdAt),
            updatedAt: WealthAutomationCoding.timestamp(model.updatedAt)
        )
    }

    func evaluate(
        screen: WatchlistScreenModel,
        userId: UUID,
        sendsAlerts: Bool,
        req: Request
    ) async throws -> WatchlistScreenEvaluation {
        let definition = try screenResponse(screen)
        let items = try await WatchlistItem.query(on: req.db)
            .filter(\.$userId == userId).filter(\.$watchlistListId ~~ screen.watchlistListIds).all()
        let symbols = Array(Set(items.map { $0.symbol.uppercased() })).sorted()
        let previous = try await WatchlistScreenEvaluationModel.query(on: req.db)
            .filter(\.$userId == userId).filter(\.$screen.$id == screen.requireID())
            .sort(\.$evaluatedAt, .descending).first()
        let previousMatches = Set(previous?.matchSymbols ?? [])
        let descriptors = Dictionary(uniqueKeysWithValues: WatchlistScreenEvaluator.catalog.map { ($0.id, $0) })
        let evaluator = WatchlistScreenEvaluator()
        var matches: [WatchlistScreenMatch] = []
        for symbol in symbols {
            var groupMatches: [Bool] = []
            var results: [ScreenConditionResult] = []
            for group in definition.groups {
                var conditionMatches: [Bool] = []
                for condition in group.conditions {
                    guard let descriptor = descriptors[condition.metric] else { continue }
                    let observation = await metricObservation(symbol: symbol, condition: condition, req: req)
                    let result = evaluator.evaluate(condition: condition, observation: observation, descriptor: descriptor)
                    results.append(result)
                    conditionMatches.append(result.matched)
                }
                groupMatches.append(evaluator.combines(conditionMatches, using: group.logicalOperator))
            }
            if evaluator.combines(groupMatches, using: definition.logicalOperator) {
                let profile = try? await req.application.marketDataService.profile(symbol: symbol, on: req)
                matches.append(.init(
                    id: symbol, symbol: symbol, name: profile?.name,
                    isNew: previous != nil && !previousMatches.contains(symbol), conditionResults: results
                ))
            }
        }
        let now = Date()
        let model = WatchlistScreenEvaluationModel()
        model.id = UUID()
        model.userId = userId
        model.$screen.id = try screen.requireID()
        model.symbolCount = symbols.count
        model.matchSymbols = matches.map(\.symbol)
        model.isAlertBaseline = previous == nil
        let response = WatchlistScreenEvaluation(
            id: model.id!.uuidString, screenId: model.$screen.id.uuidString,
            evaluatedAt: ISO8601DateFormatter().string(from: now), symbolCount: symbols.count,
            matches: matches, isAlertBaseline: previous == nil
        )
        model.result = try WealthAutomationCoding.json(ScreenResultsEnvelope(matches: matches))
        try await model.create(on: req.db)
        screen.lastEvaluatedAt = now
        try await screen.update(on: req.db)
        if sendsAlerts, previous != nil {
            let newSymbols = matches.filter(\.isNew).map(\.symbol)
            if !newSymbols.isEmpty {
                try await persistNotification(
                    userId: userId, kind: .watchlistScreen,
                    deduplicationKey: "screen:\(screen.requireID()):\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)",
                    title: "New smart-screen matches",
                    body: "\(newSymbols.joined(separator: ", ")) entered \(screen.name).",
                    deepLink: "financeplan://automation/screens/\(screen.requireID())",
                    payload: ["screen_id": screen.requireID().uuidString],
                    req: req
                )
            }
        }
        return response
    }

    private func metricObservation(
        symbol: String,
        condition: WatchlistScreenCondition,
        req: Request
    ) async -> ScreenMetricObservation {
        if condition.metric == "price" {
            return await .init(current: try? req.application.marketDataService.quote(symbol: symbol, on: req).currentPrice, previous: nil)
        }
        if condition.metric == "market_cap" {
            return await .init(current: try? req.application.marketDataService.profile(symbol: symbol, on: req).marketCapitalization, previous: nil)
        }
        if condition.period == .ttm {
            guard let value = try? await req.application.marketDataService.ratiosTTM(symbol: symbol, on: req).first else {
                return .init(current: nil, previous: nil)
            }
            return .init(current: ttmValue(condition.metric, value), previous: nil)
        }
        let period = condition.period == .quarterly ? "quarter" : "annual"
        if condition.metric == "revenue_growth" || condition.metric == "eps_growth" {
            let values = await (try? req.application.marketDataService.financialGrowth(
                symbol: symbol, limit: 2, period: period, on: req
            )) ?? []
            return .init(
                current: values.first.flatMap { growthValue(condition.metric, $0) },
                previous: values.dropFirst().first.flatMap { growthValue(condition.metric, $0) }
            )
        }
        let values = await (try? req.application.marketDataService.ratios(
            symbol: symbol, limit: 2, period: period, on: req
        )) ?? []
        return .init(
            current: values.first.flatMap { ratioValue(condition.metric, $0) },
            previous: values.dropFirst().first.flatMap { ratioValue(condition.metric, $0) }
        )
    }

    private func ttmValue(_ metric: String, _ value: RatiosTTMResponse) -> Double? {
        switch metric {
        case "pe_ratio": value.priceToEarningsRatioTTM
        case "price_to_sales": value.priceToSalesRatioTTM
        case "net_profit_margin": value.netProfitMarginTTM
        case "debt_to_equity": value.debtToEquityRatioTTM
        case "current_ratio": value.currentRatioTTM
        case "free_cash_flow": value.freeCashFlowPerShareTTM
        case "dividend_yield": value.dividendYieldTTM
        default: nil
        }
    }

    private func ratioValue(_ metric: String, _ value: RatiosResponse) -> Double? {
        switch metric {
        case "pe_ratio": value.priceToEarningsRatio
        case "price_to_sales": value.priceToSalesRatio
        case "net_profit_margin": value.netProfitMargin
        case "debt_to_equity": value.debtToEquityRatio
        case "current_ratio": value.currentRatio
        case "free_cash_flow": value.freeCashFlowPerShare
        case "dividend_yield": value.dividendYield
        default: nil
        }
    }

    private func growthValue(_ metric: String, _ value: FinancialGrowthResponse) -> Double? {
        switch metric {
        case "revenue_growth": value.revenueGrowth
        case "eps_growth": value.epsgrowth
        default: nil
        }
    }

    private func screenEvaluationResponse(_ model: WatchlistScreenEvaluationModel) throws -> WatchlistScreenEvaluation {
        let envelope = try WealthAutomationCoding.decode(ScreenResultsEnvelope.self, from: model.result)
        return .init(
            id: model.id?.uuidString ?? "", screenId: model.$screen.id.uuidString,
            evaluatedAt: WealthAutomationCoding.timestamp(model.evaluatedAt) ?? "",
            symbolCount: model.symbolCount, matches: envelope.matches, isAlertBaseline: model.isAlertBaseline
        )
    }

    private func rebalanceContext(_ req: Request) async throws -> (UUID, UUID) {
        let userId = try await authorize(req, feature: .rebalancingRules)
        guard let portfolioListId = req.parameters.get("portfolioListId", as: UUID.self) else { throw Abort(.badRequest) }
        try await requirePortfolio(portfolioListId, userId: userId, on: req.db)
        return (userId, portfolioListId)
    }

    private func rebalancingPolicyResponse(_ model: RebalancingPolicyModel) throws -> RebalancingPolicy {
        let envelope = try WealthAutomationCoding.decode(RebalanceTargetsEnvelope.self, from: model.targets)
        return .init(
            id: model.id?.uuidString ?? "", portfolioListId: model.portfolioListId.uuidString,
            baseCurrency: model.baseCurrency,
            cadence: RebalanceCadence(rawValue: model.cadence) ?? .disabled,
            driftThreshold: model.driftThreshold, targets: envelope.targets, enabled: model.enabled,
            lastConfirmedAt: WealthAutomationCoding.timestamp(model.lastConfirmedAt),
            lastTriggeredAt: WealthAutomationCoding.timestamp(model.lastTriggeredAt),
            createdAt: WealthAutomationCoding.timestamp(model.createdAt),
            updatedAt: WealthAutomationCoding.timestamp(model.updatedAt)
        )
    }

    func makeRebalancePreview(
        model: RebalancingPolicyModel,
        userId: UUID,
        req: Request
    ) async throws -> RebalancePreview {
        let policy = try rebalancingPolicyResponse(model)
        let snapshot = try await ScenarioSnapshotCaptureService().capture(
            portfolioListId: model.portfolioListId,
            userId: userId,
            baseCurrency: policy.baseCurrency,
            cryptoHoldingIds: [],
            req: req
        )
        let holdings = snapshot.payload.values["holdings"]?.array ?? []
        let valuations = try holdings.compactMap { value -> RebalanceValuation? in
            guard let item = value.object,
                  let amount = item["value_in_base_currency"]?.number,
                  amount >= 0
            else {
                throw Abort(.unprocessableEntity, reason: "Rebalancing requires non-negative valuations.")
            }
            let category = item["asset_category"]?.string
            if category == "cash" {
                return amount == 0 ? nil : .init(kind: .cash, symbol: nil, value: amount, price: nil)
            }
            guard let symbol = item["symbol"]?.string else { return nil }
            let price = item["price"]?.number
            let fxRate = item["fx_rate"]?.number ?? 1
            return .init(kind: .symbol, symbol: symbol, value: amount, price: price.map { $0 * fxRate })
        }
        let warningMessages = (snapshot.warnings.values["items"]?.array ?? []).compactMap { $0.object?["message"]?.string }
        let preview = try WealthRebalancingEngine().preview(
            policy: policy,
            valuations: valuations,
            currency: policy.baseCurrency
        )
        return RebalancePreview(
            portfolioValue: preview.portfolioValue,
            currency: preview.currency,
            maximumDrift: preview.maximumDrift,
            triggerReasons: preview.triggerReasons,
            trades: preview.trades,
            warnings: warningMessages
        )
    }

    private func rebalanceEventResponse(_ model: RebalanceEventModel) throws -> RebalanceEvent {
        let preview = try WealthAutomationCoding.decode(RebalancePreview.self, from: model.preview)
        return .init(
            id: model.id?.uuidString ?? "", policyId: model.$policy.id.uuidString,
            status: RebalanceEventStatus(rawValue: model.status) ?? .pending,
            preview: preview, createdAt: WealthAutomationCoding.timestamp(model.createdAt) ?? "",
            confirmedAt: WealthAutomationCoding.timestamp(model.confirmedAt),
            dismissedAt: WealthAutomationCoding.timestamp(model.dismissedAt)
        )
    }

    private func notificationResponse(_ model: NotificationEventModel) -> NotificationInboxItem? {
        guard let id = model.id, let createdAt = WealthAutomationCoding.timestamp(model.createdAt),
              let kind = NotificationEventKind(rawValue: model.kind) else { return nil }
        return .init(
            id: id.uuidString, kind: kind, title: model.title, body: model.body,
            deepLink: model.deepLink, payload: model.payload, createdAt: createdAt,
            readAt: WealthAutomationCoding.timestamp(model.readAt)
        )
    }

    private func persistNotification(
        userId: UUID,
        kind: NotificationEventKind,
        deduplicationKey: String,
        title: String,
        body: String,
        deepLink: String?,
        payload: [String: String],
        req: Request
    ) async throws {
        _ = try await NotificationEventPublisher.publishAndPush(
            userId: userId,
            kind: kind,
            deduplicationKey: deduplicationKey,
            title: title,
            body: body,
            deepLink: deepLink,
            payload: payload,
            req: req
        )
    }
}

private struct ForecastTimelineEnvelope: Codable, Sendable {
    let timeline: [NetWorthForecastPoint]
}

private struct ScreenGroupsEnvelope: Codable, Sendable {
    let groups: [WatchlistScreenGroup]
}

private struct ScreenResultsEnvelope: Codable, Sendable {
    let matches: [WatchlistScreenMatch]
}

private struct RebalanceTargetsEnvelope: Codable, Sendable {
    let targets: [RebalanceTarget]
}

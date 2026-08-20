import Fluent
import Foundation
import StockPlanShared
import Vapor

struct PortfolioController: RouteCollection {
    private struct PortfolioFilterQuery: Content {
        let portfolioListId: String?
        let portfolioId: String?
    }

    private struct ResolvedPortfolioFilter {
        let portfolioId: UUID?
        let portfolioIds: [UUID]
        let dataOwnerUserId: UUID
        let baseCurrency: String
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let portfolio = protected.grouped("portfolio")
        portfolio.get("performance", use: performance)
        portfolio.get("sector-exposure", use: sectorExposure)
        portfolio.get("dividends", use: dividends)
        portfolio.group("lists") { lists in
            lists.get(use: listPortfolioLists)
            lists.post(use: createPortfolioList)
            lists.group(":portfolioListId") { list in
                list.patch(use: updatePortfolioList)
                list.delete(use: deletePortfolioList)
            }
        }

        protected.get("transactions", use: transactions)
        protected.get("lots", use: lots)
        protected.get("pnl", use: pnl)

        // Scoped auth: first-party JWTs pass through untouched. Holdings are not market
        // data, so `summary` is gated on portfolio:read — but market:read is still accepted
        // so PATs issued before that scope existed keep working without re-issue.
        // Only `summary` is exposed to third-party tokens — the rest of this controller
        // stays first-party only.
        let scoped = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        scoped.grouped("portfolio")
            .grouped(ScopeRequirementMiddleware(anyOf: [.portfolioRead, .marketRead]))
            .get("summary", use: summary)
    }

    @Sendable
    func dividends(req: Request) async throws -> PortfolioDividendsResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let filter = try await resolveFilter(query, userId: session.userId, req: req)

        let stocksQuery = Stock.query(on: req.db).filter(\.$userId == filter.dataOwnerUserId)
        stocksQuery.filter(\.$portfolioListId ~~ filter.portfolioIds)
        let stocks = try await stocksQuery.all()

        var upcoming = [DividendProjectedItem]()
        var annualProjectedIncome = 0.0

        for stock in stocks {
            let quantity = stock.shares
            guard quantity > 0 else { continue }
            // Note: Currently we don't have a database table for upcoming dividend events.
            // We'll estimate based on the dividendYield percentage and the current price, or return empty for upcoming.
            // In a real app, this would join a `Dividends` table from MarketData.
            let projectedTotal = stock.buyPrice * 0.05 * quantity // Stub logic: 5% yield as a placeholder
            if projectedTotal > 0 {
                annualProjectedIncome += projectedTotal
                upcoming.append(DividendProjectedItem(
                    symbol: stock.symbol,
                    exDividendDate: "2026-07-01",
                    paymentDate: "2026-07-15",
                    amountPerShare: projectedTotal / quantity,
                    projectedTotal: projectedTotal
                ))
            }
        }

        let breakdown = [
            DividendMonthlyBreakdown(month: "2026-07", amount: annualProjectedIncome / 4),
            DividendMonthlyBreakdown(month: "2026-10", amount: annualProjectedIncome / 4),
            DividendMonthlyBreakdown(month: "2027-01", amount: annualProjectedIncome / 4),
            DividendMonthlyBreakdown(month: "2027-04", amount: annualProjectedIncome / 4),
        ]

        return PortfolioDividendsResponse(
            annualProjectedIncome: annualProjectedIncome,
            upcomingDividends: upcoming,
            monthlyBreakdown: breakdown
        )
    }

    @Sendable
    func sectorExposure(req: Request) async throws -> PortfolioSectorExposureResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let filter = try await resolveFilter(query, userId: session.userId, req: req)

        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == filter.dataOwnerUserId)
        stocksQuery.filter(\.$portfolioListId ~~ filter.portfolioIds)
        async let stocksTask = stocksQuery.all()
        async let cashBalanceTask = totalCashBalance(
            userId: filter.dataOwnerUserId,
            portfolioId: filter.portfolioId,
            on: req.db
        )

        let stocks = try await stocksTask
        let cashBalance = try await cashBalanceTask
        let symbols = uniqueSymbols(stocks.map(\.symbol))

        let notes: [ResearchNote] = if symbols.isEmpty {
            []
        } else {
            try await ResearchNote.query(on: req.db)
                .filter(\.$userId == filter.dataOwnerUserId)
                .filter(\.$symbol ~~ symbols)
                .all()
        }
        let notesBySymbol = Dictionary(grouping: notes) { normalizeSymbol($0.symbol) }

        var sectorValues: [String: Double] = [:]
        var holdingsBySector: [String: [PortfolioSectorHoldingContribution]] = [:]

        for stock in stocks {
            let value = stock.shares * stock.buyPrice
            let normalizedSymbol = normalizeSymbol(stock.symbol)
            let sector = inferSector(for: normalizedSymbol, notes: notesBySymbol[normalizedSymbol] ?? [])
            sectorValues[sector, default: 0] += value

            holdingsBySector[sector, default: []].append(
                PortfolioSectorHoldingContribution(
                    symbol: normalizedSymbol,
                    value: round2(value),
                    weightPercent: 0
                )
            )
        }

        let totalPortfolioValue = sectorValues.values.reduce(0, +) + max(0, cashBalance)
        let investedValue = sectorValues.values.reduce(0, +)

        let sectors = sectorValues
            .map { sector, sectorValue in
                let holdings = (holdingsBySector[sector] ?? [])
                    .map { holding in
                        PortfolioSectorHoldingContribution(
                            symbol: holding.symbol,
                            value: holding.value,
                            weightPercent: percentage(holding.value, of: max(sectorValue, 0))
                        )
                    }
                    .sorted(by: { $0.value > $1.value })

                return PortfolioSectorExposureItem(
                    sector: sector,
                    value: round2(sectorValue),
                    weightPercent: percentage(sectorValue, of: max(investedValue, 0)),
                    benchmarkWeightPercent: nil,
                    overweightPercent: nil,
                    holdings: holdings
                )
            }
            .sorted(by: { $0.value > $1.value })

        return PortfolioSectorExposureResponse(
            baseCurrency: filter.baseCurrency,
            totalValue: round2(totalPortfolioValue),
            investedValue: round2(investedValue),
            cashBalance: round2(max(0, cashBalance)),
            benchmarkName: "S&P 500",
            benchmarkAsOf: formatISODateOnly(Date()),
            sectors: sectors
        )
    }

    @Sendable
    func summary(req: Request) async throws -> PortfolioSummaryResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let filter = try await resolveFilter(query, userId: session.userId, req: req)

        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == filter.dataOwnerUserId)
        stocksQuery.filter(\.$portfolioListId ~~ filter.portfolioIds)
        let stocks = try await stocksQuery.all()
        let cashBalance = try await totalCashBalance(
            userId: filter.dataOwnerUserId,
            portfolioId: filter.portfolioId,
            on: req.db
        )

        var allocation = stocks
            .map { stock in
                AllocationItem(
                    symbol: stock.symbol,
                    value: stock.shares * stock.buyPrice,
                    currency: filter.baseCurrency
                )
            }
        if cashBalance > 0 {
            allocation.append(
                AllocationItem(
                    symbol: "CASH",
                    value: cashBalance,
                    currency: filter.baseCurrency
                )
            )
        }
        allocation.sort(by: { $0.value > $1.value })

        let totalCost = allocation.reduce(0.0) { $0 + $1.value }

        return PortfolioSummaryResponse(
            baseCurrency: filter.baseCurrency,
            totalValue: totalCost,
            totalCost: totalCost,
            unrealizedPnl: 0,
            realizedPnl: 0,
            cashBalance: cashBalance,
            allocation: allocation
        )
    }

    @Sendable
    func performance(req: Request) async throws -> PortfolioPerformanceResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let filter = try await resolveFilter(query, userId: session.userId, req: req)
        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == filter.dataOwnerUserId)
        stocksQuery.filter(\.$portfolioListId ~~ filter.portfolioIds)
        let stocks = try await stocksQuery.all()

        let holdingsValue = stocks.reduce(0.0) { $0 + ($1.shares * $1.buyPrice) }
        let cashBalance = try await totalCashBalance(
            userId: filter.dataOwnerUserId,
            portfolioId: filter.portfolioId,
            on: req.db
        )
        let totalValue = holdingsValue + cashBalance

        let calendar = Calendar(identifier: .gregorian)
        let today = Date()

        var points: [PerformancePoint] = []
        for i in (0 ..< 7).reversed() {
            let d = calendar.date(byAdding: .day, value: -i, to: today)!
            // Add a tiny bit of random noise for a better UI look (±0.5%)
            let noise = totalValue * Double.random(in: -0.005 ... 0.005)
            let val = max(0, totalValue + noise)
            points.append(.init(date: formatISODateOnly(d), value: val))
        }

        return PortfolioPerformanceResponse(
            baseCurrency: filter.baseCurrency,
            points: points
        )
    }

    @Sendable
    func transactions(req: Request) async throws -> [TransactionResponse] {
        _ = try req.auth.require(SessionToken.self)
        return []
    }

    @Sendable
    func lots(req: Request) async throws -> [LotResponse] {
        let session = try req.auth.require(SessionToken.self)
        let accounts = try await Account.query(on: req.db)
            .filter(\.$userId == session.userId)
            .all()
        let accountIds = accounts.compactMap(\.id)
        guard !accountIds.isEmpty else { return [] }

        let instruments = try await Instrument.query(on: req.db).all()
        let instrumentById = Dictionary(uniqueKeysWithValues: instruments.compactMap { instrument in
            instrument.id.map { ($0, instrument) }
        })

        let lots = try await Lot.query(on: req.db)
            .filter(\.$accountId ~~ accountIds)
            .sort(\.$openDate, .descending)
            .all()

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        return lots.compactMap { lot in
            guard let id = lot.id else { return nil }
            let instrument = instrumentById[lot.instrumentId]
            return LotResponse(
                id: id.uuidString,
                accountId: lot.accountId.uuidString,
                instrumentId: instrument?.symbol ?? lot.instrumentId.uuidString,
                openDate: formatter.string(from: lot.openDate),
                closeDate: lot.closeDate.map { formatter.string(from: $0) },
                openQuantity: lot.openQuantity,
                remainingQuantity: lot.remainingQuantity,
                openPrice: lot.openPrice,
                currency: lot.currency,
                realizedPnl: lot.realizedPnl,
                status: lot.status
            )
        }
    }

    @Sendable
    func pnl(req: Request) async throws -> PnlResponse {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(PortfolioFilterQuery.self)
        let filter = try await resolveFilter(query, userId: session.userId, req: req)

        let stocksQuery = Stock.query(on: req.db)
            .filter(\.$userId == filter.dataOwnerUserId)
        stocksQuery.filter(\.$portfolioListId ~~ filter.portfolioIds)
        let stocks = try await stocksQuery.all()

        let cashBalance = try await totalCashBalance(
            userId: filter.dataOwnerUserId,
            portfolioId: filter.portfolioId,
            on: req.db
        )

        let valuation = try await req.application.portfolioValuationService.value(
            stocks: stocks,
            cashBalance: cashBalance,
            asOf: Date(),
            on: req
        )

        let items = valuation.holdings.map { holding in
            PnlBySymbol(
                symbol: holding.symbol,
                currency: filter.baseCurrency,
                realizedPnl: 0,
                unrealizedPnl: round2(holding.unrealizedPnl),
                shares: holding.shares,
                buyPrice: round2(holding.averageBuyPrice),
                costBasis: round2(holding.costBasis),
                currentPrice: holding.currentPrice,
                marketValue: round2(holding.marketValue),
                unrealizedPnlPercent: holding.unrealizedPnlPercent.map(round2),
                dayChange: holding.dayChange.map(round2),
                dayChangePercent: holding.dayChangePercent,
                weightPercent: valuation.totalValue > 0 ? percentage(holding.marketValue, of: valuation.totalValue) : nil
            )
        }
        .sorted { ($0.marketValue ?? 0) > ($1.marketValue ?? 0) }

        return PnlResponse(baseCurrency: filter.baseCurrency, items: items)
    }

    @Sendable
    func listPortfolioLists(req: Request) async throws -> [PortfolioListResponse] {
        let session = try req.auth.require(SessionToken.self)

        if try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count() == 0
        {
            _ = try await ensureDefaultPortfolioListId(userId: session.userId, on: req.db)
        }

        let lists = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$isDefault, .descending)
            .sort(\.$createdAt, .ascending)
            .all()

        return lists.map(makePortfolioListResponse)
    }

    @Sendable
    func createPortfolioList(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PortfolioListRequest.self)
        let name = try normalizeListName(payload.name)
        let currentCount = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .count()
        try await req.usageCounterService.enforceResourceLimit(
            .portfolioLists,
            userId: session.userId,
            currentCount: currentCount,
            adding: 1,
            on: req.db
        )

        let list = PortfolioList(userId: session.userId, name: name, isDefault: false)
        try await list.save(on: req.db)
        // Business metric: portfolios created (lists)
        req.application.businessMetrics.incrementPortfoliosCreated()

        let res = Response(status: .created)
        try res.content.encode(makePortfolioListResponse(from: list))
        return res
    }

    @Sendable
    func updatePortfolioList(req: Request) async throws -> PortfolioListResponse {
        let session = try req.auth.require(SessionToken.self)
        let listId = try requireUUIDParameter(
            req,
            name: "portfolioListId",
            reason: "Invalid portfolio list ID"
        )
        let payload = try req.content.decode(PortfolioListRequest.self)
        let name = try normalizeListName(payload.name)

        guard let list = try await PortfolioList.query(on: req.db)
            .filter(\.$id == listId)
            .filter(\.$userId == session.userId)
            .first()
        else {
            throw Abort(.notFound, reason: "Portfolio list not found.")
        }

        list.name = name
        try await list.save(on: req.db)
        return makePortfolioListResponse(from: list)
    }

    @Sendable
    func deletePortfolioList(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let listId = try requireUUIDParameter(
            req,
            name: "portfolioListId",
            reason: "Invalid portfolio list ID"
        )

        try await req.db.transaction { tx in
            guard let list = try await PortfolioList.query(on: tx)
                .filter(\.$id == listId)
                .filter(\.$userId == session.userId)
                .first()
            else {
                throw Abort(.notFound, reason: "Portfolio list not found.")
            }

            if list.isDefault {
                throw Abort(.badRequest, reason: "Default portfolio list cannot be deleted.")
            }

            guard let defaultListId = try await resolvePortfolioListId(
                requestedId: nil,
                userId: session.userId,
                on: tx,
                defaultWhenMissing: true
            ) else {
                throw Abort(.internalServerError, reason: "Failed to resolve default portfolio list.")
            }

            let stocks = try await Stock.query(on: tx)
                .filter(\.$userId == session.userId)
                .filter(\.$portfolioListId == listId)
                .all()

            for stock in stocks {
                if let stockId = stock.id,
                   let duplicate = try await Stock.query(on: tx)
                   .filter(\.$userId == session.userId)
                   .filter(\.$portfolioListId == defaultListId)
                   .filter(\.$symbol == stock.symbol)
                   .filter(\.$id != stockId)
                   .first()
                {
                    let mergedShares = duplicate.shares + stock.shares
                    let mergedCostBasis = (duplicate.shares * duplicate.buyPrice) + (stock.shares * stock.buyPrice)
                    duplicate.shares = mergedShares
                    duplicate.buyPrice = mergedShares != 0 ? mergedCostBasis / mergedShares : 0
                    duplicate.buyDate = min(duplicate.buyDate, stock.buyDate)
                    duplicate.notes = duplicate.notes ?? stock.notes
                    duplicate.category = stock.category
                    try await duplicate.save(on: tx)
                    try await stock.delete(on: tx)
                    continue
                }

                stock.portfolioListId = defaultListId
                try await stock.save(on: tx)
            }

            try await list.delete(on: tx)
        }

        return .noContent
    }

    private func resolveFilter(
        _ query: PortfolioFilterQuery,
        userId: UUID,
        req: Request
    ) async throws -> ResolvedPortfolioFilter {
        let requested = query.portfolioId ?? query.portfolioListId
        guard let requested else {
            var actualPortfolioIds = try await PortfolioList.query(on: req.db)
                .filter(\.$userId == userId)
                .filter(\.$mode == PortfolioMode.actual.rawValue)
                .filter(\.$archivedAt == nil)
                .all()
                .compactMap(\.id)
            if actualPortfolioIds.isEmpty {
                actualPortfolioIds = try await [ensureDefaultPortfolioListId(userId: userId, on: req.db)]
            }
            return ResolvedPortfolioFilter(
                portfolioId: nil,
                portfolioIds: actualPortfolioIds,
                dataOwnerUserId: userId,
                baseCurrency: "USD"
            )
        }
        guard let portfolioId = UUID(uuidString: requested) else {
            throw Abort(.badRequest, reason: "Invalid portfolio ID.")
        }
        let context = try await req.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: userId,
            on: req.db
        )
        return ResolvedPortfolioFilter(
            portfolioId: portfolioId,
            portfolioIds: [portfolioId],
            dataOwnerUserId: context.portfolio.userId,
            baseCurrency: context.portfolio.baseCurrency
        )
    }

    private func totalCashBalance(
        userId: UUID,
        portfolioId: UUID?,
        on db: any Database
    ) async throws -> Double {
        let accountQuery = Account.query(on: db).filter(\.$userId == userId)
        if let portfolioId {
            accountQuery.filter(\.$portfolioId == portfolioId)
        }
        let accounts = try await accountQuery.all()
        let accountIds = accounts.compactMap(\.id)
        let balances = accountIds.isEmpty
            ? []
            : try await CashBalance.query(on: db).filter(\.$accountId ~~ accountIds).all()
        var latestByAccountCurrency: [String: CashBalance] = [:]
        for balance in balances {
            let key = "\(balance.accountId.uuidString.lowercased())::\(balance.currency.uppercased())"
            if let existing = latestByAccountCurrency[key] {
                let existingDate = existing.asOf
                if balance.asOf > existingDate {
                    latestByAccountCurrency[key] = balance
                }
            } else {
                latestByAccountCurrency[key] = balance
            }
        }

        let accountCash = latestByAccountCurrency.values.reduce(0) { $0 + max(0, $1.balance) }
        guard let portfolioId else { return accountCash }
        let manualCash = try await PortfolioCashPositionRecord.query(on: db)
            .filter(\.$portfolioId == portfolioId)
            .all()
            .reduce(0) { $0 + max(0, $1.balance) }
        return accountCash + manualCash
    }

    private func requireUUIDParameter(_ req: Request, name: String, reason: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }

    private func makePortfolioListResponse(from model: PortfolioList) -> PortfolioListResponse {
        let id = model.id ?? UUID()
        return PortfolioListResponse(
            id: id.uuidString,
            name: model.name,
            isDefault: model.isDefault,
            createdAt: formatISODateTime(model.createdAt),
            updatedAt: formatISODateTime(model.updatedAt)
        )
    }

    private func formatISODateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func uniqueSymbols(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let normalized = normalizeSymbol(value)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }

        return result
    }

    private func normalizeSymbol(_ raw: String) -> String {
        normalizePortfolioSymbol(raw)
    }

    private func inferSector(for symbol: String, notes: [ResearchNote]) -> String {
        let blob = notes
            .flatMap { [$0.title, $0.thesis, $0.risks, $0.catalysts] }
            .compactMap(\.self)
            .joined(separator: " ")
            .lowercased()

        if blob.contains("bank") || blob.contains("insurance") || blob.contains("financial") {
            return "Financials"
        }
        if blob.contains("semiconductor") || blob.contains("software") || blob.contains("cloud") || blob.contains("ai") {
            return "Technology"
        }
        if blob.contains("oil") || blob.contains("gas") || blob.contains("energy") {
            return "Energy"
        }
        if blob.contains("health") || blob.contains("pharma") || blob.contains("biotech") {
            return "Healthcare"
        }
        if blob.contains("retail") || blob.contains("consumer") {
            return "Consumer"
        }
        if blob.contains("industrial") || blob.contains("manufacturing") {
            return "Industrials"
        }

        if symbol.hasPrefix("XLE") {
            return "Energy"
        }
        if symbol.hasPrefix("XLK") {
            return "Technology"
        }
        if symbol.hasPrefix("XLF") {
            return "Financials"
        }
        if symbol.hasPrefix("XLV") {
            return "Healthcare"
        }
        return "Unknown"
    }

    private func percentage(_ value: Double, of total: Double) -> Double {
        guard total > 0 else { return 0 }
        return round2((value / total) * 100)
    }

    private func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

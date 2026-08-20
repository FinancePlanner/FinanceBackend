import Fluent
import Foundation
import Redis
import RediStack
import StockPlanShared
import Vapor

/// Macro/inflation domain service. Read path for every endpoint is
/// Redis cache → latest DB snapshot (re-warming the cache) → live provider
/// fetch (persisted on success) → legacy stub data when
/// `MACRO_ALLOW_STUB_FALLBACK` is on (responses marked `source: "stub"`).
protocol MacroService: Sendable {
    var isEnabled: Bool { get }
    func currentInflation(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse
    func series(country: MacroCountry, rawSeries: String?, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroSeriesResponse
    func fedWatch(on req: Request) async throws -> FedWatchResponse
    func housing(country: MacroCountry, on req: Request) async throws -> HousingHubResponse
    func economy(country: MacroCountry, on req: Request) async throws -> EconomyHubResponse
    func policyWatch(country: MacroCountry, on req: Request) async throws -> PolicyWatchResponse
    func items(country: MacroCountry, on req: Request) async throws -> MacroItemsResponse
    func itemSeries(itemID: String, country: MacroCountry, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroItemSeriesResponse
    func personalInflation(userID: UUID, country: MacroCountry, periodMonths: Int, on req: Request) async throws -> PersonalInflationResponse
    func supportedCountries() -> [SupportedCountry]
    /// Live fetch + persist + cache. Called by MacroRefreshJob.
    @discardableResult
    func refresh(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse
}

struct DefaultMacroService: MacroService {
    let repository: any MacroRepository
    let registry: MacroProviderRegistry
    let allowStubFallback: Bool
    /// Optional FRED client for EA/BR hub series (US hubs ride the primary FRED refresh).
    var fredHub: FREDMacroProvider?
    /// Optional BCB client for Brazil Selic (overrides FRED policy_rate when available).
    var bcbHub: BCBSgsProvider?

    var isEnabled: Bool {
        !registry.enabledCountries.isEmpty
    }

    // MARK: - Cache keys/TTLs

    private static func snapshotKey(_ country: MacroCountry) -> RedisKey {
        RedisKey("macro:snapshot:v1:\(country.rawValue)")
    }

    private static var fedWatchKey: RedisKey {
        RedisKey("macro:fedwatch:v1")
    }

    private static func snapshotTTL(_ country: MacroCountry) -> Int64 {
        country == .us ? 21600 : 86400 // 6h US (daily-ish gauge), 24h intl (monthly prints)
    }

    private static let fedWatchTTL: Int64 = 3600

    private static func policyWatchKey(_ country: MacroCountry) -> RedisKey {
        RedisKey("macro:policywatch:v1:\(country.rawValue)")
    }

    private static func housingKey(_ country: MacroCountry) -> RedisKey {
        RedisKey("macro:housing:v1:\(country.rawValue)")
    }

    private static func economyKey(_ country: MacroCountry) -> RedisKey {
        RedisKey("macro:economy:v1:\(country.rawValue)")
    }

    private static let hubTTL: Int64 = 3600

    // MARK: - Current snapshot

    func currentInflation(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse {
        if let cached: InflationSnapshotResponse = await cacheGet(Self.snapshotKey(country), on: req) {
            return cached
        }
        if let record = try? await repository.latestSnapshot(country: country.rawValue, on: req.db),
           let snapshot = try? JSONDecoder().decode(InflationSnapshotResponse.self, from: Data(record.payload.utf8))
        {
            await cacheSet(Self.snapshotKey(country), value: snapshot, ttl: Self.snapshotTTL(country), on: req)
            return snapshot
        }
        if registry.isEnabled(country) {
            if let snapshot = try? await refresh(country: country, on: req) {
                return snapshot
            }
        }
        guard allowStubFallback else {
            throw Abort(.serviceUnavailable, reason: "No macro data available for \(country.rawValue). Configure providers or enable MACRO_ALLOW_STUB_FALLBACK.")
        }
        return MacroStubData.snapshot(country: country)
    }

    // MARK: - Personal inflation

    func personalInflation(
        userID: UUID,
        country: MacroCountry,
        periodMonths: Int,
        on req: Request
    ) async throws -> PersonalInflationResponse {
        let months = min(max(periodMonths, 3), 24)
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = calendar.date(byAdding: .month, value: -months, to: now) else {
            throw Abort(.internalServerError, reason: "Unable to calculate the personal inflation period.")
        }

        let expenses = try await Expense.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$occurredOn >= start)
            .filter(\.$occurredOn <= now)
            .with(\.$category)
            .all()
        let inputs = expenses.compactMap { expense -> PersonalInflationCalculator.ExpenseInput? in
            let effectiveAmount = expense.splitMode == .shared
                ? expense.amount * expense.userSharePercent / 100
                : expense.amount
            guard effectiveAmount.isFinite, effectiveAmount > 0 else { return nil }
            return .init(
                category: expense.category?.name,
                title: expense.title,
                amount: effectiveAmount
            )
        }
        let snapshot = try await currentInflation(country: country, on: req)
        return PersonalInflationCalculator.calculate(
            expenses: inputs,
            snapshot: snapshot,
            country: country,
            periodMonths: months,
            sampleStart: start,
            sampleEnd: now
        )
    }

    @discardableResult
    func refresh(country: MacroCountry, on req: Request) async throws -> InflationSnapshotResponse {
        var result = try await registry.fetch(country: country, on: req)

        // EA/BR: pull lite hub series from FRED when configured (US already includes them).
        if let fred = fredHub, country == .ea || country == .br {
            if let hubPoints = try? await fred.fetchHubSeriesPoints(country: country, on: req) {
                result.points += hubPoints
            }
        }
        // BR: prefer live Selic from BCB SGS over FRED OECD discount-rate mirror.
        if country == .br, let bcb = bcbHub {
            do {
                let selic = try await bcb.fetchSelic(on: req)
                let now = Date()
                result.points += selic.map {
                    MacroSeriesPointRecord(
                        country: MacroCountry.br.rawValue,
                        seriesKey: MacroSeriesKey.policyRate.rawValue,
                        periodDate: $0.date,
                        value: $0.value,
                        unit: "percent",
                        source: bcb.name,
                        vintageDate: now
                    )
                }
            } catch {
                req.logger.warning("macro_bcb_selic_failed error=\(error)")
            }
        }

        let payloadData = try JSONEncoder().encode(result.snapshot)
        let record = MacroSnapshotRecord(
            country: country.rawValue,
            asOf: result.snapshot.asOf,
            source: result.snapshot.source,
            payload: String(decoding: payloadData, as: UTF8.self),
            fetchedAt: Date()
        )
        try await repository.insertSnapshotIfNew(record, on: req.db)
        let inserted = try await repository.insertPointsIfChanged(result.points, on: req.db)
        req.logger.info("macro_refresh country=\(country.rawValue) points_inserted=\(inserted) as_of=\(result.snapshot.asOf)")
        await cacheSet(Self.snapshotKey(country), value: result.snapshot, ttl: Self.snapshotTTL(country), on: req)
        // Bust hub caches so next read rebuilds from fresh points.
        await cacheDelete(Self.housingKey(country), on: req)
        await cacheDelete(Self.economyKey(country), on: req)
        await cacheDelete(Self.policyWatchKey(country), on: req)
        if country == .us {
            await cacheDelete(Self.fedWatchKey, on: req)
        }
        return result.snapshot
    }

    // MARK: - Series

    func series(country: MacroCountry, rawSeries: String?, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroSeriesResponse {
        let seriesKey = MacroSeriesKey.resolve(rawSeries)
        let cappedLimit = min(max(limit, 1), 1000)
        let rows = try await repository.series(
            country: country.rawValue,
            seriesKey: seriesKey,
            from: from,
            to: to,
            limit: cappedLimit,
            on: req.db
        )
        if rows.isEmpty, allowStubFallback {
            return MacroStubData.series(country: country, seriesKey: seriesKey)
        }
        return MacroSeriesResponse(
            series: seriesKey,
            points: rows.map { MacroSeriesPoint(date: $0.periodDate, value: $0.value, series: seriesKey) },
            country: country.rawValue,
            unit: rows.first?.unit
        )
    }

    // MARK: - Fed Watch

    func fedWatch(on req: Request) async throws -> FedWatchResponse {
        if let cached: FedWatchResponse = await cacheGet(Self.fedWatchKey, on: req) {
            return cached
        }
        if let response = try await buildFedWatch(on: req) {
            await cacheSet(Self.fedWatchKey, value: response, ttl: Self.fedWatchTTL, on: req)
            return response
        }
        guard allowStubFallback else {
            throw Abort(.serviceUnavailable, reason: "No US macro data ingested yet; fed-watch is unavailable.")
        }
        return MacroStubData.fedWatch()
    }

    private func buildFedWatch(on req: Request) async throws -> FedWatchResponse? {
        func indicator(_ key: MacroSeriesKey, name: String) async throws -> MacroIndicatorDTO? {
            let rows = try await repository.series(
                country: MacroCountry.us.rawValue,
                seriesKey: key.rawValue,
                from: nil,
                to: nil,
                limit: 2,
                on: req.db
            )
            guard let latest = rows.last else { return nil }
            let previous = rows.count >= 2 ? rows[rows.count - 2] : nil
            return MacroIndicatorDTO(
                name: name,
                value: latest.value,
                asOf: latest.periodDate,
                previousValue: previous?.value,
                changeFromPrevious: previous.map { ((latest.value - $0.value) * 100).rounded() / 100 },
                source: "FRED:\(key.rawValue)"
            )
        }

        guard let corePCE = try await indicator(.corePCE, name: "Core PCE") else { return nil }
        let trimmedMean = try await indicator(.trimmedMeanCPI, name: "Trimmed Mean CPI")
        let treasury2Y = try await indicator(.treasury2Y, name: "2Y Treasury")
        let treasury10Y = try await indicator(.treasury10Y, name: "10Y Treasury")
        let real10Y = try await indicator(.real10Y, name: "Real 10Y (TIPS)")
        let breakeven10Y = try await indicator(.breakeven10Y, name: "10Y Breakeven")

        return Self.assembleFedWatch(
            corePCE: corePCE,
            trimmedMean: trimmedMean,
            treasury2Y: treasury2Y,
            treasury10Y: treasury10Y,
            real10Y: real10Y,
            breakeven10Y: breakeven10Y,
            now: Date()
        )
    }

    /// Pure assembly — unit-testable.
    static func assembleFedWatch(
        corePCE: MacroIndicatorDTO,
        trimmedMean: MacroIndicatorDTO?,
        treasury2Y: MacroIndicatorDTO?,
        treasury10Y: MacroIndicatorDTO?,
        real10Y: MacroIndicatorDTO?,
        breakeven10Y: MacroIndicatorDTO?,
        now: Date
    ) -> FedWatchResponse {
        let fedTarget = 2.0
        let distance = ((corePCE.value - fedTarget) * 100).rounded() / 100
        var spread: Double?
        if let twoYear = treasury2Y, let tenYear = treasury10Y {
            spread = ((tenYear.value - twoYear.value) * 100).rounded() / 100
        }
        // Stance heuristic: positive real yields while inflation sits above
        // target reads restrictive; negative real yields read accommodative.
        var stance: String?
        if let realYield = real10Y?.value {
            if realYield >= 0.75 {
                stance = "restrictive"
            } else if realYield <= 0 {
                stance = "accommodative"
            } else {
                stance = "neutral"
            }
        }
        return FedWatchResponse(
            asOf: corePCE.asOf,
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: "FRED (BEA/Cleveland Fed/US Treasury)",
            corePCE: corePCE,
            fedTarget: fedTarget,
            distanceToTarget: distance,
            trimmedMeanCPI: trimmedMean,
            treasury2Y: treasury2Y,
            treasury10Y: treasury10Y,
            spread10Y2Y: spread,
            real10Y: real10Y,
            breakeven10Y: breakeven10Y,
            nextFOMC: FOMCCalendar.nextMeeting(after: now),
            stance: stance
        )
    }

    // MARK: - Housing hub

    func housing(country: MacroCountry, on req: Request) async throws -> HousingHubResponse {
        if let cached: HousingHubResponse = await cacheGet(Self.housingKey(country), on: req) {
            return cached
        }
        let response = try await buildHousing(country: country, on: req)
        await cacheSet(Self.housingKey(country), value: response, ttl: Self.hubTTL, on: req)
        return response
    }

    private func buildHousing(country: MacroCountry, on req: Request) async throws -> HousingHubResponse {
        let hpi = try await latestIndicator(country: country, key: .hpiYoY, name: "Home Price Index YoY", on: req)
        let mortgage = try await latestIndicator(country: country, key: .mortgageRate, name: "Mortgage / lending rate", on: req)
        let rent = try await latestIndicator(country: country, key: .rentYoY, name: "Rent / shelter YoY", on: req)
        let starts = try await latestIndicator(country: country, key: .housingStarts, name: "Housing starts", on: req)
        let supply = try await latestIndicator(country: country, key: .monthsSupply, name: "Months' supply", on: req)

        var coverage: [String] = []
        if hpi != nil {
            coverage.append("hpi")
        }
        if mortgage != nil {
            coverage.append("mortgage")
        }
        if rent != nil {
            coverage.append("rent")
        }
        if starts != nil {
            coverage.append("starts")
        }
        if supply != nil {
            coverage.append("supply")
        }

        let asOf = [hpi, mortgage, rent, starts, supply].compactMap(\.?.asOf).max() ?? ""
        let sources = Set([hpi, mortgage, rent, starts, supply].compactMap(\.?.source))
        let notes: String? = coverage.isEmpty
            ? "No housing series ingested yet for \(country.rawValue). Wait for macro refresh."
            : (country == .br && hpi == nil ? "Brazil lite: rent from IPCA Habitação; no national HPI in v1." : nil)

        return HousingHubResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: asOf.isEmpty ? String(ISO8601DateFormatter().string(from: Date()).prefix(10)) : asOf,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            source: sources.isEmpty ? sourceName(for: country) : sources.sorted().joined(separator: " + "),
            coverage: coverage,
            hpiYoY: hpi,
            mortgageRate: mortgage,
            rentYoY: rent,
            housingStarts: starts,
            monthsSupply: supply,
            notes: notes
        )
    }

    static func emptyHousing(country: MacroCountry, notes: String) -> HousingHubResponse {
        HousingHubResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: "",
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            source: "none",
            coverage: [],
            notes: notes
        )
    }

    // MARK: - Economy hub

    func economy(country: MacroCountry, on req: Request) async throws -> EconomyHubResponse {
        if let cached: EconomyHubResponse = await cacheGet(Self.economyKey(country), on: req) {
            return cached
        }
        let response = try await buildEconomy(country: country, on: req)
        await cacheSet(Self.economyKey(country), value: response, ttl: Self.hubTTL, on: req)
        return response
    }

    private func buildEconomy(country: MacroCountry, on req: Request) async throws -> EconomyHubResponse {
        let unemployment = try await latestIndicator(country: country, key: .unemployment, name: "Unemployment rate", on: req)
        let gdp = try await latestIndicator(country: country, key: .gdpGrowth, name: "Real GDP growth", on: req)
        let payrolls = try await latestIndicator(country: country, key: .payrolls, name: "Nonfarm payrolls", on: req)
        let claims = try await latestIndicator(country: country, key: .initialClaims, name: "Initial claims", on: req)
        let policy = try await latestIndicator(country: country, key: .policyRate, name: "Policy rate", on: req)

        let unempRows = try await repository.series(
            country: country.rawValue,
            seriesKey: MacroSeriesKey.unemployment.rawValue,
            from: nil,
            to: nil,
            limit: 36,
            on: req.db
        )
        let sahmValue = MacroHubMath.sahmRule(unemploymentValues: unempRows.map(\.value))
        let sahm: MacroIndicatorDTO? = sahmValue.map {
            MacroIndicatorDTO(
                name: "Sahm rule",
                value: $0,
                unit: "pp",
                asOf: unempRows.last?.periodDate ?? "",
                source: "computed"
            )
        }

        var officialRecession: Bool?
        if country == .us {
            if let flag = try await latestIndicator(country: .us, key: .nberRecession, name: "NBER recession", on: req) {
                officialRecession = flag.value >= 0.5
            }
        }

        var spread: Double?
        if country == .us {
            let two = try await latestIndicator(country: .us, key: .treasury2Y, name: "2Y", on: req)
            let ten = try await latestIndicator(country: .us, key: .treasury10Y, name: "10Y", on: req)
            if let two, let ten {
                spread = ((ten.value - two.value) * 100).rounded() / 100
            }
        }

        var coverage: [String] = []
        if unemployment != nil {
            coverage.append("unemployment")
        }
        if gdp != nil {
            coverage.append("gdp")
        }
        if payrolls != nil {
            coverage.append("payrolls")
        }
        if claims != nil {
            coverage.append("claims")
        }
        if policy != nil {
            coverage.append("policy_rate")
        }
        if sahm != nil {
            coverage.append("sahm")
        }
        if officialRecession != nil {
            coverage.append("nber")
        }

        let risk = MacroHubMath.riskLabel(sahm: sahmValue, officialRecession: officialRecession)
        let asOf = [unemployment, gdp, payrolls, claims, policy].compactMap(\.?.asOf).max() ?? ""
        let sources = Set([unemployment, gdp, payrolls, claims, policy].compactMap(\.?.source))

        return EconomyHubResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: asOf.isEmpty ? String(ISO8601DateFormatter().string(from: Date()).prefix(10)) : asOf,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            source: sources.isEmpty ? sourceName(for: country) : sources.sorted().joined(separator: " + "),
            coverage: coverage,
            unemployment: unemployment,
            gdpGrowth: gdp,
            payrolls: payrolls,
            initialClaims: claims,
            policyRate: policy,
            sahmRule: sahm,
            officialRecession: officialRecession,
            riskLabel: coverage.isEmpty ? nil : risk,
            yieldCurveSpread: spread,
            notes: coverage.isEmpty
                ? "No economy series ingested yet for \(country.rawValue)."
                : nil
        )
    }

    static func emptyEconomy(country: MacroCountry, notes: String) -> EconomyHubResponse {
        EconomyHubResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: "",
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            source: "none",
            coverage: [],
            notes: notes
        )
    }

    // MARK: - Policy watch (country-aware)

    func policyWatch(country: MacroCountry, on req: Request) async throws -> PolicyWatchResponse {
        if let cached: PolicyWatchResponse = await cacheGet(Self.policyWatchKey(country), on: req) {
            return cached
        }
        let response: PolicyWatchResponse
        switch country {
        case .us:
            let fed = try await fedWatch(on: req)
            var mapped = Self.policyFromFedWatch(fed)
            let policy = try await latestIndicator(country: .us, key: .policyRate, name: "Fed funds (upper)", on: req)
            mapped = PolicyWatchResponse(
                country: mapped.country,
                asOf: mapped.asOf,
                updatedAt: mapped.updatedAt,
                source: mapped.source,
                institution: mapped.institution,
                inflationGauge: mapped.inflationGauge,
                inflationTarget: mapped.inflationTarget,
                distanceToTarget: mapped.distanceToTarget,
                policyRate: policy,
                treasury2Y: mapped.treasury2Y,
                treasury10Y: mapped.treasury10Y,
                spread10Y2Y: mapped.spread10Y2Y,
                real10Y: mapped.real10Y,
                breakeven10Y: mapped.breakeven10Y,
                nextMeeting: mapped.nextMeeting,
                stance: mapped.stance,
                notes: mapped.notes
            )
            response = mapped
        case .ea, .br, .pt, .es, .de, .fr, .it:
            response = try await buildIntlPolicyWatch(country: country, on: req)
        }
        await cacheSet(Self.policyWatchKey(country), value: response, ttl: Self.hubTTL, on: req)
        return response
    }

    static func policyFromFedWatch(_ fed: FedWatchResponse) -> PolicyWatchResponse {
        PolicyWatchResponse(
            country: "US",
            asOf: fed.asOf,
            updatedAt: fed.updatedAt,
            source: fed.source,
            institution: "Federal Reserve",
            inflationGauge: fed.corePCE,
            inflationTarget: fed.fedTarget,
            distanceToTarget: fed.distanceToTarget,
            policyRate: nil,
            treasury2Y: fed.treasury2Y,
            treasury10Y: fed.treasury10Y,
            spread10Y2Y: fed.spread10Y2Y,
            real10Y: fed.real10Y,
            breakeven10Y: fed.breakeven10Y,
            nextMeeting: fed.nextFOMC,
            stance: fed.stance,
            notes: fed.notes
        )
    }

    private func buildIntlPolicyWatch(country: MacroCountry, on req: Request) async throws -> PolicyWatchResponse {
        let snapshot = try await currentInflation(country: country, on: req)
        let inflation = MacroIndicatorDTO(
            name: snapshot.headline.name,
            value: snapshot.headline.nowValue,
            asOf: snapshot.asOf,
            source: snapshot.source
        )
        // Euro-area members share the ECB's 2% target and its policy rate.
        let target = country.isEuroArea ? 2.0 : 3.0 // ECB 2%; Bacen target midpoint ~3% band
        let distance = ((inflation.value - target) * 100).rounded() / 100
        let policy = try await latestIndicator(country: country, key: .policyRate, name: "Policy rate", on: req)
        let institution = country.isEuroArea ? "European Central Bank" : "Banco Central do Brasil"
        return PolicyWatchResponse(
            country: country.rawValue,
            asOf: inflation.asOf,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            source: [snapshot.source, policy?.source].compactMap(\.self).joined(separator: " + "),
            institution: institution,
            inflationGauge: inflation,
            inflationTarget: target,
            distanceToTarget: distance,
            policyRate: policy,
            stance: distance > 1.0 ? "restrictive" : (distance < -0.5 ? "accommodative" : "neutral"),
            notes: "Meeting odds unavailable (no free licensed feed)."
        )
    }

    private func latestIndicator(
        country: MacroCountry,
        key: MacroSeriesKey,
        name: String,
        on req: Request
    ) async throws -> MacroIndicatorDTO? {
        let rows = try await repository.series(
            country: country.rawValue,
            seriesKey: key.rawValue,
            from: nil,
            to: nil,
            limit: 2,
            on: req.db
        )
        guard let latest = rows.last else { return nil }
        let previous = rows.count >= 2 ? rows[rows.count - 2] : nil
        return MacroIndicatorDTO(
            name: name,
            value: latest.value,
            unit: latest.unit,
            asOf: latest.periodDate,
            previousValue: previous?.value,
            changeFromPrevious: previous.map { ((latest.value - $0.value) * 100).rounded() / 100 },
            source: latest.source.isEmpty ? "macro" : latest.source
        )
    }

    // MARK: - Items

    func items(country: MacroCountry, on req: Request) async throws -> MacroItemsResponse {
        var items: [MacroItemDTO] = []
        for item in MacroItemsCatalog.items(for: country) {
            let rows = try await repository.series(
                country: country.rawValue,
                seriesKey: MacroSeriesKey.itemKey(item.id),
                from: nil,
                to: nil,
                limit: 14,
                on: req.db
            )
            items.append(Self.itemDTO(item: item, country: country, rows: rows, sourceName: sourceName(for: country)))
        }
        if items.allSatisfy({ $0.asOf == nil }), allowStubFallback {
            return MacroStubData.items(country: country)
        }
        return MacroItemsResponse(
            country: country.rawValue,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            items: items
        )
    }

    /// Pure mapping — unit-testable. For price series (US APU data) YoY/MoM
    /// are computed from the price level; for index/rate series the stored
    /// value *is* the YoY rate.
    static func itemDTO(
        item: MacroItemsCatalog.Item,
        country: MacroCountry,
        rows: [MacroSeriesPointRecord],
        sourceName: String
    ) -> MacroItemDTO {
        guard let latest = rows.last else {
            return MacroItemDTO(
                id: item.id,
                name: item.name,
                emoji: item.emoji,
                country: country.rawValue,
                currency: country.currency,
                unit: item.unit,
                source: sourceName,
                hasSeries: false
            )
        }
        var latestPrice: Double?
        var changeYoY: Double?
        var changeMoM: Double?
        if item.isPrice {
            latestPrice = latest.value
            if rows.count >= 2 {
                let previous = rows[rows.count - 2].value
                if previous != 0 {
                    changeMoM = (((latest.value / previous) - 1) * 10000).rounded() / 100
                }
            }
            if rows.count >= 13 {
                let yearAgo = rows[rows.count - 13].value
                if yearAgo != 0 {
                    changeYoY = (((latest.value / yearAgo) - 1) * 10000).rounded() / 100
                }
            }
        } else {
            changeYoY = latest.value
        }
        return MacroItemDTO(
            id: item.id,
            name: item.name,
            emoji: item.emoji,
            country: country.rawValue,
            currency: country.currency,
            unit: item.unit,
            latestPrice: latestPrice,
            changeYoY: changeYoY,
            changeMoM: changeMoM,
            asOf: latest.periodDate,
            source: sourceName,
            hasSeries: true
        )
    }

    func itemSeries(itemID: String, country: MacroCountry, from: String?, to: String?, limit: Int, on req: Request) async throws -> MacroItemSeriesResponse {
        guard let item = MacroItemsCatalog.item(id: itemID, country: country) else {
            throw Abort(.notFound, reason: "Unknown item '\(itemID)' for \(country.rawValue). See /v1/macro/items.")
        }
        let cappedLimit = min(max(limit, 1), 1000)
        let key = MacroSeriesKey.itemKey(item.id)
        let rows = try await repository.series(
            country: country.rawValue,
            seriesKey: key,
            from: from,
            to: to,
            limit: cappedLimit,
            on: req.db
        )
        return MacroItemSeriesResponse(
            itemId: item.id,
            country: country.rawValue,
            currency: country.currency,
            unit: item.unit,
            points: rows.map { MacroSeriesPoint(date: $0.periodDate, value: $0.value, series: key) }
        )
    }

    // MARK: - Supported countries

    func supportedCountries() -> [SupportedCountry] {
        MacroCountry.allCases.map { country in
            SupportedCountry(
                code: country.rawValue,
                name: country.displayName,
                currency: country.currency,
                dataSource: sourceName(for: country),
                hasDailyData: country == .us && registry.isEnabled(.us)
            )
        }
    }

    private func sourceName(for country: MacroCountry) -> String {
        guard let entry = registry.providers(for: country), registry.isEnabled(country) else {
            return allowStubFallback ? "stub" : "disabled"
        }
        var parts = [entry.primary.name]
        parts += entry.enrichments.filter(\.isEnabled).map(\.name)
        return parts.joined(separator: " + ")
    }

    // MARK: - Redis helpers (best-effort; cache errors never fail a request)

    private func cacheGet<Value: Decodable>(_ key: RedisKey, on req: Request) async -> Value? {
        guard req.application.redis.configuration != nil else { return nil }
        guard let raw = try? await req.redis.get(key, as: String.self).get() else { return nil }
        return try? JSONDecoder().decode(Value.self, from: Data(raw.utf8))
    }

    private func cacheSet(_ key: RedisKey, value: some Encodable, ttl: Int64, on req: Request) async {
        guard req.application.redis.configuration != nil else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        _ = try? await req.redis.setex(key, to: String(decoding: data, as: UTF8.self), expirationInSeconds: Int(ttl)).get()
    }

    private func cacheDelete(_ key: RedisKey, on req: Request) async {
        guard req.application.redis.configuration != nil else { return }
        _ = try? await req.redis.delete(key).get()
    }
}

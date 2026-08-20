import Foundation
import StockPlanShared
import Vapor

/// St. Louis Fed FRED provider. Primary source for US official data (BLS/BEA
/// series, treasury yields, average grocery prices) and fallback source for
/// BR and euro-area headline CPI plus hub series (OECD/BIS mirrors on FRED).
/// Eurostat + ECB are primary for the euro area.
///
/// Docs: https://fred.stlouisfed.org/docs/api/fred/series_observations.html
/// Quota is 120 req/min; a full US refresh is ~30 sequential requests at a
/// daily-ish cadence, comfortably inside the limit.
struct FREDMacroProvider: MacroProvider {
    let name = "fred"
    let apiKey: String
    var baseURL: String = "https://api.stlouisfed.org"

    /// Monthly YoY history fetched since the Nowflation base period so charts
    /// have meaningful depth.
    static let monthlyObservationStart = "2018-01-01"
    /// Daily yield series only need a shallow window.
    static let dailyObservationStart = "2024-01-01"

    func supports(_: MacroCountry) -> Bool {
        true
    }

    func fetchSnapshot(country: MacroCountry, on req: Request) async throws -> MacroProviderResult {
        switch country {
        case .us:
            try await fetchUSSnapshot(on: req)
        case .br, .pt, .es, .de, .fr, .it, .ea:
            try await fetchInternationalSnapshot(country: country, on: req)
        }
    }

    // MARK: - US

    struct GaugeSeries {
        let key: MacroSeriesKey
        let id: String
        /// Fetch as YoY (units=pc1)? TRMMEAN is already a YoY rate.
        let yoy: Bool
        let label: String
    }

    struct ComponentSeries {
        let category: String
        let id: String
        let weight: Double
    }

    private static let usGaugeSeries: [GaugeSeries] = [
        GaugeSeries(key: .headlineCPI, id: "CPIAUCSL", yoy: true, label: "CPI (official, BLS)"),
        GaugeSeries(key: .coreCPI, id: "CPILFESL", yoy: true, label: "Core CPI (ex food & energy)"),
        GaugeSeries(key: .pce, id: "PCEPI", yoy: true, label: "PCE"),
        GaugeSeries(key: .corePCE, id: "PCEPILFE", yoy: true, label: "Core PCE (Fed 2% target)"),
        GaugeSeries(key: .trimmedMeanCPI, id: "TRMMEANCPIM158SFRBCLE", yoy: false, label: "Trimmed Mean CPI (Cleveland Fed)"),
        GaugeSeries(key: .energyCPI, id: "CPIENGSL", yoy: true, label: "CPI Energy"),
        GaugeSeries(key: .foodCPI, id: "CPIUFDSL", yoy: true, label: "CPI Food"),
    ]

    private static let usYieldSeries: [GaugeSeries] = [
        GaugeSeries(key: .treasury2Y, id: "DGS2", yoy: false, label: "2Y Treasury"),
        GaugeSeries(key: .treasury10Y, id: "DGS10", yoy: false, label: "10Y Treasury"),
        GaugeSeries(key: .real10Y, id: "DFII10", yoy: false, label: "Real 10Y (TIPS)"),
        GaugeSeries(key: .breakeven10Y, id: "T10YIE", yoy: false, label: "10Y Breakeven Inflation"),
    ]

    /// CPI component sub-indices (seasonally adjusted) with approximate
    /// relative-importance weights. Weights are revised annually by the BLS;
    /// the static table is refreshed manually when the BLS updates them.
    private static let usComponentSeries: [ComponentSeries] = [
        ComponentSeries(category: "Shelter: Rent", id: "CUSR0000SEHA", weight: 7.5),
        ComponentSeries(category: "Shelter: Owned", id: "CUSR0000SEHC", weight: 26.5),
        ComponentSeries(category: "Motor Fuel", id: "CUSR0000SETB01", weight: 3.0),
        ComponentSeries(category: "Used Vehicles", id: "CUSR0000SETA02", weight: 2.1),
        ComponentSeries(category: "New Vehicles", id: "CUSR0000SETA01", weight: 3.6),
        ComponentSeries(category: "Food at Home", id: "CUSR0000SAF11", weight: 8.2),
        ComponentSeries(category: "Food Away", id: "CUSR0000SEFV", weight: 5.7),
        ComponentSeries(category: "Electricity", id: "CUSR0000SEHF01", weight: 2.8),
        ComponentSeries(category: "Utility Gas", id: "CUSR0000SEHF02", weight: 0.7),
        ComponentSeries(category: "Medical Care", id: "CPIMEDSL", weight: 8.1),
        ComponentSeries(category: "Apparel", id: "CPIAPPSL", weight: 2.5),
        ComponentSeries(category: "Recreation", id: "CPIRECSL", weight: 5.3),
        ComponentSeries(category: "Education & Comm", id: "CPIEDUSL", weight: 5.5),
    ]

    private func fetchUSSnapshot(on req: Request) async throws -> MacroProviderResult {
        let now = Date()
        var points: [MacroSeriesPointRecord] = []
        var gauges: [InflationGaugeDTO] = []
        var headline: InflationGaugeDTO?
        var asOf = ""

        for series in Self.usGaugeSeries {
            let observations = try await fetchObservations(
                seriesID: series.id,
                yoy: series.yoy,
                observationStart: Self.monthlyObservationStart,
                on: req
            )
            guard let latest = observations.last else { continue }
            points += observations.map {
                MacroSeriesPointRecord(
                    country: MacroCountry.us.rawValue,
                    seriesKey: series.key.rawValue,
                    periodDate: $0.date,
                    value: $0.value,
                    unit: "percent",
                    source: name,
                    vintageDate: now
                )
            }
            let gauge = InflationGaugeDTO(
                name: series.label,
                nowValue: latest.value,
                officialValue: latest.value,
                officialAsOf: String(latest.date.prefix(7)),
                gap: nil
            )
            if series.key == .headlineCPI {
                headline = gauge
                asOf = latest.date
            }
            if series.key != .energyCPI, series.key != .foodCPI {
                gauges.append(gauge)
            }
        }

        guard let headline else {
            throw Abort(.badGateway, reason: "FRED returned no observations for CPIAUCSL.")
        }

        for series in Self.usYieldSeries {
            let observations = try await fetchObservations(
                seriesID: series.id,
                yoy: false,
                observationStart: Self.dailyObservationStart,
                on: req
            )
            points += observations.suffix(260).map {
                MacroSeriesPointRecord(
                    country: MacroCountry.us.rawValue,
                    seriesKey: series.key.rawValue,
                    periodDate: $0.date,
                    value: $0.value,
                    unit: "percent",
                    source: name,
                    vintageDate: now
                )
            }
        }

        var components: [InflationComponentDTO] = []
        var moverCandidates: [(mover: TopMoverDTO, magnitude: Double)] = []
        for component in Self.usComponentSeries {
            let observations = try await fetchObservations(
                seriesID: component.id,
                yoy: true,
                observationStart: Self.monthlyObservationStart,
                on: req
            )
            guard let latest = observations.last else { continue }
            components.append(
                InflationComponentDTO(
                    category: component.category,
                    ourYoY: latest.value,
                    blsYoY: latest.value,
                    cpiWeight: component.weight
                )
            )
            let previous = observations.count >= 2 ? observations[observations.count - 2].value : nil
            let direction: String = if let previous {
                latest.value > previous ? "up" : (latest.value < previous ? "down" : "flat")
            } else {
                latest.value >= 0 ? "up" : "down"
            }
            moverCandidates.append((
                TopMoverDTO(
                    category: component.category,
                    changeYoY: latest.value,
                    weight: component.weight,
                    direction: direction
                ),
                abs(latest.value)
            ))
        }
        let topMovers = moverCandidates
            .sorted { $0.magnitude > $1.magnitude }
            .prefix(6)
            .map(\.mover)

        for item in MacroItemsCatalog.items(for: .us) {
            guard case let .fredSeries(seriesID) = item.sourceRef else { continue }
            let observations = try await fetchObservations(
                seriesID: seriesID,
                yoy: false,
                observationStart: Self.monthlyObservationStart,
                on: req
            )
            points += observations.map {
                MacroSeriesPointRecord(
                    country: MacroCountry.us.rawValue,
                    seriesKey: MacroSeriesKey.itemKey(item.id),
                    periodDate: $0.date,
                    value: $0.value,
                    unit: item.unit,
                    source: name,
                    vintageDate: now
                )
            }
        }

        // Housing + economy hub series (lite). Failures are isolated per series.
        points += try await fetchHubSeriesPoints(country: .us, on: req)

        let nextPrint = await BLSCPIReleaseCalendar.nextPrint(
            after: now,
            lastOfficial: headline.officialValue,
            on: req
        )
        let snapshot = InflationSnapshotResponse(
            country: MacroCountry.us.rawValue,
            currency: MacroCountry.us.currency,
            asOf: asOf,
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: "BLS/BEA via FRED (\(String(asOf.prefix(7))))",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: Array(topMovers),
            notes: nil,
            nextPrintCountdown: nextPrint
        )
        return MacroProviderResult(snapshot: snapshot, points: points)
    }

    // MARK: - Housing / economy hub series (FRED)

    struct HubSeries {
        let key: MacroSeriesKey
        let id: String
        let yoy: Bool
        let unit: String
        let observationStart: String
    }

    /// US lite hubs: HPI, mortgage, rent, starts, supply, labor, GDP, NBER, Fed funds.
    private static let usHubSeries: [HubSeries] = [
        HubSeries(key: .hpiYoY, id: "CSUSHPISA", yoy: true, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .mortgageRate, id: "MORTGAGE30US", yoy: false, unit: "percent", observationStart: dailyObservationStart),
        HubSeries(key: .rentYoY, id: "CUSR0000SEHA", yoy: true, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .housingStarts, id: "HOUST", yoy: false, unit: "thousands", observationStart: monthlyObservationStart),
        HubSeries(key: .monthsSupply, id: "MSACSR", yoy: false, unit: "months", observationStart: monthlyObservationStart),
        HubSeries(key: .unemployment, id: "UNRATE", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .gdpGrowth, id: "A191RL1Q225SBEA", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .payrolls, id: "PAYEMS", yoy: false, unit: "thousands", observationStart: monthlyObservationStart),
        HubSeries(key: .initialClaims, id: "ICSA", yoy: false, unit: "claims", observationStart: dailyObservationStart),
        HubSeries(key: .policyRate, id: "DFEDTARU", yoy: false, unit: "percent", observationStart: dailyObservationStart),
        HubSeries(key: .nberRecession, id: "USREC", yoy: false, unit: "flag", observationStart: monthlyObservationStart),
        HubSeries(key: .govBond10Y, id: "DGS10", yoy: false, unit: "percent", observationStart: dailyObservationStart),
        HubSeries(key: .consumerConfidence, id: "UMCSENT", yoy: false, unit: "index", observationStart: monthlyObservationStart),
        HubSeries(key: .wageGrowth, id: "CES0500000003", yoy: true, unit: "percent", observationStart: monthlyObservationStart),
    ]

    /// EA lite hubs via FRED mirrors (Eurostat remains primary for HICP).
    private static let eaHubSeries: [HubSeries] = [
        HubSeries(key: .hpiYoY, id: "QEUR628BIS", yoy: true, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .unemployment, id: "LRHUTTTTEZM156S", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .gdpGrowth, id: "NAEXKP01EZQ657S", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .policyRate, id: "ECBDFR", yoy: false, unit: "percent", observationStart: dailyObservationStart),
        HubSeries(key: .mortgageRate, id: "IRLTCT01EZM156N", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
    ]

    /// Euro-area member hubs via FRED OECD/BIS mirrors. Fallback only —
    /// Eurostat + ECB are primary. Series ids follow the per-country families
    /// (`LRHUTTTT<CC>M156S`, `NAEXKP01<CC>Q657S`, `IRLTLT01<CC>M156N`,
    /// `Q<CC>N628BIS`); a discontinued id is skipped by the best-effort loop in
    /// `fetchHubSeriesPoints` rather than failing the ingest.
    static func euroMemberHubSeries(_ code: String) -> [HubSeries] {
        [
            HubSeries(key: .unemployment, id: "LRHUTTTT\(code)M156S", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
            HubSeries(key: .gdpGrowth, id: "NAEXKP01\(code)Q657S", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
            HubSeries(key: .govBond10Y, id: "IRLTLT01\(code)M156N", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
            HubSeries(key: .hpiYoY, id: "Q\(code)N628BIS", yoy: true, unit: "percent", observationStart: monthlyObservationStart),
            HubSeries(key: .policyRate, id: "ECBDFR", yoy: false, unit: "percent", observationStart: dailyObservationStart),
        ]
    }

    /// BR lite hubs via FRED OECD mirrors (IBGE/BCB preferred when wired).
    private static let brHubSeries: [HubSeries] = [
        HubSeries(key: .unemployment, id: "LRHUTTTTBRM156S", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .gdpGrowth, id: "NAEXKP01BRQ657S", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
        HubSeries(key: .policyRate, id: "INTDSRBRM193N", yoy: false, unit: "percent", observationStart: monthlyObservationStart),
    ]

    /// Fetches housing/economy series for a country. Best-effort per series —
    /// one bad FRED id never aborts the whole hub ingest.
    func fetchHubSeriesPoints(country: MacroCountry, on req: Request) async throws -> [MacroSeriesPointRecord] {
        let seriesList: [HubSeries] = switch country {
        case .us: Self.usHubSeries
        case .ea: Self.eaHubSeries
        case .br: Self.brHubSeries
        case .pt, .es, .de, .fr, .it: Self.euroMemberHubSeries(country.rawValue)
        }
        let now = Date()
        var points: [MacroSeriesPointRecord] = []
        for series in seriesList {
            do {
                let observations = try await fetchObservations(
                    seriesID: series.id,
                    yoy: series.yoy,
                    observationStart: series.observationStart,
                    on: req
                )
                let limited = series.observationStart == Self.dailyObservationStart
                    ? Array(observations.suffix(260))
                    : observations
                points += limited.map {
                    MacroSeriesPointRecord(
                        country: country.rawValue,
                        seriesKey: series.key.rawValue,
                        periodDate: $0.date,
                        value: $0.value,
                        unit: series.unit,
                        source: name,
                        vintageDate: now
                    )
                }
            } catch {
                req.logger.warning("macro_hub_fred_series_failed country=\(country.rawValue) id=\(series.id) error=\(error)")
            }
        }
        // EA rent YoY from HICP housing division when available via separate path — skip here.
        return points
    }

    // MARK: - International fallback (OECD series mirrored on FRED)

    /// Headline CPI YoY only — a thinner snapshot than the primary providers.
    /// NOTE: OECD mirrors on FRED have seen discontinuations since the 2024
    /// OECD data revamp; verified working IDs are pinned here.
    private static let internationalHeadline: [MacroCountry: (id: String, label: String)] = [
        .br: ("CPALTT01BRM659N", "CPI Brazil (OECD via FRED)"),
        .pt: ("CPALTT01PTM659N", "CPI Portugal (OECD via FRED)"),
        .es: ("CPALTT01ESM659N", "CPI Spain (OECD via FRED)"),
        .de: ("CPALTT01DEM659N", "CPI Germany (OECD via FRED)"),
        .fr: ("CPALTT01FRM659N", "CPI France (OECD via FRED)"),
        .it: ("CPALTT01ITM659N", "CPI Italy (OECD via FRED)"),
        .ea: ("CPHPTT01EZM659N", "HICP Euro Area (OECD via FRED)"),
    ]

    private func fetchInternationalSnapshot(country: MacroCountry, on req: Request) async throws -> MacroProviderResult {
        guard let series = Self.internationalHeadline[country] else {
            throw Abort(.serviceUnavailable, reason: "FRED fallback has no headline series for \(country.rawValue).")
        }
        let now = Date()
        let observations = try await fetchObservations(
            seriesID: series.id,
            yoy: false, // OECD *659N series are already YoY growth rates
            observationStart: Self.monthlyObservationStart,
            on: req
        )
        guard let latest = observations.last else {
            throw Abort(.badGateway, reason: "FRED returned no observations for \(series.id).")
        }
        let points = observations.map {
            MacroSeriesPointRecord(
                country: country.rawValue,
                seriesKey: MacroSeriesKey.headlineCPI.rawValue,
                periodDate: $0.date,
                value: $0.value,
                unit: "percent",
                source: name,
                vintageDate: now
            )
        }
        let headline = InflationGaugeDTO(
            name: series.label,
            nowValue: latest.value,
            officialValue: latest.value,
            officialAsOf: String(latest.date.prefix(7))
        )
        let snapshot = InflationSnapshotResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: latest.date,
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: "OECD via FRED (\(String(latest.date.prefix(7))))",
            headline: headline,
            gauges: [headline],
            components: [],
            topMovers: []
        )
        return MacroProviderResult(snapshot: snapshot, points: points)
    }

    // MARK: - HTTP

    struct Observation: Equatable {
        let date: String
        let value: Double
    }

    func fetchObservations(
        seriesID: String,
        yoy: Bool,
        observationStart: String,
        on req: Request
    ) async throws -> [Observation] {
        var query: [(String, String)] = [
            ("series_id", seriesID),
            ("api_key", apiKey),
            ("file_type", "json"),
            ("observation_start", observationStart),
        ]
        if yoy {
            query.append(("units", "pc1"))
        }
        let uri = try makeURI(path: "/fred/series/observations", query: query)
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(20)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "FRED request for \(seriesID) failed with status \(response.status.code).")
        }
        let decoded: FREDObservationsResponse
        do {
            decoded = try response.content.decode(FREDObservationsResponse.self)
        } catch {
            throw Abort(.badGateway, reason: "Failed to decode FRED response for \(seriesID).")
        }
        return Self.parseObservations(decoded)
    }

    /// FRED encodes missing observations as ".". Rounded to 2dp to keep
    /// vintage comparisons stable.
    static func parseObservations(_ response: FREDObservationsResponse) -> [Observation] {
        response.observations.compactMap { raw in
            guard let value = Double(raw.value) else { return nil }
            return Observation(date: raw.date, value: (value * 100).rounded() / 100)
        }
    }

    private func makeURI(path: String, query: [(String, String)]) throws -> URI {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmed + path) else {
            throw Abort(.internalServerError, reason: "Invalid FRED base URL configuration.")
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build FRED request URL.")
        }
        return URI(string: url.absoluteString)
    }
}

struct FREDObservationsResponse: Decodable {
    struct RawObservation: Decodable {
        let date: String
        let value: String
    }

    let observations: [RawObservation]
}

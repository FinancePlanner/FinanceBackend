import Foundation
import StockPlanShared
import Vapor

/// ECB Data Portal enrichment: layers the euro-area policy rate on top of the
/// Eurostat (or FRED fallback) result for every euro-area country.
///
/// Keyless and free — `https://data-api.ecb.europa.eu/service/data/<flow>/<key>`
/// with `format=jsondata` returns SDMX-JSON. The rate is an area-wide series, so
/// every euro-area member gets the same values, which is correct: they share a
/// central bank.
///
/// Enrichment NEVER fails the refresh — on any error the input result is
/// returned unchanged.
struct ECBMacroEnrichment: MacroEnrichmentProviding {
    let name = "ecb"
    var baseURL: String = "https://data-api.ecb.europa.eu/service/data"
    /// Main refinancing operations, fixed rate — the headline ECB policy rate.
    var seriesPath: String = "/FM/B.U2.EUR.4F.KR.MRR_FR.LEV"
    var yearsBack: Int = 8

    var isEnabled: Bool {
        !baseURL.isEmpty && !seriesPath.isEmpty
    }

    func enrich(_ result: MacroProviderResult, country: MacroCountry, on req: Request) async -> MacroProviderResult {
        guard isEnabled, country.isEuroArea else { return result }
        do {
            let payload = try await fetchPayload(on: req)
            return Self.apply(payload: payload, to: result, country: country, providerName: name, now: Date())
        } catch {
            req.logger.warning(
                "ecb_enrichment failed for \(country.rawValue), serving snapshot without ECB policy rate error=\(String(describing: error))"
            )
            return result
        }
    }

    /// Pure merge — unit-testable. Replaces any policy-rate points already
    /// present (e.g. from the FRED fallback) so a country never carries two
    /// sources for the same series.
    static func apply(
        payload: SDMXJSONResponse,
        to result: MacroProviderResult,
        country: MacroCountry,
        providerName: String,
        now: Date
    ) -> MacroProviderResult {
        let observations = payload.observations()
        guard !observations.isEmpty else { return result }
        var merged = result
        merged.points.removeAll { $0.seriesKey == MacroSeriesKey.policyRate.rawValue }
        merged.points += observations.compactMap { observation in
            guard let date = EurostatMacroProvider.periodDate(observation.period) ?? Self.isoDate(observation.period)
            else { return nil }
            return MacroSeriesPointRecord(
                country: country.rawValue,
                seriesKey: MacroSeriesKey.policyRate.rawValue,
                periodDate: date,
                value: observation.value,
                unit: "percent",
                source: providerName,
                vintageDate: now
            )
        }
        return merged
    }

    /// ECB daily series report full `YYYY-MM-DD` periods, which the Eurostat
    /// month/quarter normaliser does not handle.
    static func isoDate(_ period: String) -> String? {
        let parts = period.split(separator: "-").map(String.init)
        guard parts.count == 3, parts[0].count == 4,
              let month = Int(parts[1]), let day = Int(parts[2]),
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        return String(format: "%@-%02d-%02d", parts[0], month, day)
    }

    private func fetchPayload(on req: Request) async throws -> SDMXJSONResponse {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmed + seriesPath) else {
            throw Abort(.internalServerError, reason: "Invalid ECB base URL configuration.")
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "jsondata"),
            URLQueryItem(name: "startPeriod", value: Self.startPeriod(yearsBack: yearsBack)),
        ]
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build ECB request URL.")
        }
        let response = try await req.client.get(URI(string: url.absoluteString)) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(30)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "ECB request failed with status \(response.status.code).")
        }
        // The portal answers with `application/vnd.sdmx.data+json`, which Vapor
        // has no content decoder for, so decode the raw body as JSON instead of
        // going through `content.decode`.
        guard var body = response.body, let bytes = body.readData(length: body.readableBytes) else {
            throw Abort(.badGateway, reason: "ECB returned an empty body.")
        }
        do {
            return try JSONDecoder().decode(SDMXJSONResponse.self, from: bytes)
        } catch {
            throw Abort(.badGateway, reason: "Failed to decode ECB SDMX-JSON response: \(String(reflecting: error))")
        }
    }

    static func startPeriod(yearsBack: Int, from date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date) - yearsBack
        return "\(year)-01-01"
    }
}

// MARK: - SDMX-JSON decoding

/// Minimal SDMX-JSON 1.0 decoder covering what the ECB Data Portal returns for
/// a single-series request: one `dataSets` entry whose `series` map holds
/// observations keyed by position, with the periods in
/// `structure.dimensions.observation`.
struct SDMXJSONResponse: Decodable {
    struct DataSet: Decodable {
        struct Series: Decodable {
            /// Observation position (as string) → [value, ...flags].
            let observations: [String: [Double?]]
        }

        let series: [String: Series]?
    }

    struct Structure: Decodable {
        struct Dimensions: Decodable {
            struct Dimension: Decodable {
                struct Value: Decodable {
                    let id: String?
                }

                let id: String?
                let values: [Value]
            }

            let observation: [Dimension]?
        }

        let dimensions: Dimensions?
    }

    let dataSets: [DataSet]
    let structure: Structure?

    struct Observation {
        let period: String
        let value: Double
    }

    /// Flattens the first series into ordered (period, value) pairs.
    func observations() -> [Observation] {
        guard let series = dataSets.first?.series?.sorted(by: { $0.key < $1.key }).first?.value else { return [] }
        let periods = structure?.dimensions?.observation?
            .first { ($0.id ?? "TIME_PERIOD") == "TIME_PERIOD" }?
            .values
            .compactMap(\.id) ?? []
        guard !periods.isEmpty else { return [] }
        return series.observations
            .compactMap { key, values -> (Int, Double)? in
                guard let position = Int(key), let value = values.first ?? nil else { return nil }
                return (position, value)
            }
            .sorted { $0.0 < $1.0 }
            .compactMap { position, value in
                guard position < periods.count else { return nil }
                return Observation(period: periods[position], value: value)
            }
    }
}

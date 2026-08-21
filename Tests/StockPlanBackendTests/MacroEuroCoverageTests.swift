import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

/// Covers the euro-area expansion: Eurostat hub datasets, the ECB SDMX-JSON
/// policy-rate enrichment, and the period normalisers both rely on.
@Suite("Macro Euro Coverage Tests")
struct MacroEuroCoverageTests {
    // MARK: - Period normalisation

    @Test("Eurostat period normalisation handles monthly, quarterly and annual forms")
    func eurostatPeriodDates() {
        #expect(EurostatMacroProvider.periodDate("2026-04") == "2026-04-01")
        #expect(EurostatMacroProvider.periodDate("2026-Q1") == "2026-01-01")
        #expect(EurostatMacroProvider.periodDate("2026-Q3") == "2026-07-01")
        #expect(EurostatMacroProvider.periodDate("2026-Q4") == "2026-10-01")
        #expect(EurostatMacroProvider.periodDate("2026") == "2026-01-01")
        #expect(EurostatMacroProvider.periodDate("2026-Q5") == nil)
        #expect(EurostatMacroProvider.periodDate("2026-13") == nil)
        #expect(EurostatMacroProvider.periodDate("nonsense") == nil)
    }

    @Test("ECB daily periods normalise to ISO dates")
    func ecbIsoDates() {
        #expect(ECBMacroEnrichment.isoDate("2026-06-12") == "2026-06-12")
        #expect(ECBMacroEnrichment.isoDate("2026-6-2") == "2026-06-02")
        #expect(ECBMacroEnrichment.isoDate("2026-06") == nil)
        #expect(ECBMacroEnrichment.isoDate("") == nil)
    }

    // MARK: - Eurostat hub datasets

    /// Quarterly hub shape: every dimension except `time` is filtered to one
    /// category, which is what `JSONStatDataset.value(at:)` requires.
    private let quarterlyHubFixture = """
    {
        "version": "2.0",
        "class": "dataset",
        "id": ["freq", "purchase", "unit", "geo", "time"],
        "size": [1, 1, 1, 1, 3],
        "dimension": {
            "freq": {"category": {"index": {"Q": 0}}},
            "purchase": {"category": {"index": {"TOTAL": 0}}},
            "unit": {"category": {"index": {"RCH_A_AVG": 0}}},
            "geo": {"category": {"index": {"DE": 0}}},
            "time": {"category": {"index": {"2025-Q3": 0, "2025-Q4": 1, "2026-Q1": 2}}}
        },
        "value": {"0": 3.1, "2": 4.7}
    }
    """

    @Test("Eurostat hub points map quarterly periods and skip gaps")
    func eurostatHubPoints() throws {
        let dataset = try JSONDecoder().decode(JSONStatDataset.self, from: Data(quarterlyHubFixture.utf8))
        let hub = EurostatMacroProvider.HubDataset(
            key: .hpiYoY,
            path: "/prc_hpi_q",
            filters: [("purchase", "TOTAL"), ("unit", "RCH_A")],
            unit: "percent",
            euroAreaGeo: "EA20"
        )
        let points = EurostatMacroProvider.hubPoints(
            dataset: dataset,
            hub: hub,
            country: .de,
            providerName: "eurostat",
            now: Date()
        )
        #expect(points.count == 2)
        #expect(points[0].country == "DE")
        #expect(points[0].seriesKey == "hpi_yoy")
        #expect(points[0].periodDate == "2025-07-01")
        #expect(points[0].value == 3.1)
        #expect(points[1].periodDate == "2026-01-01")
        #expect(points[1].value == 4.7)
    }

    @Test("hub dataset catalog covers the promised indicators")
    func hubDatasetCatalog() {
        let keys = Set(EurostatMacroProvider.hubDatasets.map(\.key))
        #expect(keys.contains(.unemployment))
        #expect(keys.contains(.gdpGrowth))
        #expect(keys.contains(.govBond10Y))
        #expect(keys.contains(.hpiYoY))
        #expect(keys.contains(.consumerConfidence))
        #expect(keys.contains(.wageGrowth))
    }

    @Test("hub datasets carry the euro-area geo code each one actually publishes")
    func euroAreaGeoPerDataset() {
        // Verified against the live dimension listings: une_rt_m publishes only
        // EA21, irt_lt_mcby_m only EA, the rest carry EA20.
        let expected: [MacroSeriesKey: String] = [
            .unemployment: "EA21",
            .gdpGrowth: "EA20",
            .govBond10Y: "EA",
            .hpiYoY: "EA20",
            .consumerConfidence: "EA20",
            .wageGrowth: "EA20",
        ]
        for hub in EurostatMacroProvider.hubDatasets {
            #expect(hub.euroAreaGeo == expected[hub.key], "unexpected EA geo for \(hub.key.rawValue)")
            #expect(hub.geo(for: .ea) == expected[hub.key])
            #expect(hub.geo(for: .de) == "DE")
            #expect(hub.geo(for: .pt) == "PT")
        }
    }

    @Test("Eurostat supports every euro-area country and geo maps EA to EA20")
    func eurostatSupport() {
        let provider = EurostatMacroProvider()
        for country in MacroCountry.allCases where country.isEuroArea {
            #expect(provider.supports(country))
        }
        #expect(!provider.supports(.us))
        #expect(!provider.supports(.br))
        #expect(MacroCountry.ea.eurostatGeo == "EA20")
        #expect(MacroCountry.de.eurostatGeo == "DE")
    }

    // MARK: - ECB SDMX-JSON

    /// Trimmed real-shape ECB response: one series, three observations, one of
    /// which is null.
    private let sdmxFixture = """
    {
        "dataSets": [{
            "series": {
                "0:0:0:0:0:0:0": {
                    "observations": {
                        "0": [4.5, 0],
                        "1": [null, 0],
                        "2": [3.15, 0]
                    }
                }
            }
        }],
        "structure": {
            "dimensions": {
                "observation": [{
                    "id": "TIME_PERIOD",
                    "values": [{"id": "2024-06-12"}, {"id": "2025-01-05"}, {"id": "2026-03-11"}]
                }]
            }
        }
    }
    """

    @Test("ECB SDMX-JSON flattens the first series in period order and skips nulls")
    func sdmxObservations() throws {
        let payload = try JSONDecoder().decode(SDMXJSONResponse.self, from: Data(sdmxFixture.utf8))
        let observations = payload.observations()
        #expect(observations.count == 2)
        #expect(observations[0].period == "2024-06-12")
        #expect(observations[0].value == 4.5)
        #expect(observations[1].period == "2026-03-11")
        #expect(observations[1].value == 3.15)
    }

    @Test("ECB enrichment replaces fallback policy-rate points")
    func ecbEnrichmentReplacesPolicyRate() throws {
        let payload = try JSONDecoder().decode(SDMXJSONResponse.self, from: Data(sdmxFixture.utf8))
        let now = Date()
        let existing = MacroSeriesPointRecord(
            country: "ES",
            seriesKey: MacroSeriesKey.policyRate.rawValue,
            periodDate: "2020-01-01",
            value: 0.0,
            unit: "percent",
            source: "fred",
            vintageDate: now
        )
        let unemployment = MacroSeriesPointRecord(
            country: "ES",
            seriesKey: MacroSeriesKey.unemployment.rawValue,
            periodDate: "2026-01-01",
            value: 11.2,
            unit: "percent",
            source: "eurostat",
            vintageDate: now
        )
        let input = MacroProviderResult(
            snapshot: Self.emptySnapshot(country: .es),
            points: [existing, unemployment]
        )

        let merged = ECBMacroEnrichment.apply(
            payload: payload,
            to: input,
            country: .es,
            providerName: "ecb",
            now: now
        )

        let policyPoints = merged.points.filter { $0.seriesKey == MacroSeriesKey.policyRate.rawValue }
        #expect(policyPoints.count == 2)
        #expect(policyPoints.allSatisfy { $0.source == "ecb" })
        #expect(policyPoints.allSatisfy { $0.country == "ES" })
        // Non-policy series are left untouched.
        #expect(merged.points.contains { $0.seriesKey == MacroSeriesKey.unemployment.rawValue })
    }

    @Test("ECB enrichment leaves non-euro countries and empty payloads unchanged")
    func ecbEnrichmentNoOps() throws {
        let now = Date()
        let input = MacroProviderResult(snapshot: Self.emptySnapshot(country: .us), points: [])
        let empty = try JSONDecoder().decode(
            SDMXJSONResponse.self,
            from: Data(#"{"dataSets": [], "structure": null}"#.utf8)
        )
        let merged = ECBMacroEnrichment.apply(
            payload: empty,
            to: input,
            country: .us,
            providerName: "ecb",
            now: now
        )
        #expect(merged.points.isEmpty)
    }

    // MARK: - Country metadata

    @Test("every tax jurisdiction is a macro country with a currency and name")
    func taxJurisdictionsAreMacroCountries() {
        for jurisdiction in TaxJurisdiction.allCases {
            let country = MacroCountry(query: jurisdiction.rawValue)
            #expect(country != nil, "\(jurisdiction.rawValue) must have macro coverage")
            #expect(country?.currency.isEmpty == false)
            #expect(country?.displayName.isEmpty == false)
        }
    }

    private static func emptySnapshot(country: MacroCountry) -> InflationSnapshotResponse {
        let gauge = InflationGaugeDTO(name: "Headline", nowValue: 2.0, officialValue: 2.0, officialAsOf: "2026-01")
        return InflationSnapshotResponse(
            country: country.rawValue,
            currency: country.currency,
            asOf: "2026-01-01",
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            source: "test",
            headline: gauge,
            gauges: [gauge],
            components: [],
            topMovers: []
        )
    }
}

import Foundation
import StockPlanShared

/// Legacy Phase-1 stub data, kept as the last-resort fallback while providers
/// are proven out in production (`MACRO_ALLOW_STUB_FALLBACK=true`). Every
/// response is marked `source: "stub"` so clients can detect it. Flip the
/// flag off once live data is verified, then delete this file.
enum MacroStubData {
    static func snapshot(country: MacroCountry) -> InflationSnapshotResponse {
        let now = ISO8601DateFormatter().string(from: Date())
        switch country {
        case .us: return usSnapshot(now: now)
        case .br: return brazilSnapshot(now: now)
        case .pt, .es, .de, .fr, .it, .ea: return euroAreaSnapshot(now: now, country: country)
        }
    }

    static func series(country: MacroCountry, seriesKey: String) -> MacroSeriesResponse {
        let baseValue = switch country {
        case .us: 1.71
        case .br: 4.3
        case .pt, .es, .de, .fr, .it, .ea: 2.3
        }
        let points: [MacroSeriesPoint] = [
            .init(date: "2026-02-01", value: baseValue, series: seriesKey),
            .init(date: "2026-03-01", value: baseValue + 0.01, series: seriesKey),
            .init(date: "2026-04-01", value: baseValue + 0.02, series: seriesKey),
            .init(date: "2026-05-01", value: baseValue + 0.03, series: seriesKey),
            .init(date: "2026-06-01", value: baseValue + 0.04, series: seriesKey),
            .init(date: "2026-07-01", value: baseValue + 0.05, series: seriesKey),
        ]
        return MacroSeriesResponse(series: seriesKey, points: points, country: country.rawValue, unit: "percent")
    }

    static func fedWatch() -> FedWatchResponse {
        let now = Date()
        let corePCE = MacroIndicatorDTO(
            name: "Core PCE",
            value: 3.41,
            asOf: "2026-05-01",
            previousValue: 3.38,
            changeFromPrevious: 0.03,
            source: "stub"
        )
        return FedWatchResponse(
            asOf: "2026-05-01",
            updatedAt: ISO8601DateFormatter().string(from: now),
            source: "stub",
            corePCE: corePCE,
            distanceToTarget: 1.41,
            trimmedMeanCPI: MacroIndicatorDTO(name: "Trimmed Mean CPI", value: 2.41, asOf: "2026-05-01", source: "stub"),
            treasury2Y: MacroIndicatorDTO(name: "2Y Treasury", value: 4.19, asOf: "2026-07-07", source: "stub"),
            treasury10Y: MacroIndicatorDTO(name: "10Y Treasury", value: 4.55, asOf: "2026-07-07", source: "stub"),
            spread10Y2Y: 0.36,
            real10Y: MacroIndicatorDTO(name: "Real 10Y (TIPS)", value: 0.48, asOf: "2026-07-07", source: "stub"),
            breakeven10Y: nil,
            nextFOMC: FOMCCalendar.nextMeeting(after: now),
            stance: "neutral"
        )
    }

    static func items(country: MacroCountry) -> MacroItemsResponse {
        let stubReadings: [String: (price: Double?, yoy: Double)] = [
            "eggs": (3.12, 4.1), "milk": (4.05, 2.2), "bread": (2.01, 1.4),
            "gasoline": (3.42, 21.3), "chicken": (2.08, 3.0), "ground-beef": (5.55, 4.6),
            "electricity": (0.182, 5.9), "coffee": (7.90, 6.2),
        ]
        let items = MacroItemsCatalog.items(for: country).map { item -> MacroItemDTO in
            let reading = stubReadings[item.id]
            return MacroItemDTO(
                id: item.id,
                name: item.name,
                emoji: item.emoji,
                country: country.rawValue,
                currency: country.currency,
                unit: item.unit,
                latestPrice: item.isPrice ? reading?.price : nil,
                changeYoY: reading?.yoy ?? 2.5,
                asOf: "2026-06-01",
                source: "stub",
                hasSeries: false
            )
        }
        return MacroItemsResponse(
            country: country.rawValue,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            items: items
        )
    }

    // MARK: - Snapshots (ported unchanged from the Phase-1 MacroService stubs,

    // except `source` is now "stub" for client detection)

    private static func usSnapshot(now: String) -> InflationSnapshotResponse {
        let headline = InflationGaugeDTO(
            name: "Nowflation CPI",
            nowValue: 1.74,
            officialValue: 4.2,
            officialAsOf: "2026-05",
            gap: -2.46,
            unit: "percent",
            colVariant: 1.47,
            cumulativeSinceBase: 33.9,
            basePeriod: "2018-01"
        )

        let gauges: [InflationGaugeDTO] = [
            headline,
            InflationGaugeDTO(name: "Core CPI (Nowflation Forecast)", nowValue: 2.87, officialValue: 2.9, officialAsOf: "2026-05", gap: -0.03),
            InflationGaugeDTO(name: "Supercore (svcs ex-shelter)", nowValue: 2.01, officialValue: nil, officialAsOf: nil, gap: nil),
            InflationGaugeDTO(name: "PCE (PCE-weighted gauge)", nowValue: 2.04, officialValue: 4.07, officialAsOf: "2026-05", gap: -2.03),
            InflationGaugeDTO(name: "Core PCE (Fed 2% target)", nowValue: 3.4, officialValue: 3.41, officialAsOf: "2026-05", gap: -0.01),
        ]

        let components: [InflationComponentDTO] = [
            .init(category: "Shelter: Rent", ourYoY: 0.8, blsYoY: 2.9, cpiWeight: 7.5),
            .init(category: "Shelter: Owned", ourYoY: 3.3, blsYoY: 3.3, cpiWeight: 26.5),
            .init(category: "Motor Fuel", ourYoY: 41.6, blsYoY: 41.6, cpiWeight: 3.0),
            .init(category: "Used Vehicles", ourYoY: -2.0, blsYoY: -2.0, cpiWeight: 2.1),
            .init(category: "New Vehicles", ourYoY: 0.2, blsYoY: 0.2, cpiWeight: 3.6),
            .init(category: "Food at Home", ourYoY: 2.7, blsYoY: 2.7, cpiWeight: 8.2),
            .init(category: "Food Away", ourYoY: 3.5, blsYoY: 3.5, cpiWeight: 5.7),
            .init(category: "Electricity", ourYoY: 8.4, blsYoY: 5.9, cpiWeight: 2.8),
            .init(category: "Utility Gas", ourYoY: -5.6, blsYoY: 3.0, cpiWeight: 0.7),
            .init(category: "Medical Care", ourYoY: 2.6, blsYoY: 2.6, cpiWeight: 8.1),
            .init(category: "Apparel", ourYoY: 4.8, blsYoY: 4.8, cpiWeight: 2.5),
            .init(category: "Recreation", ourYoY: 2.6, blsYoY: 2.6, cpiWeight: 5.3),
            .init(category: "Education & Comm", ourYoY: 0.8, blsYoY: 0.8, cpiWeight: 5.5),
            .init(category: "Everything Else", ourYoY: 2.8, blsYoY: 2.8, cpiWeight: 18.5),
        ]

        let topMovers: [TopMoverDTO] = [
            .init(category: "Utility Gas", changeYoY: -5.6, changeMoM: nil, weight: 0.7, direction: "down"),
            .init(category: "Food at Home", changeYoY: 2.7, changeMoM: nil, weight: 8.2, direction: "up"),
            .init(category: "Apparel", changeYoY: 4.8, changeMoM: nil, weight: 2.5, direction: "up"),
            .init(category: "Shelter: Owned", changeYoY: 3.3, changeMoM: nil, weight: 26.5, direction: "up"),
            .init(category: "Everything Else", changeYoY: 2.8, changeMoM: nil, weight: 18.5, direction: "up"),
            .init(category: "Motor Fuel", changeYoY: 41.6, changeMoM: -12.12, weight: 3.0, direction: "down"),
        ]

        return InflationSnapshotResponse(
            country: "US",
            currency: "USD",
            asOf: "2026-07-08",
            updatedAt: now,
            source: "stub",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: topMovers,
            notes: "Stub data — configure FRED_API_KEY for live US macro data.",
            nextPrintCountdown: BLSCPIReleaseCalendar.nextPrint(after: Date(), lastOfficial: 4.2)
        )
    }

    private static func brazilSnapshot(now: String) -> InflationSnapshotResponse {
        let headline = InflationGaugeDTO(
            name: "IPCA",
            nowValue: 4.52,
            officialValue: 4.52,
            officialAsOf: "2026-06",
            gap: nil,
            unit: "percent"
        )

        let gauges: [InflationGaugeDTO] = [
            headline,
            InflationGaugeDTO(name: "IPCA Ex-Food and Energy", nowValue: 3.8, officialValue: 3.8, officialAsOf: "2026-06"),
            InflationGaugeDTO(name: "IPCA Food", nowValue: 6.1, officialValue: 6.1, officialAsOf: "2026-06"),
        ]

        let components: [InflationComponentDTO] = [
            .init(category: "Alimentação e bebidas", ourYoY: 6.1, blsYoY: 6.1),
            .init(category: "Habitação", ourYoY: 3.9, blsYoY: 3.9),
            .init(category: "Transportes", ourYoY: 2.8, blsYoY: 2.8),
            .init(category: "Saúde e cuidados pessoais", ourYoY: 5.2, blsYoY: 5.2),
            .init(category: "Despesas pessoais", ourYoY: 4.1, blsYoY: 4.1),
            .init(category: "Educação", ourYoY: 5.5, blsYoY: 5.5),
            .init(category: "Comunicação", ourYoY: 1.2, blsYoY: 1.2),
            .init(category: "Vestuário", ourYoY: 3.4, blsYoY: 3.4),
        ]

        let topMovers: [TopMoverDTO] = [
            .init(category: "Alimentação e bebidas", changeYoY: 6.1, changeMoM: 0.4, weight: nil, direction: "up"),
            .init(category: "Transportes", changeYoY: 2.8, changeMoM: -0.3, weight: nil, direction: "up"),
            .init(category: "Habitação", changeYoY: 3.9, changeMoM: 0.1, weight: nil, direction: "up"),
            .init(category: "Saúde e cuidados pessoais", changeYoY: 5.2, changeMoM: 0.2, weight: nil, direction: "up"),
        ]

        return InflationSnapshotResponse(
            country: "BR",
            currency: "BRL",
            asOf: "2026-07-08",
            updatedAt: now,
            source: "stub",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: topMovers,
            notes: "Dados de demonstração — IPCA acumulado em 12 meses.",
            nextPrintCountdown: nil
        )
    }

    private static func euroAreaSnapshot(now: String, country: MacroCountry) -> InflationSnapshotResponse {
        let isPortugal = country == .pt

        let headline = InflationGaugeDTO(
            name: isPortugal ? "HICP Portugal" : "HICP Euro Area",
            nowValue: 2.5,
            officialValue: 2.5,
            officialAsOf: "2026-06",
            gap: nil,
            unit: "percent"
        )

        let gauges: [InflationGaugeDTO] = [
            headline,
            InflationGaugeDTO(name: "HICP Core (ex food & energy)", nowValue: 2.8, officialValue: 2.8, officialAsOf: "2026-06"),
            InflationGaugeDTO(name: "HICP Energy", nowValue: -1.2, officialValue: -1.2, officialAsOf: "2026-06"),
        ]

        let components: [InflationComponentDTO] = [
            .init(category: "Food and non-alcoholic beverages", ourYoY: 3.1, blsYoY: 3.1),
            .init(category: "Housing, water, electricity, gas", ourYoY: 2.9, blsYoY: 2.9),
            .init(category: "Transport", ourYoY: 1.4, blsYoY: 1.4),
            .init(category: "Restaurants and hotels", ourYoY: 4.2, blsYoY: 4.2),
            .init(category: "Recreation and culture", ourYoY: 2.1, blsYoY: 2.1),
        ]

        let topMovers: [TopMoverDTO] = [
            .init(category: "Restaurants and hotels", changeYoY: 4.2, direction: "up"),
            .init(category: "Food and non-alcoholic beverages", changeYoY: 3.1, direction: "up"),
            .init(category: "Housing, water, electricity, gas", changeYoY: 2.9, direction: "up"),
            .init(category: "Energy", changeYoY: -1.2, direction: "down"),
        ]

        return InflationSnapshotResponse(
            country: country.rawValue,
            currency: "EUR",
            asOf: "2026-07-08",
            updatedAt: now,
            source: "stub",
            headline: headline,
            gauges: gauges,
            components: components,
            topMovers: topMovers,
            notes: isPortugal
                ? "Dados de demonstração — HICP Portugal."
                : "Stub data — HICP Euro Area.",
            nextPrintCountdown: nil
        )
    }
}

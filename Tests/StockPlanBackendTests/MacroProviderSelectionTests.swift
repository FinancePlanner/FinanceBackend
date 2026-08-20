@testable import StockPlanBackend
import Testing

@Suite("Macro Provider Selection Tests")
struct MacroProviderSelectionTests {
    @Test("macro disabled turns every country off")
    func macroDisabled() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: false, hasFREDKey: true, nowflationConfigured: true)
        for country in MacroCountry.allCases {
            #expect(plan[country]?.primary == .disabled)
            #expect(plan[country]?.nowflationEnrichment == false)
        }
    }

    @Test("full configuration: FRED primary US with Nowflation, official providers elsewhere with FRED fallback")
    func fullConfiguration() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: true, nowflationConfigured: true)
        #expect(plan[.us] == .init(primary: .fred, fallback: nil, nowflationEnrichment: true))
        #expect(plan[.br] == .init(primary: .ibge, fallback: .fred, nowflationEnrichment: false))
        let euro = MacroProviderPlanSelection.CountryPlan(
            primary: .eurostat,
            fallback: .fred,
            nowflationEnrichment: false,
            ecbEnrichment: true
        )
        for country in MacroCountry.allCases where country.isEuroArea {
            #expect(plan[country] == euro)
        }
    }

    @Test("every tax jurisdiction has a macro plan")
    func taxJurisdictionCoverage() throws {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: true, nowflationConfigured: true)
        for code in ["US", "PT", "ES", "DE", "FR", "IT"] {
            let country = MacroCountry(query: code)
            #expect(country != nil, "\(code) must be a supported macro country")
            #expect(try plan[#require(country)]?.primary != .disabled, "\(code) must have a live primary provider")
        }
    }

    @Test("no FRED key: US disabled, intl providers keep working without fallback")
    func noFREDKey() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: false, nowflationConfigured: true)
        #expect(plan[.us]?.primary == .disabled)
        #expect(plan[.us]?.nowflationEnrichment == false) // enrichment needs a FRED base
        #expect(plan[.br] == .init(primary: .ibge, fallback: nil, nowflationEnrichment: false))
        #expect(plan[.pt] == .init(
            primary: .eurostat,
            fallback: nil,
            nowflationEnrichment: false,
            ecbEnrichment: true
        ))
    }

    @Test("FRED without Nowflation: US live but official-only")
    func fredOnly() {
        let plan = MacroProviderPlanSelection.plan(macroEnabled: true, hasFREDKey: true, nowflationConfigured: false)
        #expect(plan[.us] == .init(primary: .fred, fallback: nil, nowflationEnrichment: false))
    }

    @Test("country query parsing accepts aliases and rejects unknowns")
    func countryParsing() {
        #expect(MacroCountry(query: "us") == .us)
        #expect(MacroCountry(query: " BR ") == .br)
        #expect(MacroCountry(query: "EURO") == .ea)
        #expect(MacroCountry(query: "EZ") == .ea)
        #expect(MacroCountry(query: "de") == .de)
        #expect(MacroCountry(query: " ES ") == .es)
        #expect(MacroCountry(query: "FR") == .fr)
        #expect(MacroCountry(query: "it") == .it)
        #expect(MacroCountry(query: "XX") == nil)
        #expect(MacroCountry(query: nil) == nil)
    }

    @Test("series key resolution maps legacy names")
    func seriesKeyResolution() {
        #expect(MacroSeriesKey.resolve("nowflation_cpi") == "nowflation_gauge")
        #expect(MacroSeriesKey.resolve("official_cpi") == "headline_cpi")
        #expect(MacroSeriesKey.resolve("headline") == "headline_cpi")
        #expect(MacroSeriesKey.resolve("core") == "core_cpi")
        #expect(MacroSeriesKey.resolve(nil) == "headline_cpi")
        #expect(MacroSeriesKey.resolve("dgs10") == "dgs10")
        #expect(MacroSeriesKey.itemKey("eggs") == "item.eggs")
    }
}

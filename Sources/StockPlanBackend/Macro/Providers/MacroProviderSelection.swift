import Foundation

/// Pure per-country provider planning — mirrors `MarketDataProviderKind.select`
/// so the wiring decision is unit-testable without Vapor.
enum MacroProviderPlanSelection {
    enum ProviderKind: Equatable {
        case fred
        case eurostat
        case ibge
        case disabled
    }

    struct CountryPlan: Equatable {
        let primary: ProviderKind
        let fallback: ProviderKind?
        let nowflationEnrichment: Bool
        /// ECB policy-rate enrichment. Keyless, so it rides along with every
        /// euro-area country.
        var ecbEnrichment: Bool = false
    }

    static func plan(
        macroEnabled: Bool,
        hasFREDKey: Bool,
        nowflationConfigured: Bool
    ) -> [MacroCountry: CountryPlan] {
        guard macroEnabled else {
            return MacroCountry.allCases.reduce(into: [:]) {
                $0[$1] = CountryPlan(primary: .disabled, fallback: nil, nowflationEnrichment: false)
            }
        }
        var plans: [MacroCountry: CountryPlan] = [:]
        plans[.us] = CountryPlan(
            primary: hasFREDKey ? .fred : .disabled,
            fallback: nil,
            nowflationEnrichment: hasFREDKey && nowflationConfigured
        )
        plans[.br] = CountryPlan(
            primary: .ibge,
            fallback: hasFREDKey ? .fred : nil,
            nowflationEnrichment: false
        )
        let euro = CountryPlan(
            primary: .eurostat,
            fallback: hasFREDKey ? .fred : nil,
            nowflationEnrichment: false,
            ecbEnrichment: true
        )
        for country in MacroCountry.allCases where country.isEuroArea {
            plans[country] = euro
        }
        return plans
    }
}

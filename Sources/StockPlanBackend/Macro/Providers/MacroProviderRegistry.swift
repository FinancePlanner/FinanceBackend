import Foundation
import StockPlanShared
import Vapor

/// Resolved providers per country: primary source, optional fallback, and
/// enrichment layers applied in order on top of whichever source succeeded.
struct MacroProviderRegistry {
    struct CountryProviders {
        let primary: any MacroProvider
        let fallback: (any MacroProvider)?
        let enrichments: [any MacroEnrichmentProviding]
    }

    private let providers: [MacroCountry: CountryProviders]

    init(providers: [MacroCountry: CountryProviders]) {
        self.providers = providers
    }

    var enabledCountries: [MacroCountry] {
        MacroCountry.allCases.filter { country in
            guard let entry = providers[country] else { return false }
            return !(entry.primary is DisabledMacroProvider)
        }
    }

    func isEnabled(_ country: MacroCountry) -> Bool {
        enabledCountries.contains(country)
    }

    func providers(for country: MacroCountry) -> CountryProviders? {
        providers[country]
    }

    /// Primary → fallback → enrichment. Throws only when every source fails.
    func fetch(country: MacroCountry, on req: Request) async throws -> MacroProviderResult {
        guard let entry = providers[country] else {
            throw Abort(.serviceUnavailable, reason: "No macro provider configured for \(country.rawValue).")
        }
        var result: MacroProviderResult
        do {
            result = try await entry.primary.fetchSnapshot(country: country, on: req)
        } catch {
            guard let fallback = entry.fallback else { throw error }
            req.logger.warning(
                "macro primary provider \(entry.primary.name) failed for \(country.rawValue), trying \(fallback.name) error=\(String(describing: error))"
            )
            result = try await fallback.fetchSnapshot(country: country, on: req)
        }
        for enrichment in entry.enrichments where enrichment.isEnabled {
            result = await enrichment.enrich(result, country: country, on: req)
        }
        return result
    }

    /// Builds the registry from a pure selection plan plus concrete providers.
    static func build(
        plan: [MacroCountry: MacroProviderPlanSelection.CountryPlan],
        fred: FREDMacroProvider?,
        eurostat: EurostatMacroProvider,
        ibge: IBGEMacroProvider,
        nowflation: NowflationEnrichment,
        ecb: ECBMacroEnrichment = ECBMacroEnrichment(),
        extraEnrichments: [any MacroEnrichmentProviding] = []
    ) -> MacroProviderRegistry {
        func materialize(_ kind: MacroProviderPlanSelection.ProviderKind?) -> (any MacroProvider)? {
            switch kind {
            case .fred: fred
            case .eurostat: eurostat
            case .ibge: ibge
            case .disabled: DisabledMacroProvider()
            case nil: nil
            }
        }

        var providers: [MacroCountry: CountryProviders] = [:]
        for (country, countryPlan) in plan {
            let primary = materialize(countryPlan.primary) ?? DisabledMacroProvider()
            let fallback = materialize(countryPlan.fallback)
            var enrichments: [any MacroEnrichmentProviding] = []
            if countryPlan.nowflationEnrichment {
                enrichments.append(nowflation)
            }
            if countryPlan.ecbEnrichment {
                enrichments.append(ecb)
            }
            enrichments += extraEnrichments
            providers[country] = CountryProviders(primary: primary, fallback: fallback, enrichments: enrichments)
        }
        return MacroProviderRegistry(providers: providers)
    }
}

import Foundation
import StockPlanShared

/// One quadro / schedule of a national form, rows already formatted the way
/// the form wants them (dates split into year/month, money as "0.00").
struct FilingPackSection: Sendable, Equatable, Codable {
    let id: String
    let title: String
    let columns: [String]
    let rows: [[String]]
    let totals: [String: Decimal]
    let notes: [String]
}

struct FilingPack: Sendable, Equatable, Codable {
    let jurisdiction: TaxJurisdiction
    let taxYear: Int
    let reportingCurrency: String
    let formName: String
    let rulePackVersion: String
    let sections: [FilingPackSection]
    let summary: [String: Decimal]
    let disclaimer: String

    static let disclaimer = "Prepared from your imported trades and dividends. Norviq is not a tax adviser; verify against your broker statements before filing."
}

protocol FilingCountryMapper: Sendable {
    var jurisdiction: TaxJurisdiction { get }
    func map(_ ledger: FilingLedger) -> FilingPack
}

enum FilingCountryMappers {
    /// The mapper for a jurisdiction, or nil when no filing pack exists for it yet.
    static func mapper(for jurisdiction: TaxJurisdiction) -> (any FilingCountryMapper)? {
        switch jurisdiction {
        case .portugal: PortugalAnexoJMapper()
        case .germany: GermanyAnlageKAPMapper()
        default: nil
        }
    }

    /// Row counts the preview shows, read from the sections each mapper
    /// designates for disposals, dividends, and the manual-check list.
    static func counts(of pack: FilingPack) -> (disposals: Int, dividends: Int, unsupported: Int) {
        let rows = { (ids: [String]) -> Int in
            ids.reduce(0) { total, id in total + (pack.sections.first { $0.id == id }?.rows.count ?? 0) }
        }
        switch pack.jurisdiction {
        case .germany:
            return (
                rows([GermanyAnlageKAPMapper.disposalsSectionID, GermanyAnlageKAPMapper.fundDisposalsSectionID]),
                rows([GermanyAnlageKAPMapper.dividendsSectionID]),
                rows([GermanyAnlageKAPMapper.unsupportedSectionID])
            )
        default:
            return (
                rows([PortugalAnexoJMapper.sharesSectionID]),
                rows([PortugalAnexoJMapper.dividendsSectionID]),
                rows([PortugalAnexoJMapper.unsupportedSectionID])
            )
        }
    }
}

enum FilingFormat {
    static func money(_ value: Decimal) -> String {
        let rounded = value.roundedForFiling(scale: 2)
        return NSDecimalNumber(decimal: rounded).stringValue.paddedToCents()
    }

    static func year(_ date: Date) -> String {
        String(Calendar.utcFiling.component(.year, from: date))
    }

    static func month(_ date: Date) -> String {
        String(format: "%02d", Calendar.utcFiling.component(.month, from: date))
    }

    static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}

private extension String {
    /// "910" → "910.00", "910.5" → "910.50", "-1.2" → "-1.20"
    func paddedToCents() -> String {
        guard let dot = firstIndex(of: ".") else { return self + ".00" }
        let decimals = distance(from: index(after: dot), to: endIndex)
        return decimals >= 2 ? self : self + String(repeating: "0", count: 2 - decimals)
    }
}

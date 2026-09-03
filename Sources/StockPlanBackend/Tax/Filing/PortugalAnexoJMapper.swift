import Foundation
import StockPlanShared

/// IRS Modelo 3, Anexo J (rendimentos obtidos no estrangeiro).
///
/// Quadro 9.2A — one row per disposal of shares/securities: código (G01 shares,
/// G10 other securities), país da fonte (ISO-3166 numeric), realização
/// ano/mês/valor, aquisição ano/mês/valor, despesas e encargos.
/// Quadro 8A — dividends (E11): país da fonte, rendimento bruto, imposto pago
/// no estrangeiro, imposto retido em Portugal (always 0.00 for foreign brokers).
///
/// Instruments the PT rule pack does not fully support go to a "verify
/// manually" section instead of being silently dropped.
struct PortugalAnexoJMapper: FilingCountryMapper {
    let jurisdiction: TaxJurisdiction = .portugal
    private let rulePack = TaxRuleRegistry(validatedJurisdictions: [.portugal]).pack(for: .portugal)

    static let sharesSectionID = "anexo-j-9.2A"
    static let dividendsSectionID = "anexo-j-8A"
    static let unsupportedSectionID = "unsupported"

    func map(_ ledger: FilingLedger) -> FilingPack {
        var shareRows: [[String]] = []
        var unsupportedRows: [[String]] = []
        var supportedGain: Decimal = 0

        for disposal in ledger.disposals {
            guard rulePack.supportLevel(instrumentType: disposal.instrumentType, wrapper: .taxable) == .supported else {
                unsupportedRows.append([
                    disposal.symbol,
                    "Instrument type \(disposal.instrumentType) is not covered by \(rulePack.ruleVersion)",
                    FilingFormat.money(disposal.gain),
                ])
                continue
            }
            supportedGain += disposal.gain
            shareRows.append([
                disposal.instrumentType == "stock" || disposal.instrumentType == "equity" ? "G01" : "G10",
                Self.numericCountry(disposal.sourceCountry),
                FilingFormat.year(disposal.realizationDate),
                FilingFormat.month(disposal.realizationDate),
                FilingFormat.money(disposal.realizationValue),
                FilingFormat.year(disposal.acquisitionDate),
                FilingFormat.month(disposal.acquisitionDate),
                FilingFormat.money(disposal.acquisitionValue),
                FilingFormat.money(disposal.expenses),
            ])
        }

        let dividendRows = ledger.dividends.map { dividend in
            [
                "E11",
                Self.numericCountry(dividend.sourceCountry),
                FilingFormat.money(dividend.gross),
                FilingFormat.money(dividend.withholding),
                "0.00",
            ]
        }

        for row in ledger.unsupported {
            unsupportedRows.append([row.reference, row.reason, ""])
        }

        return FilingPack(
            jurisdiction: .portugal,
            taxYear: ledger.taxYear,
            reportingCurrency: ledger.reportingCurrency,
            formName: "IRS Modelo 3 — Anexo J",
            rulePackVersion: rulePack.ruleVersion,
            sections: [
                FilingPackSection(
                    id: Self.sharesSectionID,
                    title: "Quadro 9.2A — Alienação onerosa de partes sociais e outros valores mobiliários",
                    columns: ["Código", "País", "Real. ano", "Real. mês", "Valor realização", "Aq. ano", "Aq. mês", "Valor aquisição", "Despesas"],
                    rows: shareRows,
                    totals: ["gain": supportedGain],
                    notes: [
                        "Valores em \(ledger.reportingCurrency) à taxa de referência do BCE na data de cada operação.",
                        "Método de apuramento: FIFO (art. 43.º CIRS).",
                    ]
                ),
                FilingPackSection(
                    id: Self.dividendsSectionID,
                    title: "Quadro 8A — Rendimentos de capitais (categoria E)",
                    columns: ["Código", "País", "Rendimento bruto", "Imposto pago no estrangeiro", "Retido em Portugal"],
                    rows: dividendRows,
                    totals: ["gross": ledger.totalDividendsGross, "withholding": ledger.totalWithholding],
                    notes: []
                ),
                FilingPackSection(
                    id: Self.unsupportedSectionID,
                    title: "Verificar manualmente",
                    columns: ["Referência", "Motivo", "Ganho"],
                    rows: unsupportedRows,
                    totals: [:],
                    notes: []
                ),
            ],
            summary: [
                "totalGain": ledger.totalGain,
                "totalDividendsGross": ledger.totalDividendsGross,
                "totalWithholding": ledger.totalWithholding,
            ],
            disclaimer: FilingPack.disclaimer
        )
    }

    /// ISO-3166 numeric codes the form expects. Extend as instruments appear;
    /// an unknown country renders blank so the user fills it rather than
    /// filing a wrong code.
    static func numericCountry(_ alpha2: String?) -> String {
        let table: [String: String] = [
            "US": "840", "PT": "620", "DE": "276", "FR": "250", "NL": "528", "IE": "372", "GB": "826",
            "CH": "756", "ES": "724", "IT": "380", "LU": "442", "BE": "056", "AT": "040", "DK": "208",
            "SE": "752", "FI": "246", "NO": "578", "CA": "124", "JP": "392", "AU": "036", "JE": "832",
            // Offshore domiciles common for US-listed ADRs and holding companies
            // (DLO, GRAB → KY; many insurers → BM), plus the rest of the usual
            // IBKR universe. ISO 3166-1 numeric.
            "KY": "136", "BM": "060", "VG": "092", "PA": "591", "LR": "430", "MH": "584", "CW": "531",
            "GG": "831", "IM": "833", "CY": "196", "MT": "470", "IL": "376", "CN": "156", "HK": "344",
            "SG": "702", "TW": "158", "KR": "410", "IN": "356", "BR": "076", "MX": "484", "AR": "032",
            "CL": "152", "NZ": "554", "ZA": "710", "PR": "630", "GR": "300", "PL": "616", "CZ": "203",
            "HU": "348", "TR": "792", "AE": "784", "SA": "682", "ID": "360", "TH": "764", "MY": "458",
            "PH": "608", "VN": "704", "RU": "643", "IS": "352", "LI": "438", "MC": "492", "SK": "703",
            "SI": "705", "HR": "191", "RO": "642", "BG": "100", "EE": "233", "LV": "428", "LT": "440",
        ]
        guard let alpha2 = alpha2?.uppercased() else { return "" }
        return table[alpha2] ?? ""
    }
}

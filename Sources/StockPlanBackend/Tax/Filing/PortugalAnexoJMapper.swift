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
        ]
        guard let alpha2 = alpha2?.uppercased() else { return "" }
        return table[alpha2] ?? ""
    }
}

import Foundation
import StockPlanShared

/// Einkommensteuererklärung — Anlage KAP and Anlage KAP-INV for a foreign
/// broker account (no German Kapitalertragsteuer withheld at source).
///
/// Anlage KAP: Zeile 19 carries the balance of foreign capital income
/// (dividends plus share gains net of share losses); Zeile 20 and 22 break out
/// the share gains and share losses contained in it so the Finanzamt can run
/// the Aktienverlust pot; Zeile 41 the creditable foreign withholding, capped
/// at the treaty rate. Shares only — funds never touch Anlage KAP.
///
/// Anlage KAP-INV: fund distributions (Zeile 4–8), Vorabpauschalen (Zeile
/// 9–13) and fund disposal results (Zeile 14–18), one row per InvStG fund
/// type, all *before* Teilfreistellung because the form asks for gross
/// figures and the Finanzamt applies the exemption.
///
/// Anything the pack cannot place — options, funds without a classification —
/// is listed under "Manuell prüfen" instead of being dropped.
struct GermanyAnlageKAPMapper: FilingCountryMapper {
    let jurisdiction: TaxJurisdiction = .germany
    private let rulePack = TaxRuleRegistry(validatedJurisdictions: []).pack(for: .germany)

    static let kapSectionID = "anlage-kap"
    static let kapInvSectionID = "anlage-kap-inv"
    static let disposalsSectionID = "kap-disposals"
    static let fundDisposalsSectionID = "kap-inv-disposals"
    static let dividendsSectionID = "kap-dividends"
    static let lossSectionID = "verlustverrechnung"
    static let unsupportedSectionID = "unsupported"

    /// Treaty cap on creditable foreign withholding (Zeile 41): 15 % of the gross dividend.
    static let creditableWithholdingRate = Decimal(string: "0.15")!

    private enum Route {
        case shares
        case fund(TaxFundClassification)
        case manual(String)
    }

    func map(_ ledger: FilingLedger) -> FilingPack {
        let classifications = ledger.germany?.fundClassifications ?? [:]

        var stockDisposalRows: [[String]] = []
        var fundDisposalRows: [[String]] = []
        var unsupportedRows: [[String]] = []
        var stockGains: Decimal = 0
        var stockLosses: Decimal = 0
        var fundResultByClass: [TaxFundClassification: Decimal] = [:]

        for disposal in ledger.disposals {
            switch route(disposal, classifications: classifications) {
            case .shares:
                if disposal.gain >= 0 {
                    stockGains += disposal.gain
                } else {
                    stockLosses -= disposal.gain
                }
                stockDisposalRows.append([
                    disposal.symbol,
                    disposal.isin ?? "",
                    FilingFormat.isoDate(disposal.realizationDate),
                    FilingFormat.isoDate(disposal.acquisitionDate),
                    FilingFormat.money(disposal.realizationValue),
                    FilingFormat.money(disposal.acquisitionValue),
                    FilingFormat.money(disposal.expenses),
                    FilingFormat.money(disposal.gain),
                ])
            case let .fund(classification):
                fundResultByClass[classification, default: 0] += disposal.gain
                fundDisposalRows.append([
                    disposal.symbol,
                    disposal.isin ?? "",
                    Self.fundLabel(classification),
                    FilingFormat.isoDate(disposal.realizationDate),
                    FilingFormat.isoDate(disposal.acquisitionDate),
                    FilingFormat.money(disposal.realizationValue),
                    FilingFormat.money(disposal.acquisitionValue),
                    FilingFormat.money(disposal.expenses),
                    FilingFormat.money(disposal.gain),
                ])
            case let .manual(reason):
                unsupportedRows.append([disposal.symbol, reason, FilingFormat.money(disposal.gain)])
            }
        }

        var dividendRows: [[String]] = []
        var stockDividendsGross: Decimal = 0
        var creditableForeignTax: Decimal = 0
        var fundDistributionsByClass: [TaxFundClassification: Decimal] = [:]
        for dividend in ledger.dividends {
            switch classifications[dividend.symbol] {
            case .some(.unknown):
                unsupportedRows.append([dividend.symbol, "Fondsausschüttung ohne InvStG-Klassifizierung", FilingFormat.money(dividend.gross)])
            case let .some(classification):
                fundDistributionsByClass[classification, default: 0] += dividend.gross
                dividendRows.append([
                    dividend.symbol,
                    dividend.sourceCountry ?? "",
                    FilingFormat.isoDate(dividend.payDate),
                    "KAP-INV Zeile \(Self.distributionLine(classification))",
                    FilingFormat.money(dividend.gross),
                    FilingFormat.money(dividend.withholding),
                    "0.00",
                ])
            case .none:
                stockDividendsGross += dividend.gross
                let cap = (dividend.gross * Self.creditableWithholdingRate).roundedForFiling(scale: 2)
                let credit = max(0, min(dividend.withholding, cap))
                creditableForeignTax += credit
                dividendRows.append([
                    dividend.symbol,
                    dividend.sourceCountry ?? "",
                    FilingFormat.isoDate(dividend.payDate),
                    "KAP Zeile 19",
                    FilingFormat.money(dividend.gross),
                    FilingFormat.money(dividend.withholding),
                    FilingFormat.money(credit),
                ])
            }
        }

        for row in ledger.unsupported {
            unsupportedRows.append([row.reference, row.reason, ""])
        }

        let saldo = stockDividendsGross + stockGains - stockLosses
        let kapRows: [[String]] = [
            ["19", "Ausländische Kapitalerträge (Saldo aus Dividenden und Aktienveräußerungen)", FilingFormat.money(saldo)],
            ["20", "In Zeile 19 enthaltene Gewinne aus Aktienveräußerungen", FilingFormat.money(stockGains)],
            ["22", "In Zeile 19 enthaltene Verluste aus Aktienveräußerungen", FilingFormat.money(stockLosses)],
            ["41", "Anrechenbare ausländische Steuern (Quellensteuer, höchstens 15 % nach DBA)", FilingFormat.money(creditableForeignTax)],
        ]

        var kapInvRows: [[String]] = []
        let advanceByClass = (ledger.germany?.advanceLumpSums ?? []).reduce(into: [TaxFundClassification: Decimal]()) { $0[$1.classification, default: 0] += $1.gross }
        for classification in Self.fundOrder {
            if let amount = fundDistributionsByClass[classification] {
                kapInvRows.append([String(Self.distributionLine(classification)), "Ausschüttungen — \(Self.fundLabel(classification))", FilingFormat.money(amount)])
            }
        }
        for classification in Self.fundOrder {
            if let amount = advanceByClass[classification] {
                kapInvRows.append([String(Self.advanceLine(classification)), "Vorabpauschale — \(Self.fundLabel(classification))", FilingFormat.money(amount)])
            }
        }
        for classification in Self.fundOrder {
            if let amount = fundResultByClass[classification] {
                kapInvRows.append([String(Self.disposalLine(classification)), "Gewinn/Verlust aus Veräußerung — \(Self.fundLabel(classification)) (vor Teilfreistellung)", FilingFormat.money(amount)])
            }
        }
        let fundResult = fundResultByClass.values.reduce(0, +)
        let fundDistributions = fundDistributionsByClass.values.reduce(0, +)
        let advanceTotal = advanceByClass.values.reduce(0, +)

        var lossRows: [[String]] = [["Aktienverluste \(ledger.taxYear) (Zeile 22)", FilingFormat.money(stockLosses)]]
        if let prior = ledger.germany?.priorStockLossCarryforward {
            lossRows.append(["Verlustvortrag Aktien aus \(ledger.taxYear - 1)", FilingFormat.money(prior)])
        }
        if let prior = ledger.germany?.priorGeneralLossCarryforward {
            lossRows.append(["Verlustvortrag sonstige Kapitalerträge aus \(ledger.taxYear - 1)", FilingFormat.money(prior)])
        }

        return FilingPack(
            jurisdiction: .germany,
            taxYear: ledger.taxYear,
            reportingCurrency: ledger.reportingCurrency,
            formName: "ESt 1 A — Anlage KAP / KAP-INV",
            rulePackVersion: rulePack.ruleVersion,
            sections: [
                FilingPackSection(
                    id: Self.kapSectionID,
                    title: "Anlage KAP — Kapitalerträge ohne inländischen Steuerabzug",
                    columns: ["Zeile", "Bezeichnung", "Betrag"],
                    rows: kapRows,
                    totals: ["saldo": saldo, "stockGains": stockGains, "stockLosses": stockLosses, "creditableForeignTax": creditableForeignTax],
                    notes: [
                        "Beträge in \(ledger.reportingCurrency) zum EZB-Referenzkurs am Tag der jeweiligen Operation; Veräußerungen nach FIFO (§ 20 Abs. 4 Satz 7 EStG).",
                        "Zeilennummern nach Anlage KAP 2025 — vor Übertragung mit dem amtlichen Formular abgleichen.",
                        "Der Sparer-Pauschbetrag ist nicht abgezogen; ihn berücksichtigt das Finanzamt.",
                    ]
                ),
                FilingPackSection(
                    id: Self.kapInvSectionID,
                    title: "Anlage KAP-INV — Investmenterträge (vor Teilfreistellung)",
                    columns: ["Zeile", "Bezeichnung", "Betrag"],
                    rows: kapInvRows,
                    totals: ["distributions": fundDistributions, "advanceLumpSums": advanceTotal, "fundResult": fundResult],
                    notes: [
                        "Alle Beträge vor Teilfreistellung (§ 20 InvStG: Aktienfonds 30 %, Mischfonds 15 %, Immobilienfonds 60 %, Auslands-Immobilienfonds 80 %); die Freistellung nimmt das Finanzamt vor.",
                        "Vorabpauschalen stammen aus den im Steuer-Dashboard erfassten Fondsjahreswerten.",
                    ]
                ),
                FilingPackSection(
                    id: Self.disposalsSectionID,
                    title: "Aktienveräußerungen (Einzelnachweis zu Zeile 19/20/22)",
                    columns: ["Symbol", "ISIN", "Veräußerung", "Anschaffung", "Erlös", "Anschaffungskosten", "Kosten", "Gewinn/Verlust"],
                    rows: stockDisposalRows,
                    totals: ["gain": stockGains - stockLosses],
                    notes: []
                ),
                FilingPackSection(
                    id: Self.fundDisposalsSectionID,
                    title: "Fondsveräußerungen (Einzelnachweis zu KAP-INV Zeile 14–18)",
                    columns: ["Symbol", "ISIN", "Fondsart", "Veräußerung", "Anschaffung", "Erlös", "Anschaffungskosten", "Kosten", "Gewinn/Verlust"],
                    rows: fundDisposalRows,
                    totals: ["gain": fundResult],
                    notes: []
                ),
                FilingPackSection(
                    id: Self.dividendsSectionID,
                    title: "Dividenden und Ausschüttungen (Einzelnachweis)",
                    columns: ["Symbol", "Land", "Zahltag", "Zuordnung", "Brutto", "Quellensteuer", "Anrechenbar"],
                    rows: dividendRows,
                    totals: ["gross": ledger.totalDividendsGross, "withholding": ledger.totalWithholding, "creditable": creditableForeignTax],
                    notes: []
                ),
                FilingPackSection(
                    id: Self.lossSectionID,
                    title: "Verlustverrechnung (nachrichtlich)",
                    columns: ["Topf", "Betrag"],
                    rows: lossRows,
                    totals: [:],
                    notes: ["Verlustvorträge stellt das Finanzamt gesondert fest; die Werte dienen dem Abgleich mit dem Verlustfeststellungsbescheid."]
                ),
                FilingPackSection(
                    id: Self.unsupportedSectionID,
                    title: "Manuell prüfen",
                    columns: ["Referenz", "Grund", "Betrag"],
                    rows: unsupportedRows,
                    totals: [:],
                    notes: []
                ),
            ],
            summary: [
                "totalGain": ledger.totalGain,
                "totalDividendsGross": ledger.totalDividendsGross,
                "totalWithholding": ledger.totalWithholding,
                "creditableForeignTax": creditableForeignTax,
                "stockGains": stockGains,
                "stockLosses": stockLosses,
                "fundResult": fundResult,
                "advanceLumpSums": advanceTotal,
            ],
            disclaimer: FilingPack.disclaimer
        )
    }

    private func route(_ disposal: FilingDisposal, classifications: [String: TaxFundClassification]) -> Route {
        switch disposal.instrumentType {
        case "stock", "equity":
            .shares
        case _ where FilingLedgerBuilder.isFund(disposal.instrumentType):
            switch classifications[disposal.symbol] {
            case .none, .some(.unknown):
                .manual("InvStG-Klassifizierung fehlt — Teilfreistellung nicht bestimmbar")
            case let .some(classification):
                .fund(classification)
            }
        default:
            .manual("Instrumententyp \(disposal.instrumentType) wird von \(rulePack.ruleVersion) nicht abgedeckt")
        }
    }

    static let fundOrder: [TaxFundClassification] = [.equity, .mixed, .realEstate, .foreignRealEstate, .other]

    static func fundLabel(_ classification: TaxFundClassification) -> String {
        switch classification {
        case .equity: "Aktienfonds"
        case .mixed: "Mischfonds"
        case .realEstate: "Immobilienfonds"
        case .foreignRealEstate: "Auslands-Immobilienfonds"
        case .other, .unknown: "Sonstige Investmentfonds"
        }
    }

    /// KAP-INV 2025 line numbers per fund type, in `fundOrder`.
    static func distributionLine(_ classification: TaxFundClassification) -> Int {
        4 + fundIndex(classification)
    }

    static func advanceLine(_ classification: TaxFundClassification) -> Int {
        9 + fundIndex(classification)
    }

    static func disposalLine(_ classification: TaxFundClassification) -> Int {
        14 + fundIndex(classification)
    }

    private static func fundIndex(_ classification: TaxFundClassification) -> Int {
        fundOrder.firstIndex(of: classification) ?? (fundOrder.count - 1)
    }
}

import Fluent
import Foundation
import StockPlanShared
import Vapor

struct TaxReportGenerator: Sendable {
    func generate(reportID: UUID, application: Application) async {
        do {
            guard let report = try await TaxReport.find(reportID, on: application.db) else { return }
            guard let profile = try await TaxProfile.query(on: application.db)
                .filter(\.$userId == report.userId)
                .filter(\.$taxYear == report.taxYear)
                .first(),
                let jurisdiction = TaxJurisdiction(rawValue: profile.jurisdiction)
            else { throw Abort(.unprocessableEntity, reason: "A completed tax profile is required.") }

            let dashboard = try await application.taxService.dashboard(
                userId: report.userId,
                jurisdiction: jurisdiction,
                taxYear: report.taxYear,
                on: application.db
            )
            let carryforwardLedger: TaxLossCarryforwardLedgerResponse? = switch jurisdiction {
            case .portugal:
                try await PortugalLossCarryforwardLedger().response(
                    userId: report.userId,
                    jurisdiction: jurisdiction,
                    asOfTaxYear: report.taxYear,
                    on: application.db
                )
            case .germany:
                try await GermanyStockLossLedger().response(
                    userId: report.userId,
                    asOfTaxYear: report.taxYear,
                    on: application.db
                )
            default:
                nil
            }
            let accountIDs = try await Account.query(on: application.db)
                .filter(\.$userId == report.userId)
                .all()
                .compactMap(\.id)
            let inferredBasisCount = accountIDs.isEmpty ? 0 : try await Transaction.query(on: application.db)
                .filter(\.$accountId ~~ accountIDs)
                .filter(\.$type == "OPENING_BALANCE")
                .count()
            let basisDisclosure = inferredBasisCount > 0
                ? "Warning: \(inferredBasisCount) opening lot(s) use position-snapshot average cost because broker acquisition history was unavailable. Verify dates and basis before filing."
                : nil
            let actionPlans = try await application.taxService.actionPlans(userId: report.userId, on: application.db)
            let format = TaxReportFormat(rawValue: report.format) ?? .pdf
            let kind = TaxReportKind(rawValue: report.kind) ?? .transactionWorkpaper
            let data: Data
            if kind == .annualFilingPack {
                // The filing pack does not derive from the dashboard: it is the
                // lot ledger and dividends converted at ECB rates and mapped to
                // the national form by the jurisdiction's mapper.
                guard let mapper = FilingCountryMappers.mapper(for: jurisdiction) else {
                    throw Abort(.unprocessableEntity, reason: "Filing pack is not available for \(jurisdiction.rawValue) yet.")
                }
                let resolver = FXRateResolver(
                    provider: ECBDailyRateProvider(client: application.client),
                    db: application.db
                )
                let ledger = try await FilingLedgerBuilder(fx: resolver).build(
                    userId: report.userId,
                    taxYear: report.taxYear,
                    jurisdiction: jurisdiction,
                    reportingCurrency: profile.reportingCurrency,
                    on: application.db
                )
                let pack = mapper.map(ledger)
                let renderer = FilingPackRenderer()
                data = format == .csv ? renderer.csv(pack) : renderer.pdf(pack)
            } else {
                data = format == .csv
                    ? csvData(dashboard, kind: kind, actionPlans: actionPlans, carryforwardLedger: carryforwardLedger, basisDisclosure: basisDisclosure)
                    : simplePDFData(dashboard, kind: kind, actionPlans: actionPlans, carryforwardLedger: carryforwardLedger, basisDisclosure: basisDisclosure)
            }
            let path = try application.taxReportStorage.store(
                data: data,
                userID: report.userId,
                reportID: reportID,
                format: format
            )
            report.status = "ready"
            report.filePath = path
            report.expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: Date())
            report.errorMessage = nil
            try await report.save(on: application.db)
        } catch {
            application.logger.error("tax.report generation failed report_id=\(reportID) error=\(error)")
            if let report = try? await TaxReport.find(reportID, on: application.db) {
                report.status = "failed"
                report.errorMessage = "Report generation failed."
                try? await report.save(on: application.db)
            }
        }
    }

    private func csvData(
        _ dashboard: TaxDashboardResponse,
        kind: TaxReportKind,
        actionPlans: [TaxActionPlanResponse],
        carryforwardLedger: TaxLossCarryforwardLedgerResponse?,
        basisDisclosure: String?
    ) -> Data {
        var rows = [
            "reportKind,symbol,instrumentType,accountId,portfolioId,lotIds,quantity,marketValue,unrealizedLoss,currentYearTaxReduction,deferredTaxLiability,transactionCosts,afterCostBenefit,holdingPeriod,status,supportLevel,priceQuality,replacementCandidates,warnings",
        ]
        rows += dashboard.opportunities.map { opportunity in
            [
                kind.rawValue,
                opportunity.symbol,
                opportunity.instrumentType,
                opportunity.accountId,
                opportunity.portfolioId ?? "",
                (opportunity.lots ?? []).map(\.id).joined(separator: ";"),
                NSDecimalNumber(decimal: opportunity.eligibleQuantity).stringValue,
                NSDecimalNumber(decimal: opportunity.marketValue.amount).stringValue,
                NSDecimalNumber(decimal: opportunity.unrealizedLoss.amount).stringValue,
                money(opportunity.currentYearTaxReduction?.amount ?? opportunity.estimatedTaxBenefit.amount),
                money(opportunity.deferredTaxLiability?.amount ?? 0),
                money(opportunity.estimatedTransactionCosts?.amount ?? 0),
                money(opportunity.estimatedAfterCostBenefit?.amount ?? opportunity.estimatedTaxBenefit.amount),
                opportunity.holdingPeriod,
                opportunity.status.rawValue,
                opportunity.supportLevel.rawValue,
                opportunity.priceQuality?.rawValue ?? "",
                (opportunity.replacementCandidates ?? []).map(\.symbol).joined(separator: ";"),
                opportunity.warnings.joined(separator: "; "),
            ].map(csvEscape).joined(separator: ",")
        }
        rows.append("")
        rows.append("actionPlanId,strategy,status,rebalancingPlanIds,legCount")
        rows += actionPlans.map { plan in
            [
                plan.id,
                plan.kind?.rawValue ?? TaxActionPlanKind.harvest.rawValue,
                plan.status,
                (plan.rebalancingPlanIds ?? []).joined(separator: ";"),
                String(plan.legs?.count ?? 0),
            ].map(csvEscape).joined(separator: ",")
        }
        rows.append("")
        if let carryforwardLedger {
            rows.append("lossCarryforwardSourceYear,category,expiresAfterTaxYear,originalAmount,remainingAmount,currency,ruleVersion,applicationHistory")
            rows += carryforwardLedger.balances.map { balance in
                let applicationHistory = balance.applications.map {
                    "\($0.targetTaxYear):\(money($0.amount.amount)) \($0.amount.currency)"
                }.joined(separator: "; ")
                return [
                    String(balance.sourceTaxYear),
                    balance.category?.rawValue ?? "unspecified",
                    String(balance.expiresAfterTaxYear),
                    money(balance.originalAmount.amount),
                    money(balance.remainingAmount.amount),
                    balance.remainingAmount.currency,
                    balance.ruleVersion,
                    applicationHistory,
                ].map(csvEscape).joined(separator: ",")
            }
            rows.append(csvEscape(
                "Total available for \(carryforwardLedger.asOfTaxYear): \(money(carryforwardLedger.totalAvailable.amount)) \(carryforwardLedger.totalAvailable.currency)"
            ))
            rows.append("")
        }
        if let basisDisclosure {
            rows.append(csvEscape(basisDisclosure))
        }
        rows.append(csvEscape("Advisor workpaper only. \(dashboard.disclaimer)"))
        return Data((["\u{FEFF}"] + rows).joined(separator: "\n").utf8)
    }

    private func simplePDFData(
        _ dashboard: TaxDashboardResponse,
        kind: TaxReportKind,
        actionPlans: [TaxActionPlanResponse],
        carryforwardLedger: TaxLossCarryforwardLedgerResponse?,
        basisDisclosure: String?
    ) -> Data {
        let currency = dashboard.summary.estimatedNetBenefit.currency
        var lines = [
            "Norviq Tax Report: " + kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
            "Jurisdiction: \(dashboard.jurisdiction.rawValue)   Tax year: \(dashboard.taxYear)",
            "Rule version: \(dashboard.ruleVersion)",
            "Estimated realized liability: \(money(dashboard.summary.realizedEstimatedLiability.amount)) \(currency)",
            "Embedded unrealized liability: \(money(dashboard.summary.embeddedUnrealizedLiability.amount)) \(currency)",
            "Harvestable losses: \(money(dashboard.summary.harvestableLosses.amount)) \(currency)",
            "Estimated net benefit: \(money(dashboard.summary.estimatedNetBenefit.amount)) \(currency)",
            "Opportunities: \(dashboard.opportunities.count)",
            "Accepted and reconciled plans: \(actionPlans.count)",
        ]
        if let drag = dashboard.taxDrag {
            lines.append(
                "Projected year-end tax drag: "
                    + money(drag.projectedYearEndTax.amount)
                    + " "
                    + drag.projectedYearEndTax.currency
            )
            lines.append("Tax cost ratio: " + (drag.taxCostRatio.map { money($0 * 100) + "%" } ?? "unavailable"))
        }
        for opportunity in dashboard.opportunities.prefix(12) {
            let lots = (opportunity.lots ?? []).map(\.id).joined(separator: ", ")
            lines.append(
                opportunity.symbol
                    + ": loss "
                    + money(opportunity.unrealizedLoss.amount)
                    + "; after-cost benefit "
                    + money(opportunity.estimatedAfterCostBenefit?.amount ?? opportunity.estimatedTaxBenefit.amount)
                    + "; lots "
                    + lots
            )
        }
        if let carryforwardLedger {
            lines += [
                "",
                "\(dashboard.jurisdiction.rawValue) carried tax losses",
                "Available for \(carryforwardLedger.asOfTaxYear): \(money(carryforwardLedger.totalAvailable.amount)) \(carryforwardLedger.totalAvailable.currency)",
            ]
            for balance in carryforwardLedger.balances {
                lines.append(
                    "\(balance.sourceTaxYear) [\(balance.category?.rawValue ?? "unspecified")]: \(money(balance.remainingAmount.amount)) \(balance.remainingAmount.currency) remaining; expires after \(balance.expiresAfterTaxYear)"
                )
                for application in balance.applications {
                    lines.append(
                        "  Applied in \(application.targetTaxYear): \(money(application.amount.amount)) \(application.amount.currency)"
                    )
                }
            }
        }
        lines += ["", "Advisor workpaper only. Not filing-ready.", dashboard.disclaimer]
        if let basisDisclosure {
            lines.insert(basisDisclosure, at: max(0, lines.count - 2))
        }
        return MinimalPDF.make(lines: lines)
    }

    private func money(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

enum MinimalPDF {
    static func make(lines: [String]) -> Data {
        let pageSize = 27
        let pages = lines.isEmpty ? [[]] : stride(from: 0, to: lines.count, by: pageSize).map {
            Array(lines[$0 ..< min($0 + pageSize, lines.count)])
        }
        let fontObjectNumber = 3 + pages.count * 2
        let pageObjectNumbers = pages.indices.map { 3 + $0 * 2 }
        let kids = pageObjectNumbers.map { "\($0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>",
        ]
        for (index, pageLines) in pages.enumerated() {
            let content = contentStream(pageLines)
            let contentObjectNumber = 4 + index * 2
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(fontObjectNumber) 0 R >> >> /Contents \(contentObjectNumber) 0 R >>"
            )
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var pdf = "%PDF-1.4\n"
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private static func contentStream(_ lines: [String]) -> String {
        var stream = "BT\n/F1 16 Tf\n50 740 Td\n"
        for (index, line) in lines.enumerated() {
            if index > 0 {
                stream += "0 -24 Td\n"
            }
            stream += "(\(escape(line))) Tj\n"
        }
        return stream + "ET"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .unicodeScalars
            .map { $0.isASCII ? String($0) : "?" }
            .joined()
    }
}

extension Application {
    private struct TaxReportGeneratorKey: StorageKey {
        typealias Value = TaxReportGenerator
    }

    var taxReportGenerator: TaxReportGenerator {
        get { storage[TaxReportGeneratorKey.self] ?? TaxReportGenerator() }
        set { storage[TaxReportGeneratorKey.self] = newValue }
    }
}

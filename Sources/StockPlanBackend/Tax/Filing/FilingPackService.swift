import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Builds the preview a client shows before generating (or buying) the annual
/// filing pack. Same ledger, same mapper as the report; only the rendering
/// differs, so the numbers on screen are the numbers in the file.
struct FilingPackService: Sendable {
    enum Failure: Error, AbortError, Equatable {
        case profileIncomplete(taxYear: Int)
        case jurisdictionUnsupported(TaxJurisdiction)

        var status: HTTPResponseStatus {
            switch self {
            case .profileIncomplete: .conflict
            case .jurisdictionUnsupported: .unprocessableEntity
            }
        }

        var reason: String {
            switch self {
            case let .profileIncomplete(taxYear):
                "profile_incomplete: complete your tax profile for \(taxYear) first."
            case let .jurisdictionUnsupported(jurisdiction):
                "Filing pack is not available for \(jurisdiction.rawValue) yet."
            }
        }
    }

    func preview(userId: UUID, taxYear: Int, on req: Request) async throws -> FilingPackPreviewResponse {
        let pack = try await buildPack(userId: userId, taxYear: taxYear, db: req.db, client: req.client)
        return Self.previewResponse(from: pack)
    }

    func buildPack(userId: UUID, taxYear: Int, db: any Database, client: any Client) async throws -> FilingPack {
        guard let profile = try await TaxProfile.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$taxYear == taxYear)
            .first(),
            profile.isComplete,
            let jurisdiction = TaxJurisdiction(rawValue: profile.jurisdiction)
        else {
            throw Failure.profileIncomplete(taxYear: taxYear)
        }
        guard let mapper = FilingCountryMappers.mapper(for: jurisdiction) else {
            throw Failure.jurisdictionUnsupported(jurisdiction)
        }
        let resolver = FXRateResolver(provider: ECBDailyRateProvider(client: client), db: db)
        let ledger = try await FilingLedgerBuilder(fx: resolver).build(
            userId: userId,
            taxYear: taxYear,
            jurisdiction: jurisdiction,
            reportingCurrency: profile.reportingCurrency,
            on: db
        )
        return mapper.map(ledger)
    }

    static func previewResponse(from pack: FilingPack) -> FilingPackPreviewResponse {
        let sections = pack.sections.map { section in
            FilingPackSectionDTO(id: section.id, title: section.title, columns: section.columns, rows: section.rows, totals: section.totals, notes: section.notes)
        }
        let counts = FilingCountryMappers.counts(of: pack)
        return FilingPackPreviewResponse(
            jurisdiction: pack.jurisdiction,
            taxYear: pack.taxYear,
            reportingCurrency: pack.reportingCurrency,
            formName: pack.formName,
            rulePackVersion: pack.rulePackVersion,
            sections: sections,
            summary: pack.summary,
            disclaimer: pack.disclaimer,
            disposalCount: counts.disposals,
            dividendCount: counts.dividends,
            unsupportedCount: counts.unsupported
        )
    }
}

extension FilingPackPreviewResponse: Content {}
extension FilingPackSectionDTO: Content {}

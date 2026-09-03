import Fluent
import Foundation

/// Per-year filing pack purchases. A pack grants preview + generation of the
/// annual filing pack for one tax year; it never unlocks anything else, so
/// the Pro gate stays exactly where it is for every other tax feature.
struct TaxPackEntitlementService: Sendable {
    static let productPrefix = "norviq_tax_pack_"

    /// `norviq_tax_pack_2025` → 2025. Anything else (subscriptions, other
    /// consumables, malformed years) is nil and left to the subscription path.
    static func taxYear(fromProductId productId: String?) -> Int? {
        guard let productId = productId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              productId.hasPrefix(productPrefix)
        else { return nil }
        let digits = productId.dropFirst(productPrefix.count).prefix { $0.isNumber }
        guard digits.count == 4, let year = Int(digits), (2000 ... 2100).contains(year) else { return nil }
        return year
    }

    static func productId(taxYear: Int) -> String {
        "\(productPrefix)\(taxYear)"
    }

    /// Idempotent: a second purchase (or replayed webhook) for the same year
    /// updates the row instead of failing on the unique index.
    @discardableResult
    func grant(
        userId: UUID,
        taxYear: Int,
        source: String,
        productId: String,
        providerEventId: String?,
        jurisdiction: String? = nil,
        on db: any Database
    ) async throws -> TaxPackEntitlement {
        let entitlement = try await TaxPackEntitlement.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$taxYear == taxYear)
            .first() ?? TaxPackEntitlement()
        entitlement.userId = userId
        entitlement.taxYear = taxYear
        entitlement.source = source
        entitlement.productId = productId
        entitlement.providerEventId = providerEventId
        if let jurisdiction {
            entitlement.jurisdiction = jurisdiction
        }
        try await entitlement.save(on: db)
        return entitlement
    }

    func hasEntitlement(userId: UUID, taxYear: Int, on db: any Database) async throws -> Bool {
        try await TaxPackEntitlement.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$taxYear == taxYear)
            .count() > 0
    }
}

import Fluent
import Foundation

/// One purchased annual filing pack: the user may preview and generate the
/// pack for `taxYear` without a Pro subscription. Granted by the RevenueCat
/// webhook for `norviq_tax_pack_<year>` products (App Store or Web Billing).
final class TaxPackEntitlement: Model, @unchecked Sendable {
    static let schema = "tax_pack_entitlements"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "tax_year") var taxYear: Int
    @OptionalField(key: "jurisdiction") var jurisdiction: String?
    @Field(key: "source") var source: String
    @Field(key: "product_id") var productId: String
    @OptionalField(key: "provider_event_id") var providerEventId: String?
    @Timestamp(key: "granted_at", on: .create) var grantedAt: Date?

    init() {}
}

struct CreateTaxPackEntitlements: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(TaxPackEntitlement.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("tax_year", .int, .required)
            .field("jurisdiction", .string)
            .field("source", .string, .required)
            .field("product_id", .string, .required)
            .field("provider_event_id", .string)
            .field("granted_at", .datetime)
            .unique(on: "user_id", "tax_year")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(TaxPackEntitlement.schema).delete()
    }
}

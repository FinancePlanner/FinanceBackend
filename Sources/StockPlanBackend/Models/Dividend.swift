import Fluent
import Foundation
import Vapor

final class Dividend: Model, Content, @unchecked Sendable {
    static let schema = "dividends"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "account_id")
    var accountId: UUID

    @Field(key: "instrument_id")
    var instrumentId: UUID

    @Field(key: "external_id")
    var externalId: String?

    @Field(key: "amount")
    var amount: Double

    @Field(key: "currency")
    var currency: String

    @Field(key: "ex_date")
    var exDate: Date?

    @Field(key: "pay_date")
    var payDate: Date

    /// Tax withheld at source, positive, same currency as `amount`. Filled by
    /// the broker sync when the statement carries a withholding line.
    @OptionalField(key: "withholding_tax")
    var withholdingTax: Double?

    /// `amount + withholdingTax` when withholding is known.
    @OptionalField(key: "gross_amount")
    var grossAmount: Double?

    /// ISO-3166 alpha-2 of the paying issuer, for the filing pack's country column.
    @OptionalField(key: "source_country")
    var sourceCountry: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        accountId: UUID,
        instrumentId: UUID,
        externalId: String? = nil,
        amount: Double,
        currency: String,
        exDate: Date? = nil,
        payDate: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.instrumentId = instrumentId
        self.externalId = externalId
        self.amount = amount
        self.currency = currency
        self.exDate = exDate
        self.payDate = payDate
    }
}

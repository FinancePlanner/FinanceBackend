import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Dividend withholding reconciler")
struct DividendWithholdingReconcilerTests {
    private static let pay = FXRateResolverTests.day("2025-06-13")

    private func dividend(amount: Double = 85, currency: String = "USD", payDate: Date = pay) -> Dividend {
        Dividend(accountId: UUID(), instrumentId: UUID(), externalId: "d1", amount: amount, currency: currency, payDate: payDate)
    }

    @Test("Withholding attaches to the dividend with the same symbol, pay date, and currency")
    func attachesByInstrumentAndDate() {
        let row = IBKRWithholdingRow(symbol: "AAPL", payDate: Self.pay, amount: -15, currency: "USD")
        let out = DividendWithholdingReconciler().apply(withholdings: [row], to: [(symbol: "AAPL", dividend: dividend())])
        #expect(out[0].withholdingTax == 15)
        #expect(out[0].grossAmount == 100)
    }

    @Test("Unmatched withholding leaves the dividend untouched")
    func unmatchedIsIgnored() {
        let row = IBKRWithholdingRow(symbol: "MSFT", payDate: Self.pay, amount: -15, currency: "USD")
        let out = DividendWithholdingReconciler().apply(withholdings: [row], to: [(symbol: "AAPL", dividend: dividend())])
        #expect(out[0].withholdingTax == nil)
        #expect(out[0].grossAmount == nil)
    }

    @Test("Each withholding row is consumed once")
    func consumedOnce() {
        let row = IBKRWithholdingRow(symbol: "AAPL", payDate: Self.pay, amount: -15, currency: "USD")
        let out = DividendWithholdingReconciler().apply(
            withholdings: [row],
            to: [(symbol: "AAPL", dividend: dividend()), (symbol: "AAPL", dividend: dividend(amount: 42))]
        )
        #expect(out[0].withholdingTax == 15)
        #expect(out[1].withholdingTax == nil)
    }

    @Test("Currency mismatch on the same day does not match")
    func currencyMustMatch() {
        let row = IBKRWithholdingRow(symbol: "AAPL", payDate: Self.pay, amount: -15, currency: "EUR")
        let out = DividendWithholdingReconciler().apply(withholdings: [row], to: [(symbol: "aapl", dividend: dividend())])
        #expect(out[0].withholdingTax == nil)
    }

    @Test("Broker type detection covers WHTAX and spelled-out forms")
    func typeDetection() {
        #expect(DividendWithholdingReconciler.isWithholdingType("WHTAX"))
        #expect(DividendWithholdingReconciler.isWithholdingType("Withholding Tax"))
        #expect(DividendWithholdingReconciler.isWithholdingType("withholding_tax"))
        #expect(!DividendWithholdingReconciler.isWithholdingType("DIV"))
    }
}

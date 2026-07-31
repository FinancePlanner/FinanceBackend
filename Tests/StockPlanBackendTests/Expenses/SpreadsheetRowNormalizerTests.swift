import Foundation
@testable import StockPlanBackend
import Testing

/// Amount, date and currency handling. These are the conversions that corrupt
/// data quietly when they go wrong -- a misread date files an expense in the
/// wrong month and then feeds snapshots and drift alerts -- so the ambiguous
/// cases are pinned down here rather than left to the review screen to catch.
@Suite("Spreadsheet row normalizer")
struct SpreadsheetRowNormalizerTests {
    private typealias Normalizer = SpreadsheetRowNormalizer

    // MARK: - Decimal separators

    @Test("infers the decimal separator from the column as a whole")
    func infersDecimalSeparator() {
        // "1.234" alone is unknowable; the sibling value settles it.
        #expect(Normalizer.inferDecimalSeparator(from: ["1.234,56", "1.234"]) == .comma)
        #expect(Normalizer.inferDecimalSeparator(from: ["1,234.56", "99.90"]) == .dot)
        #expect(Normalizer.inferDecimalSeparator(from: ["84,20", "13,99"]) == .comma)
        #expect(Normalizer.inferDecimalSeparator(from: ["84.20", "13.99"]) == .dot)
    }

    @Test("parses amounts under both separator conventions")
    func parsesAmounts() {
        #expect(Normalizer.parseAmount("1.234,56", separator: .comma) == 1234.56)
        #expect(Normalizer.parseAmount("1,234.56", separator: .dot) == 1234.56)
        #expect(Normalizer.parseAmount("84,20 €", separator: .comma) == 84.20)
        #expect(Normalizer.parseAmount("€ 84.20", separator: .dot) == 84.20)
        #expect(Normalizer.parseAmount("1.234.567,89", separator: .comma) == 1_234_567.89)
        #expect(Normalizer.parseAmount("", separator: .dot) == nil)
        #expect(Normalizer.parseAmount("n/a", separator: .dot) == nil)
    }

    @Test("accounting negatives and minus signs both read as negative")
    func parsesNegatives() {
        #expect(Normalizer.parseAmount("(123.45)", separator: .dot) == -123.45)
        #expect(Normalizer.parseAmount("-123.45", separator: .dot) == -123.45)
    }

    // MARK: - Date order

    /// 03/04/2026 is two different real dates. Getting it wrong moves an expense
    /// a month, so the column has to settle it or the user does.
    @Test("infers date order from values that can only read one way")
    func infersDateOrder() {
        // 13 can only be a day.
        #expect(Normalizer.inferDateOrder(from: ["13/04/2026", "03/04/2026"]) == .dayFirst)
        // 13 in second position can only be a day, so the month is first.
        #expect(Normalizer.inferDateOrder(from: ["04/13/2026", "04/03/2026"]) == .monthFirst)
        // Nothing over 12 anywhere: genuinely undecidable.
        #expect(Normalizer.inferDateOrder(from: ["03/04/2026", "05/06/2026"]) == .ambiguous)
    }

    @Test("parses dates in the order the column implies")
    func parsesDatesByOrder() throws {
        let dayFirst = try #require(Normalizer.parseDate("03/04/2026", order: .dayFirst))
        #expect(Normalizer.isoString(dayFirst) == "2026-04-03")

        let monthFirst = try #require(Normalizer.parseDate("03/04/2026", order: .monthFirst))
        #expect(Normalizer.isoString(monthFirst) == "2026-03-04")
    }

    @Test("ISO dates parse the same whatever the column order")
    func parsesISORegardlessOfOrder() throws {
        for order in [Normalizer.DateOrder.dayFirst, .monthFirst, .ambiguous] {
            let parsed = try #require(Normalizer.parseDate("2026-01-03", order: order))
            #expect(Normalizer.isoString(parsed) == "2026-01-03")
        }
    }

    @Test("spelled-out months parse")
    func parsesSpelledOutMonths() throws {
        let parsed = try #require(Normalizer.parseDate("3 April 2026", order: .dayFirst))
        #expect(Normalizer.isoString(parsed) == "2026-04-03")
    }

    @Test("nonsense dates fail rather than landing on a wrong day")
    func rejectsInvalidDates() {
        #expect(Normalizer.parseDate("not a date", order: .dayFirst) == nil)
        #expect(Normalizer.parseDate("", order: .dayFirst) == nil)
        #expect(Normalizer.parseDate("32/13/2026", order: .dayFirst) == nil)
    }

    // MARK: - Rows

    private func row(
        _ cells: [SpreadsheetColumnRole: SpreadsheetCell],
        settings: Normalizer.Settings = .init(),
        isAggregate: Bool = false
    ) -> Normalizer.NormalizedRow {
        Normalizer.normalize(row: 6, cells: cells, settings: settings, isAggregateRow: isAggregate)
    }

    @Test("a complete row normalizes")
    func normalizesCompleteRow() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        let result = row([
            .date: .date(date),
            .title: .text("Continente"),
            .amount: .number(84.20),
            .category: .text("Supermercado"),
        ])
        #expect(result.isImportable)
        #expect(result.title == "Continente")
        #expect(result.amount == 84.20)
        #expect(result.occurredOn == "2026-01-03")
        #expect(result.sourceCategoryValue == "Supermercado")
    }

    @Test("missing pieces are reported individually")
    func reportsMissingFields() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        #expect(row([.title: .text("x"), .amount: .number(1)]).issue == .invalidDate)
        #expect(row([.date: .date(date), .title: .text("x")]).issue == .invalidAmount)
        #expect(row([.date: .date(date), .amount: .number(1)]).issue == .missingTitle)
    }

    @Test("a totals row is reported, not silently dropped")
    func reportsAggregateRow() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        let result = row(
            [.date: .date(date), .title: .text("TOTAL"), .amount: .number(954.59)],
            isAggregate: true
        )
        #expect(result.issue == .aggregateRow)
        #expect(!result.isImportable)
    }

    /// Bank exports sign outgoings negative; expenses are stored positive.
    @Test("negative-is-expense flips the sign")
    func honoursNegativeIsExpense() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        var settings = Normalizer.Settings()
        settings.negativeIsExpense = true
        let result = row(
            [.date: .date(date), .title: .text("Card payment"), .amount: .number(-42.50)],
            settings: settings
        )
        #expect(result.amount == 42.50)
    }

    /// No invented rates: importing a GBP row at face value into a EUR budget
    /// would be wrong by ~17% and completely invisible.
    @Test("a foreign row with no rate is held back rather than converted at par")
    func withholdsRowsNeedingRate() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        var settings = Normalizer.Settings()
        settings.baseCurrency = "EUR"
        let result = row(
            [.date: .date(date), .title: .text("London"), .amount: .number(100), .currency: .text("GBP")],
            settings: settings
        )
        #expect(result.issue == .needsExchangeRate)
        #expect(result.foreignAmount == 100)
        #expect(result.exchangeRate == nil)
    }

    @Test("a supplied rate converts and keeps the original for audit")
    func appliesExchangeRate() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        var settings = Normalizer.Settings()
        settings.baseCurrency = "EUR"
        settings.exchangeRates = ["GBP": 1.17]
        let result = row(
            [.date: .date(date), .title: .text("London"), .amount: .number(100), .currency: .text("GBP")],
            settings: settings
        )
        #expect(result.isImportable)
        #expect(result.amount == 117.0)
        #expect(result.foreignAmount == 100)
        #expect(result.exchangeRate == 1.17)
    }

    @Test("base-currency rows need no rate")
    func baseCurrencyNeedsNoRate() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        var settings = Normalizer.Settings()
        settings.baseCurrency = "EUR"
        let result = row(
            [.date: .date(date), .title: .text("Lisboa"), .amount: .number(50), .currency: .text("eur")],
            settings: settings
        )
        #expect(result.isImportable)
        #expect(result.amount == 50)
        #expect(result.exchangeRate == nil)
    }

    @Test("overlong titles are truncated rather than rejected")
    func truncatesLongTitles() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        let result = row([
            .date: .date(date),
            .title: .text(String(repeating: "a", count: 500)),
            .amount: .number(1),
        ])
        #expect(result.isImportable)
        #expect(result.title?.count == 200)
    }

    @Test("a zero amount is not importable")
    func rejectsZeroAmounts() throws {
        let date = try #require(Normalizer.parseDate("2026-01-03", order: .dayFirst))
        let result = row([.date: .date(date), .title: .text("x"), .amount: .number(0)])
        #expect(result.issue == .invalidAmount)
    }
}

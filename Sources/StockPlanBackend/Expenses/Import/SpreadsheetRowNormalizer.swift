import Foundation

/// Turns detected cells into expense-shaped values.
///
/// Everything here is a decision that can silently corrupt data if it goes
/// wrong quietly, so each one either resolves from evidence or is reported:
/// an ambiguous date format is surfaced rather than guessed, a foreign currency
/// with no rate is skipped rather than converted at 1:1.
enum SpreadsheetRowNormalizer {
    /// Why a row can't be imported as-is. Mirrors the wire status enum, but
    /// stays internal so this layer builds without the shared package.
    enum RowIssue: String, Sendable, Equatable {
        case invalidDate
        case invalidAmount
        case missingTitle
        case needsExchangeRate
        case aggregateRow
    }

    struct NormalizedRow: Sendable, Equatable {
        let row: Int
        let title: String?
        /// In the user's base currency once a rate has been applied.
        let amount: Double?
        let occurredOn: String?
        let sourceCategoryValue: String?
        let currency: String?
        let foreignAmount: Double?
        let exchangeRate: Double?
        let notes: String?
        let issue: RowIssue?

        var isImportable: Bool {
            issue == nil
        }
    }

    /// Which way round a `03/04/2026`-style date reads.
    enum DateOrder: String, Sendable, Equatable {
        case dayFirst
        case monthFirst
        /// Nothing in the column settles it. The user is asked.
        case ambiguous
    }

    enum DecimalSeparator: String, Sendable, Equatable {
        case dot
        case comma
    }

    struct Settings: Sendable {
        var dateOrder: DateOrder = .dayFirst
        var decimalSeparator: DecimalSeparator = .dot
        var negativeIsExpense = false
        /// Rate per source currency code, keyed uppercased.
        var exchangeRates: [String: Double] = [:]
        var baseCurrency: String?
        var defaultCurrency: String?
    }

    // MARK: - Column-level inference

    /// Decides whether a column of text dates reads day-first or month-first.
    ///
    /// A first component over 12 can only be a day; a second component over 12
    /// can only be a month-second layout. When neither appears the column is
    /// genuinely ambiguous — `03/04/2026` is two different real dates — so we
    /// say so and let the user pick rather than defaulting silently.
    static func inferDateOrder(from values: [String]) -> DateOrder {
        var sawFirstOverTwelve = false
        var sawSecondOverTwelve = false

        for value in values {
            let parts = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { "/-.".contains($0) })
                .compactMap { Int($0) }
            guard parts.count >= 3 else { continue }
            // ISO-style values settle nothing about dd/mm ordering.
            if parts[0] > 31 {
                continue
            }
            if parts[0] > 12 {
                sawFirstOverTwelve = true
            }
            if parts[1] > 12 {
                sawSecondOverTwelve = true
            }
        }

        if sawFirstOverTwelve, !sawSecondOverTwelve {
            return .dayFirst
        }
        if sawSecondOverTwelve, !sawFirstOverTwelve {
            return .monthFirst
        }
        return .ambiguous
    }

    /// Decides which character is the decimal point for a column of amounts.
    ///
    /// Judged column-wide rather than per value: `1.234` alone is unknowable,
    /// but one `1.234,56` in the column settles every value in it.
    static func inferDecimalSeparator(from values: [String]) -> DecimalSeparator {
        var commaDecimal = 0
        var dotDecimal = 0

        for value in values {
            let digitsOnly = value.replacingOccurrences(
                of: "[^0-9,.]", with: "", options: .regularExpression
            )
            guard !digitsOnly.isEmpty else { continue }
            let lastComma = digitsOnly.lastIndex(of: ",")
            let lastDot = digitsOnly.lastIndex(of: ".")

            switch (lastComma, lastDot) {
            case let (comma?, dot?):
                // Whichever comes last is the decimal point.
                if comma > dot {
                    commaDecimal += 1
                } else {
                    dotDecimal += 1
                }
            case let (comma?, nil):
                // A single comma with exactly two digits after it is a decimal;
                // three digits after is a thousands separator.
                let after = digitsOnly.distance(from: digitsOnly.index(after: comma), to: digitsOnly.endIndex)
                if after == 2 {
                    commaDecimal += 1
                } else if after == 3 {
                    dotDecimal += 1
                }
            case let (nil, dot?):
                let after = digitsOnly.distance(from: digitsOnly.index(after: dot), to: digitsOnly.endIndex)
                if after == 2 {
                    dotDecimal += 1
                } else if after == 3 {
                    commaDecimal += 1
                }
            case (nil, nil):
                continue
            }
        }
        return commaDecimal > dotDecimal ? .comma : .dot
    }

    // MARK: - Value parsing

    static func parseAmount(_ raw: String, separator: DecimalSeparator) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Accounting negatives: (123.45)
        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("-") {
            negative = true
        }

        // Strip currency symbols, codes, spaces of every width, and the
        // apostrophe grouping used in Switzerland.
        var digits = text.replacingOccurrences(
            of: "[^0-9,.]", with: "", options: .regularExpression
        )
        guard !digits.isEmpty else { return nil }

        switch separator {
        case .dot:
            digits = digits.replacingOccurrences(of: ",", with: "")
        case .comma:
            digits = digits.replacingOccurrences(of: ".", with: "")
            digits = digits.replacingOccurrences(of: ",", with: ".")
        }
        // Any remaining extra dots are grouping, e.g. "1.234.567".
        if digits.filter({ $0 == "." }).count > 1 {
            digits = digits.replacingOccurrences(
                of: "\\.(?=.*\\.)", with: "", options: .regularExpression
            )
        }
        guard let value = Double(digits) else { return nil }
        return negative ? -abs(value) : value
    }

    /// Parses a text date. Native date cells never reach here — they arrive
    /// already typed and are used directly.
    static func parseDate(_ raw: String, order: DateOrder) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // ISO first: unambiguous regardless of the column's order.
        if let iso = formatter("yyyy-MM-dd").date(from: text) {
            return iso
        }
        if let iso = formatter("yyyy/MM/dd").date(from: text) {
            return iso
        }

        let numeric = ["dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yyyy"]
        let numericMonthFirst = ["MM/dd/yyyy", "MM-dd-yyyy", "MM.dd.yyyy"]
        let shortYear = ["dd/MM/yy", "dd-MM-yy", "dd.MM.yy"]
        let shortYearMonthFirst = ["MM/dd/yy", "MM-dd-yy", "MM.dd.yy"]

        let ordered: [String] = switch order {
        case .monthFirst: numericMonthFirst + shortYearMonthFirst + numeric + shortYear
        case .dayFirst, .ambiguous: numeric + shortYear + numericMonthFirst + shortYearMonthFirst
        }

        for pattern in ordered {
            if let date = formatter(pattern).date(from: text) {
                return date
            }
        }
        // Spelled-out months, e.g. "3 April 2026".
        for pattern in ["d MMMM yyyy", "d MMM yyyy", "MMMM d, yyyy", "MMM d, yyyy"] {
            if let date = formatter(pattern).date(from: text) {
                return date
            }
        }
        return nil
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        return formatter
    }

    static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    // MARK: - Row normalisation

    static func normalize(
        row rowNumber: Int,
        cells: [SpreadsheetColumnRole: SpreadsheetCell],
        settings: Settings,
        isAggregateRow: Bool
    ) -> NormalizedRow {
        let isoFormatter = SpreadsheetStructureDetector.isoDateFormatter()

        func text(_ role: SpreadsheetColumnRole) -> String? {
            guard let cell = cells[role], !cell.isEmpty else { return nil }
            return cell.displayText(dateFormatter: isoFormatter)
        }

        let title = text(.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceCategory = text(.category)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = text(.notes)
        let currencyCode = (text(.currency) ?? settings.defaultCurrency)?.uppercased()

        // A totals row is reported, not silently dropped, so the review screen
        // can show it struck through and let the user re-include it.
        if isAggregateRow {
            return NormalizedRow(
                row: rowNumber, title: title, amount: nil, occurredOn: nil,
                sourceCategoryValue: sourceCategory, currency: currencyCode,
                foreignAmount: nil, exchangeRate: nil, notes: notes, issue: .aggregateRow
            )
        }

        // Date
        var occurredOn: String?
        if let dateCell = cells[.date], !dateCell.isEmpty {
            if case let .date(value) = dateCell {
                occurredOn = isoString(value)
            } else if let parsed = parseDate(
                dateCell.displayText(dateFormatter: isoFormatter), order: settings.dateOrder
            ) {
                occurredOn = isoString(parsed)
            }
        }

        // Amount
        var amount: Double?
        if let amountCell = cells[.amount], !amountCell.isEmpty {
            if case let .number(value) = amountCell {
                amount = value
            } else {
                amount = parseAmount(
                    amountCell.displayText(dateFormatter: isoFormatter),
                    separator: settings.decimalSeparator
                )
            }
        }
        if var value = amount {
            // Bank exports sign outgoings negative; expenses are stored positive.
            if settings.negativeIsExpense {
                value = -value
            }
            amount = abs(value) < 0.0000001 ? nil : abs(value)
        }

        func failing(_ issue: RowIssue) -> NormalizedRow {
            NormalizedRow(
                row: rowNumber, title: title, amount: amount, occurredOn: occurredOn,
                sourceCategoryValue: sourceCategory, currency: currencyCode,
                foreignAmount: nil, exchangeRate: nil, notes: notes, issue: issue
            )
        }

        guard let occurredOn else { return failing(.invalidDate) }
        guard let amount else { return failing(.invalidAmount) }
        guard let title, !title.isEmpty else { return failing(.missingTitle) }

        // Currency. No invented rates: a row in a currency the user hasn't
        // given a rate for is held back rather than imported at face value.
        var finalAmount = amount
        var foreignAmount: Double?
        var appliedRate: Double?
        if let currencyCode,
           let baseCurrency = settings.baseCurrency?.uppercased(),
           currencyCode != baseCurrency
        {
            guard let rate = settings.exchangeRates[currencyCode], rate > 0 else {
                return NormalizedRow(
                    row: rowNumber, title: title, amount: amount, occurredOn: occurredOn,
                    sourceCategoryValue: sourceCategory, currency: currencyCode,
                    foreignAmount: amount, exchangeRate: nil, notes: notes,
                    issue: .needsExchangeRate
                )
            }
            foreignAmount = amount
            appliedRate = rate
            finalAmount = (amount * rate * 100).rounded() / 100
        }

        return NormalizedRow(
            row: rowNumber,
            title: String(title.prefix(200)),
            amount: finalAmount,
            occurredOn: occurredOn,
            sourceCategoryValue: sourceCategory,
            currency: currencyCode,
            foreignAmount: foreignAmount,
            exchangeRate: appliedRate,
            notes: notes,
            issue: nil
        )
    }
}

import Foundation

/// The parts of an IBKR *Activity Statement* CSV export the filing pack needs:
/// stock trades, dividend cash lines, withholding-tax cash lines, and the
/// instrument table that carries ISINs. Everything else in the file (Forex,
/// options, interest, fees, NAV) is ignored here and counted so a caller can
/// tell the user what was left out.
///
/// The section/Header/Data layout is the same "flex style" `IBKRSODHTCSVParser`
/// already understands; this type only interprets the rows.
struct IBKRActivityStatement: Sendable, Equatable {
    struct Trade: Sendable, Equatable {
        let symbol: String
        let assetCategory: String
        let currency: String
        let tradeDate: Date
        /// Signed as IBKR reports it: positive buys, negative sells.
        let quantity: Double
        let price: Double
        /// Commission and fees as a positive number.
        let fee: Double
    }

    struct CashLine: Sendable, Equatable {
        let symbol: String
        let isin: String?
        let currency: String
        let date: Date
        let amount: Double
        let description: String
    }

    struct InstrumentInfo: Sendable, Equatable {
        let symbol: String
        let assetCategory: String
        let description: String
        let conid: String?
        let isin: String?
        let listingExchange: String?
        /// IBKR "Type": COMMON, ETF, ADR, REIT, …
        let type: String?
    }

    let trades: [Trade]
    let dividends: [CashLine]
    let withholdingTaxes: [CashLine]
    let instruments: [InstrumentInfo]
    /// Trade rows that were not stock orders (options, forex, sub-totals).
    let skippedTradeRows: Int

    static func parse(_ csv: String) throws -> IBKRActivityStatement {
        let document = try IBKRSODHTCSVParser().parse(csv)
        let sections = { (name: String) in document.sections.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

        var trades: [Trade] = []
        var skipped = 0
        for section in sections("Trades") {
            for row in section.rows {
                let discriminator = row["datadiscriminator"] ?? "Order"
                let category = row["assetcategory"] ?? ""
                guard discriminator.caseInsensitiveCompare("Order") == .orderedSame || discriminator.caseInsensitiveCompare("Trade") == .orderedSame,
                      category.lowercased().hasPrefix("stock"),
                      let symbol = row["symbol"], !symbol.isEmpty,
                      let date = parseDate(row["datetime"] ?? row["date"] ?? ""),
                      let quantity = parseNumber(row["quantity"]),
                      let price = parseNumber(row["tprice"] ?? row["price"] ?? row["tradeprice"])
                else {
                    skipped += 1
                    continue
                }
                trades.append(Trade(
                    symbol: symbol,
                    assetCategory: category,
                    currency: row["currency"] ?? "USD",
                    tradeDate: date,
                    quantity: quantity,
                    price: price,
                    fee: abs(parseNumber(row["commfee"] ?? row["commission"]) ?? 0)
                ))
            }
        }

        let dividends = cashLines(sections("Dividends"))
        let withholding = cashLines(sections("Withholding Tax"))

        // One instrument can trade under several symbols; IBKR then writes
        // them into one quoted field ("CSPX, SXR8"). Register every alias so
        // trades under either symbol find the ISIN and the type.
        let instruments = sections("Financial Instrument Information").flatMap { section in
            section.rows.flatMap { row -> [InstrumentInfo] in
                let symbols = (row["symbol"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return symbols.map { symbol in
                    InstrumentInfo(
                        symbol: symbol,
                        assetCategory: row["assetcategory"] ?? "",
                        description: row["description"] ?? symbol,
                        conid: row["conid"].flatMap { $0.isEmpty ? nil : $0 },
                        isin: row["securityid"].flatMap { $0.isEmpty ? nil : $0.uppercased() },
                        listingExchange: row["listingexch"].flatMap { $0.isEmpty ? nil : $0 },
                        type: row["type"].flatMap { $0.isEmpty ? nil : $0 }
                    )
                }
            }
        }

        return IBKRActivityStatement(
            trades: trades.sorted { $0.tradeDate < $1.tradeDate },
            dividends: dividends,
            withholdingTaxes: withholding,
            instruments: instruments,
            skippedTradeRows: skipped
        )
    }

    /// Dividend and withholding sections share a shape: Currency, Date,
    /// Description, Amount, plus "Total" rows with no date that we drop.
    private static func cashLines(_ sections: [IBKRSODHTCSVParser.Section]) -> [CashLine] {
        sections.flatMap { section in
            section.rows.compactMap { row -> CashLine? in
                guard let currency = row["currency"], !currency.isEmpty, currency.caseInsensitiveCompare("Total") != .orderedSame,
                      let date = parseDate(row["date"] ?? row["settledate"] ?? ""),
                      let amount = parseNumber(row["amount"]),
                      let description = row["description"], !description.isEmpty
                else { return nil }
                let (symbol, isin) = symbolAndISIN(from: description)
                return CashLine(symbol: symbol, isin: isin, currency: currency, date: date, amount: amount, description: description)
            }
        }
    }

    /// "AAPL(US0378331005) Cash Dividend USD 0.25 per Share (Ordinary Dividend)"
    /// → ("AAPL", "US0378331005"). Without the parenthesis the first token is
    /// the symbol and the ISIN is unknown.
    static func symbolAndISIN(from description: String) -> (symbol: String, isin: String?) {
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.firstIndex(of: "("), let close = trimmed[open...].firstIndex(of: ")"), open < close {
            let symbol = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            let inside = String(trimmed[trimmed.index(after: open) ..< close]).trimmingCharacters(in: .whitespaces)
            let looksLikeISIN = inside.count == 12 && inside.prefix(2).allSatisfy(\.isLetter)
            if !symbol.isEmpty, !symbol.contains(" ") {
                return (symbol, looksLikeISIN ? inside.uppercased() : nil)
            }
        }
        let first = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return (first, nil)
    }

    /// "2025-03-14, 09:31:02", "2025-03-14;09:31:02", "2025-03-14", "20250314".
    static func parseDate(_ raw: String) -> Date? {
        let head = raw.trimmingCharacters(in: .whitespaces).prefix(10)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: String(head)) {
            return date
        }
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(head.prefix(8)))
    }

    /// IBKR writes thousands separators ("1,000") inside quoted fields.
    static func parseNumber(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
}

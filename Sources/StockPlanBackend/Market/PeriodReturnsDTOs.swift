import Vapor

// MARK: - /v1/market/returns response

/// Trailing 3-month, 6-month, and calendar year-to-date percent moves for one
/// symbol. Values are percent points (12.5 means +12.5%), matching
/// `QuoteResponse.percentChange`. A nil window means that period is unavailable
/// (IPO, missing FMP coverage) — never a fabricated 0.
struct StockPeriodReturnsResponse: Content, Equatable, Sendable {
    let symbol: String
    let threeMonth: Double?
    let sixMonth: Double?
    let yearToDate: Double?
    let asOf: String?

    var hasUsableWindows: Bool {
        threeMonth != nil || sixMonth != nil || yearToDate != nil
    }
}

struct StockPeriodReturnsBatchResponse: Content, Equatable, Sendable {
    let returns: [StockPeriodReturnsResponse]
}

// MARK: - FMP /stable/stock-price-change wire model

/// FMP returns every window in one object. Keys have been `3M`/`6M`/`ytd` and
/// occasionally `YTD`; unknown extra periods are ignored.
struct FMPStockPriceChange: Decodable, Sendable, Equatable {
    let symbol: String
    let threeMonth: Double?
    let sixMonth: Double?
    let yearToDate: Double?

    init(symbol: String, threeMonth: Double?, sixMonth: Double?, yearToDate: Double?) {
        self.symbol = symbol
        self.threeMonth = threeMonth
        self.sixMonth = sixMonth
        self.yearToDate = yearToDate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        symbol = try container.decode(String.self, forKey: DynamicCodingKey("symbol"))
        threeMonth = decodeFlexibleDouble(container, keys: ["3M", "3m"])
        sixMonth = decodeFlexibleDouble(container, keys: ["6M", "6m"])
        yearToDate = decodeFlexibleDouble(container, keys: ["ytd", "YTD"])
    }
}

func mapFMPPriceChange(_ item: FMPStockPriceChange) -> StockPeriodReturnsResponse {
    StockPeriodReturnsResponse(
        symbol: item.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
        threeMonth: item.threeMonth,
        sixMonth: item.sixMonth,
        yearToDate: item.yearToDate,
        asOf: nil
    )
}

func emptyPeriodReturns(symbol: String) -> StockPeriodReturnsResponse {
    StockPeriodReturnsResponse(
        symbol: symbol.uppercased(),
        threeMonth: nil,
        sixMonth: nil,
        yearToDate: nil,
        asOf: nil
    )
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func decodeFlexibleDouble(
    _ container: KeyedDecodingContainer<DynamicCodingKey>,
    keys: [String]
) -> Double? {
    for key in keys {
        let codingKey = DynamicCodingKey(key)
        if let value = try? container.decode(Double.self, forKey: codingKey) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: codingKey) {
            return Double(value)
        }
        if let raw = try? container.decode(String.self, forKey: codingKey),
           let value = Double(raw)
        {
            return value
        }
    }
    return nil
}

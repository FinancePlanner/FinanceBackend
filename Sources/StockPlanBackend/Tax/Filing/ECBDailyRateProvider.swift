import Foundation
import Vapor

/// ECB Data Portal, flow `EXR`, key `D.<QUOTE>.EUR.SP00.A`, as CSV.
/// Keyless and free — the same host `ECBMacroEnrichment` already uses.
/// Docs: https://data.ecb.europa.eu/help/api/data
struct ECBDailyRateProvider: FXDailyRateProviding {
    let client: any Client
    var baseURL: String = "https://data-api.ecb.europa.eu/service/data"

    func rates(quote: String, from: Date, to: Date) async throws -> [FXDailyRate] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let normalizedQuote = quote.uppercased()
        let key = "D.\(normalizedQuote).EUR.SP00.A"
        let uri = URI(string: "\(baseURL)/EXR/\(key)?startPeriod=\(formatter.string(from: from))&endPeriod=\(formatter.string(from: to))&format=csvdata")

        let response = try await client.get(uri, headers: ["Accept": "text/csv"]) { clientRequest in
            clientRequest.timeout = .seconds(15)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "ECB EXR \(normalizedQuote) returned \(response.status.code)")
        }
        guard let buffer = response.body else { return [] }
        return Self.parseCSV(String(buffer: buffer), quote: normalizedQuote, formatter: formatter)
    }

    /// `csvdata` has one header row; the columns we need are TIME_PERIOD and
    /// OBS_VALUE, located by name so a column reorder does not break parsing.
    static func parseCSV(_ body: String, quote: String, formatter: DateFormatter) -> [FXDailyRate] {
        var lines = body.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first else { return [] }
        lines.removeFirst()
        let columns = header.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let timeIndex = columns.firstIndex(of: "TIME_PERIOD"),
              let valueIndex = columns.firstIndex(of: "OBS_VALUE")
        else { return [] }
        return lines.compactMap { line in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > max(timeIndex, valueIndex),
                  let date = formatter.date(from: parts[timeIndex].trimmingCharacters(in: .whitespaces)),
                  let rate = Decimal(string: parts[valueIndex].trimmingCharacters(in: .whitespaces)),
                  rate > 0
            else { return nil }
            return FXDailyRate(date: date, base: "EUR", quote: quote, rate: rate)
        }
    }
}

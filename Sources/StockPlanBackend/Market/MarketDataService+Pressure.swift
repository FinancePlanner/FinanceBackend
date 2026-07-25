import Foundation
import Vapor

/// Defaults keep pre-existing MarketDataService conformers (test stubs)
/// compiling; DefaultMarketDataService overrides with the real assembly.
extension MarketDataService {
    func marketPressure(symbol _: String, on _: Request) async throws -> MarketPressureResponse {
        throw Abort(.serviceUnavailable, reason: "Market pressure is not supported by this provider.")
    }
}

private enum MarketPressureConfig {
    static let ttlSeconds = Environment.get("MARKET_PRESSURE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 300
    static let insiderWindowDays = 90
    static let insiderFetchLimit = 100
    static let historySessions = 30
    static let notableLimit = 5

    static func redisKey(_ symbol: String) -> String {
        "market:pressure:v1:\(symbol)"
    }
}

extension DefaultMarketDataService {
    func marketPressure(symbol rawSymbol: String, on req: Request) async throws -> MarketPressureResponse {
        let symbol = try normalizeSymbol(rawSymbol)
        let cacheKey = MarketPressureConfig.redisKey(symbol)
        if let cached = await redisGetValue(cacheKey, as: MarketPressureResponse.self, on: req) {
            return cached
        }
        guard let fmp = fmpProvider else {
            throw Abort(.serviceUnavailable, reason: "Market pressure requires the FMP provider.")
        }

        async let quotesTask = fmp.fetchStockQuotes(symbols: [symbol], on: req)
        async let historyTask = fmp.stockHistoricalEOD(
            symbol: symbol,
            from: pressureDateString(daysAgo: 75),
            to: pressureDateString(daysAgo: 0),
            on: req
        )
        async let insiderTask = loadInsider(fmp: fmp, symbol: symbol, on: req)

        guard let quote = try await quotesTask.first else {
            throw Abort(.notFound, reason: "No quote available for \(symbol).")
        }
        let history = try await historyTask
            .filter { ($0.volume ?? 0) > 0 }
            .sorted { $0.date < $1.date }
        let insider = await insiderTask

        let volumes = history.compactMap(\.volume)
        let todayVolume = quote.volume ?? volumes.last ?? 0
        let baseline = volumes.suffix(MarketPressureConfig.historySessions)
        let average = baseline.isEmpty ? 0 : baseline.reduce(0, +) / Double(baseline.count)
        let relative = average > 0 ? todayVolume / average : 0

        let historyPoints = relativeVolumeHistory(history: history)
        let temperature = pressureTemperature(
            relativeVolume: relative,
            changePct: quote.changePercentage,
            insider: insider
        )

        let response = MarketPressureResponse(
            symbol: symbol,
            asOf: ISO8601DateFormatter().string(from: Date()),
            temperature: temperature,
            label: pressureLabel(temperature),
            volume: MarketPressureVolume(
                today: todayVolume,
                average30d: average,
                relative: (relative * 100).rounded() / 100,
                changePct: quote.changePercentage
            ),
            insider: insider,
            history: historyPoints
        )
        await redisSetValue(cacheKey, value: response, ttlSeconds: MarketPressureConfig.ttlSeconds, on: req)
        return response
    }

    /// Insider failures degrade to nil (the section hides) rather than
    /// failing the whole snapshot.
    private func loadInsider(
        fmp: any FMPMarketDataProvider,
        symbol: String,
        on req: Request
    ) async -> MarketPressureInsider? {
        do {
            let trades = try await fmp.fetchInsiderTrades(
                symbol: symbol,
                limit: MarketPressureConfig.insiderFetchLimit,
                on: req
            )
            let cutoff = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -MarketPressureConfig.insiderWindowDays,
                to: Date()
            ) ?? Date()
            let cutoffString = pressureDayFormatter.string(from: cutoff)

            var buys = 0
            var sells = 0
            var netShares = 0.0
            var lastActivity: String?
            var notable: [MarketPressureInsiderTrade] = []

            for trade in trades {
                guard let date = trade.transactionDate, date >= cutoffString else { continue }
                let shares = trade.securitiesTransacted ?? 0
                guard shares > 0 else { continue }
                let isBuy = pressureIsBuy(trade)
                if isBuy {
                    buys += 1
                    netShares += shares
                } else {
                    sells += 1
                    netShares -= shares
                }
                if lastActivity == nil || date > lastActivity! {
                    lastActivity = date
                }
                notable.append(MarketPressureInsiderTrade(
                    name: trade.reportingName ?? "Insider",
                    role: trade.typeOfOwner,
                    side: isBuy ? "buy" : "sell",
                    shares: shares,
                    date: date
                ))
            }
            notable.sort { $0.shares > $1.shares }
            return MarketPressureInsider(
                windowDays: MarketPressureConfig.insiderWindowDays,
                buyCount: buys,
                sellCount: sells,
                netShares: netShares,
                lastActivityAt: lastActivity,
                notable: Array(notable.prefix(MarketPressureConfig.notableLimit))
            )
        } catch {
            req.logger.warning("market.pressure insider failed symbol=\(symbol) error=\(error)")
            return nil
        }
    }

    private func relativeVolumeHistory(history: [CryptoHistoricalLightPoint]) -> [MarketPressureHistoryPoint] {
        let sessions = history.suffix(MarketPressureConfig.historySessions + 1)
        guard sessions.count > 1 else { return [] }
        var points: [MarketPressureHistoryPoint] = []
        let list = Array(sessions)
        for index in 1 ..< list.count {
            let trailing = list[max(0, index - MarketPressureConfig.historySessions) ..< index].compactMap(\.volume)
            guard !trailing.isEmpty, let volume = list[index].volume else { continue }
            let avg = trailing.reduce(0, +) / Double(trailing.count)
            guard avg > 0 else { continue }
            points.append(MarketPressureHistoryPoint(
                date: list[index].date,
                relativeVolume: ((volume / avg) * 100).rounded() / 100
            ))
        }
        return points
    }
}

/// 0–100 blend: 50 = balanced. Direction comes from the day's price move,
/// intensity from relative volume, tilted by 90-day insider net flow.
func pressureTemperature(
    relativeVolume: Double,
    changePct: Double,
    insider: MarketPressureInsider?
) -> Double {
    let intensity = min(max(relativeVolume, 0), 3) / 3 // 0…1
    let direction = max(-1.0, min(1.0, changePct / 2)) // saturate at ±2%
    var score = 50.0 + direction * intensity * 35

    if let insider, insider.buyCount + insider.sellCount > 0 {
        let gross = abs(insider.netShares)
        if gross > 0 {
            let tilt = insider.netShares / gross // -1…1 by sign
            let weight = min(Double(insider.buyCount + insider.sellCount), 10) / 10
            score += tilt * weight * 15
        }
    }
    return min(100, max(0, (score * 10).rounded() / 10))
}

func pressureLabel(_ temperature: Double) -> String {
    switch temperature {
    case ..<20: "heavy selling"
    case ..<40: "selling"
    case ..<60: "balanced"
    case ..<80: "buying"
    default: "heavy buying"
    }
}

private func pressureIsBuy(_ trade: FMPInsiderTrade) -> Bool {
    if let acquisition = trade.acquisitionOrDisposition?.uppercased() {
        if acquisition.hasPrefix("A") {
            return true
        }
        if acquisition.hasPrefix("D") {
            return false
        }
    }
    let type = trade.transactionType?.uppercased() ?? ""
    return type.hasPrefix("P") || type.contains("PURCHASE") || type.contains("BUY")
}

private let pressureDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private func pressureDateString(daysAgo: Int) -> String {
    let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    return pressureDayFormatter.string(from: date)
}

import Foundation
import StockPlanShared
import Vapor

/// Macro / Inflation controller (global Nowflation-style data).
/// Rate limiting is applied once by the `/v1/macro` group in routes.swift.
struct MacroController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let macro = routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.marketRead))
            .grouped("macro")

        macro.get("inflation", "current", use: getCurrentInflation)
        macro.get("inflation", "components", use: getComponents)
        macro.get("top-movers", use: getTopMovers)
        macro.get("inflation", "series", use: getSeries)
        macro.get("inflation", "personal", use: getPersonalInflation)
        macro.get("supported-countries", use: getSupportedCountries)
        macro.get("fed-watch", use: getFedWatch)
        macro.get("policy-watch", use: getPolicyWatch)
        macro.get("housing", use: getHousing)
        macro.get("economy", use: getEconomy)
        macro.get("items", use: getItems)
        macro.get("items", ":itemId", "series", use: getItemSeries)
    }

    /// Unknown/absent `country` falls back to US (documented legacy behavior).
    private func country(from req: Request) -> MacroCountry {
        MacroCountry(query: req.query[String.self, at: "country"]) ?? .us
    }

    // MARK: - Current snapshot

    @Sendable
    func getCurrentInflation(req: Request) async throws -> InflationSnapshotResponse {
        try await req.application.macroService.currentInflation(country: country(from: req), on: req)
    }

    // MARK: - Components

    @Sendable
    func getComponents(req: Request) async throws -> [InflationComponentDTO] {
        let snapshot = try await getCurrentInflation(req: req)
        return snapshot.components
    }

    // MARK: - Top movers

    @Sendable
    func getTopMovers(req: Request) async throws -> [TopMoverDTO] {
        let snapshot = try await getCurrentInflation(req: req)
        if let focus = req.query[String.self, at: "focus"] {
            let wanted = focus.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return snapshot.topMovers.filter { mover in
                wanted.contains { mover.category.lowercased().contains($0) }
            }
        }
        return snapshot.topMovers
    }

    // MARK: - Series (history)

    @Sendable
    func getSeries(req: Request) async throws -> MacroSeriesResponse {
        try await req.application.macroService.series(
            country: country(from: req),
            rawSeries: req.query[String.self, at: "series"],
            from: req.query[String.self, at: "from"],
            to: req.query[String.self, at: "to"],
            limit: req.query[Int.self, at: "limit"] ?? 120,
            on: req
        )
    }

    @Sendable
    func getPersonalInflation(req: Request) async throws -> PersonalInflationResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.macroService.personalInflation(
            userID: session.userId,
            country: country(from: req),
            periodMonths: req.query[Int.self, at: "months"] ?? 12,
            on: req
        )
    }

    // MARK: - Supported countries

    @Sendable
    func getSupportedCountries(req: Request) async throws -> [SupportedCountry] {
        req.application.macroService.supportedCountries()
    }

    // MARK: - Fed Watch

    @Sendable
    func getFedWatch(req: Request) async throws -> FedWatchResponse {
        try await req.application.macroService.fedWatch(on: req)
    }

    // MARK: - Policy / Housing / Economy hubs

    @Sendable
    func getPolicyWatch(req: Request) async throws -> PolicyWatchResponse {
        try await req.application.macroService.policyWatch(country: country(from: req), on: req)
    }

    @Sendable
    func getHousing(req: Request) async throws -> HousingHubResponse {
        try await req.application.macroService.housing(country: country(from: req), on: req)
    }

    @Sendable
    func getEconomy(req: Request) async throws -> EconomyHubResponse {
        try await req.application.macroService.economy(country: country(from: req), on: req)
    }

    // MARK: - Items

    @Sendable
    func getItems(req: Request) async throws -> MacroItemsResponse {
        try await req.application.macroService.items(country: country(from: req), on: req)
    }

    @Sendable
    func getItemSeries(req: Request) async throws -> MacroItemSeriesResponse {
        guard let itemID = req.parameters.get("itemId") else {
            throw Abort(.badRequest, reason: "Missing item id.")
        }
        return try await req.application.macroService.itemSeries(
            itemID: itemID,
            country: country(from: req),
            from: req.query[String.self, at: "from"],
            to: req.query[String.self, at: "to"],
            limit: req.query[Int.self, at: "limit"] ?? 120,
            on: req
        )
    }
}

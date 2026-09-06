import Fluent
import Foundation
import StockPlanShared
import Vapor

struct RetirementController: RouteCollection {
    let registry = RetirementRuleRegistry()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.planningRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.planningWrite))

        read.get("retirement", "rules", ":jurisdiction", use: rules)
        read.get("portfolios", ":portfolioId", "retirement", use: getPlan)
        write.group("portfolios", ":portfolioId", "retirement") { retirement in
            retirement.put(use: upsertPlan)
            retirement.post("refresh-rules", use: refreshRules)
            retirement.post("projection", use: projection)
        }
    }

    @Sendable
    func rules(req: Request) async throws -> RetirementRulePack {
        guard let raw = req.parameters.get("jurisdiction")?.uppercased(),
              let jurisdiction = TaxJurisdiction(rawValue: raw)
        else { throw Abort(.badRequest, reason: "Unsupported tax jurisdiction.") }
        let version: String? = req.query["version"]
        guard let pack = registry.rulePack(jurisdiction: jurisdiction, version: version) else {
            throw Abort(.notFound, reason: "Retirement rule version not found.")
        }
        return pack
    }

    @Sendable
    func getPlan(req: Request) async throws -> RetirementPlan {
        let (context, record) = try await requirePlan(req, editing: false)
        return try makePlan(record, portfolioId: context.portfolio.requireID())
    }

    @Sendable
    func upsertPlan(req: Request) async throws -> RetirementPlan {
        let session = try req.auth.require(SessionToken.self)
        let portfolioId = try parameter(req, "portfolioId")
        let context = try await req.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: session.userId,
            editing: true,
            on: req.db
        )
        guard context.portfolio.purpose == PortfolioPurpose.retirement.rawValue else {
            throw Abort(.badRequest, reason: "Retirement planning requires a retirement portfolio.")
        }
        let payload = try req.content.decode(RetirementPlanUpsertRequest.self)
        guard registry.rulePack(jurisdiction: payload.input.jurisdiction, version: payload.ruleVersion) != nil else {
            throw Abort(.badRequest, reason: "Unsupported retirement rule version.")
        }
        let inputJSON = try encode(payload.input)
        let record = try await RetirementPlanRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .first() ?? RetirementPlanRecord(
                portfolioId: portfolioId,
                ruleVersion: payload.ruleVersion ?? RetirementRuleRegistry.currentVersion,
                inputJSON: inputJSON
            )
        record.ruleVersion = payload.ruleVersion ?? RetirementRuleRegistry.currentVersion
        record.inputJSON = inputJSON
        try await record.save(on: req.db)
        return try makePlan(record, portfolioId: portfolioId)
    }

    @Sendable
    func refreshRules(req: Request) async throws -> RetirementPlan {
        let (context, record) = try await requirePlan(req, editing: true)
        record.ruleVersion = RetirementRuleRegistry.currentVersion
        try await record.save(on: req.db)
        return try makePlan(record, portfolioId: context.portfolio.requireID())
    }

    @Sendable
    func projection(req: Request) async throws -> RetirementProjection {
        let (context, record) = try await requirePlan(req, editing: false)
        let request = try req.content.decode(RetirementProjectionRequest.self)
        let input = try decode(RetirementPlanInput.self, from: record.inputJSON)
        let effective = RetirementProjectionRequest(
            ruleVersion: request.ruleVersion ?? record.ruleVersion,
            pathCount: request.pathCount,
            seed: request.seed
        )
        return try RetirementProjectionEngine(rules: registry).project(
            portfolioId: context.portfolio.requireID(),
            input: input,
            request: effective
        )
    }

    private func requirePlan(
        _ req: Request,
        editing: Bool
    ) async throws -> (PortfolioAccessContext, RetirementPlanRecord) {
        let session = try req.auth.require(SessionToken.self)
        let portfolioId = try parameter(req, "portfolioId")
        let context = try await req.portfolioAccessService.require(
            portfolioId: portfolioId,
            userId: session.userId,
            editing: editing,
            on: req.db
        )
        guard let record = try await RetirementPlanRecord.query(on: req.db)
            .filter(\.$portfolioId == portfolioId)
            .first()
        else { throw Abort(.notFound, reason: "Retirement plan not found.") }
        return (context, record)
    }

    private func makePlan(_ record: RetirementPlanRecord, portfolioId: UUID) throws -> RetirementPlan {
        try RetirementPlan(
            id: record.requireID().uuidString,
            portfolioId: portfolioId.uuidString,
            ruleVersion: record.ruleVersion,
            input: decode(RetirementPlanInput.self, from: record.inputJSON),
            newerRuleVersion: record.ruleVersion == RetirementRuleRegistry.currentVersion
                ? nil
                : RetirementRuleRegistry.currentVersion,
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    private func parameter(_ req: Request, _ name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return id
    }

    private func encode(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder.backendAPI.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode retirement plan.")
        }
        return string
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        try JSONDecoder.backendAPI.decode(type, from: Data(value.utf8))
    }
}

import Foundation
import StockPlanShared
import Vapor

extension FinancingSimulationRequest: @retroactive Content {}
extension FinancingSimulationResponse: @retroactive Content {}
extension FinancingAffordabilityAssumptions: @retroactive Content {}
extension FinancingPlanRequest: @retroactive Content {}
extension FinancingPlanResponse: @retroactive Content {}
extension FinancingPlanRevisionRequest: @retroactive Content {}
extension FinancingPlanStatusRequest: @retroactive Content {}
extension FinancingProjectionResponse: @retroactive Content {}
extension FinancingExpenseMatchRequest: @retroactive Content {}
extension FinancingExpenseMatchResponse: @retroactive Content {}
extension FinancingMatchCandidateResponse: @retroactive Content {}
extension FinancingURLImportRequest: @retroactive Content {}
extension FinancingImportResponse: @retroactive Content {}

struct FinancingController: RouteCollection {
    private let service = FinancingService()
    private let maxImportBytes = 8 * 1024 * 1024

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let financing = protected.grouped("financing")
        financing.post("simulations", use: simulate)
        financing.get("assumptions", use: getAssumptions)
        financing.put("assumptions", use: putAssumptions)
        financing.get("projections", use: projections)
        financing.get("match-candidates", ":expenseId", use: matchCandidates)
        financing.get("plans", use: plans)
        financing.post("plans", use: createPlan)
        financing.post("imports", "url", use: importURL)
        financing.on(.POST, "imports", "file", body: .collect(maxSize: "8mb"), use: importFile)
        financing.group("plans", ":planId") { plan in
            plan.get("schedule", use: schedule)
            plan.patch(use: updateStatus)
            plan.post("revisions", use: revise)
            plan.post("installments", ":installment", "match", use: match)
            plan.delete("installments", ":installment", "match", use: unmatch)
        }
    }

    @Sendable func simulate(req: Request) async throws -> FinancingSimulationResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(FinancingSimulationRequest.self)
        if payload.offers.count > 1 {
            try await requirePro(userId: session.userId, req: req)
        }
        return try await service.simulation(userId: session.userId, request: payload, on: req.db)
    }

    @Sendable func getAssumptions(req: Request) async throws -> FinancingAffordabilityAssumptions {
        let session = try req.auth.require(SessionToken.self)
        return try await service.assumptions(userId: session.userId, on: req.db)
    }

    @Sendable func putAssumptions(req: Request) async throws -> FinancingAffordabilityAssumptions {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(FinancingAffordabilityAssumptions.self)
        return try await service.updateAssumptions(userId: session.userId, value: payload, on: req.db)
    }

    @Sendable func plans(req: Request) async throws -> [FinancingPlanResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await service.plans(userId: session.userId, on: req.db)
    }

    @Sendable func createPlan(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await requirePro(userId: session.userId, req: req)
        let created = try await service.createPlan(userId: session.userId, request: req.content.decode(FinancingPlanRequest.self), on: req.db)
        let response = Response(status: .created)
        try response.content.encode(created)
        return response
    }

    @Sendable func updateStatus(req: Request) async throws -> FinancingPlanResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requirePro(userId: session.userId, req: req)
        return try await service.updateStatus(userId: session.userId, planId: planId(req), status: req.content.decode(FinancingPlanStatusRequest.self).status, on: req.db)
    }

    @Sendable func revise(req: Request) async throws -> FinancingPlanResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requirePro(userId: session.userId, req: req)
        return try await service.revise(userId: session.userId, planId: planId(req), request: req.content.decode(FinancingPlanRevisionRequest.self), on: req.db)
    }

    @Sendable func schedule(req: Request) async throws -> [FinancingProjectionResponse] {
        let session = try req.auth.require(SessionToken.self)
        return try await service.schedule(userId: session.userId, planId: planId(req), on: req.db)
    }

    @Sendable func projections(req: Request) async throws -> [FinancingProjectionResponse] {
        let session = try req.auth.require(SessionToken.self)
        let from = req.query[String.self, at: "from"].flatMap(FinancingCalculator.dayFormatter.date(from:))
        let to = req.query[String.self, at: "to"].flatMap(FinancingCalculator.dayFormatter.date(from:))
        return try await service.projections(userId: session.userId, from: from, to: to, on: req.db)
    }

    @Sendable func match(req: Request) async throws -> FinancingExpenseMatchResponse {
        let session = try req.auth.require(SessionToken.self)
        let installment = try installment(req)
        let payload = try req.content.decode(FinancingExpenseMatchRequest.self)
        guard let expenseId = UUID(uuidString: payload.expenseId) else { throw Abort(.badRequest) }
        return try await service.match(userId: session.userId, planId: planId(req), installment: installment, expenseId: expenseId, on: req.db)
    }

    @Sendable func matchCandidates(req: Request) async throws -> [FinancingMatchCandidateResponse] {
        let session = try req.auth.require(SessionToken.self)
        guard let raw = req.parameters.get("expenseId"), let expenseId = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return try await service.matchCandidates(userId: session.userId, expenseId: expenseId, on: req.db)
    }

    @Sendable func unmatch(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await service.unmatch(userId: session.userId, planId: planId(req), installment: installment(req), on: req.db)
        return .noContent
    }

    @Sendable func importURL(req: Request) async throws -> FinancingImportResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requirePro(userId: session.userId, req: req)
        let raw = try req.content.decode(FinancingURLImportRequest.self).url
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !Self.blockedHost(host)
        else { throw Abort(.badRequest, reason: "Only public HTTPS offer pages can be imported.") }
        let headers = HTTPHeaders([("User-Agent", "Norviq Financing Import/1.0")])
        let response = try await req.client.get(URI(string: raw), headers: headers)
        guard response.status == HTTPResponseStatus.ok, let body = response.body, body.readableBytes <= maxImportBytes else {
            throw Abort(.badRequest, reason: "The offer page could not be imported.")
        }
        return FinancingOfferExtractor.extract(text: body.getString(at: body.readerIndex, length: body.readableBytes) ?? "", sourceDomain: host)
    }

    private struct ImportUpload: Content { var file: File? }

    @Sendable func importFile(req: Request) async throws -> FinancingImportResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requirePro(userId: session.userId, req: req)
        let upload = try req.content.decode(ImportUpload.self)
        guard var buffer = upload.file?.data, buffer.readableBytes <= maxImportBytes else { throw Abort(.badRequest, reason: "Missing or oversized file.") }
        let text = buffer.readString(length: buffer.readableBytes) ?? ""
        guard !text.isEmpty else {
            return .init(recognized: false, draft: nil, warnings: ["This file has no extractable text. Use a text-based PDF or enter the terms manually."])
        }
        return FinancingOfferExtractor.extract(text: text, sourceDomain: nil)
    }

    private func requirePro(userId: UUID, req: Request) async throws {
        try await req.usageCounterService.requirePremium(.scenarioPlanning, userId: userId, on: req.db)
    }

    private func planId(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("planId"), let value = UUID(uuidString: raw) else { throw Abort(.badRequest) }
        return value
    }

    private func installment(_ req: Request) throws -> Int {
        guard let raw = req.parameters.get("installment"), let value = Int(raw), value > 0 else { throw Abort(.badRequest) }
        return value
    }

    /// Delegates to the shared guard so there is one copy of the blocked-host
    /// list. Bring-your-own-key needs the same check on a user-supplied base
    /// URL, and two drifting copies of an SSRF filter is how one gets missed.
    private static func blockedHost(_ host: String) -> Bool {
        OutboundURLGuard.isBlockedHost(host)
    }
}

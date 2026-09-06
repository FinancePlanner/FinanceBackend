import Foundation
import StockPlanShared
import Vapor

struct RebalancingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.planningRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.planningWrite))

        read.get("rebalancing", "dashboard", use: dashboard)
        read.get("rebalancing", "alerts", use: alerts)
        write.post("rebalancing", "alerts", ":alertId", "acknowledge", use: acknowledgeAlert)

        read.group("portfolios", ":portfolioId", "rebalancing") { rebalancing in
            rebalancing.get("models", use: models)
            rebalancing.get("overview", use: overview)
            rebalancing.get("plans", use: plans)
            rebalancing.get("plans", ":planId", "export.csv", use: exportCSV)
            rebalancing.get("plans", ":planId", "export.pdf", use: exportPDF)
            rebalancing.get("history", use: history)
            rebalancing.get("preferences", use: preferences)
        }
        write.group("portfolios", ":portfolioId", "rebalancing") { rebalancing in
            rebalancing.post("models", use: createModel)
            rebalancing.put("models", ":modelId", use: updateModel)
            rebalancing.post("models", ":modelId", "activate", use: activateModel)
            rebalancing.post("models", ":modelId", "copy", use: copyModel)
            rebalancing.post("simulate", use: simulate)
            rebalancing.post("plans", use: createPlan)
            rebalancing.post("plans", ":planId", "complete", use: completePlan)
            rebalancing.post("plans", ":planId", "cancel", use: cancelPlan)
            rebalancing.put("preferences", use: updatePreferences)
        }
    }

    @Sendable
    func models(req: Request) async throws -> [AllocationModel] {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.models(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func createModel(req: Request) async throws -> Response {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let model = try await req.rebalancingService.createModel(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            payload: req.content.decode(AllocationModelUpsertRequest.self),
            req: req
        )
        let response = Response(status: .created)
        try response.content.encode(model)
        return response
    }

    @Sendable
    func updateModel(req: Request) async throws -> AllocationModel {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.updateModel(
            portfolioId: parameter(req, "portfolioId"),
            modelId: parameter(req, "modelId"),
            userId: session.userId,
            payload: req.content.decode(AllocationModelUpsertRequest.self),
            req: req
        )
    }

    @Sendable
    func activateModel(req: Request) async throws -> AllocationModel {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.activateModel(
            portfolioId: parameter(req, "portfolioId"),
            modelId: parameter(req, "modelId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func copyModel(req: Request) async throws -> AllocationModelBulkCopyResult {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.copyModel(
            portfolioId: parameter(req, "portfolioId"),
            modelId: parameter(req, "modelId"),
            userId: session.userId,
            payload: req.content.decode(AllocationModelBulkCopyRequest.self),
            req: req
        )
    }

    @Sendable
    func overview(req: Request) async throws -> RebalancingOverview {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.overview(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func simulate(req: Request) async throws -> RebalancingSimulation {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.simulate(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            payload: req.content.decode(RebalancingSimulationRequest.self),
            req: req
        )
    }

    @Sendable
    func plans(req: Request) async throws -> [RebalancePlan] {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.plans(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func createPlan(req: Request) async throws -> Response {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let plan = try await req.rebalancingService.createPlan(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            payload: req.content.decode(RebalancePlanCreateRequest.self),
            req: req
        )
        let response = Response(status: .created)
        try response.content.encode(plan)
        return response
    }

    @Sendable
    func completePlan(req: Request) async throws -> RebalancePlan {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let payload = try? req.content.decode(RebalancePlanCompletionRequest.self)
        return try await req.rebalancingService.transitionPlan(
            portfolioId: parameter(req, "portfolioId"),
            planId: parameter(req, "planId"),
            userId: session.userId,
            status: .completed,
            note: payload?.note,
            req: req
        )
    }

    @Sendable
    func cancelPlan(req: Request) async throws -> RebalancePlan {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.transitionPlan(
            portfolioId: parameter(req, "portfolioId"),
            planId: parameter(req, "planId"),
            userId: session.userId,
            status: .cancelled,
            note: nil,
            req: req
        )
    }

    @Sendable
    func history(req: Request) async throws -> RebalancingHistorySummary {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.history(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func alerts(req: Request) async throws -> [RebalancingAlert] {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.alerts(userId: session.userId, req: req)
    }

    @Sendable
    func acknowledgeAlert(req: Request) async throws -> RebalancingAlert {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.acknowledge(
            alertId: parameter(req, "alertId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func preferences(req: Request) async throws -> RebalancingNotificationPreferences {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.preferences(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            req: req
        )
    }

    @Sendable
    func updatePreferences(req: Request) async throws -> RebalancingNotificationPreferences {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.updatePreferences(
            portfolioId: parameter(req, "portfolioId"),
            userId: session.userId,
            payload: req.content.decode(UpdateRebalancingNotificationPreferencesRequest.self),
            req: req
        )
    }

    @Sendable
    func dashboard(req: Request) async throws -> RebalancingDashboardSummary {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        return try await req.rebalancingService.dashboard(userId: session.userId, req: req)
    }

    @Sendable
    func exportCSV(req: Request) async throws -> Response {
        let plan = try await exportedPlan(req: req)
        let header = "side,symbol,quantity,price,notional,estimated_fee,estimated_cost_basis,estimated_realized_gain_loss,currency"
        let rows = plan.trades.map { trade in
            [
                trade.side.rawValue,
                trade.symbol,
                number(trade.quantity),
                number(trade.price),
                number(trade.notional),
                number(trade.estimatedFee),
                trade.estimatedCostBasis.map(number) ?? "",
                trade.estimatedRealizedGainLoss.map(number) ?? "",
                trade.currency,
            ].map(csvField).joined(separator: ",")
        }
        let response = Response(status: .ok, body: .init(string: ([header] + rows).joined(separator: "\r\n") + "\r\n"))
        response.headers.contentType = .init(type: "text", subType: "csv", parameters: ["charset": "utf-8"])
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"rebalance-\(plan.id).csv\""
        )
        return response
    }

    @Sendable
    func exportPDF(req: Request) async throws -> Response {
        let plan = try await exportedPlan(req: req)
        let lines = [
            "Norviq Rebalancing Plan",
            "Portfolio: \(plan.portfolioId)",
            "Status: \(plan.status.rawValue)",
            "Drift: \(basisPoints(plan.driftBeforeBasisPoints)) -> \(basisPoints(plan.driftAfterBasisPoints))",
            "Estimated fees: \(plan.baseCurrency) \(number(plan.estimatedFees))",
            "Estimated realized gain/loss: \(plan.baseCurrency) \(number(plan.estimatedRealizedGainLoss))",
            "",
        ] + plan.trades.map { trade in
            "\(trade.side.rawValue.uppercased()) \(trade.symbol)  \(number(trade.quantity)) @ \(number(trade.price))  \(trade.currency) \(number(trade.notional))"
        } + ["", "Planning record only. Norviq did not place these orders. Tax figures are estimates, not tax advice."]
        let response = Response(status: .ok, body: .init(data: MinimalRebalancingPDF.make(lines: lines)))
        response.headers.contentType = .pdf
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"rebalance-\(plan.id).pdf\""
        )
        return response
    }

    private func exportedPlan(req: Request) async throws -> RebalancePlan {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let portfolioId = try parameter(req, "portfolioId")
        let planId = try parameter(req, "planId")
        let available = try await req.rebalancingService.plans(portfolioId: portfolioId, userId: session.userId, req: req)
        guard let plan = available.first(where: { $0.id == planId.uuidString }) else {
            throw Abort(.notFound, reason: "Rebalancing plan not found.")
        }
        return plan
    }

    private func requireEnabled() throws {
        guard envBool("REBALANCING_ENABLED", default: true) else { throw Abort(.notFound) }
    }

    private func parameter(_ req: Request, _ name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return id
    }

    private func number(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func basisPoints(_ value: Int) -> String {
        String(format: "%.2f%%", Double(value) / 100)
    }

    private func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private enum MinimalRebalancingPDF {
    static func make(lines: [String]) -> Data {
        let text = lines.prefix(52).enumerated().map { index, line in
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            return index == 0 ? "BT /F1 18 Tf 54 760 Td (\(escaped)) Tj ET" : "BT /F1 10 Tf 54 \(738 - index * 13) Td (\(escaped)) Tj ET"
        }.joined(separator: "\n")
        let stream = Data(text.utf8)
        var objects = [Data]()
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".utf8))
        objects.append(Data("<< /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("\nendstream".utf8))
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))

        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8))
            data.append(object)
            data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF".utf8))
        return data
    }
}

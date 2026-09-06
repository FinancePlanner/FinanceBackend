import Crypto
import Fluent
import Foundation
import Redis
import Vapor

private struct FinancialGoalInput: Content {
    let portfolioListId: UUID
    let name: String
    let targetAmount: Double
    let targetDate: Date
    let baseCurrency: String
    let monthlyContribution: Double?
    let annualContributionGrowth: Double?
    let inflationAssumption: Double?
}

private struct ScenarioInput: Content {
    let portfolioListId: UUID
    let financialGoalId: UUID?
    let name: String
    let kind: String
    let configuration: ScenarioJSON
    let isSaved: Bool?
}

private struct SnapshotInput: Content {
    let portfolioListId: UUID
    let baseCurrency: String
    let valuationTimestamp: Date?
    let payload: ScenarioJSON?
    let warnings: ScenarioJSON?
    let cryptoHoldingIds: [UUID]?
}

private struct RunInput: Content {
    let snapshotId: UUID
    let seed: UInt64?
}

private struct CompareInput: Content { let runIds: [UUID] }
struct ScenarioComparisonPoint: Content {
    let elapsedDays: Double
    let value: Double
    let percentageChange: Double
}

struct ScenarioComparisonSeries: Content {
    let runId: UUID
    let points: [ScenarioComparisonPoint]
}

struct ComparisonResponse: Content {
    let runs: [ScenarioRunModel]
    let series: [ScenarioComparisonSeries]
}

private struct RiskProfileInput: Content {
    let holdingId: UUID
    let assetCategory: String
    let sector: String?
    let region: String?
    let benchmarkProxy: String?
    let manualValue: Double?
    let duration: Double?
    let convexity: Double?
    let factorOverrides: ScenarioJSON?
}

struct ScenarioController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.planningRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.planningWrite))

        read.group("scenarios") { scenarios in
            scenarios.get("catalog", use: catalog)
            scenarios.get(use: listScenarios)
            scenarios.get(":id", use: getScenario)
        }
        write.group("scenarios") { scenarios in
            scenarios.post(use: createScenario)
            scenarios.group(":id") { scenario in
                scenario.put(use: updateScenario)
                scenario.delete(use: deleteScenario)
                scenario.post("runs", use: createRun)
            }
        }

        read.group("portfolio", "scenario-snapshots") { snapshots in
            snapshots.get(use: listSnapshots)
            snapshots.get(":id", use: getSnapshot)
        }
        write.post("portfolio", "scenario-snapshots", use: createSnapshot)

        read.group("scenario-runs") { runs in
            runs.get(use: listRuns)
            runs.get(":id", use: getRun)
            runs.get(":id", "result", use: getResult)
        }
        write.group("scenario-runs") { runs in
            runs.post("compare", use: compareRuns)
            runs.delete(":id", use: cancelRun)
        }

        read.get("holding-risk-profiles", use: listRiskProfiles)
        write.group("holding-risk-profiles") { profiles in
            profiles.post(use: saveRiskProfile)
            profiles.delete(":id", use: deleteRiskProfile)
        }
    }

    @Sendable
    func catalog(req: Request) async throws -> ScenarioCatalogResponse {
        _ = try await authorize(req)
        return ScenarioCatalog.response
    }

    @Sendable func listGoals(req: Request) async throws -> [FinancialGoalModel] {
        let user = try await authorize(req); return try await FinancialGoalModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createGoal(req: Request) async throws -> FinancialGoalModel {
        let user = try await authorize(req); let input = try req.content.decode(FinancialGoalInput.self)
        try validateGoal(input)
        try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        let goal = FinancialGoalModel(userId: user, portfolioListId: input.portfolioListId, name: input.name,
                                      targetAmount: input.targetAmount, targetDate: input.targetDate, baseCurrency: input.baseCurrency.uppercased(),
                                      monthlyContribution: input.monthlyContribution ?? 0, annualContributionGrowth: input.annualContributionGrowth ?? 0,
                                      inflationAssumption: input.inflationAssumption ?? 0.02)
        try await goal.save(on: req.db); return goal
    }

    @Sendable func getGoal(req: Request) async throws -> FinancialGoalModel {
        let user = try await authorize(req); return try await ownedGoal(req, user: user)
    }

    @Sendable func updateGoal(req: Request) async throws -> FinancialGoalModel {
        let user = try await authorize(req); let goal = try await ownedGoal(req, user: user); let input = try req.content.decode(FinancialGoalInput.self)
        try validateGoal(input)
        try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        goal.portfolioListId = input.portfolioListId; goal.name = input.name; goal.targetAmount = input.targetAmount
        goal.targetDate = input.targetDate; goal.baseCurrency = input.baseCurrency.uppercased()
        goal.monthlyContribution = input.monthlyContribution ?? 0; goal.annualContributionGrowth = input.annualContributionGrowth ?? 0
        goal.inflationAssumption = input.inflationAssumption ?? 0.02; try await goal.save(on: req.db); return goal
    }

    @Sendable func deleteGoal(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); try await ownedGoal(req, user: user).delete(on: req.db); return .noContent
    }

    @Sendable func listScenarios(req: Request) async throws -> [ScenarioDefinitionModel] {
        let user = try await authorize(req); return try await ScenarioDefinitionModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createScenario(req: Request) async throws -> ScenarioDefinitionModel {
        let user = try await authorize(req); return try await persistScenario(req, user: user, existing: nil)
    }

    @Sendable func getScenario(req: Request) async throws -> ScenarioDefinitionModel {
        let user = try await authorize(req); return try await ownedScenario(req, user: user)
    }

    @Sendable func updateScenario(req: Request) async throws -> ScenarioDefinitionModel {
        let user = try await authorize(req); return try await persistScenario(req, user: user, existing: ownedScenario(req, user: user))
    }

    @Sendable func deleteScenario(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); try await ownedScenario(req, user: user).delete(on: req.db); return .noContent
    }

    @Sendable func listSnapshots(req: Request) async throws -> [ScenarioSnapshotModel] {
        let user = try await authorize(req); return try await ScenarioSnapshotModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createSnapshot(req: Request) async throws -> ScenarioSnapshotModel {
        let user = try await authorize(req); let input = try req.content.decode(SnapshotInput.self); try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        let baseCurrency = input.baseCurrency.uppercased()
        guard baseCurrency.count == 3 else { throw Abort(.badRequest, reason: "Invalid base currency") }
        let snapshot: ScenarioSnapshotModel = if req.application.environment == .testing, let payload = input.payload {
            ScenarioSnapshotModel(userId: user, portfolioListId: input.portfolioListId, baseCurrency: baseCurrency, valuationTimestamp: input.valuationTimestamp ?? Date(), payload: payload, warnings: input.warnings ?? ScenarioJSON())
        } else {
            try await ScenarioSnapshotCaptureService().capture(
                portfolioListId: input.portfolioListId,
                userId: user,
                baseCurrency: baseCurrency,
                cryptoHoldingIds: input.cryptoHoldingIds ?? [],
                req: req
            )
        }
        try await snapshot.save(on: req.db); return snapshot
    }

    @Sendable func getSnapshot(req: Request) async throws -> ScenarioSnapshotModel {
        let user = try await authorize(req); return try await ownedSnapshot(req, user: user)
    }

    @Sendable func listRuns(req: Request) async throws -> [ScenarioRunModel] {
        let user = try await authorize(req); return try await ScenarioRunModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createRun(req: Request) async throws -> Response {
        let user = try await authorize(req); let scenario = try await ownedScenario(req, user: user); let input = try req.content.decode(RunInput.self)
        guard let scenarioId = scenario.id else { throw Abort(.internalServerError) }
        guard let snapshot = try await ScenarioSnapshotModel.owned(by: user, on: req.db).filter(\.$id == input.snapshotId).first() else { throw Abort(.notFound) }
        guard snapshot.portfolioListId == scenario.portfolioListId else {
            throw Abort(.unprocessableEntity, reason: "Snapshot and scenario must use the same portfolio")
        }
        guard let snapshotId = snapshot.id else { throw Abort(.internalServerError) }
        let seed = input.seed ?? UInt64.random(in: .min ... .max)
        let hashSource = [
            canonicalJSON(scenario.configuration), canonicalJSON(snapshot.payload), canonicalJSON(snapshot.warnings),
            String(seed), ScenarioCatalog.version, ScenarioEngine.version,
        ].joined(separator: "|")
        let hash = SHA256.hash(data: Data(hashSource.utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = try await ScenarioRunModel.owned(by: user, on: req.db).filter(\.$deduplicationHash == hash).filter(\.$state == "completed").first() {
            return try existing.encodeResponse(status: HTTPResponseStatus.ok)
        }
        let expiry = scenario.isSaved ? nil : Date().addingTimeInterval(90 * 86400)
        let run = ScenarioRunModel(userId: user, scenarioId: scenarioId, snapshotId: snapshotId, seed: seed, deduplicationHash: hash, expiresAt: expiry)
        try await run.save(on: req.db); return try run.encodeResponse(status: HTTPResponseStatus.accepted)
    }

    @Sendable func getRun(req: Request) async throws -> ScenarioRunModel {
        let user = try await authorize(req); return try await ownedRun(req, user: user)
    }

    @Sendable func cancelRun(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); let run = try await ownedRun(req, user: user); guard run.state == "queued" || run.state == "running" else { throw Abort(.conflict, reason: "Run is already terminal") }; run.state = "cancelled"; run.completedAt = Date(); try await run.save(on: req.db); return .noContent
    }

    @Sendable func getResult(req: Request) async throws -> ScenarioJSON {
        let user = try await authorize(req); let run = try await ownedRun(req, user: user)
        guard run.state == "completed", let runID = run.id else { throw Abort(.conflict, reason: "Result is not ready") }
        if req.application.redis.configuration != nil {
            let key = RedisKey("scenario:result:\(runID.uuidString.lowercased())")
            if let value = try? await req.redis.get(key, as: String.self).get(),
               let data = value.data(using: .utf8), let cached = try? JSONDecoder().decode(ScenarioJSON.self, from: data)
            {
                PrometheusMetrics.shared.recordScenarioCacheHit(); return cached
            }
        }
        guard let result = run.result else { throw Abort(.conflict, reason: "Result is not ready") }
        return result
    }

    @Sendable func compareRuns(req: Request) async throws -> ComparisonResponse {
        let user = try await authorize(req)
        let input = try req.content.decode(CompareInput.self)
        guard (1 ... 4).contains(input.runIds.count) else {
            throw Abort(.badRequest, reason: "Compare between one and four runs")
        }
        let fetched = try await ScenarioRunModel.owned(by: user, on: req.db)
            .filter(\.$id ~~ input.runIds).all()
        guard fetched.count == Set(input.runIds).count else { throw Abort(.notFound) }
        let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { run in run.id.map { ($0, run) } })
        let runs = input.runIds.compactMap { byID[$0] }
        guard runs.allSatisfy({ $0.state == "completed" && $0.result != nil }) else {
            throw Abort(.conflict, reason: "Only completed runs can be compared")
        }
        return ComparisonResponse(runs: runs, series: runs.compactMap(normalizedComparisonSeries))
    }

    private func normalizedComparisonSeries(_ run: ScenarioRunModel) -> ScenarioComparisonSeries? {
        guard let id = run.id, let result = run.result else { return nil }
        var source = result.values["timeline"]?.array?.compactMap(\.object) ?? []
        var valueKey = "value"
        if source.isEmpty {
            source = result.values["percentile_bands"]?.array?.compactMap(\.object) ?? []
            valueKey = "p50"
        }
        let raw = source.compactMap { point -> (Double, Double)? in
            guard let value = point[valueKey]?.number else { return nil }
            if let days = point["elapsed_days"]?.number {
                return (days, value)
            }
            guard let months = point["elapsed_months"]?.number else { return nil }
            return (months * 30.4375, value)
        }.sorted { $0.0 < $1.0 }
        guard let initial = raw.first?.1 else { return ScenarioComparisonSeries(runId: id, points: []) }
        return ScenarioComparisonSeries(runId: id, points: raw.map {
            ScenarioComparisonPoint(
                elapsedDays: $0.0, value: $0.1,
                percentageChange: initial == 0 ? 0 : $0.1 / initial - 1
            )
        })
    }

    @Sendable func listRiskProfiles(req: Request) async throws -> [HoldingRiskProfileModel] {
        let user = try await authorize(req)
        return try await HoldingRiskProfileModel.owned(by: user, on: req.db).sort(\.$updatedAt, .descending).all()
    }

    @Sendable func saveRiskProfile(req: Request) async throws -> HoldingRiskProfileModel {
        let user = try await authorize(req); let input = try req.content.decode(RiskProfileInput.self)
        guard let holding = try await Stock.query(on: req.db).filter(\.$id == input.holdingId).filter(\.$userId == user).first() else { throw Abort(.notFound) }
        let supported = Set(["stock", "etf", "mutual_fund", "crypto", "cash", "bond", "real_estate", "commodity"])
        guard supported.contains(input.assetCategory), input.manualValue.map({ $0 > 0 }) ?? true,
              input.duration.map({ $0 >= 0 }) ?? true, input.convexity.map({ $0 >= 0 }) ?? true
        else { throw Abort(.badRequest, reason: "Invalid risk profile") }
        let profile = try await HoldingRiskProfileModel.owned(by: user, on: req.db)
            .filter(\.$holdingId == input.holdingId).first()
            ?? HoldingRiskProfileModel(userId: user, holdingId: input.holdingId, assetCategory: holding.category.rawValue)
        profile.assetCategory = input.assetCategory; profile.sector = input.sector?.nilIfBlank
        profile.region = input.region?.nilIfBlank; profile.benchmarkProxy = input.benchmarkProxy?.nilIfBlank?.uppercased()
        profile.manualValue = input.manualValue; profile.duration = input.duration; profile.convexity = input.convexity
        profile.factorOverrides = input.factorOverrides ?? ScenarioJSON(); try await profile.save(on: req.db); return profile
    }

    @Sendable func deleteRiskProfile(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); let id = try requireID(req)
        guard let profile = try await HoldingRiskProfileModel.owned(by: user, on: req.db).filter(\.$id == id).first() else { throw Abort(.notFound) }
        try await profile.delete(on: req.db); return .noContent
    }

    private func authorize(_ req: Request) async throws -> UUID {
        guard envBool("SCENARIO_PLANNING_ENABLED", default: false) else { throw Abort(.notFound) }; let session = try req.auth.require(SessionToken.self); try await req.usageCounterService.requirePremium(.scenarioPlanning, userId: session.userId, on: req.db); return session.userId
    }

    private func requireID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid id") }; return id
    }

    private func validateGoal(_ input: FinancialGoalInput) throws {
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.targetAmount.isFinite, input.targetAmount > 0,
              input.baseCurrency.count == 3,
              input.monthlyContribution.map({ $0.isFinite && $0 >= 0 }) ?? true,
              input.annualContributionGrowth.map({ $0.isFinite && $0 > -1 && $0 <= 10 }) ?? true,
              input.inflationAssumption.map({ $0.isFinite && $0 > -1 && $0 <= 10 }) ?? true
        else { throw Abort(.badRequest, reason: "Invalid financial goal") }
    }

    private func canonicalJSON(_ value: ScenarioJSON) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func requirePortfolio(_ id: UUID, user: UUID, db: any Database) async throws {
        guard try await PortfolioList.query(on: db).filter(\.$id == id).filter(\.$userId == user).first() != nil else { throw Abort(.notFound) }
    }

    private func ownedGoal(_ req: Request, user: UUID) async throws -> FinancialGoalModel {
        guard let value = try await FinancialGoalModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func ownedScenario(_ req: Request, user: UUID) async throws -> ScenarioDefinitionModel {
        guard let value = try await ScenarioDefinitionModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func ownedSnapshot(_ req: Request, user: UUID) async throws -> ScenarioSnapshotModel {
        guard let value = try await ScenarioSnapshotModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func ownedRun(_ req: Request, user: UUID) async throws -> ScenarioRunModel {
        guard let value = try await ScenarioRunModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func persistScenario(_ req: Request, user: UUID, existing: ScenarioDefinitionModel?) async throws -> ScenarioDefinitionModel {
        let input = try req.content.decode(ScenarioInput.self)
        try validateScenario(input)
        try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        if let goalId = input.financialGoalId {
            guard let goal = try await FinancialGoalModel.owned(by: user, on: req.db)
                .filter(\.$id == goalId).first()
            else { throw Abort(.notFound, reason: "Financial goal not found") }
            guard goal.portfolioListId == input.portfolioListId else {
                throw Abort(.unprocessableEntity, reason: "Financial goal and scenario must use the same portfolio")
            }
        }
        let scenario = existing ?? ScenarioDefinitionModel(
            userId: user, portfolioListId: input.portfolioListId,
            financialGoalId: input.financialGoalId, name: input.name, kind: input.kind,
            configuration: input.configuration, isSaved: input.isSaved ?? true
        )
        scenario.portfolioListId = input.portfolioListId
        scenario.financialGoalId = input.financialGoalId
        scenario.name = input.name
        scenario.kind = input.kind
        scenario.configuration = input.configuration
        scenario.isSaved = input.isSaved ?? true
        try await scenario.save(on: req.db)
        return scenario
    }

    private func validateScenario(_ input: ScenarioInput) throws {
        guard ["historical", "custom", "monte_carlo"].contains(input.kind),
              !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Abort(.badRequest, reason: "Invalid scenario") }
        let values = input.configuration.values
        if input.kind == "historical" {
            let catalogID = values["catalogId"]?.string ?? values["catalog_id"]?.string
            let supported = Set(ScenarioCatalog.response.historicalScenarios.map(\.id))
            guard let catalogID, supported.contains(catalogID) else {
                throw Abort(.badRequest, reason: "Unknown historical scenario")
            }
        }
        if input.kind == "custom" {
            let months = values["horizon_months"]?.number ?? 1
            let rateShift = values["parallel_rate_shift_bps"]?.number ?? 0
            let volatility = values["volatility_multiplier"]?.number ?? 1
            let recovery = values["recovery"]?.string ?? "none"
            guard months.isFinite, months.rounded() == months, (1 ... 120).contains(months),
                  rateShift.isFinite, (-5000 ... 5000).contains(rateShift),
                  volatility.isFinite, (0 ... 10).contains(volatility),
                  ["none", "linear", "mean_reverting"].contains(recovery),
                  validShockList(values["holding_shocks"]),
                  validShockList(values["sector_shocks"]),
                  validShockList(values["region_shocks"]),
                  validShockList(values["currency_shocks"]),
                  validShockList(values["asset_class_shocks"])
            else { throw Abort(.badRequest, reason: "Invalid custom scenario configuration") }
        }
        if input.kind == "monte_carlo" {
            let paths = values["path_count"]?.number ?? 10000
            let months = values["horizon_months"]?.number ?? 360
            let degrees = values["degrees_of_freedom"]?.number ?? 5
            let block = values["bootstrap_block_months"]?.number ?? 6
            let distribution = values["distribution"]?.string ?? "block_bootstrap"
            guard paths.isFinite, paths.rounded() == paths, (1 ... 50000).contains(paths),
                  months.isFinite, months.rounded() == months, (1 ... 600).contains(months),
                  degrees.isFinite, degrees > 2, degrees <= 100,
                  block.isFinite, block.rounded() == block, (1 ... 120).contains(block),
                  ["block_bootstrap", "normal", "student_t"].contains(distribution),
                  validMonteCarloAssumptions(values)
            else { throw Abort(.badRequest, reason: "Invalid Monte Carlo configuration") }
        }
    }

    private func validShockList(_ value: ScenarioJSONValue?) -> Bool {
        guard let value else { return true }
        guard let shocks = value.array else { return false }
        return shocks.allSatisfy { item in
            guard let object = item.object,
                  let target = object["target"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let percentage = object["percentage"]?.number
            else { return false }
            return !target.isEmpty && percentage.isFinite && (-1 ... 10).contains(percentage)
        }
    }

    private func validMonteCarloAssumptions(_ values: [String: ScenarioJSONValue]) -> Bool {
        let weights = values["asset_weights"]?.array?.compactMap(\.number) ?? []
        let returns = values["asset_annual_returns"]?.array?.compactMap(\.number) ?? []
        let covariance = values["annual_covariance"]?.array?.compactMap { $0.array?.compactMap(\.number) } ?? []
        if weights.isEmpty, returns.isEmpty, covariance.isEmpty {
            return true
        }
        let count = weights.count
        guard (2 ... 50).contains(count), returns.count == count, covariance.count == count,
              covariance.allSatisfy({ $0.count == count }),
              weights.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }),
              abs(weights.reduce(0, +) - 1) <= 0.001,
              returns.allSatisfy({ $0.isFinite && (-1 ... 10).contains($0) })
        else { return false }
        for row in 0 ..< count {
            guard covariance[row].allSatisfy(\.isFinite), covariance[row][row] >= 0 else { return false }
            for column in 0 ..< count where abs(covariance[row][column] - covariance[column][row]) > 0.000_001 {
                return false
            }
        }
        return true
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value
    }
}

private extension Model where Self: Content {
    func encodeResponse(status: HTTPResponseStatus) throws -> Response {
        let response = Response(status: status); try response.content.encode(self); return response
    }
}

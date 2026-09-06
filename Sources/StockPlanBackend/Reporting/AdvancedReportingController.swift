import Fluent
import Foundation
import StockPlanShared
import Vapor

struct AdvancedReportingController: RouteCollection {
    private struct ArtifactDownloadQuery: Content {
        let expires: Int64
        let recipient: String?
        let signature: String
    }

    private let mapper = AdvancedReportMapper()
    private let recurrence = ReportRecurrenceCalculator()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.exportRead)).grouped("reporting")
        let write = protected.grouped(ScopeRequirementMiddleware(.exportWrite)).grouped("reporting")

        read.get("templates", use: listTemplates)
        read.get("templates", ":templateId", use: getTemplate)
        write.group("templates") { templates in
            templates.post(use: createTemplate)
            templates.group(":templateId") { template in
                template.put(use: updateTemplate)
                template.delete(use: archiveTemplate)
            }
        }

        read.get("schedules", use: listSchedules)
        read.get("schedules", ":scheduleId", use: getSchedule)
        write.group("schedules") { schedules in
            schedules.post(use: createSchedule)
            schedules.group(":scheduleId") { schedule in
                schedule.put(use: updateSchedule)
                schedule.delete(use: deleteSchedule)
            }
        }

        read.get("runs", use: listRuns)
        read.get("runs", ":runId", use: getRun)
        write.post("runs", use: createRun)

        read.get("artifacts", ":artifactId", "link", use: artifactLink)

        // Unauthenticated by design: the download URL is itself a signed link.
        routes.get("reporting", "artifacts", ":artifactId", "download", use: downloadArtifact)
    }

    @Sendable
    func listTemplates(req: Request) async throws -> ReportTemplatePageResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let records = try await AdvancedReportTemplateRecord.query(on: req.db)
            .filter(\.$ownerUserId == userId)
            .filter(\.$archivedAt == nil)
            .sort(\.$updatedAt, .descending)
            .all()
        return try ReportTemplatePageResponse(items: records.map(mapper.template))
    }

    @Sendable
    func createTemplate(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        try await requirePro(userId: userId, feature: .advancedReportTemplates, req: req)
        let input = try req.content.decode(ReportTemplateInput.self)
        try await validateTemplate(input, userId: userId, req: req)
        let record = try AdvancedReportTemplateRecord(
            ownerUserId: userId,
            inputJSON: encodeReportJSON(input)
        )
        try await record.save(on: req.db)
        let response = Response(status: .created)
        try response.content.encode(mapper.template(record))
        return response
    }

    @Sendable
    func getTemplate(req: Request) async throws -> ReportTemplate {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await mapper.template(ownedTemplate(req, userId: userId, includeArchived: true))
    }

    @Sendable
    func updateTemplate(req: Request) async throws -> ReportTemplate {
        let userId = try req.auth.require(SessionToken.self).userId
        try await requirePro(userId: userId, feature: .advancedReportTemplates, req: req)
        let record = try await ownedTemplate(req, userId: userId)
        let input = try req.content.decode(ReportTemplateInput.self)
        try await validateTemplate(input, userId: userId, req: req)
        record.inputJSON = try encodeReportJSON(input)
        record.revision += 1
        try await record.save(on: req.db)
        return try mapper.template(record)
    }

    @Sendable
    func archiveTemplate(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        let record = try await ownedTemplate(req, userId: userId)
        record.archivedAt = Date()
        try await record.save(on: req.db)
        let schedules = try await AdvancedReportScheduleRecord.query(on: req.db)
            .filter(\.$ownerUserId == userId)
            .all()
        for schedule in schedules {
            let input = try decodeReportJSON(ReportScheduleInput.self, schedule.inputJSON)
            if input.templateId == record.id?.uuidString {
                schedule.nextRunAt = nil
                schedule.pausedReason = "template_archived"
                try await schedule.save(on: req.db)
            }
        }
        return .noContent
    }

    @Sendable
    func listSchedules(req: Request) async throws -> ReportSchedulePageResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let records = try await AdvancedReportScheduleRecord.query(on: req.db)
            .filter(\.$ownerUserId == userId)
            .sort(\.$createdAt, .descending)
            .all()
        return try ReportSchedulePageResponse(items: records.map(mapper.schedule))
    }

    @Sendable
    func createSchedule(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        try await requirePro(userId: userId, feature: .advancedReportSchedules, req: req)
        let count = try await AdvancedReportScheduleRecord.query(on: req.db)
            .filter(\.$ownerUserId == userId)
            .count()
        guard count < 20 else {
            throw BillingUpgradeRequiredError(feature: .advancedReportSchedules, plan: "pro", limit: 20, current: count)
        }
        let input = try req.content.decode(ReportScheduleInput.self)
        try await validateSchedule(input, userId: userId, req: req)
        let nextRunAt = input.isEnabled ? try recurrence.next(after: Date(), recurrence: input.recurrence) : nil
        let record = try AdvancedReportScheduleRecord(
            ownerUserId: userId,
            inputJSON: encodeReportJSON(input),
            nextRunAt: nextRunAt
        )
        try await record.save(on: req.db)
        let response = Response(status: .created)
        try response.content.encode(mapper.schedule(record))
        return response
    }

    @Sendable
    func getSchedule(req: Request) async throws -> ReportSchedule {
        let userId = try req.auth.require(SessionToken.self).userId
        return try await mapper.schedule(ownedSchedule(req, userId: userId))
    }

    @Sendable
    func updateSchedule(req: Request) async throws -> ReportSchedule {
        let userId = try req.auth.require(SessionToken.self).userId
        try await requirePro(userId: userId, feature: .advancedReportSchedules, req: req)
        let record = try await ownedSchedule(req, userId: userId)
        let input = try req.content.decode(ReportScheduleInput.self)
        try await validateSchedule(input, userId: userId, req: req)
        record.inputJSON = try encodeReportJSON(input)
        record.nextRunAt = input.isEnabled ? try recurrence.next(after: Date(), recurrence: input.recurrence) : nil
        record.pausedReason = input.isEnabled ? nil : "disabled_by_user"
        try await record.save(on: req.db)
        return try mapper.schedule(record)
    }

    @Sendable
    func deleteSchedule(req: Request) async throws -> HTTPStatus {
        let userId = try req.auth.require(SessionToken.self).userId
        try await (ownedSchedule(req, userId: userId)).delete(on: req.db)
        return .noContent
    }

    @Sendable
    func listRuns(req: Request) async throws -> ReportRunPageResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let records = try await AdvancedReportRunRecord.query(on: req.db)
            .filter(\.$requestedByUserId == userId)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
        var items = [ReportRun]()
        for record in records {
            try await items.append(mapper.run(record, on: req.db))
        }
        return ReportRunPageResponse(items: items)
    }

    @Sendable
    func createRun(req: Request) async throws -> Response {
        let userId = try req.auth.require(SessionToken.self).userId
        try await requirePro(userId: userId, feature: .advancedReportRuns, req: req)
        let input = try req.content.decode(ReportRunCreateRequest.self)
        let templateId = try requireUUID(input.templateId, field: "templateId")
        guard let template = try await AdvancedReportTemplateRecord.find(templateId, on: req.db),
              template.ownerUserId == userId, template.archivedAt == nil
        else { throw Abort(.notFound) }
        try validateFormats(input.outputFormats)
        let templateInput = try decodeReportJSON(ReportTemplateInput.self, template.inputJSON)
        try await validateRecipients(input.recipientUserIds, template: templateInput, ownerUserId: userId, req: req)
        let generatedToday = try await artifactsRequestedToday(userId: userId, req: req)
        guard generatedToday + input.outputFormats.count <= 100 else {
            throw Abort(.tooManyRequests, reason: "The daily limit of 100 generated report files has been reached.")
        }
        let recipients = input.recipientUserIds.isEmpty ? [userId.uuidString] : input.recipientUserIds
        let record = try AdvancedReportRunRecord(
            templateId: templateId,
            requestedByUserId: userId,
            templateRevision: template.revision,
            templateInputJSON: template.inputJSON,
            outputFormatsJSON: encodeReportJSON(input.outputFormats),
            recipientUserIdsJSON: encodeReportJSON(recipients)
        )
        try await record.save(on: req.db)
        let response = Response(status: .accepted)
        try await response.content.encode(mapper.run(record, on: req.db))
        return response
    }

    @Sendable
    func getRun(req: Request) async throws -> ReportRun {
        let userId = try req.auth.require(SessionToken.self).userId
        guard let id = req.parameters.get("runId").flatMap(UUID.init(uuidString:)),
              let record = try await AdvancedReportRunRecord.find(id, on: req.db),
              record.requestedByUserId == userId
        else { throw Abort(.notFound) }
        return try await mapper.run(record, on: req.db)
    }

    @Sendable
    func artifactLink(req: Request) async throws -> ReportArtifactDownloadResponse {
        let userId = try req.auth.require(SessionToken.self).userId
        let (artifact, _) = try await ownedArtifact(req, userId: userId)
        guard artifact.expiresAt > Date() else { throw Abort(.gone, reason: "This report has expired.") }
        let linkExpiry = min(artifact.expiresAt, Date().addingTimeInterval(24 * 60 * 60))
        let artifactId = try artifact.requireID()
        let signature = req.application.reportDownloadSigner.signature(
            artifactId: artifactId,
            expiresAt: linkExpiry,
            recipientUserId: userId
        )
        let baseURL = (Environment.get("PUBLIC_API_BASE_URL") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "/v1/reporting/artifacts/\(artifactId.uuidString)/download"
        let url = "\(baseURL)\(path)?expires=\(Int64(linkExpiry.timeIntervalSince1970))&recipient=\(userId.uuidString)&signature=\(signature)"
        return ReportArtifactDownloadResponse(url: url, expiresAt: formatISODateTime(linkExpiry) ?? "")
    }

    @Sendable
    func downloadArtifact(req: Request) async throws -> Response {
        guard let artifactId = req.parameters.get("artifactId").flatMap(UUID.init(uuidString:)),
              let artifact = try await AdvancedReportArtifactRecord.find(artifactId, on: req.db)
        else { throw Abort(.notFound) }
        let query = try req.query.decode(ArtifactDownloadQuery.self)
        let recipient = query.recipient.flatMap(UUID.init(uuidString:))
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(query.expires))
        guard artifact.expiresAt > Date(),
              req.application.reportDownloadSigner.verify(
                  signature: query.signature,
                  artifactId: artifactId,
                  expiresAt: expiresAt,
                  recipientUserId: recipient
              )
        else { throw Abort(.forbidden, reason: "This report link is invalid or expired.") }
        let run = try await AdvancedReportRunRecord.find(artifact.runId, on: req.db)
        let allowedRecipients = (try? decodeReportJSON([String].self, run?.recipientUserIdsJSON ?? "[]")) ?? []
        guard let run, recipient == run.requestedByUserId || allowedRecipients.contains(recipient?.uuidString ?? "") else {
            throw Abort(.forbidden)
        }
        let data = try req.application.advancedReportStorage.load(key: artifact.storageKey)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: artifact.contentType)
        headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(artifact.filename.replacingOccurrences(of: "\"", with: ""))\""
        )
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    private func ownedTemplate(
        _ req: Request,
        userId: UUID,
        includeArchived: Bool = false
    ) async throws -> AdvancedReportTemplateRecord {
        guard let id = req.parameters.get("templateId").flatMap(UUID.init(uuidString:)),
              let record = try await AdvancedReportTemplateRecord.find(id, on: req.db),
              record.ownerUserId == userId,
              includeArchived || record.archivedAt == nil
        else { throw Abort(.notFound) }
        return record
    }

    private func ownedSchedule(_ req: Request, userId: UUID) async throws -> AdvancedReportScheduleRecord {
        guard let id = req.parameters.get("scheduleId").flatMap(UUID.init(uuidString:)),
              let record = try await AdvancedReportScheduleRecord.find(id, on: req.db),
              record.ownerUserId == userId
        else { throw Abort(.notFound) }
        return record
    }

    private func ownedArtifact(
        _ req: Request,
        userId: UUID
    ) async throws -> (AdvancedReportArtifactRecord, AdvancedReportRunRecord) {
        guard let id = req.parameters.get("artifactId").flatMap(UUID.init(uuidString:)),
              let artifact = try await AdvancedReportArtifactRecord.find(id, on: req.db),
              let run = try await AdvancedReportRunRecord.find(artifact.runId, on: req.db),
              run.requestedByUserId == userId
        else { throw Abort(.notFound) }
        return (artifact, run)
    }

    private func requirePro(userId: UUID, feature: BillingFeature, req: Request) async throws {
        let entitlement = try await req.entitlementResolver.resolve(userId: userId, on: req.db)
        guard entitlement.isPro else { throw BillingUpgradeRequiredError(feature: feature, plan: entitlement.level) }
    }

    private func validateTemplate(_ input: ReportTemplateInput, userId: UUID, req: Request) async throws {
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.name.count <= 120 else {
            throw Abort(.badRequest, reason: "Template name must contain 1 to 120 characters.")
        }
        guard !input.blocks.isEmpty, input.blocks.count <= 30 else {
            throw Abort(.badRequest, reason: "A report template must contain 1 to 30 blocks.")
        }
        guard Set(input.blocks.map(\.id)).count == input.blocks.count else {
            throw Abort(.badRequest, reason: "Report block IDs must be unique.")
        }
        for portfolioId in try portfolioIds(in: input) {
            _ = try await req.portfolioAccessService.require(portfolioId: portfolioId, userId: userId, on: req.db)
        }
    }

    private func validateSchedule(_ input: ReportScheduleInput, userId: UUID, req: Request) async throws {
        guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.name.count <= 120 else {
            throw Abort(.badRequest, reason: "Schedule name must contain 1 to 120 characters.")
        }
        try validateFormats(input.outputFormats)
        _ = try recurrence.next(after: Date(), recurrence: input.recurrence)
        let templateId = try requireUUID(input.templateId, field: "templateId")
        guard let template = try await AdvancedReportTemplateRecord.find(templateId, on: req.db),
              template.ownerUserId == userId, template.archivedAt == nil
        else { throw Abort(.notFound, reason: "Report template not found.") }
        try await validateRecipients(
            input.recipientUserIds,
            template: decodeReportJSON(ReportTemplateInput.self, template.inputJSON),
            ownerUserId: userId,
            req: req
        )
    }

    private func validateFormats(_ formats: [ReportOutputFormat]) throws {
        guard !formats.isEmpty, formats.count <= 2, Set(formats.map(\.rawValue)).count == formats.count else {
            throw Abort(.badRequest, reason: "Choose one or two distinct report output formats.")
        }
    }

    private func validateRecipients(
        _ values: [String],
        template: ReportTemplateInput,
        ownerUserId: UUID,
        req: Request
    ) async throws {
        let recipientIds = values.isEmpty ? [ownerUserId] : try values.map { try requireUUID($0, field: "recipientUserIds") }
        guard Set(recipientIds).count == recipientIds.count, recipientIds.count <= 6 else {
            throw Abort(.badRequest, reason: "Recipients must be unique and limited to the owner plus five shared members.")
        }
        let users = try await User.query(on: req.db).filter(\.$id ~~ recipientIds).all()
        guard users.count == recipientIds.count, users.allSatisfy(\.isVerified) else {
            throw Abort(.badRequest, reason: "Every report recipient must have a verified account.")
        }
        for portfolioId in try portfolioIds(in: template) {
            for recipientId in recipientIds {
                _ = try await req.portfolioAccessService.require(
                    portfolioId: portfolioId,
                    userId: recipientId,
                    on: req.db
                )
            }
        }
    }

    private func portfolioIds(in template: ReportTemplateInput) throws -> [UUID] {
        let values = template.blocks.flatMap { block in
            block.portfolioIds + [block.settings.comparisonPortfolioId].compactMap(\.self)
        }
        return try Array(Set(values)).map { try requireUUID($0, field: "portfolioIds") }
    }

    private func requireUUID(_ value: String, field: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw Abort(.badRequest, reason: "Invalid \(field).") }
        return id
    }

    private func artifactsRequestedToday(userId: UUID, req: Request) async throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = calendar.startOfDay(for: Date())
        let runs = try await AdvancedReportRunRecord.query(on: req.db)
            .filter(\.$requestedByUserId == userId)
            .filter(\.$createdAt >= start)
            .all()
        return try runs.reduce(0) { total, run in
            try total + (decodeReportJSON([ReportOutputFormat].self, run.outputFormatsJSON).count)
        }
    }
}

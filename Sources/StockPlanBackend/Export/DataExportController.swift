import Vapor

struct DataExportController: RouteCollection {
    let exportService: any DataExportService

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let rateLimit = RateLimitMiddleware(limit: 60, interval: 60)
        let rateLimitedProtected = protected.grouped(rateLimit)

        rateLimitedProtected.grouped(ScopeRequirementMiddleware(.exportWrite))
            .post("api", "v3", "export", use: createExport)
        rateLimitedProtected.grouped(ScopeRequirementMiddleware(.exportRead))
            .group("api", "v3", "export") { exports in
                exports.get(use: listExports)
                exports.get(":id", use: getExport)
            }
    }

    @Sendable
    func createExport(req: Request) async throws -> ExportCreateResponse {
        let session = try req.auth.require(SessionToken.self)
        let requestBody = try req.content.decode(ExportCreateRequest.self)

        let export = try await exportService.createExportJob(
            userId: session.userId,
            type: requestBody.type,
            format: requestBody.format,
            filters: requestBody.filters,
            on: req.db
        )

        return ExportCreateResponse(
            exportId: export.id!,
            status: ExportStatus(rawValue: export.status) ?? .pending
        )
    }

    @Sendable
    func listExports(req: Request) async throws -> ExportListResponse {
        let session = try req.auth.require(SessionToken.self)
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20
        let offset = (try? req.query.get(Int.self, at: "offset")) ?? 0

        let exports = try await exportService.listExports(userId: session.userId, limit: limit, offset: offset, on: req.db)

        let items = exports.map { export in
            ExportListItem(
                id: export.id!,
                type: ExportType(rawValue: export.type)!,
                format: ExportFormat(rawValue: export.format)!,
                status: ExportStatus(rawValue: export.status) ?? .pending,
                createdAt: export.createdAt ?? Date(),
                filePath: export.filePath,
                fileSizeBytes: export.fileSizeBytes,
                expiresAt: export.expiresAt
            )
        }

        return ExportListResponse(items: items)
    }

    @Sendable
    func getExport(req: Request) async throws -> ExportDetailResponse {
        let session = try req.auth.require(SessionToken.self)
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Missing export ID")
        }

        guard let export = try await exportService.getExportStatus(id: id, userId: session.userId, on: req.db) else {
            throw Abort(.notFound, reason: "Export not found")
        }

        var downloadURL: String? = nil
        if let filePath = export.filePath, export.status == ExportStatus.ready.rawValue {
            // Return relative file path - client can download via direct file serve endpoint
            // For now, just provide the path (no signed URL since local storage)
            downloadURL = "/exports/\(session.userId)/\(export.id!.uuidString).\(export.format)"
        }

        return ExportDetailResponse(
            id: export.id!,
            type: ExportType(rawValue: export.type)!,
            format: ExportFormat(rawValue: export.format)!,
            status: ExportStatus(rawValue: export.status) ?? .pending,
            filters: export.filters,
            filePath: export.filePath,
            fileSizeBytes: export.fileSizeBytes,
            downloadURL: downloadURL,
            expiresAt: export.expiresAt,
            createdAt: export.createdAt,
            updatedAt: export.updatedAt
        )
    }
}

struct ExportCreateRequest: Content {
    let type: ExportType
    let format: ExportFormat
    let filters: ExportFilters?
}

struct ExportCreateResponse: Content {
    let exportId: UUID
    let status: ExportStatus
}

struct ExportListItem: Content {
    let id: UUID
    let type: ExportType
    let format: ExportFormat
    let status: ExportStatus
    let createdAt: Date
    let filePath: String?
    let fileSizeBytes: Int64?
    let expiresAt: Date?
}

struct ExportListResponse: Content {
    let items: [ExportListItem]
}

struct ExportDetailResponse: Content {
    let id: UUID
    let type: ExportType
    let format: ExportFormat
    let status: ExportStatus
    let filters: [String: String]?
    let filePath: String?
    let fileSizeBytes: Int64?
    let downloadURL: String?
    let expiresAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
}

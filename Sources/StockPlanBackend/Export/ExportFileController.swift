import HTTPTypes
import Vapor

struct ExportFileController: RouteCollection {
    let exportService: any DataExportService

    func boot(routes: any RoutesBuilder) throws {
        routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped(ScopeRequirementMiddleware(.exportRead))
            .get("api", "v3", "export", "file", ":userId", ":filename", use: serveExportFile)
    }

    @Sendable
    func serveExportFile(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)

        guard let userId = req.parameters.get("userId", as: UUID.self),
              let filename = req.parameters.get("filename")
        else {
            throw Abort(.badRequest, reason: "Missing parameters")
        }

        guard userId == session.userId else {
            throw Abort(.forbidden, reason: "You are not allowed to access this export")
        }

        let exportIdString = filename.split(separator: ".").first.map(String.init)
        guard let exportIdString, let exportId = UUID(uuidString: exportIdString) else {
            throw Abort(.badRequest, reason: "Invalid filename format")
        }

        guard let export = try await exportService.getExportStatus(id: exportId, userId: userId, on: req.db) else {
            throw Abort(.notFound, reason: "Export not found")
        }

        guard export.status == ExportStatus.ready.rawValue else {
            throw Abort(.badRequest, reason: "Export is not ready for download")
        }

        let filePath = export.filePath ?? ""
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw Abort(.notFound, reason: "File not found")
        }

        let file = try req.fileio.streamFile(at: filePath)

        // Set download headers
        let isCSV = export.format == ExportFormat.csv.rawValue
        file.headers.contentType = isCSV
            ? HTTPMediaType(type: "text", subType: "csv")
            : .json
        file.headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(filename)\"")

        return file
    }
}

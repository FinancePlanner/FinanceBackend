import Foundation
import Vapor

/// The OpenAPI document copied into the module bundle via Package.swift.
/// Tests read this directly so they do not have to `configure()` a full app
/// (which races `ProcessInfo.environment` on Linux).
enum BundledOpenAPISpec {
    static func resourceURL() -> URL? {
        Bundle.module.url(forResource: "openapi", withExtension: "yaml")
    }

    static func yamlString() throws -> String {
        guard let url = resourceURL() else {
            throw Abort(.notFound, reason: "openapi.yaml is not bundled (check Package.swift resources)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

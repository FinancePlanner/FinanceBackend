// swift-tools-version:6.0
import Foundation
import PackageDescription

let sharedPackagePath = ProcessInfo.processInfo.environment["STOCKPLAN_SHARED_PATH"]
let sharedPackage: Package.Dependency = if let sharedPackagePath {
    .package(path: sharedPackagePath)
} else {
    .package(url: "https://github.com/FinancePlanner/norviq-shared.git", exact: "5.3.0")
}

let sharedPackageIdentity = sharedPackagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "norviq-shared"

let package = Package(
    name: "StockPlanBackend",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🧩 FluentSQL helpers for SQL-backed Fluent migrations.
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.55.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🔐 JWT support.
        .package(url: "https://github.com/vapor/jwt.git", from: "5.0.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-webauthn.git", from: "1.0.0-beta.1"),
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        // Prometheus metrics exporter for Swift Metrics
        .package(url: "https://github.com/vapor/redis.git", from: "4.8.0"),
        // Shared API contracts used by backend and iOS app.
        sharedPackage,
        // Container packaging without Dockerfile builds in CI.
        .package(url: "https://github.com/apple/swift-container-plugin.git", from: "1.3.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
        // 📊 Reading user-supplied .xlsx workbooks for expense import.
        // NOTE: these pull in FoundationXML, which dynamically links libxml2.
        // The runtime image must install it or the binary won't load at all --
        // see the libxml2 line in Dockerfile.
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        .executableTarget(
            name: "StockPlanBackend",
            dependencies: [
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                // Telemetry
                .product(name: "Logging", package: "swift-log"),
                .product(name: "WebAuthn", package: "swift-webauthn"),
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "Atomics", package: "swift-atomics"),
                // Optional Redis cache integration.
                .product(name: "Redis", package: "redis"),
                .product(name: "StockPlanShared", package: sharedPackageIdentity),
                .product(name: "VaporAPNS", package: "apns"),
                .product(name: "CoreXLSX", package: "CoreXLSX"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                .copy("openapi.yaml"),
                .copy("Tax/Resources"),
            ],
            swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .testTarget(
            name: "StockPlanBackendTests",
            dependencies: [
                .target(name: "StockPlanBackend"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "StockPlanShared", package: sharedPackageIdentity),
            ],
            // Loaded from disk via #filePath, not through Bundle, so these are
            // not build inputs.
            exclude: ["Fixtures/Spreadsheets"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
    ]
}

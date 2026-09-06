import Vapor

struct PushNotificationsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.notificationsRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.notificationsWrite))

        write.put("notifications", "apns", "device", use: registerDevice)
        write.post("notifications", "apns", "device", "deactivate", use: deactivateDevice)

        read.get("notifications", "earnings", "preferences", use: getEarningsPreferences)
        write.put("notifications", "earnings", "preferences", use: updateEarningsPreferences)
    }

    @Sendable
    func registerDevice(req: Request) async throws -> PushDeviceRegistrationResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PushDeviceRegistrationRequest.self)
        let model = try await req.pushDeviceService.upsert(userId: session.userId, payload: payload, on: req.db)
        return try .init(from: model)
    }

    @Sendable
    func deactivateDevice(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PushDeviceDeactivateRequest.self)
        try await req.pushDeviceService.deactivate(userId: session.userId, deviceToken: payload.deviceToken, on: req.db)
        return .ok
    }

    @Sendable
    func getEarningsPreferences(req: Request) async throws -> EarningsNotificationPreferencesResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.targetAlerts, userId: session.userId, on: req.db)
        return try await req.earningsNotificationPreferenceService.get(userId: session.userId, on: req.db)
    }

    @Sendable
    func updateEarningsPreferences(req: Request) async throws -> EarningsNotificationPreferencesResponse {
        let session = try req.auth.require(SessionToken.self)
        try await req.usageCounterService.requirePremium(.targetAlerts, userId: session.userId, on: req.db)
        let payload = try req.content.decode(UpdateEarningsNotificationPreferencesRequest.self)
        return try await req.earningsNotificationPreferenceService.update(userId: session.userId, payload: payload, on: req.db)
    }
}

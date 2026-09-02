import StockPlanShared
import Vapor

struct UserProfileController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let userProfile = protected.grouped("users")
        let userProfileByID = userProfile.grouped(":id")

        userProfile.get(use: getProfile)
        userProfile.put(use: updateProfile)
        userProfile.patch("username", use: updateUsername)
        userProfile.patch("email", use: updateEmail)
        userProfile.patch("password", use: updatePassword)
        userProfile.delete(use: deleteProfile)

        userProfileByID.get(use: getProfileByID)
        userProfileByID.put(use: updateProfileByID)
        userProfileByID.delete(use: deleteProfileByID)
    }

    @Sendable
    func getProfile(req: Request) async throws -> GetUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.userProfileService.get(userId: session.userId, on: req.db)
    }

    @Sendable
    func updateProfile(req: Request) async throws -> UpdateUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdateUserProfileRequest.self)
        return try await req.application.userProfileService.update(userId: session.userId, payload: payload, on: req.db)
    }

    @Sendable
    func deleteProfile(req: Request) async throws -> DeleteUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.userProfileService.delete(userId: session.userId, on: req.db)
    }

    @Sendable
    func updateUsername(req: Request) async throws -> UpdateUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdateUsernameRequest.self)
        return try await req.application.userProfileService.updateUsername(userId: session.userId, payload: payload, on: req.db)
    }

    @Sendable
    func updateEmail(req: Request) async throws -> UpdateUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdateEmailRequest.self)
        return try await req.application.userProfileService.updateEmail(userId: session.userId, payload: payload, on: req.db)
    }

    @Sendable
    func updatePassword(req: Request) async throws -> APIMessageResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdatePasswordRequest.self)
        try await req.application.userProfileService.updatePassword(userId: session.userId, payload: payload, on: req)
        return APIMessageResponse(success: true, message: "Password updated successfully")
    }

    @Sendable
    func getProfileByID(req: Request) async throws -> GetUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let userId = try requireAuthorizedUserID(req, session: session)
        return try await req.application.userProfileService.get(userId: userId, on: req.db)
    }

    @Sendable
    func updateProfileByID(req: Request) async throws -> UpdateUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let userId = try requireAuthorizedUserID(req, session: session)
        let payload = try req.content.decode(UpdateUserProfileRequest.self)
        return try await req.application.userProfileService.update(userId: userId, payload: payload, on: req.db)
    }

    @Sendable
    func deleteProfileByID(req: Request) async throws -> DeleteUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let userId = try requireAuthorizedUserID(req, session: session)
        return try await req.application.userProfileService.delete(userId: userId, on: req.db)
    }

    private func requireAuthorizedUserID(_ req: Request, session: SessionToken) throws -> UUID {
        let userId = try requireUUIDParameter(req, name: "id", reason: "Invalid user ID")
        guard userId == session.userId else {
            throw Abort(.forbidden, reason: "You are not allowed to access this user profile")
        }
        return userId
    }

    private func requireUUIDParameter(_ req: Request, name: String, reason: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: reason)
        }
        return value
    }
}

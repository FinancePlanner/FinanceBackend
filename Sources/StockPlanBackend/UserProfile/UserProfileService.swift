import Fluent
import Foundation
import StockPlanShared
import Vapor

protocol UserProfileService: Sendable {
    func get(userId: UUID, on db: any Database) async throws -> GetUserProfileResponse
    func update(userId: UUID, payload: UpdateUserProfileRequest, on db: any Database) async throws -> UpdateUserProfileResponse
    func updateUsername(userId: UUID, payload: UpdateUsernameRequest, on db: any Database) async throws -> UpdateUserProfileResponse
    func updateEmail(userId: UUID, payload: UpdateEmailRequest, on db: any Database) async throws -> UpdateUserProfileResponse
    func updatePassword(userId: UUID, payload: UpdatePasswordRequest, on req: Request) async throws
    func delete(userId: UUID, on db: any Database) async throws -> DeleteUserProfileResponse
}

struct DefaultUserProfileService: UserProfileService {
    let repo: any UserProfileRepository

    func get(userId: UUID, on db: any Database) async throws -> GetUserProfileResponse {
        let user = try await requireUser(id: userId, on: db)
        return GetUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func update(userId: UUID, payload: UpdateUserProfileRequest, on db: any Database) async throws -> UpdateUserProfileResponse {
        guard payload.userProfile.id == userId.uuidString else {
            throw Abort(.badRequest, reason: "Profile ID does not match authenticated user")
        }

        let user = try await requireUser(id: userId, on: db)
        let normalizedEmail = normalizeEmail(payload.userProfile.email)
        let normalizedUsername = normalizeOptional(payload.userProfile.username)?.lowercased()
        let normalizedBio = normalizeOptional(payload.userProfile.bio)

        try validateEmail(normalizedEmail)
        try validateUsername(normalizedUsername)

        if let existing = try await repo.find(email: normalizedEmail, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Email already registered")
        }

        if let normalizedUsername,
           let existing = try await repo.find(username: normalizedUsername, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Username already registered")
        }

        user.email = normalizedEmail
        user.username = normalizedUsername
        user.bio = normalizedBio
        user.avatarURLString = payload.userProfile.avatarURL?.absoluteString
        user.bannerAvatarURLString = payload.userProfile.bannerAvatarURL?.absoluteString

        try await repo.save(user, on: db)
        return UpdateUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func delete(userId: UUID, on db: any Database) async throws -> DeleteUserProfileResponse {
        let user = try await requireUser(id: userId, on: db)
        try await repo.delete(user, on: db)
        return DeleteUserProfileResponse(success: true, message: "User account deleted")
    }

    func updateUsername(userId: UUID, payload: UpdateUsernameRequest, on db: any Database) async throws -> UpdateUserProfileResponse {
        let user = try await requireUser(id: userId, on: db)
        let normalizedUsername = normalizeOptional(payload.username)?.lowercased()
        try validateUsername(normalizedUsername)

        if let normalizedUsername,
           let existing = try await repo.find(username: normalizedUsername, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Username already registered")
        }

        user.username = normalizedUsername
        try await repo.save(user, on: db)
        return UpdateUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func updateEmail(userId: UUID, payload: UpdateEmailRequest, on db: any Database) async throws -> UpdateUserProfileResponse {
        let user = try await requireUser(id: userId, on: db)
        let normalizedEmail = normalizeEmail(payload.email)
        try validateEmail(normalizedEmail)

        if let existing = try await repo.find(email: normalizedEmail, on: db),
           existing.id != user.id
        {
            throw Abort(.conflict, reason: "Email already registered")
        }

        user.email = normalizedEmail
        try await repo.save(user, on: db)
        return UpdateUserProfileResponse(userProfile: makeProfile(from: user))
    }

    func updatePassword(userId: UUID, payload: UpdatePasswordRequest, on req: Request) async throws {
        let db = req.db
        let user = try await requireUser(id: userId, on: db)

        // Verify current password
        guard try await req.password.async.verify(payload.currentPassword, created: user.passwordHash).get() else {
            throw Abort(.unauthorized, reason: "Invalid current password")
        }

        // Hash and save new password
        user.passwordHash = try await req.password.async.hash(payload.newPassword).get()
        try await repo.save(user, on: db)
    }

    private func requireUser(id: UUID, on db: any Database) async throws -> User {
        guard let user = try await repo.find(id: id, on: db) else {
            throw Abort(.unauthorized, reason: "User not found")
        }
        return user
    }

    private func makeProfile(from user: User) -> UserProfile {
        UserProfile(
            id: user.id?.uuidString ?? "",
            email: user.email,
            bio: normalizeOptional(user.bio),
            avatarURL: user.avatarURLString.flatMap(URL.init(string:)),
            bannerAvatarURL: user.bannerAvatarURLString.flatMap(URL.init(string:)),
            username: normalizeOptional(user.username)
        )
    }

    private func normalizeEmail(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateEmail(_ email: String) throws {
        if email.isEmpty || !email.contains("@") {
            throw Abort(.badRequest, reason: "Invalid email")
        }
    }

    private func validateUsername(_ username: String?) throws {
        guard let username else { return }
        let pattern = #"^[a-zA-Z0-9_]{4,30}$"#
        if username.range(of: pattern, options: .regularExpression) == nil {
            throw Abort(.badRequest, reason: "Username must be 4-30 characters (letters, numbers, underscore)")
        }
    }
}

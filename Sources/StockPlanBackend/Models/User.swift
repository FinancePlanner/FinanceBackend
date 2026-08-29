import Fluent
import Foundation
import Vapor

final class User: Model, Authenticatable, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @OptionalField(key: "username")
    var username: String?

    @OptionalField(key: "bio")
    private var bioPlaintext: String?

    @OptionalField(key: "bio_encrypted")
    var bioEncrypted: Data?

    @OptionalField(key: "avatar_url")
    var avatarURLString: String?

    @OptionalField(key: "banner_avatar_url")
    var bannerAvatarURLString: String?

    @OptionalField(key: "household_partner_display_name")
    private var householdPartnerDisplayNamePlaintext: String?

    @OptionalField(key: "household_partner_display_name_encrypted")
    var householdPartnerDisplayNameEncrypted: Data?

    /// Percentage of a shared item the owner keeps, seeding new shared items.
    /// Null means no household default; see AddHouseholdDefaultSharePercentToUsers.
    @OptionalField(key: "household_default_user_share_percent")
    var householdDefaultUserSharePercent: Double?

    @OptionalField(key: "date_of_birth")
    private var dateOfBirthPlaintext: Date?

    @OptionalField(key: "date_of_birth_encrypted")
    var dateOfBirthEncrypted: Data?

    @Field(key: "failed_login_attempts")
    var failedLoginAttempts: Int

    @OptionalField(key: "lockout_until")
    var lockoutUntil: Date?

    @Field(key: "is_verified")
    var isVerified: Bool

    @OptionalField(key: "trial_started_at")
    var trialStartedAt: Date?

    @OptionalField(key: "trial_days")
    var trialDays: Int?

    @OptionalField(key: "trial_tier")
    var trialTier: String?

    @Field(key: "had_trial")
    var hadTrial: Bool

    @OptionalField(key: "trial_warning_sent_at")
    var trialWarningSentAt: Date?

    @OptionalField(key: "dca_symbol")
    var dcaSymbol: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    private var decryptedBio: String?
    private var decryptedHouseholdPartnerDisplayName: String?
    private var decryptedDateOfBirth: Date?

    var bio: String? {
        get { decryptedBio ?? bioPlaintext }
        set {
            decryptedBio = newValue
            bioPlaintext = newValue
        }
    }

    var householdPartnerDisplayName: String? {
        get { decryptedHouseholdPartnerDisplayName ?? householdPartnerDisplayNamePlaintext }
        set {
            decryptedHouseholdPartnerDisplayName = newValue
            householdPartnerDisplayNamePlaintext = newValue
        }
    }

    var dateOfBirth: Date? {
        get { decryptedDateOfBirth ?? dateOfBirthPlaintext }
        set {
            decryptedDateOfBirth = newValue
            dateOfBirthPlaintext = newValue
        }
    }

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String,
        username: String? = nil,
        bio: String? = nil,
        avatarURLString: String? = nil,
        bannerAvatarURLString: String? = nil,
        householdPartnerDisplayName: String? = nil,
        householdDefaultUserSharePercent: Double? = nil,
        dateOfBirth: Date? = nil,
        failedLoginAttempts: Int = 0,
        lockoutUntil: Date? = nil,
        isVerified: Bool = false,
        hadTrial: Bool = false,
        trialStartedAt: Date? = nil,
        trialDays: Int? = nil,
        trialTier: String? = nil
    ) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.username = username
        bioPlaintext = bio
        decryptedBio = bio
        self.avatarURLString = avatarURLString
        self.bannerAvatarURLString = bannerAvatarURLString
        householdPartnerDisplayNamePlaintext = householdPartnerDisplayName
        decryptedHouseholdPartnerDisplayName = householdPartnerDisplayName
        self.householdDefaultUserSharePercent = householdDefaultUserSharePercent
        dateOfBirthPlaintext = dateOfBirth
        decryptedDateOfBirth = dateOfBirth
        self.failedLoginAttempts = failedLoginAttempts
        self.lockoutUntil = lockoutUntil
        self.isVerified = isVerified
        self.hadTrial = hadTrial
        self.trialStartedAt = trialStartedAt
        self.trialDays = trialDays
        self.trialTier = trialTier
    }
}

extension User {
    func hydrateProtectedFields(using encryptionService: any UserPIIEncrypting) throws {
        if let encryptedBio = bioEncrypted {
            decryptedBio = try encryptionService.decryptString(encryptedBio)
        } else {
            decryptedBio = bioPlaintext
        }

        if let encryptedPartnerName = householdPartnerDisplayNameEncrypted {
            decryptedHouseholdPartnerDisplayName = try encryptionService.decryptString(encryptedPartnerName)
        } else {
            decryptedHouseholdPartnerDisplayName = householdPartnerDisplayNamePlaintext
        }

        if let encryptedDOB = dateOfBirthEncrypted {
            let value = try encryptionService.decryptString(encryptedDOB)
            guard let milliseconds = Int64(value) else {
                throw UserPIIEncryptionError.invalidPayload
            }
            decryptedDateOfBirth = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        } else {
            decryptedDateOfBirth = dateOfBirthPlaintext
        }
    }

    func encryptProtectedFields(using encryptionService: any UserPIIEncrypting) throws {
        if let bioValue = decryptedBio ?? bioPlaintext {
            bioEncrypted = try encryptionService.encryptString(bioValue)
        } else {
            bioEncrypted = nil
        }
        bioPlaintext = nil

        if let partnerName = decryptedHouseholdPartnerDisplayName ?? householdPartnerDisplayNamePlaintext {
            householdPartnerDisplayNameEncrypted = try encryptionService.encryptString(partnerName)
        } else {
            householdPartnerDisplayNameEncrypted = nil
        }
        householdPartnerDisplayNamePlaintext = nil

        if let dateOfBirthValue = decryptedDateOfBirth ?? dateOfBirthPlaintext {
            let millis = Int64((dateOfBirthValue.timeIntervalSince1970 * 1000).rounded())
            dateOfBirthEncrypted = try encryptionService.encryptString(String(millis))
        } else {
            dateOfBirthEncrypted = nil
        }
        dateOfBirthPlaintext = nil
    }
}

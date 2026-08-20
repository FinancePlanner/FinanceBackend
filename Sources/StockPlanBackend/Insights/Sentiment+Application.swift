import Vapor

extension Application {
    struct SentimentRepositoryKey: StorageKey {
        typealias Value = any SentimentRepository
    }

    struct SentimentAggregationServiceKey: StorageKey {
        typealias Value = any SentimentAggregationServing
    }

    struct SentimentQueryServiceKey: StorageKey {
        typealias Value = any SentimentQuerying
    }

    struct SentimentSyncStatusKey: StorageKey {
        typealias Value = SentimentSyncStatus
    }

    struct SentimentIndexSeederKey: StorageKey {
        typealias Value = SentimentIndexSeeder
    }

    struct ProviderCooldownRegistryKey: StorageKey {
        typealias Value = ProviderCooldownRegistry
    }

    var sentimentRepository: any SentimentRepository {
        get { storage[SentimentRepositoryKey.self]! }
        set { storage[SentimentRepositoryKey.self] = newValue }
    }

    var sentimentAggregationService: any SentimentAggregationServing {
        get { storage[SentimentAggregationServiceKey.self]! }
        set { storage[SentimentAggregationServiceKey.self] = newValue }
    }

    var sentimentQueryService: any SentimentQuerying {
        get { storage[SentimentQueryServiceKey.self]! }
        set { storage[SentimentQueryServiceKey.self] = newValue }
    }

    var sentimentSyncStatus: SentimentSyncStatus {
        get { storage[SentimentSyncStatusKey.self]! }
        set { storage[SentimentSyncStatusKey.self] = newValue }
    }

    var sentimentIndexSeeder: SentimentIndexSeeder {
        get { storage[SentimentIndexSeederKey.self]! }
        set { storage[SentimentIndexSeederKey.self] = newValue }
    }

    /// Shared with the provider chain so a credit-exhaustion cooldown observed
    /// on one call suppresses the rest of the run.
    var providerCooldowns: ProviderCooldownRegistry {
        get { storage[ProviderCooldownRegistryKey.self]! }
        set { storage[ProviderCooldownRegistryKey.self] = newValue }
    }
}

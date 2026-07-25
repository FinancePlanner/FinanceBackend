import Vapor

extension Application {
    struct DashboardRepositoryKey: StorageKey {
        typealias Value = any DashboardRepository
    }

    struct WhyMovedServiceKey: StorageKey {
        typealias Value = any WhyMovedService
    }

    struct DashboardServiceKey: StorageKey {
        typealias Value = any DashboardService
    }

    var dashboardRepository: any DashboardRepository {
        get { storage[DashboardRepositoryKey.self]! }
        set { storage[DashboardRepositoryKey.self] = newValue }
    }

    var whyMovedService: any WhyMovedService {
        get { storage[WhyMovedServiceKey.self]! }
        set { storage[WhyMovedServiceKey.self] = newValue }
    }

    var dashboardService: any DashboardService {
        get { storage[DashboardServiceKey.self]! }
        set { storage[DashboardServiceKey.self] = newValue }
    }
}

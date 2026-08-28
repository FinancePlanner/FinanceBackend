import Vapor

extension Application {
    struct OpenAIChatClientKey: StorageKey {
        typealias Value = any OpenAIChatClient
    }

    var openAIChatClient: any OpenAIChatClient {
        get { storage[OpenAIChatClientKey.self]! }
        set { storage[OpenAIChatClientKey.self] = newValue }
    }

    /// Optional on purpose: nil means "no plan routing", which is the path
    /// `AIChatTests` and `WhyMovedTests` take when they inject a scripted client
    /// into `openAIChatClient`.
    struct AIModelRouterKey: StorageKey {
        typealias Value = AIModelRouter
    }

    var aiModelRouter: AIModelRouter? {
        get { storage[AIModelRouterKey.self] }
        set { storage[AIModelRouterKey.self] = newValue }
    }

    struct AIViewSummaryServiceKey: StorageKey {
        typealias Value = any AIViewSummaryService
    }

    var aiViewSummaryService: any AIViewSummaryService {
        get { storage[AIViewSummaryServiceKey.self]! }
        set { storage[AIViewSummaryServiceKey.self] = newValue }
    }

    struct AIInsightsServiceKey: StorageKey {
        typealias Value = any AIInsightsService
    }

    var aiInsightsService: any AIInsightsService {
        get { storage[AIInsightsServiceKey.self]! }
        set { storage[AIInsightsServiceKey.self] = newValue }
    }

    struct AIChatServiceKey: StorageKey {
        typealias Value = any AIChatService
    }

    var aiChatService: any AIChatService {
        get { storage[AIChatServiceKey.self]! }
        set { storage[AIChatServiceKey.self] = newValue }
    }
}

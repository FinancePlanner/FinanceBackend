import Foundation
import Vapor

/// What the model is shown: structure and a small sample, never the file.
///
/// A digest is built from the detector's output, so the model is reasoning
/// about columns we have already typed and bounded rather than raw cells. Cell
/// values are truncated and sampled; the upload itself never leaves the process
/// and is never written to disk.
struct SpreadsheetDigest: Content, Sendable {
    struct Column: Content, Sendable {
        let letter: String
        let header: String?
        let detectedType: String
        let distinctCount: Int
        let samples: [String]
    }

    struct Sheet: Content, Sendable {
        let name: String
        let rowCount: Int
        let headerRow: Int?
        let columns: [Column]
    }

    let sheets: [Sheet]
    /// Category names the user already has, so mappings can point at them
    /// instead of inventing near-duplicates ("Groceries" vs "Grocery").
    let existingCategories: [String]
    /// The only pillar values that will be accepted. Anything else is dropped
    /// by the validator.
    let allowedPillars: [String]
}

/// What the model proposes. Every field is a suggestion; nothing here is
/// applied without passing `SpreadsheetMappingValidator` first.
struct SpreadsheetAIProposal: Sendable, Equatable {
    struct ColumnProposal: Sendable, Equatable {
        let letter: String
        let field: String
        let confidence: Double
    }

    struct CategoryProposal: Sendable, Equatable {
        let sourceValue: String
        let pillar: String?
        let categoryName: String?
        let confidence: Double
    }

    let sheetName: String?
    let columns: [ColumnProposal]
    let categories: [CategoryProposal]
    let notes: [String]
    let confidence: Double
}

/// Proposes a mapping for a spreadsheet.
///
/// Optional by design: when no provider is configured the import still runs on
/// the detector alone, with weaker category mapping. Nothing in the pipeline
/// may treat an absent or failed proposal as an error.
protocol SpreadsheetAnalysisProvider: Sendable {
    var isEnabled: Bool { get }

    /// Returns nil when unavailable or when the response can't be trusted.
    /// Implementations must not throw for provider-side failures — degrading to
    /// heuristics is always preferable to failing the user's upload.
    func analyze(digest: SpreadsheetDigest, on req: Request) async throws -> SpreadsheetAIProposal?
}

/// Used when no provider is configured. The feature remains fully usable.
struct DisabledSpreadsheetAnalysisProvider: SpreadsheetAnalysisProvider {
    var isEnabled: Bool {
        false
    }

    func analyze(digest _: SpreadsheetDigest, on _: Request) async throws -> SpreadsheetAIProposal? {
        nil
    }
}

enum SpreadsheetAnalysisProviderKind: String {
    case disabled
    case openAI

    static func select(configured: String?) -> SpreadsheetAnalysisProviderKind {
        switch configured?.lowercased() {
        case "openai", "ai", "enabled":
            .openAI
        case "disabled", "", nil:
            .disabled
        default:
            .disabled
        }
    }
}

enum SpreadsheetAnalysisProviderBootstrap {
    /// Selects the provider from `SPREADSHEET_IMPORT_AI`. Defaults to disabled,
    /// which is also the kill switch for customers who don't want spreadsheet
    /// contents reaching a third party. Credentials come from
    /// `AIProviderConfiguration`; the model can be pinned separately via
    /// `SPREADSHEET_IMPORT_MODEL`.
    static func fromEnvironment(app: Application) -> any SpreadsheetAnalysisProvider {
        let configured = Environment.get("SPREADSHEET_IMPORT_AI")?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch SpreadsheetAnalysisProviderKind.select(configured: configured) {
        case .openAI:
            let config = AIProviderConfiguration.load()
            let rawModel = Environment.get("SPREADSHEET_IMPORT_MODEL")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = rawModel.isEmpty ? config.chatModel : rawModel
            let provider = OpenAISpreadsheetAnalysisProvider(
                apiKey: config.apiKey,
                baseURL: config.baseURL,
                model: model
            )
            guard provider.isEnabled else {
                app.logger.warning(
                    "SPREADSHEET_IMPORT_AI=\(configured ?? "") set but AI credentials/model are missing; spreadsheet import will use heuristics only."
                )
                return DisabledSpreadsheetAnalysisProvider()
            }
            app.logger.notice("spreadsheet_import configured provider=openai model=\(model)")
            return provider
        case .disabled:
            if let configured, !configured.isEmpty, configured.lowercased() != "disabled" {
                app.logger.warning(
                    "SPREADSHEET_IMPORT_AI=\(configured) is not recognized; spreadsheet import will use heuristics only."
                )
            }
            return DisabledSpreadsheetAnalysisProvider()
        }
    }
}

extension Application {
    struct SpreadsheetAnalysisProviderKey: StorageKey {
        typealias Value = any SpreadsheetAnalysisProvider
    }

    var spreadsheetAnalysisProvider: any SpreadsheetAnalysisProvider {
        get { storage[SpreadsheetAnalysisProviderKey.self] ?? DisabledSpreadsheetAnalysisProvider() }
        set { storage[SpreadsheetAnalysisProviderKey.self] = newValue }
    }
}

extension Request {
    var spreadsheetAnalysisProvider: any SpreadsheetAnalysisProvider {
        application.spreadsheetAnalysisProvider
    }
}

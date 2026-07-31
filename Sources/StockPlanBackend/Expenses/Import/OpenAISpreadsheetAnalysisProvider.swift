import Foundation
import NIOCore
import Vapor

/// Spreadsheet mapping via an OpenAI-compatible chat model.
///
/// Uses its own request shape rather than `DefaultOpenAIChatClient`, which
/// hardcodes temperature 0.3 — too loose for extraction, where the same file
/// should map the same way every time.
///
/// Every failure path returns nil rather than throwing. A provider outage must
/// degrade the import to heuristics, never reject an upload the user has
/// already waited on.
struct OpenAISpreadsheetAnalysisProvider: SpreadsheetAnalysisProvider {
    let apiKey: String
    let baseURL: String
    let model: String
    /// Generous enough for a slow model, short enough that a hung provider
    /// doesn't hold the user's request open indefinitely.
    var timeout: TimeAmount = .seconds(25)

    var isEnabled: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }

    func analyze(digest: SpreadsheetDigest, on req: Request) async throws -> SpreadsheetAIProposal? {
        guard isEnabled else { return nil }

        guard let digestJSON = try? JSONEncoder().encode(digest),
              let digestText = String(data: digestJSON, encoding: .utf8)
        else {
            req.logger.warning("spreadsheet_import_ai skipped: digest could not be encoded")
            return nil
        }

        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: SpreadsheetAnalysisPrompt.system),
                .init(role: "user", content: SpreadsheetAnalysisPrompt.user(digestJSON: digestText)),
            ],
            temperature: 0,
            maxTokens: 1200,
            responseFormat: .init(type: "json_object")
        )

        let uri = URI(string: "\(baseURL)/chat/completions")
        let response: ClientResponse
        do {
            response = try await req.client.post(uri) { clientReq in
                clientReq.headers.contentType = .json
                clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                clientReq.timeout = timeout
                try clientReq.content.encode(body)
            }
        } catch {
            req.logger.warning("spreadsheet_import_ai request failed: \(error.localizedDescription)")
            return nil
        }

        guard response.status == .ok else {
            let bodyText = response.body.map { String(buffer: $0) } ?? ""
            req.logger.error(
                "spreadsheet_import_ai_error status=\(response.status.code) body=\(bodyText.prefix(300))"
            )
            return nil
        }

        guard
            let decoded = try? response.content.decode(ChatResponse.self),
            let jsonText = decoded.choices.first?.message.content,
            let jsonData = jsonText.data(using: .utf8),
            let proposal = try? JSONDecoder().decode(RawProposal.self, from: jsonData)
        else {
            req.logger.warning("spreadsheet_import_ai returned an unparseable proposal")
            return nil
        }

        // Deliberately no cell content in the log -- only shape.
        req.logger.info(
            "spreadsheet_import_ai model=\(model) columns=\(proposal.columns?.count ?? 0) categories=\(proposal.categories?.count ?? 0)"
        )
        return proposal.toProposal()
    }
}

// MARK: - Wire model

private struct ChatRequest: Content {
    struct Message: Content {
        var role: String
        var content: String
    }

    struct ResponseFormat: Content {
        var type: String
    }

    var model: String
    var messages: [Message]
    var temperature: Double
    var maxTokens: Int
    var responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct ChatResponse: Content {
    struct Choice: Content {
        var message: Message
    }

    struct Message: Content {
        var content: String?
    }

    var choices: [Choice]
}

/// Everything optional: a model that omits or mistypes a field should cost us
/// that field, not the whole proposal.
private struct RawProposal: Decodable {
    struct Column: Decodable {
        var column: String?
        var field: String?
        var confidence: Double?
    }

    struct Category: Decodable {
        var sourceValue: String?
        var pillar: String?
        var categoryName: String?
        var confidence: Double?
    }

    var sheet: String?
    var columns: [Column]?
    var categories: [Category]?
    var notes: [String]?
    var confidence: Double?

    func toProposal() -> SpreadsheetAIProposal {
        SpreadsheetAIProposal(
            sheetName: sheet?.trimmingCharacters(in: .whitespacesAndNewlines),
            columns: (columns ?? []).compactMap { column in
                guard let letter = column.column?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !letter.isEmpty,
                      let field = column.field?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !field.isEmpty
                else { return nil }
                return .init(
                    letter: letter.uppercased(),
                    field: field,
                    confidence: clamp(column.confidence)
                )
            },
            categories: (categories ?? []).compactMap { category in
                guard let sourceValue = category.sourceValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !sourceValue.isEmpty
                else { return nil }
                return .init(
                    sourceValue: sourceValue,
                    pillar: category.pillar?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
                    categoryName: category.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
                    confidence: clamp(category.confidence)
                )
            },
            notes: Array((notes ?? []).prefix(10)),
            confidence: clamp(confidence)
        )
    }

    private func clamp(_ value: Double?) -> Double {
        min(max(value ?? 0.5, 0), 1)
    }
}

private extension String {
    var nilWhenEmpty: String? {
        isEmpty ? nil : self
    }
}

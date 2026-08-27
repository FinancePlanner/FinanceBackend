import Foundation
import StockPlanShared
import Vapor

/// Receipt OCR via an OpenAI-compatible vision chat model. Sends the receipt
/// image as a base64 data URL and asks for a strict JSON object, which is
/// decoded into a `ReceiptDraft`. Uses its own multimodal request shape because
/// the assistant's `OpenAIMessage.content` is a plain string and cannot carry
/// images. Credentials/base URL are shared with the AI assistant
/// (`AIProviderConfiguration`); the model is chosen separately so a
/// vision-capable model can be pinned without changing the chat model.
struct OpenAIVisionReceiptOCRProvider: ReceiptOCRProvider {
    let apiKey: String
    let baseURL: String
    let model: String

    var isEnabled: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }

    func extract(imageData: Data, contentType: String, on req: Request) async throws -> ReceiptDraft? {
        guard isEnabled else { return nil }

        let mime = contentType.isEmpty || contentType == "application/octet-stream" ? "image/jpeg" : contentType
        let dataURL = "data:\(mime);base64,\(imageData.base64EncodedString())"

        let body = VisionRequest(
            model: model,
            messages: [
                VisionMessage(role: "system", content: [.text(Self.systemPrompt)]),
                VisionMessage(role: "user", content: [
                    .text("Extract the fields from this receipt image and return the JSON object."),
                    .imageURL(dataURL),
                ]),
            ],
            temperature: 0,
            maxTokens: 500,
            responseFormat: .init(type: "json_object")
        )

        let uri = URI(string: "\(baseURL)/chat/completions")
        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            try clientReq.content.encode(body)
        }

        guard response.status == .ok else {
            let bodyText = response.body.map { String(buffer: $0) } ?? ""
            req.logger.error("receipt_ocr_error status=\(response.status.code) body=\(bodyText.prefix(300))")
            throw Abort(.badGateway, reason: "Receipt OCR is temporarily unavailable. Please try again.")
        }

        // See `DefaultOpenAIChatClient.decodeProviderJSON`: third-party payloads must not
        // go through the global API decoder, which eats explicitly mapped snake_case keys.
        let decoded = try DefaultOpenAIChatClient.decodeProviderJSON(
            VisionResponse.self,
            from: response,
            logger: req.logger
        )
        guard
            let jsonText = decoded.choices.first?.message.content,
            let jsonData = jsonText.data(using: .utf8),
            let extracted = try? JSONDecoder().decode(ExtractedReceipt.self, from: jsonData),
            extracted.hasContent
        else {
            return nil
        }
        return extracted.toDraft()
    }

    private static let systemPrompt = """
    You extract structured data from a photographed shop receipt. Respond with a \
    single JSON object and nothing else, using exactly these keys (use null when a \
    value is not clearly legible — never guess):
    {"merchant": string|null, "total": number|null, "currency": string|null (ISO 4217, e.g. "EUR"), \
    "date": string|null (YYYY-MM-DD), "taxId": string|null (merchant tax/VAT id), \
    "taxTotal": number|null (total VAT/tax amount)}
    Amounts are numbers without currency symbols. If the image is not a receipt, \
    return all null values.
    """
}

// MARK: - Vision request wire model (multimodal content array)

private struct VisionRequest: Content {
    var model: String
    var messages: [VisionMessage]
    var temperature: Double
    var maxTokens: Int
    var responseFormat: ResponseFormat

    struct ResponseFormat: Content {
        var type: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct VisionMessage: Content {
    var role: String
    var content: [VisionContentPart]
}

/// A single content part — either a text span or an image reference. Encodes to
/// the OpenAI chat multimodal shape (`{"type":"text",...}` / `{"type":"image_url",...}`).
private enum VisionContentPart: Content {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    private struct ImageURL: Content {
        var url: String
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "image_url" {
            self = try .imageURL(container.decode(ImageURL.self, forKey: .imageURL).url)
        } else {
            self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
        }
    }
}

private struct VisionResponse: Content {
    var choices: [Choice]

    struct Choice: Content {
        var message: Message
    }

    struct Message: Content {
        var content: String?
    }
}

// MARK: - Extracted JSON → ReceiptDraft

private struct ExtractedReceipt: Decodable {
    var merchant: String?
    var total: Double?
    var currency: String?
    var date: String?
    var taxId: String?
    var taxTotal: Double?

    var hasContent: Bool {
        merchant != nil || total != nil || taxId != nil || taxTotal != nil
    }

    func toDraft() -> ReceiptDraft {
        ReceiptDraft(
            merchant: merchant?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            total: total,
            currency: currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty,
            date: date?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            taxId: taxId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            taxTotal: taxTotal,
            vatLines: [],
            confidence: 0.6,
            source: .ocr,
            rawPayload: nil
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

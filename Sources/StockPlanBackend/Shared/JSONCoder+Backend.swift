import Foundation
import StockPlanShared

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension JSONDecoder {
    static var backendAPI: JSONDecoder {
        let decoder = JSONDecoder.stockPlanShared
        decoder.keyDecodingStrategy = .custom { codingPath in
            guard let last = codingPath.last else {
                return AnyCodingKey(stringValue: "")!
            }

            let key = last.stringValue
            if key.contains("_") {
                return AnyCodingKey(stringValue: normalizeSnakeCaseKey(key))!
            }
            return AnyCodingKey(stringValue: key)!
        }
        return decoder
    }

    private static func normalizeSnakeCaseKey(_ key: String) -> String {
        let parts = key.split(separator: "_").map { String($0).lowercased() }
        guard let first = parts.first else { return key }

        var normalized = first
        for segment in parts.dropFirst() {
            if segment == "url" {
                normalized += "URL"
            } else if segment == "uri" {
                normalized += "URI"
            } else if segment == "id" {
                normalized += "Id"
            } else {
                normalized += segment.prefix(1).uppercased() + segment.dropFirst()
            }
        }
        return normalized
    }
}

extension JSONDecoder {
    /// For payloads written by somebody else: AI providers, OAuth providers,
    /// banking APIs.
    ///
    /// `backendAPI` above rewrites every snake_case key to camelCase *before*
    /// `CodingKeys` lookup, which is right for our own clients and wrong for a
    /// third-party wire format: a struct that maps `case toolCalls =
    /// "tool_calls"` explicitly then matches nothing and decodes as nil, with no
    /// error to notice. Reach for this whenever the JSON was not produced by us.
    static var externalProvider: JSONDecoder {
        JSONDecoder()
    }
}

extension JSONEncoder {
    static var backendAPI: JSONEncoder {
        let encoder = JSONEncoder.stockPlanShared
        encoder.keyEncodingStrategy = .useDefaultKeys
        return encoder
    }
}

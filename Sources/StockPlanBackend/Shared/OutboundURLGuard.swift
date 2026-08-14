import Foundation
import Vapor

/// Guards outbound requests to user-supplied URLs.
///
/// This exists because bring-your-own-key lets a user hand us a base URL that
/// the server will then POST a bearer token to. Unguarded, that is textbook
/// SSRF and credential exfiltration: point Norviq at `169.254.169.254` or an
/// internal host and it will happily authenticate to it.
///
/// Lifted out of `FinancingController.blockedHost` so there is exactly one copy
/// of this list.
enum OutboundURLGuard {
    enum Failure: Error, CustomStringConvertible {
        case notHTTPS
        case malformed
        case blockedHost(String)

        var description: String {
            switch self {
            case .notHTTPS: "URL must use https."
            case .malformed: "URL is not a valid absolute URL."
            case let .blockedHost(host): "Host \(host) is not allowed."
            }
        }
    }

    /// True for hosts that must never be reached from server-side code:
    /// loopback, link-local (including the cloud metadata endpoint), and the
    /// RFC 1918 private ranges.
    static func isBlockedHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }
        if host == "0.0.0.0" || host == "127.0.0.1" || host == "::1" {
            return true
        }
        if host.hasPrefix("127.") {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
            return true
        }
        if host.hasPrefix("172.") {
            let secondOctet = Int(host.split(separator: ".").dropFirst().first ?? "") ?? -1
            if (16 ... 31).contains(secondOctet) {
                return true
            }
        }
        return false
    }

    /// Validates a user-supplied base URL.
    ///
    /// Call this at *use* time as well as at create time. A host that resolved
    /// to a public address when it was saved can point somewhere else later.
    @discardableResult
    static func validate(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw Failure.malformed
        }
        guard url.scheme?.lowercased() == "https" else {
            throw Failure.notHTTPS
        }
        guard !isBlockedHost(host) else {
            throw Failure.blockedHost(host)
        }
        return url
    }

    /// Same check, surfaced as an HTTP error for use inside a route handler.
    static func validateForRequest(_ raw: String) throws -> URL {
        do {
            return try validate(raw)
        } catch let failure as Failure {
            throw Abort(.badRequest, reason: failure.description)
        }
    }
}

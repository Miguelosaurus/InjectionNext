#if DEBUG || !SWIFT_PACKAGE
import Foundation

/// Narrow install envelope carried by the existing authenticated Debug connection.
/// No arbitrary URL schemes, other app identities, or expired requests are admitted.
struct DeveloperInstallIntent: Codable, Equatable {
    let buildID: String
    let bundleID: String
    let version: String
    let build: String
    let sha256: String
    let manifestURL: String
    let expiresAt: Double

    static func parse(_ value: String?, bundleID: String, now: Double = Date().timeIntervalSince1970) -> Self? {
        guard let value, value.utf8.count <= 4096, let data = value.data(using: .utf8),
              let item = try? JSONDecoder().decode(Self.self, from: data),
              UUID(uuidString: item.buildID) != nil, item.bundleID == bundleID, !bundleID.isEmpty,
              !item.version.isEmpty, item.version.utf8.count <= 128,
              !item.build.isEmpty, item.build.utf8.count <= 128,
              item.sha256.count == 64, item.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              item.expiresAt.isFinite, item.expiresAt > now, item.expiresAt <= now + 7200,
              let url = URLComponents(string: item.manifestURL), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              url.path == "/api/device-builds/\(item.buildID)/artifact/manifest",
              let query = url.queryItems, query.count == 1, query[0].name == "token",
              let token = query[0].value, token.count >= 24, token.count <= 256,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return item
    }

    var installURL: URL? {
        var url = URLComponents()
        url.scheme = "itms-services"; url.host = ""
        url.queryItems = [URLQueryItem(name: "action", value: "download-manifest"),
                          URLQueryItem(name: "url", value: manifestURL)]
        return url.url
    }
}
#endif

import Foundation

/// Build-time configuration injected from Config.xcconfig via Info.plist.
enum AppConfig {
    static var baseURL: URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
              !raw.isEmpty, let url = URL(string: raw)
        else { fatalError("API_BASE_URL missing — copy Config.xcconfig.example to Config.xcconfig") }
        return url
    }

    static var token: String {
        Bundle.main.object(forInfoDictionaryKey: "API_TOKEN") as? String ?? ""
    }

    /// Where assistants connect. They authenticate via OAuth, approving with a code minted in-app.
    static var mcpURL: String { baseURL.absoluteString + "/mcp" }

    /// Opens claude.ai with the custom-connector sheet pre-filled.
    static var addToClaudeURL: URL? {
        var components = URLComponents(string: "https://claude.ai/customize/connectors")
        components?.queryItems = [
            URLQueryItem(name: "modal", value: "add-custom-connector"),
            URLQueryItem(name: "connectorName", value: "eidetic"),
            URLQueryItem(name: "connectorUrl", value: mcpURL),
        ]
        return components?.url
    }
}

import Foundation

enum APIError: LocalizedError {
    case http(status: Int, body: String)
    case offline

    var errorDescription: String? {
        switch self {
        case .http(let status, _): "server error \(status)"
        case .offline: "offline"
        }
    }
}

/// Thin async JSON client. snake_case on the wire, camelCase in Swift;
/// dates are second-resolution ISO 8601 UTC both ways.
struct APIClient: Sendable {
    var baseURL = AppConfig.baseURL
    var token = AppConfig.token

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(raw, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601))
        }
        return e
    }()

    func get<T: Decodable>(_ path: String) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send("GET", path, body: nil))
    }

    func post<T: Decodable>(_ path: String, _ body: (some Encodable)? = Optional<Int>.none) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send("POST", path, body: body.map { try Self.encoder.encode($0) }))
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw error.code == .cancelled ? error : APIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

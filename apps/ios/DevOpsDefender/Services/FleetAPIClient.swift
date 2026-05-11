import Foundation

enum FleetError: LocalizedError {
    case missingToken
    case unauthorized
    case transport(String)
    case decode(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "Not signed in"
        case .unauthorized: return "Sign-in expired"
        case .transport(let m): return "Network error: \(m)"
        case .decode(let m): return "Bad response: \(m)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(120))"
        }
    }
}

/// Talks to the control plane on behalf of the signed-in iOS user.
/// Today: list the agents this user is authorized for. Per-agent
/// session listing happens via the agent's Noise RPC, not via the CP.
struct FleetAPIClient {
    /// Default CP base URL. The README points at this host.
    static let defaultCPBaseURL = URL(string: "https://app.devopsdefender.com")!

    var baseURL: URL
    var keychain: KeychainStore
    var session: URLSession

    init(
        baseURL: URL = FleetAPIClient.defaultCPBaseURL,
        keychain: KeychainStore = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.keychain = keychain
        self.session = session
    }

    func agents() async throws -> [AgentSummary] {
        guard let token = keychain.string(for: .bearerToken), !token.isEmpty else {
            throw FleetError.missingToken
        }
        let url = baseURL.appendingPathComponent("/api/v1/agents")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FleetError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FleetError.decode("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([AgentSummary].self, from: data)
            } catch {
                throw FleetError.decode(error.localizedDescription)
            }
        case 401, 403:
            throw FleetError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FleetError.http(http.statusCode, body)
        }
    }
}

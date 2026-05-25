import Foundation

/// Codex CLI の OAuth 認証を使って Codex の 5h / 7d 利用状況を取得する。
///
/// 認証情報は新規保存せず、Codex CLI が管理する `~/.codex/auth.json` を読む。
/// このファイルには OAuth token が含まれるため、ログやダンプには出さない。
final class CodexUsageFetcher {

    private let session: URLSession
    private let authURL: URL
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    func fetchUsage() async throws -> CodexUsageSnapshot {
        let auth = try loadAuth()

        do {
            let data = try await getUsage(accessToken: auth.accessToken, accountID: auth.accountID)
            DebugDump.writeCodex(data: prettyJSON(data) ?? data)
            return try decodeUsage(data)
        } catch FetchError.unauthorized {
            let refreshed = try await refreshAccessToken(refreshToken: auth.refreshToken)
            let data = try await getUsage(accessToken: refreshed, accountID: auth.accountID)
            DebugDump.writeCodex(data: prettyJSON(data) ?? data)
            return try decodeUsage(data)
        }
    }

    private func loadAuth() throws -> CodexAuth {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw FetchError.decodeFailed("Codex auth not found. Run `codex login` first.")
        }
        let data = try Data(contentsOf: authURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String
        else {
            throw FetchError.decodeFailed("Codex auth.json does not contain OAuth tokens.")
        }
        return CodexAuth(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: tokens["account_id"] as? String
        )
    }

    private func getUsage(accessToken: String, accountID: String?) async throws -> Data {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeCodexUsageBar/1.0", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar.Codex", code: -1))
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw FetchError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ].map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }.joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar.Codex", code: -2))
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String
        else {
            throw FetchError.decodeFailed("Codex token refresh response did not include access_token.")
        }
        return token
    }

    private func decodeUsage(_ data: Data) throws -> CodexUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decodeFailed("Codex usage response is not a JSON object.")
        }
        let rateLimit = root["rate_limit"] as? [String: Any] ?? root
        return CodexUsageSnapshot(
            plan: root["plan_type"] as? String ?? "unknown",
            fiveHour: buildTrack(label: "5h", from: rateLimit["primary_window"]),
            sevenDay: buildTrack(label: "7d", from: rateLimit["secondary_window"]),
            fetchedAt: Date()
        )
    }

    private func buildTrack(label: String, from value: Any?) -> CodexUsageTrack? {
        guard let obj = value as? [String: Any],
              let usedPercent = numeric(obj["used_percent"])
        else { return nil }
        let remaining = max(0, min(1, 1.0 - usedPercent / 100.0))
        let resetsAt = numeric(obj["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return CodexUsageTrack(label: label, remainingFraction: remaining, resetsAt: resetsAt)
    }

    private func numeric(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func prettyJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

private struct CodexAuth {
    let accessToken: String
    let refreshToken: String
    let accountID: String?
}

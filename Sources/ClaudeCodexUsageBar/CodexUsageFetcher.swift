import Foundation

/// Codex CLI の OAuth 認証を使って Codex の 5h / 7d 利用状況を取得する。
///
/// 認証情報は新規保存せず、Codex CLI が管理する `~/.codex/auth.json` を読む。
/// このファイルには OAuth token が含まれるため、ログやダンプには出さない。
final class CodexUsageFetcher {

    private let session: URLSession
    private let authURL: URL
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    private let resetCreditListURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private let resetCreditConsumeURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
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

    func consumeRateLimitResetCredit() async throws {
        let auth = try loadAuth()

        do {
            try await consumeRateLimitResetCredit(accessToken: auth.accessToken, accountID: auth.accountID)
        } catch FetchError.unauthorized {
            let refreshed = try await refreshAccessToken(refreshToken: auth.refreshToken)
            try await consumeRateLimitResetCredit(accessToken: refreshed, accountID: auth.accountID)
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

    private func consumeRateLimitResetCredit(accessToken: String, accountID: String?) async throws {
        let creditID = try await firstAvailableResetCreditID(accessToken: accessToken, accountID: accountID)
        try await postResetCredit(
            accessToken: accessToken,
            accountID: accountID,
            creditID: creditID,
            redeemRequestID: UUID().uuidString
        )
    }

    private func firstAvailableResetCreditID(accessToken: String, accountID: String?) async throws -> String {
        var req = URLRequest(url: resetCreditListURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeCodexUsageBar/1.0", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: req)
        DebugDump.writeCodexReset(data: prettyJSON(data) ?? data)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar.Codex", code: -4))
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw FetchError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = root["credits"] as? [[String: Any]],
              let credit = credits.first(where: { ($0["status"] as? String) == "available" }),
              let id = credit["id"] as? String,
              !id.isEmpty
        else {
            throw FetchError.decodeFailed("Codex reset credit is not available.")
        }
        return id
    }

    private func postResetCredit(accessToken: String, accountID: String?, creditID: String, redeemRequestID: String) async throws {
        var req = URLRequest(url: resetCreditConsumeURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ClaudeCodexUsageBar/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "credit_id": creditID,
            "redeem_request_id": redeemRequestID,
        ])
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: req)
        DebugDump.writeCodexReset(data: prettyJSON(data) ?? data)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar.Codex", code: -3))
        }
        switch http.statusCode {
        case 200..<300:
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let outcome = root["outcome"] as? String,
               outcome != "reset" {
                throw FetchError.decodeFailed("Codex reset was not applied: \(outcome)")
            }
            return
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
        let tracks = [
            buildTrack(from: rateLimit["primary_window"], fallbackLabel: "5h"),
            buildTrack(from: rateLimit["secondary_window"], fallbackLabel: "7d"),
        ].compactMap { $0 }

        return CodexUsageSnapshot(
            plan: root["plan_type"] as? String ?? "unknown",
            fiveHour: tracks.first(where: { $0.label == "5h" }),
            sevenDay: tracks.first(where: { $0.label == "7d" }),
            rateLimitResetCreditsAvailable: resetCreditsAvailable(from: root),
            fetchedAt: Date()
        )
    }

    private func buildTrack(from value: Any?, fallbackLabel: String) -> CodexUsageTrack? {
        guard let obj = value as? [String: Any],
              let usedPercent = numeric(obj["used_percent"])
        else { return nil }
        let label = windowLabel(from: obj) ?? fallbackLabel
        let remaining = max(0, min(1, 1.0 - usedPercent / 100.0))
        let resetsAt = numeric(obj["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        return CodexUsageTrack(label: label, remainingFraction: remaining, resetsAt: resetsAt)
    }

    private func windowLabel(from obj: [String: Any]) -> String? {
        let seconds = numeric(obj["limit_window_seconds"]) ?? numeric(obj["reset_after_seconds"])
        guard let seconds else { return nil }

        switch Int(seconds.rounded()) {
        case 5 * 60 * 60:
            return "5h"
        case 7 * 24 * 60 * 60:
            return "7d"
        default:
            return nil
        }
    }

    private func numeric(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    private func resetCreditsAvailable(from root: [String: Any]) -> Int {
        guard let credits = root["rate_limit_reset_credits"] as? [String: Any],
              let count = numeric(credits["available_count"])
        else { return 0 }
        return max(0, Int(count))
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

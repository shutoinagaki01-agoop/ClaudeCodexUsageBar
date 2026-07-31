import Foundation

/// Codex CLI の OAuth 認証を使って Codex の 5h / 7d 利用状況を取得する。
///
/// 認証情報は Codex CLI が管理する `~/.codex/auth.json` を **読むだけ** で、
/// 保存もリフレッシュもしない。
/// このファイルには OAuth token が含まれるため、ログやダンプには出さない。
///
/// ## 自前リフレッシュをしない理由
///
/// 以前はここで refresh_token を使ってアクセストークンを更新していたが、保存はしていなかった。
/// サーバがリフレッシュトークンをローテーションすると、新しいトークンは誰も記録しないまま
/// 古いトークンが `auth.json` に残り、Codex CLI 側をログアウトさせ得る。
/// 401 を受けたら `auth.json` を読み直し、Codex CLI が更新済みの場合だけ 1 回進む。
final class CodexUsageFetcher {

    private let session: URLSession
    private let authURL: URL
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    private let resetCreditListURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private let resetCreditConsumeURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    /// 401 で拒否されたアクセストークンのダイジェスト。
    /// `auth.json` に有効期限は無いので、拒否済みかどうかがそのまま唯一の判断材料になる。
    private var rejectedAccessTokenDigest: String?

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

    /// - Parameter forceRejectedTokenRetry: 明示的な手動更新から呼ばれた時だけ true。
    ///   拒否済みマークを無視して 1 回だけ強制的に試す。
    ///   `loadAuth()` は毎回ファイルを読むのでキャッシュ破棄は不要。
    ///
    ///   マーク自体は事前にクリアしない。通信エラーや 5xx で終わった場合に
    ///   拒否状態を失い、次の自動更新で同じトークンを再送してしまうため。
    ///   解除は 200 が返った時にだけ行う。
    ///
    ///   自動更新（タイマー、スリープ復帰、起動時、リセット成功後の再取得）では false のまま。
    func fetchUsage(forceRejectedTokenRetry: Bool = false) async throws -> CodexUsageSnapshot {
        let auth = try loadAuth()

        // 前回 401 で拒否されたトークンのままなら API を叩かない。
        if forceRejectedTokenRetry || canAttempt(auth) {
            do {
                return try await requestUsageSnapshot(auth: auth)
            } catch FetchError.unauthorized {
                // 読み直しに進む
            }
        }

        // 読み直して「Codex CLI が別のトークンに更新済み」の時だけ 1 回だけ試す。
        guard let reloaded = reloadedAuthIfUsable(previous: auth) else {
            throw FetchError.codexAuthExpired
        }
        do {
            return try await requestUsageSnapshot(auth: reloaded)
        } catch FetchError.unauthorized {
            throw FetchError.codexAuthExpired
        }
    }

    func consumeRateLimitResetCredit() async throws {
        let auth = try loadAuth()

        if canAttempt(auth) {
            do {
                try await requestConsumeRateLimitResetCredit(auth: auth)
                return
            } catch FetchError.unauthorized {
                // 読み直しに進む
            }
        }

        guard let reloaded = reloadedAuthIfUsable(previous: auth) else {
            throw FetchError.codexAuthExpired
        }
        do {
            try await requestConsumeRateLimitResetCredit(auth: reloaded)
        } catch FetchError.unauthorized {
            throw FetchError.codexAuthExpired
        }
    }

    /// API を叩く価値がある状態か。
    private func canAttempt(_ auth: CodexAuth) -> Bool {
        auth.accessTokenDigest != rejectedAccessTokenDigest
    }

    /// 401 だったトークンを覚える。API 呼び出しは必ずここを通す。
    private func requestUsageSnapshot(auth: CodexAuth) async throws -> CodexUsageSnapshot {
        let data: Data
        do {
            data = try await getUsage(accessToken: auth.accessToken, accountID: auth.accountID)
        } catch FetchError.unauthorized {
            rejectedAccessTokenDigest = auth.accessTokenDigest
            throw FetchError.unauthorized
        }

        // 200 が返った時点でトークンは有効。この後の解析失敗は認証の問題ではない。
        rejectedAccessTokenDigest = nil
        DebugDump.writeCodex(data: prettyJSON(data) ?? data)
        let expiresAt = try? await nextResetCreditExpiration(accessToken: auth.accessToken, accountID: auth.accountID)
        return try decodeUsage(data, nextResetCreditExpiresAt: expiresAt)
    }

    private func requestConsumeRateLimitResetCredit(auth: CodexAuth) async throws {
        do {
            try await consumeRateLimitResetCredit(accessToken: auth.accessToken, accountID: auth.accountID)
            rejectedAccessTokenDigest = nil
        } catch FetchError.unauthorized {
            rejectedAccessTokenDigest = auth.accessTokenDigest
            throw FetchError.unauthorized
        }
    }

    /// `auth.json` を読み直し、前回と違い、かつ拒否済みでないトークンの時だけ返す。
    ///
    /// `loadAuth()` は毎回ファイルを読むのでキャッシュ破棄は不要。
    /// 条件を満たさなければ nil を返し、呼び出し側は API を叩かずに認証切れとして扱う。
    private func reloadedAuthIfUsable(previous: CodexAuth) -> CodexAuth? {
        guard let reloaded = try? loadAuth() else { return nil }
        guard reloaded.accessTokenDigest != previous.accessTokenDigest else { return nil }
        guard canAttempt(reloaded) else { return nil }
        return reloaded
    }

    private func loadAuth() throws -> CodexAuth {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw FetchError.decodeFailed("Codex auth not found. Run `codex login` first.")
        }
        let data = try Data(contentsOf: authURL)
        // refresh_token は読まない。使わないものを持たない。
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw FetchError.decodeFailed("Codex auth.json does not contain an access token.")
        }
        return CodexAuth(
            accessToken: accessToken,
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
        // 403 は権限・プラン起因なので認証拒否として扱わない（default の HTTP エラーへ）。
        case 401:
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
        let credits = try await resetCredits(accessToken: accessToken, accountID: accountID)
        guard let credit = earliestExpiringAvailableCredit(from: credits),
              let id = credit["id"] as? String,
              !id.isEmpty
        else {
            throw FetchError.decodeFailed("Codex reset credit is not available.")
        }
        return id
    }

    private func nextResetCreditExpiration(accessToken: String, accountID: String?) async throws -> Date? {
        let credits = try await resetCredits(accessToken: accessToken, accountID: accountID)
        guard let credit = earliestExpiringAvailableCredit(from: credits) else { return nil }
        return dateValue(credit["expires_at"])
    }

    private func resetCredits(accessToken: String, accountID: String?) async throws -> [[String: Any]] {
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
        // 403 は権限・プラン起因なので認証拒否として扱わない（default の HTTP エラーへ）。
        case 401:
            throw FetchError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = root["credits"] as? [[String: Any]]
        else {
            throw FetchError.decodeFailed("Codex reset credits response is not valid.")
        }
        return credits
    }

    private func earliestExpiringAvailableCredit(from credits: [[String: Any]]) -> [String: Any]? {
        credits
            .filter { ($0["status"] as? String) == "available" }
            .min { lhs, rhs in
                switch (dateValue(lhs["expires_at"]), dateValue(rhs["expires_at"])) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return false
                }
            }
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
        // 403 は権限・プラン起因なので認証拒否として扱わない（default の HTTP エラーへ）。
        case 401:
            throw FetchError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.http(http.statusCode, body)
        }
    }

    private func decodeUsage(_ data: Data, nextResetCreditExpiresAt: Date?) throws -> CodexUsageSnapshot {
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
            nextResetCreditExpiresAt: nextResetCreditExpiresAt,
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

    private func dateValue(_ v: Any?) -> Date? {
        if let n = numeric(v) {
            return n > 10_000_000_000
                ? Date(timeIntervalSince1970: n / 1000)
                : Date(timeIntervalSince1970: n)
        }
        guard let s = v as? String else { return nil }
        if let d = ISO8601DateFormatter.withFractionalSeconds.date(from: s) {
            return d
        }
        return ISO8601DateFormatter.plain.date(from: s)
    }

    private func resetCreditsAvailable(from root: [String: Any]) -> Int {
        guard let credits = root["rate_limit_reset_credits"] as? [String: Any],
              let count = numeric(credits["available_count"])
        else { return 0 }
        return max(0, Int(count))
    }

    private func prettyJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// `~/.codex/auth.json` から読み取った認証情報。
/// 読み取り専用に扱うため `refresh_token` は保持しない。
private struct CodexAuth {
    let accessToken: String
    let accountID: String?

    var accessTokenDigest: String {
        TokenDigest.of(accessToken)
    }
}

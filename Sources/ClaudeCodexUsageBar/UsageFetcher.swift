import Foundation
import Security

/// Claude Code / Claude CLI の OAuth 認証情報を使って Claude の利用量を取得するクライアント。
///
/// ブラウザ Cookie の sessionKey は扱わず、OAuth usage endpoint のレスポンスから枠ごとの利用量を抽出する。
/// 実観測では以下のような枠ごとオブジェクトが入る:
///
/// ```json
/// {
///   "seven_day":          { "utilization": 0.27, "resets_at": "..." },
///   "seven_day_sonnet":   { "utilization": 0.18, "resets_at": "..." },
///   "extra_usage":        { ... },
///   "tangelo": "...",  // ← Statsig 実験フラグ。無視する
///   "iguana_necktie": "...",
///   ...
/// }
/// ```
///
/// 上記の "枠オブジェクト" を発見的に抽出し、UsageTrack の配列に変換する。
///
/// 仕様変更が起きた時のために、レスポンスは生 JSON のままダンプして
/// `~/Library/Application Support/ClaudeCodexUsageBar/last_response.json` に保存する。
final class UsageFetcher {

    private let session: URLSession
    private let claudeOAuthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let claudeOAuthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let claudeOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let claudeCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let record = loadClaudeOAuthCredentials() else {
            throw FetchError.missingClaudeOAuthCredentials
        }
        var credentials = record.credentials

        do {
            if credentials.isExpired {
                credentials = try await refreshClaudeOAuthCredentials(credentials)
                saveClaudeOAuthCredentials(credentials, to: record)
            }
            return try await fetchOAuthUsage(credentials: credentials)
        } catch FetchError.unauthorized {
            credentials = try await refreshClaudeOAuthCredentials(credentials)
            saveClaudeOAuthCredentials(credentials, to: record)
            return try await fetchOAuthUsage(credentials: credentials)
        }
    }

    // MARK: - Claude OAuth

    private func loadClaudeOAuthCredentials() -> ClaudeOAuthCredentialRecord? {
        if let data = try? Data(contentsOf: claudeCredentialsURL),
           let credentials = parseClaudeOAuthCredentials(from: data) {
            return ClaudeOAuthCredentialRecord(
                credentials: credentials,
                source: .file(claudeCredentialsURL),
                rawData: data,
                modifiedAt: fileModificationDate(claudeCredentialsURL)
            )
        }

        return deduplicatedClaudeOAuthKeychainCandidates()
            .flatMap { loadGenericPasswordRecords(service: $0.service, account: $0.account) }
            .compactMap { item -> ClaudeOAuthCredentialRecord? in
                guard let credentials = parseClaudeOAuthCredentials(from: item.data) else { return nil }
                return ClaudeOAuthCredentialRecord(
                    credentials: credentials,
                    source: .keychain(service: item.service, account: item.account),
                    rawData: item.data,
                    modifiedAt: item.modifiedAt
                )
            }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            .first
    }

    private var claudeOAuthKeychainCandidates: [(service: String?, account: String?)] {
        [
            ("Claude Code", "Claude Code-credentials"),
            ("Claude Code-credentials", "Claude Code-credentials"),
        ]
    }

    private func deduplicatedClaudeOAuthKeychainCandidates() -> [(service: String?, account: String?)] {
        var seen = Set<String>()
        return (claudeOAuthKeychainCandidates + discoverClaudeCodeCredentialKeychainCandidates()).filter { candidate in
            let key = "\(candidate.service ?? "")\u{1f}\(candidate.account ?? "")"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func discoverClaudeCodeCredentialKeychainCandidates() -> [(service: String?, account: String?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }

        let items = result as? [[String: Any]] ?? []
        return items.compactMap { item -> (service: String?, account: String?)? in
            let service = item[kSecAttrService as String] as? String
            let account = item[kSecAttrAccount as String] as? String
            let label = item[kSecAttrLabel as String] as? String
            guard service == "Claude Code-credentials" || label == "Claude Code-credentials" else {
                return nil
            }
            return (service: service, account: account)
        }
    }

    private func parseClaudeOAuthCredentials(from data: Data) -> ClaudeOAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else { return nil }
        let expiresAt = numeric(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: oauth["rateLimitTier"] as? String,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private func saveClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials, to record: ClaudeOAuthCredentialRecord) {
        guard let data = updatedClaudeOAuthCredentialData(credentials, basedOn: record.rawData) else { return }

        switch record.source {
        case .file(let url):
            try? data.write(to: url, options: .atomic)
        case .keychain(let service, let account):
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
            ]
            if let service {
                query[kSecAttrService as String] = service
            }
            if let account {
                query[kSecAttrAccount as String] = account
            }
            let attributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    private func updatedClaudeOAuthCredentialData(_ credentials: ClaudeOAuthCredentials, basedOn data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            return nil
        }

        oauth["accessToken"] = credentials.accessToken
        oauth["refreshToken"] = credentials.refreshToken
        oauth["expiresAt"] = credentials.expiresAt.map { Int($0.timeIntervalSince1970 * 1000) }
        oauth["scopes"] = credentials.scopes
        if let rateLimitTier = credentials.rateLimitTier {
            oauth["rateLimitTier"] = rateLimitTier
        }
        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        root["claudeAiOauth"] = oauth

        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func fetchOAuthUsage(credentials: ClaudeOAuthCredentials) async throws -> UsageSnapshot {
        let data = try await getOAuthUsage(accessToken: credentials.accessToken)
        DebugDump.write(data: data, url: claudeOAuthUsageURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decodeFailed("Claude OAuth usage: not a JSON object")
        }
        let tracks = extractTracks(from: json)
        guard !tracks.isEmpty else {
            throw FetchError.decodeFailed("Claude OAuth usage: usage tracks not found. top-level keys=\(Array(json.keys).sorted())")
        }
        return UsageSnapshot(
            plan: credentials.subscriptionType ?? credentials.rateLimitTier ?? extractPlan(from: json),
            tracks: tracks,
            fetchedAt: Date()
        )
    }

    private func getOAuthUsage(accessToken: String) async throws -> Data {
        var req = URLRequest(url: claudeOAuthUsageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar.ClaudeOAuth", code: -1))
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
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError.network(error)
        }
    }

    private func refreshClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw FetchError.unauthorized
        }

        var req = URLRequest(url: claudeOAuthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeOAuthClientID,
        ])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar.ClaudeOAuth", code: -2))
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw FetchError.unauthorized
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                throw FetchError.http(http.statusCode, body)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  !accessToken.isEmpty
            else {
                throw FetchError.decodeFailed("Claude OAuth refresh response did not include access_token.")
            }

            let expiresAt: Date?
            if let expiresIn = numeric(json["expires_in"]) {
                expiresAt = Date().addingTimeInterval(expiresIn)
            } else {
                expiresAt = credentials.expiresAt
            }
            let scopeString = json["scope"] as? String
            return ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: (json["refresh_token"] as? String) ?? refreshToken,
                expiresAt: expiresAt,
                scopes: scopeString?.split(separator: " ").map(String.init) ?? credentials.scopes,
                rateLimitTier: credentials.rateLimitTier,
                subscriptionType: credentials.subscriptionType
            )
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError.network(error)
        }
    }

    private func loadGenericPasswordRecords(service: String?, account: String?) -> [GenericPasswordRecord] {
        guard service != nil || account != nil else { return [] }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        if let account {
            query[kSecAttrAccount as String] = account
        }
        let expectsSingleItem = service != nil && account != nil
        query[kSecMatchLimit as String] = expectsSingleItem ? kSecMatchLimitOne : kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }

        let items: [[String: Any]]
        if let item = result as? [String: Any] {
            items = [item]
        } else {
            items = result as? [[String: Any]] ?? []
        }
        return items.compactMap { item in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return GenericPasswordRecord(
                data: data,
                service: item[kSecAttrService as String] as? String,
                account: item[kSecAttrAccount as String] as? String,
                modifiedAt: item[kSecAttrModificationDate as String] as? Date
            )
        }
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: - 解析: 枠オブジェクトの発見

    /// レスポンスの top-level を走査し、許可リストに載っている枠だけ UsageTrack として収集する。
    ///
    /// Statsig のコードネーム（`tangelo`, `omelette_promotional`, `iguana_necktie`,
    /// `seven_day_omelette` 等）は意味のあるリミットではなくノイズなので、明示的に
    /// 「これは本物の枠」と判断できるキーだけを採用する。
    func extractTracks(from root: [String: Any]) -> [UsageTrack] {
        var tracks: [UsageTrack] = []

        let knownKeys = [
            "five_hour",
            "five_hour_sonnet",
            "seven_day",
            "seven_day_sonnet",
            "seven_day_opus",
            "seven_day_haiku",
            "extra_usage",
        ]
        for key in knownKeys {
            if let obj = root[key] as? [String: Any],
               let t = buildTrack(label: prettyLabel(key), from: obj) {
                tracks.append(t)
            }
        }
        tracks.append(contentsOf: extractLimitTracks(from: root))

        return tracks
    }

    private func extractLimitTracks(from root: [String: Any]) -> [UsageTrack] {
        guard let limits = root["limits"] as? [[String: Any]] else { return [] }

        return limits.compactMap { limit in
            guard (limit["group"] as? String) == "weekly" else { return nil }
            guard let percent = numeric(limit["percent"]), percent >= 0 else { return nil }
            guard let label = scopedWeeklyLimitLabel(from: limit) else { return nil }

            let remaining = 1.0 - max(0, min(1, percent / 100.0))
            let resetDate = resetDate(from: limit)

            return UsageTrack(label: label, remainingFraction: remaining, resetsAt: resetDate)
        }
    }

    private func scopedWeeklyLimitLabel(from limit: [String: Any]) -> String? {
        guard let scope = limit["scope"] as? [String: Any],
              let model = scope["model"] as? [String: Any],
              let displayName = model["display_name"] as? String,
              !displayName.isEmpty
        else {
            return nil
        }
        return "7d \(displayName)"
    }

    private func buildTrack(label: String, from obj: [String: Any]) -> UsageTrack? {
        // 残量を求める。優先順位:
        //  a) "utilization" を使う（= 0..100 の使用済みパーセントなので 1 - util/100 が残量）
        //     実観測: claude.ai は {"utilization": 90.0} や {"utilization": 1.0} のように
        //     パーセント値で返す。1.0 は 100% ではなく 1% 使用済みとして扱う。
        //  b) "remaining" / "remaining_fraction" がそのまま使える
        //  c) "used" + "total" / "limit" の組み合わせ
        var remaining: Double?

        if let util = numeric(obj["utilization"]), util >= 0 {
            let usedFraction = max(0, min(1, util / 100.0))
            remaining = 1.0 - usedFraction
        }
        if remaining == nil, let r = numeric(obj["remaining_fraction"]), r >= 0, r <= 1 {
            remaining = r
        }
        if remaining == nil,
           let r = numeric(obj["remaining"]) ?? numeric(obj["messages_remaining"]),
           let t = numeric(obj["total"]) ?? numeric(obj["limit"]) ?? numeric(obj["messages_limit"]),
           t > 0 {
            remaining = max(0, min(1, r / t))
        }
        if remaining == nil,
           let used = numeric(obj["used"]) ?? numeric(obj["messages_used"]),
           let t = numeric(obj["total"]) ?? numeric(obj["limit"]) ?? numeric(obj["messages_limit"]),
           t > 0 {
            remaining = max(0, min(1, 1.0 - used / t))
        }

        guard let frac = remaining else { return nil }

        // リセット時刻
        let resetDate = resetDate(from: obj)

        // is_enabled が明示的に false の枠は無効扱い（例: extra_usage がオフ状態）。
        // 注意: utilization=0 / resets_at=null でも「まだ使われていない正規の枠」なので消さない。
        //       許可リスト経由の名前だけ通すので、Statsig コードネームは別途防げている。
        if let enabled = obj["is_enabled"] as? Bool, enabled == false { return nil }

        return UsageTrack(label: label, remainingFraction: frac, resetsAt: resetDate)
    }

    private func resetDate(from obj: [String: Any]) -> Date? {
        for key in ["resets_at", "reset_at", "resetsAt", "reset_time", "next_reset"] {
            if let s = obj[key] as? String, let d = parseISODate(s) { return d }
            if let n = numeric(obj[key]) {
                return n > 10_000_000_000
                    ? Date(timeIntervalSince1970: n / 1000)
                    : Date(timeIntervalSince1970: n)
            }
        }
        return nil
    }

    private func numeric(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    private func prettyLabel(_ raw: String) -> String {
        switch raw {
        case "seven_day": return "7d"
        case "seven_day_sonnet": return "7d Sonnet"
        case "seven_day_opus": return "7d Opus"
        case "seven_day_haiku": return "7d Haiku"
        case "five_hour": return "5h"
        case "five_hour_sonnet": return "5h Sonnet"
        case "extra_usage": return "Extra"
        default:
            return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func extractPlan(from root: [String: Any]) -> String? {
        for key in ["plan", "plan_type", "subscription_plan", "account_plan"] {
            if let value = root[key] as? String, !value.isEmpty {
                return value
            }
            if let obj = root[key] as? [String: Any] {
                for nestedKey in ["name", "type", "plan", "plan_type"] {
                    if let value = obj[nestedKey] as? String, !value.isEmpty {
                        return value
                    }
                }
            }
        }
        if let subscription = root["subscription"] as? [String: Any] {
            for key in ["plan", "plan_type", "name", "type"] {
                if let value = subscription[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        if let account = root["account"] as? [String: Any] {
            for key in ["plan", "plan_type", "subscription_plan"] {
                if let value = account[key] as? String, !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func parseISODate(_ s: String) -> Date? {
        // claude.ai はマイクロ秒精度 (".379497+00:00") で返してくる。
        // ISO8601DateFormatter はミリ秒 (3桁) までしか受け付けないため、
        // 末尾の小数を 3 桁に切り詰めてから渡す。
        let normalized = s.replacingOccurrences(
            of: #"\.(\d{3})\d+"#,
            with: ".$1",
            options: .regularExpression
        )
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: normalized) { return d }
        // 小数を一切なしにして再挑戦
        let noFrac = normalized.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: noFrac)
    }

}

private struct ClaudeOAuthCredentialRecord {
    let credentials: ClaudeOAuthCredentials
    let source: ClaudeOAuthCredentialSource
    let rawData: Data
    let modifiedAt: Date?
}

private enum ClaudeOAuthCredentialSource {
    case file(URL)
    case keychain(service: String?, account: String?)
}

private struct GenericPasswordRecord {
    let data: Data
    let service: String?
    let account: String?
    let modifiedAt: Date?
}

/// レスポンスを ~/Library/Application Support/ClaudeCodexUsageBar/ にダンプする。
enum DebugDump {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClaudeCodexUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var lastResponseURL: URL {
        directory.appendingPathComponent("last_response.json")
    }

    static func write(data: Data, url: URL) {
        // url ごとに最新版を残しつつ、汎用の last_response.json も更新する
        let safe = url.path.replacingOccurrences(of: "/", with: "_")
        let perURL = directory.appendingPathComponent("response\(safe).json")
        try? data.write(to: perURL)
        try? data.write(to: lastResponseURL)
    }

    static func writeCodex(data: Data) {
        let url = codexResponseURL
        try? data.write(to: url)
    }

    static func writeCodexReset(data: Data) {
        let url = codexResetResponseURL
        try? data.write(to: url)
    }

    static var codexResponseURL: URL {
        directory.appendingPathComponent("codex_usage_response.json")
    }

    static var codexResetResponseURL: URL {
        directory.appendingPathComponent("codex_reset_response.json")
    }
}

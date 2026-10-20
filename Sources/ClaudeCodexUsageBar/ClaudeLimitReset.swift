import Foundation

/// 公式 CLI 2.1.292 で確認した OAuth のリセット手順。
/// POST の自動再試行はしない。不明な結果を再確認する場合も同じ request_id を使う。
final class ClaudeLimitReset {
    private let session: URLSession
    private let defaults: UserDefaults
    private let credentials: () -> ClaudeOAuthCredentials?

    init(
        session: URLSession? = nil,
        defaults: UserDefaults = .standard,
        credentials: @escaping () -> ClaudeOAuthCredentials? = { ClaudeOAuthCredentialReader.load() }
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
        self.defaults = defaults
        self.credentials = credentials
    }

    func consume(grant: ClaudeResetGrant, credentialDigest: String) async throws {
        guard let auth = credentials(), !auth.isExpired else { throw FetchError.claudeAuthExpired }
        guard auth.accessTokenDigest == credentialDigest else {
            throw ResetError.message("認証情報が変わりました。残量を手動更新してから、もう一度確認してください。")
        }
        // 保存された organizationUuid はログイン切替で古くなるため、同じトークンで確認する。
        let profile = try await request(path: "/api/oauth/profile", auth: auth)
        guard let organization = profile["organization"] as? [String: Any],
              let organizationID = organization["uuid"] as? String,
              UUID(uuidString: organizationID) != nil else {
            throw ResetError.message("Claude のアカウントを確認できません。残量を手動更新してください。")
        }
        let pendingKey = "claudeLimitReset.pending.\(organizationID).\(grant.id)"
        let pendingRequestID = defaults.string(forKey: pendingKey)
        let root = try await request(path: "/api/oauth/usage?cedar_ember=1&skip_spend=1", auth: auth)
        guard let status = ClaudeResetStatus.decode(from: root) else {
            throw ResetError.message("リセット権を確認できません。Claude の使用量設定で確認してください。")
        }
        // 不明な POST の再確認に限り、消費済みの権利にも同じ ID を送って結果を確認する。
        if pendingRequestID == nil {
            guard status.usableGrant() == grant else {
                throw ResetError.message("リセット権の状態が変わったか、現在は利用できません。残量を手動更新してください。")
            }
        }
        try Task.checkCancellation()
        let requestID = pendingRequestID ?? UUID().uuidString
        defaults.set(requestID, forKey: pendingKey)
        let response: [String: Any]
        do {
            response = try await request(
                path: "/api/organizations/\(organizationID)/reset_rate_limits",
                auth: auth,
                body: ["program": "cedar_ember", "grant_id": grant.id, "request_id": requestID]
            )
        } catch {
            throw ResetError.message("リセット結果を確認できませんでした。残量を手動更新するか、Claude の使用量設定で確認してください。再実行時は同じリクエストIDで確認します。\n\(error.localizedDescription)")
        }
        switch response["result"] as? String {
        case "reset", "already_used":
            defaults.removeObject(forKey: pendingKey)
        case "not_limited":
            defaults.removeObject(forKey: pendingKey)
            throw ResetError.message("対象の使用量はすでに回復しているため、リセットされませんでした。")
        case "ineligible":
            defaults.removeObject(forKey: pendingKey)
            throw ResetError.message("このリセット権は現在利用できません。Claude の使用量設定で確認してください。")
        default:
            // cooldown / unavailable / 未知の応答は、処理中・結果不明の可能性を残す。
            throw ResetError.message("リセットの完了を確認できません。少し待って残量を手動更新してください。再実行時は同じリクエストIDで確認します。")
        }
    }

    private func request(path: String, auth: ClaudeOAuthCredentials, body: [String: String]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        for (field, value) in ClaudeCLIHeaders.values { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResetError.message("Claude からの応答を確認できません。") }
        if http.statusCode == 401 { throw FetchError.claudeAuthExpired }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResetError.message("Claude のリセット応答を解析できません。")
        }
        return root
    }

    private enum ResetError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): return message }
        }
    }
}

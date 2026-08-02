import Foundation

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
/// 認証情報はダンプ対象に含めない。
///
/// ## 認証情報は読み取り専用に扱う
///
/// このクライアントは Claude Code の認証情報を **読むだけ** で、リフレッシュも保存もしない。
/// 自前でリフレッシュすると、サーバがリフレッシュトークンをローテーションした場合に
/// Claude Code 側に古いトークンが残り、Claude Code をログアウトさせ得る。
/// トークンの更新は Claude Code 本体に任せ、こちらは期限切れを検出したら
/// キャッシュを捨てて読み直すだけにする。
final class UsageFetcher {

    private let session: URLSession
    private let claudeOAuthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// プラン名の取得先。usage レスポンスにプラン名は含まれないため、
    /// 認証情報から取れない長期トークン経路でだけ使う。
    private let claudeOAuthProfileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private let claudeCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    private var cachedClaudeOAuthCredentials: ClaudeOAuthCredentials?

    /// このアプリ自身が持つ長期トークンの置き場所。
    ///
    /// `claude setup-token` が発行する 1 年トークン（`sk-ant-oat...`）を、
    /// ユーザが `security add-generic-password` で自分で格納する。
    /// アプリは読むだけで、書き込みも発行も行わない。
    ///
    /// service は既存のアプリ用項目と共用し、account だけ分ける。
    /// 同 service には sessionKey 時代の `claude.ai.sessionKey` が残っているが、
    /// account が違うので干渉しない。
    private let longLivedTokenService = "com.example.ClaudeCodexUsageBar"
    private let longLivedTokenAccount = "claude.oauth.longLivedToken"
    /// 読み込み済みかどうか。「読んだが未設定」と「未読」を区別するために別に持つ。
    private var longLivedTokenLoaded = false
    private var cachedLongLivedToken: String?
    /// 拒否された長期トークンと、その理由。
    ///
    /// Claude Code の認証情報と同じく、拒否済みのまま投げ続けないための門番。
    /// 理由も持つのは、API を叩かずに同じ説明を UI へ返せるようにするため。
    private var rejectedLongLivedToken: (digest: String, reason: String)?
    /// profile から引いたプラン名。トークンが入れ替わるまで使い回す。
    /// 「解決済みだが取得できなかった」と「未解決」を区別するためにフラグを別に持つ。
    private var longLivedPlanResolved = false
    private var cachedLongLivedPlan: String?
    /// 401 で拒否されたアクセストークンのダイジェスト。
    ///
    /// 拒否されたトークンは認証情報が入れ替わるまで何度投げても 401 なので、
    /// これを覚えておいて API 呼び出し自体を打ち切る。成功したら破棄する。
    /// `expiresAt` が未来（あるいは無い）のまま失効するケースがあるため、
    /// `isExpired` だけでは足りない。
    private var rejectedAccessTokenDigest: String?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// - Parameter forceRejectedTokenRetry: 明示的な手動更新から呼ばれた時だけ true。
    ///   キャッシュを破棄して最新の認証情報を読み直した上で、拒否済みマークと
    ///   期限切れ判定の両方を無視して 1 回だけ強制的に試す。
    ///
    ///   拒否済みマークは事前にクリアしない。ゲートの通過は下の
    ///   `forceRejectedTokenRetry ||` が担っており、事前にクリアすると
    ///   通信エラーや 5xx で終わった場合（`.unauthorized` 以外は外へ抜ける）に
    ///   拒否状態を失い、次の自動更新で同じトークンを再送してしまう。
    ///   解除は 200 が返った時にだけ行う。
    ///
    ///   自動更新（タイマー、スリープ復帰、起動時）では常に false のままにする。
    ///   Claude Code が動いていなければトークンは更新されないので、停止状態から
    ///   抜ける手段としてこの強制経路が必要になる。
    ///   再度 401 なら `requestUsage` が拒否済みマークを付け直すので、
    ///   連続通信にはならない。
    func fetchUsage(forceRejectedTokenRetry: Bool = false) async throws -> UsageSnapshot {
        if forceRejectedTokenRetry {
            cachedClaudeOAuthCredentials = nil
            longLivedTokenLoaded = false
            cachedLongLivedToken = nil
        }

        // 長期トークンがあれば最優先で使い、Claude Code の認証情報は一切見ない。
        // こちらは 1 年有効なので、8 時間ごとの失効も、Claude Code が
        // Keychain を更新してくれるかどうかへの依存も無くなる。
        if let token = loadLongLivedToken() {
            return try await fetchUsingLongLivedToken(token, force: forceRejectedTokenRetry)
        }

        guard let credentials = loadClaudeOAuthCredentials() else {
            throw FetchError.missingClaudeOAuthCredentials
        }

        // 期限切れ、または前回 401 で拒否されたトークンのままなら API を叩かない。
        // その状態で投げても 401 が返るだけなので、認証情報が入れ替わるのを待つ。
        if forceRejectedTokenRetry || canAttempt(credentials) {
            do {
                return try await requestUsage(credentials: credentials)
            } catch FetchError.unauthorized {
                // 読み直しに進む
            }
        }

        // 読み直して「別のトークンかつ使える」時だけ 1 回だけ試す。
        guard let reloaded = reloadedCredentialsIfUsable(previous: credentials) else {
            throw FetchError.claudeAuthExpired
        }
        do {
            return try await requestUsage(credentials: reloaded)
        } catch FetchError.unauthorized {
            // 更新後のトークンでも 401 なら、アプリ側から復帰させる手段は無い。
            // .unauthorized を外に出すと共通のエラー文で表示されてしまうため変換する。
            throw FetchError.claudeAuthExpired
        }
    }

    // MARK: - 長期トークン（読み取り専用）

    private func loadLongLivedToken() -> String? {
        if longLivedTokenLoaded {
            return cachedLongLivedToken
        }
        longLivedTokenLoaded = true

        guard let data = SecurityCLI.genericPassword(
            service: longLivedTokenService,
            account: longLivedTokenAccount
        ) else {
            cachedLongLivedToken = nil
            return nil
        }

        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cachedLongLivedToken = token.isEmpty ? nil : token
        return cachedLongLivedToken
    }

    /// 長期トークンでの取得。
    ///
    /// 失効判定は無い。1 年トークンなので期限切れを気にする必要が無い。
    /// 401 と「スコープ不足の 403」だけは、原因が特定できるので専用のエラーに変換する。
    ///
    /// - Parameter force: 手動更新から来た時だけ true。拒否済みマークを無視して 1 回試す。
    private func fetchUsingLongLivedToken(_ token: String, force: Bool) async throws -> UsageSnapshot {
        let digest = TokenDigest.of(token)

        // 拒否されたトークンは、ユーザが入れ替えるまで何度投げても同じ結果になる。
        // Claude Code の認証情報と違って勝手に更新されることが無いぶん、
        // ここで打ち切らないと 10 分ごとに無意味な 401 を投げ続ける。
        //
        // 打ち切る時もキャッシュは毎回捨てる。捨てないとキーチェーンを読み直さず、
        // ユーザがトークンを入れ替えても気付けないまま止まり続ける。
        if !force, let rejected = rejectedLongLivedToken, rejected.digest == digest {
            invalidateLongLivedTokenCache()
            throw FetchError.longLivedTokenInvalid(rejected.reason)
        }

        do {
            let data = try await getOAuthUsage(accessToken: token)
            // 200 が返った時点でトークンは有効。解除はここでだけ行う。
            rejectedLongLivedToken = nil
            DebugDump.write(data: data, url: claudeOAuthUsageURL)
            let plan = await longLivedPlan(accessToken: token)
            return try makeSnapshot(from: data, planHint: plan, source: .longLivedToken)
        } catch FetchError.unauthorized {
            throw rejectLongLivedToken(digest: digest, reason: "HTTP 401")
        } catch FetchError.http(403, let body) {
            // 実観測では、権限が足りない時に不足しているスコープ名が本文に入る。
            // `user:profile` は usage エンドポイントが要求するもの。
            let scope = ["user:profile", "user:inference"].first { body.contains($0) }
            let detail = scope.map { "スコープ \($0) が不足しています" } ?? "HTTP 403"
            throw rejectLongLivedToken(digest: digest, reason: detail)
        }
    }

    private func rejectLongLivedToken(digest: String, reason: String) -> FetchError {
        rejectedLongLivedToken = (digest: digest, reason: reason)
        invalidateLongLivedTokenCache()
        return FetchError.longLivedTokenInvalid(reason)
    }

    /// 長期トークン経路のプラン名。
    ///
    /// usage レスポンスにプラン名は無く、長期トークンには認証情報も付随しないので、
    /// profile エンドポイントから 1 回だけ取ってプロセス内に保持する。
    /// プラン名は頻繁に変わらないため、取得のたびに問い合わせる必要は無い。
    ///
    /// 失敗しても利用量の表示は妨げない。恒久的な拒否（401 / 403）なら以後諦め、
    /// 通信エラーなら次の取得でもう一度試す。
    private func longLivedPlan(accessToken: String) async -> String? {
        if longLivedPlanResolved {
            return cachedLongLivedPlan
        }

        do {
            let data = try await getOAuth(claudeOAuthProfileURL, accessToken: accessToken)
            longLivedPlanResolved = true
            cachedLongLivedPlan = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0 }
                .flatMap(extractProfilePlan)
        } catch FetchError.unauthorized {
            longLivedPlanResolved = true
        } catch FetchError.http(403, _) {
            longLivedPlanResolved = true
        } catch {
            // 通信エラーなどの一時的な失敗。解決済みにはせず、次回また試す。
        }
        return cachedLongLivedPlan
    }

    /// profile レスポンスからプラン名を組み立てる。
    ///
    /// 実観測では次の形をしている。Claude Code 認証経路の `subscriptionType`
    /// （"team"）と揃うよう、`claude_` 接頭辞を落とす。
    /// ```json
    /// { "account":      { "has_claude_max": false, "has_claude_pro": false },
    ///   "organization": { "organization_type": "claude_team",
    ///                     "rate_limit_tier": "default_raven" } }
    /// ```
    private func extractProfilePlan(from root: [String: Any]) -> String? {
        let organization = root["organization"] as? [String: Any]

        if let type = organization?["organization_type"] as? String, !type.isEmpty {
            return type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        }
        // 個人プランには organization_type が無いことがあるので、アカウント側から拾う。
        if let account = root["account"] as? [String: Any] {
            if account["has_claude_max"] as? Bool == true { return "max" }
            if account["has_claude_pro"] as? Bool == true { return "pro" }
        }
        if let tier = organization?["rate_limit_tier"] as? String, !tier.isEmpty {
            return tier
        }
        return nil
    }

    /// 次回の取得でキーチェーンを読み直させる。
    ///
    /// 拒否状態の間はこれを毎回呼ぶ。ユーザがトークンを入れ替えたら手動更新を待たずに
    /// 復帰できるようにするためで、Claude Code 経路が認証情報の入れ替わりを待つのと
    /// 同じ形にそろえてある。読み直すだけで API は叩かない
    /// （同じトークンなら拒否済みの門番が止める）。
    private func invalidateLongLivedTokenCache() {
        longLivedTokenLoaded = false
        cachedLongLivedToken = nil
        // プラン名はトークン（＝アカウント）に紐づくので一緒に捨てる。
        longLivedPlanResolved = false
        cachedLongLivedPlan = nil
    }

    // MARK: - Claude OAuth（読み取り専用）

    /// API を叩く価値がある状態か。
    private func canAttempt(_ credentials: ClaudeOAuthCredentials) -> Bool {
        !credentials.isExpired && credentials.accessTokenDigest != rejectedAccessTokenDigest
    }

    /// 利用量を取得し、401 だったトークンを覚える。API 呼び出しは必ずここを通す。
    /// 拒否済みマークの解除は「200 が返った時点」で `fetchOAuthUsage` が行う。
    private func requestUsage(credentials: ClaudeOAuthCredentials) async throws -> UsageSnapshot {
        do {
            return try await fetchOAuthUsage(credentials: credentials)
        } catch FetchError.unauthorized {
            rejectedAccessTokenDigest = credentials.accessTokenDigest
            throw FetchError.unauthorized
        }
    }

    /// キャッシュを破棄して認証情報を読み直し、再試行に使えるものだけを返す。
    ///
    /// 「使える」条件は次の 2 つを満たすこと。どちらか欠けたら nil を返し、
    /// 呼び出し側は API を叩かずに認証切れとして扱う。
    ///   1. アクセストークンが前回と異なる（= Claude Code が更新した）
    ///   2. 期限切れでなく、かつ 401 で拒否されたトークンでない
    private func reloadedCredentialsIfUsable(previous: ClaudeOAuthCredentials) -> ClaudeOAuthCredentials? {
        cachedClaudeOAuthCredentials = nil
        guard let reloaded = loadClaudeOAuthCredentials() else { return nil }
        guard reloaded.accessTokenDigest != previous.accessTokenDigest else { return nil }
        guard canAttempt(reloaded) else { return nil }
        return reloaded
    }

    private func loadClaudeOAuthCredentials() -> ClaudeOAuthCredentials? {
        if let cachedClaudeOAuthCredentials {
            return cachedClaudeOAuthCredentials
        }

        let credentials = loadCredentialsFromFile() ?? loadCredentialsFromKeychain()
        cachedClaudeOAuthCredentials = credentials
        return credentials
    }

    private func loadCredentialsFromFile() -> ClaudeOAuthCredentials? {
        guard let data = try? Data(contentsOf: claudeCredentialsURL) else { return nil }
        return parseClaudeOAuthCredentials(from: data)
    }

    /// Claude Code が使う service 名。先に見つかった方を採用する。
    private let claudeKeychainServices = ["Claude Code-credentials", "Claude Code"]

    private func loadCredentialsFromKeychain() -> ClaudeOAuthCredentials? {
        for service in claudeKeychainServices {
            // account は環境によって異なる（ユーザ名が入る）ので属性から拾う。
            // 拾えなければ service だけで引く。
            let account = SecurityCLI.genericPasswordAccount(service: service)
            guard let data = SecurityCLI.genericPassword(service: service, account: account),
                  let credentials = parseClaudeOAuthCredentials(from: data)
            else {
                continue
            }
            return credentials
        }
        return nil
    }

    private func parseClaudeOAuthCredentials(from data: Data) -> ClaudeOAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else { return nil }
        let expiresAt = numeric(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: oauth["rateLimitTier"] as? String,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private func fetchOAuthUsage(credentials: ClaudeOAuthCredentials) async throws -> UsageSnapshot {
        let data = try await getOAuthUsage(accessToken: credentials.accessToken)
        // 200 が返った時点でトークンは有効。この後の解析失敗は認証の問題ではないので、
        // 拒否済みマークはここで外す。
        rejectedAccessTokenDigest = nil
        DebugDump.write(data: data, url: claudeOAuthUsageURL)
        return try makeSnapshot(
            from: data,
            planHint: credentials.subscriptionType ?? credentials.rateLimitTier,
            source: .claudeCode
        )
    }

    /// レスポンスを UsageSnapshot に変換する。認証情報の出どころに依存しない部分。
    ///
    /// - Parameter planHint: 認証情報から分かるプラン名。長期トークンには
    ///   付随情報が無いので nil になり、その場合はレスポンス本体から拾う。
    private func makeSnapshot(from data: Data, planHint: String?, source: CredentialSource) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decodeFailed("Claude OAuth usage: not a JSON object")
        }
        let tracks = extractTracks(from: json)
        guard !tracks.isEmpty else {
            throw FetchError.decodeFailed("Claude OAuth usage: usage tracks not found. top-level keys=\(Array(json.keys).sorted())")
        }
        return UsageSnapshot(
            plan: planHint ?? extractPlan(from: json),
            tracks: tracks,
            fetchedAt: Date(),
            source: source
        )
    }

    private func getOAuthUsage(accessToken: String) async throws -> Data {
        try await getOAuth(claudeOAuthUsageURL, accessToken: accessToken)
    }

    private func getOAuth(_ url: URL, accessToken: String) async throws -> Data {
        var req = URLRequest(url: url)
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
            // 403 は権限・エンタイトルメント起因なので認証拒否として扱わない。
            // 拒否済みマークを付けても再読込では復帰しないため、default の HTTP エラーに落とす。
            case 401:
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

/// キーチェーンへの読み取り専用アクセス。
///
/// Security framework（`SecItemCopyMatching` / `SecItemUpdate`）を直接呼ばず、
/// `/usr/bin/security` を子プロセスとして実行する。理由は 2 つある。
///
/// 1. 要求元プロセスが Apple 署名の `security` になるため、キーチェーン項目の
///    ACL / パーティションリストに登録されるのは `apple-tool:` だけになる。
///    このアプリは ad-hoc 署名なので、直接アクセスするとビルドごとに cdhash が変わり、
///    そのたびに ACL が増え、パーティションリストが自分の cdhash に狭められて
///    Claude Code 本体（同じく `security` 経由で読む）が弾かれてしまう。
/// 2. 書き込み API を一切呼ばないことがコード上で保証される。
///
/// `security` はシェルを介さず `executableURL` + 引数配列で直接起動する。
/// 秘密値は引数ではなく stdout で受け取り、ログにもダンプにも出さない。
enum SecurityCLI {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/security")

    /// 汎用パスワード項目の中身を取り出す。復号を伴うため、初回は認可が必要になる。
    static func genericPassword(service: String, account: String?) -> Data? {
        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")

        guard let output = run(arguments) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Data(trimmed.utf8)
    }

    /// 項目の `acct` 属性だけを読む。復号を伴わないので認可ダイアログは出ない。
    ///
    /// Claude Code は account にログインユーザ名を入れるため、環境ごとに値が違う。
    /// 決め打ちにせずここで拾う。
    static func genericPasswordAccount(service: String) -> String? {
        guard let output = run(["find-generic-password", "-s", service]) else { return nil }

        // 出力例: `    "acct"<blob>="shuto.inagaki01"`
        let marker = "\"acct\"<blob>=\""
        for line in output.split(separator: "\n") {
            guard let start = line.range(of: marker) else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.lastIndex(of: "\"") else { continue }
            let account = String(rest[..<end])
            return account.isEmpty ? nil : account
        }
        return nil
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // waitUntilExit の前に読み切る（パイプが埋まると deadlock する）
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
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

import Foundation

/// claude.ai から利用量を取得するクライアント。
///
/// 公式の使用量取得 API は存在しないため、ブラウザの DevTools で観測した非公開エンドポイントを
/// 叩いている。実観測では `/api/bootstrap/{org}/statsig` のレスポンスに以下のような枠ごとオブジェクトが入る:
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

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let sessionKey = KeychainHelper.load(), !sessionKey.isEmpty else {
            throw FetchError.missingSessionKey
        }

        // Step 1: 組織 UUID を取得
        let orgUUID = try await fetchOrgUUID(sessionKey: sessionKey)

        // Step 2: 利用量を取得（複数エンドポイントを順に試す）
        // 最初に bootstrap/statsig を試す。実観測でここに使用量が含まれていた。
        var lastError: Error?
        for url in candidateUsageURLs(orgUUID: orgUUID) {
            do {
                let data = try await get(url: url, sessionKey: sessionKey)
                DebugDump.write(data: data, url: url) // 失敗時に解析できるよう常に保存
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw FetchError.decodeFailed("\(url.lastPathComponent): not a JSON object")
                }
                let tracks = extractTracks(from: json)
                if !tracks.isEmpty {
                    return UsageSnapshot(plan: extractPlan(from: json), tracks: tracks, fetchedAt: Date())
                }
                // tracks 空ならフォールバックに進む
                lastError = FetchError.decodeFailed(
                    "\(url.lastPathComponent): usage tracks not found. top-level keys=\(Array(json.keys).sorted())"
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FetchError.decodeFailed("no candidate endpoint succeeded")
    }

    // MARK: - Step 1

    private func fetchOrgUUID(sessionKey: String) async throws -> String {
        let url = URL(string: "https://claude.ai/api/organizations")!
        let data = try await get(url: url, sessionKey: sessionKey)

        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let uuid = first["uuid"] as? String
        else {
            throw FetchError.organizationNotFound
        }
        return uuid
    }

    // MARK: - Step 2: 候補 URL

    private func candidateUsageURLs(orgUUID: String) -> [URL] {
        [
            "https://claude.ai/api/bootstrap/\(orgUUID)/statsig",
            "https://claude.ai/api/organizations/\(orgUUID)/usage",
            "https://claude.ai/api/account",
        ].compactMap(URL.init(string:))
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

        return tracks
    }

    private func buildTrack(label: String, from obj: [String: Any]) -> UsageTrack? {
        // 残量を求める。優先順位:
        //  a) "utilization" を使う（= 使用済み比率なので 1 - util が残量）
        //     値が 1.0 を超えていれば 0..100 のパーセント値、それ以下なら 0..1 の小数として解釈する。
        //     実観測: claude.ai は {"utilization": 90.0} のようにパーセントで返す。
        //  b) "remaining" / "remaining_fraction" がそのまま使える
        //  c) "used" + "total" / "limit" の組み合わせ
        var remaining: Double?

        if let util = numeric(obj["utilization"]), util >= 0 {
            let usedFraction = util > 1.0 ? util / 100.0 : util
            if usedFraction <= 1.0 {
                remaining = 1.0 - usedFraction
            }
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
        var resetDate: Date?
        for key in ["resets_at", "reset_at", "resetsAt", "reset_time", "next_reset"] {
            if let s = obj[key] as? String, let d = parseISODate(s) { resetDate = d; break }
            if let n = numeric(obj[key]) {
                resetDate = n > 10_000_000_000
                    ? Date(timeIntervalSince1970: n / 1000)
                    : Date(timeIntervalSince1970: n)
                break
            }
        }

        // is_enabled が明示的に false の枠は無効扱い（例: extra_usage がオフ状態）。
        // 注意: utilization=0 / resets_at=null でも「まだ使われていない正規の枠」なので消さない。
        //       許可リスト経由の名前だけ通すので、Statsig コードネームは別途防げている。
        if let enabled = obj["is_enabled"] as? Bool, enabled == false { return nil }

        return UsageTrack(label: label, remainingFraction: frac, resetsAt: resetDate)
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

    // MARK: - 共通 HTTP

    private func get(url: URL, sessionKey: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ClaudeCodexUsageBar/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw FetchError.network(NSError(domain: "ClaudeCodexUsageBar", code: -1))
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

    static var codexResponseURL: URL {
        directory.appendingPathComponent("codex_usage_response.json")
    }
}

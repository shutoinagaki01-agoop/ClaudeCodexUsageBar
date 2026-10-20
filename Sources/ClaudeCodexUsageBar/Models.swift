import CryptoKit
import Foundation

/// アクセストークンの同一性判定に使う短いダイジェスト。
///
/// 「前回と同じトークンなら再送しない」判定のためにトークン本体を保持し続けると
/// 平文のコピーが増えるだけなので、比較はこのダイジェストで行う。
/// ダイジェストはログ・ダンプに出しても安全な値だが、出す必要も無い。
enum TokenDigest {
    static func of(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Claude Code が管理している OAuth 認証情報の読み取り結果。
///
/// このアプリは認証情報を **読むだけ** で、更新も保存も行わない。
/// そのため `refreshToken` は保持しない（持つと事故の余地しか無い）。
/// トークンのリフレッシュは Claude Code 本体の責務である。
struct ClaudeOAuthCredentials: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    let scopes: [String]
    let rateLimitTier: String?
    let subscriptionType: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    var accessTokenDigest: String {
        TokenDigest.of(accessToken)
    }
}

/// 公式 CLI 2.1.292 と同じ接続元ヘッダー。
/// サーバーはこれで接続元を判定し、他の値では cedar_ember が `ineligible_reason: "surface"` になる。
enum ClaudeCLIHeaders {
    static let values = [
        "User-Agent": "claude-cli/2.1.292 (external, cli)",
        "x-app": "cli",
    ]
}

/// 単一の使用量トラック（例: 「7日間 Sonnet 上限」）。
struct UsageTrack: Equatable {
    /// 表示用ラベル（例: "7d Sonnet"）
    let label: String
    /// 残り使用可能量の割合 (0.0 ... 1.0)
    let remainingFraction: Double
    /// 次にリセットされる時刻（ローカルタイム）
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, Int((remainingFraction * 100).rounded())))
    }

    /// リセット時刻を過ぎている = この枠はすでに切り替わっており、
    /// 手元の残量は実際の値ではない。取得が止まっている時にだけ起こる。
    var isResetPassed: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= Date()
    }

    var resetTimeString: String {
        guard let resetsAt = resetsAt else { return "--:--" }
        let f = DateFormatter()
        // 7d枠は日付が重要なので、24時間以内でも M/d HH:mm で表示する。
        // 過去の時刻も必ず日付を付ける。"05:30" だけだと今日の予定に見えてしまう。
        if label.hasPrefix("7d") {
            f.dateFormat = "M/d HH:mm"
        } else if DateInterval.withinNextDay.contains(resetsAt) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: resetsAt)
    }
}

extension DateInterval {
    /// 「今から24時間以内の未来」。時刻だけの短い表記を許してよい範囲。
    static var withinNextDay: DateInterval {
        DateInterval(start: Date(), duration: 24 * 60 * 60)
    }
}

/// 鮮度判定に必要な部分だけを取り出したビュー。
/// Claude / Codex で同じ判定を使うために挟んでいる。
struct TrackStaleness {
    let label: String
    let isResetPassed: Bool
}

extension UsageTrack {
    var staleness: TrackStaleness { TrackStaleness(label: label, isResetPassed: isResetPassed) }
}

extension CodexUsageTrack {
    var staleness: TrackStaleness { TrackStaleness(label: label, isResetPassed: isResetPassed) }
}

/// claude.ai の現在の利用状況スナップショット。複数のトラック（5h / 7d など）を保持し、
/// メニューバーには代表トラック（primary）を表示する。
struct UsageSnapshot: Equatable {
    let plan: String?
    let tracks: [UsageTrack]
    let fetchedAt: Date
    var claudeResetStatus: ClaudeResetStatus? = nil
    /// 確認画面を開いた後にログイン先が変わった場合、古い確認内容で消費しない。
    var credentialDigest: String? = nil

    /// メニューバーに出す主トラック。残量が最も少ないものを採用する（一番効くリミット）。
    var primary: UsageTrack? {
        tracks.min(by: { $0.remainingFraction < $1.remainingFraction })
    }
}

/// Claude Code 2.1.292 の cedar_ember レスポンスに対応する。
/// 不明な状態を「残り0回」や「実行可能」と推測しない。
struct ClaudeResetStatus: Decodable, Equatable {
    let eligible: Bool
    let atLimit: Bool?
    let grants: [ClaudeResetGrant]
    let nextGrantID: String?
    let cooldownUntil: Date?

    enum CodingKeys: String, CodingKey {
        case eligible, grants
        case atLimit = "at_limit"
        case nextGrantID = "next_grant_id", cooldownUntil = "cooldown_until"
    }

    func remainingGrants(at now: Date = Date()) -> [ClaudeResetGrant] {
        grants.filter { $0.resetsLeft > 0 && ($0.endsAt == nil || $0.endsAt! > now) }
            .sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
    }

    /// 接続元の制限などで eligible=false の場合、空の grants は残数ゼロを意味しない。
    func remainingCount(at now: Date = Date()) -> Int? {
        guard eligible else { return nil }
        return remainingGrants(at: now).reduce(0) { $0 + $1.resetsLeft }
    }

    func usableGrant(at now: Date = Date()) -> ClaudeResetGrant? {
        guard eligible, cooldownUntil == nil || cooldownUntil! <= now else { return nil }
        return remainingGrants(at: now).first {
            $0.id == nextGrantID && $0.usableNow && !$0.paused && !$0.clears.isEmpty
                && ($0.useRequiresLimit != true || atLimit == true)
                && ($0.startsAt == nil || $0.startsAt! <= now)
                && $0.id.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
        }
    }

    static func decode(from root: [String: Any]) -> ClaudeResetStatus? {
        guard let block = root["cedar_ember"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: block) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid reset date"))
            }
            return date
        }
        guard let status = try? decoder.decode(Self.self, from: data),
              status.grants.allSatisfy({ $0.resetsLeft >= 0 }),
              Set(status.grants.map(\.id)).count == status.grants.count else { return nil }
        return status
    }
}

struct ClaudeResetGrant: Decodable, Equatable {
    let id: String
    let label: String?
    let resetsLeft: Int
    let startsAt: Date?
    let endsAt: Date?
    let clears: [String]
    let paused: Bool
    let usableNow: Bool
    /// true の権利は上限に達している時だけ使える。
    let useRequiresLimit: Bool?

    enum CodingKeys: String, CodingKey {
        case id, label, clears, paused
        case resetsLeft = "resets_left", startsAt = "starts_at", endsAt = "ends_at"
        case usableNow = "usable_now", useRequiresLimit = "use_requires_limit"
    }

    var limitsLabel: String {
        clears.map {
            switch $0 {
            case "five_hour": return "5h"
            case "seven_day": return "7d"
            case "seven_day_overage_included": return "7d Fable"
            case "seven_day_opus": return "7d Opus"
            case "seven_day_sonnet": return "7d Sonnet"
            case "seven_day_cowork": return "7d Cowork"
            case "seven_day_oauth_apps": return "7d OAuth apps"
            default: return $0
            }
        }.joined(separator: " / ")
    }
}

struct CodexUsageTrack: Equatable {
    let label: String
    let remainingFraction: Double
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, Int((remainingFraction * 100).rounded())))
    }

    var isResetPassed: Bool {
        guard let resetsAt else { return false }
        return resetsAt <= Date()
    }

    var resetTimeString: String {
        guard let resetsAt = resetsAt else { return "--:--" }
        let f = DateFormatter()
        if label.hasPrefix("7d") {
            f.dateFormat = "M/d HH:mm"
        } else if DateInterval.withinNextDay.contains(resetsAt) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: resetsAt)
    }
}

struct CodexResetCredit: Equatable {
    let id: String
    let title: String?
    let expiresAt: Date?
}

struct CodexUsageSnapshot: Equatable {
    let plan: String
    let fiveHour: CodexUsageTrack?
    let sevenDay: CodexUsageTrack?
    let rateLimitResetCreditsAvailable: Int
    /// 利用可能なリセット権。期限が近い順。一覧の取得に失敗した場合は空。
    let resetCredits: [CodexResetCredit]
    let fetchedAt: Date

    var tracks: [CodexUsageTrack] {
        [fiveHour, sevenDay].compactMap { $0 }
    }
}

enum FetchError: LocalizedError {
    case missingClaudeOAuthCredentials
    /// HTTP 401 を表す内部シグナル。認証情報の再読込を促すために使う。
    ///
    /// 403 はここに含めない。権限・プランや通信経路のアクセス制限などでも発生するため、
    /// 拒否済みトークンとして記録すると無関係な取得まで止めてしまう。`.http` として扱う。
    ///
    /// Claude / Codex 共通の型なので、これが UI まで漏れるとサービス名を誤って表示する。
    /// 各 fetcher は再試行後の 401 を `.claudeAuthExpired` / `.codexAuthExpired` に
    /// 変換する責任を持つ。念のためメッセージ自体もサービス非依存にしてある。
    case unauthorized
    /// 再読込しても有効なトークンが得られなかった状態。
    case claudeAuthExpired
    /// 公式 Claude CLI への委譲は試みたが、有効な認証情報へ更新できなかった状態。
    case claudeAuthRefreshFailed(String)
    /// CLI は引き続き実行中。UI だけ待機を終了し、次回取得時に状態を再確認する。
    case claudeAuthRefreshInProgress
    /// refresh token の失効・取り消しなどにより、ユーザ自身の再ログインが必要な状態。
    case claudeLoginRequired
    case codexAuthExpired
    case decodeFailed(String)
    case network(Error)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClaudeOAuthCredentials: return "Claude auth not found. Run `claude auth login` first."
        case .unauthorized: return "Auth rejected (HTTP 401)."
        case .claudeAuthExpired: return "Claude auth expired. Use manual refresh, or run `claude auth login`."
        case .claudeAuthRefreshFailed(let m): return "Claude CLI auth refresh failed: \(m)"
        case .claudeAuthRefreshInProgress:
            return "Claude CLI の認証更新を待っています。次回の取得時に再確認します。"
        case .claudeLoginRequired:
            return "Claude login required. Run `claude auth login` in Terminal."
        case .codexAuthExpired: return "Codex auth expired. Run `codex login` again."
        case .decodeFailed(let m): return "レスポンス解析失敗: \(m)"
        case .network(let e): return "通信エラー: \(e.localizedDescription)"
        case .http(let code, let body):
            // HTML のタグ・CSS や改行を NSMenuItem に渡すとメニューの表示が崩れる。
            // エラーページの文言から、認証切れや特定の拒否元を断定しない。
            if body.range(of: #"<\s*(?:!|/?[a-z])"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return code == 403
                    ? "HTTP 403: アクセスが拒否されました（HTML 応答）。"
                    : "HTTP \(code): サーバーから HTML のエラー応答が返されました。"
            }
            let text = body.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { return "HTTP \(code)" }
            let snippet = String(text.prefix(120)) + (text.count > 120 ? "…" : "")
            return "HTTP \(code): \(snippet)"
        }
    }

    /// 認証切れで、同じトークンのまま Usage API を再送すべきでない状態か。
    /// true の間は更新間隔を長めに落とし、Claude は設定に応じて公式 CLI へ更新を委譲する。
    var isAuthExpired: Bool {
        switch self {
        case .claudeAuthExpired, .claudeAuthRefreshFailed,
             .claudeLoginRequired, .codexAuthExpired,
             .missingClaudeOAuthCredentials, .unauthorized:
            return true
        case .claudeAuthRefreshInProgress, .decodeFailed, .network, .http:
            return false
        }
    }

    /// 何をすれば直るか。認証情報の出どころで手順が変わるので、エラー自身に持たせる。
    ///
    /// まず CLI の起動を案内し、再ログインは次善として置く。アクセストークンの失効は
    /// リフレッシュトークンが生きていれば CLI の起動だけで直り、`login` は
    /// ブラウザでの再サインインを伴うため。
    var recoveryHint: String? {
        switch self {
        case .missingClaudeOAuthCredentials:
            return "復帰方法: ターミナルで `claude auth login` を実行してください。"
        case .claudeAuthExpired, .unauthorized:
            return "復帰方法: 手動更新を実行してください。直らなければ `claude auth login`。"
        case .claudeAuthRefreshFailed:
            return "復帰方法: ターミナルで `claude` を起動してください。直らなければ `claude auth login`。"
        case .claudeLoginRequired:
            return "復帰方法: ターミナルで `claude auth login` を実行してください。"
        case .codexAuthExpired:
            return "復帰方法: ターミナルで `codex` を起動してください。直らなければ `codex login`。"
        case .http(403, _):
            return "対処: 少し待って手動更新。続く場合は公式アプリや VPN・プロキシの設定を確認してください。"
        case .claudeAuthRefreshInProgress, .decodeFailed, .network, .http:
            return nil
        }
    }
}

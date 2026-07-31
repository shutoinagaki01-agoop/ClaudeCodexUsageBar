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
struct ClaudeOAuthCredentials: Equatable {
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

    var resetTimeString: String {
        guard let resetsAt = resetsAt else { return "--:--" }
        let f = DateFormatter()
        // 7d枠は日付が重要なので、24時間以内でも M/d HH:mm で表示する。
        if label.hasPrefix("7d") {
            f.dateFormat = "M/d HH:mm"
        } else if abs(resetsAt.timeIntervalSinceNow) < 24 * 60 * 60 {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: resetsAt)
    }
}

/// claude.ai の現在の利用状況スナップショット。複数のトラック（5h / 7d など）を保持し、
/// メニューバーには代表トラック（primary）を表示する。
struct UsageSnapshot: Equatable {
    let plan: String?
    let tracks: [UsageTrack]
    let fetchedAt: Date

    /// メニューバーに出す主トラック。残量が最も少ないものを採用する（一番効くリミット）。
    var primary: UsageTrack? {
        tracks.min(by: { $0.remainingFraction < $1.remainingFraction })
    }
}

struct CodexUsageTrack: Equatable {
    let label: String
    let remainingFraction: Double
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, Int((remainingFraction * 100).rounded())))
    }

    var resetTimeString: String {
        guard let resetsAt = resetsAt else { return "--:--" }
        let f = DateFormatter()
        if label.hasPrefix("7d") {
            f.dateFormat = "M/d HH:mm"
        } else if abs(resetsAt.timeIntervalSinceNow) < 24 * 60 * 60 {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: resetsAt)
    }
}

struct CodexUsageSnapshot: Equatable {
    let plan: String
    let fiveHour: CodexUsageTrack?
    let sevenDay: CodexUsageTrack?
    let rateLimitResetCreditsAvailable: Int
    let nextResetCreditExpiresAt: Date?
    let fetchedAt: Date

    var tracks: [CodexUsageTrack] {
        [fiveHour, sevenDay].compactMap { $0 }
    }
}

enum FetchError: LocalizedError {
    case missingClaudeOAuthCredentials
    /// HTTP 401 を表す内部シグナル。認証情報の再読込を促すために使う。
    ///
    /// 403 はここに含めない。403 は権限・プラン起因で、トークンを読み直しても復帰せず、
    /// 拒否済みトークンとして記録すると無関係な取得まで止めてしまう。`.http` として扱う。
    ///
    /// Claude / Codex 共通の型なので、これが UI まで漏れるとサービス名を誤って表示する。
    /// 各 fetcher は再試行後の 401 を `.claudeAuthExpired` / `.codexAuthExpired` に
    /// 変換する責任を持つ。念のためメッセージ自体もサービス非依存にしてある。
    case unauthorized
    /// 再読込しても有効なトークンが得られなかった状態。自前リフレッシュはしないので、
    /// 復帰は Claude Code / Codex CLI 側のトークン更新を待つしかない。
    case claudeAuthExpired
    case codexAuthExpired
    case decodeFailed(String)
    case network(Error)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClaudeOAuthCredentials: return "Claude auth not found. Run `claude auth login` first."
        case .unauthorized: return "Auth rejected (HTTP 401)."
        case .claudeAuthExpired: return "Claude auth expired. Start Claude Code, or run `claude auth login`."
        case .codexAuthExpired: return "Codex auth expired. Run `codex login` again."
        case .decodeFailed(let m): return "レスポンス解析失敗: \(m)"
        case .network(let e): return "通信エラー: \(e.localizedDescription)"
        case .http(let code, let body):
            let snippet = body.prefix(120)
            return "HTTP \(code): \(snippet)"
        }
    }

    /// 認証切れで、アプリ側からは復帰させられない状態か。
    /// true の間は API を叩かず、更新間隔も長めに落とす。
    var isAuthExpired: Bool {
        switch self {
        case .claudeAuthExpired, .codexAuthExpired, .missingClaudeOAuthCredentials, .unauthorized:
            return true
        case .decodeFailed, .network, .http:
            return false
        }
    }
}

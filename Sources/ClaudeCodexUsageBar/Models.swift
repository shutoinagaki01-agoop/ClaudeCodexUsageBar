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
    /// 再読込しても有効なトークンが得られなかった状態。
    case claudeAuthExpired
    /// 公式 Claude CLI への委譲は試みたが、有効な認証情報へ更新できなかった状態。
    case claudeAuthRefreshFailed(String)
    /// Claude Desktop の利用とは別に、Claude CLI 自身の初回セットアップが必要な状態。
    case claudeCLISetupRequired
    /// refresh token の失効・取り消しなどにより、ユーザ自身の再ログインが必要な状態。
    case claudeLoginRequired
    /// 安全に自動応答できない対話画面が表示され、ターミナルでの確認が必要な状態。
    case claudeCLIInteractionRequired
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
        case .claudeCLISetupRequired:
            return "Claude CLI setup required. Run `claude` once in Terminal and complete the setup."
        case .claudeLoginRequired:
            return "Claude login required. Run `claude auth login` in Terminal."
        case .claudeCLIInteractionRequired:
            return "Claude CLI needs interactive attention. Run `claude` in Terminal and follow its instructions."
        case .codexAuthExpired: return "Codex auth expired. Run `codex login` again."
        case .decodeFailed(let m): return "レスポンス解析失敗: \(m)"
        case .network(let e): return "通信エラー: \(e.localizedDescription)"
        case .http(let code, let body):
            let snippet = body.prefix(120)
            return "HTTP \(code): \(snippet)"
        }
    }

    /// 認証切れで、同じトークンのまま Usage API を再送すべきでない状態か。
    /// true の間は更新間隔を長めに落とし、Claude は設定に応じて公式 CLI へ更新を委譲する。
    var isAuthExpired: Bool {
        switch self {
        case .claudeAuthExpired, .claudeAuthRefreshFailed, .claudeCLISetupRequired,
             .claudeLoginRequired, .claudeCLIInteractionRequired, .codexAuthExpired,
             .missingClaudeOAuthCredentials, .unauthorized:
            return true
        case .decodeFailed, .network, .http:
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
        case .claudeCLISetupRequired:
            return "復帰方法: ターミナルで `claude` を一度起動し、初回設定を完了してください。"
        case .claudeLoginRequired:
            return "復帰方法: ターミナルで `claude auth login` を実行してください。"
        case .claudeCLIInteractionRequired:
            return "復帰方法: ターミナルで `claude` を起動し、表示された案内を確認してください。"
        case .codexAuthExpired:
            return "復帰方法: ターミナルで `codex` を起動してください。直らなければ `codex login`。"
        case .decodeFailed, .network, .http:
            return nil
        }
    }
}

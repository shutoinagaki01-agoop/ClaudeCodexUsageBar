import Foundation

struct ClaudeOAuthCredentials: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]
    let rateLimitTier: String?
    let subscriptionType: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
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
    case unauthorized
    case decodeFailed(String)
    case network(Error)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClaudeOAuthCredentials: return "Claude auth not found. Run `claude auth login` first."
        case .unauthorized: return "Claude auth expired. Run `claude auth login` again."
        case .decodeFailed(let m): return "レスポンス解析失敗: \(m)"
        case .network(let e): return "通信エラー: \(e.localizedDescription)"
        case .http(let code, let body):
            let snippet = body.prefix(120)
            return "HTTP \(code): \(snippet)"
        }
    }
}

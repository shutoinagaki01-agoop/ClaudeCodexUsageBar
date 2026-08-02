import Foundation

/// 自動更新の時間設定。メニューから変更し、UserDefaults に保存する。
struct AppConfig {
    let peakRefreshInterval: TimeInterval
    let normalRefreshInterval: TimeInterval
    let depletedFallbackRefreshInterval: TimeInterval
    let resetRefreshBuffer: TimeInterval
    let autoRefreshStartHour: Int
    let autoRefreshStartMinute: Int
    let autoRefreshEndHour: Int
    let autoRefreshEndMinute: Int
    let peakRefreshStartHour: Int
    let peakRefreshStartMinute: Int
    let peakRefreshEndHour: Int
    let peakRefreshEndMinute: Int
    let autoRefreshTimeZone: TimeZone
    let menuBarUsesIcons: Bool
    /// 認証切れ時に、定期更新から公式 Claude CLI を PTY 起動してよいか。
    /// 手動更新はこの設定にかかわらずユーザ操作として許可される。
    let allowBackgroundClaudeAuthRefresh: Bool
    let selectedClaudeMenuBarTrackLabel: String?
    let selectedCodexMenuBarTrackLabel: String?

    /// 認証切れを検出している間の自動更新間隔。
    ///
    /// 通常の 3〜5 分間隔は続けない。バックグラウンド CLI 更新が許可されていれば、
    /// このタイミングで公式 Claude CLI に更新を委譲する。
    ///
    /// Claude は許可設定がオフなら認証情報の読み直しだけ、オンなら公式 CLI への委譲も行う。
    /// Codex は `auth.json` の読み直しだけを行う。各 fetcher は拒否済みトークンを覚え、
    /// 同じ認証情報のまま Usage API を繰り返し呼ばない。
    /// その折り合いとして 10 分を採る。手動更新はこの間隔を待たずに実行できる。
    static let authExpiredRefreshInterval: TimeInterval = 10 * 60

    static func load() -> AppConfig {
        let defaults = UserDefaults.standard
        return AppConfig(
            peakRefreshInterval: defaults.timeInterval(forKey: Keys.peakRefreshInterval, default: 3 * 60),
            normalRefreshInterval: defaults.timeInterval(forKey: Keys.normalRefreshInterval, default: 5 * 60),
            depletedFallbackRefreshInterval: 60 * 60,
            resetRefreshBuffer: 60,
            autoRefreshStartHour: defaults.integer(forKey: Keys.autoRefreshStartHour, default: 9),
            autoRefreshStartMinute: defaults.integer(forKey: Keys.autoRefreshStartMinute, default: 30),
            autoRefreshEndHour: defaults.integer(forKey: Keys.autoRefreshEndHour, default: 21),
            autoRefreshEndMinute: defaults.integer(forKey: Keys.autoRefreshEndMinute, default: 0),
            peakRefreshStartHour: defaults.integer(forKey: Keys.peakRefreshStartHour, default: 11),
            peakRefreshStartMinute: defaults.integer(forKey: Keys.peakRefreshStartMinute, default: 0),
            peakRefreshEndHour: defaults.integer(forKey: Keys.peakRefreshEndHour, default: 16),
            peakRefreshEndMinute: defaults.integer(forKey: Keys.peakRefreshEndMinute, default: 0),
            autoRefreshTimeZone: TimeZone(identifier: "Asia/Tokyo")!,
            menuBarUsesIcons: defaults.bool(forKey: Keys.menuBarUsesIcons, default: true),
            allowBackgroundClaudeAuthRefresh: defaults.bool(
                forKey: Keys.allowBackgroundClaudeAuthRefresh,
                default: false
            ),
            selectedClaudeMenuBarTrackLabel: defaults.string(forKey: Keys.selectedClaudeMenuBarTrackLabel),
            selectedCodexMenuBarTrackLabel: defaults.string(forKey: Keys.selectedCodexMenuBarTrackLabel)
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(peakRefreshInterval, forKey: Keys.peakRefreshInterval)
        defaults.set(normalRefreshInterval, forKey: Keys.normalRefreshInterval)
        defaults.set(autoRefreshStartHour, forKey: Keys.autoRefreshStartHour)
        defaults.set(autoRefreshStartMinute, forKey: Keys.autoRefreshStartMinute)
        defaults.set(autoRefreshEndHour, forKey: Keys.autoRefreshEndHour)
        defaults.set(autoRefreshEndMinute, forKey: Keys.autoRefreshEndMinute)
        defaults.set(peakRefreshStartHour, forKey: Keys.peakRefreshStartHour)
        defaults.set(peakRefreshStartMinute, forKey: Keys.peakRefreshStartMinute)
        defaults.set(peakRefreshEndHour, forKey: Keys.peakRefreshEndHour)
        defaults.set(peakRefreshEndMinute, forKey: Keys.peakRefreshEndMinute)
        defaults.set(menuBarUsesIcons, forKey: Keys.menuBarUsesIcons)
        defaults.set(allowBackgroundClaudeAuthRefresh, forKey: Keys.allowBackgroundClaudeAuthRefresh)
        saveOptional(selectedClaudeMenuBarTrackLabel, key: Keys.selectedClaudeMenuBarTrackLabel, defaults: defaults)
        saveOptional(selectedCodexMenuBarTrackLabel, key: Keys.selectedCodexMenuBarTrackLabel, defaults: defaults)
    }

    func withMenuBarUsesIcons(_ enabled: Bool) -> AppConfig {
        AppConfig(
            peakRefreshInterval: peakRefreshInterval,
            normalRefreshInterval: normalRefreshInterval,
            depletedFallbackRefreshInterval: depletedFallbackRefreshInterval,
            resetRefreshBuffer: resetRefreshBuffer,
            autoRefreshStartHour: autoRefreshStartHour,
            autoRefreshStartMinute: autoRefreshStartMinute,
            autoRefreshEndHour: autoRefreshEndHour,
            autoRefreshEndMinute: autoRefreshEndMinute,
            peakRefreshStartHour: peakRefreshStartHour,
            peakRefreshStartMinute: peakRefreshStartMinute,
            peakRefreshEndHour: peakRefreshEndHour,
            peakRefreshEndMinute: peakRefreshEndMinute,
            autoRefreshTimeZone: autoRefreshTimeZone,
            menuBarUsesIcons: enabled,
            allowBackgroundClaudeAuthRefresh: allowBackgroundClaudeAuthRefresh,
            selectedClaudeMenuBarTrackLabel: selectedClaudeMenuBarTrackLabel,
            selectedCodexMenuBarTrackLabel: selectedCodexMenuBarTrackLabel
        )
    }

    func withSelectedClaudeMenuBarTrackLabel(_ label: String?) -> AppConfig {
        AppConfig(
            peakRefreshInterval: peakRefreshInterval,
            normalRefreshInterval: normalRefreshInterval,
            depletedFallbackRefreshInterval: depletedFallbackRefreshInterval,
            resetRefreshBuffer: resetRefreshBuffer,
            autoRefreshStartHour: autoRefreshStartHour,
            autoRefreshStartMinute: autoRefreshStartMinute,
            autoRefreshEndHour: autoRefreshEndHour,
            autoRefreshEndMinute: autoRefreshEndMinute,
            peakRefreshStartHour: peakRefreshStartHour,
            peakRefreshStartMinute: peakRefreshStartMinute,
            peakRefreshEndHour: peakRefreshEndHour,
            peakRefreshEndMinute: peakRefreshEndMinute,
            autoRefreshTimeZone: autoRefreshTimeZone,
            menuBarUsesIcons: menuBarUsesIcons,
            allowBackgroundClaudeAuthRefresh: allowBackgroundClaudeAuthRefresh,
            selectedClaudeMenuBarTrackLabel: label,
            selectedCodexMenuBarTrackLabel: selectedCodexMenuBarTrackLabel
        )
    }

    func withSelectedCodexMenuBarTrackLabel(_ label: String?) -> AppConfig {
        AppConfig(
            peakRefreshInterval: peakRefreshInterval,
            normalRefreshInterval: normalRefreshInterval,
            depletedFallbackRefreshInterval: depletedFallbackRefreshInterval,
            resetRefreshBuffer: resetRefreshBuffer,
            autoRefreshStartHour: autoRefreshStartHour,
            autoRefreshStartMinute: autoRefreshStartMinute,
            autoRefreshEndHour: autoRefreshEndHour,
            autoRefreshEndMinute: autoRefreshEndMinute,
            peakRefreshStartHour: peakRefreshStartHour,
            peakRefreshStartMinute: peakRefreshStartMinute,
            peakRefreshEndHour: peakRefreshEndHour,
            peakRefreshEndMinute: peakRefreshEndMinute,
            autoRefreshTimeZone: autoRefreshTimeZone,
            menuBarUsesIcons: menuBarUsesIcons,
            allowBackgroundClaudeAuthRefresh: allowBackgroundClaudeAuthRefresh,
            selectedClaudeMenuBarTrackLabel: selectedClaudeMenuBarTrackLabel,
            selectedCodexMenuBarTrackLabel: label
        )
    }

    func withAllowBackgroundClaudeAuthRefresh(_ enabled: Bool) -> AppConfig {
        AppConfig(
            peakRefreshInterval: peakRefreshInterval,
            normalRefreshInterval: normalRefreshInterval,
            depletedFallbackRefreshInterval: depletedFallbackRefreshInterval,
            resetRefreshBuffer: resetRefreshBuffer,
            autoRefreshStartHour: autoRefreshStartHour,
            autoRefreshStartMinute: autoRefreshStartMinute,
            autoRefreshEndHour: autoRefreshEndHour,
            autoRefreshEndMinute: autoRefreshEndMinute,
            peakRefreshStartHour: peakRefreshStartHour,
            peakRefreshStartMinute: peakRefreshStartMinute,
            peakRefreshEndHour: peakRefreshEndHour,
            peakRefreshEndMinute: peakRefreshEndMinute,
            autoRefreshTimeZone: autoRefreshTimeZone,
            menuBarUsesIcons: menuBarUsesIcons,
            allowBackgroundClaudeAuthRefresh: enabled,
            selectedClaudeMenuBarTrackLabel: selectedClaudeMenuBarTrackLabel,
            selectedCodexMenuBarTrackLabel: selectedCodexMenuBarTrackLabel
        )
    }

    var autoRefreshWindowLabel: String {
        "\(Self.formatTime(hour: autoRefreshStartHour, minute: autoRefreshStartMinute))-\(Self.formatTime(hour: autoRefreshEndHour, minute: autoRefreshEndMinute))"
    }

    var peakWindowLabel: String {
        "\(Self.formatTime(hour: peakRefreshStartHour, minute: peakRefreshStartMinute))-\(Self.formatTime(hour: peakRefreshEndHour, minute: peakRefreshEndMinute))"
    }

    static func formatTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    static func formatHour(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private enum Keys {
        static let peakRefreshInterval = "settings.peakRefreshInterval"
        static let normalRefreshInterval = "settings.normalRefreshInterval"
        static let autoRefreshStartHour = "settings.autoRefreshStartHour"
        static let autoRefreshStartMinute = "settings.autoRefreshStartMinute"
        static let autoRefreshEndHour = "settings.autoRefreshEndHour"
        static let autoRefreshEndMinute = "settings.autoRefreshEndMinute"
        static let peakRefreshStartHour = "settings.peakRefreshStartHour"
        static let peakRefreshStartMinute = "settings.peakRefreshStartMinute"
        static let peakRefreshEndHour = "settings.peakRefreshEndHour"
        static let peakRefreshEndMinute = "settings.peakRefreshEndMinute"
        static let menuBarUsesIcons = "settings.menuBarUsesIcons"
        static let allowBackgroundClaudeAuthRefresh = "settings.allowBackgroundClaudeAuthRefresh"
        static let selectedClaudeMenuBarTrackLabel = "settings.selectedClaudeMenuBarTrackLabel"
        static let selectedCodexMenuBarTrackLabel = "settings.selectedCodexMenuBarTrackLabel"
    }

    private func saveOptional(_ value: String?, key: String, defaults: UserDefaults) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private extension UserDefaults {
    func integer(forKey key: String, default defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }

    func timeInterval(forKey key: String, default defaultValue: TimeInterval) -> TimeInterval {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}

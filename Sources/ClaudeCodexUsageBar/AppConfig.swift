import Foundation

/// 利用サービス・表示・自動更新の設定。メニューから変更し、UserDefaults に保存する。
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
    var claudeEnabled: Bool
    var codexEnabled: Bool
    var menuBarShowsTrackLabels: Bool
    /// 認証切れ時に、定期更新から公式 Claude CLI を PTY 起動してよいか。
    /// 手動更新はこの設定にかかわらずユーザ操作として許可される。
    let allowBackgroundClaudeAuthRefresh: Bool
    let selectedClaudeMenuBarTrackLabels: [String]
    let selectedCodexMenuBarTrackLabels: [String]

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

    static func load(defaults: UserDefaults = .standard) -> AppConfig {
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
            claudeEnabled: defaults.bool(forKey: Keys.claudeEnabled, default: true),
            codexEnabled: defaults.bool(forKey: Keys.codexEnabled, default: true),
            menuBarShowsTrackLabels: defaults.bool(forKey: Keys.menuBarShowsTrackLabels, default: false),
            allowBackgroundClaudeAuthRefresh: defaults.bool(
                forKey: Keys.allowBackgroundClaudeAuthRefresh,
                default: true
            ),
            selectedClaudeMenuBarTrackLabels: Self.loadTrackLabels(defaults: defaults, key: Keys.selectedClaudeMenuBarTrackLabels, legacyKey: "settings.selectedClaudeMenuBarTrackLabel", defaultLabels: ["5h", "7d"]),
            selectedCodexMenuBarTrackLabels: Self.loadTrackLabels(defaults: defaults, key: Keys.selectedCodexMenuBarTrackLabels, legacyKey: "settings.selectedCodexMenuBarTrackLabel")
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(claudeEnabled, forKey: Keys.claudeEnabled)
        defaults.set(codexEnabled, forKey: Keys.codexEnabled)
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
        defaults.set(menuBarShowsTrackLabels, forKey: Keys.menuBarShowsTrackLabels)
        defaults.set(allowBackgroundClaudeAuthRefresh, forKey: Keys.allowBackgroundClaudeAuthRefresh)
        defaults.set(MenuBarTrackSelection.normalized(selectedClaudeMenuBarTrackLabels), forKey: Keys.selectedClaudeMenuBarTrackLabels)
        defaults.set(MenuBarTrackSelection.normalized(selectedCodexMenuBarTrackLabels), forKey: Keys.selectedCodexMenuBarTrackLabels)
    }

    func withSelectedClaudeMenuBarTrackLabels(_ labels: [String]) -> AppConfig {
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
            claudeEnabled: claudeEnabled,
            codexEnabled: codexEnabled,
            menuBarShowsTrackLabels: menuBarShowsTrackLabels,
            allowBackgroundClaudeAuthRefresh: allowBackgroundClaudeAuthRefresh,
            selectedClaudeMenuBarTrackLabels: MenuBarTrackSelection.normalized(labels),
            selectedCodexMenuBarTrackLabels: selectedCodexMenuBarTrackLabels
        )
    }

    func withSelectedCodexMenuBarTrackLabels(_ labels: [String]) -> AppConfig {
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
            claudeEnabled: claudeEnabled,
            codexEnabled: codexEnabled,
            menuBarShowsTrackLabels: menuBarShowsTrackLabels,
            allowBackgroundClaudeAuthRefresh: allowBackgroundClaudeAuthRefresh,
            selectedClaudeMenuBarTrackLabels: selectedClaudeMenuBarTrackLabels,
            selectedCodexMenuBarTrackLabels: MenuBarTrackSelection.normalized(labels)
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
            claudeEnabled: claudeEnabled,
            codexEnabled: codexEnabled,
            menuBarShowsTrackLabels: menuBarShowsTrackLabels,
            allowBackgroundClaudeAuthRefresh: enabled,
            selectedClaudeMenuBarTrackLabels: selectedClaudeMenuBarTrackLabels,
            selectedCodexMenuBarTrackLabels: selectedCodexMenuBarTrackLabels
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
        static let claudeEnabled = "settings.claudeEnabled"
        static let codexEnabled = "settings.codexEnabled"
        static let menuBarShowsTrackLabels = "settings.menuBarShowsTrackLabels"
        static let allowBackgroundClaudeAuthRefresh = "settings.allowBackgroundClaudeAuthRefresh"
        static let selectedClaudeMenuBarTrackLabels = "settings.selectedClaudeMenuBarTrackLabels"
        static let selectedCodexMenuBarTrackLabels = "settings.selectedCodexMenuBarTrackLabels"
    }

    private static func loadTrackLabels(defaults: UserDefaults, key: String, legacyKey: String, defaultLabels: [String] = []) -> [String] {
        let labels = defaults.stringArray(forKey: key)
            ?? defaults.string(forKey: legacyKey).map { [$0] }
            ?? defaultLabels
        return MenuBarTrackSelection.normalized(labels)
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

/// 空の保存値は既定の枠を意味する。表示・操作には現在取得できた枠を使う。
enum MenuBarTrackSelection {
    static func normalized(_ labels: [String]) -> [String] {
        var result: [String] = []
        for label in labels where !label.isEmpty && !result.contains(label) {
            result.append(label)
        }
        return Array(result.prefix(2))
    }

    static func resolved(_ selected: [String], available: [String]) -> [String] {
        let selected = normalized(selected)
        let matches = available.filter { selected.contains($0) }
        if !matches.isEmpty { return Array(matches.prefix(2)) }
        return (available.first(where: { $0 == "5h" })
            ?? available.first(where: { $0 == "7d" })
            ?? available.first).map { [$0] } ?? []
    }

    static func canToggle(_ label: String, selected: [String]) -> Bool {
        selected.contains(label) ? selected.count > 1 : selected.count < 2
    }

    static func toggling(_ label: String, selected: [String]) -> [String] {
        guard canToggle(label, selected: selected) else { return selected }
        return selected.contains(label) ? selected.filter { $0 != label } : selected + [label]
    }
}

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
    let selectedClaudeOrgUUID: String?

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
            selectedClaudeOrgUUID: defaults.string(forKey: Keys.selectedClaudeOrgUUID)
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
        if let selectedClaudeOrgUUID, !selectedClaudeOrgUUID.isEmpty {
            defaults.set(selectedClaudeOrgUUID, forKey: Keys.selectedClaudeOrgUUID)
        } else {
            defaults.removeObject(forKey: Keys.selectedClaudeOrgUUID)
        }
    }

    func withSelectedClaudeOrgUUID(_ uuid: String?) -> AppConfig {
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
            selectedClaudeOrgUUID: uuid
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
        static let selectedClaudeOrgUUID = "settings.selectedClaudeOrgUUID"
    }
}

private extension UserDefaults {
    func integer(forKey key: String, default defaultValue: Int) -> Int {
        object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }

    func timeInterval(forKey key: String, default defaultValue: TimeInterval) -> TimeInterval {
        object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }
}

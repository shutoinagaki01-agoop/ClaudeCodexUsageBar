import Foundation

// swiftc Sources/ClaudeCodexUsageBar/AppConfig.swift scripts/check_menu_bar_tracks.swift -o /tmp/check_menu_bar_tracks
@main
struct MenuBarTrackChecks {
    static func main() {
        let suite = "ClaudeCodexUsageBarTracks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = AppConfig.load(defaults: defaults)
        precondition(MenuBarTrackSelection.resolved(initial.selectedClaudeMenuBarTrackLabels, available: ["5h", "7d"]) == ["5h", "7d"])
        precondition(MenuBarTrackSelection.resolved(initial.selectedCodexMenuBarTrackLabels, available: ["5h", "7d"]) == ["5h"])
        precondition(!initial.menuBarShowsTrackLabels)
        defaults.set("7d", forKey: "settings.selectedClaudeMenuBarTrackLabel")
        defaults.set("5h", forKey: "settings.selectedCodexMenuBarTrackLabel")
        let migrated = AppConfig.load(defaults: defaults)
        precondition(migrated.selectedClaudeMenuBarTrackLabels == ["7d"])
        precondition(migrated.selectedCodexMenuBarTrackLabels == ["5h"])

        let two = MenuBarTrackSelection.toggling("5h", selected: migrated.selectedClaudeMenuBarTrackLabels)
        precondition(Set(two) == Set(["5h", "7d"]))
        var changed = migrated.withSelectedClaudeMenuBarTrackLabels(two)
            .withSelectedCodexMenuBarTrackLabels(["5h", "7d"])
            .withAllowBackgroundClaudeAuthRefresh(true)
        changed.menuBarShowsTrackLabels = true
        changed.save(defaults: defaults)
        let reloaded = AppConfig.load(defaults: UserDefaults(suiteName: suite)!)
        precondition(reloaded.selectedClaudeMenuBarTrackLabels == two)
        precondition(reloaded.selectedCodexMenuBarTrackLabels == ["5h", "7d"])
        precondition(reloaded.allowBackgroundClaudeAuthRefresh)
        precondition(reloaded.menuBarShowsTrackLabels)

        // 表示順はクリック順に依存しない。存在しない枠を別の枠として重複表示しない。
        precondition(MenuBarTrackSelection.resolved(two, available: ["5h", "7d", "7d Sonnet"]) == ["5h", "7d"])
        precondition(MenuBarTrackSelection.resolved(two, available: ["7d"]) == ["7d"])
        precondition(MenuBarTrackSelection.resolved(["missing"], available: ["7d", "Extra"]) == ["7d"])
        precondition(MenuBarTrackSelection.resolved(two, available: []).isEmpty)
        precondition(MenuBarTrackSelection.toggling("7d Sonnet", selected: two) == two)
        precondition(!MenuBarTrackSelection.canToggle("7d Sonnet", selected: two))
        let single = MenuBarTrackSelection.toggling("5h", selected: two)
        precondition(single == ["7d"])
        precondition(MenuBarTrackSelection.toggling("7d", selected: single) == single)
        precondition(!MenuBarTrackSelection.canToggle("7d", selected: single))
        precondition(MenuBarTrackSelection.toggling("7d", selected: []) == ["7d"])
        changed.withSelectedClaudeMenuBarTrackLabels(single).save(defaults: defaults)
        precondition(AppConfig.load(defaults: defaults).selectedClaudeMenuBarTrackLabels == single)

        defaults.set(["", "5h", "5h", "7d", "Extra"], forKey: "settings.selectedClaudeMenuBarTrackLabels")
        precondition(AppConfig.load(defaults: defaults).selectedClaudeMenuBarTrackLabels == ["5h", "7d"])
        print("PASS: new defaults, legacy migration, saved preferences, two selections, reload, display order, missing tracks, selection bounds")
    }
}

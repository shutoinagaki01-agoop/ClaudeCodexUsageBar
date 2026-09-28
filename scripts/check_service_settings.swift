import Foundation

// Run with Xcode Command Line Tools (XCTest is not required):
// swiftc Sources/ClaudeCodexUsageBar/AppConfig.swift scripts/check_service_settings.swift -o /tmp/check_service_settings
// /tmp/check_service_settings
@main
struct ServiceSettingsChecks {
    let defaults: UserDefaults
    let suiteName: String

    static func main() {
        let suiteName = "ClaudeCodexUsageBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let checks = Self(defaults: defaults, suiteName: suiteName)
        checks.testExistingSettingsKeepBothServicesEnabled()
        checks.testBackgroundAuthDefaultAndSavedChoices()
        checks.testAllServiceCombinationsSurviveReload()
        checks.testChangingOtherPreferencesPreservesServiceSelection()
        print("PASS: defaults, background auth default and saved choices, all four service combinations, and preservation across preference changes")
    }

    func testExistingSettingsKeepBothServicesEnabled() {
        defaults.set(false, forKey: "settings.menuBarUsesIcons")
        defaults.set(420.0, forKey: "settings.normalRefreshInterval")

        let config = AppConfig.load(defaults: defaults)

        precondition(config.claudeEnabled)
        precondition(config.codexEnabled)
        precondition(config.normalRefreshInterval == 420)
    }

    func testBackgroundAuthDefaultAndSavedChoices() {
        precondition(AppConfig.load(defaults: defaults).allowBackgroundClaudeAuthRefresh)
        for enabled in [false, true] {
            AppConfig.load(defaults: defaults)
                .withAllowBackgroundClaudeAuthRefresh(enabled)
                .save(defaults: defaults)
            let reloaded = AppConfig.load(defaults: UserDefaults(suiteName: suiteName)!)
            precondition(reloaded.allowBackgroundClaudeAuthRefresh == enabled)
        }
    }

    func testAllServiceCombinationsSurviveReload() {
        for claude in [false, true] {
            for codex in [false, true] {
                var config = AppConfig.load(defaults: defaults)
                config.claudeEnabled = claude
                config.codexEnabled = codex
                config.save(defaults: defaults)

                let reloaded = AppConfig.load(defaults: UserDefaults(suiteName: suiteName)!)
                precondition(reloaded.claudeEnabled == claude)
                precondition(reloaded.codexEnabled == codex)
            }
        }
    }

    func testChangingOtherPreferencesPreservesServiceSelection() {
        for claude in [false, true] {
            for codex in [false, true] {
                var config = AppConfig.load(defaults: defaults)
                config.claudeEnabled = claude
                config.codexEnabled = codex
                let changed = config
                    .withAllowBackgroundClaudeAuthRefresh(true)
                    .withSelectedClaudeMenuBarTrackLabels(["5h", "7d"])
                    .withSelectedCodexMenuBarTrackLabels(["5h", "7d"])
                changed.save(defaults: defaults)

                let reloaded = AppConfig.load(defaults: defaults)
                precondition(reloaded.claudeEnabled == claude)
                precondition(reloaded.codexEnabled == codex)
                precondition(reloaded.allowBackgroundClaudeAuthRefresh)
                precondition(reloaded.selectedClaudeMenuBarTrackLabels == ["5h", "7d"])
                precondition(reloaded.selectedCodexMenuBarTrackLabels == ["5h", "7d"])
            }
        }
    }
}

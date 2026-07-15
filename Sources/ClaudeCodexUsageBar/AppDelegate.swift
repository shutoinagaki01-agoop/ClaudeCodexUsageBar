import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var claudeTimer: Timer?
    private var codexTimer: Timer?
    private let fetcher = UsageFetcher()
    private let codexFetcher = CodexUsageFetcher()
    private var latest: UsageSnapshot?
    private var latestCodex: CodexUsageSnapshot?
    private var latestError: String?
    private var latestCodexError: String?
    private var isLoadingClaude = false
    private var isLoadingCodex = false
    private var isResettingCodexUsage = false
    private var nextClaudeAutoRefreshAt: Date?
    private var nextCodexAutoRefreshAt: Date?
    private var config = AppConfig.load()
    private let weeklyLimitAlertThresholds = [50, 20]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            setMenuBarTitle("\(claudeTextLabel) …")
            button.toolTip = "Claude usage"
        }

        rebuildMenu()
        configureNotifications()
        registerWorkspaceNotifications()

        refreshClaude(isAutomatic: true)
        refreshCodex(isAutomatic: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    // MARK: - メニュー

    private func rebuildMenu() {
        let menu = NSMenu()

        if let snap = latest {
            let planLabel = snap.plan.map { "Claude: \($0)" } ?? "Claude"
            let plan = NSMenuItem(title: planLabel, action: nil, keyEquivalent: "")
            plan.isEnabled = false
            menu.addItem(plan)

            let selectedTrack = claudeHeaderTrack(from: snap.tracks)
            for t in sortedClaudeTracks(snap.tracks) {
                addClaudeTrackItem(to: menu, track: t, selectedTrack: selectedTrack)
            }
            let updated = NSMenuItem(title: "Claude 更新: \(formatTime(snap.fetchedAt))", action: nil, keyEquivalent: "")
            updated.isEnabled = false
            menu.addItem(updated)
            if let nextClaudeAutoRefreshAt {
                let next = NSMenuItem(title: "Claude 次回自動更新: \(formatTime(nextClaudeAutoRefreshAt))", action: nil, keyEquivalent: "")
                next.isEnabled = false
                menu.addItem(next)
            }
        } else if let err = latestError {
            let item = NSMenuItem(title: "Claude: \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Claude: 取得中…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let codex = latestCodex, !codex.tracks.isEmpty {
            menu.addItem(.separator())
            let plan = NSMenuItem(title: "Codex: \(codex.plan)", action: nil, keyEquivalent: "")
            plan.isEnabled = false
            menu.addItem(plan)
            let selectedTrack = codexTitleTrack(from: codex)
            for t in codex.tracks {
                addCodexTrackItem(to: menu, track: t, selectedTrack: selectedTrack)
            }
            let updated = NSMenuItem(title: "Codex 更新: \(formatTime(codex.fetchedAt))", action: nil, keyEquivalent: "")
            updated.isEnabled = false
            menu.addItem(updated)
            if let nextCodexAutoRefreshAt {
                let next = NSMenuItem(title: "Codex 次回自動更新: \(formatTime(nextCodexAutoRefreshAt))", action: nil, keyEquivalent: "")
                next.isEnabled = false
                menu.addItem(next)
            }
        } else if let latestCodexError {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Codex: \(latestCodexError)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let nextCodexAutoRefreshAt {
                let next = NSMenuItem(title: "Codex 次回自動更新: \(formatTime(nextCodexAutoRefreshAt))", action: nil, keyEquivalent: "")
                next.isEnabled = false
                menu.addItem(next)
            }
        } else if isLoadingCodex {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Codex: 取得中…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        addAction(to: menu, title: "Claude/Codexの残量を手動で更新", selector: #selector(refreshAction), key: "r")
        addCodexResetAction(to: menu)
        addSettingsSubmenu(to: menu)

        menu.addItem(.separator())
        addAction(to: menu, title: "ClaudeCodexUsageBar を終了", selector: #selector(quitAction), key: "q")

        statusItem.menu = menu
    }

    private func addAction(to menu: NSMenu, title: String, selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func addClaudeTrackItem(to menu: NSMenu, track: UsageTrack, selectedTrack: UsageTrack?) {
        let item = NSMenuItem(
            title: "  \(track.label): 残り \(track.remainingPercent)% · \(track.resetTimeString)",
            action: #selector(selectClaudeMenuBarTrackAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = track.label
        item.state = track.label == selectedTrack?.label ? .on : .off
        menu.addItem(item)
    }

    private func addCodexTrackItem(to menu: NSMenu, track: CodexUsageTrack, selectedTrack: CodexUsageTrack?) {
        let item = NSMenuItem(
            title: "  \(track.label): 残り \(track.remainingPercent)% · \(track.resetTimeString)",
            action: #selector(selectCodexMenuBarTrackAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = track.label
        item.state = track.label == selectedTrack?.label ? .on : .off
        menu.addItem(item)
    }

    private func addCodexResetAction(to menu: NSMenu) {
        let count = latestCodex?.rateLimitResetCreditsAvailable ?? 0
        var title = "Codex リセット: 残り\(count)回"
        if count > 0, let expiresAt = latestCodex?.nextResetCreditExpiresAt {
            title += " · 期限 \(formatMonthDayTime(expiresAt))"
        }
        let item = NSMenuItem(title: title, action: #selector(resetCodexUsageAction), keyEquivalent: "")
        item.target = self
        item.isEnabled = count > 0 && !isResettingCodexUsage
        menu.addItem(item)
    }

    private func addDataSubmenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "取得データをFinderで開く", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        addAction(to: submenu, title: "Claude", selector: #selector(revealDumpAction), key: "j")
        addAction(to: submenu, title: "Codex", selector: #selector(revealCodexDumpAction), key: "k")
        menu.setSubmenu(submenu, for: parent)
        menu.addItem(parent)
    }

    private func addSettingsSubmenu(to menu: NSMenu) {
        let parent = NSMenuItem(title: "詳細設定", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        addDisabledItem(to: submenu, title: "起動時間: \(config.autoRefreshWindowLabel)")
        addDisabledItem(to: submenu, title: "ピーク時間: \(config.peakWindowLabel)")
        addDisabledItem(to: submenu, title: "ピーク時更新間隔: \(formatInterval(config.peakRefreshInterval))")
        addDisabledItem(to: submenu, title: "通常時更新間隔: \(formatInterval(config.normalRefreshInterval))")
        submenu.addItem(.separator())
        let iconDisplay = NSMenuItem(title: "メニューバーをアイコン表示", action: #selector(toggleMenuBarIconDisplayAction), keyEquivalent: "")
        iconDisplay.target = self
        iconDisplay.state = config.menuBarUsesIcons ? .on : .off
        submenu.addItem(iconDisplay)
        submenu.addItem(.separator())
        addDataSubmenu(to: submenu)
        submenu.addItem(.separator())
        let edit = NSMenuItem(title: "時間設定を変更…", action: #selector(editTimeSettingsAction), keyEquivalent: "")
        edit.target = self
        submenu.addItem(edit)

        menu.setSubmenu(submenu, for: parent)
        menu.addItem(parent)
    }

    private func addDisabledItem(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if let tracks = latest?.tracks, !tracks.isEmpty {
            let sorted = sortedClaudeTracks(tracks)
            let headerTrack = claudeHeaderTrack(from: tracks) ?? sorted.first!
            let codexPart = codexTitlePart(includeUnavailableState: true)
            let resetSuffix = headerTrack.resetsAt == nil ? "" : "·\(shortReset(headerTrack))"
            setMenuBarTitle("\(claudeTextLabel)\(claudeTitleLabelPart(for: headerTrack)) \(headerTrack.remainingPercent)%\(resetSuffix)\(codexPart)")
            let claudeTip = sorted.map { "\($0.label): 残り \($0.remainingPercent)%, リセット \($0.resetTimeString)" }
                .joined(separator: "\n")
                + "\n更新: \(formatTime(latest!.fetchedAt))"
            let codexTip = codexToolTipPart()
            button.toolTip = codexTip.isEmpty ? claudeTip : "\(claudeTip)\n\n\(codexTip)"
        } else if latestError != nil {
            let codexPart = codexTitlePart(includeUnavailableState: true)
            let title = codexPart.isEmpty ? "\(claudeTextLabel) error" : "\(claudeTextLabel) error\(codexPart)"
            setMenuBarTitle(title)
            let codexTip = codexToolTipPart()
            button.toolTip = codexTip.isEmpty ? latestError : "\(latestError ?? "")\n\n\(codexTip)"
        } else {
            let codexPart = codexTitlePart(includeUnavailableState: true)
            let title = codexPart.isEmpty ? "\(claudeTextLabel) …" : "\(claudeTextLabel) …\(codexPart)"
            setMenuBarTitle(title)
            let codexTip = codexToolTipPart()
            button.toolTip = codexTip.isEmpty ? "取得中" : "取得中\n\n\(codexTip)"
        }
    }

    private func setMenuBarTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.image = nil

        guard config.menuBarUsesIcons else {
            button.attributedTitle = NSAttributedString()
            button.title = title
            return
        }

        button.title = ""
        button.attributedTitle = iconMenuBarTitle(from: title)
    }

    private func iconMenuBarTitle(from title: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var remaining = title

        if remaining.hasPrefix(claudeTextLabel) {
            output.append(iconAttachmentString(image: makeClaudeMenuBarIcon()))
            remaining.removeFirst(claudeTextLabel.count)
        }

        while let range = remaining.range(of: codexTextLabel) {
            output.append(NSAttributedString(string: String(remaining[..<range.lowerBound])))
            output.append(iconAttachmentString(image: makeCodexMenuBarIcon()))
            remaining = String(remaining[range.upperBound...])
        }

        output.append(NSAttributedString(string: remaining))
        return output
    }

    private func iconAttachmentString(image: NSImage) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let string = NSMutableAttributedString(attachment: attachment)
        string.append(NSAttributedString(string: " "))
        return string
    }

    private func sortedClaudeTracks(_ tracks: [UsageTrack]) -> [UsageTrack] {
        let priority: [String] = ["5h", "5h Sonnet", "7d", "7d Sonnet", "7d Opus", "7d Haiku", "7d Fable", "Extra"]
        return tracks.sorted { a, b in
            let ai = priority.firstIndex(of: a.label) ?? Int.max
            let bi = priority.firstIndex(of: b.label) ?? Int.max
            if ai != bi { return ai < bi }
            return a.remainingFraction < b.remainingFraction
        }
    }

    private func claudeHeaderTrack(from tracks: [UsageTrack]) -> UsageTrack? {
        let sorted = sortedClaudeTracks(tracks)
        if let selected = config.selectedClaudeMenuBarTrackLabel,
           let track = sorted.first(where: { $0.label == selected }) {
            return track
        }
        return sorted.first(where: { $0.label == "5h" })
            ?? sorted.first(where: { $0.label == "7d" })
            ?? sorted.first
    }

    private func claudeTitleLabelPart(for track: UsageTrack) -> String {
        track.label.hasPrefix("7d") ? " \(track.label)" : ""
    }

    private func codexTitlePart(includeUnavailableState: Bool = false) -> String {
        guard let codex = latestCodex, let track = codexTitleTrack(from: codex) else {
            guard includeUnavailableState else { return "" }
            if latestCodexError != nil {
                return " | \(codexTextLabel) error"
            }
            if isLoadingCodex {
                return " | \(codexTextLabel) …"
            }
            return ""
        }
        let label = track.label == "5h" ? "" : " \(track.label)"
        return " | \(codexTextLabel)\(label) \(track.remainingPercent)%·\(shortReset(track))"
    }

    private func codexTitleTrack(from snapshot: CodexUsageSnapshot) -> CodexUsageTrack? {
        if let selected = config.selectedCodexMenuBarTrackLabel,
           let track = snapshot.tracks.first(where: { $0.label == selected }) {
            return track
        }
        return snapshot.fiveHour ?? snapshot.sevenDay
    }

    private var claudeTextLabel: String {
        "Claude"
    }

    private var codexTextLabel: String {
        "Codex"
    }

    private func makeClaudeMenuBarIcon() -> NSImage {
        makeVectorIcon(resourceName: "ClaudeIcon")
    }

    private func makeCodexMenuBarIcon() -> NSImage {
        loadTemplateIcon(resourceName: "CodexIcon", tint: .white) ?? NSImage(size: NSSize(width: 16, height: 16))
    }

    private func makeVectorIcon(resourceName: String) -> NSImage {
        guard let icon = loadSVGIcon(resourceName: resourceName) else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        return makeVectorIcon(pathData: icon.pathData, viewBox: icon.viewBox)
    }

    private func makeVectorIcon(pathData: String, viewBox: NSRect) -> NSImage {
        let iconSize: CGFloat = 16
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        var parser = SVGPathParser(pathData)
        let path = parser.parse()
        let scale = min(iconSize / viewBox.width, iconSize / viewBox.height)
        let width = viewBox.width * scale
        let height = viewBox.height * scale
        let x = (iconSize - width) / 2
        let y = (iconSize - height) / 2

        context.saveGState()
        context.translateBy(x: x, y: y + height)
        context.scaleBy(x: scale, y: -scale)
        NSColor.labelColor.setFill()
        path.fill()
        context.restoreGState()

        image.unlockFocus()
        return image
    }

    private func loadSVGIcon(resourceName: String) -> SVGIcon? {
        guard let url = iconResourceURL(resourceName: resourceName),
              let data = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return SVGIcon(svg: data)
    }

    private func iconResourceURL(resourceName: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: resourceName, withExtension: "svg") {
            return bundled
        }

        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(resourceName).svg")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private func loadTemplateIcon(resourceName: String, tint: NSColor) -> NSImage? {
        guard let url = imageResourceURL(resourceName: resourceName),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.size = NSSize(width: 16, height: 16)
        return image.tinted(with: tint)
    }

    private func imageResourceURL(resourceName: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            return bundled
        }

        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(resourceName).png")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private func codexToolTipPart() -> String {
        if let codex = latestCodex, !codex.tracks.isEmpty {
            let lines = codex.tracks.map {
                "Codex \($0.label): 残り \($0.remainingPercent)%, リセット \($0.resetTimeString)"
            }
            return (["Codex plan: \(codex.plan)"] + lines + ["Codex 更新: \(formatTime(codex.fetchedAt))"])
                .joined(separator: "\n")
        }
        if let latestCodexError {
            return "Codex: \(latestCodexError)"
        }
        return ""
    }

    /// メニューバー用の短いリセット表記。
    /// 24h 以内なら "HH:mm"、それ以上先なら "M/d" だけ（時刻はドロップダウン側で見せる）。
    private func shortReset(_ t: UsageTrack) -> String {
        guard let d = t.resetsAt else { return "--" }
        let f = DateFormatter()
        if abs(d.timeIntervalSinceNow) < 24 * 60 * 60 {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d"
        }
        return f.string(from: d)
    }

    private func shortReset(_ t: CodexUsageTrack) -> String {
        guard let d = t.resetsAt else { return "--" }
        let f = DateFormatter()
        if abs(d.timeIntervalSinceNow) < 24 * 60 * 60 {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "M/d"
        }
        return f.string(from: d)
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }

    private func formatMonthDayTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: d)
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds % 60 == 0 {
            return "\(seconds / 60)分"
        }
        return "\(seconds)秒"
    }

    // MARK: - アクション

    @objc private func refreshAction() { refreshNow() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func selectClaudeMenuBarTrackAction(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        config = config.withSelectedClaudeMenuBarTrackLabel(label)
        config.save()
        updateTitle()
        rebuildMenu()
    }

    @objc private func selectCodexMenuBarTrackAction(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        config = config.withSelectedCodexMenuBarTrackLabel(label)
        config.save()
        updateTitle()
        rebuildMenu()
    }

    @objc private func workspaceWillSleep() {
        claudeTimer?.invalidate()
        codexTimer?.invalidate()
        claudeTimer = nil
        codexTimer = nil
        nextClaudeAutoRefreshAt = nil
        nextCodexAutoRefreshAt = nil
    }

    @objc private func workspaceDidWake() {
        config = AppConfig.load()

        if isInAutoRefreshWindow() {
            refreshClaude(isAutomatic: true)
            refreshCodex(isAutomatic: true)
        } else {
            scheduleNextClaudeAutoRefresh()
            scheduleNextCodexAutoRefresh()
            rebuildMenu()
        }
    }

    @objc private func editTimeSettingsAction() {
        promptForTimeSettings()
    }

    @objc private func toggleMenuBarIconDisplayAction() {
        config = config.withMenuBarUsesIcons(!config.menuBarUsesIcons)
        config.save()
        updateTitle()
        rebuildMenu()
    }

    @objc private func resetCodexUsageAction() {
        let count = latestCodex?.rateLimitResetCreditsAvailable ?? 0
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Codex 使用量をリセットしますか？"
        alert.informativeText = "リセット可能回数を1回消費します。現在の残り回数は \(count) 回です。この操作は取り消せません。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "リセット")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isResettingCodexUsage = true
        latestCodexError = "Codex 使用量をリセット中…"
        rebuildMenu()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.codexFetcher.consumeRateLimitResetCredit()
                await MainActor.run {
                    self.isResettingCodexUsage = false
                    self.refreshCodex()
                }
            } catch {
                await MainActor.run {
                    self.isResettingCodexUsage = false
                    self.latestCodexError = "リセット失敗: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.updateTitle()
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc private func revealDumpAction() {
        let url = DebugDump.lastResponseURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // まだダンプがない場合はディレクトリだけ開く
            NSWorkspace.shared.open(DebugDump.directory)
        }
    }

    @objc private func revealCodexDumpAction() {
        let url = DebugDump.codexResponseURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(DebugDump.directory)
        }
    }

    private func promptForTimeSettings() {
        let autoStart = NSTextField(string: AppConfig.formatTime(hour: config.autoRefreshStartHour, minute: config.autoRefreshStartMinute))
        let autoEnd = NSTextField(string: AppConfig.formatTime(hour: config.autoRefreshEndHour, minute: config.autoRefreshEndMinute))
        let peakStart = NSTextField(string: AppConfig.formatTime(hour: config.peakRefreshStartHour, minute: config.peakRefreshStartMinute))
        let peakEnd = NSTextField(string: AppConfig.formatTime(hour: config.peakRefreshEndHour, minute: config.peakRefreshEndMinute))
        let peakInterval = NSTextField(string: "\(Int(config.peakRefreshInterval / 60))")
        let normalInterval = NSTextField(string: "\(Int(config.normalRefreshInterval / 60))")

        let fields: [(String, NSTextField)] = [
            ("起動時間 開始 (HH:mm)", autoStart),
            ("起動時間 終了 (HH:mm)", autoEnd),
            ("ピーク時間 開始 (HH:mm)", peakStart),
            ("ピーク時間 終了 (HH:mm)", peakEnd),
            ("ピーク時 更新間隔 (分)", peakInterval),
            ("通常時 更新間隔 (分)", normalInterval),
        ]

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 184))
        for (index, pair) in fields.enumerated() {
            let y = 154 - (index * 30)
            let label = NSTextField(labelWithString: pair.0)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y, width: 210, height: 22)
            pair.1.frame = NSRect(x: 222, y: y - 2, width: 120, height: 24)
            form.addSubview(label)
            form.addSubview(pair.1)
        }

        let alert = NSAlert()
        alert.messageText = "時間設定"
        alert.informativeText = "自動取得する時間帯、ピーク時間帯、更新間隔を変更できます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.accessoryView = form
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let autoStartTime = try parseClock(autoStart.stringValue, fieldName: "起動時間 開始")
            let autoEndTime = try parseClock(autoEnd.stringValue, fieldName: "起動時間 終了")
            let peakStartTime = try parseClock(peakStart.stringValue, fieldName: "ピーク時間 開始")
            let peakEndTime = try parseClock(peakEnd.stringValue, fieldName: "ピーク時間 終了")
            let peakMinutes = try parsePositiveMinutes(peakInterval.stringValue, fieldName: "ピーク時 更新間隔")
            let normalMinutes = try parsePositiveMinutes(normalInterval.stringValue, fieldName: "通常時 更新間隔")

            config = AppConfig(
                peakRefreshInterval: TimeInterval(peakMinutes * 60),
                normalRefreshInterval: TimeInterval(normalMinutes * 60),
                depletedFallbackRefreshInterval: config.depletedFallbackRefreshInterval,
                resetRefreshBuffer: config.resetRefreshBuffer,
                autoRefreshStartHour: autoStartTime.hour,
                autoRefreshStartMinute: autoStartTime.minute,
                autoRefreshEndHour: autoEndTime.hour,
                autoRefreshEndMinute: autoEndTime.minute,
                peakRefreshStartHour: peakStartTime.hour,
                peakRefreshStartMinute: peakStartTime.minute,
                peakRefreshEndHour: peakEndTime.hour,
                peakRefreshEndMinute: peakEndTime.minute,
                autoRefreshTimeZone: config.autoRefreshTimeZone,
                menuBarUsesIcons: config.menuBarUsesIcons,
                selectedClaudeMenuBarTrackLabel: config.selectedClaudeMenuBarTrackLabel,
                selectedCodexMenuBarTrackLabel: config.selectedCodexMenuBarTrackLabel
            )
            config.save()
            scheduleNextClaudeAutoRefresh()
            scheduleNextCodexAutoRefresh()
            rebuildMenu()
        } catch {
            showValidationError(error.localizedDescription)
        }
    }

    private func parseClock(_ raw: String, fieldName: String) throws -> (hour: Int, minute: Int) {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else {
            throw SettingsValidationError.invalidValue("\(fieldName) は HH:mm 形式で入力してください。")
        }
        return (hour, minute)
    }

    private func parsePositiveMinutes(_ raw: String, fieldName: String) throws -> Int {
        guard let minutes = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), minutes > 0 else {
            throw SettingsValidationError.invalidValue("\(fieldName) は 1 以上の分数で入力してください。")
        }
        return minutes
    }

    private func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "設定を保存できません"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - データ取得

    private func refreshNow() {
        refreshClaude()
        refreshCodex()
    }

    private func refreshClaude(isAutomatic: Bool = false) {
        if isAutomatic && !isInAutoRefreshWindow() {
            latestError = "自動更新は JST \(config.autoRefreshWindowLabel) のみ"
            isLoadingClaude = false
            updateTitle()
            scheduleNextClaudeAutoRefresh()
            rebuildMenu()
            return
        }

        latestError = nil
        isLoadingClaude = true
        updateTitle()
        rebuildMenu()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let snap = try await self.fetcher.fetchUsage()
                await MainActor.run {
                    self.latest = snap
                    self.latestError = nil
                    self.isLoadingClaude = false
                    self.showClaudeWeeklyLimitAlertsIfNeeded(from: snap)
                    self.updateTitle()
                    self.scheduleNextClaudeAutoRefresh()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.latestError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isLoadingClaude = false
                    self.updateTitle()
                    self.scheduleNextClaudeAutoRefresh()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func refreshCodex(isAutomatic: Bool = false) {
        if isAutomatic && !isInAutoRefreshWindow() {
            latestCodexError = "自動更新は JST \(config.autoRefreshWindowLabel) のみ"
            isLoadingCodex = false
            updateTitle()
            scheduleNextCodexAutoRefresh()
            rebuildMenu()
            return
        }

        latestCodexError = nil
        isLoadingCodex = true
        updateTitle()
        rebuildMenu()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let snap = try await self.codexFetcher.fetchUsage()
                await MainActor.run {
                    self.latestCodex = snap
                    self.latestCodexError = nil
                    self.isLoadingCodex = false
                    self.showWeeklyLimitAlertIfNeeded(service: "Codex", track: self.weeklyLimitTrack(from: snap))
                    self.updateTitle()
                    self.scheduleNextCodexAutoRefresh()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.latestCodexError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isLoadingCodex = false
                    self.updateTitle()
                    self.scheduleNextCodexAutoRefresh()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func scheduleNextClaudeAutoRefresh() {
        claudeTimer?.invalidate()

        let now = Date()
        let next: Date
        if isInAutoRefreshWindow(now) {
            let candidate = nextClaudeRefreshDate(after: now)
            next = isInAutoRefreshWindow(candidate) ? candidate : nextAutoRefreshStart(after: now)
        } else {
            next = nextAutoRefreshStart(after: now)
        }

        nextClaudeAutoRefreshAt = next
        claudeTimer = Timer(fireAt: next, interval: 0, target: self, selector: #selector(claudeAutoRefreshTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(claudeTimer!, forMode: .common)
    }

    private func scheduleNextCodexAutoRefresh() {
        codexTimer?.invalidate()

        let now = Date()
        let next: Date
        if isInAutoRefreshWindow(now) {
            let candidate = nextCodexRefreshDate(after: now)
            next = isInAutoRefreshWindow(candidate) ? candidate : nextAutoRefreshStart(after: now)
        } else {
            next = nextAutoRefreshStart(after: now)
        }

        nextCodexAutoRefreshAt = next
        codexTimer = Timer(fireAt: next, interval: 0, target: self, selector: #selector(codexAutoRefreshTimerFired), userInfo: nil, repeats: false)
        RunLoop.main.add(codexTimer!, forMode: .common)
    }

    @objc private func claudeAutoRefreshTimerFired() {
        refreshClaude(isAutomatic: true)
    }

    @objc private func codexAutoRefreshTimerFired() {
        refreshCodex(isAutomatic: true)
    }

    private func nextClaudeRefreshDate(after date: Date) -> Date {
        if isFiveHourDepleted(), let resetDate = nextFiveHourOrSevenDayReset(after: date) {
            return resetDate.addingTimeInterval(config.resetRefreshBuffer)
        }
        let interval = isFiveHourDepleted() ? config.depletedFallbackRefreshInterval : refreshInterval(at: date)
        return date.addingTimeInterval(interval)
    }

    private func nextCodexRefreshDate(after date: Date) -> Date {
        if isCodexFiveHourDepleted(), let resetDate = nextCodexReset(after: date) {
            return resetDate.addingTimeInterval(config.resetRefreshBuffer)
        }
        let interval = isCodexFiveHourDepleted() ? config.depletedFallbackRefreshInterval : refreshInterval(at: date)
        return date.addingTimeInterval(interval)
    }

    private func isFiveHourDepleted() -> Bool {
        guard let tracks = latest?.tracks else { return false }
        return tracks.contains { track in
            track.label.hasPrefix("5h") && track.remainingPercent <= 0
        }
    }

    private func nextFiveHourOrSevenDayReset(after date: Date) -> Date? {
        guard let tracks = latest?.tracks else { return nil }
        let minimumDelay: TimeInterval = 5
        return tracks.compactMap { track -> Date? in
            guard track.label.hasPrefix("5h") || track.label.hasPrefix("7d") else { return nil }
            guard let resetsAt = track.resetsAt, resetsAt.timeIntervalSince(date) > minimumDelay else { return nil }
            return resetsAt
        }.min()
    }

    private func isCodexFiveHourDepleted() -> Bool {
        guard let fiveHour = latestCodex?.fiveHour else { return false }
        return fiveHour.remainingPercent <= 0
    }

    private func nextCodexReset(after date: Date) -> Date? {
        let minimumDelay: TimeInterval = 5
        return latestCodex?.tracks.compactMap { track -> Date? in
            guard let resetsAt = track.resetsAt, resetsAt.timeIntervalSince(date) > minimumDelay else { return nil }
            return resetsAt
        }.min()
    }

    private func claudeWeeklyLimitTracks(from snapshot: UsageSnapshot) -> [UsageTrack] {
        snapshot.tracks
            .filter { ["7d", "7d Fable"].contains($0.label) }
    }

    private func weeklyLimitTrack(from snapshot: CodexUsageSnapshot) -> CodexUsageTrack? {
        snapshot.tracks
            .filter { $0.label.hasPrefix("7d") }
            .min { $0.remainingFraction < $1.remainingFraction }
    }

    private func showClaudeWeeklyLimitAlertsIfNeeded(from snapshot: UsageSnapshot) {
        for track in claudeWeeklyLimitTracks(from: snapshot) {
            showWeeklyLimitAlertIfNeeded(service: "Claude", track: track)
        }
    }

    private func showWeeklyLimitAlertIfNeeded(service: String, track: UsageTrack?) {
        guard let track else { return }
        showWeeklyLimitAlertIfNeeded(
            service: service,
            label: track.label,
            remainingPercent: track.remainingPercent,
            resetTimeString: track.resetTimeString,
            resetsAt: track.resetsAt
        )
    }

    private func showWeeklyLimitAlertIfNeeded(service: String, track: CodexUsageTrack?) {
        guard let track else { return }
        showWeeklyLimitAlertIfNeeded(
            service: service,
            label: track.label,
            remainingPercent: track.remainingPercent,
            resetTimeString: track.resetTimeString,
            resetsAt: track.resetsAt
        )
    }

    private func showWeeklyLimitAlertIfNeeded(
        service: String,
        label: String,
        remainingPercent: Int,
        resetTimeString: String,
        resetsAt: Date?
    ) {
        let thresholds = weeklyLimitAlertThresholds.sorted()
        guard let threshold = thresholds.first(where: { remainingPercent <= $0 }) else { return }

        let key = weeklyLimitAlertKey(service: service, label: label, threshold: threshold, resetsAt: resetsAt)
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let crossedThresholds = thresholds.filter { $0 >= threshold }

        deliverWeeklyLimitNotification(
            service: service,
            label: label,
            threshold: threshold,
            remainingPercent: remainingPercent,
            resetTimeString: resetTimeString
        ) { delivered in
            guard delivered else { return }
            for crossedThreshold in crossedThresholds {
                UserDefaults.standard.set(true, forKey: self.weeklyLimitAlertKey(service: service, label: label, threshold: crossedThreshold, resetsAt: resetsAt))
            }
        }
    }

    private func weeklyLimitAlertKey(service: String, label: String, threshold: Int, resetsAt: Date?) -> String {
        let labelID = label.replacingOccurrences(of: " ", with: "_")
        let resetID = resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "weeklyLimitAlert.\(service).\(labelID).\(threshold).\(resetID)"
    }

    private func deliverWeeklyLimitNotification(
        service: String,
        label: String,
        threshold: Int,
        remainingPercent: Int,
        resetTimeString: String,
        completion: @escaping (Bool) -> Void
    ) {
        ensureNotificationAuthorization { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    self?.showNotificationPermissionAlert()
                    completion(false)
                }
                return
            }

            self?.enqueueWeeklyLimitNotification(
                service: service,
                label: label,
                threshold: threshold,
                remainingPercent: remainingPercent,
                resetTimeString: resetTimeString,
                completion: completion
            )
        }
    }

    private func ensureNotificationAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        print("Notification authorization failed: \(error.localizedDescription)")
                    }
                    completion(granted)
                }
            case .denied:
                completion(false)
            @unknown default:
                completion(false)
            }
        }
    }

    private func enqueueWeeklyLimitNotification(
        service: String,
        label: String,
        threshold: Int,
        remainingPercent: Int,
        resetTimeString: String,
        completion: @escaping (Bool) -> Void
    ) {
        let content = UNMutableNotificationContent()
        let serviceLabel = service == "Claude" && label == "7d Fable" ? "Claude(Fable)" : service
        content.title = "\(serviceLabel) 週次枠 残り\(remainingPercent)%"
        content.body = "リセット: \(resetTimeString)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "weeklyLimit.\(service).\(threshold).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("Weekly limit notification failed: \(error.localizedDescription)")
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    private func showNotificationPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "通知が許可されていません"
        alert.informativeText = "macOSの「システム設定 > 通知」で ClaudeCodexUsageBar の通知を許可してください。"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func isInAutoRefreshWindow(_ date: Date = Date()) -> Bool {
        let components = japanCalendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = config.autoRefreshStartHour * 60 + config.autoRefreshStartMinute
        let end = config.autoRefreshEndHour * 60 + config.autoRefreshEndMinute
        return minuteOfDay >= start && minuteOfDay < end
    }

    private func refreshInterval(at date: Date) -> TimeInterval {
        let components = japanCalendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = config.peakRefreshStartHour * 60 + config.peakRefreshStartMinute
        let end = config.peakRefreshEndHour * 60 + config.peakRefreshEndMinute
        if minuteOfDay >= start && minuteOfDay < end {
            return config.peakRefreshInterval
        }
        return config.normalRefreshInterval
    }

    private func nextAutoRefreshStart(after date: Date) -> Date {
        let calendar = japanCalendar
        let startToday = calendar.date(
            bySettingHour: config.autoRefreshStartHour,
            minute: config.autoRefreshStartMinute,
            second: 0,
            of: date
        )!

        if date < startToday {
            return startToday
        }

        return calendar.date(byAdding: .day, value: 1, to: startToday)!
    }

    private var japanCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = config.autoRefreshTimeZone
        return calendar
    }

}

private struct SVGIcon {
    let viewBox: NSRect
    let pathData: String

    init?(svg: String) {
        guard let viewBoxValue = Self.attribute("viewBox", in: svg),
              let pathData = Self.attribute("d", in: svg)
        else {
            return nil
        }

        let values = viewBoxValue.split(separator: " ").compactMap { Double($0) }
        guard values.count == 4 else { return nil }

        self.viewBox = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        self.pathData = pathData
    }

    private static func attribute(_ name: String, in string: String) -> String? {
        let pattern = #"\#(name)="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let valueRange = Range(match.range(at: 1), in: string)
        else {
            return nil
        }
        return String(string[valueRange])
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)

        output.unlockFocus()
        output.isTemplate = false
        return output
    }
}

private struct SVGPathParser {
    private let tokens: [String]
    private var index = 0
    private var current = NSPoint.zero
    private var subpathStart = NSPoint.zero

    init(_ pathData: String) {
        let pattern = #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(pathData.startIndex..<pathData.endIndex, in: pathData)
        self.tokens = regex.matches(in: pathData, range: range).compactMap {
            Range($0.range, in: pathData).map { String(pathData[$0]) }
        }
    }

    mutating func parse() -> NSBezierPath {
        let path = NSBezierPath()
        var command: String?

        while index < tokens.count {
            if isCommand(tokens[index]) {
                command = tokens[index]
                index += 1
            }

            guard let activeCommand = command else { break }

            switch activeCommand {
            case "M", "m":
                parseMove(path: path, relative: activeCommand == "m")
                command = activeCommand == "m" ? "l" : "L"
            case "L", "l":
                parseLine(path: path, relative: activeCommand == "l")
            case "H", "h":
                parseHorizontal(path: path, relative: activeCommand == "h")
            case "V", "v":
                parseVertical(path: path, relative: activeCommand == "v")
            case "C", "c":
                parseCurve(path: path, relative: activeCommand == "c")
            case "Z", "z":
                path.close()
                current = subpathStart
                command = nil
            default:
                command = nil
            }
        }

        return path
    }

    private func isCommand(_ token: String) -> Bool {
        token.count == 1 && token.first?.isLetter == true
    }

    private mutating func parseMove(path: NSBezierPath, relative: Bool) {
        guard let point = readPoint(relative: relative) else { return }
        path.move(to: point)
        current = point
        subpathStart = point

        while let point = readPoint(relative: relative) {
            path.line(to: point)
            current = point
        }
    }

    private mutating func parseLine(path: NSBezierPath, relative: Bool) {
        while let point = readPoint(relative: relative) {
            path.line(to: point)
            current = point
        }
    }

    private mutating func parseHorizontal(path: NSBezierPath, relative: Bool) {
        while let x = readNumber() {
            let point = NSPoint(x: relative ? current.x + x : x, y: current.y)
            path.line(to: point)
            current = point
        }
    }

    private mutating func parseVertical(path: NSBezierPath, relative: Bool) {
        while let y = readNumber() {
            let point = NSPoint(x: current.x, y: relative ? current.y + y : y)
            path.line(to: point)
            current = point
        }
    }

    private mutating func parseCurve(path: NSBezierPath, relative: Bool) {
        while let c1 = readPoint(relative: relative),
              let c2 = readPoint(relative: relative),
              let end = readPoint(relative: relative) {
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            current = end
        }
    }

    private mutating func readPoint(relative: Bool) -> NSPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        if relative {
            return NSPoint(x: current.x + x, y: current.y + y)
        }
        return NSPoint(x: x, y: y)
    }

    private mutating func readNumber() -> CGFloat? {
        guard index < tokens.count, !isCommand(tokens[index]) else { return nil }
        defer { index += 1 }
        guard let value = Double(tokens[index]) else { return nil }
        return CGFloat(value)
    }
}

private enum SettingsValidationError: LocalizedError {
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidValue(let message): return message
        }
    }
}

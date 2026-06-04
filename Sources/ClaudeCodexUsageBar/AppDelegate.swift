import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var claudeTimer: Timer?
    private var codexTimer: Timer?
    private let fetcher = UsageFetcher()
    private let codexFetcher = CodexUsageFetcher()
    private var latest: UsageSnapshot?
    private var latestCodex: CodexUsageSnapshot?
    private var latestError: String?
    private var latestCodexError: String?
    private var latestClaudeOrganizations: [ClaudeOrganization] = []
    private var latestClaudeOrganizationsError: String?
    private var nextClaudeAutoRefreshAt: Date?
    private var nextCodexAutoRefreshAt: Date?
    private var config = AppConfig.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "Claude …"
            button.toolTip = "Claude usage"
        }

        rebuildMenu()
        loadClaudeOrganizations()

        if KeychainHelper.load() == nil {
            promptForSessionKey(reason: "初回セットアップ: claude.ai の sessionKey を貼り付けてください")
        }

        refreshClaude(isAutomatic: true)
        refreshCodex(isAutomatic: true)
    }

    // MARK: - メニュー

    private func rebuildMenu() {
        let menu = NSMenu()

        if let snap = latest {
            let planLabel = snap.plan.map { "Claude: \($0)" } ?? "Claude"
            let plan = NSMenuItem(title: planLabel, action: nil, keyEquivalent: "")
            plan.isEnabled = false
            menu.addItem(plan)

            let headerTrack = claudeHeaderTrack(from: snap.tracks)
            if let headerTrack {
                let header = NSMenuItem(title: "  \(headerTrack.label): 残り \(headerTrack.remainingPercent)% · \(headerTrack.resetTimeString)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }

            for t in sortedClaudeTracks(snap.tracks) where t != headerTrack {
                let item = NSMenuItem(
                    title: "  \(t.label): 残り \(t.remainingPercent)% · \(t.resetTimeString)",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
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
            for t in codex.tracks {
                let item = NSMenuItem(
                    title: "  \(t.label): 残り \(t.remainingPercent)% · \(t.resetTimeString)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
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
        }

        menu.addItem(.separator())

        addAction(to: menu, title: "Claude/Codexの残量を手動で更新", selector: #selector(refreshAction), key: "r")
        addDataSubmenu(to: menu)
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
        let sessionKey = NSMenuItem(title: "Claude sessionKey を設定…", action: #selector(setSessionKeyAction), keyEquivalent: ",")
        sessionKey.target = self
        submenu.addItem(sessionKey)
        submenu.addItem(.separator())
        addClaudeOrgSubmenu(to: submenu)
        let reloadOrgs = NSMenuItem(title: "Claude org一覧を再読み込み", action: #selector(reloadClaudeOrganizationsAction), keyEquivalent: "")
        reloadOrgs.target = self
        submenu.addItem(reloadOrgs)
        submenu.addItem(.separator())
        let edit = NSMenuItem(title: "時間設定を変更…", action: #selector(editTimeSettingsAction), keyEquivalent: "")
        edit.target = self
        submenu.addItem(edit)

        menu.setSubmenu(submenu, for: parent)
        menu.addItem(parent)
    }

    private func addClaudeOrgSubmenu(to menu: NSMenu) {
        let title = selectedClaudeOrganization().map { "Claude org: \($0.displayName)" } ?? "Claude orgを選択"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if latestClaudeOrganizations.isEmpty {
            let message = latestClaudeOrganizationsError ?? "org一覧を取得中…"
            addDisabledItem(to: submenu, title: message)
        } else {
            for org in latestClaudeOrganizations {
                let item = NSMenuItem(title: org.displayName, action: #selector(selectClaudeOrganizationAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = org.uuid
                item.state = org.uuid == selectedClaudeOrgUUID() ? .on : .off
                submenu.addItem(item)
            }
        }

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
            let codexPart = codexTitlePart()
            let resetSuffix = headerTrack.resetsAt == nil ? "" : "·\(shortReset(headerTrack))"
            button.title = "Claude \(headerTrack.remainingPercent)%\(resetSuffix)\(codexPart)"
            let claudeTip = sorted.map { "\($0.label): 残り \($0.remainingPercent)%, リセット \($0.resetTimeString)" }
                .joined(separator: "\n")
                + "\n更新: \(formatTime(latest!.fetchedAt))"
            let codexTip = codexToolTipPart()
            button.toolTip = codexTip.isEmpty ? claudeTip : "\(claudeTip)\n\n\(codexTip)"
        } else if latestError != nil {
            button.title = "Claude !"
            button.toolTip = latestError
        } else {
            button.title = "Claude …"
            button.toolTip = "取得中"
        }
    }

    private func sortedClaudeTracks(_ tracks: [UsageTrack]) -> [UsageTrack] {
        let priority: [String] = ["5h", "5h Sonnet", "7d", "7d Sonnet", "7d Opus", "7d Haiku", "Extra"]
        return tracks.sorted { a, b in
            let ai = priority.firstIndex(of: a.label) ?? Int.max
            let bi = priority.firstIndex(of: b.label) ?? Int.max
            if ai != bi { return ai < bi }
            return a.remainingFraction < b.remainingFraction
        }
    }

    private func claudeHeaderTrack(from tracks: [UsageTrack]) -> UsageTrack? {
        let sorted = sortedClaudeTracks(tracks)
        return sorted.first(where: { $0.label.hasPrefix("5h") }) ?? sorted.first
    }

    private func codexTitlePart() -> String {
        guard let fiveHour = latestCodex?.fiveHour else { return "" }
        return " | Codex \(fiveHour.remainingPercent)%·\(shortReset(fiveHour))"
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

    @objc private func editTimeSettingsAction() {
        promptForTimeSettings()
    }

    @objc private func reloadClaudeOrganizationsAction() {
        loadClaudeOrganizations()
    }

    @objc private func selectClaudeOrganizationAction(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        config = config.withSelectedClaudeOrgUUID(uuid)
        config.save()
        latest = nil
        latestError = "Claude 取得中…"
        rebuildMenu()
        refreshClaude()
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

    @objc private func setSessionKeyAction() {
        promptForSessionKey(reason: "ブラウザの DevTools → Application → Cookies → claude.ai → sessionKey をコピーして貼り付けてください")
    }

    private func promptForSessionKey(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Claude sessionKey"
        alert.informativeText = reason
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "sk-ant-sid01-…"
        input.stringValue = KeychainHelper.load() ?? ""
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        let res = alert.runModal()
        if res == .alertFirstButtonReturn {
            let v = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                KeychainHelper.save(v)
                loadClaudeOrganizations()
                refreshClaude()
            }
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
                selectedClaudeOrgUUID: config.selectedClaudeOrgUUID
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

    private func loadClaudeOrganizations() {
        guard KeychainHelper.load()?.isEmpty == false else { return }
        latestClaudeOrganizationsError = nil
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let organizations = try await self.fetcher.fetchOrganizations()
                await MainActor.run {
                    self.latestClaudeOrganizations = organizations
                    self.latestClaudeOrganizationsError = nil
                    if self.config.selectedClaudeOrgUUID == nil, let first = organizations.first {
                        self.config = self.config.withSelectedClaudeOrgUUID(first.uuid)
                        self.config.save()
                    } else if let selected = self.config.selectedClaudeOrgUUID,
                              !organizations.contains(where: { $0.uuid == selected }),
                              let first = organizations.first {
                        self.config = self.config.withSelectedClaudeOrgUUID(first.uuid)
                        self.config.save()
                    }
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.latestClaudeOrganizationsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.rebuildMenu()
                }
            }
        }
    }

    private func refreshClaude(isAutomatic: Bool = false) {
        if isAutomatic && !isInAutoRefreshWindow() {
            latestError = "自動更新は JST \(config.autoRefreshWindowLabel) のみ"
            updateTitle()
            scheduleNextClaudeAutoRefresh()
            rebuildMenu()
            return
        }

        latestError = "Claude 取得中…"
        updateTitle()
        rebuildMenu()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let snap = try await self.fetcher.fetchUsage(preferredOrgUUID: self.config.selectedClaudeOrgUUID)
                await MainActor.run {
                    self.latest = snap
                    self.latestError = nil
                    self.updateTitle()
                    self.scheduleNextClaudeAutoRefresh()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.latestError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            updateTitle()
            scheduleNextCodexAutoRefresh()
            rebuildMenu()
            return
        }

        latestCodexError = "取得中…"
        updateTitle()
        rebuildMenu()

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let snap = try await self.codexFetcher.fetchUsage()
                await MainActor.run {
                    self.latestCodex = snap
                    self.latestCodexError = nil
                    self.updateTitle()
                    self.scheduleNextCodexAutoRefresh()
                    self.rebuildMenu()
                }
            } catch {
                await MainActor.run {
                    self.latestCodexError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    private func selectedClaudeOrgUUID() -> String? {
        config.selectedClaudeOrgUUID ?? latestClaudeOrganizations.first?.uuid
    }

    private func selectedClaudeOrganization() -> ClaudeOrganization? {
        guard let uuid = selectedClaudeOrgUUID() else { return nil }
        return latestClaudeOrganizations.first(where: { $0.uuid == uuid })
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

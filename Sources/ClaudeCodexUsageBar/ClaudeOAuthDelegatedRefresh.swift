import Foundation

/// 公式 Claude CLI の起動を許可する呼び出し種別。
///
/// 手動更新はユーザ操作そのものなので常に許可する。バックグラウンド起動は、
/// 設定がオンの時だけ使う（既定オン）。開始した CLI は自然終了まで待つ。
enum ClaudeAuthRefreshInteraction: Sendable {
    case disabled
    case background
    case userInitiated
}

/// Claude Code が所有する認証情報の読み取り専用ストア。
///
/// refresh token は解析も保持もしない。Claude CLI への委譲前後で access token や
/// 有効期限が変わったかを確認するため、通常取得と委譲コーディネータで共用する。
enum ClaudeOAuthCredentialReader {
    enum Revision: Equatable, Sendable {
        case file(modifiedAt: TimeInterval, size: UInt64, inode: UInt64)
        case keychain(service: String, account: String?, modificationMarker: String)
    }

    private static let keychainServices = ["Claude Code-credentials", "Claude Code"]

    static func load() -> ClaudeOAuthCredentials? {
        loadFromFile() ?? loadFromKeychain()
    }

    /// 現在実際に読み取り対象となる保存元の変更識別子。
    ///
    /// ファイルは属性だけ、Keychain は復号を伴わない `mdat` などのメタデータだけを見る。
    /// アクセストークンの復号は、この値が変化した後にだけ `load()` で1回行う。
    static func revision(
        credentialsURLOverride: URL? = nil,
        fileManager: FileManager = .default
    ) -> Revision? {
        let url = credentialsURLOverride ?? credentialsURL(fileManager: fileManager)
        if let data = try? Data(contentsOf: url), parse(data) != nil,
           let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        {
            let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64(data.count)
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            return .file(modifiedAt: modifiedAt, size: size, inode: inode)
        }

        for service in keychainServices {
            guard let metadata = SecurityCLI.genericPasswordMetadata(service: service) else { continue }
            return .keychain(
                service: service,
                account: metadata.account,
                modificationMarker: metadata.modificationMarker
            )
        }
        return nil
    }

    private static func credentialsURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private static func loadFromFile() -> ClaudeOAuthCredentials? {
        guard let data = try? Data(contentsOf: credentialsURL()) else { return nil }
        return parse(data)
    }

    private static func loadFromKeychain() -> ClaudeOAuthCredentials? {
        for service in keychainServices {
            // account は環境ごとに異なるため属性から拾い、見つからない場合は service だけで引く。
            let metadata = SecurityCLI.genericPasswordMetadata(service: service)
            guard let data = SecurityCLI.genericPassword(service: service, account: metadata?.account),
                  let credentials = parse(data)
            else { continue }
            return credentials
        }
        return nil
    }

    private static func parse(_ data: Data) -> ClaudeOAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty
        else { return nil }

        let expiresAt = numeric(oauth["expiresAt"])
            .map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: oauth["rateLimitTier"] as? String,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

/// 同時実行と再試行頻度を制御しながら、認証更新を公式 Claude CLI に委譲する。
actor ClaudeOAuthDelegatedRefreshCoordinator {
    static let shared = ClaudeOAuthDelegatedRefreshCoordinator()

    enum Outcome: Sendable {
        case refreshed(ClaudeOAuthCredentials)
        case skippedByCooldown
        case skippedByPolicy
        case cliUnavailable
        case loginRequired
        case inProgress
        case failed(String)

        var wasRefreshed: Bool {
            if case .refreshed = self { return true }
            return false
        }
    }

    private struct InFlight {
        let id: UInt64
        let interaction: ClaudeAuthRefreshInteraction
        let task: Task<Outcome, Never>
    }

    private let successCooldown: TimeInterval = 5 * 60
    private let failureCooldown: TimeInterval = 20
    private var lastAttemptAt: Date?
    private var cooldown: TimeInterval = 0
    private var inFlight: InFlight?
    private var nextAttemptID: UInt64 = 0

    func refresh(
        previousCredentials: ClaudeOAuthCredentials?,
        interaction: ClaudeAuthRefreshInteraction
    ) async -> Outcome {
        guard interaction != .disabled else { return .skippedByPolicy }

        if let current = inFlight {
            let retryAsUser = interaction == .userInitiated && current.interaction != .userInitiated
            let joined = await waitForResult(current)
            if case .inProgress = joined { return joined }
            if retryAsUser, !joined.wasRefreshed {
                return await refresh(previousCredentials: previousCredentials, interaction: interaction)
            }
            return joined
        }

        let now = Date()
        if interaction == .background,
           let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < cooldown
        {
            return .skippedByCooldown
        }

        guard let binary = ClaudeCLIResolver.resolve() else { return .cliUnavailable }

        nextAttemptID &+= 1
        let attemptID = nextAttemptID
        // 開始時点で予約することで、並行した自動更新が cooldown をすり抜けるのを防ぐ。
        lastAttemptAt = now
        cooldown = failureCooldown

        let task = Task.detached(priority: .utility) {
            let outcome = await Self.performRefresh(binary: binary, previousCredentials: previousCredentials)
            await self.finishAttempt(id: attemptID, outcome: outcome)
            return outcome
        }
        let current = InFlight(id: attemptID, interaction: interaction, task: task)
        inFlight = current

        return await waitForResult(current)
    }

    private func finishAttempt(id: UInt64, outcome: Outcome) {
        if inFlight?.id == id {
            inFlight = nil
            lastAttemptAt = Date()
            cooldown = outcome.wasRefreshed ? successCooldown : failureCooldown
        }
    }

    private func waitForResult(_ current: InFlight) async -> Outcome {
        // UI の待機だけを区切り、CLI は自然終了まで保持する。
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while inFlight?.id == current.id {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                return .inProgress
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return .inProgress
            }
        }
        return await current.task.value
    }

    private static func performRefresh(binary: String, previousCredentials: ClaudeOAuthCredentials?) async -> Outcome {
        // CLI 起動前に、復号を伴わない保存元のリビジョンだけを記録する。
        // 更新後のポーリングでもこのメタデータだけを比較し、変化した時に限り1回復号する。
        let initialRevision = ClaudeOAuthCredentialReader.revision()
        do {
            try ClaudeAuthCLIProbe.touchOAuthPath(binary: binary)
        } catch {
            return .failed(error.localizedDescription)
        }

        // CLI が終了しただけでは成功扱いにしない。最大 2 秒だけ保存元の変更を待ち、
        // 変更された認証情報を1回だけ復号して access token が実際に変わったか確認する。
        let deadline = Date().addingTimeInterval(2)
        var attemptedDecryption = false
        var lastDecryptedRevision: ClaudeOAuthCredentialReader.Revision?
        repeat {
            let currentRevision = ClaudeOAuthCredentialReader.revision()
            if currentRevision != initialRevision,
               !attemptedDecryption || currentRevision != lastDecryptedRevision
            {
                attemptedDecryption = true
                lastDecryptedRevision = currentRevision
                guard let credentials = ClaudeOAuthCredentialReader.load() else { return .loginRequired }
                if credentials != previousCredentials,
                   !credentials.isExpired
                {
                    return .refreshed(credentials)
                }
            }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return .failed("認証更新がキャンセルされました。")
            }
        } while Date() < deadline

        // 属性取得自体が利用できない環境だけは、互換性のため最後に1回だけ復号して確認する。
        // 通常の Keychain 経路では initialRevision が得られるため、ここには入らない。
        if initialRevision == nil, !attemptedDecryption,
           let credentials = ClaudeOAuthCredentialReader.load(),
           credentials != previousCredentials,
           !credentials.isExpired
        {
            return .refreshed(credentials)
        }

        return .failed("Claude CLI 実行後も認証情報が更新されませんでした。")
    }
}

/// GUI アプリではシェルの PATH が短いことがあるため、環境変数と代表的な配置先から探す。
enum ClaudeCLIResolver {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let override = environment["CLAUDE_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            candidates.append(override)
        }

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/claude" })
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.claude/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.asdf/shims/claude",
            "\(home)/.local/share/mise/shims/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])

        // nvm はバージョンごとのディレクトリに実体を置く。
        let nvmVersions = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/claude").path })
        }

        var seen = Set<String>()
        return candidates.first { candidate in
            let path = URL(fileURLWithPath: candidate).standardized.path
            guard seen.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0).standardized.path }
    }
}

/// 非対話 CLI に認証更新を委譲し、自然終了まで待つ。
///
/// 認証更新自体は数秒で終わるため、`hangTimeout` を超えて戻らない場合だけハングとみなして
/// SIGTERM を送り、それでも終了しなければ SIGKILL する。
enum ClaudeAuthCLIProbe {
    private static let hangTimeout: TimeInterval = 5 * 60
    private static let killGracePeriod: TimeInterval = 10

    enum ProbeError: LocalizedError {
        case launchFailed(String)
        case unsupportedVersion
        case processExited(Int32)
        case timedOut
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return "Claude CLI を起動できませんでした: \(message)"
            case .unsupportedVersion:
                return "自動認証更新には Claude Code 2.1.292 以降が必要です。ターミナルで `claude update` を実行してください。"
            case .processExited(let status):
                return "Claude CLI の使用量確認に失敗しました（終了コード \(status)）。ターミナルで `claude` の認証状態を確認してください。"
            case .timedOut:
                return "Claude CLI が \(Int(hangTimeout / 60)) 分以上応答しなかったため停止しました。ターミナルで `claude` を起動して状態を確認してください。"
            case .outputTooLarge:
                return "Claude CLI のバージョン出力が上限を超えました。"
            }
        }
    }

    // coordinator の detached task から実行し、UI のキャンセルでは停止しない。
    static func touchOAuthPath(binary: String) throws {
        let environment = ProcessInfo.processInfo.environment

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageBarAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var cliEnvironment = environment
        cliEnvironment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        cliEnvironment.removeValue(forKey: "CLAUDE_CODE_OAUTH_SCOPES")
        for key in cliEnvironment.keys where key.hasPrefix("ANTHROPIC_") {
            cliEnvironment.removeValue(forKey: key)
        }
        cliEnvironment["DISABLE_AUTOUPDATER"] = "1"
        cliEnvironment["PWD"] = directory.path
        cliEnvironment["PATH"] = enrichedPATH(binary: binary, environment: cliEnvironment)

        let version = try run(
            binary: binary,
            arguments: ["--version"],
            directory: directory,
            environment: cliEnvironment,
            captureVersion: true
        )
        guard supportsUsageCommand(version) else { throw ProbeError.unsupportedVersion }

        // safe-mode はカスタムコマンド・ユーザの hooks / MCP / skills を無効化する。
        // bare は OAuth 自体を無効化するため使わない。モデルに送る通常の質問も渡さない。
        _ = try run(
            binary: binary,
            arguments: [
                "--safe-mode", "--no-session-persistence", "--tools", "",
                "--output-format", "json", "-p", "/usage",
            ],
            directory: directory,
            environment: cliEnvironment,
            captureVersion: false
        )
    }

    /// 未確認の旧 CLI に `/usage` を渡さず、非対話コマンド対応の確認済みバージョンから使う。
    private static func supportsUsageCommand(_ output: String) -> Bool {
        guard let first = output.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        let parts = first.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return false }
        // メジャーバージョン変更時は動作確認をやり直す。
        return numbers[0] == 2 && (numbers[1] > 1 || (numbers[1] == 1 && numbers[2] >= 292))
    }

    private static func run(
        binary: String,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        captureVersion: Bool
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // パイプを EOF まで読むと、stdout を引き継いだ子孫プロセスが残る間は戻らない。
        // 一時ファイルに書かせ、直接起動したプロセスの終了後に先頭だけ読む。
        var output: FileHandle?
        if captureVersion {
            let url = directory.appendingPathComponent("version.txt")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forUpdating: url)
            else { throw ProbeError.launchFailed("出力ファイルを作成できませんでした。") }
            output = handle
        }
        defer { try? output?.close() }
        process.standardOutput = output ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProbeError.launchFailed(error.localizedDescription)
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGracePeriod) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + hangTimeout, execute: watchdog)
        defer { watchdog.cancel() }

        process.waitUntilExit()
        if ProcessInfo.processInfo.systemUptime - startedAt >= hangTimeout {
            throw ProbeError.timedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ProbeError.processExited(process.terminationStatus)
        }
        guard let output else { return "" }
        // バージョン出力だけ保持する。上限 + 1 バイトまで読み、超過を判定する。
        try? output.seek(toOffset: 0)
        let data = output.readData(ofLength: 4097)
        guard data.count <= 4096 else { throw ProbeError.outputTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private static func enrichedPATH(binary: String, environment: [String: String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        let entries = [
            URL(fileURLWithPath: binary).deletingLastPathComponent().path,
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}

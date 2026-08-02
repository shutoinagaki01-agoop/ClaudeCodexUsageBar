import Darwin
import Foundation

/// 公式 Claude CLI の起動を許可する呼び出し種別。
///
/// 手動更新はユーザ操作そのものなので常に許可する。バックグラウンド起動は、
/// Keychain の認可 UI が突然出る可能性があるため設定で明示的に許可された時だけ使う。
enum ClaudeAuthRefreshInteraction: Sendable {
    case disabled
    case background
    case userInitiated
}

enum ClaudeCLIOnboardingState: Sendable, Equatable {
    case completed
    case required
    case unknown
}

/// Claude CLI が初回セットアップ済みかを、Claude 所有の設定ファイルから読み取り専用で確認する。
/// 未完了のウィザードへ `/status` や Enter を送ると、意図しない選択を確定しかねない。
enum ClaudeCLIOnboardingProbe {
    static func state(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> ClaudeCLIOnboardingState {
        let url = accountConfigURL(
            environment: environment,
            workingDirectory: workingDirectory,
            fileManager: fileManager
        )
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // 設定ファイル自体が無い場合は、まだ CLI を対話起動していないと判断する。
            return fileManager.fileExists(atPath: url.path) ? .unknown : .required
        }
        guard let completed = root["hasCompletedOnboarding"] as? Bool else { return .unknown }
        return completed ? .completed : .required
    }

    private static func accountConfigURL(
        environment: [String: String],
        workingDirectory: URL?,
        fileManager: FileManager
    ) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            let root: URL
            if configured.hasPrefix("/") {
                root = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
            } else {
                let base = workingDirectory
                    ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                root = base.appendingPathComponent(configured, isDirectory: true).standardizedFileURL
            }
            let profileConfig = root.appendingPathComponent(".config.json")
            return fileManager.fileExists(atPath: profileConfig.path)
                ? profileConfig
                : root.appendingPathComponent(".claude.json")
        }

        let home: URL
        if let rawHome = environment["HOME"], !rawHome.isEmpty {
            home = URL(fileURLWithPath: rawHome, isDirectory: true)
        } else {
            home = fileManager.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent(".claude.json")
    }
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
        case onboardingRequired
        case loginRequired
        case manualInteractionRequired
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
            let joined = await current.task.value
            if retryAsUser, !joined.wasRefreshed {
                // 完了済み task を保持したまま再帰すると、元の呼び出し側が clear する前に
                // 同じ task へ再 join し続ける。ID が同じ時だけここで引き取って解放する。
                if inFlight?.id == current.id {
                    inFlight = nil
                    cooldown = failureCooldown
                }
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
            await Self.performRefresh(binary: binary, previousCredentials: previousCredentials)
        }
        inFlight = InFlight(id: attemptID, interaction: interaction, task: task)

        let outcome = await task.value
        if inFlight?.id == attemptID {
            inFlight = nil
            cooldown = outcome.wasRefreshed ? successCooldown : failureCooldown
        }
        return outcome
    }

    private static func performRefresh(binary: String, previousCredentials: ClaudeOAuthCredentials?) async -> Outcome {
        // CLI 起動前に、復号を伴わない保存元のリビジョンだけを記録する。
        // 更新後のポーリングでもこのメタデータだけを比較し、変化した時に限り1回復号する。
        let initialRevision = ClaudeOAuthCredentialReader.revision()
        do {
            try await ClaudeAuthPTYProbe.touchOAuthPath(binary: binary, timeout: 8)
        } catch ClaudeAuthPTYProbe.ProbeError.onboardingRequired {
            return .onboardingRequired
        } catch ClaudeAuthPTYProbe.ProbeError.loginRequired {
            return .loginRequired
        } catch ClaudeAuthPTYProbe.ProbeError.manualInteractionRequired {
            return .manualInteractionRequired
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
                if let credentials = ClaudeOAuthCredentialReader.load(),
                   credentials != previousCredentials,
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

/// Claude の対話 CLI を疑似端末上で起動し、`/status` を送って認証経路を通す。
/// 出力はプロンプト応答の判定にだけ使い、ログやファイルには保存しない。
enum ClaudeAuthPTYProbe {
    enum ProbeError: LocalizedError {
        case launchFailed(String)
        case onboardingRequired
        case loginRequired
        case manualInteractionRequired
        case processExited
        case ioFailed(String)
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): return "Claude CLI を起動できませんでした: \(message)"
            case .onboardingRequired:
                return "Claude CLI の初回設定が未完了です。ターミナルで `claude` を一度起動して設定を完了してください。"
            case .loginRequired:
                return "Claude CLI の再ログインが必要です。ターミナルで `claude auth login` を実行してください。"
            case .manualInteractionRequired:
                return "Claude CLI が対話操作を求めています。ターミナルで `claude` を起動して画面を確認してください。"
            case .processExited: return "Claude CLI が認証確認前に終了しました。"
            case .ioFailed(let message): return "Claude CLI の PTY 通信に失敗しました: \(message)"
            case .outputTooLarge: return "Claude CLI の出力が安全上限を超えました。"
            }
        }
    }

    private static let outputLimit = 1_048_576
    private static let outputReadPassLimit = 65_536
    private static let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
    private static let onboardingNeedles = [
        normalized("Welcome to Claude Code"),
        normalized("Choose the text style that looks best with your terminal"),
        normalized("Dark mode (colorblind-friendly)"),
        normalized("Light mode (colorblind-friendly)"),
    ]
    /// オンボーディング完了後でも、refresh token の失効・取り消しなどで表示される。
    /// この状態ではブラウザ認証へ進めず、ユーザ自身による `claude auth login` に委ねる。
    private static let loginNeedles = [
        normalized("Select login method:"),
        normalized("Paste code here if prompted"),
        normalized("Browser didn't open"),
        normalized("oauth/authorize"),
        normalized("Not logged"),
        normalized("Run claude auth login"),
        normalized("Please run /login"),
        normalized("OAuth token expired"),
        normalized("OAuth token revoked"),
    ]
    /// 意味を確定できない汎用プロンプトには、自動で Enter を送らない。
    private static let manualInteractionNeedles = [
        normalized("Press Enter to continue"),
    ]
    /// 通常の入力画面に固有の表示。未知の画面では `/status` 自体も送らず安全側に倒す。
    private static let normalReadyNeedles = [
        normalized("? for shortcuts"),
        normalized("Tips for getting started"),
    ]
    private static let promptResponses: [(needle: String, response: String)] = [
        (normalized("Do you trust the files in this folder?"), "y\r"),
        (normalized("Quick safety check:"), "\r"),
        (normalized("Yes, I trust this folder"), "\r"),
        (normalized("Ready to code here?"), "\r"),
        (normalized("Show Claude Code status"), "\r"),
        (normalized("Show Claude Code"), "\r"),
    ]

    static func touchOAuthPath(
        binary: String,
        timeout: TimeInterval,
        workingDirectoryOverride: URL? = nil,
        onboardingStateOverride: ClaudeCLIOnboardingState? = nil,
        environmentOverride: [String: String]? = nil
    ) async throws {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var window = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &window) == 0 else {
            throw ProbeError.launchFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        let process = Process()
        let workingDirectory: URL
        let sessionID: UUID
        if let workingDirectoryOverride {
            try FileManager.default.createDirectory(
                at: workingDirectoryOverride,
                withIntermediateDirectories: true
            )
            workingDirectory = workingDirectoryOverride
            sessionID = UUID()
        } else {
            let probeWorkspace = try ClaudeAuthProbeWorkspace.prepare()
            workingDirectory = probeWorkspace.directory
            sessionID = probeWorkspace.sessionID
        }

        let baseEnvironment = environmentOverride ?? ProcessInfo.processInfo.environment
        let onboardingState = onboardingStateOverride
            ?? ClaudeCLIOnboardingProbe.state(
                environment: baseEnvironment,
                workingDirectory: workingDirectory
            )
        guard onboardingState == .completed else { throw ProbeError.onboardingRequired }

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--allowed-tools", "",
            "--session-id", sessionID.uuidString.lowercased(),
        ]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle

        var environment = baseEnvironment
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_SCOPES")
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["PWD"] = workingDirectory.path
        environment["PATH"] = enrichedPATH(binary: binary, environment: environment)
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? primaryHandle.close()
            try? secondaryHandle.close()
            throw ProbeError.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        let processGroup: pid_t? = setpgid(pid, pid) == 0 ? pid : nil
        defer {
            // ウィザード検知による終了時もここを通るため、`/exit` などの文字列は送らない。
            // 入力先が通常画面だと確認できていない状態でキーを送る余地を残さない。
            if let processGroup {
                kill(-processGroup, SIGTERM)
            } else if process.isRunning {
                process.terminate()
            }
            let waitUntil = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < waitUntil { usleep(50_000) }
            if process.isRunning {
                if let processGroup {
                    kill(-processGroup, SIGKILL)
                } else {
                    kill(pid, SIGKILL)
                }
            }
            try? primaryHandle.close()
            try? secondaryHandle.close()
        }

        let start = Date()
        let commandAt = start.addingTimeInterval(2)
        let deadline = start.addingTimeInterval(max(3, timeout))
        var commandSent = false
        var scanData = Data()
        var totalOutput = 0
        var triggeredPrompts = Set<String>()
        var cursorQueryHandled = false
        var lastOutputAt = start
        var normalReadyObserved = false

        while Date() < deadline {
            // 累積上限を1バイト超えるところまでしか読まず、1回の読み取りも64KBで返す。
            // 子プロセスが書き続けても、この呼び出し内でメモリが無制限に増えない。
            let readBudget = min(outputReadPassLimit, outputLimit - totalOutput + 1)
            let chunk = try readAvailable(from: primaryFD, maxBytes: readBudget)
            if !chunk.isEmpty {
                lastOutputAt = Date()
                totalOutput += chunk.count
                guard totalOutput <= outputLimit else { throw ProbeError.outputTooLarge }

                scanData.append(chunk)
                if scanData.count > 32_768 { scanData = Data(scanData.suffix(32_768)) }
                let normalizedOutput = normalized(String(decoding: scanData, as: UTF8.self))
                if loginNeedles.contains(where: normalizedOutput.contains) {
                    throw ProbeError.loginRequired
                }
                if onboardingNeedles.contains(where: normalizedOutput.contains) {
                    throw ProbeError.onboardingRequired
                }
                if manualInteractionNeedles.contains(where: normalizedOutput.contains) {
                    throw ProbeError.manualInteractionRequired
                }
                if normalReadyNeedles.contains(where: normalizedOutput.contains) {
                    normalReadyObserved = true
                }
                if !cursorQueryHandled, scanData.range(of: cursorQuery) != nil {
                    try? write(Data("\u{1b}[1;1R".utf8), to: primaryFD)
                    cursorQueryHandled = true
                }
                for item in promptResponses where !triggeredPrompts.contains(item.needle) {
                    if normalizedOutput.contains(item.needle) {
                        try? write(Data(item.response.utf8), to: primaryFD)
                        triggeredPrompts.insert(item.needle)
                        // 2 つの command palette 表記は包含関係にあるため、1 回の表示で
                        // Enter を二重送信しないよう同じグループをまとめて処理済みにする。
                        if item.needle.hasPrefix("showclaudecode") {
                            for commandItem in promptResponses
                                where commandItem.needle.hasPrefix("showclaudecode")
                            {
                                triggeredPrompts.insert(commandItem.needle)
                            }
                        }
                        break
                    }
                }
            }

            let now = Date()
            // 通常画面を明示的に確認し、断片化した警告文を読み切れるだけの静穏時間を置く。
            // 未知の画面や安定しない TUI には `/status` 自体を送らず、安全側に倒す。
            if !commandSent,
               normalReadyObserved,
               now >= commandAt,
               now.timeIntervalSince(lastOutputAt) >= 0.5
            {
                try write(Data("/status\r".utf8), to: primaryFD)
                commandSent = true
            }

            guard process.isRunning else { throw ProbeError.processExited }
            try await Task.sleep(nanoseconds: 60_000_000)
        }

        guard commandSent else { throw ProbeError.manualInteractionRequired }
    }

    private static func readAvailable(from fd: Int32, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(min(maxBytes, 8192))
        while result.count < maxBytes {
            let requestSize = min(8192, maxBytes - result.count)
            var buffer = [UInt8](repeating: 0, count: requestSize)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            throw ProbeError.ioFailed(String(cString: strerror(errno)))
        }
        return result
    }

    private static func enrichedPATH(binary: String, environment: [String: String]) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var entries = [
            URL(fileURLWithPath: binary).deletingLastPathComponent().path,
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        entries.append(contentsOf: (environment["PATH"] ?? "").split(separator: ":").map(String.init))

        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            var retries = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                    retries = 0
                    continue
                }
                if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno), retries < 200 {
                    retries += 1
                    usleep(5_000)
                    continue
                }
                throw ProbeError.ioFailed(String(cString: strerror(errno)))
            }
        }
    }

    private static func normalized(_ text: String) -> String {
        let withoutANSI = text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        return withoutANSI.lowercased().filter { !$0.isWhitespace }
    }
}

/// 認証プローブ専用の作業ディレクトリと Claude セッション ID を管理する。
///
/// ID を固定すると、更新のたびに空の Claude セッションを増やさずに済む。一方、Claude CLI の
/// `--session-id` は同じ transcript が残っていると再作成に失敗するため、この専用ディレクトリに
/// 対応する前回の JSONL だけを起動前に削除する。ユーザのプロジェクトは対象にならない。
private enum ClaudeAuthProbeWorkspace {
    private static let sessionIDFilename = ".usagebar-session-id"

    struct Prepared {
        let directory: URL
        let sessionID: UUID
    }

    static func prepare(fileManager: FileManager = .default) throws -> Prepared {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base
            .appendingPathComponent("ClaudeCodexUsageBar", isDirectory: true)
            .appendingPathComponent("ClaudeAuthProbe", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let sessionID = loadOrCreateSessionID(in: directory, fileManager: fileManager)
        removePreviousProbeTranscripts(for: directory, fileManager: fileManager)
        return Prepared(directory: directory, sessionID: sessionID)
    }

    private static func loadOrCreateSessionID(in directory: URL, fileManager: FileManager) -> UUID {
        let url = directory.appendingPathComponent(sessionIDFilename)
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let existing = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return existing
        }

        let sessionID = UUID()
        do {
            try sessionID.uuidString.lowercased().write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            // 永続化できなくても今回のプローブは一意な ID で実行できる。
        }
        return sessionID
    }

    private static func removePreviousProbeTranscripts(
        for directory: URL,
        fileManager: FileManager
    ) {
        let projectName = claudeProjectDirectoryName(for: directory)
        for root in claudeConfigRoots(fileManager: fileManager) {
            let projectDirectory = root
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectName, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: projectDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "jsonl" {
                guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func claudeConfigRoots(fileManager: FileManager) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return }
            roots.append(standardized)
        }

        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            for part in configured.split(separator: ",") {
                let path = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { append(URL(fileURLWithPath: path)) }
            }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        append(home.appendingPathComponent(".claude", isDirectory: true))
        append(home.appendingPathComponent(".config/claude", isDirectory: true))
        return roots
    }

    private static func claudeProjectDirectoryName(for directory: URL) -> String {
        let path = directory.path.precomposedStringWithCanonicalMapping
        return String(path.utf16.map { codeUnit in
            switch codeUnit {
            case 48...57, 65...90, 97...122:
                return Character(UnicodeScalar(codeUnit)!)
            default:
                return "-"
            }
        })
    }
}

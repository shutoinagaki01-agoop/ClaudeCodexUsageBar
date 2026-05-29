import Foundation

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
    let peakRefreshEndHour: Int
    let autoRefreshTimeZone: TimeZone

    static func load() -> AppConfig {
        let env = EnvConfig.load()
        return AppConfig(
            peakRefreshInterval: env.timeInterval("PEAK_REFRESH_INTERVAL_SECONDS", default: 3 * 60),
            normalRefreshInterval: env.timeInterval("NORMAL_REFRESH_INTERVAL_SECONDS", default: 5 * 60),
            depletedFallbackRefreshInterval: env.timeInterval("DEPLETED_FALLBACK_REFRESH_INTERVAL_SECONDS", default: 60 * 60),
            resetRefreshBuffer: env.timeInterval("RESET_REFRESH_BUFFER_SECONDS", default: 60),
            autoRefreshStartHour: env.int("AUTO_REFRESH_START_HOUR", default: 9),
            autoRefreshStartMinute: env.int("AUTO_REFRESH_START_MINUTE", default: 30),
            autoRefreshEndHour: env.int("AUTO_REFRESH_END_HOUR", default: 21),
            autoRefreshEndMinute: env.int("AUTO_REFRESH_END_MINUTE", default: 0),
            peakRefreshStartHour: env.int("PEAK_REFRESH_START_HOUR", default: 11),
            peakRefreshEndHour: env.int("PEAK_REFRESH_END_HOUR", default: 16),
            autoRefreshTimeZone: TimeZone(identifier: env.string("AUTO_REFRESH_TIME_ZONE", default: "Asia/Tokyo"))
                ?? TimeZone(identifier: "Asia/Tokyo")!
        )
    }
}

struct EnvConfig {
    private let values: [String: String]

    static func load() -> EnvConfig {
        var values = readEnvFile()
        for (key, value) in ProcessInfo.processInfo.environment {
            values[key] = value
        }
        return EnvConfig(values: values)
    }

    func string(_ key: String, default defaultValue: String) -> String {
        values[key]?.isEmpty == false ? values[key]! : defaultValue
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        guard let raw = values[key], let value = Int(raw) else { return defaultValue }
        return value
    }

    func timeInterval(_ key: String, default defaultValue: TimeInterval) -> TimeInterval {
        guard let raw = values[key], let value = TimeInterval(raw) else { return defaultValue }
        return value
    }

    private static func readEnvFile() -> [String: String] {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        ].compactMap { $0 }

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return [:]
        }

        return parse(text)
    }

    private static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }

        return result
    }
}

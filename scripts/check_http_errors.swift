import Foundation

// swiftc Sources/ClaudeCodexUsageBar/Models.swift scripts/check_http_errors.swift -o /tmp/check_http_errors
// /tmp/check_http_errors
@main
struct HTTPErrorChecks {
    static func main() {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }

        let htmlBodies = [
            "<html>\n<head>\n<meta name=\"viewport\" content=\"width=device-width\" /><style global>body{font-family:system-ui}</style>",
            "\u{feff}  <!DOCTYPE HTML>\r\n<HTML><BODY>Forbidden</BODY></HTML>",
            "<!-- gateway error -->\n<html><body>Forbidden</body></html>",
        ]
        for body in htmlBodies {
            let error = FetchError.http(403, body)
            let message = error.localizedDescription
            check(message.contains("403"), "403 status retained")
            check(!message.contains("<") && !message.contains("font-family"), "HTML is hidden")
            check(!message.contains("\n") && !message.contains("\r"), "one menu line")
            check(error.recoveryHint != nil, "403 recovery hint")
            check(!error.isAuthExpired, "403 does not invalidate credentials")
        }
        let gateway = FetchError.http(502, "<html><body>Bad gateway</body></html>").localizedDescription
        check(gateway.contains("502") && !gateway.contains("<"), "other HTML errors")
        let json = FetchError.http(400, "{\n  \"error\": \"invalid_request\"\n}").localizedDescription
        check(json.contains("invalid_request") && !json.contains("\n"), "JSON detail kept on one line")
        check(FetchError.http(503, " \r\n ").localizedDescription == "HTTP 503", "empty body")
        let long = FetchError.http(500, String(repeating: "a", count: 500)).localizedDescription
        check(long.count <= 135, "long errors are bounded")
        check(FetchError.codexAuthExpired.isAuthExpired, "401 recovery behavior preserved")
        check(FetchError.codexAuthExpired.recoveryHint?.contains("codex") == true, "Codex auth hint preserved")
        if !failures.isEmpty {
            print("FAIL: " + failures.joined(separator: ", "))
            exit(1)
        }
        print("PASS: HTML errors, single-line details, bounds, recovery hints, and auth classification")
    }
}

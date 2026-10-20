import Foundation

// swiftc Sources/ClaudeCodexUsageBar/{Models,AppConfig,UsageFetcher,ClaudeOAuthDelegatedRefresh,ClaudeLimitReset}.swift scripts/check_claude_reset.swift -o /tmp/check_claude_reset
// /tmp/check_claude_reset
private final class ResetURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, json) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@main
struct ClaudeResetChecks {
    static let organizationID = "00000000-0000-0000-0000-000000000001"
    static let auth = ClaudeOAuthCredentials(
        accessToken: "test-token", expiresAt: .distantFuture, scopes: ["user:profile"],
        rateLimitTier: nil, subscriptionType: nil
    )
    static let grantJSON: [String: Any] = [
        "id": "test_grant", "resets_left": 2, "resets_total": 2,
        "starts_at": "2026-01-01T00:00:00Z", "ends_at": "2099-01-01T00:00:00.000000Z",
        "clears": ["five_hour", "seven_day"], "paused": false, "usable_now": true,
    ]
    static func root(grant: [String: Any] = grantJSON, overrides: [String: Any] = [:]) -> [String: Any] {
        var status: [String: Any] = ["eligible": true, "grants": [grant], "next_grant_id": "test_grant"]
        status.merge(overrides) { _, new in new }
        return ["cedar_ember": status]
    }

    static func main() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        let status = ClaudeResetStatus.decode(from: root())!
        let grant = status.usableGrant(at: now)!
        precondition(grant.limitsLabel == "5h / 7d")
        precondition(status.remainingGrants(at: now).map(\.resetsLeft) == [2])
        precondition(status.remainingCount(at: now) == 2)
        // 実際の surface 拒否応答。Webの無料リセットの有無はこの応答では分からない。
        let surfaceRejected = ClaudeResetStatus.decode(from: root(overrides: [
            "eligible": false, "ineligible_reason": "surface",
            "grants": [], "next_grant_id": NSNull(),
        ]))!
        precondition(surfaceRejected.remainingGrants(at: now).isEmpty)
        precondition(surfaceRejected.remainingCount(at: now) == nil)
        precondition(surfaceRejected.usableGrant(at: now) == nil)
        let knownEmpty = ClaudeResetStatus.decode(from: root(overrides: [
            "grants": [], "next_grant_id": NSNull(),
        ]))!
        precondition(knownEmpty.remainingCount(at: now) == 0)
        precondition(ClaudeResetStatus.decode(from: [:]) == nil)
        precondition(ClaudeResetStatus.decode(from: ["cedar_ember": NSNull()]) == nil)
        precondition(ClaudeResetStatus.decode(from: ["cedar_ember": "bad"]) == nil)
        precondition(ClaudeResetStatus.decode(from: root(overrides: ["eligible": false]))?.usableGrant(at: now) == nil)
        precondition(ClaudeResetStatus.decode(from: root(overrides: ["next_grant_id": "other"]))?.usableGrant(at: now) == nil)
        precondition(ClaudeResetStatus.decode(from: root(overrides: ["cooldown_until": "2099-01-01T00:00:00Z"]))?.usableGrant(at: now) == nil)
        precondition(ClaudeResetStatus.decode(from: root(overrides: ["grants": [grantJSON, grantJSON]])) == nil)
        for (key, value) in [
            ("ends_at", "2026-10-20T00:00:00Z" as Any),
            ("starts_at", "2099-01-01T00:00:00Z" as Any),
            ("paused", true), ("usable_now", false), ("resets_left", 0),
            ("id", "../bad"), ("clears", [] as [String]),
        ] {
            var changed = grantJSON
            changed[key] = value
            precondition(ClaudeResetStatus.decode(from: root(grant: changed))?.usableGrant(at: now) == nil, key)
        }
        for (key, value) in [("resets_left", -1 as Any), ("ends_at", "invalid"), ("usable_now", "true")] {
            var changed = grantJSON
            changed[key] = value
            precondition(ClaudeResetStatus.decode(from: root(grant: changed)) == nil, key)
        }
        var requiresLimit = grantJSON
        requiresLimit["use_requires_limit"] = true
        precondition(ClaudeResetStatus.decode(from: root(grant: requiresLimit, overrides: ["at_limit": false]))!.usableGrant(at: now) == nil)
        precondition(ClaudeResetStatus.decode(from: root(grant: requiresLimit, overrides: ["at_limit": true]))!.usableGrant(at: now) != nil)
        var overage = grantJSON
        overage["clears"] = ["five_hour", "seven_day", "seven_day_overage_included"]
        precondition(ClaudeResetStatus.decode(from: root(grant: overage))!.usableGrant(at: now)!.limitsLabel == "5h / 7d / 7d Fable")
        var noExpiry = grantJSON
        noExpiry["ends_at"] = NSNull()
        precondition(ClaudeResetStatus.decode(from: root(grant: noExpiry))!.usableGrant(at: now) != nil)

        let suite = "ClaudeResetChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func client() -> ClaudeLimitReset {
            ClaudeLimitReset(session: session, defaults: defaults, credentials: { auth })
        }
        var posts = 0
        var calls = 0
        var requestIDs: [String] = []
        var outcome = "reset"
        var failPost = false
        var preflight = root()
        var profileCode = 200
        ResetURLProtocol.handler = { request in
            calls += 1
            precondition(request.url!.host == "api.anthropic.com")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            precondition(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.292 (external, cli)")
            precondition(request.value(forHTTPHeaderField: "x-app") == "cli")
            switch request.url!.path {
            case "/api/oauth/profile":
                return (profileCode, ["organization": ["uuid": organizationID]])
            case "/api/oauth/usage":
                precondition(request.url!.query == "cedar_ember=1&skip_spend=1")
                return (200, preflight)
            case "/api/organizations/\(organizationID)/reset_rate_limits":
                precondition(request.httpMethod == "POST")
                posts += 1
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: String]
                precondition(Set(body.keys) == ["program", "grant_id", "request_id"])
                precondition(body["program"] == "cedar_ember" && body["grant_id"] == grant.id)
                precondition(UUID(uuidString: body["request_id"]!) != nil)
                requestIDs.append(body["request_id"]!)
                if failPost { throw URLError(.timedOut) }
                return (200, ["result": outcome])
            default:
                preconditionFailure("Unexpected request")
            }
        }
        func expectFailure(_ action: () async throws -> Void) async {
            do {
                try await action()
                preconditionFailure("Expected failure")
            } catch {}
        }
        await expectFailure { try await client().consume(grant: grant, credentialDigest: "changed-account") }
        precondition(calls == 0)
        for code in [401, 403, 429] {
            profileCode = code
            await expectFailure { try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest) }
            precondition(posts == 0)
        }
        profileCode = 200
        preflight = root(overrides: ["eligible": false])
        await expectFailure { try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest) }
        precondition(posts == 0)
        preflight = root()
        try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest)
        precondition(posts == 1)
        precondition(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("claudeLimitReset.pending.") }.isEmpty)

        // Timeout does not trigger another POST; a recreated client reuses the persisted ID.
        failPost = true
        await expectFailure { try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest) }
        precondition(posts == 2)
        failPost = false
        outcome = "already_used"
        preflight = root(overrides: ["grants": [], "next_grant_id": NSNull()])
        try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest)
        precondition(posts == 3 && requestIDs[1] == requestIDs[2] && requestIDs[0] != requestIDs[1])
        preflight = root()
        outcome = "unavailable"
        await expectFailure { try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest) }
        outcome = "unexpected"
        await expectFailure { try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest) }
        precondition(posts == 5 && requestIDs[3] == requestIDs[4])
        outcome = "not_limited"
        await expectFailure { try await client().consume(grant: grant, credentialDigest: auth.accessTokenDigest) }
        precondition(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("claudeLimitReset.pending.") }.isEmpty)
        print("PASS: Claude reset CLI headers, parsing, use_requires_limit, expiry, eligibility, auth changes, HTTP errors, preflight, consume payload, success, and persisted idempotency after timeout")
    }
}

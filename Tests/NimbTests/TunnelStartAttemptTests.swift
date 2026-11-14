import Foundation
import Testing
@testable import Nimb

@Suite @MainActor struct TunnelStartAttemptTests {
    private func folder() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }
    @Test func cancellingBeforeAuthorizationPreventsALateStart() async throws {
        let attempt = try TunnelStartAttempt(), f = try folder()
        defer { attempt.remove(); try? FileManager.default.removeItem(at: f) }
        try attempt.cancel()
        let launched = f.appendingPathComponent("started").path
        let result = await TunnelStartAttempt.perform {
            try DNSManager.run("/bin/sh", ["-c", attempt.script(up: "/usr/bin/touch '\(launched)'", down: "true")], timeout: 3)
        }
        #expect(TunnelStartAttempt.cancellationWasClean(result))
        #expect(!FileManager.default.fileExists(atPath: launched))
    }
    @Test(arguments: [false, true]) func cancellingABlockedStartKillsItAndRunsCleanup(viaAppleScript: Bool) async throws {
        let attempt = try TunnelStartAttempt(), f = try folder()
        defer { attempt.remove(); try? FileManager.default.removeItem(at: f) }
        let helper = f.appendingPathComponent("helper.sh")
        let started = f.appendingPathComponent("started").path, cleaned = f.appendingPathComponent("cleaned").path
        try "#!/bin/sh\ntouch '\(started)'\nsleep 30\ntouch '\(f.path)/late-success'\n".write(to: helper, atomically: true, encoding: .utf8)
        let script = attempt.script(up: "/bin/sh '\(helper.path)'", down: "/usr/bin/touch '\(cleaned)'")
        let task = Task { await TunnelStartAttempt.perform {
            if viaAppleScript {
                return try DNSManager.run("/usr/bin/osascript", ["-e", DNSManager.appleScript(running: script, privileged: false)], timeout: 5)
            }
            return try DNSManager.run("/bin/sh", ["-c", script], timeout: 5)
        } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: started))
        let stop = Date()
        try attempt.cancel()
        #expect(TunnelStartAttempt.cancellationWasClean(await task.value))
        #expect(Date().timeIntervalSince(stop) < 2)
        #expect(FileManager.default.fileExists(atPath: cleaned))
        #expect(!FileManager.default.fileExists(atPath: f.path + "/late-success"))
    }
    @Test func anUnresponsiveStartHasAnOverallDeadline() async throws {
        let attempt = try TunnelStartAttempt(), f = try folder()
        defer { attempt.remove(); try? FileManager.default.removeItem(at: f) }
        let cleaned = f.appendingPathComponent("cleaned").path
        let start = Date()
        let result = await TunnelStartAttempt.perform {
            try DNSManager.run("/bin/sh", ["-c", attempt.script(up: "/bin/sleep 30", down: "/usr/bin/touch '\(cleaned)'", timeout: 1)], timeout: 5)
        }
        if case .success = result { Issue.record("Startup deadline was ignored") }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(FileManager.default.fileExists(atPath: cleaned))
    }
    @Test func successDoesNotRunStopOrLeavePreparationFiles() async throws {
        let attempt = try TunnelStartAttempt(), f = try folder()
        defer { attempt.remove(); try? FileManager.default.removeItem(at: f) }
        let stage = f.appendingPathComponent("stage").path
        let stopped = f.appendingPathComponent("stop").path
        let result = await TunnelStartAttempt.perform {
            try DNSManager.run("/bin/sh", ["-c", attempt.script(up: "/usr/bin/true", down: "/usr/bin/touch '\(stopped)'", preparation: ["stage='\(stage)'", "mkdir \"$stage\""])], timeout: 3)
        }
        _ = try result.get()
        #expect(!FileManager.default.fileExists(atPath: stage))
        #expect(!FileManager.default.fileExists(atPath: stopped))
    }
}

@Suite @MainActor struct TunnelPreparationCancellationTests {
    @Test func cancellationFinishesAnInstallationButNeverStartsTheTunnelAfterIt() async throws {
        let attempt = try TunnelStartAttempt()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { attempt.remove(); try? FileManager.default.removeItem(at: folder) }
        let preparing = folder.appendingPathComponent("preparing").path
        let ready = folder.appendingPathComponent("ready").path
        let started = folder.appendingPathComponent("started").path
        let task = Task { await TunnelStartAttempt.perform {
            try DNSManager.run("/bin/sh", ["-c", attempt.script(up: "/usr/bin/touch '\(started)'", down: "true", preparation: ["touch '\(preparing)'", "sleep 0.4", "touch '\(ready)'"])], timeout: 4)
        } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: preparing) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: preparing))
        try attempt.cancel()
        #expect(TunnelStartAttempt.cancellationWasClean(await task.value))
        #expect(FileManager.default.fileExists(atPath: ready))
        #expect(!FileManager.default.fileExists(atPath: started))
    }
}

@testable import LizardCore
import Foundation
import Synchronization
import Testing

@Suite struct ProcessRunnerTests {
    @Test func capturesMergedOutputAndExitCode() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
    }

    @Test func resolvesToolsThroughEnvAndStreamsLines() async throws {
        let lines = Mutex<[String]>([])
        let result = try await ProcessRunner.run("printf", ["a\\nb\\nc"], onLine: { line in lines.withLock { $0.append(line) } })
        #expect(result.succeeded)
        #expect(lines.withLock { $0 } == ["a", "b", "c"])  // the unterminated last line is flushed too
    }

    @Test func passesEnvironmentAndWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo $LIZARD_TEST_VALUE; pwd"], cwd: directory, environment: ["LIZARD_TEST_VALUE": "gecko"])
        let output = result.output.split(separator: "\n").map(String.init)
        #expect(output.first == "gecko")
        #expect(output.last.map { URL(filePath: $0).resolvingSymlinksInPath().path } == directory.path)
    }

    @Test func timesOut() async {
        let start = Date()
        await #expect(throws: ProcessError.self) { try await ProcessRunner.run("/bin/sleep", ["5"], timeout: .milliseconds(200)) }
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func quickCommandsWithLongTimeoutsReturnPromptly() async throws {
        let start = Date()
        _ = try await ProcessRunner.run("/usr/bin/true", timeout: .seconds(600))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func launchFailuresAndCheckedRuns() async {
        await #expect(throws: ProcessError.self) { try await ProcessRunner.run("/nonexistent/tool") }
        do {
            try await ProcessRunner.runChecked("/bin/sh", ["-c", "echo nope; exit 2"])
            Issue.record("expected a failure")
        } catch let error as ProcessError {
            #expect(error.errorDescription?.contains("exited with 2") == true)
            #expect(error.errorDescription?.contains("nope") == true)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func cancellationStopsTheProcess() async throws {
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["5"]) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        let result = try await task.value
        #expect(!result.succeeded)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func backgroundProcesses() async throws {
        let exited = Mutex<Int32?>(nil)
        let lines = Mutex<[String]>([])
        let process = try ProcessRunner.launch(
            "/bin/sh", ["-c", "echo started; sleep 5"], onLine: { line in lines.withLock { $0.append(line) } },
            onExit: { code in exited.withLock { $0 = code } })
        #expect(process.isRunning)
        #expect(process.processIdentifier > 0)
        process.terminate()
        for _ in 0..<50 where exited.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(exited.withLock { $0 } != nil)
        #expect(!process.isRunning)
        #expect(throws: ProcessError.self) { try ProcessRunner.launch("/nonexistent", onLine: { _ in }) }
    }

    @Test func tailKeepsTheLastLines() {
        let result = CommandResult(exitCode: 0, output: "1\n2\n3\n4")
        #expect(result.tail(2) == "3\n4")
        #expect(result.tail(10) == "1\n2\n3\n4")
        #expect(ProcessError.timedOut("x").errorDescription == "`x` timed out")
    }
}

@Suite struct ResilientFileTests {
    @Test func keepsABackupAndRestoresFromIt() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "resilient-\(UUID()).json")
        try ResilientFile.write(Data("1".utf8), to: url)
        try ResilientFile.write(Data("2".utf8), to: url)
        #expect(try String(contentsOf: ResilientFile.backupURL(url), encoding: .utf8) == "1")
        // Corrupt the main file: the backup is used and put back, the damaged copy kept.
        try Data("garbage".utf8).write(to: url)
        let value = ResilientFile.read(url) { data -> Int in
            guard let number = Int(String(decoding: data, as: UTF8.self)) else { throw CocoaError(.coderReadCorrupt) }
            return number
        }
        #expect(value == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "1")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("damaged").path))
    }

    @Test func missingFilesReadAsNil() {
        let url = FileManager.default.temporaryDirectory.appending(path: "absent-\(UUID()).json")
        #expect(ResilientFile.read(url) { $0 } == nil)
    }
}

@Suite struct EnvironmentAndPathsTests {
    @Test func toolEnvironment() {
        let environment = ToolEnvironment.shared.environment(merging: ["EXTRA": "1", "PATH": "/custom"])
        #expect(environment["EXTRA"] == "1")
        #expect(environment["PATH"] == "/custom")  // explicit values win
        #expect(ToolEnvironment.shared.environment()["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(ToolEnvironment.shared.which("ls") == "/bin/ls")
        #expect(ToolEnvironment.shared.which("definitely-not-a-tool-\(UUID())") == nil)
        #expect(Set(ToolEnvironment.shared.searchPath).count == ToolEnvironment.shared.searchPath.count)
    }

    @Test func logRingKeepsTheNewest() {
        let ring = LogRing(capacity: 3)
        for index in 0..<5 { ring.append(LogLine(source: "t", text: "\(index)")) }
        #expect(ring.recent(10).map(\.text) == ["2", "3", "4"])
        #expect(ring.recent(1).map(\.text) == ["4"])
    }

    @Test func portsAndDisk() throws {
        let port = PortFinder.freePort(preferring: 0)
        #expect(port >= 0)
        let ephemeral = try #require(PortFinder.bindEphemeral())
        #expect(ephemeral > 1024)
        #expect(PortFinder.isFree(ephemeral))
        let directory = AppPaths.ensure(FileManager.default.temporaryDirectory.appending(path: "disk-\(UUID())", directoryHint: .isDirectory))
        try Data(count: 10_000).write(to: directory.appending(path: "f"))
        #expect(DiskUsage.bytes(at: directory) >= 10_000)
        #expect(DiskUsage.freeBytes() > 0)
        #expect(DiskUsage.canFit(0, reserve: 0))
    }

    @Test func githubDeviceCodeLines() {
        #expect(GitHubCLI.deviceCode(in: "! First copy your one-time code: AB12-CD34") == "AB12-CD34")
        #expect(GitHubCLI.deviceCode(in: "! One-time code (WXYZ-1234) copied to clipboard") == "WXYZ-1234")
        #expect(GitHubCLI.deviceCode(in: "Press Enter to open github.com in your browser...") == nil)
        #expect(GitHubCLI.deviceCode(in: "commit ABCD-EFGH") == nil)  // no "code" word
        #expect(GitHubCLI.deviceURL(in: "Open https://github.com/login/device?x=1 now").absoluteString == "https://github.com/login/device?x=1")
        #expect(GitHubCLI.deviceURL(in: "nothing").absoluteString == "https://github.com/login/device")
    }

    @Test func githubEnvironment() {
        let plain = GitHubCLI.environment(managed: false)
        #expect(plain["GH_PROMPT_DISABLED"] == "1")
        #expect(plain["GH_CONFIG_DIR"] == nil)
        #expect(GitHubCLI.managedExecutable.path.hasSuffix(".lizard/gh/bin/gh"))
        #expect(GitHubCLI.CLIError.failed("x").errorDescription?.contains("x") == true)
        #expect(GitHubCLI.Status(executable: "/gh", username: nil, isManaged: true).isSignedIn == false)
    }
}

@Suite struct ResourcePolicyTests {
    static let gb: UInt64 = 1_073_741_824
    let mac = HardwareProfile(chip: "M9", memoryBytes: 32 * gb, performanceCores: 8, efficiencyCores: 4, gpuBudgetBytes: 24 * gb)

    @Test func limitsFollowTheMode() {
        let efficient = ResourcePolicy(profile: mac, mode: .efficient)
        let performance = ResourcePolicy(profile: mac, mode: .performance)
        #expect(efficient.mlxMemoryLimitBytes < performance.mlxMemoryLimitBytes)
        #expect(efficient.buildJobs == 4)
        #expect(performance.buildJobs == 12)
        #expect(efficient.modelIdleUnload == .seconds(120))
        #expect(performance.modelIdleUnload == nil)
        #expect(ResourcePolicy(profile: mac, mode: .balanced).backgroundAppLimit == 1)
        #expect(efficient.containerCPUs >= 1)
        #expect(efficient.containerMemoryMB > 0)
        #expect(efficient.previewInterval > performance.previewInterval)
        #expect(efficient.gradleHeapMB < performance.gradleHeapMB)
    }

    @Test func profileSummary() {
        #expect(mac.totalCores == 12)
        #expect(mac.memoryGB == 32)
        #expect(mac.gpuBudgetGB == 24)
        #expect(mac.summary == "M9 · 32 GB memory · 12 cores (8P + 4E)")
        #expect(HardwareProfile.current.memoryBytes > 0)
        #expect(PerformanceMode.allCases.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty })
        #expect(SystemMetrics.processFootprintBytes() > 0)
        #expect(SystemMetrics.availableBytes() > 0)
    }
}

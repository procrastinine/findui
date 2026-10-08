import Foundation
import Darwin

package struct CodexSearchStatus: Codable, Sendable {
    package let executable: String?
    package let available: Bool
    package let message: String
    package init(executable: String?, available: Bool, message: String) {
        self.executable = executable; self.available = available; self.message = message
    }
}

/// Codex owns login storage and refresh. FindUI never reads auth.json, copies an
/// OAuth token, or sends a Codex credential to a user-configurable API URL.
package struct CodexSearchClient: AISearchGenerating {
    package let settings: AISearchSettings
    package init(settings: AISearchSettings) { self.settings = settings }
    package static func locate(preferred: String = "") -> URL? {
        if !preferred.isEmpty {
            let path = (preferred as NSString).expandingTildeInPath
            return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path, isDirectory: false) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0, isDirectory: false) }
    }
    package static func status(preferred: String = "") async -> CodexSearchStatus {
        guard let executable = locate(preferred: preferred) else { return .init(executable: nil, available: false, message: "Codex wasn’t found. Install Codex or choose its executable.") }
        do {
            let help = try await AICommandProcess.run(executable, arguments: ["exec", "--help"], timeout: 10)
            let supported = ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--output-last-message"].allSatisfy { help.stdout.contains($0) }
            guard help.exitCode == 0, supported else { return .init(executable: executable.path, available: false, message: "Update Codex: this version lacks isolated structured requests.") }
            let login = try await AICommandProcess.run(executable, arguments: ["login", "status"], timeout: 10)
            let output = (login.stdout + login.stderr).lowercased()
            let loggedIn = login.exitCode == 0 && output.contains("logged in") && output.contains("chatgpt")
            return .init(executable: executable.path, available: loggedIn, message: loggedIn
                ? "ChatGPT login detected. FindUI will reuse it through Codex."
                : "No ChatGPT login detected. Run codex login, then check again.")
        } catch is CancellationError { return .init(executable: executable.path, available: false, message: "Check cancelled.") }
        catch { return .init(executable: executable.path, available: false, message: "Couldn’t check Codex. Verify that its executable runs.") }
    }
    package static var isolatedConfiguration: [String] {
        ["approval_policy=\"never\"", "web_search=\"disabled\"", "project_doc_max_bytes=0",
         "skills.include_instructions=false", "tools.update_plan.enabled=false", "tools.experimental_request_user_input.enabled=false",
         "features.shell_tool=false", "features.unified_exec=false", "features.code_mode=false", "features.code_mode_host=false",
         "features.apps=false", "features.plugins=false", "features.remote_plugin=false", "features.hooks=false",
         "features.memories=false", "features.skill_search=false", "features.skip_host_skill_discovery=true",
         "features.multi_agent=false", "features.browser_use=false", "features.in_app_browser=false",
         "features.computer_use=false", "features.image_generation=false", "features.view_image=false",
         "features.goals=false", "features.tool_suggest=false", "features.sleep_tool=false",
         "features.unbounded_connection_retries=false", "features.shell_snapshot=false"]
    }
    package static func instructionsConfiguration(_ path: String) throws -> String {
        // TOML does not accept JSON's optional \/ escape. Keep slash characters
        // literal while still escaping quotes, backslashes and control bytes.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return "model_instructions_file=" + String(decoding: try encoder.encode(path), as: UTF8.self)
    }
    package static func validateEvents(_ output: String) throws {
        var completed = false
        for line in output.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            // Codex represents startup warnings as error items too. They are
            // diagnostics, not tool operations; require a successful turn below.
            if let item = event["item"] as? [String: Any], let type = item["type"] as? String,
               !["agent_message", "reasoning", "error"].contains(type) {
                throw AISearchError.message("Codex attempted an operation outside search generation. The proposal was discarded.")
            }
            if event["type"] as? String == "turn.failed" || event["type"] as? String == "error" {
                throw AISearchError.message("Codex did not finish generating the search.")
            }
            completed = completed || event["type"] as? String == "turn.completed"
        }
        guard completed else { throw AISearchError.message("Codex did not confirm a completed response.") }
    }
    package func generate(messages: [AISearchMessage], schema: Data) async throws -> String {
        let status = await Self.status(preferred: settings.codexPath)
        try Task.checkCancellation()
        guard status.available, let path = status.executable else { throw AISearchError.message(status.message) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("findui-ai-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appendingPathComponent("result.json")
        let promptFile = directory.appendingPathComponent("prompt.txt"), instructionsFile = directory.appendingPathComponent("instructions.txt")
        try Data("You translate search descriptions into a JSON search expression. No tools, file access, or commands are needed or permitted. Follow the supplied schema and return only the final JSON.\n".utf8).write(to: instructionsFile)
        let prompt = messages.map { "\($0.role.uppercased()):\n\($0.content)" }.joined(separator: "\n\n")
            + "\n\nRequired JSON schema (including every nested rule shape):\n" + String(decoding: schema, as: UTF8.self)
        try Data(prompt.utf8).write(to: promptFile)
        // Native recursive-schema constraints produced semantically unrelated
        // allLines nodes in live compound-query tests. Keep the complete grammar
        // in the prompt and validate it locally, with the service's bounded repair.
        var args = ["exec", "--strict-config", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
            "--color", "never", "--json", "--cd", directory.path, "--output-last-message", outputFile.path]
        for config in Self.isolatedConfiguration { args += ["-c", config] }
        args += ["-c", try Self.instructionsConfiguration(instructionsFile.path)]
        if !settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--model", settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)] }
        args.append("-")
        let result = try await AICommandProcess.run(URL(fileURLWithPath: path, isDirectory: false), arguments: args, input: promptFile, timeout: 180)
        guard result.exitCode == 0 else { throw AISearchError.message("Codex couldn’t generate the search. Check its ChatGPT login, selected model, and connection; update Codex if needed.") }
        // A tool event is a protocol violation, even if a future Codex version
        // changes its defaults. Such a response can never become a search.
        try Self.validateEvents(result.stdout)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputFile.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 256 * 1024 else { throw AISearchError.message("Codex returned an oversized search.") }
        return try String(contentsOf: outputFile, encoding: .utf8)
    }
}

/// Bounded, cancellable subprocess transport with literal argv, private stdin,
/// a process group, and no shell. Kept independent from GUI lifecycle code.
package final class AICommandProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var group: pid_t?
    private var stopped = false
    private var timedOut = false
    private let stdout = Pipe(), stderr = Pipe()
    private func stop(timeout: Bool = false) {
        lock.withLock {
            stopped = true; timedOut = timedOut || timeout
            if let group { kill(-group, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.withLock { if let group { kill(-group, SIGKILL) } }
        }
    }
    package static func run(_ executable: URL, arguments: [String], input: URL? = nil, timeout: Double) async throws -> ProcessExecution {
        let session = AICommandProcess()
        return try await withTaskCancellationHandler {
            try session.start(executable, arguments: arguments, input: input)
            let timer = Task { try await Task.sleep(for: .seconds(timeout)); session.stop(timeout: true) }
            defer { timer.cancel(); session.lock.withLock { session.group = nil } }
            async let out = session.read(session.stdout.fileHandleForReading)
            async let err = session.read(session.stderr.fileHandleForReading)
            let status = await session.wait()
            let output = try await (out, err)
            try Task.checkCancellation()
            if session.lock.withLock({ session.timedOut }) { throw AISearchError.message("The AI request timed out. Try again.") }
            return ProcessExecution(stdout: output.0, stderr: output.1, exitCode: status)
        } onCancel: { session.stop() }
    }
    private func start(_ executable: URL, arguments: [String], input: URL?) throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw AISearchError.message("Couldn’t initialize Codex.") }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, input?.path ?? "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            for pipe in [stdout, stderr] {
                posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
                posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
            }
            // Reuse only Codex's stored login, never ambient API credentials.
            var environment = ProcessInfo.processInfo.environment
            for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID",
                        "OPENAI_IDENTITY_TOKEN_FILE", "OPENAI_AUDIENCE", "CODEX_THREAD_ID", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] { environment.removeValue(forKey: key) }
            let strings = ([executable.path] + arguments).map { strdup($0) }
            let env = environment.map { strdup("\($0.key)=\($0.value)") }
            defer { strings.forEach { free($0) }; env.forEach { free($0) } }
            var argv = strings + [nil], envp = env + [nil], pid: pid_t = 0
            let result = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
            guard result == 0 else { throw AISearchError.message("Couldn’t launch Codex (\(result)).") }
            group = pid
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        }
    }
    private func wait() async -> Int32 {
        let pid = lock.withLock { group! }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var raw: Int32 = 0, result: pid_t
                repeat { result = waitpid(pid, &raw, 0) } while result < 0 && errno == EINTR
                continuation.resume(returning: result < 0 ? 2 : raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f))
            }
        }
    }
    private func read(_ handle: FileHandle) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { try? handle.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; continuation.resume(throwing: AISearchError.message("Couldn’t read the Codex response.")); stop(); return }
                    guard data.count + count <= 2 * 1024 * 1024 else {
                        stop(); continuation.resume(throwing: AISearchError.message("Codex returned too much output.")); return
                    }
                    data.append(contentsOf: buffer.prefix(count))
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

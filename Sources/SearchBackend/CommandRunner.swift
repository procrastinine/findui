import Foundation
import Darwin

package struct ProcessExecution: Sendable {
    package let stdout: String
    package let stderr: String
    package let exitCode: Int32
    package var stoppedEarly = false
    package init(stdout: String, stderr: String, exitCode: Int32, stoppedEarly: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.stoppedEarly = stoppedEarly
    }

}

package enum ProcessRunner {
    /// CLI-only: once planning is finished, a non-transforming relay adds no
    /// value. Replace this process so the tool owns stdout, signals and status.
    package static func replace(with spec: CommandSpec, pathOverride: String? = nil) throws -> Never {
        if let directory = spec.workingDirectory, chdir(directory.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        var environment = ProcessInfo.processInfo.environment
        if let pathOverride { environment["PATH"] = pathOverride }
        let args = ([spec.executable.path] + spec.arguments).map { strdup($0) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var argv = args + [nil], envp = env + [nil]
        _ = execve(spec.executable.path, &argv, &envp)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// A chunked CLI relay for rg's JSON envelope. There is no GUI materializing
    /// rows here, so do not decode and re-encode every snippet and submatch.
    package static func relayRipgrep(_ spec: CommandSpec, pathOverride: String, collectStatistics: Bool = false) async throws -> ProcessExecution {
        let session = ProcessSession(spec: spec, path: pathOverride)
        return try await withTaskCancellationHandler {
            try session.start()
            async let stderr = readDiagnostics(session.stderr.fileHandleForReading)
            let input = session.stdout.fileHandleForReading
            defer { try? input.close() }
            do {
                let match = Data(#"{"type":"match","#.utf8)
                let auxiliary = ["begin", "end", "summary"].map { Data((#"{"type":""# + $0 + #"","#).utf8) }
                var pending = Data()
                var statistics = ""
                while let chunk = try await readChunk(input), !chunk.isEmpty {
                    try Task.checkCancellation()
                    pending.append(chunk)
                    var first = 0, output = Data()
                    try pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        guard let base = bytes.baseAddress else { return }
                        try match.withUnsafeBytes { (prefix: UnsafeRawBufferPointer) in
                            var runStart: Int?
                            while let newline = memchr(base.advanced(by: first), 10, bytes.count - first) {
                                let end = base.distance(to: UnsafeRawPointer(newline))
                                let isMatch = end - first >= prefix.count && memcmp(base.advanced(by: first), prefix.baseAddress!, prefix.count) == 0
                                if isMatch { if runStart == nil { runStart = first } }
                                else {
                                    if let start = runStart { output.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: first - start); runStart = nil }
                                    let row = pending[first..<end]
                                    if !auxiliary.contains(where: { row.starts(with: $0) }) || (collectStatistics && row.starts(with: auxiliary[2])) {
                                        // rg's final summary has a different key order.
                                        guard let object = try JSONSerialization.jsonObject(with: row) as? [String: Any],
                                              let kind = object["type"] as? String else {
                                            throw SearchServiceError.commandFailed("Unexpected ripgrep result envelope.")
                                        }
                                        if kind == "match" { output.append(row); output.append(10) }
                                        else if kind == "summary", collectStatistics,
                                                let data = object["data"] as? [String: Any] {
                                            let payload = try JSONSerialization.data(withJSONObject: ["engine": "ripgrep", "data": data], options: .sortedKeys)
                                            statistics = "findui-stats: " + String(decoding: payload, as: UTF8.self) + "\n"
                                        }
                                        else if !["begin", "end", "summary"].contains(kind) {
                                            throw SearchServiceError.commandFailed("Unknown ripgrep result envelope.")
                                        }
                                    }
                                }
                                first = end + 1
                            }
                            if let start = runStart { output.append(base.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: first - start) }
                        }
                    }
                    if first != pending.startIndex { pending = Data(pending[first...]) }
                    guard pending.count <= 64 * 1024 * 1024 else { throw SearchServiceError.commandFailed("A search result exceeds the 64 MB record limit.") }
                    if !output.isEmpty { try FileHandle.standardOutput.write(contentsOf: output) }
                }
                guard pending.isEmpty else { throw SearchServiceError.commandFailed("Incomplete ripgrep result record.") }
                let status = await session.waitForExit()
                let diagnostics = try await stderr
                try Task.checkCancellation()
                return ProcessExecution(stdout: "", stderr: diagnostics + (diagnostics.isEmpty || diagnostics.hasSuffix("\n") ? "" : "\n") + statistics, exitCode: status)
            } catch {
                session.stop(); _ = await session.waitForExit(); _ = try? await stderr
                throw error
            }
        } onCancel: { session.stop() }
    }
    package static func run(spec: CommandSpec, pathOverride: String) async throws -> ProcessExecution {
        let session = ProcessSession(spec: spec, path: pathOverride)
        return try await withTaskCancellationHandler {
            try session.start()
            async let stdout = readAll(session.stdout.fileHandleForReading)
            async let stderr = readDiagnostics(session.stderr.fileHandleForReading)
            let status = await session.waitForExit()
            let output = try await (stdout, stderr)
            try Task.checkCancellation()
            return ProcessExecution(stdout: output.0, stderr: output.1, exitCode: status)
        } onCancel: {
            session.stop()
        }
    }

    /// Unstructured command output has no record separator or UTF-8 guarantee.
    /// Preserve bytes here; presentation owns decoding and bounded retention.
    package static func streamBytes(
        spec: CommandSpec, pathOverride: String,
        onChunk: @Sendable @escaping (Data) async throws -> Void
    ) async throws -> ProcessExecution {
        let session = ProcessSession(spec: spec, path: pathOverride)
        return try await withTaskCancellationHandler {
            try session.start()
            async let stderr = readDiagnostics(session.stderr.fileHandleForReading)
            let handle = session.stdout.fileHandleForReading
            defer { try? handle.close() }
            do {
                while let data = try await readChunk(handle), !data.isEmpty {
                    try Task.checkCancellation()
                    try await onChunk(data)
                }
                let status = await session.waitForExit()
                let diagnostics = try await stderr
                try Task.checkCancellation()
                return ProcessExecution(stdout: "", stderr: diagnostics, exitCode: status)
            } catch {
                session.stop()
                _ = await session.waitForExit()
                _ = try? await stderr
                throw error
            }
        } onCancel: { session.stop() }
    }

    /// Returning false stops the producer after a caller has enough results.
    package static func stream(
        spec: CommandSpec,
        pathOverride: String,
        separator: UInt8 = 10,
        onLine: @Sendable @escaping (String) async throws -> Bool
    ) async throws -> ProcessExecution {
        let session = ProcessSession(spec: spec, path: pathOverride)
        return try await withTaskCancellationHandler {
            try session.start()
            async let stderr = readDiagnostics(session.stderr.fileHandleForReading)
            let handle = session.stdout.fileHandleForReading
            defer { try? handle.close() }
            var stoppedEarly = false
            do {
                var record = Data()
                while let data = try await readChunk(handle), !data.isEmpty {
                    try Task.checkCancellation()
                    record.append(data)
                    var first = record.startIndex
                    while let end = record[first...].firstIndex(of: separator) {
                        guard end - first <= 64 * 1024 * 1024 else { throw SearchServiceError.commandFailed("A search result exceeds the 64 MB record limit.") }
                        guard let text = String(data: record[first..<end], encoding: .utf8) else {
                            throw SearchServiceError.commandFailed("The search tool returned a path or record that is not UTF-8.")
                        }
                        if try await !onLine(text) {
                            stoppedEarly = true; session.stop(); break
                        }
                        first = record.index(after: end)
                    }
                    if stoppedEarly { break }
                    if first != record.startIndex { record = Data(record[first...]) }
                    guard record.count <= 64 * 1024 * 1024 else { throw SearchServiceError.commandFailed("A search result exceeds the 64 MB record limit.") }
                }
                if !stoppedEarly, !record.isEmpty {
                    guard let text = String(data: record, encoding: .utf8) else { throw SearchServiceError.commandFailed("The search tool returned a path or record that is not UTF-8.") }
                    stoppedEarly = try await !onLine(text)
                    if stoppedEarly { session.stop() }
                }
                let status = await session.waitForExit()
                let errorOutput = try await stderr
                try Task.checkCancellation()
                return ProcessExecution(stdout: "", stderr: errorOutput, exitCode: status, stoppedEarly: stoppedEarly)
            } catch {
                session.stop()
                _ = await session.waitForExit()
                _ = try? await stderr
                throw error
            }
        } onCancel: {
            session.stop()
        }
    }

    /// Drain stderr completely while bounding resident diagnostics. Preserve the
    /// beginning for context and the end for the structured completion record.
    private static func readDiagnostics(_ handle: FileHandle) async throws -> String {
        defer { try? handle.close() }
        let limit = 512 * 1024
        var first = Data(), last = Data(), omitted = false
        while let chunk = try await readChunk(handle), !chunk.isEmpty {
            let count = min(limit - first.count, chunk.count)
            first.append(chunk.prefix(count)); last.append(chunk.dropFirst(count))
            if last.count > limit { last = Data(last.suffix(limit)); omitted = true }
        }
        if omitted {
            first.append(Data("\n[Additional search diagnostics omitted]\n".utf8))
            if let newline = last.firstIndex(of: 10) { last = Data(last.suffix(from: last.index(after: newline))) }
        }
        first.append(last)
        return String(decoding: first, as: UTF8.self)
    }

    private static func readChunk(_ handle: FileHandle) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // FileHandle.read(upToCount:) can wait for the entire requested
                // length on a pipe. A single read returns the bytes available now.
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                var count: Int
                repeat { count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
                if count < 0 { continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
                else { continuation.resume(returning: count == 0 ? nil : Data(bytes.prefix(count))) }
            }
        }
    }

    // Blocking pipe reads run on Dispatch queues, never on the Swift cooperative executor.
    private static func readAll(_ handle: FileHandle) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? handle.close() }
                do {
                    let data = try handle.readToEnd() ?? Data()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// posix_spawn preserves exact UTF-8 argv bytes and creates the cancellation
/// group atomically. No shell or interpreter starts for a native command.
private final class ProcessSession: @unchecked Sendable {
    let stdout = Pipe()
    let stderr = Pipe()
    private let spec: CommandSpec
    private let path: String
    private let lock = NSLock()
    private var stopped = false
    private var processGroup: pid_t?
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(spec: CommandSpec, path: String) { self.spec = spec; self.path = path }
    func start() throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
                throw SearchServiceError.launchFailed("Cannot initialize search process.")
            }
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
            if let directory = spec.workingDirectory {
                let status = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
                guard status == 0 else { throw SearchServiceError.launchFailed("Cannot use command folder: \(directory.path)") }
            }
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            for fd in [stdout.fileHandleForReading.fileDescriptor, stdout.fileHandleForWriting.fileDescriptor,
                       stderr.fileHandleForReading.fileDescriptor, stderr.fileHandleForWriting.fileDescriptor] {
                posix_spawn_file_actions_addclose(&actions, fd)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            for key in ["RIPGREP_CONFIG_PATH", "FZF_DEFAULT_OPTS", "FZF_DEFAULT_OPTS_FILE", "FZF_DEFAULT_COMMAND"] { environment.removeValue(forKey: key) }
            let strings = ([spec.executable.path] + spec.arguments).map { strdup($0) }
            let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
            defer { strings.forEach { free($0) }; env.forEach { free($0) } }
            var argv = strings + [nil], envp = env + [nil]
            var pid: pid_t = 0
            let status = spec.executable.path.withCString { executable in
                posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
            }
            guard status == 0 else {
                throw SearchServiceError.launchFailed("Failed to launch \(spec.executable.lastPathComponent): \(String(cString: strerror(status)))")
            }
            processGroup = pid
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            let child = pid
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var raw: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(child, &raw, 0) } while result < 0 && errno == EINTR
                let code = result < 0 ? Int32(2) : raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                finish(code)
            }
        }
    }
    func stop() {
        let group = lock.withLock { () -> pid_t? in
            stopped = true
            if let processGroup { kill(-processGroup, SIGTERM) }
            return processGroup
        }
        if let group {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
            }
        }
    }
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let exitCode { continuation.resume(returning: exitCode) }
                else { waiters.append(continuation) }
            }
        }
    }
    private func finish(_ status: Int32) {
        let pending = lock.withLock {
            exitCode = status
            let pending = waiters; waiters.removeAll(); return pending
        }
        pending.forEach { $0.resume(returning: status) }
    }
}

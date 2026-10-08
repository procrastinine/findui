import Foundation

public struct ToolCapabilities: Codable, Hashable, Sendable {
    public var fd: String?
    public var rg: String?
    public var rgPCRE2 = false
    public var fzf: String?
    public var find: String?
    public var mdfind: String?
    public var worker: String?
    public init() {}
}

public struct Invocation: Codable, Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var unsetEnvironment: [String]
    public var emptyExitCodes: [Int32]
    public var workingDirectory: String? = nil
    public init(_ executable: String, _ arguments: [String] = [], emptyExitCodes: [Int32] = []) {
        self.executable = executable; self.arguments = arguments
        self.environment = [:]; self.unsetEnvironment = []; self.emptyExitCodes = emptyExitCodes
    }
    public var shell: String {
        var words: [String] = []
        if !environment.isEmpty || !unsetEnvironment.isEmpty {
            words += ["/usr/bin/env"] + unsetEnvironment.flatMap { ["-u", $0] }
            words += environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        words += [executable] + arguments
        let command = words.map(quoteShellArgument).joined(separator: " ")
        return workingDirectory.map { "(cd -- " + quoteShellArgument($0) + " && " + command + ")" } ?? command
    }
}

/// A pipeline's data contract is independent of its rendering. Properties are
/// explicit so rewrites never need to inspect command text or count strings.
public struct PlanStage: Codable, Hashable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case enumerate, filter, rank, scan, queryIndex, admit, select, render, command
    }
    public var operation: Operation
    public var invocation: Invocation
    public var input: StreamFormat?
    public var output: StreamFormat
    public var preservesOrder: Bool
    public var label: String
    public init(_ operation: Operation, _ invocation: Invocation, input: StreamFormat? = nil,
                output: StreamFormat, preservesOrder: Bool = true, label: String) {
        self.operation = operation; self.invocation = invocation; self.input = input
        self.output = output; self.preservesOrder = preservesOrder; self.label = label
    }
}
public struct ExecutionPlan: Codable, Hashable, Sendable {
    public var version = 1
    public let query: SearchQuery
    public let stages: [PlanStage]
    public let reasons: [String]
    public let resourceBudget: ResourceBudget
    public init(query: SearchQuery, stages: [PlanStage], reasons: [String] = []) throws {
        guard !stages.isEmpty else { throw PlanningError.invalid("An execution plan cannot be empty.") }
        for (previous, next) in zip(stages, stages.dropFirst()) {
            guard previous.output == next.input else { throw PlanningError.invalid("Incompatible search stream types.") }
        }
        let commandText = stages.count == 1 && stages[0].operation == .command && stages[0].output == .text
        guard commandText || stages.last?.output == query.output else { throw PlanningError.invalid("Search output does not match the requested result unit.") }
        self.query = query; self.stages = stages; self.reasons = reasons
        self.resourceBudget = ResourceBudget(workers: query.options.workers)
    }
    public var output: StreamFormat { stages.last!.output }
    public var direct: Invocation? { stages.count == 1 ? stages[0].invocation : nil }
    public var engineName: String { stages.map(\.label).joined(separator: " → ") }
    public var invocation: Invocation {
        if let direct { return direct }
        // Exit 1 means no matches only for stages whose declared contract says
        // so. A converter/worker failure never becomes an empty result set.
        let body = stages.map { stage -> String in
            let call = stage.invocation.shell
            guard !stage.invocation.emptyExitCodes.isEmpty else { return call }
            let cases = stage.invocation.emptyExitCodes.map(String.init).joined(separator: "|")
            return "( \(call); status=$?; case $status in \(cases)) exit 0;; *) exit $status;; esac )"
        }.joined(separator: " |\n")
        return Invocation("/bin/bash", ["--noprofile", "--norc", "-c", "set -o pipefail\n" + body])
    }
    public var command: String { invocation.shell }
}

public struct ResourceBudget: Codable, Hashable, Sendable {
    public let workers: Int
    public let conversionWorkers: Int
    public let memoryBytes: Int
    public init(workers: Int) {
        self.workers = workers
        conversionWorkers = min(workers == 0 ? 4 : max(1, workers), 4)
        memoryBytes = 64 * 1024 * 1024
    }
    public var effectiveWorkers: Int {
        workers == 0 ? min(ProcessInfo.processInfo.activeProcessorCount, 12) : workers
    }
    public func allocation(stages: Int) -> [Int] {
        let total = effectiveWorkers
        guard stages > 0 else { return [] }
        // Pipelined stages may need one runnable producer each. The planner
        // uses a fused worker when that would exceed an explicit budget.
        return (0..<stages).map { max(1, total / stages + ($0 < total % stages ? 1 : 0)) }
    }
}

public func quoteShellArgument(_ value: String) -> String {
    if value.isEmpty { return "''" }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._:=@")
    if value.unicodeScalars.allSatisfy(allowed.contains) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func encodeSearchJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

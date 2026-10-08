import SearchBackend
import Foundation
import SearchCore

// Measures preparation in isolation, without launching a search or the GUI.
// Use the release-optimized build made by benchmark_startup.sh.
@main enum StartupBenchmark {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { return }
        let payload = Data(CommandLine.arguments[1].utf8)
        var records = [[String: Double]]()
        for _ in 0..<101 {
            var record = [String: Double]()
            func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
                let start = DispatchTime.now().uptimeNanoseconds
                let value = try body()
                record[name] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                return value
            }
            let request = try measure("decode") {
                let description = try JSONDecoder().decode(HeadlessCLI.SearchDescription.self, from: payload)
                return SearchRequest(state: description.state, referenceDate: description.referenceDate)
            }
            let tools = measure("tool_discovery") { Toolchain.resolve(for: request) }
            var query = try measure("normalize_validate") { try request.normalizedQuery() }
            measure("reader_options") { tools.resolveReaders(in: &query) }
            let pipeline = try measure("planning") { try SearchPipelineCompiler(tools: tools).compile(query) }
            let script = measure("render_command") { pipeline.script }
            let path = measure("execution_path") { tools.searchPath }
            guard !script.isEmpty, !path.isEmpty else { fatalError("Missing command") }
            records.append(record)
        }
        print(String(decoding: try JSONEncoder().encode(records), as: UTF8.self))
    }
}

import AppKit
import Foundation

// focus-bench <group> [--json FILE] [--fixtures DIR]      group: a key of `groups` below
// focus-bench report --out MD --unit-log LOG --unit-status N --lint FILE --app STATUS JSON...
// Unattended: never requests a permission; a check that needs one reports "skip" with the reason.

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

/// The group table. Adding a group = one row here (+ one line in scripts/bench.sh).
/// `appKit`: the group needs a running AppKit event loop (NSEvent monitors, Carbon hot keys, AX observers).
let groups: [String: (appKit: Bool, run: @MainActor () async -> [BenchResult])] = [
    "engine": (false, { EngineBench.run() }),
    "vision": (false, { VisionBench.run(fixtures: option("--fixtures") ?? "Tests/GazeKitTests/Fixtures") }),
    "ax": (true, { await LiveAXBench.run() }),
]

func finish(_ results: [BenchResult], json: String?) -> Never {
    for r in results { print("[\(r.status.rawValue)] \(r.group) / \(r.name) \(r.metrics) \(r.reason ?? "")") }
    if let json {
        do { try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: json)) }
        catch { FileHandle.standardError.write(Data("cannot write \(json): \(error)\n".utf8)) }
    }
    exit(Int32(min(results.filter { $0.status == .fail }.count, 255)))
}

if let name = args.first, let group = groups[name] {
    Task { @MainActor in finish(await group.run(), json: option("--json")) }
    if group.appKit {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    } else {
        dispatchMain()
    }
} else if args.first == "report" {
    let jsons = args.dropFirst().filter { $0.hasSuffix(".json") }
    exit(Report.write(out: option("--out") ?? "build/bench/report.md", unitLog: option("--unit-log") ?? "",
                      unitStatus: Int32(option("--unit-status") ?? "1") ?? 1, lint: option("--lint") ?? "",
                      app: option("--app") ?? "skip:not run", jsons: Array(jsons)))
} else {
    FileHandle.standardError.write(Data("usage: focus-bench \(groups.keys.sorted().joined(separator: "|"))|report …\n".utf8))
    exit(64)
}

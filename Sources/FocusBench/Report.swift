import Foundation

/// One bench check. Every group returns `[BenchResult]`; the report groups rows by `group`.
struct BenchResult: Codable {
    enum Status: String, Codable { case pass, fail, skip }
    var group: String
    var name: String
    var status: Status
    var reason: String? = nil
    /// Must be finite: JSONEncoder refuses NaN/infinity (use -1 for "never").
    var metrics: [String: Double] = [:]
    /// Human-readable pass rule, e.g. "p95 < 500 ms".
    var rule: String? = nil

    static func check(_ group: String, _ name: String, _ ok: Bool, rule: String, metrics: [String: Double] = [:],
                      reason: String? = nil) -> BenchResult {
        BenchResult(group: group, name: name, status: ok ? .pass : .fail, reason: ok ? nil : reason, metrics: metrics, rule: rule)
    }
    static func skip(_ group: String, _ name: String, _ reason: String) -> BenchResult {
        BenchResult(group: group, name: name, status: .skip, reason: reason)
    }
}

extension BenchResult {
    /// Group labels by number, so the report orders and names groups the same whoever writes the row.
    static let groupNames = [0: "0 no-prompt lint", 1: "1 unit", 2: "2 engine", 3: "3 vision", 4: "4 live AX", 5: "5 app smoke"]

    /// `detail` is kept on pass too (it carries the measured value).
    init(group: Int, name: String, passed: Bool, detail: String) {
        self.init(group: Self.groupNames[group] ?? "\(group)", name: name, status: passed ? .pass : .fail, reason: detail)
    }
    static func skipped(group: Int, name: String, reason: String) -> BenchResult {
        .skip(groupNames[group] ?? "\(group)", name, reason)
    }
}

enum Report {
    /// Markdown report of every group; returns the number of failures (the script's exit code).
    static func write(out: String, unitLog: String, unitStatus: Int32, lint: String, app: String,
                      jsons: [String]) -> Int32 {
        let g = BenchResult.groupNames
        var results: [BenchResult] = []
        // A missing lint file means the grep never ran: that proves nothing, so it fails too.
        if let text = try? String(contentsOfFile: lint, encoding: .utf8) {
            let hits = text.split(separator: "\n")
            results.append(.check(g[0]!, "no permission request in tests/benches", hits.isEmpty,
                                  rule: "no match", reason: hits.prefix(5).joined(separator: "; ")))
        } else {
            results.append(.check(g[0]!, "no permission request in tests/benches", false, rule: "no match",
                                  reason: "lint not run (\(lint) missing)"))
        }
        let log = (try? String(contentsOfFile: unitLog, encoding: .utf8)) ?? ""
        let counts = log.matches(of: /Test run with (\d+) tests/).compactMap { Double($0.1) }
        results.append(.check(g[1]!, "swift test", unitStatus == 0, rule: "exit 0",
                              metrics: Dictionary(uniqueKeysWithValues: counts.enumerated().map { ("bundle\($0.offset + 1)", $0.element) }),
                              reason: "see unit.log"))
        for path in jsons {
            guard let data = FileManager.default.contents(atPath: path),
                  let r = try? JSONDecoder().decode([BenchResult].self, from: data) else {
                results.append(.check(URL(fileURLWithPath: path).lastPathComponent, "results readable", false,
                                      rule: "valid JSON", reason: "missing or unreadable: the group crashed or the build failed (build.log)"))
                continue
            }
            results += r
        }
        if app.hasPrefix("skip") { results.append(.skip(g[5]!, "build-app + --selftest", String(app.dropFirst(5)))) }
        else { results.append(.check(g[5]!, "build-app + --selftest", app == "pass", rule: "exit 0", reason: "see app.log")) }

        let fails = results.filter { $0.status == .fail }.count
        var md = "# Bench report\n\n\(Date().formatted()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        md += "**\(results.filter { $0.status == .pass }.count) pass · \(fails) fail · \(results.filter { $0.status == .skip }.count) skip**\n\n"
        var seen = Set<String>()
        for group in results.map(\.group) where seen.insert(group).inserted {
            md += "## \(group)\n\n| check | status | metrics | rule | reason |\n|---|---|---|---|---|\n"
            for r in results where r.group == group {
                let m = r.metrics.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4g", $0.value))" }.joined(separator: " ")
                let cells = [r.name, r.status.rawValue, m, r.rule ?? "", r.reason ?? ""]
                    .map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                md += "| \(cells.joined(separator: " | ")) |\n"
            }
            md += "\n"
        }
        try? md.write(toFile: out, atomically: true, encoding: .utf8)
        print(md)
        return Int32(min(fails, 255))
    }
}

import Foundation

/// One JSON file per setup. Unreadable files are renamed `.broken` so the rest still loads.
public struct SetupStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func loadAll() -> [Setup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            if let data = try? Data(contentsOf: url), let setup = try? JSONDecoder().decode(Setup.self, from: data) {
                return setup
            }
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("broken"))
            return nil
        }
    }

    public func save(_ setup: Setup) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(setup).write(to: url(for: setup.id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}

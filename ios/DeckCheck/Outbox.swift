import Foundation
import Combine

/// The durable, visible outbox (spec §5.4). Every confirmed card is written here the
/// instant it's confirmed, before it counts as entered; entries survive
/// app-close/crash and leave only once the Sheet write is acknowledged.
@MainActor
final class Outbox: ObservableObject {
    @Published private(set) var pending: [OutboxOp] = []
    @Published private(set) var isFlushing = false
    @Published var lastError: String?

    private let fileURL: URL

    init() {
        let dir = Self.supportDir()
        fileURL = dir.appendingPathComponent("outbox.json")
        load()
    }

    var count: Int { pending.count }

    func enqueue(_ op: OutboxOp) {
        pending.append(op)
        save()
    }

    /// Discard all pending ops without sending them. Used to recover from a bad
    /// state (e.g. ops that already reached the Sheet but weren't acknowledged).
    func clear() {
        pending.removeAll()
        lastError = nil
        save()
    }

    /// Flush pending ops via the active backend (`apply` returns the acked op ids);
    /// drop acknowledged entries. Failures stay queued for the next flush. The
    /// backend is injected as a closure so this works against either the v1 Apps
    /// Script client or the v2 direct Sheets API (§5).
    func flush(apply: ([OutboxOp]) async throws -> Set<String>) async {
        guard !pending.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let batch = pending
        do {
            let acked = try await apply(batch)
            pending.removeAll { acked.contains($0.id) }
            save()
            lastError = nil
        } catch {
            lastError = "\(error)"   // stay queued, retry later
        }
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let ops = try? JSONDecoder().decode([OutboxOp].self, from: data) else { return }
        pending = ops
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func supportDir() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

import Foundation
import Network
import UIKit

/// Downloads your whole collection's thumbnails ahead of time, so Cards is instant
/// and works with no signal.
///
/// This is cheap in a way that's worth stating: card art is ~11 KB a thumbnail and
/// served `immutable, max-age=1y`, so a 1,000-card collection is ~11 MB fetched once
/// and never again. The image cache is sized for it (256 MB on disk). What makes it a
/// feature rather than a one-liner is that it should happen when the person chooses,
/// on a connection they're happy to spend — not silently on cellular.
///
/// Only list thumbnails are warmed, not full art: the hero image is ~36 KB, so warming
/// both would triple the download for a screen most cards never reach. The detail view
/// already shows the cached thumbnail blurred underneath while the full art loads.
@MainActor
final class CollectionArtWarmer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(warmed: Int, missed: Int)
        /// Not started, with the reason — currently only "you asked for Wi-Fi only".
        case blocked(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    @Published private(set) var phase: Phase = .idle

    private var job: Task<Void, Never>?

    /// How many downloads are in flight. Card art is small; the point of a cap is to
    /// leave the connection responsive for whatever else the person is doing, not to
    /// protect the server.
    private static let concurrency = 6

    /// Warm `urlStrings` at list-thumbnail size. `wifiOnly` refuses to start on an
    /// expensive (cellular/hotspot) or constrained (Low Data Mode) connection rather
    /// than spending someone's data plan without being asked.
    func start(urlStrings: [String], wifiOnly: Bool) {
        guard !phase.isRunning else { return }

        if wifiOnly, let reason = Self.expensiveConnectionReason() {
            phase = .blocked(reason)
            return
        }

        let urls = Array(Set(urlStrings.compactMap(URL.init(string:))))
        guard !urls.isEmpty else {
            phase = .finished(warmed: 0, missed: 0)
            return
        }

        phase = .running(done: 0, total: urls.count)
        job = Task { [weak self] in
            var done = 0, warmed = 0
            await withTaskGroup(of: Bool.self) { group in
                var next = urls.makeIterator()
                func addOne() {
                    guard let url = next.next() else { return }
                    group.addTask(priority: .utility) {
                        await CardImageLoader.shared.image(for: url, size: CardArtSize.listThumb) != nil
                    }
                }
                for _ in 0..<Self.concurrency { addOne() }

                while let ok = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    done += 1
                    if ok { warmed += 1 }
                    await self?.report(done: done, total: urls.count)
                    addOne()
                }
            }
            await self?.finish(warmed: warmed, missed: done - warmed, cancelled: Task.isCancelled)
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
    }

    private func report(done: Int, total: Int) {
        guard phase.isRunning else { return }
        phase = .running(done: done, total: total)
    }

    private func finish(warmed: Int, missed: Int, cancelled: Bool) {
        job = nil
        // A cancelled run still warmed whatever it got through — those bytes are cached
        // and the next run skips them, so report it as progress rather than as nothing.
        phase = .finished(warmed: warmed, missed: cancelled ? 0 : missed)
    }

    /// nil when the current connection is fine to download over; otherwise why not.
    /// A one-shot read of the current path — this gates a button press, so there's
    /// nothing to keep monitoring.
    private static func expensiveConnectionReason() -> String? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "art-warm-path")
        let semaphore = DispatchSemaphore(value: 0)
        var path: NWPath?
        monitor.pathUpdateHandler = { p in
            path = p
            semaphore.signal()
        }
        monitor.start(queue: queue)
        defer { monitor.cancel() }
        // The first update arrives promptly; if it somehow doesn't, don't block the
        // button — treat an unknown connection as fine and let the download proceed.
        guard semaphore.wait(timeout: .now() + 1) == .success, let path else { return nil }

        if path.isConstrained { return "Low Data Mode is on. Turn it off, or allow cellular below." }
        if path.isExpensive { return "You're not on Wi-Fi. Connect to Wi-Fi, or allow cellular below." }
        return nil
    }
}

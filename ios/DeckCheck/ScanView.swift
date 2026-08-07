import SwiftUI
import UIKit
import DeckCheckCore

/// Batch scan: capture cards into a batch, review them (newest scan on
/// top), correct any via the name-search picker, then on each row dial the copy count
/// and **Add** or **Remove** it — no separate mode.
/// **Add all** commits every identified card at once. Everything flows through the
/// durable outbox → sync.
struct ScanView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var inventory: InventoryStore
    @EnvironmentObject var outbox: Outbox

    @State private var batch: [BatchItem] = []
    @State private var scanning = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var correcting: BatchItem?

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    private var ready: Bool { catalog.lookup != nil }
    private var identifiedItems: [BatchItem] { batch.filter(\.identified) }
    private var needAttention: Int { batch.filter { !$0.identified }.count }
    /// Newest scan on top (reverse capture order) — you review the card you just shot.
    private var ordered: [BatchItem] { Array(batch.reversed()) }

    /// Which owned printing a Remove would decrement (exact, else a functional
    /// equivalent); nil = you own none, so Remove is disabled.
    private func removalTarget(for item: BatchItem) -> (row: ReadCacheRow, exact: Bool)? {
        guard let c = item.chosen else { return nil }
        return inventory.removalTarget(cardId: c.cardId, equivalenceKey: c.equivalenceKey)
    }

    /// Heads-up when a Remove would decrement a *different* printing than the one
    /// scanned (you own an equivalent, not this exact card "🔁").
    private func removalNote(for item: BatchItem) -> String? {
        guard item.identified, let t = removalTarget(for: item), !t.exact else { return nil }
        let label = t.row.set.isEmpty ? t.row.code : t.row.set
        return "Remove takes your \(label) \(t.row.number) 🔁"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if batch.isEmpty { emptyState } else { reviewList }
            }
            .navigationTitle("Scan")
            .toolbar {
                if !batch.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { batch.removeAll() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { if !batch.isEmpty { commitBar } }
            .fullScreenCover(isPresented: $showCamera) {
                RapidCameraView(onCapture: handle, onFinish: { showCamera = false })
            }
            .sheet(isPresented: $showLibrary) {
                ImagePicker(source: .library, onImage: handle)
            }
            .sheet(item: $correcting) { item in
                if let lookup = catalog.lookup {
                    PrintingPickerView(catalog: lookup) { setChosen(item, $0) }
                }
            }
        }
    }

    // MARK: sections

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button { showCamera = true } label: {
                    Label("Scan", systemImage: "camera").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cameraAvailable || !ready)

                Button { showLibrary = true } label: {
                    Label("Pick", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!ready)
            }

            if !ready { Text(catalog.status).font(.footnote).foregroundStyle(.secondary) }
            if scanning { ProgressView("Reading…") }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
            Text("Scan cards to build a batch,\nthen Add or Remove each.")
                .multilineTextAlignment(.center).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var reviewList: some View {
        List {
            ForEach(ordered) { item in
                VStack(alignment: .leading, spacing: 10) {
                    BatchRow(item: item, ownedCount: ownedCount(item), note: removalNote(for: item))
                        .contentShape(Rectangle())
                        .onTapGesture { correcting = item }
                    if item.identified { rowActions(item) }
                }
                .padding(.vertical, 4)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { discard(item) } label: {
                        Label("Discard", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// The per-card action line: the whole cluster is right-aligned so the count
    /// stepper and — at the far right — the primary **Add** all fall under the right
    /// thumb while the left hand feeds cards.
    @ViewBuilder private func rowActions(_ item: BatchItem) -> some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)

            // Compact quantity stepper — round −/+ around the count.
            HStack(spacing: 10) {
                Button { setQty(item, currentQty(item) - 1) } label: {
                    Image(systemName: "minus").frame(width: 16, height: 16)
                }
                .disabled(currentQty(item) <= 1)
                Text("\(currentQty(item))")
                    .font(.body.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 18)
                Button { setQty(item, currentQty(item) + 1) } label: {
                    Image(systemName: "plus").frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)

            Button { remove(item) } label: {
                Text("Remove").frame(minWidth: 60)
            }
            .buttonStyle(.bordered).tint(.red).controlSize(.large)
            .disabled(removalTarget(for: item) == nil)

            Button { add(item) } label: {
                Text("Add").frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
        }
    }

    private func currentQty(_ item: BatchItem) -> Int {
        batch.first { $0.id == item.id }?.qty ?? 1
    }

    private func setQty(_ item: BatchItem, _ v: Int) {
        guard let i = batch.firstIndex(where: { $0.id == item.id }) else { return }
        batch[i].qty = min(max(1, v), 99)
    }

    private var commitBar: some View {
        VStack(spacing: 6) {
            if needAttention > 0 {
                Text("\(needAttention) need identifying — tap to pick").font(.caption).foregroundStyle(.orange)
            }
            Button { addAll() } label: {
                Text("Add all (\(identifiedItems.reduce(0) { $0 + $1.qty }))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(identifiedItems.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    // MARK: actions

    private func ownedCount(_ item: BatchItem) -> Int {
        guard let key = item.chosen?.equivalenceKey else { return 0 }
        return inventory.ownedCount(forKey: key)
    }

    private func handle(_ picked: UIImage) {
        guard let cg = picked.cgImageOriented(), let lookup = catalog.lookup else { return }
        scanning = true
        Task {
            let scan = await CardScanner.scan(cg)
            let resolution = PrintingResolver.resolve(scan.asRecognizedCard(), catalog: lookup)
            await MainActor.run {
                batch.append(BatchItem(image: picked, resolution: resolution))
                scanning = false
            }
        }
    }

    private func setChosen(_ item: BatchItem, _ card: CatalogCard) {
        guard let i = batch.firstIndex(where: { $0.id == item.id }) else { return }
        batch[i].chosen = card
    }

    private func discard(_ item: BatchItem) {
        batch.removeAll { $0.id == item.id }
    }

    /// Add this card's copies to inventory (the scanned printing) and drop the row.
    private func add(_ item: BatchItem) {
        guard let card = item.chosen else { return }
        enqueueCopies(item, op: .intake, targetCardId: card.cardId)
        batch.removeAll { $0.id == item.id }
        Task { await model.syncNow() }
    }

    /// Remove this card's copies from inventory (the exact printing if owned,
    /// else a functional equivalent) and drop the row.
    private func remove(_ item: BatchItem) {
        guard let t = removalTarget(for: item) else { return }
        enqueueCopies(item, op: .removal, targetCardId: t.row.card_id)
        batch.removeAll { $0.id == item.id }
        Task { await model.syncNow() }
    }

    /// Bulk intake: add every identified card at its chosen count.
    private func addAll() {
        for item in identifiedItems {
            guard let card = item.chosen else { continue }
            enqueueCopies(item, op: .intake, targetCardId: card.cardId)
        }
        batch.removeAll { $0.identified }
        Task { await model.syncNow() }
    }

    /// One op per copy — the backend applies ±1 each and nets the batch.
    private func enqueueCopies(_ item: BatchItem, op: OutboxOp.Kind, targetCardId: String) {
        guard let card = item.chosen else { return }
        let copies = max(1, currentQty(item))
        for _ in 0..<copies {
            outbox.enqueue(OutboxOp(
                id: UUID().uuidString,
                op: op,
                card_id: targetCardId,
                name: card.name, set: card.setName, code: card.ptcgoCode ?? "",
                number: card.number, location: "",
                equivalence_key: card.equivalenceKey,
                norm_version: catalog.normVersion ?? ""
            ))
        }
    }
}

/// One card's info block in the batch review (image + identity + owned count). The
/// action line (quantity, Add/Remove) is rendered by the parent so it can drive the
/// batch state.
private struct BatchRow: View {
    let item: BatchItem
    let ownedCount: Int
    var note: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: item.image)
                .resizable().scaledToFill()
                .frame(width: 78, height: 109)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if let c = item.chosen {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).font(.body.weight(.medium))
                    Text("\(c.ptcgoCode ?? c.setName) \(c.number)  ·  owned \(ownedCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note {
                        Text(note).font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Couldn’t identify", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Tap to pick by name").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

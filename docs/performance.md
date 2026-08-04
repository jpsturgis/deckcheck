# Performance review

Why the app felt fine at home and sluggish elsewhere, what got fixed, and what's left.

Measurements are from an M1 Max against a 23,444-card catalog snapshot. **A phone is
slower** — treat these as lower bounds and as relative weights, not as device numbers.

## The short version

Two independent problems, and only one of them is about the network.

1. **Images had no cache worth the name.** `AsyncImage` starts a fresh load every time a
   cell appears, and the process-wide HTTP cache it falls back on is far too small for
   a card-image workload. Off a fast network the re-fetch was invisible; anywhere else
   it was a placeholder flash on every scroll.
2. **The two busiest screens did real work on the main thread, per render, several times
   over.** This had nothing to do with the network — it was just as slow at home, and it
   is why typing in search felt heavy. It was the bigger of the two effects for a large
   collection.

---

## Images

### The asset side is already ideal

```
GET https://assets.tcgdex.net/en/swsh/swsh1/156/low.webp   → 11,224 bytes
GET .../high.webp                                          → 35,738 bytes
cache-control: public, max-age=31536000, immutable
```

Thumbnails are ~11 KB, full art ~36 KB, and both are immutable for a year. Nothing
about the source is slow. A screen of 12 thumbnails is ~130 KB — about one photo. If
that feels slow, the bytes aren't the reason.

### What was actually wrong

**`AsyncImage` is scoped to the view's lifetime.** Scroll a row off screen and back and
it starts the request again. It keeps no decoded image anywhere, so even a cache hit
costs a `URLSession` round trip plus a WebP decode, and shows the placeholder in the
meantime. In a `List`, which recycles aggressively, that is *every* row, *every* pass.

**`URLCache.shared` was never sized.** The system default is small — hundreds of
kilobytes of memory cache. At ~11 KB per thumbnail that is a few dozen images before
eviction, so scrolling a collection of any size evicts its own working set continuously
and every re-appearance goes back to disk or to the network.

**Nothing was prefetched.** The first sight of a row was also the first byte requested.
On a fast link the gap is imperceptible; on a slow or high-latency link it's the whole
experience.

**The detail view ignored art it already had.** The hero image loads `imageLarge` from
scratch behind a spinner, even though the `imageSmall` for the same card was on screen a
moment earlier in the list — and is 3× smaller.

### What changed

A small image pipeline in `ios/DeckCheck/CardImageLoader.swift`, and a `CardImage` view
that replaces every `AsyncImage` call site:

- **A decoded-image memory cache** (`NSCache`, keyed by URL + target size) that
  `CardImage` reads **synchronously when the view is created**. A cached image renders
  in the first frame — no placeholder, no flash, no async hop. This is the single change
  that makes scrolling feel different.
- **A properly sized `URLCache`** installed at launch (32 MB memory / 256 MB disk).
  Given `immutable, max-age=1y`, a card you've seen once should never be fetched twice;
  256 MB holds a very large collection's thumbnails.
- **Request coalescing.** Ten rows asking for one URL produce one request. Card images
  repeat constantly across printing lists and search results.
- **Downsampling at decode time** via `CGImageSourceCreateThumbnailAtIndex`, so a 40×56
  thumbnail doesn't hold a full-size bitmap. Decode happens off the main thread.
- **Prefetch ahead of the scroll** — as a row appears, the next several rows' images are
  warmed at low priority. It's the same bytes, just requested earlier.
- **Blur-up on the detail hero**: the cached thumbnail is shown scaled and blurred
  underneath while the full image loads, so the card is recognisable immediately and
  resolves in place instead of appearing from blank.

Cancellation is handled: a row that scrolls away before its image lands cancels, unless
another view is waiting on the same URL.

---

## Main-thread work

This is the part that was slow regardless of network, and for a large collection it
dominated.

Per-query costs against the real catalog, all indexed lookups:

| Query | Cost |
|---|---|
| `card(byId:)` | 11.6 µs |
| `cards(equivalenceKey:)` | 16.2 µs |
| `searchByName` (1 token) | **21.9 ms** |
| `searchByName` (2 tokens) | **22.0 ms** |

### 1. `CardsView.ownedItems()` queried SQLite inside a sort comparator

Owned printings were sorted by release date, and the comparator fetched *both* sides'
release dates from SQLite on every comparison — two queries per comparison, ~n log n
comparisons.

| Owned printings | Lookups | Per evaluation | ×3 (see below) |
|---|---|---|---|
| 100 | 1,328 | 8.6 ms | 25.9 ms |
| 500 | 8,964 | 59.8 ms | 179.3 ms |
| 1,500 | 31,652 | 221.5 ms | 664.4 ms |

**And `items` was computed three times per `body` evaluation** — once by `emptyMessage`,
once by the `ForEach`, once by `header` — each time redoing all of it. `body` re-runs on
every keystroke, every filter toggle, and every store update.

Fixed by resolving each printing's release date **once** into a dictionary before
sorting (n lookups instead of n log n), and by computing `items` a single time per pass.

### 2. Search ran synchronously on every keystroke

`searchByName` is a full table scan: `LIKE '%term%'` against five expressions —
including a `REPLACE(REPLACE(...))` over the name column — across 23,444 rows, with no
index that can help. **22 ms per call on an M1 Max**, run on the main thread, once per
keystroke, and then multiplied by the `items`-computed-three-times problem above.

Fixed by debouncing: typing settles for 180 ms before the catalog is queried, so a word
costs one scan instead of one per letter. Clearing the field is still immediate.
Combined with the fix above, a keystroke now does no catalog work at all until you stop.

The scan itself is unchanged, and it still runs on the main thread — see *Deferred*.

> **Since superseded.** The scan is now an FTS5 index lookup (~1 ms) and Cards no
> longer re-resolves the collection per render. See *Round two* below.

### 3. `DecksView` ran a full gap-check per deck, per render

Each row called `GapChecker.check`, which parses the decklist and resolves every line
against the catalog (~60 lines × ~12–16 µs ≈ 1 ms per deck, plus parsing) — recomputed
for every deck on every `body` evaluation, including during scrolling.

Fixed by computing reports in `DecksStore` when decks or inventory actually change, and
having rows read the cached result.

---

---

# Round two — the deferred work

The five items below were named in the first pass and left undone. Four are now done
or answered; one is a review rather than a change.

Numbers in this half come from a synthetic catalog built to the real one's size
(23,444 cards / 170 sets) and queried through SQLite directly, so they measure the
*query* rather than the app. Treat them as relative. The scan measured 18–24 ms here
against the 22 ms measured in-app above, which is close enough to trust the ratio.

## Search is indexed now

`searchByName` was a full-table scan: `LIKE '%term%'` against five expressions across
23,444 rows, with no index that could help. The builder now writes an FTS5 index and
the app queries it.

| Query | Scan | Indexed |
|---|---|---|
| `char` | 18.5 ms | 1.2 ms |
| `charizard ex` | 21.7 ms | 0.05 ms |
| `obsidian flames` | 23.6 ms | 3.1 ms |
| `125` | 22.3 ms | 0.8 ms |
| `zard` | 18.4 ms | 1.2 ms |

The remaining milliseconds on the broad queries are materializing and sorting a couple
of thousand result rows, not searching — the narrow queries show what the lookup
itself costs.

### Why the trigram tokenizer, and what it costs

FTS5's default (`unicode61`) indexes words, so it matches prefixes: `char` finds
`Charizard`, but **`zard` finds nothing**. Search here is specified as a
case-insensitive *substring* match, and silently returning nothing is a wrong answer
rather than a slow one — worse than what we started with. `trigram` matches substrings
and reproduces the old semantics exactly.

It isn't free:

| | index size | `zard` |
|---|---|---|
| `unicode61` | +0.88 MB | 0 rows — wrong |
| `trigram` | +4.01 MB | 782 rows — correct |

On a ~6 MB snapshot that's a two-thirds bigger catalog. It buys behaviour parity, which
is the right trade for something that ships inside the app.

Two consequences worth knowing:

- **Trigram can't match patterns shorter than three characters**, and doesn't error —
  it just returns nothing. Tokens under three characters therefore keep the scan. A
  mixed query (`charizard ex`) still wins, because the index narrows the rows first and
  the short token is then a LIKE over what survived. Only an all-short query (`ex`)
  scans the whole table.
- **The index is detected, not assumed.** The catalog is built separately from the app,
  so a snapshot without one is a normal thing to be handed; it falls back to the scan
  and says so in the catalog status line.

Both paths are tested against each other — every query the scan is tested with, plus
the awkward ones, must return identically through the index. That parity test is the
whole safety argument.

The debounce stays. At ~1 ms it's no longer load-bearing, but it still collapses a
word's worth of keystrokes into one query, and removing it is a separate change with
its own feel to judge on a phone.

## Catalog reads: not moved, not needed

The deferred plan was to make `SQLiteCatalog` an actor so queries leave the main
thread. Having done the search work first, that's the wrong fix for what's left.

With search indexed, the dominant remaining main-thread catalog cost was Cards
resolving every owned printing inside `body` — one lookup per printing at 11.6 µs, so
~17 ms for a 1,500-printing collection, repeated on every keystroke, filter toggle and
store update to recompute something that only changes when the inventory does.
`InventoryStore` now caches that resolution against its `revision` counter, which is
what the counter was for. That removes the cost rather than relocating it, and it
doesn't make every call site async.

Making the catalog an actor would ripple through Cards, Decks, the pickers, Scan,
`GapChecker` and the `gapcheck` CLI — turning a synchronous pure core into an async
one — to hide work that no longer needs hiding.

**But there is a real issue an actor would have fixed, and it isn't about speed.**
`SQLiteCatalog` wraps a raw `sqlite3` pointer in a plain final class, isn't `Sendable`,
and is already used from more than one thread: Scan resolves OCR results on a
background task while views query the same connection on the main thread. That works
today because Apple's SQLite is built in serialized mode and mutexes the connection
internally — so the *access* is safe, but nothing in the type system says so, and the
concurrency is accidental rather than declared. Worth making explicit (marking it
`@unchecked Sendable` with that reasoning written down, at minimum) independently of
any performance argument.

## Pre-warming your collection's art

Done, as a Settings action with progress and a cancel. Thumbnails only — full art is
~36 KB against a thumbnail's ~11 KB, so warming both would triple the download for a
screen most cards never reach, and the detail view already blurs up from the cached
thumbnail.

Wi-Fi only unless cellular is explicitly allowed, and it refuses up front with the
reason (including Low Data Mode) rather than quietly spending someone's data. Six
downloads in flight — the cap is about leaving the connection responsive, not about
the server.

## Normalization migration

The blocker on the Air Balloon fix was never the fix; it was that changing `resolve.ts`
invalidates every `equivalence_key` already written into people's Sheets. That
migration now exists (`InventoryMigration`), so the `resolve.ts` change becomes
shippable — bump `NORM_VERSION`, rebuild the catalog, and rows re-derive themselves.

`norm_version` was being written into every row and read back, and never compared to
anything. It is now compared against the catalog's `meta.norm_version`.

**A blank stamp counts as stale.** Real sheets contain rows whose `norm_version` was
never populated — an artefact of the poke-check → deckcheck migration. A blank says
nothing about whether that row's key is current, so the honest reading is to re-derive
it from the catalog. The easy mistake is comparing only non-empty stamps, which strands
exactly those rows forever; there's a test named for it.

This also means the migration is worth running *today*, before any `resolve.ts` change:
if any blank-stamped row carries a key that doesn't match the current catalog, that
card is silently failing to group with its other printings and reads as missing in a
gap-check.

The pass touches only `equivalence_key` and `norm_version` — the person owns the rest
of the row — and an up-to-date Sheet plans nothing, so it's safe to re-run.

### The case it can't fix

A **linked promo** adopts a catalog card's equivalence key, and `ManualEntry` bakes
that key into the promo's synthetic `card_id`. So after a normalization change the row
records only the *old* key, and the old key no longer exists in the rebuilt catalog —
there's nothing left to map it through. Those are reported for re-linking by hand
rather than guessed at, because guessing would silently re-point a promo at the wrong
card.

If that turns out to be more than a handful of rows, the fix is on the builder side:
when `NORM_VERSION` bumps, keep the previous version's `resolve()` alongside the new
one and stamp both keys per card. A `prev_equivalence_key` column makes old → new a
lookup, and linked promos migrate like everything else.

---

## Still deferred

- **The scan/OCR path** — reviewed now, not changed. Findings below; none are
  measurable without a device and real card photos, so changing them blind would be
  guessing.
  - Vision runs `.accurate` recognition on the cropped capture, which is a few
    megapixels. Card text is large relative to the crop, so **downscaling to ~1000 px on
    the long edge before recognition**, and/or raising `minimumTextHeight` from its
    1/32 default, is the obvious first thing to measure. This is very likely the
    biggest available win in the scan path.
  - **Each capture starts its own Vision request with no cap.** In rapid-fire mode
    several run concurrently on multi-megapixel images. `Camera.swift` already carries
    a comment about a jetsam kill from decoded-image memory during a batch; unbounded
    concurrent recognition is the same kind of risk. Serializing, or capping at two,
    costs throughput that should be measured before spending.
  - `try? handler.perform([request])` discards the error, so a failed recognition is
    indistinguishable from a card with no text on it.
  - The request's `revision` isn't pinned, so recognition behaviour can shift under the
    app on an OS update.
- **Removing the search debounce.** Now defensible at ~1 ms; it's a feel change to
  judge on a phone, not a measurement.
- **Root-causing the Air Balloon equivalence split** itself. The migration that
  unblocked it is done; the `resolve.ts` root cause is still open.

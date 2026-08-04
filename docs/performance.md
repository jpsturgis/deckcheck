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

### 3. `DecksView` ran a full gap-check per deck, per render

Each row called `GapChecker.check`, which parses the decklist and resolves every line
against the catalog (~60 lines × ~12–16 µs ≈ 1 ms per deck, plus parsing) — recomputed
for every deck on every `body` evaluation, including during scrolling.

Fixed by computing reports in `DecksStore` when decks or inventory actually change, and
having rows read the cached result.

---

## Deferred

Named here rather than done, so the choice is visible:

- **FTS5 for search.** The right fix for the 22 ms scan is a full-text index in the
  catalog builder, which would make it sub-millisecond and remove the need to debounce
  at all. It's a catalog schema change plus a builder change plus a query rewrite —
  worth doing, but it belongs in its own branch alongside a catalog rebuild.
- **Catalog reads off the main thread.** Everything above reduces *how often* the
  catalog is queried; none of it moves the queries. Doing that means making
  `SQLiteCatalog` an actor (it wraps a raw `sqlite3` pointer and is currently a plain
  final class reached synchronously from views), which ripples through every call site.
  Worth doing after FTS5, when what's left is small enough to see clearly.
- **Pre-warming your collection's art over Wi-Fi.** Because the assets are immutable and
  tiny, "download my collection's thumbnails" is a genuinely small feature: ~11 MB for a
  1,000-card collection, and Cards would then be instant and fully offline. Needs a
  progress UI and a settings toggle.
- **The scan/OCR path** wasn't reviewed. It's a different kind of workload (Vision on
  camera frames) and nothing about the report was about it.
- **Root-causing the Air Balloon equivalence split.** Tracked separately — see the note
  at the end of the gap-check work. The fix belongs in `resolve.ts` and would invalidate
  every `equivalence_key` already written into people's Sheets, so it needs a migration
  rather than a patch.

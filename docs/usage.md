# Using DeckCheck

A tour of every feature, tab by tab. DeckCheck has five tabs — **Scan · Cards · Decks ·
Gap Check · Settings** — and everything you change is stored in **your own Google
Sheet**, which you can also edit by hand from a laptop.

First time here? Do the one-time setup in the [README](../README.md) (build a catalog,
connect your Sheet) before the tabs below will do much.

## A few concepts first

These ideas run through the whole app:

- **Functional equivalence.** Reprints and alternate arts that play identically count as
  **the same card**. DeckCheck groups printings by a precomputed *equivalence key*, so
  "you own 4" and "the deck needs 4" are judged across the whole group — a Base-set and a
  reprint of the same card are interchangeable.
- **Promos & "plays as".** Some cards (promos, or printings whose source data differs
  from their set printing) don't auto-group. You can **link** them to the card they
  *play as*, and your copies then count toward that card's group.
- **Owned vs. available.** Decks *reserve* the copies they use. In Cards, **available =
  owned − reserved by decks**, so you can tell what's actually free to build with.
- **Sync.** Adds/removes queue in a durable **outbox** on the phone and flush to your
  Sheet automatically; a **pull-to-refresh** (or **Settings → Sync now**) also pulls the
  Sheet back down. Your Sheet is the source of truth — hand-edits show up on the next
  refresh.

---

## Scan — add & remove cards by photo

Build a **batch** of card photos, then Add or Remove each. There's no separate "add
mode" vs "remove mode" — you decide per card.

1. **Capture.** Tap **Scan** (camera) to shoot cards one after another, or **Pick** to
   choose a photo from your library. Each capture appears in the review list, **newest on
   top**. (Both need the catalog loaded.)
2. **Review & correct.** Each row shows the photo and DeckCheck's best guess (name,
   set + number, and how many you already own). **Tap any row** to open the name-search
   picker and choose the exact printing:
   - **Couldn't identify?** The row says so — tap it, search by name, pick the printing,
     and you're back to the row.
   - **A promo?** In the same picker you can **search** for the card it plays as, or
     **enter it by hand**; either way it's stored linked to that card's group (its
     "plays as" counterpart) so it counts in your collection and in gap-checks.
3. **Set the count.** Use the round **− / +** stepper on the row (1–99).
4. **Add or Remove.**
   - **Add** (green) puts that many copies of the scanned printing into inventory.
   - **Remove** (red) takes them out. It's disabled if you own none. If you own a
     *different* printing of the same card, Remove decrements that one and the row notes
     it (🔁 "Remove takes your …").
5. **Add all (N)** commits every *identified* row at once — handy for a stack you've
   confirmed.

Swipe a row left to **Discard** it; **Clear** (top-right) empties the batch. Everything
flows through the outbox and syncs to your Sheet.

## Cards — browse & search your collection

One search surface with a scope switch:

- **Owned** (default) — your collection, from the on-device cache (works offline).
- **All** — search the **whole catalog** by name, set, or number; each result shows how
  many you own (including 0).

**Search** with the bar (name / set / number). Two filters sit above the list:

- **Standard only** — show only Standard-legal cards. Persisted, and shared with the
  Gap Check and the printing picker.
- **Free only** (Owned scope) — show only cards with an unreserved copy (owned minus
  what your decks use).

The header tallies your collection: *N cards · N unique · N printings · N in use*.

**Add promo** (top-right) enters a hand-entered promo without scanning — search for the
card it plays as (or enter it manually), and it lands in your Owned list on the next
sync.

**Tap a card** to open its detail:

- The full card image, set/number, **TCG Live code**, regulation mark, and **Standard /
  Expanded** legality.
- **You own N**, and a **Your copies (this printing)** **− / +** stepper to adjust that
  exact printing on the spot (each tap queues a sync; the count moves immediately).
- **Plays as** — link this card to another card's functional group (e.g. a promo that
  plays as its set printing), so your copies count together.
- **View on TCGplayer** — jumps to a TCGplayer search for that exact printing (price
  check / buy).
- **Printings (N)** — every printing in the equivalence group, with the ones you own
  check-marked; tap any to open its own detail.

## Decks — track the decks you're building

DeckCheck reads decks straight from **your Sheet**. This is the convention:

> **Add a tab named `Deck: <name>`** (e.g. `Deck: Charizard ex`) and paste a decklist
> (TCG Live **Copy List**) into it — one card per row, starting in **column A**. Then
> **pull to refresh** in the app.

Each such tab shows up under **Decks** with a **Buildable N/total · short N** summary.
**Tap a deck** for its full per-deck gap-check against what you own (honoring the
Standard-only filter). Decks also **reserve** the cards they use, which is what drives the
"in use / free" numbers in Cards.

You don't have to create these tabs by hand — the **Gap Check** tab has an **Add as
deck** button (below) that writes one for you.

## Gap Check — what am I missing?

Paste a decklist and see exactly what you need to build it.

1. Paste a **TCG Live / Limitless** decklist into the box and tap **Check**.
2. You get a **gap-first report**: a **Buildable N/total** headline, then **❌ Missing /
   ⚠️ Short / ✅ Have** (🔁 marks a card you own via a *different* printing), plus a
   copy-ready **TCGplayer buy list** for just the shortfall.
3. **Couldn't identify a line?** (usually a promo.) The report lists it with a
   **Resolve** action — search and pick the printing, and the report recomputes.
4. **Add as deck** saves the list as a `Deck: <name>` tab in your Sheet (so it reserves
   cards and appears under Decks). Requires your Sheet connected.

**Two other ways to run a gap-check:**

- **In your Sheet, any time:** your Sheet has a **`Gap Check`** tab — paste a decklist
  into **column A** and the report fills in from **column C** on your next sync in the
  app.
- **In your browser, app closed (optional add-on):** enable it in Settings and the
  report updates itself as you edit the Sheet, without the app running — see
  [`browser-gap-check.md`](setup/browser-gap-check.md).

## Settings — connection, sync, and options

- **Inventory Sheet** — connect/manage your Sheet: paste your **OAuth Client ID**, sign
  in with Google, and create your Inventory sheet (see
  [`setup/google-oauth-client.md`](setup/google-oauth-client.md)). The steps stay greyed
  out until a Client ID is entered.
- **Sync now** — flush pending adds/removes, then refresh the cache from your Sheet.
  (Most screens also **pull-to-refresh**.)
- **Status** — catalog state, inventory row count, pending-sync count, last-synced time,
  and the last error if any. The **Settings** tab icon carries a badge with the number of
  pending changes.
- **In-browser gap-check** — the optional app-closed add-on: enable it (grants one extra
  Google permission and pushes a slim catalog index into a hidden tab), refresh the index
  after a catalog rebuild, or turn it off. Details in
  [`setup/browser-gap-check.md`](setup/browser-gap-check.md).
- **Clear pending** — appears when writes are queued; discards them without sending
  (recovery valve if a sync gets stuck).

---

## Editing the Sheet by hand

Because the inventory *is* a Google Sheet in your Drive, you can sort, filter, fix a
row, or bulk-edit in the browser — DeckCheck picks up your changes on the next refresh.
Machine columns (`card_id`, `equivalence_key`, `norm_version`) are how the app finds each
row, so leave those intact; the human columns (name/set/number/qty/location) are yours to
tidy.

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
- **Sets** — how far through each set you are (below).

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

### Sets — how close am I to completing one?

Switch the scope to **Sets** for one row per set, newest first, each with a progress bar
and an *N/total* count. The search bar filters by set name or TCG Live code, and
**Standard only** narrows the list to sets still in the format.

**Tap a set** for a **Missing / Have** switch listing either side, plus a **Copy buy
list** button that puts every card you're missing from that set on the clipboard as a
TCGplayer Mass Entry list — the same format the Gap Check buy list uses.

> **Sets count printings, not cards.** This is the one place in DeckCheck where
> [functional equivalence](#a-few-concepts-first) is deliberately *not* used. A deck
> doesn't care which printing of Iono you own, but a binder page does — so owning the
> Paldean Fates reprint does nothing for your Paldea Evolved slot. Everywhere else in
> the app, reprints count as the same card; here they don't.

The denominator is **how many cards of that set are in your catalog snapshot**, not the
printed "/191" on the card. Those differ (secret rares push the real count higher, and
your snapshot may not carry every printing), and a total you can't actually reach would
make a bar that never fills. Where they differ, the set's detail screen says so.

## Decks — track the decks you're building

DeckCheck reads decks straight from **your Sheet**. This is the convention:

> **Add a tab named `Deck: <name>`** (e.g. `Deck: Charizard ex`) and paste a decklist
> (TCG Live **Copy List**) into it — one card per row, starting in **column A**. Then
> **pull to refresh** in the app.

Each such tab shows up under **Decks** with a **Buildable N/total · short N** summary.
**Tap a deck** for its full per-deck gap-check against what you own (honoring the
Standard-only filter). Decks also **reserve** the cards they use, which is what drives the
"in use / free" numbers in Cards.

### Built decks vs. ideas

Not every deck on the list is actually sleeved — some are "I'd like to build this one
day". Those shouldn't make their cards look unavailable.

Each deck has a **Counts against my card totals** toggle (in the deck's detail, or swipe
right on the row in the list). Turn it off and the deck is marked **Idea**: it still
gap-checks exactly as before, but it reserves nothing, so its cards stay free for the
decks you've actually built.

The setting lives in the deck's own tab as a line reading `#built: no`, which you can
also add or change by hand from a laptop. DeckCheck's decklist parser ignores any line
that doesn't start with a quantity, so it sits harmlessly alongside the cards. A deck
with no such line counts as built — nothing changes for tabs you already have.

You don't have to create these tabs by hand — the **Gap Check** tab has an **Add as
deck** button (below) that writes one for you.

## Gap Check — what am I missing?

Paste a decklist and see exactly what you need to build it.

1. Paste a **TCG Live / Limitless** decklist into the box and tap **Check** — or just
   tap **Paste**, which pastes *and* checks in one go, with no "Allow Paste?" prompt.
   (iOS greys the Paste button out on its own when there's nothing on the clipboard to
   paste.) If the box already has a list in it, pasting asks before replacing it.
2. You get a **gap-first report**: a **Buildable N/total** headline, then **❌ Missing /
   ⚠️ Short / 📝 Different wording / ✅ Have** (🔁 marks a card you own via a *different*
   printing), plus a copy-ready **TCGplayer buy list** for just the shortfall.
3. **📝 Different wording** is for reprints whose text was reworded — Energy Retrieval
   reads "Put 2 basic Energy cards…" on older printings and "Put **up to** 2…" on
   current ones. The game plays every printing with the most recent text, so these
   count toward the build and stay off the buy list. They get their own section rather
   than being folded into ✅ Have, because the wording really does differ and it's worth
   a glance. Only Trainers and Energy are matched this way — two Pokémon that share a
   name are usually different cards.
4. **Couldn't identify a line?** (usually a promo.) The report lists it with a
   **Resolve** action — search and pick the printing, and the report recomputes.
5. **Add as deck** saves the list as a `Deck: <name>` tab in your Sheet (so it reserves
   cards and appears under Decks). Requires your Sheet connected.

**Three other ways to run a gap-check:**

- **From anywhere on your phone (Shortcuts):** DeckCheck ships a **Gap Check Decklist**
  action, so you can check a list straight from Safari, Discord, or Notes without
  copying it first. See [From the share sheet](#from-the-share-sheet) below.
- **In your Sheet, any time:** your Sheet has a **`Gap Check`** tab — paste a decklist
  into **column A** and the report fills in from **column C** on your next sync in the
  app.
- **In your browser, app closed (optional add-on):** enable it in Settings and the
  report updates itself as you edit the Sheet, without the app running — see
  [`browser-gap-check.md`](setup/browser-gap-check.md).

### From the share sheet

DeckCheck registers a Shortcuts action called **Gap Check Decklist**. It's there as soon
as you install the app — you'll find it in the Shortcuts app under DeckCheck, and by
typing "gap check" into Spotlight.

To get it into the **share sheet**, wrap it in a shortcut. This is a one-time setup and
takes about a minute.

1. Open the **Shortcuts** app → the **Shortcuts** tab → **+** (top right).
2. Tap **Info** (the ⓘ at the bottom of the editor, or *Shortcut Details* in the
   right-hand pane on iPad).
   - Turn on **Show in Share Sheet**.
   - Tap **Share Sheet Types**, **Deselect All**, then select **Text** only. (Without
     this the shortcut also offers itself for photos and files, where it can't work.)
   - Tap **Done**.
3. Tap **Add Action** and search for `Gap Check`. Under **DeckCheck**, tap
   **Gap Check Decklist**.
4. The action reads *Gap check **Decklist***. Tap the **Decklist** placeholder, then
   choose **Shortcut Input** from the variable bar just above the keyboard.
   - It should now read *Gap check **Shortcut Input***. This is the step that's easy to
     miss — without it the shortcut runs with an empty decklist.
5. Rename it: tap the shortcut's name at the top → **Rename** → e.g. `Gap Check`. This
   is the name you'll be looking for in the share sheet.
6. **Done**.

To use it: select a decklist in Safari (or Discord, Notes, Messages — anywhere), tap
**Share**, then **scroll down past the app icons** to the list of actions and tap your
shortcut. DeckCheck opens straight to the report.

> The shortcut appears in the share sheet's **action list** — the rows below the app
> icons — not in the top row of apps. On first run iOS asks once whether to allow it to
> share data with DeckCheck; tap **Allow**. You can drag it higher up the action list by
> scrolling to the bottom and choosing **Edit Actions…**.

If the shortcut runs but the report is empty, step 4 is almost certainly the reason —
reopen the shortcut and check the action says *Shortcut Input* and not *Decklist*.

> **Why a shortcut rather than DeckCheck appearing in the share sheet directly?** That
> would need a Share Extension, and a share extension can only hand data to its app
> through an **App Group**, which Apple gates behind the paid Developer Program. Since
> DeckCheck is built to work on a **free Apple ID**, it uses an App Intent instead —
> the setup above is one-time, and it also gets you Siri and Home Screen / Control
> Center / Action Button triggers that a share extension wouldn't.

The same action works for anything else Shortcuts can feed it. A useful one: a
Home Screen shortcut that passes **Clipboard** to *Gap Check Decklist* — copy a list,
tap the icon, read the report.

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

## Ongoing use & tradeoffs

Day to day you just scan, search, and gap-check — most of that works offline; only
syncing needs a connection. A few things need occasional attention, and most have an
"if you'd rather not deal with it" escape hatch:

- **You'll re-sign in with Google about once a week.** While your OAuth client stays in
  *Testing* mode, Google expires its refresh token every 7 days; the app just re-prompts
  and your Sheet and data are untouched.
  *Don't want the weekly sign-in?* Set your OAuth consent screen to **In production** — a
  one-time "unverified app → continue" click-through, after which tokens stop expiring on
  the 7-day clock. See [`setup/google-oauth-client.md`](setup/google-oauth-client.md).
- **A free-Apple-ID build stops launching after 7 days.** That's Apple's sideloading
  limit, not DeckCheck — plug in and hit **Run** in Xcode again to refresh it.
  *Don't want to do that weekly?* A paid Apple Developer account signs for a year instead.
- **New sets need a catalog rebuild.** When a set releases and you want its cards, re-run
  `tools/build-catalog`, drop the new `catalog.sqlite` into the app, and (if you use
  in-browser gap-check) tap **Refresh catalog index** in Settings. Until then the app
  keeps working on your current catalog — there's no hosted catalog to auto-update, by
  design.
- **Don't want to open the app just to gap-check a list?** Use the **`Gap Check`** tab in
  your Sheet (it fills in on the next sync), or the app-closed **in-browser** add-on.
- **Don't want to scan?** You never have to: edit the Sheet by hand (below), use **Add
  promo** in Cards, or the ± stepper on any card's detail.

## Editing the Sheet by hand

Because the inventory *is* a Google Sheet in your Drive, you can sort, filter, fix a
row, or bulk-edit in the browser — DeckCheck picks up your changes on the next refresh.
Machine columns (`card_id`, `equivalence_key`, `norm_version`) are how the app finds each
row, so leave those intact; the human columns (name/set/number/qty/location) are yours to
tidy.

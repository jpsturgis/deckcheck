# In-browser / app-closed gap-check (v2, optional)

The Gap Check tab normally fills in when you **Sync** in the app — the app resolves
your pasted decklist against its local catalog and writes the report back (spec
[v2 §7.4](../spec/v2.md), PART 1). This optional feature lets that gap-check run
**in your browser with the app closed**: you edit the decklist in the Gap Check tab
and the report updates itself.

It's **off by default** and entirely opt-in. Turn it on from **Settings ▸ In-browser
gap-check** once your Inventory sheet is connected.

## What it does when you enable it

1. **Asks for one extra Google permission** — `script.projects` (manage Apps Script
   projects). This is granted *incrementally*: you'll see a fresh consent screen
   listing only the new permission. It's used solely to deploy the gap-check code
   into **your own** sheet; nothing else.
2. **Adds a hidden `Catalog` tab** to your sheet and fills it with a **slim
   resolution index** — seven columns (`card_id`, `name`, `set_name`, `code`,
   `number`, `printed_total`, `equivalence_key`), one row per card. This is *not* the
   full catalog (no images, HP, attacks, prices); it's only what's needed to turn a
   decklist line into a card + equivalence group. The tab is hidden because it's
   machine scaffolding, not something you edit.
3. **Deploys a small container-bound Apps Script** into your sheet with two simple
   triggers:
   - **`onEdit`** — when you edit the decklist (column A of the Gap Check tab), it
     re-runs the check and rewrites the report in column C.
   - **`onOpen`** — adds a **DeckCheck ▸ Run gap-check** menu as a manual fallback.

   The deployed code is only the gap-check (parse → resolve → diff → gap-first
   report); the retired v1 web-app backend is *not* deployed.

Ownership comes from the `Inventory` tab's `equivalence_key`/`qty` (so a functional
equivalent or a linked promo counts as owned), exactly matching the app.

## Prerequisites

- Your Inventory sheet is connected in the app (Settings ▸ Inventory Sheet).
- The catalog has finished loading in the app (the enable button is disabled until
  then — it reads the index from the local catalog to push it).
- **The Apps Script API must be enabled for your Google account.** One-time: visit
  <https://script.google.com/home/usersettings> and turn **Google Apps Script API**
  on. Without it, enabling fails with a permission error from the Apps Script API.

## Using it

- Paste a TCG Live "Copy List" into **column A** of the **Gap Check** tab in your
  browser. The report appears from **column C**: a headline (buildable N/deck-total ·
  short count), a gap-first table (❌ Missing red · ⚠️ Short amber · ✅ Have green,
  with 🔁 when a different printing you own covers it), a TCGplayer link per gap, an
  ❓ unidentified list, and a copy-ready TCGplayer Mass Entry buy list.
- The app's own **Sync** still works and writes the same report region — whichever
  ran most recently wins.

## Keeping the index fresh

The `Catalog` index is a snapshot taken when you enabled the feature. After you
**rebuild the catalog** (a new `catalog.sqlite`), tap **Settings ▸ Refresh catalog
index** to push the new index. (Refreshing needs no new permission — it only writes
the Sheet.) Your inventory and decklist are read live, so only the catalog snapshot
can go stale.

## Turning it off

**Settings ▸ Turn off in-browser gap-check** trashes the deployed script (so the
auto-recompute stops) and removes the hidden `Catalog` tab. Your Inventory and Gap
Check tabs are untouched; the app's own Sync-driven gap-check keeps working.

## Notes & limitations

- Everything stays in **your own** Drive/sheet — no shared server, no data leaves
  your account. The `script.projects` scope only lets the app manage scripts it
  creates.
- The `onEdit` trigger fires on **manual** edits in the browser, not on the app's API
  writes (which is why the app recomputes on Sync itself). Recompute runs under
  Apps Script's ~30-second simple-trigger budget; the slim index keeps it fast.
- A brand-new set that isn't in your pushed index yet will show its cards as
  ❓ unidentified in the browser until you Refresh the catalog index.

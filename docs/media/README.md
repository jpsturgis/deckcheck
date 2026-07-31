# Media (screenshots & gifs for the README)

Drop capture files in this folder, then uncomment the `<table>` in the root
[`README.md`](../../README.md) "Screenshots" section. Files here are the one exception
to "ship the recipe, not the meal" — they're UI captures, so **avoid framing that shows
large amounts of copyrighted card art** (a few cards incidentally in a scan shot is
fine; a full-screen gallery of card images is not).

## Suggested shot list

Three to five captures that show the core loop. Priority order:

1. **`intake.gif`** — the headline flow: point the camera at a stack → cards get
   recognized → confirm/correct → they land in inventory. A short gif (5–10s) sells this
   far better than a still.
2. **`gapcheck.png`** (or `.gif`) — paste/open a decklist → the gap-first report with
   ❌ Missing / ⚠️ Short / ✅ Have and the TCGplayer buy list. The single most useful screen.
3. **`search.png`** — the Cards tab searching your own collection ("do I own X?").
4. *(optional)* **`browser-gapcheck.gif`** — editing the decklist in the Google Sheet in a
   browser and the report updating itself (the app-closed add-on).
5. *(optional)* **`sheet.png`** — the inventory as a plain Google Sheet, to make the
   "your data stays yours" point visually.

## Capture tips

- **Device:** capture on a real iPhone (Side + Volume Up) or the Simulator
  (`File ▸ Save Screen` / `⌘S`). Simulator avoids personal data in the shot.
- **Gifs:** screen-record (iOS Control Center, or Simulator `⌘R`), then convert. Keep them
  short and small — target **< 3 MB**, ~240–320 px wide, so the README stays light.
  `ffmpeg -i in.mov -vf "fps=12,scale=320:-1:flags=lanczos" -loop 0 out.gif` works well.
- **Consistency:** same device frame / light or dark mode across shots reads as one set.
- **Sizes:** the README table renders each at `width="240"`; 2× that natively (≈480 px
  wide) keeps them crisp on retina.

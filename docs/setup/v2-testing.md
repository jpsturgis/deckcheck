# v2 on-device testing checklist

The consolidated walkthrough to get the **v2 Google Sheets beta** running on your
iPhone and verify the OAuth + Sheets sync end-to-end. This is the first v2 piece you
test on-device; everything before it was unit-tested off-device.

**Two reassurances up front:**
- **v1 is untouched.** v2 builds under a **different bundle id**
  (`com.example.DeckCheck`), so it installs as a *separate app* next to v1. Your
  v1 app and its Sheet keep working.
- **The beta makes its own new sheet.** "Create my Inventory sheet" creates a brand-new
  `DeckCheck Inventory` spreadsheet in your Drive. It never touches your existing v1
  Sheet, so the write self-test is safe.

---

## A. One-time Google Cloud setup (~10 min)

Follow **[`google-oauth-client.md`](google-oauth-client.md)** — the full step-by-step.
The one value to use consistently:

- [ ] When you create the **iOS OAuth client**, set **Bundle ID = `com.example.DeckCheck`**
      (exactly — it must match the app). iOS clients have **no client secret** and no
      redirect URIs to configure; the app handles the redirect automatically.
- [ ] Consent screen: **External**, **Testing**, add **yourself** as a test user, scopes
      **`spreadsheets` + `drive.file`** only (never `drive`).
- [ ] Copy your **Client ID** (`…apps.googleusercontent.com`).

> Testing mode expires the refresh token every ~7 days → you'll re-tap "Sign in" about
> weekly. The app handles it. See the OAuth guide for the "publish to production +
> click through the unverified warning" alternative if you'd rather avoid that.

## B. Build v2 to your phone

- [ ] Merge the PR, then pull `main`. **Signing conflict note:** because your Xcode has
      written your Team (and now the bundle id changed), the pull may conflict on
      `project.pbxproj` — resolve with
      `git stash push -u -m mine && git pull && git stash apply` (then re-set your Team
      if needed).
- [ ] Open `ios/DeckCheck.xcodeproj` in Xcode.
- [ ] Target **DeckCheck → Signing & Capabilities**: pick your **Team**; confirm
      **Bundle Identifier = `com.example.DeckCheck`**.
- [ ] iPhone: **Settings → Privacy & Security → Developer Mode → on** (one-time, iOS 16+).
- [ ] Plug in your iPhone, select it as the run destination, **⌘R**. (Free Apple ID →
      the app is signed for 7 days; the $99 Developer Program → a year.)
- [ ] You should now have **two** app icons: your v1 app and the new v2 build.

## C. Test the Sheets beta

In the **v2** app:

- [ ] **Settings → Google Sheets API (v2 beta)**.
- [ ] Paste your **Client ID** into the field.
- [ ] **1 · Sign in with Google.** A Google sheet slides up. Because the app is
      unverified/testing, you'll see **"Google hasn't verified this app"** →
      *Advanced → Go to … (unsafe)* → grant the Sheets + Drive permissions. Expect
      **"Signed in"** with a green check.
- [ ] **2 · Create my Inventory sheet.** Expect **"Created — Inventory sheet is ready"**
      and an **Open in Google Sheets** link. Tap it — you should see a new sheet with the
      header row (`name, set, code, number, qty, location, card_id, equivalence_key,
      norm_version`).
- [ ] **3 · Test read.** Expect **"Read OK — 0 data row(s), 9 columns."**
- [ ] **3 · Test write.** Expect **"Write self-test passed — append + delete
      round-tripped."** (It briefly adds a `SELF-TEST` row, confirms it, then deletes it —
      watch the sheet if you like.)

## D. Report back

Tell me which steps passed and paste any **"Status"** error text (it includes the HTTP
code + Google's message). Likely first-try snags and what they mean:

- **`redirect_uri_mismatch` / won't return to the app** → the OAuth client type isn't
  **iOS**, or the bundle id doesn't match `com.example.DeckCheck`.
- **`access_denied`** → you're not added as a **test user** on the consent screen (or you
  hit Cancel).
- **HTTP 403 on create/read** → the **Sheets API and/or Drive API aren't enabled** in the
  project, or the scopes are wrong.
- **Sign-in sheet never appears** → the Client ID is malformed/empty.

---

## What this proves (and what's next)

Passing C end-to-end proves the whole 2a–2c pipeline on real hardware: PKCE sign-in →
token exchange/refresh → create/seed the sheet → read into `SheetTable` → plan an
intake/removal → execute `values.batchUpdate` / `append` / `deleteDimension`.

It is **not yet** wired into the real capture/gap-check flows — that's **milestone 3**
(the durable outbox flushing to this service, replacing v1's Apps Script path). This
beta screen is the proving ground that de-risks that step.

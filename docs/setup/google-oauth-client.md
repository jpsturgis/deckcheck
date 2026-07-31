# Setting up your own Google OAuth client (v2)

v2 talks to **your** Google Sheet through the Google Sheets API using **your own
OAuth client** — one you create in your own Google Cloud account (spec
[v2 §8.2](../spec/v2.md)). Nothing is hosted by anyone else; the app signs in as
you and only ever touches the files it creates. This is a **one-time, ~10-minute**
setup. It's the trade for needing no App Store, no shared server, and no Google
app-verification.

Why you do this yourself: an app that asked Google for *sensitive* scopes under a
*published, shared* client would need Google's verification (a CASA security audit).
By making your **own** client with **yourself as the only user**, that whole burden
disappears — an unverified client is fine for your own account.

## What you'll end up with

A single **iOS OAuth client ID** string (looks like
`407408718192-abc123.apps.googleusercontent.com`) that you paste into the app. No
client *secret* — an iOS client is a public, PKCE-based client, so there's no secret
to store or leak.

## Steps

1. **Create a project.** Go to <https://console.cloud.google.com/>, and create a new
   project (top bar → project dropdown → *New Project*). Name it anything, e.g.
   `deckcheck`.

2. **Enable the two APIs.** APIs & Services → *Enable APIs and Services*, then enable:
   - **Google Sheets API**
   - **Google Drive API**

3. **Configure the OAuth consent screen.** APIs & Services → *OAuth consent screen*:
   - User type: **External**. (There's no "Internal" unless you're on Google
     Workspace; External + testing is the personal path.)
   - App name, your email for support/developer contact — anything reasonable.
   - **Scopes:** add exactly these two, and **no others** — in particular *not* the
     broad `.../auth/drive` scope:
     - `.../auth/spreadsheets`
     - `.../auth/drive.file`
   - **Test users:** add **your own Google account** as a test user.
   - Leave the publishing status as **Testing**.

4. **Create the OAuth client ID.** APIs & Services → *Credentials* → *Create
   Credentials* → *OAuth client ID*:
   - Application type: **iOS**.
   - Bundle ID: the app's v2 bundle identifier (the app tells you this on the setup
     screen; it's a distinct id from v1 so both can live on your phone).
   - Create, then **copy the Client ID**.

5. **Paste it into the app.** On first launch, the app's setup screen asks for this
   Client ID, then does "Sign in with Google" and creates your **Inventory** sheet in
   your Drive. Done.

## Honest caveats (read these)

- **Testing-mode refresh tokens expire after 7 days.** While your client stays in
  "Testing", Google expires the app's refresh token weekly, so **you'll re-tap "Sign
  in with Google" about once a week.** The app handles this gracefully — it detects
  the expired token and re-prompts; your Sheet and local data are untouched. For a
  personal tool this is usually fine.
- **Want to stop the weekly sign-in?** Set the consent screen's publishing status to
  **In production**. Because the app is still *unverified*, Google shows a one-time
  **"Google hasn't verified this app"** warning — click *Advanced → Go to
  deckcheck (unsafe)* to proceed (you are the developer and the only user, so this
  is expected). After that, refresh tokens no longer expire on the 7-day clock. You do
  **not** need to complete verification for your own personal use.
- **Never add the `drive` scope.** `drive.file` already lets the app create and open
  the one Sheet it makes. The broad `drive` scope is what would drag you into
  verification/audit territory — the app never requests it, and neither should your
  consent screen.

## Security notes

- The Client ID is **not a secret** — it's safe to keep in the app / commit in your
  own fork's config. There is no client secret for an iOS client.
- The app requests `drive.file`, so it can only see files **it** created or that you
  explicitly open with it — never the rest of your Drive.
- Tokens are stored in the iOS Keychain on your device.

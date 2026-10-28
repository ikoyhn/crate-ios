# Crate for iOS

A native iPhone companion app for [Crate](../crate), the self-hosted, Spotify-style playlist curator
for Navidrome. Everything you'd do in Crate's web UI, from your phone, plus a proper music player.

* **Home:** Up Next (songs like the one playing), recently played and recently added albums,
  frequently played albums, random albums, your top played songs and your song history, all
  from Navidrome. Top played and history use Navidrome's own API, so they need Navidrome itself
  rather than another Subsonic server.
* **Liked Songs:** every song you've ♥'d, newest first.
* **Playlists:** Discover Weekly, Release Radar, Daily Mixes, prompt playlists and your own Navidrome
  playlists, with each track's state (New in the inbox, Kept, Added by you).
* **Curation:** ♥ and ★ ratings on any song, from the list, Now Playing or the lock screen. On a new
  inbox track a ♥ or 4-5 ★ keeps it and 1-2 ★ removes it, straight away rather than at the next
  15-minute check. **👎 Not for me** on a new track (or swipe) deletes it and blocks it from coming
  back; swipe to **Keep**.
* **Add to playlist…** on any song (long-press, swipe, or Now Playing): into one of your Navidrome
  playlists, or a new one. Inbox tracks are kept first, so they aren't deleted when they expire.
* **Suggested songs** for every playlist: 30-second previews of new songs, plus songs from your
  library on your own playlists, each with its reason. **Add** (new songs are downloaded first),
  **👎** with Undo, **Refresh** for a different batch.
* **Regenerate:** Rebuild now on any playlist, Run now on every job, with progress in a banner,
  **Stop all**, and each run's live log.
* **Prompt playlists:** describe what you want to hear, choose its size, new songs and weekly
  refresh. Rebuild or forget them later.
* **Search** Deezer's catalogue, preview, and add songs or whole albums to your library.
* **Activity:** runs and logs, inbox decisions, connection health, discovery history with
  **Clear discovery history**.
* **Downloads:** save any song (long-press) or a whole playlist (⋯ menu) to the phone and play it
  with no connection. Downloaded playlists follow the playlist: when Discover Weekly is rebuilt or
  you ♥ a new song, opening Playlists online downloads the new songs and clears out the old ones.
  Everything saved is under **Playlists › Downloads**. Downloads use the streaming quality you
  chose; formats iOS can't play from a file are saved as 320 kbps MP3.
* **Player:** streams from Navidrome at full quality (or a chosen bitrate) and scrobbles, so plays
  count as usual. Background audio, lock-screen and Control Centre controls with a ♥ button,
  queue, shuffle and repeat. Or skip Navidrome and stream through Crate.

## Requirements

* Crate from the same release as this app. The app uses `/api/ping`, `/api/info`,
  `/api/songs/{id}/like`, `POST /api/own-playlists` and the `run_id`s that actions return.
* iOS 17 or later; Xcode 16 or later to build it.
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project: `brew install xcodegen`.

## Building

```bash
xcodegen generate
open CrateCompanion.xcodeproj
```

Choose your team under *Signing & Capabilities* (or set `DEVELOPMENT_TEAM` in `project.yml`), pick
your iPhone, and Run. A free Apple ID works for installing on your own phone; the app then needs
re-installing every 7 days. A paid developer account lasts a year, and lets you use TestFlight.

### Getting an .ipa from GitHub

Push this repository to GitHub and the **ipa** workflow (`.github/workflows/ipa.yml`) builds
`Crate.ipa` on every push to `main`. Download it from the run's *Artifacts*. Tags like `v1.0.0`
also attach it to a GitHub release, with that version number.

* **No secrets set:** an unsigned `.ipa`. Install it with AltStore, SideStore or Sideloadly,
  which sign it with your own Apple ID as they install it.
* **Signed:** add `IOS_CERTIFICATE_P12` (base64 of your `.p12`), `IOS_CERTIFICATE_PASSWORD`,
  `IOS_PROVISIONING_PROFILE` (base64 of the `.mobileprovision` for `app.crate.companion`),
  `IOS_TEAM_ID`, and optionally `IOS_EXPORT_METHOD` (`ad-hoc`, `development` or `app-store`) as
  repository secrets. This needs a paid Apple developer account.

The non-UI code is a Swift package, `CrateKit`, that builds and tests anywhere Swift runs, Linux
included:

```bash
cd CrateKit && swift test
```

Its test fixtures are real answers from Crate's API, so the tests catch the app and server drifting
apart. To regenerate them after an API change, see `CrateKit/Tests/CrateKitTests/Fixtures/README.md`.

## Setting up Crate for the app

In Crate's `.env`:

```bash
# Required if Crate is reachable from outside your home network. Generate one with: openssl rand -hex 24
API_TOKEN=...
# Navidrome's address as your phone reaches it, if NAVIDROME_URL is a Docker-internal name
NAVIDROME_PUBLIC_URL=https://music.example.com
```

Then in the app, enter Crate's address (for example `192.168.1.10:8090`), and its token if it asks.
The app fills in Navidrome's address and user from Crate; add your Navidrome password. Use the
**same Navidrome user Crate uses**, so the likes you make in the app are the ones Crate reads.

Away from home, put Crate and Navidrome behind a VPN like Tailscale or WireGuard, or a reverse
proxy with HTTPS. Plain `http://` works on your local network.

## Layout

```
project.yml                 XcodeGen spec (generates CrateCompanion.xcodeproj)
CrateKit/                   Swift package: models, Crate API client, Subsonic client, play queue
CrateCompanion/
  App/                      entry point, AppModel (connection, status, actions, run tracking)
  Player/AudioPlayer.swift  AVPlayer, lock screen and remote commands, scrobbling
  Views/                    Setup, Playlists (+ Suggested), Player, Search, Automations, Activity
  Support/Keychain.swift    the token and password are kept in the Keychain
```

## Credits

Built after looking at the open-source Navidrome clients for iOS, in particular
[Vibrdrome](https://github.com/ddmoney420/vibrdrome) (MIT): the lock-screen and audio-session
handling follows its approach, and the XcodeGen setup follows its `project.yml`. Also
[flo](https://github.com/kepelet/flo) (MIT) and [SwiftSonic](https://github.com/CassetteLab/SwiftSonic)
(MIT). The Subsonic client here is deliberately small (stream, cover art, scrobble), because
everything to do with curation goes through Crate.

# Koda — map for Claude

A YouTube Music client in SwiftUI: an iPhone app plus a Mac Catalyst app (Mac idiom, macOS 26, universal). iOS 26 deployment target, Liquid Glass. Swift 6, `@Observable`, no third-party packages. The Apple sibling of Koda for Android (`E:\Ivors\Developement\open-source\Koda`), built for Apple's platforms rather than ported: copy Android's ideas where they serve users here, never its layouts or habits.

## Rules

- **Keep this file current.** Every change that adds a feature, file, setting, persisted key or non-obvious decision adds or updates a short line here: where it lives and how it works. Short entries, no history; history goes in commits, Mac design notes in `docs/mac.md`.
- **SwiftUI defaults first.** System controls, materials, transitions and APIs (`safeAreaBar`, `scrollEdgeEffectStyle`, `navigationTransition(.zoom)`, `ContentUnavailableView`, `.glassEffect`) over hand-rolled ones. No hacks to fight the framework.
- **iPhone UI stays as it is** unless the task is about it. The Mac has its own views; shared screens branch with `if Platform.isMac { macBody } else { phoneBody }`.
- New `.swift` files are picked up automatically (synchronized folders); no pbxproj edits needed.
- The app target defaults to **MainActor isolation**: value types used off the main actor (Codable snapshots, anything sent to `Task.detached`) need `nonisolated struct/enum`.
- Comments explain *why*, in plain sentences, matching the existing style.

## Layout

```
KodaCore/            Swift package: everything below the UI (has tests)
  InnerTube/         YouTubeMusic API (InnerTube.swift), PageCache (10-min in-memory page cache), StreamResolver, VisitorIdentity
  Parsing/           JSON → models (Pages.swift, Rows.swift); Rows.isVideo detects music videos
  Models/            Song, Artwork, *Summary, Shelf, MusicItem, Mood (all Codable), YouTubeLink
  Playback/          Player (AVPlayer, queue, remote commands, persistence), PlayQueue, CachingLoader
  Library/           Library (liked, recent, stats, user playlists, Not Interested → library.json; dated plays → history.json), Taste (mix seeds),
                     AccountMirror (Library.reconcile: two-way account sync bookkeeping), TasteProfile (taste setup picks, in library.json),
                     AndroidBackup (reads Koda for Android's backup zip; Library.importAndroid merges it)
  Storage/           AudioStore (song cache + downloads; completeSongs = Ready Offline), Downloads, ZipReader
  Lyrics/, LastFM/   lyrics sources + parsing; Last.fm scrobbling
  Discord/           Rich Presence on the Mac: DiscordActivity (card + wire format), DiscordIPCConnection (socket), DiscordPresence (when to show)
  Video/             YouTube itself on the WEB client: VideoModels (Video, ChannelRef, WatchPage, ChannelPage, VideoStream),
                     VideoPages (parsers: videoRenderer + lockupViewModel rows, each page's own continuation), VideoTube (API)
  Profiles/          ProfileRoster (KodaProfile list + active, profiles.json, a folder per profile), KodaAvatar (drawn faces)
  Account/           signed-in YouTube Music: YouTubeCookies, SAPISIDHash, AccountSessions (active session, rotation, verdicts),
                     AccountKeychain, AccountAPI (library + writes on YouTubeMusic), PlaybackHistory (plays → the account's YouTube history);
                     parsers in Parsing/AccountPages.swift
Koda/                the app target
  App/               KodaApp (+ .appEnvironment), AppModel (long-lived objects), AppSettings (UserDefaults prefs),
                     Route (every pushable page), RootView (iPhone tabs), MacShell (Platform.isMac, MacPlayerBar, menu bar KodaCommands),
                     Snapshot (on-disk JSON of pages for cold launch)
  Screens/           iPhone screens (+ Mac bodies of shared ones): Home (HomeModel), Search (SearchModel), Album, Artist, Playlist, Settings…
  Mac/               Mac-only: MacRootView (sidebar, sections, Up Next glance), MacHomeView, MacBrowseSearch, MacComponents, MacSettingsView
  Video/             VideoPlayback (the one AVPlayer + AVPlayerViewController), VideoModels (feed/search/watch/channel models),
                     VideoHomeView (feed, search, Recently Watched), VideoWatchView, ChannelView, VideoComponents (thumbnail, card, row)
  Onboarding/        OnboardingView (welcome → account → taste), TasteModel, TasteSetupViews (artists grid, genre chips, deck), TastePreview
  Player/            NowPlayingView (+ TransportControls), MiniPlayer (PlayPauseButton), QueuePanel, lyrics views, SleepTimer
  Components/        SongRow, Cards, ShelfView, Loading (LoadState, AsyncContent, placeholders), SongActions (SongMenuItems)
  Images/            ArtworkView, ImagePipeline (downsampled, memory + 300 MB URLCache on disk), Palette
  Intents/           KodaIntents (App Intents + App Shortcuts + Spotlight, iPhone and Mac),
                     SiriSchemas (iOS 27 audio schemas for the new Siri; only built with the iOS 27 SDK, never Catalyst)
Shared/              compiled into the app AND KodaWidgets: PlaybackIntents (PlayLikedSongs, TogglePlayback)
KodaWidgets/         widget extension (ivors.Koda.Widgets): Quick Play widget (Home/Lock Screen, Mac), Control Center controls
docs/                mac.md (Mac decisions and scars), lastfm.md
Koda-Info.plist      extra Info.plist keys: URL scheme koda://, background audio, permission strings
.github/workflows/   build.yml: tests KodaCore, builds the unsigned .ipa (xcode-27) and the universal .dmg (macos-26)
```

## How things work

- **Environment:** `AppModel` owns `Player`, `Library`, `Downloads`, `LastFM`, `settings`. Views read them with `@Environment(X.self)`. Anything *presented* (sheet, cover, popover) must add `.appEnvironment(model)` or it crashes on Catalyst.
- **Settings:** add a property to `AppSettings` with a `didSet` that writes UserDefaults (`koda.*` keys), read it in `init`, then show it in both `Screens/SettingsView.swift` (iPhone Form) and `Mac/MacSettingsView.swift` (pane, `MacSettingsGroup`/`MacSettingsToggle`/`MacSettingsRow`). Player-owned prefs (autoplay, normalize, cache while streaming, volume) live on `Player`.
- **Navigation:** push with `NavigationLink(value: Route.…)`; from outside a stack use `model.open(route)`. The Mac keeps one path per sidebar section (`paths[MacSection]`); Now Playing on the Mac is `Route.nowPlaying` pushed with the zoom transition.
- **Mac toolbar:** never hide/remove the toolbar or sidebar toggle at runtime; change what the detail column shows instead (see `docs/mac.md`).
- **Loading:** pages use `LoadState` and draw their own layout redacted from a placeholder while loading (`.loadingPlaceholder()`).
- **Cold launch:** `HomeModel` restores its last `Snapshot` ("home") in `init` and refreshes in place when `needsRefresh`; Search's mood tiles restore from "moods". To make another page open from cache, give it a Codable state and use `Snapshot.load/save` the same way.
- **Artwork:** always `ArtworkView` (square crop; YouTube video thumbnails are letterboxed 4:3 and are scaled to hide the bars). Images that fill a frame go in an `.overlay` of a fixed shape so their own size never drives layout.
- **Skip buttons:** `AppSettings.showsSkipButtons` / `skipInterval` (5/10/15/30 s, `gobackward.N`/`goforward.N` symbols) → `Player.skip(by:)`. Shown in `TransportControls` (Now Playing) and `MacPlayerBar`; ⌥⌘←/→ in the Controls menu. Lock-screen skip commands stay off so next/previous remain there.
- **Sidebar foot (Mac):** `MacSidebarGlance` shows the next song and today's listening, attached with `safeAreaBar` so the list gets the system scroll-edge effect under it.
- **Crossfade:** `Player.crossfades` / `crossfadeDuration` (default on, 5 s, 1–12). With it on, the next song waits on a separate paused `AVQueuePlayer` (`standby`) instead of behind the current item; a boundary observer at end − duration calls `switchToStandby`, which retires the old player to `tail` (fading out, equal-power) and adopts the standby as `avPlayer` (`attach`/`detach` move the KVO + time observers; callbacks from a non-main player are dropped). Skips fade by `Player.skipFade` (0.6 s). AVFoundation can't move an item between players (`_attachToPlayer` throws), hence two players. Off, the old gapless queue path is unchanged. Repeat one crossfades into the song's own start (the standby holds the same occurrence); a preloaded copy of the current occurrence becoming current is a loop, which resets `startedReported` so history, stats and Last.fm count a new play. `sampleTime` republishes Now Playing whenever a sample changes the rate or drifts > 1 s, or the Lock Screen keeps a stale (frozen) clock. Live tests: `KODA_LIVE=1 swift test --filter LivePlayerTests`.
- **Queue panel:** the list is *not* in edit mode (edit mode turns swipe actions off): long-press drags to reorder, swipe left removes, swipe right plays next, the context menu has both plus Like/Add to Playlist/Go to; Remove and Clear offer Undo for 6 s.
- **YouTube accounts (KodaCore/Account):** `YouTubeMusic.accounts` (`AccountSessions`) holds the active profile's session; the app calls `activate` (launch/switch, keeps cookies rotated this run), `signIn` (fresh login: new generation, saved), `deactivate` (device-only profile), `forget` (signed out/removed). While one is active every `InnerTube.music` call sends Cookie, `SAPISIDHASH` for https://music.youtube.com, X-Origin and X-Goog-AuthUser 0, plus visitorData as before; streams (`StreamResolver`) stay anonymous, as on Android. The URLSession keeps no cookies at all (no jar, so profiles never mix). Only youtube.com cookies are kept (google.com's SAPISID signs in as anonymous). Rotated `Set-Cookie`s are merged into the profile the request was for, if that sign-in (generation) still exists, and saved through `AccountCookieStore`; deletions are never applied. Cookies live in the Keychain via `AccountKeychain` (service `ivors.Koda.youtube`, account = profile UUID, after-first-unlock this-device-only, file fallback for builds without a Keychain); `read` is found/missing/unreadable and unreadable is *not* signed out. The only verdict is `responseContext.serviceTrackingParams` `logged_in` (0/1), published on `accounts.verdicts` once per change; HTTP 200 proves nothing (a dead session reads public pages fine); a write under a dead session answers 401 → `MusicError.signedOut`. `PageCache` keys are prefixed with the profile + generation, so no clear is needed on a switch. Library/write parsers rest partly on reconstructed fixtures (see `AccountTests.swift`); `KODA_LIVE=1 swift test --filter deadSession` checks the signed path against real YouTube.
- **Profiles:** `AppModel.roster` (`ProfileRoster`); each profile owns `Profiles/<uuid>/` (library.json, history.json, photo.jpg, account.json). One `Library` serves the app and `switchProfile` points it at another folder (`Library.open`), makes a new `HomeModel`, and pops every stack: no network, instant. Device profiles never sign requests. Toolbar avatar (iPhone) / sidebar foot (Mac) menus list profiles with "Switch to <previous>" on top (`AppModel.quickSwitchTarget`, Android's rule: the previous one, or the other of exactly two). An install from before profiles is moved into the first one.
- **Account wiring (`Koda/App/Accounts.swift`):** `YouTubeMusic` is made with `AccountSessions(store: AccountKeychain)`, so rotations are saved. Session changes and writes run one at a time through `AppModel.accountWork`, and every write checks `accounts.active?.profileID` is still its profile, so nothing goes out as the wrong account after a switch. `completeSignIn` signs in under a trial id, asks `accountInfo`, then `roster.addAccount` (repairs a known `datasyncId`, `into` converts that profile in place) and moves the session to the profile's id if it differs; a failed check forgets the trial and restores the previous session. `moveSession` (switch/delete) activates the new profile's Keychain session (missing → `isExpired`, unreadable → retried when the app is next active, not expired) and renews the visitor identity when an account is on either side, as Android does. `accounts.verdicts` sets/clears `isExpired`. Sync: `syncAccount` (launch, switch, sign-in, foreground every 15 min, Library pull to refresh, Sync Now) sends pending changes, reads liked/albums/playlists/artists, and `Library.reconcile` merges them using the profile's `AccountMirror` (account.json): items removed on the account since last seen are dropped here, items only ever here stay, items with an unsent change aren't touched. The listener's likes/saves reach the account through `library.onChange` → queued in the mirror → sent (albums via their audio playlist id); network/429/signed-out keep them queued, other refusals drop them. Playlists made in Koda stay local (not created on the account yet). Home waits for the session to settle (`AppModel.loadHome`); signed in, Quick picks are the songs on the account's own YouTube Music Home (`ShelfPage.songs`, as Android), falling back to a radio of the last played or newest liked song, then trending; Your Mix seeds from liked songs while nothing has been played on the device (`Taste.fromLiked`), and Home reloads after a profile's first sync.
- **YouTube history:** `YouTubeMusic.reportPlayback` = Android's PlaybackHistory: a signed WEB_REMIX `/player` with `cpn` and `playbackContext.contentPlaybackContext.signatureTimestamp`, then a signed GET to `playbackTracking.videostatsPlaybackUrl` (only `s.youtube.com`/`www.youtube.com`, https; `cpn`, `ver=2`, `c=WEB_REMIX` set). Without the timestamp every video is "unavailable" with no tracking. `PlayerSignatureTimestamp` reads it from the live player (`iframe_api` → `base.js`, `koda.sts.*` defaults, rechecked daily) or estimates it (epoch day − 14) and retries once on a rejection. `logged_in` 0 → `signedOut` (a dead session still gets tracking URLs and a 204). The app reports after 15 s heard per occurrence (`HeardThreshold`, fed from `player.onItemHeard`) through `accountWork`, only when the profile's `KodaProfile.sendsPlaysToYouTube` (default on; switch in the account section on both platforms and on onboarding's account page) and listening history are on.
- **Onboarding / taste:** `AppModel.onboarding` (`OnboardingView.Start`) shows the welcome on a new install only (`AppSettings.hasSeenOnboarding`, `koda.onboarding.seen`; an install with a library is marked seen silently): fullScreenCover on iPhone, sheet on Mac. Pages push on one stack: Welcome (`KodaIcon` asset = docs/icon.png), account (sign in into the active profile; then the YouTube history switch), artists (picks from the library first, then "fans also like", then local + US chart artists via `chartArtists`; search; each pick inserts 4 similar after it), genres (`TasteProfile.genres`, `ChipFlow` layout), deck (≤ 18 cards from picked artists' top songs, genre searches and one radio; skip hides, keep → `taste.songs`, love also likes; `TastePreview` plays a third of the way in on its own AVPlayer and pauses the app's player, so previews never count as plays), done. Every pick saves at once to `Library.taste`. Settings → Your Taste (iPhone) / Profiles → Taste (Mac) reopen taste setup alone. Home uses it with no history: Quick picks seed from liked then kept songs, Your Mix from liked + kept (`Taste.fromLiked`) or else the picked artists' top songs.
- **Videos:** WEB InnerTube on www.youtube.com (`InnerTube.web`, `Site.web`; signed in it is signed for that origin, so Home is the account's). Search still sends `videoRenderer`; Up Next, channels and the signed-in Home send `lockupViewModel` (contentType VIDEO with a `watchEndpoint`; two metadata lines = channel, then views · age; one line on a channel's own tabs, where the channel is the page's). Shorts are skipped. Every list's continuation comes from that list's own end, never the response's last token (channel pages end with the About panel's, search with a filter's); `moreVideos(_:from:)` sends it to browse/search/next. Channel pages ask for the Videos tab (`params EgZ2aWRlb3PyBgQKAjoA`). Signed out YouTube sends an empty Home, so `VideoFeedModel` builds one: Up Next of the last six watched (`Library.watched`, in library.json, cleared with history), else searches for taste artists, else popular. Streams are the visionOS `/player`'s `hlsManifestUrl` (`StreamResolver.resolveVideo`, same token-replacement rule as audio), played by AVPlayer as is: adaptive quality, no headers needed, PiP/AirPlay/full screen from `AVPlayerViewController`. A video starting pauses the songs and a song starting pauses the video; leaving the watch page pauses it unless another video took over or it is in PiP. **Modes** (as Android): `AppSettings.mode` (`koda.mode`, music/video) set by `ModeToggle` (segmented, top-leading on both Homes on iPhone; the head of the Mac sidebar, `safeAreaBar(edge: .top)`). iPhone tabs follow it: music = Home, Library, Search; video = Home (`VideoHomeView`), Subscriptions (signed in), Library (`VideoLibraryView`, watched), Search (`VideoSearchView`, role .search). `AppTab.mode` ties each tab to its mode (menu-bar `go(to:)` switches mode). Mac sidebar shows only the mode's places (video: Home, Subscriptions, Watched, Search Results); the toolbar search searches YouTube in video mode; wide windows (≥ 1020) put Up Next in its own column. Player: Koda's own controls (`VideoPlayerView` over an `AVPlayerLayer`), not AVPlayerViewController, so the same controls work inline and full screen: top = back (iPhone inline), AirPlay (`AVRoutePickerView`), PiP (`AVPictureInPictureController` on the front surface's layer), settings menu with Quality (Auto or a cap from the manifest's `RESOLUTION`s, `VideoStream.qualities`, applied as a square `preferredMaximumResolution`, kept in `koda.video.quality`), Speed (0.5–2×, `defaultRate`) and Captions (the HLS manifest carries YouTube's caption tracks as SUBTITLES groups: `.legible` selection); centre = ±10 s and play/pause; bottom = scrubber (1:1 drag, seeks on release), times, full screen. They fade after 3 s playing; tap (or hover on Mac) brings them back. `VideoPlayback` keeps time/playing/buffering from a 0.25 s periodic observer. Full screen is a `fullScreenCover` (`FullScreenVideoView`); the iPhone app is portrait-only except there: Info.plist lists landscape, `KodaAppDelegate` returns `Orientation.allowed` (portrait unless full screen), `requestGeometryUpdate` turns to landscape for a landscape video; turning the phone sideways on the watch page enters full screen and upright leaves it. iPhone watch page: no navigation bar (back is on the video; `InteractivePopEnabler` keeps the edge swipe), no tab bar. Subscribe goes through `AppModel.setSubscribed` (account queue). Live test: `KODA_LIVE=1 swift test --filter videoSearchWatchChannelAndStream`.
- **History / Suggest Less:** `Route.history` / `MacSection.history` → `HistoryView` (every play from `Library.history` by day, swipe or menu removes one). Suggest Less (`NotInterestedMenu` on song menus) is managed in History and Privacy (`SuggestLessView` on iPhone, `MacSuggestLessGroup` in the Mac pane); Home, Taste, radio and autoplay (`Player.isUnwanted`) leave hidden songs/artists out.
- **Last.fm credentials:** Keychain read returns found/missing/unreadable. Unreadable (locked device, Mac keychain locked) is *not* signed out: `connectedUser` (in lastfm.json) keeps it shown connected, plays queue, every call re-reads first, and nothing writes over the saved credentials until read (`saveCredentials(replacing:)` only for sign-in).
- **Discord (Mac only):** `AppSettings.sharesOnDiscord` (`koda.discord.presence`, off by default; Settings → Discord) and listening history on → `AppModel.discord` (`DiscordPresence`, watches the player) shows "Listening to" on the profile through the Discord app's local socket (`$TMPDIR/discord-ipc-N`; works because the Mac build has no App Sandbox). Same application id as Koda for Android (`1556607739231346708`). Same rules as Android: a frame only when the card changes or the bar drifts > 3 s, paused card taken down after 60 s, connection released when nothing shows, Discord looked for / checked every 15 s, at most 5 updates per 20 s. A refused card is resent without the newer fields (`DiscordActivity.basic`). iPhone can't: iOS Discord has no local RPC; it would need the Social SDK with account linking.
- **Ready Offline:** `Route.SongSource.offline` / `MacSection.offline` → `SavedSongsView` listing `AudioStore.completeSongs` (downloads + songs cached whole).
- **Android import:** Settings → Back Up and Restore → Import from Koda for Android (both platforms, `androidBackupImporter` modifier). Takes liked songs, play history (→ stats, daily listening, recent), searches, user playlists, saved albums (MPREb ids) and playlists from the active profile; skips local files. Merges; `androidPlaysImportedThrough` stops plays counting twice. Fixture is a real Java-written zip.
- **Mac window:** min 700×520. Never let page content set the detail column's *minimum* width: `NavigationSplitView` reads it, and a page that won't fit beside the sidebar gets the sidebar floated over it and runs off the window (seen after hiding/showing the sidebar). `MacPage` wraps content in `.frame(minWidth: 0, maxWidth: .infinity)`; anything that measures its width (`onGeometryChange`) measures such a flexible frame, never content whose size it then fixes (`MacGrid`'s fixed columns once held it at its old width). Pages that put two columns side by side switch to one under a width (`onGeometryChange` + `AnyLayout`): Home's mix/picks, search's top result, Last.fm, collection headers (smaller cover < 620), player bar (narrow < 760: 270 pt transport, speaker-only volume). Search is `.searchable(placement: .toolbar)` (top right); Home's Refresh is in its page title (⌘R), like Last.fm's Sync Now.
- **Siri / Shortcuts:** intents get the app through `@Dependency var app: AppModel` (registered in `KodaApp.init`). Audio intents run in the app, which the system starts in the background. `IntentsIndex.update` (on launch and when liked songs/playlists change) refreshes App Shortcut parameters and Spotlight. iOS 27 schema code sits in `#if canImport(MediaIntents) && !targetEnvironment(macCatalyst)` + `@available(iOS 27, *)`; schema macros wrap the schema's properties, so in an init set `id` and plain stored properties *first*. Reference: Apple's "Integrating your music app with Apple Intelligence" sample. CI's iOS job runs on `xcode-27` for this.
- **Widgets:** no App Group (the unsigned .ipa / ad-hoc .dmg can't carry one reliably), so widgets draw nothing from the app: buttons running `Shared/PlaybackIntents.swift` intents, which execute in the app (audio intents). Intents shared with the extension use `#if WIDGET_EXTENSION` (set in KodaWidgets' build settings) to stub `perform` there. Controls are iPhone-only (`#if !targetEnvironment(macCatalyst)`). A new widget needing app data would need an App Group plus entitlements in CI signing.
- **Share Lyrics:** `LyricsShareSheet` scrolls to the line it was opened from; on the Mac it has its own layout (preview left, lines right, Cancel/Copy Image/Share in the foot, `.presentationSizing(.fitted)`).
- **App icon:** `Koda/AppIcon.icon` (Icon Composer, Liquid Glass layers), used by the app's AppIcon setting; no asset-catalog icon (two named AppIcon would clash). Xcode 26's actool crashes on Xcode 27-only keys (top-level `features`, per-group `specular`), and Xcode 27 can't run on the Intel dev Mac, so strip those keys when re-exporting. `docs/icon.png` (README) is the 256 px render from the built app's AppIcon.icns.
- **Persistence:** queue (`Player.persistQueue`), library JSON and audio store are flushed in `AppModel.saveState()` when the app leaves the screen.

## Machines

Work happens on two machines. Check which one you're on before building anything.

### The Intel Mac

- Slow. Quick checks only: `swift build`/`swift test` in `KodaCore`, or an incremental Debug Catalyst build into `build/macdbg`.
- **Checking things you can't see:** add a temporary probe behind an environment variable that writes to stderr, run the Debug Catalyst build, read the output, then remove the probe before committing.

### The Windows PC

- **Windows 11, no Mac, no iOS simulator.** Nothing in `Koda/` can be compiled or run here; CI is the only build.
- **WSL Ubuntu 24.04** lives on `E:\WSL\Ubuntu` (distro `Ubuntu-24.04`, use `-u root`). It has Swift 6.4.1 (swiftly: `. /root/.local/share/swiftly/env.sh`), `xtool`, `usbmuxd` and libimobiledevice.
  - xtool can't build the app yet: it needs Apple's iOS SDK from an `Xcode.xip` that the person downloads with their Apple ID into `E:\Xcode\`. When that file exists, run `xtool sdk install` on it and add an xtool package setup next to the Xcode project, leaving the project and CI as they are.
  - Even with xtool, install through AltStore, not `xtool install`: signing with the same free Apple ID can revoke AltStore's certificate (it happened once).
- **Quick Linux type-check of KodaCore** before pushing core changes (catches compile errors in seconds rather than a CI round trip). Copy the portable files into a throwaway package in WSL and `swift build`: `Models/Models.swift JSON/JSON.swift Library/*.swift Lyrics/Lyrics.swift Playback/PlayQueue.swift`. Files using AVFoundation, MediaPlayer, URLSession networking, XMLParser or NSDataDetector don't build on Linux; that is expected, not an error.
- **Shells are fragile here; write files with the file tools.** Git Bash heredocs break on Swift source (quotes, `\(…)` interpolation, backslashes): a heredoc fed to `python -` or `cat` failed with "unexpected EOF while looking for matching `''". PowerShell has its own traps (backtick escapes, `$` expansion, here-string closers that must sit at column 0, different quoting for native commands). So create and change files with Write and Edit; if a script must transform a file, write the script to `.scratchpad/` with Write and run it by path. Keep shell commands short and single-purpose: git, gh, grep, running a script.
- **Large downloads** (more than 2–3 GB) go on `E:`, never `C:`.
- Headless Edge renders HTML to images: `msedge.exe --headless=new --hide-scrollbars --window-size=1600,900 --virtual-time-budget=8000 --screenshot=out.png file:///…`. Python with Pillow is available.

### Both

- **Scratch work** (drafts, artwork, probe responses, test scripts, anything that is not part of the app) goes in `.scratchpad/` at the repository root. It is git-ignored; create it if missing, never commit from it, and never point the app or CI at it.

## Building and shipping

The optimized .ipa and .dmg come only from CI; never ship or test a local Debug build as the app.

1. Work on **`beta`**. Commit and `git push origin beta`. The `Build` workflow starts on its own (about 3–5 minutes).
2. Find the run: `gh run list --branch beta --limit 1` (check its title matches the commit), then wait for it: `gh run watch <run-id> --exit-status`.
3. **Read the log, not just the status**: `gh run view <run-id> --log | grep -E 'Test run with|BUILD SUCCEEDED|BUILD FAILED|error:'`. A run is good only with the test line and `BUILD SUCCEEDED` for each job. The build steps use `set -o pipefail`; keep it, or a failed build passes. On failure, `gh run view <run-id> --log-failed`.
4. Download and rename so Downloads holds just two short files, `Koda-<short-sha>.ipa` and `Koda-<short-sha>.dmg` (`~/Downloads` on the Mac, `%USERPROFILE%\Downloads` on Windows). gh nests each artifact in a folder named with the full SHA (`Koda-<sha>/Koda.ipa`, `Koda-mac-<sha>/Koda.dmg`), so always flatten it:
   ```sh
   sha=$(git rev-parse --short HEAD); tmp=$(mktemp -d)
   gh run download <run-id> --dir "$tmp"
   mv "$tmp"/Koda-mac-*/Koda.dmg ~/Downloads/Koda-$sha.dmg   # Mac, universal
   mv "$tmp"/Koda-[0-9a-f]*/Koda.ipa ~/Downloads/Koda-$sha.ipa # iPhone, unsigned
   rm -r "$tmp"
   ```
   Tell the person the folder path.
5. Install:
   - **iPhone:** from the **AltStore app on the phone** (My Apps → +). Not AltServer's "Sideload .ipa" on the PC, which issues a new certificate and breaks AltStore.
   - **Mac:** open the .dmg, drag Koda to Applications (replace the old one). It's ad-hoc signed and not notarized, so the first launch needs System Settings → Privacy & Security → **Open Anyway**.
6. **Release**: when the person says so, fast-forward `main` to `beta`, push, wait for the `main` run, download its IPA, check `CFBundleShortVersionString` inside it, then `gh release create vX.Y <ipa> --target main` with notes. The version is `MARKETING_VERSION` in `Koda.xcodeproj/project.pbxproj`. Keep `beta` level with `main` afterwards.
7. Push to `beta` freely for CI; merging to `main` and publishing releases are public, so do them only when asked.

### Git

- Commit as **Ivorisnoob** `<179814302+Ivorisnoob@users.noreply.github.com>`. Never with another identity: history was rewritten once to remove commits made under the person's other account.
- Commit messages: a short subject, then what changed and why, in plain sentences.
- Pull before starting: work happens on both machines, so `beta` may have moved.

### Probing YouTube

Check real responses before writing or changing a parser. Use InnerTube with `clientName: WEB_REMIX` and the `webRemixVersion` from `KodaCore/Sources/KodaCore/InnerTube/Clients.swift`, POSTing to `https://music.youtube.com/youtubei/v1/<endpoint>`. Save responses in `.scratchpad/`. Real responses make the best test fixtures (`KodaCore/Tests/KodaCoreTests/Fixtures/`).

## Code standards

- **Read the surrounding code and match it**: naming, comment density, idioms. Comments say *why*, briefly; no narrating what the code does.
- **Fix causes, not symptoms.** Before changing anything, find out why it happens (read the code, probe the data). Example: shuffle was slow because the queue never dropped played songs and saved itself on the main thread, so delaying the button wouldn't have fixed it.
- **Tests** for KodaCore logic (Swift Testing). Add one for each behaviour you add or fix.
- **Swift 6 in the app target**: strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency, and member import visibility. Lessons from earlier builds:
  - Callbacks that run off the main thread (audio taps, KVO, Speech, AVFoundation notifications) must be built in `nonisolated static` helpers; a closure written in a main-actor method crashes when another thread calls it.
  - `static let` constants and protocol conformances used from nonisolated contexts (`Layout`, `LayoutValueKey`) need `nonisolated`.
  - Import what you use (`import UIKit` for `UIColor`).
  - No `await` on the right of `??`, which is an autoclosure.
  - Long chained `map`/`filter`/`sort` with tuples can time out the type checker; split them into steps.
- **Nothing heavy on the main thread**: disk writes and JSON encoding go to the background (see `Player.persistQueue`).
- **Saved data must survive upgrades**: decode with `decodeIfPresent` and defaults, so an older file never fails to load (see `Library.Snapshot`).
- **Trust the data, not string guesses**: e.g. never split artist names on "&" ("She & Him" is one artist); use the links YouTube provides.
- **No hard-coded fake data** in anything the person sees.

## UI standards

The bar is "feels like Apple made it, on iOS 27". The person checks every build on their phone and notices a few points of misalignment.

- **Native components first**: Liquid Glass (`.buttonStyle(.glass)`, `glassEffect`, `GlassEffectContainer`), system sheets, menus, `ShareLink`, `PhotosPicker`, `ContentUnavailableView`, `sensoryFeedback`. Build custom controls only when the system one can't do the job, and then draw them yourself rather than nudging a system view's insides (the volume bar is drawn by Koda for that reason).
- **No tinted glass on content buttons**: Play and Shuffle are clear glass. Colours taken from covers must stay readable (see `CollectionHeader.readableAccent`).
- **Scroll edges are soft**: `.scrollEdgeEffectStyle(.soft, for: .all)` at the root. iOS 27 made the default hard.
- **Loading never shifts layout**: draw the real view from stand-in data, redacted (`AsyncContent(… placeholder:)`, `.loadingPlaceholder()`, `KodaCore/Models/Placeholders.swift`). Don't use hand-drawn skeleton shapes. Reserve space for late-arriving content with `@ScaledMetric`-sized slots, not fake text.
- **Motion**: system animations (`.smooth`, springs, `.snappy`), interruptible, and always respecting Reduce Motion. Direct manipulation follows the finger with no animation; changes coming from elsewhere animate.
- **Accessibility**: labels, values and actions on custom controls; Dynamic Type where layout allows; VoiceOver hears "Loading" for placeholders.
- **Lyrics** are left-aligned; duet partners go right only with Duet Sides on; the sung line rests about a third of the way down and the first line starts right under the song.
- **Check how iOS 27 actually behaves**, in Apple's documentation and current developer reports, rather than from memory. iOS changes these details yearly.
- **Don't guess at visuals you can't see**: fix what the code shows; for anything that only appears on screen, ask for a screenshot.
- **Marketing art avoids the "AI look"**: no glowing blobs on dark gradients or soft-shadow glass cards. Use editorial type (serif display, grotesk body, mono labels), paper and ink in Koda's colours (indigo `#3a2ea6`, ink `#15123f`, cream `#e6e2d3`, lime `#9be83f`), hard edges, and the real mark (`.scratchpad/artwork/assets/mark.png`, cut from the app icon).

## Working with the person

- They test on their iPhone and Mac and report with screenshots; they expect fixes that are done properly for users, not quick patches.
- Say plainly what was verified (CI tests, build) and what wasn't (anything on device).
- Lead with the result: where the build is, what changed, what to try.

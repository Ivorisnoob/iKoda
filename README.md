<p align="center">
  <img src="docs/icon.png" width="120" alt="Koda icon"/>
</p>

<h1 align="center">Koda for iPhone</h1>

<p align="center">
  <b>A YouTube Music player for iOS, written in SwiftUI with Liquid Glass.</b>
</p>

<p align="center">
  <a href="https://github.com/Ivorisnoob/Koda-iOS/releases/latest"><img src="https://img.shields.io/github/v/release/Ivorisnoob/Koda-iOS?style=for-the-badge&label=Download&color=FA5C5C" alt="Latest release"/></a>
  <img src="https://img.shields.io/badge/iOS-26%2B-black?style=for-the-badge&logo=apple" alt="iOS 26 and newer"/>
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift and SwiftUI"/>
  <a href="https://t.me/ivorisnoob_chat"><img src="https://img.shields.io/badge/Telegram-Community-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram community"/></a>
</p>

Koda plays music from YouTube Music without an account and without ads. Your library, history and stats stay on your iPhone. It is the iOS sibling of [Koda for Android](https://github.com/Ivorisnoob/Koda): music only, and built for iOS rather than ported to it.

## Download

Get `Koda.ipa` from **[the latest release](https://github.com/Ivorisnoob/Koda-iOS/releases/latest)**. Koda needs iOS 26 or later.

## Installing

Koda isn't on the App Store, so you sign it yourself with your Apple ID, using any of these:

| Tool | How |
|---|---|
| [AltStore](https://altstore.io) | With AltServer running on your computer, open AltStore on the iPhone, go to **My Apps**, tap **+** and pick `Koda.ipa`. |
| [SideStore](https://sidestore.io) | The same, without needing a computer after setup. |
| [Sideloadly](https://sideloadly.io) | Connect the iPhone to your computer, drop `Koda.ipa` in, sign in and start. |

A free Apple ID's signature lasts seven days; AltStore and SideStore renew it for you. The first time, iOS may ask you to trust your Apple ID in **Settings → General → VPN & Device Management**.

## On the Mac

Koda also runs on the Mac, as one app for Apple silicon and Intel, built for the Mac rather than stretched from the phone. It needs macOS 26 or later.

- A sidebar of Home, Browse, your library and your playlists, with search in it, and Up Next and today's listening at its foot
- Albums and playlists with the cover beside the details and the songs in columns; double-click to play
- A player bar under every page; Now Playing opens out of its cover, with lyrics or the queue beside the cover in a wide window
- Add to Playlist as a submenu of your playlists, as in Music
- Settings in a window of its own, laid out like System Settings
- Each section remembers where you were, and pages you've just seen open at once

Builds of `Koda.dmg` come from [GitHub Actions](https://github.com/Ivorisnoob/Koda-iOS/actions): open the newest run and download **Koda-mac** under Artifacts. Open the disk image and drag Koda into Applications.

Koda isn't notarized by Apple, so the first time macOS says it can't check it. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** beside Koda. Or, in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Koda.app
```

| Shortcut | Does |
|---|---|
| Space | Play or pause |
| ⌘→ / ⌘← | Next / previous song |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⇧⌘P | Show or hide Now Playing |
| ⇧⌘L / ⇧⌘U | Lyrics / queue |
| Esc | Close Now Playing |
| ⌘1 / ⌘2 / ⌘F | Home / Library / Search |
| ⌘R | Refresh Home or Last.fm |
| ⌘, | Settings |

## Features

### Listening

- **Your Mix** on Home, woven from radios of the artists you play most, with recent listening counting more
- **Jump back in**, **Quick picks** and your top artists, all from what you play
- One row of **Charts**: global, then your region, then its genres or languages
- Gapless playback that keeps going in the background, with lock screen, Control Center and AirPlay
- Shuffle, repeat, autoplay radio and a queue you can drag to reorder
- Swipe the mini player left or right to skip; a sleep timer for a set time or the end of the song
- Volume normalization, so loud masters play at a similar level to everything else

### Lyrics

- Word by word from YouLyPlus and BetterLyrics, line by line from LRCLIB, chosen automatically
- Duets on their singer's side, backing vocals under their line, long notes that swell
- Tap a line to jump to it; long-press to share up to six lines as a card in the song's colours
- Pick and reorder the sources, the text size and the motion in Settings

### Finding music

- Search with suggestions and filters for songs, albums, artists and playlists
- Search by voice, recognized on the device where the iPhone supports it
- Paste a YouTube or YouTube Music link into Search to open it; `koda://` links work from Shortcuts
- Moods and genres to browse

### Your library

- Liked songs, saved albums, playlists and artists, and playlists of your own
- A profile with listening stats: time listened each day, streaks, top songs and artists
- Back up the whole library to one file and restore it on another iPhone or a Mac
- Pause listening or search history whenever you like

### Last.fm

- Scrobble what you play to your Last.fm profile, on the iPhone and the Mac
- Off until you turn it on. Koda never asks for your password: you register your own free [Last.fm API account](https://www.last.fm/api/account/create), enter its key and secret in **Settings → Last.fm**, and approve Koda on Last.fm's page
- A song counts once you've heard half of it or four minutes, whichever comes first; seeking doesn't count, and videos aren't scrobbled
- Plays made offline wait on the device and send in order later, with the time you played them
- Your profile, scrobble count and recent plays by day; pausing listening history pauses scrobbling too
- Keys and session stay in the device's Keychain and out of backups

## Privacy

Koda has no account, no analytics and no server of its own. What you like, save, play and search is stored on your iPhone and leaves it only when you back it up. Requests go to YouTube Music for music, to the lyrics services for lyrics, and to Last.fm only if you connect it.

## Building

Xcode 26 or later. Notes on how parts of Koda work, and why, are in [`docs/`](docs).

```sh
cd KodaCore && swift test                          # unit tests
KODA_LIVE=1 swift test --filter Live               # against live YouTube, plays muted audio
xcodebuild -project Koda.xcodeproj -scheme Koda -destination 'generic/platform=iOS' build
xcodebuild -project Koda.xcodeproj -scheme Koda -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual build
```

Every push to `main` or `beta` runs the tests and builds an unsigned `Koda.ipa` and a universal, ad-hoc signed `Koda.dmg` on GitHub Actions; both are in the run's artifacts.

| Path | What |
|---|---|
| `KodaCore/` | Swift package with no UI: the InnerTube client, parsers, stream resolution, lyrics, the library, the queue and the player |
| `Koda/` | The SwiftUI app |
| `.github/workflows/build.yml` | Tests and the unsigned `.ipa` build |

## Feedback

Found a bug or want something? Open an [issue](https://github.com/Ivorisnoob/Koda-iOS/issues) or say it in the [Telegram community](https://t.me/ivorisnoob_chat).

## Thanks

Lyrics come from [LRCLIB](https://lrclib.net), YouLyPlus and BetterLyrics.

The app icon is by [sameerasw](https://github.com/sameerasw).

---

Koda is an unofficial client and is not affiliated with YouTube or Google.

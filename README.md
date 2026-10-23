<p align="center">
  <img src="docs/icon.png" width="120" alt="Koda icon"/>
</p>

<h1 align="center">Koda for iPhone and Mac</h1>

<p align="center">
  <b>YouTube Music and YouTube, in one app written in SwiftUI with Liquid Glass.</b>
</p>

<p align="center">
  <a href="https://github.com/Ivorisnoob/iKoda/releases/latest"><img src="https://img.shields.io/github/v/release/Ivorisnoob/iKoda?style=for-the-badge&label=Download&color=FA5C5C" alt="Latest release"/></a>
  <img src="https://img.shields.io/badge/iOS-26%2B-black?style=for-the-badge&logo=apple" alt="iOS 26 and newer"/>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?style=for-the-badge&logo=apple" alt="macOS 26 and newer"/>
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift and SwiftUI"/>
  <a href="https://t.me/ivorisnoob_chat"><img src="https://img.shields.io/badge/Telegram-Community-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white" alt="Telegram community"/></a>
</p>

Koda plays music from YouTube Music and videos from YouTube, without ads. Use it with no account at all, or sign in to bring your likes, playlists, subscriptions and history with you. It is the Apple sibling of [Koda for Android](https://github.com/Ivorisnoob/Koda), built for iPhone and Mac rather than ported to them.

## Download

Get **`Koda.ipa`** (iPhone) and **`Koda.dmg`** (Mac) from **[the latest release](https://github.com/Ivorisnoob/iKoda/releases/latest)**. Koda needs iOS 26 or macOS 26 or later.

## Installing

### iPhone

Koda isn't on the App Store, so you sign it yourself with your Apple ID, using any of these:

| Tool | How |
|---|---|
| [AltStore](https://altstore.io) | With AltServer running on your computer, open AltStore on the iPhone, go to **My Apps**, tap **+** and pick `Koda.ipa`. |
| [SideStore](https://sidestore.io) | The same, without needing a computer after setup. |
| [Sideloadly](https://sideloadly.io) | Connect the iPhone to your computer, drop `Koda.ipa` in, sign in and start. |

A free Apple ID's signature lasts seven days; AltStore and SideStore renew it for you. The first time, iOS may ask you to trust your Apple ID in **Settings → General → VPN & Device Management**.

### Mac

One app for Apple silicon and Intel. Open `Koda.dmg` and drag Koda into Applications.

Koda isn't notarized by Apple, so the first time macOS says it can't check it. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** beside Koda. Or, in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Koda.app
```

## Music and Video

Koda has two modes, as Koda for Android does. Switch between them from the button at the top of Home on the iPhone, or the top of the sidebar on the Mac; each has its own tabs or sidebar, and whatever is playing carries on.

## Features

### Music

- **Your Mix** on Home, woven from radios of the artists you play most; **Jump back in**, **Quick picks**, your top artists and a row of **Charts**
- Signed in, Quick picks come from your own YouTube Music Home
- Gapless playback or **crossfade**, in the background, with the Lock Screen, Control Center and AirPlay
- Shuffle, repeat, autoplay radio, and a queue you can drag, swipe and undo
- Skip buttons, a sleep timer, volume normalization, and swiping the mini player to skip

### Video

- **Home** and **Subscriptions** feeds, search, and channels with their Videos and Live tabs, sorted by Latest, Popular or Oldest, and an About page with their links
- **Explore** Music, Live, News, Sports and Learning, signed in or not
- **Watch Later** and **Liked Videos** from your account, and the channels you follow
- Like and dislike with the count, subscribe, share, and read the comments
- Koda's own player: quality (1080p by default, or Auto up to 4K), speed, captions, AirPlay and picture in picture
- **Gestures**: double-tap a side to skip 10 seconds (keep tapping to skip more), hold for 2× and slide for other speeds, swipe up for full screen and down to leave it or shrink the video into the mini player, brightness on the left in full screen, and pinch to fill the screen
- Videos **pick up where you left off**, with a progress bar on each thumbnail, and the next one plays after a short countdown
- Leave the video's page and it keeps playing in the mini player

### Your account and profiles

- Sign in to YouTube Music to sync liked songs, albums, playlists and artists both ways, and to send what you play and watch to your YouTube history
- **Profiles** for everyone who uses the device, each with its own library, history and account, and a one-tap switch between them
- A welcome on first launch that sets up your taste: artists, genres and a deck of songs to keep or skip
- **Suggest Less** for songs and artists you don't want offered again, and a full listening **History**

### Lyrics

- Word by word from YouLyPlus and BetterLyrics, line by line from LRCLIB, chosen automatically
- Duets on their singer's side, backing vocals under their line, long notes that swell
- Tap a line to jump to it; share up to six lines as a card in the song's colours

### Finding music

- Search with suggestions and filters, or by voice, recognized on the device
- Paste a YouTube or YouTube Music link to open it; `koda://` links work from Shortcuts
- Moods and genres to browse

### Your library

- Liked songs, saved albums, playlists and artists, and playlists of your own
- **Downloads** and **Ready Offline**: songs kept on the device as you play them, to listen without a connection
- Listening stats: time listened each day, streaks, top songs and artists
- Back up the whole library to one file, or import it from Koda for Android

### Siri, Shortcuts and widgets

- Ask Siri or Shortcuts to play your liked songs, a playlist or anything you name, start a radio, or like the song playing; Koda's songs and playlists show up in Spotlight
- A **Quick Play** widget for the Home Screen, Lock Screen and Mac, and Control Center controls on the iPhone

### Last.fm and Discord

- Scrobble to your Last.fm profile with your own free [Last.fm API account](https://www.last.fm/api/account/create); Koda never asks for your password, and plays made offline are sent later
- On the Mac, show what you're listening to on your Discord profile

## On the Mac

Built for the Mac rather than stretched from the phone:

- A sidebar for each mode. Music: Home, Browse, your library and playlists, with Up Next and today's listening at its foot. Video: Home, Subscriptions, History, Watch Later, Liked Videos, your channels and Explore
- A player bar under every page; Now Playing opens out of its cover, with lyrics or the queue beside it
- Videos in **default** or **theater** view, as on YouTube's site, and full screen with nothing but the picture
- Settings in a window of its own, laid out like System Settings

| Shortcut | Does |
|---|---|
| Space | Play or pause |
| ⌘→ / ⌘← | Next / previous song |
| ⌥⌘→ / ⌥⌘← | Skip ahead / back within the song |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⇧⌘P | Show or hide Now Playing |
| ⇧⌘L / ⇧⌘U | Lyrics / queue |
| ⌘1 / ⌘2 / ⌘F | Home / Library / Search |
| ⌘R | Refresh |
| ⌘, | Settings |

On a video's page:

| Key | Does |
|---|---|
| Space or K | Play or pause |
| J / L | Back / ahead 10 seconds |
| ← / → | Back / ahead 5 seconds |
| F | Full screen (Esc leaves it) |
| T | Theater view |
| M | Mute |

## Privacy

Koda has no analytics and no server of its own. What you like, save, play and search is stored on your device and leaves it only when you back it up, or, if you sign in, to keep your YouTube account in step. Your sign-in stays in the device's Keychain. Requests go to YouTube and YouTube Music, to the lyrics services for lyrics, and to Last.fm or Discord only if you turn them on. Pausing listening history keeps your plays from going anywhere.

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
| `KodaCore/` | Swift package with no UI: the InnerTube clients, parsers, stream resolution, accounts, lyrics, the library, the queue and the player |
| `Koda/` | The SwiftUI app, with its Mac pages in `Koda/Mac` and video in `Koda/Video` |
| `KodaWidgets/` | The Quick Play widget and Control Center controls |
| `.github/workflows/build.yml` | Tests, the unsigned `.ipa` and the universal `.dmg` |

## Feedback

Found a bug or want something? Open an [issue](https://github.com/Ivorisnoob/iKoda/issues) or say it in the [Telegram community](https://t.me/ivorisnoob_chat).

## Thanks

Lyrics come from [LRCLIB](https://lrclib.net), YouLyPlus and BetterLyrics.

The app icon is by [sameerasw](https://github.com/sameerasw).

---

Koda is an unofficial client and is not affiliated with YouTube or Google.

# Last.fm

Scrobbling is optional and off on a fresh install. The logic is shared in `KodaCore/Sources/KodaCore/LastFM/`; the iPhone shows it in Settings (`LastFMSettingsView`) and the Mac as a sidebar page (`MacLastFMView`), with shared pieces in `Components/LastFMShared.swift`. It follows Koda for Android's design (`docs/lastfm.md` in that repository).

## Signing in

Koda ships no Last.fm credentials and never asks for a password. Each listener registers their own API account at https://www.last.fm/api/account/create (Callback URL left empty) and enters its API key and shared secret, each 32 hex digits.

The desktop token flow: `auth.getToken`, then the approval page `https://www.last.fm/api/auth/?api_key=…&token=…`, then `auth.getSession`. The page opens in a `WebAuthenticationSession`; Last.fm's desktop flow can't call back, so closing the sheet is the cue to finish. If the listener hadn't approved yet, error 14 says so and the screen offers the page again or "I've Approved Koda". A token lasts an hour.

Signing in as a different account than before empties the queue and the cached profile, so no play is ever sent under the wrong name.

## What counts

- Music with a title and an artist. Videos are not scrobbled: their artist is often the uploading channel.
- The artist is the first one credited (`Song.scrobbleArtist`), since Last.fm keeps one per track.
- A play counts after half the song or four minutes of sound, whichever is first, and only songs over 30 seconds. `LastFMListeningClock` adds only the seconds `Player` reports heard (gaps capped at six seconds), so seeking and buffering never count.
- Each queue occurrence is its own play (`Player.onItemStarted` / `onItemHeard` carry the `QueueItem`), so a song repeated is a new play. Now Playing updates are best effort.

## Sending

Qualifying plays are queued with the time they started and sent oldest first, each removed only once Last.fm acknowledges it (`ignoredMessage` code 0 accepted; 1–4 ignored with a reason shown; 5, the daily limit, keeps it). At most 1,000 wait. Network errors and rate limits wait five minutes; the app retries every five minutes, on becoming active, and on Sync Now.

## Privacy and storage

- API key, secret, session and pending token live in the Keychain, this device only, never synced. Where the Keychain refuses (an ad-hoc signed Mac build has no access group), a file only the user can read stands in, so Last.fm works rather than failing.
- The queue and cached profile are in `lastfm.json` in Application Support, excluded from backups, and not part of Koda's library backup: restoring a library never turns scrobbling on for another account.
- Turning Last.fm off drops unsent plays. Pausing listening history pauses scrobbling too; nothing heard while paused is ever sent. Disconnect forgets the account and keys on this device.
- Any change of what Koda may do bumps a generation, so a call already out never writes its result.

## Tests

`KodaCoreTests/LastFMTests.swift` covers the signature (the spec's own example), credential checks, response parsing, error mapping and the listening clock. The flow was tested end to end with a real account in October 2026.

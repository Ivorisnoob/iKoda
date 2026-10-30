# Koda on the Mac

Koda for Mac is the same app target built with Mac Catalyst in the Mac idiom (device family 6, "Optimize for Mac"), as one universal binary for Apple silicon and Intel. It needs macOS 26 for Liquid Glass; that is also the last macOS for Intel, so the 2019–2020 Intel Macs are the oldest it runs on.

## Shared and separate

Everything below the UI is shared: `KodaCore`, `AppModel`, the models of each page (`HomeModel`, `SearchModel`), menus (`SongMenuItems`), lyrics and Now Playing. The iPhone's screens are left as they are; the Mac has its own shell and pages.

- `Koda/Mac/` holds the Mac's own views: `MacRootView` (sidebar, sections, search, the player bar), `MacHomeView`, `MacBrowseSearch` (Browse, search results, library grids), `MacComponents` (pages, shelves, cards, the track list, headers, `MacMoreMenu`), `MacSettingsView` and `MacLastFMView`.
- Screens with one model and two layouts branch inside the view: `if Platform.isMac { macBody } else { phoneBody }` (albums, playlists, artists, your playlists, song lists, moods, stats). The phone's body is untouched.
- `Platform.isMac` (in `App/MacShell.swift`) is a compile-time constant; the player bar and the menu bar's commands live there too.

## Decisions

- **Now Playing is a page.** On the Mac it is `Route.nowPlaying`, pushed onto the current section's stack with the system zoom (`.navigationTransition(.zoom)` from the player bar's cover, marked `.matchedTransitionSource`), the same transition the iPhone presents with. It closes from the toolbar's back button or Esc; a click in the sidebar closes it too. The player bar fades under it but stays in place as the zoom's target.
- **Each section keeps its own trail of pages** (`paths[MacSection]`), and Home's model belongs to the window, so switching sections never reloads anything. Clicking the section you're in returns to its first page.
- **Fetched pages are cached for ten minutes** in `KodaCore`'s `PageCache` (albums, artists, playlists, moods, explore, charts). Pull to refresh and ⌘R clear it.
- **Settings is its own window** (`WindowGroup(id: "settings", for: String.self)`, so asking again brings the one window forward), laid out like System Settings.
- **Add to Playlist is a submenu** of the listener's playlists on the Mac (`AddToPlaylistMenu`); New Playlist… asks for a name in a small sheet.
- **Volume is Koda's own** (`Player.volume`): a Mac app can't set the system volume. It multiplies with normalization and is remembered.
- **Artist headers use the artist's square photo**, blurred into a background and sharp as a round portrait. YouTube's banner is a wide image with the portrait pillarboxed inside, which shows bars across a wide window.

## Scars

- **Presented views don't get the window's environment on Catalyst.** Now Playing as a `fullScreenCover` crashed with "No Observable object of type AppModel found", with no Koda frames in the backtrace. Anything presented (sheets, covers) gets `.appEnvironment(model)` explicitly.
- **Never change the window's toolbar while the app runs.** Covering the window, hiding the titlebar's toolbar and `.toolbar(removing: .sidebarToggle)` (even on the sidebar column) all left the sidebar button stuck until clicked; the button isn't an NSToolbar item Koda can see (`titlebar.toolbar.items` is empty). Change what the detail column shows instead; its title and buttons then update like any page's.
- **The toolbar stays in full screen; a full-screen video is its own window.** Catalyst's `titlebar.autoHidesToolbarInFullScreen` (set once at launch for a picture-only video) hid back, search and the sidebar button whenever the window was full screen; dropping it put the toolbar over full-screen videos. Neither the overlay nor flipping that setting per video could give both, so a full-screen video opens `MacVideoWindow`, a window with no title or toolbar that goes full screen in its own Space and closes when the video leaves full screen, as QuickTime Player does. The main window never changes. Finding its NSWindow: AppKit's key window as the UIWindow becomes key is still the main window (that one went full screen instead), a UIWindow's layer isn't under its NSWindow's content layer (separate trees), and `-[UINSWindow uiWindows]` is SPI that logs "will break in the future"; so `NSWindowDidBecomeKeyNotification`'s window is taken when its frame, flipped to top-left, equals the scene's `effectiveGeometry.systemFrame`.
- **`.defaultSize` caps a Catalyst window.** It set the scene's maximum size to the default size and nothing raised it again (`contentMinSize`, an infinite frame), so the window stopped growing at 1180×820. Without it the first window is the system's size and there is no maximum.
- **Catalyst draws a SwiftUI `Menu` as a pull-down button**, a pill with a chevron, ignoring the button style. `MacMoreMenu` draws its own label as a plain button with the indicator hidden.
- **`List` rows carry the sidebar's own margin.** Extra row insets doubled it; the sidebar's rows have none of their own.
- **Long modifier chains time out the type checker.** `MacRootView.body` is split into stages (`searching`, `routing`, `nowPlayingLayer`, `dialogs`).

## Building and checking

CI's `mac` job builds the universal app ad-hoc signed and packages `Koda.dmg` (the app beside a link to Applications). It isn't notarized, so the first launch needs Open Anyway.

What can't be seen can still be checked: a temporary probe behind an environment variable that writes state to stderr (never stdout, which is buffered until exit) has verified the Now Playing flow and the toolbar. Remove it before committing.

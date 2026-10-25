# LyricLock

A glass lyrics widget for your Mac lock screen. Play a song in the YouTube Music web app (Safari → Add to Dock), lock your Mac, and the lyrics scroll in time with the song, karaoke-style, right on the lock screen.

Lives in the menu bar (♫ icon). No Dock icon.

## Setup (one time, ~5 minutes)

**1. Install Apple's command line tools** (skip if you already have Xcode):

```bash
xcode-select --install
```

**2. Install `media-control`**, an open-source helper that reads what's "Now Playing" on your Mac (Apple locked this down in macOS 15.4, and this is the standard workaround):

```bash
brew tap ungive/media-control
brew install media-control
```

Check that it works by playing a song in YouTube Music, then running:

```bash
media-control get
```

You should see JSON with the song title and artist. If you do, LyricLock will work.

**3. Build and install LyricLock:**

```bash
cd LyricLock
chmod +x build.sh
./build.sh
mv build/LyricLock.app /Applications/
open /Applications/LyricLock.app
```

## Using it

1. Play a song in YouTube Music.
2. Lock your Mac: **Ctrl + Cmd + Q** (or Apple menu → Lock Screen).
3. The lyrics float on the lock screen, transparent, with the current line glowing in the album's colours. They hide again when you unlock.

### Desktop widget

Turn on **Show on Desktop** in the ♫ menu bar menu. The lyrics sit on your desktop, behind app windows. Extras only appear while you hover, so it stays clean.

- **Drag** it anywhere; the spot is remembered.
- **Resize**: pinch on the trackpad, drag the corner grip (bottom right), or pick ♫ → Lyrics Size.
- **Scroll** over the lyrics to look back (or ahead). It glides back to the live line after a few seconds.
- **Click a line** to jump the song to it.
- **Collapse** (hover → ˄ top right): shrinks to one line with the song and a play/pause button. Hover → ˅ to expand.
- **Controls** (hover → chevron under the lyrics): repeat, previous, play/pause, next, save lyric image (to Pictures › LyricLock, also copied to the clipboard), open YouTube Music.

The lock screen works the same way: drag it anywhere (remembered separately from the desktop), resize, collapse, play/pause and the controls.

### Lyrics options (♫ menu)

- **Glow** on or off.
- **Romanize Lyrics**: shows Tamil, Hindi, Japanese and other scripts in English letters (offline, built into macOS).
- **Show English Translation**: a small translation under the current line, using Apple's on-device translator (macOS 26). If a language needs downloading, the menu tells you where. Apple's translator doesn't cover every language (Tamil, for example, may not be available).
- **Show Lyric in Menu Bar**: the current line next to the ♫ icon.
- **Find Lyrics for This Song…**: search and pick the right lyrics if they're wrong or missing. Your pick is remembered.
- **Font**: SF Pro, SF Rounded, New York, SF Mono, Avenir Next, Futura, Didot, Gill Sans, Optima, Baskerville, American Typewriter, Noteworthy.

### Lyrics screensaver

A full-screen scene: blurred album art, a large clock, big animated lyrics and the song at the bottom.

- **Start it:** press **⌃⌥⌘S** (Control + Option + Command + S) from any app, or ♫ → Start Lyrics Screensaver.
- **End it:** press **Space**. Moving the mouse or pressing other keys does nothing, so it won't disappear by accident. (⌃⌥⌘S again also ends it.)
- **While it's showing:** scroll to look back through the lyrics, and click a line to jump the song there. The cursor appears when you move the mouse and hides again after a moment.
- **Start it automatically:** ♫ → Start Screensaver Automatically → after 2, 5, 10 or 15 minutes idle, while music is playing.

**Keep Screen On While Music Plays** (on by default) stops the display from going dark while music plays on the lock screen or the screensaver. It lets the screen sleep normally once you pause.

⌃⌥⌘S is the only system-wide shortcut LyricLock uses. Space is only taken while the screensaver is showing.

### Menu options

- **Show on Desktop** / **Reset Positions** (desktop and lock screen)
- **Hide Desktop Lyrics When Paused**: fades out after 30 seconds of pause, returns on play.
- **Lower on Lock Screen**: move it if it overlaps the clock or your user picture.
- **Album Glow on Lock Screen**: a soft colour aura from the album art behind the lyrics.
- **Start Lyrics Screensaver** / **Start Screensaver Automatically** / **Keep Screen On While Music Plays**
- **Lyrics Size**: Small, Medium, Large, Extra Large (or drag the corner grip).
- **Song & Artist Size**: Small, Medium, Large.
- **Font**: 12 built-in fonts (see Lyrics options above).
- **Show Lyrics Earlier / Later**: nudge timing in 0.25s steps.
- **Launch at Login**

## Updating

```bash
cd path/to/LyricLock
git pull && ./build.sh
rm -rf /Applications/LyricLock.app && mv build/LyricLock.app /Applications/ && open /Applications/LyricLock.app
```

## How it works

| Piece | What it does |
|---|---|
| `NowPlaying.swift` | Polls `media-control get` once a second for title, artist and playback position, and extrapolates smoothly between polls. Works with any player that shows in the system media controls, not just YouTube Music. |
| `Lyrics.swift` | Fetches time-synced lyrics from [LRCLIB](https://lrclib.net) (free, no account) and parses the LRC format. Strips "(Official Video)", "(From \"Film\")" and extra artists so more songs match. |
| `LyricsView.swift` | Transparent lyrics: line-by-line animation with the current line glowing in the song's colour, only the 5 nearby lines are drawn so it stays at 60 fps, breathing dots during instrumentals, resize grip and collapsible controls. |
| `Palette.swift` | Pulls the main colours out of the album art. |
| `Translator.swift` | English translation via Apple's Translation framework. |
| `LyricSearch.swift` | The Find Lyrics window. |
| `HotKeys.swift` | The ⌃⌥⌘S shortcut and Space-to-exit (no permissions needed). |
| `ShareCard.swift` | Renders the lyric image card. |
| `ScreensaverView.swift` | The full-screen lyrics screensaver. |
| `Assets/` | App icon (`make_icon.py` regenerates it). |
| `Overlay.swift` | Lock-screen window moved into a SkyLight window-server space above the lock screen (the technique WidgetScreen and Atoll use), plus the draggable desktop window. |

## Good to know

- **Private API.** The lock-screen layer uses undocumented SkyLight calls. It works on macOS 15 and 26, but a future macOS update could break it. If it does, the menu shows "⚠︎ Lock-screen layer unavailable" and the desktop mode still works.
- **Missing lyrics.** LRCLIB covers most popular songs. Remixes, live versions and some regional tracks may come back with plain (unsynced) lyrics or nothing.
- **Battery.** It only animates while music is playing, and the lock screen turns the display off after a while anyway.
- **Personal use only.** Not App Store-safe because of the private API.

## Troubleshooting

- **Anything ever feels stuck.** Quit from the ♫ menu, or run `killall LyricLock` in Terminal.

- **Menu says "media-control not installed".** Run step 2, then quit and reopen LyricLock.
- **Menu says "Nothing playing" while music plays.** Run `media-control get` in Terminal. If that's empty too, the issue is the Now Playing feed, not LyricLock; try pausing and resuming in YouTube Music.
- **Card doesn't appear when locked.** LyricLock must already be running before you lock. Turn on "Show on Desktop" to confirm the card renders at all.
- **Build errors.** Run `swiftc --version` and make sure it's Swift 5.9 or newer. Paste any error back to Claude to fix.

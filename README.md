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
3. The lyrics card appears on the lock screen and hides again when you unlock.

From the ♫ menu bar icon you can:

- **Show on Desktop**: lyrics float on your desktop, behind app windows, like a desktop widget. Drag them anywhere; "Reset Desktop Position" puts them back.
- **Lower on Lock Screen**: move it if it overlaps the clock or your user picture.
- **Show Lyrics Earlier / Later**: nudge the timing in 0.25s steps if lyrics feel off.
- **Launch at Login**: start automatically.

## How it works

| Piece | What it does |
|---|---|
| `NowPlaying.swift` | Polls `media-control get` once a second for title, artist and playback position, and extrapolates smoothly between polls. Works with any player that shows in the system media controls, not just YouTube Music. |
| `Lyrics.swift` | Fetches time-synced lyrics from [LRCLIB](https://lrclib.net) (free, no account) and parses the LRC format. Cleans titles like "(Official Video)". |
| `LyricsView.swift` | SwiftUI glass card: current line glows and fills left-to-right as it's sung, other lines blur and fade, and the list springs to each new line. |
| `Overlay.swift` | Click-through window moved into a SkyLight window-server space above the lock screen, the same technique WidgetScreen and Atoll use. |

## Good to know

- **Private API.** The lock-screen layer uses undocumented SkyLight calls. It works on macOS 15 and 26, but a future macOS update could break it. If it does, the menu shows "⚠︎ Lock-screen layer unavailable" and the desktop mode still works.
- **Missing lyrics.** LRCLIB covers most popular songs. Remixes, live versions and some regional tracks may come back with plain (unsynced) lyrics or nothing.
- **Battery.** It only animates while music is playing, and the lock screen turns the display off after a while anyway.
- **Personal use only.** Not App Store-safe because of the private API.

## Troubleshooting

- **Menu says "media-control not installed".** Run step 2, then quit and reopen LyricLock.
- **Menu says "Nothing playing" while music plays.** Run `media-control get` in Terminal. If that's empty too, the issue is the Now Playing feed, not LyricLock; try pausing and resuming in YouTube Music.
- **Card doesn't appear when locked.** LyricLock must already be running before you lock. Turn on "Show on Desktop" to confirm the card renders at all.
- **Build errors.** Run `swiftc --version` and make sure it's Swift 5.9 or newer. Paste any error back to Claude to fix.

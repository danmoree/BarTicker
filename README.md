# pixelScreen

A menu bar LED sign for macOS. It renders a dot-matrix panel in the status bar
and scrolls whatever you turn on through it: the track you're playing, news
headlines, stock quotes, and the weather.

The app is a status item only — no dock icon, no window (`LSUIElement`).
Everything is configured from the menu you get by clicking the panel.

## Requirements

- macOS 13 or later
- Xcode 16 or later (the project uses synchronized file groups, `objectVersion 77`)

No package manager, no dependencies, nothing to install. Clone and open.

## Building

```
open pixelScreen.xcodeproj
```

Then pick your own signing team the first time:

**Signing & Capabilities → Team → (your account)**

The team is deliberately left blank in the project so it doesn't carry one
developer's ID into everyone else's checkout. You may also want to change
`PRODUCT_BUNDLE_IDENTIFIER` from `com.danielmoreno.projects.pixelScreen` to
something under your own domain.

A free personal Apple ID team is enough — the app is sandboxed but uses no
paid capabilities.

From the command line:

```
xcodebuild -scheme pixelScreen -configuration Debug build
```

## Services it talks to

Every source is keyless, so there is no configuration file and no secret to
obtain:

| Widget       | Source                                              |
|--------------|-----------------------------------------------------|
| Weather      | Open-Meteo (forecast + geocoding)                    |
| Stocks       | Yahoo Finance chart endpoint (undocumented; see `Stocks.swift`) |
| News         | Any RSS/Atom feed — BBC, NPR, Ars Technica, HN by default |
| Now Playing  | Spotify and Music, over AppleScript                  |

Now Playing needs one thing that isn't automatic: on first run macOS asks for
permission to control Spotify/Music. If you decline it, the widget stays empty
until you re-allow it under System Settings → Privacy & Security → Automation.

## Layout of the code

| File | What's in it |
|------|--------------|
| `pixelScreenApp.swift` | App delegate, status item, and the whole menu |
| `TickerView.swift` | The dot panel view — geometry, clock, drawing |
| `Board.swift` | Zone layout: how widgets share the panel's columns |
| `BoardTheme.swift` | Colour schemes |
| `PixelFont.swift` / `PixelFontData.swift` | The hand-drawn 5x7 font and its typesetter |
| `Preferences.swift` | Widget list and persisted settings |
| `NowPlaying.swift`, `Feed.swift`, `Stocks.swift`, `Weather.swift` | Data sources |

Each file opens with a comment explaining why it works the way it does — start
with `Board.swift` if you want to add a widget, and `PixelFontData.swift` if
you want to change how a character looks (the source art is literal ASCII;
what you see is what lights up).

## Adding a scriptable music player

Two places: the bundle id has to be listed in `pixelScreen.entitlements` under
`com.apple.security.temporary-exception.apple-events` (the sandbox requires
each app be named individually), and the lookup itself goes in
`NowPlaying.swift`.

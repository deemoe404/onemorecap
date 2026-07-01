# Subtitles

Subtitles is a native macOS menu-bar app for playing an external subtitle file over a movie that does not include the subtitle track you need.

The MVP flow is:

1. Load an `.srt` or `.vtt` file from the menu bar app.
2. Play a movie in TV.app, or seek another video player to the beginning.
3. Let Apple TV sync follow TV.app automatically, or press Space when you start a non-TV player.
4. Adjust subtitle offset from the floating toolbar, or resize subtitle width by
   dragging the marked left or right edge of the subtitle container.

## Requirements

- macOS with `$HOME/Applications/Xcode-beta.app`
- SwiftPM through Xcode beta 27
- No global dependency installation

The scripts set `DEVELOPER_DIR` explicitly, so they do not require changing global `xcode-select`.

## Commands

```sh
mise exec -- scripts/check.sh
mise exec -- scripts/run.sh
mise exec -- scripts/package-app.sh
```

The packaged app is written to `build/Subtitles.app`.

## CLI Harness

```sh
mise exec -- swift run SubtitleHarness parse Fixtures/sample.srt
mise exec -- swift run SubtitleHarness at Fixtures/sample.srt 3.1 --offset 0.3
```

## App Behavior

- The menu bar item is labeled `Sub`.
- The floating subtitle window stays above normal windows and attempts to join fullscreen Spaces.
- Drag `.srt`, `.vtt`, or `.webvtt` files onto the subtitle window to replace the active subtitle.
- Hover over the subtitle window to reveal the Liquid Glass toolbar and the
  subtitle container chrome.
- Drag the marked left or right edge region of the subtitle container to adjust
  subtitle width. Height is calculated from the current subtitle text and system
  caption style.
- Hide or reopen the subtitle window from the menu bar.
- Use the hover Sync control to manually read the current Apple TV playback position. The Sync button defaults to Apple TV and also exposes an Apple TV menu item. After calibration, subtitles continue from that TV time using the local clock.
- If TV.app is not running, missing Accessibility permission, or missing position data, the app falls back to the manual Space-key clock.

## Hotkey Permission

The app installs a global Space-key monitor and can read TV.app playback controls for manual calibration. macOS may require Accessibility permission for both behaviors. If Space does not control subtitles or the hover Sync control cannot read TV.app, use the menu item `Request Accessibility Access`, then enable the app in System Settings. If permission appears granted but behavior is still broken, use `Refresh Accessibility Access` to reopen the permission location and re-enable the app manually. The menu and hover controls remain usable without that permission.

## Scope

The MVP supports SRT and WebVTT only. ASS/SSA styling, OCR, sandboxing, signing, and auto-update are intentionally out of scope for this scaffold.

## Known Limitations

See [docs/known-limitations.md](docs/known-limitations.md) for interaction
limitations that are intentionally handled with product-level workarounds.

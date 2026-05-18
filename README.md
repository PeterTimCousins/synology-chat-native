# Synology Chat Native

A native macOS wrapper for the Synology Chat web app.

This is intentionally not Electron. It uses AppKit and `WKWebView`, so the app runs natively on Apple Silicon and uses the system WebKit engine.

## First Run

On first launch, enter your Synology server address or QuickConnect ID. You can use a full Chat URL, a simpler address, or a bare QuickConnect ID:

```text
example.synology.me:5001
MyQuickConnectID
```

The app normalizes that into a DSM Chat launch URL. You can change it later from `Synology Chat Native > Settings...`.

## Themes

Settings includes three theme modes:

- `Modern Dark`: Default. Applies a dark, more current visual layer over Synology Chat.
- `Modern Light`: Keeps the app bright but removes some of the older visual weight.
- `Original Synology`: Removes the wrapper theme and leaves the web app untouched.

The themes are CSS-only. They do not intercept requests, modify authentication, replace routes, or alter how Synology Chat loads and sends messages.

## Build

```sh
swift build -c release
./scripts/package-app.sh
open "build/Synology Chat Native.app"
```

The packaged app is ad-hoc signed for local use.

## What It Does

- Loads Synology Chat in a native macOS window.
- Persists DSM login/session cookies using the default WebKit data store.
- Opens external links in the default browser.
- Supports back, forward, reload, and home commands from the menu.
- Allows the server URL to be changed without rebuilding.
- Adds selectable CSS-only themes.

## Notes

This wrapper does not implement the Synology Chat protocol itself. It relies on the official Synology web application exposed by DSM.

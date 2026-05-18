# Synology Chat Native

A native macOS wrapper for the Synology Chat web app.

This is intentionally not Electron. It uses AppKit and `WKWebView`, so the app runs natively on Apple Silicon and uses the system WebKit engine.

## Default URL

The bundled default is:

```text
https://costwisegroup.synology.me:2891/?launchApp=SYNO.SDS.Chat.Application#channels/11
```

You can change it from `Synology Chat Native > Settings...`.

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

## Notes

This wrapper does not implement the Synology Chat protocol itself. It relies on the official Synology web application exposed by DSM.

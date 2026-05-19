# Synology Chat Reference Cache

This folder is for local inspection copies of the Synology Chat web assets that are loaded by a captured `dump.html`.

The cache contents are intentionally ignored by git because the upstream CSS, JavaScript, and image assets belong to Synology and should not be redistributed with this wrapper app.

Refresh the local cache with:

```sh
./scripts/cache-synology-chat-reference.sh dump.html
```

The script writes downloaded files to `reference/synology-chat/cache/` and records a `manifest.tsv` mapping each source URL to the local file path.

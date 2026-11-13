# Synology Chat Native

For the current work-in-progress checkpoint and setup on another Mac, start with
[MacBook handoff](reference/synology-chat/MACBOOK-HANDOFF.md).

A native SwiftUI macOS client for core chat workflows that renders Synology Chat backend responses using
the existing dark palette. The original AppKit/WKWebView wrapper remains separately
available, with its packaged files preserved.

This client does not yet have full official-app feature parity. The detailed desktop
comparison and missing workflows are in `reference/synology-chat/feature-parity.txt`
and `feature-parity.json`. Core test acceptance is not a parity percentage. The product backlog also requires
a modern Slack-inspired native redesign; the current development preview styling
is not the final visual target.

## Use the native client

Open `build/Synology Chat Native API.app`. It accepts a direct HTTPS address or
QuickConnect ID. **Keep me signed in on this Mac** optionally stores its session in
macOS Keychain, never your password or verification code. macOS may ask for Keychain
approval after an ad-hoc rebuild. The normal app authenticates independently and
cannot import the official app's session.

To rebuild:

```sh
./scripts/package-api-app.sh
open "build/Synology Chat Native API.app"
```

Use `--candidate` to stage under `build/candidates/`. Packaging retains the previous
native app and restores it if installation fails. This is a locally ad-hoc signed
Apple silicon build, not a notarized public distribution.

## Native functionality

- Conversations, member lists, older main/thread history, message search and result context.
- New conversation picker and profile Message share durable recovery with the quick switcher; fresh identity/member checks, reviewed new starts and read-only verification prevent automatic repeat requests after uncertainty.
- Native ⌘K/Control-K quick switcher with keyboard selection, categories, fresh destination checks and durable new-conversation recovery; live existing Peter routing and draft preservation verified.
- Native bot browser and personal subscribe/unsubscribe controls with durable recovery; real catalogue/existing Open verified, mutation UI verified in a local fixture.
- Native incoming/outgoing webhook settings, masked credentials and guarded management; disabled synthetic backend/native checks verified, actual delivery remains unverified.
- Native slash suggestions, command review, help and nickname editing; real Jitsi invitation/link verified in Peter, meeting/media handoff still unverified.
- Native integration attachment text/buttons with guarded backend submission; real Calendar text and local action/failure loop verified, real bot callbacks remain unverified.
- Text sends and incoming live updates, automatic reconnect/resync, and sleep/wake handling.
- File uploads in main chats or threads, captions, progress/cancel, image previews and Save dialogs.
- Replies, readable reactions, own-message editing and confirmed soft deletion.
- Foreground/latest visibility-based read receipts, unread Dock badges and account-bound notifications.
- Notification clicks reopen a closed window and select the exact conversation/message.
- Server-permitted public/private channel creation and private-channel member management.
- Conversation conversion with in-place/new-channel history choice and member review; operation paths fixture-tested, live review/cancel verified.
- Server avatars/read-only profiles, personal reminder management and conversation starring/hiding.
- Manual away/automatic availability; native/official live roundtrip verified and original state restored.
- Native screenshot capture/review/cancel/save-only workflow; synthetic preview, saved-copy bytes and cleanup verified, real Screen Recording test pending.
- Native GIF viewer with Pause/Play, full-size static originals and Show message; live synthetic playback and navigation verified.
- Native Drive chooser, access review and link insertion; synthetic Peter viewer grant/restoration live verified.
- Native NAS file picker and attachment review; synthetic Peter copy matches original bytes and official web display.
- Native detected-date actions and editable private Calendar event creation; live timed event/cancel/readback verified, broader Calendar parity open.
- Native Synology app launcher and shared ordering; real order restore and Calendar browser handoff verified.
- Shared DSM language/date/time and account timezone preferences; native formats/timezone live restored, English UI localization still open.
- Paired notification devices: live list/cancel verified; unpair fixture-tested, real registrations preserved.
- Profile nickname/description editor with administrator policy checks; live edit/restore verified. Photo crop/upload/remove is fixture-tested; real photo reader verified, live photo writes remain open.
- Account-scoped username/nickname display preference with native editor, refreshed people/conversation/author labels and search by either alias; live mode round trip restored original preference and raw identities.
- Server-backed unread sidebar pinning, stable selected-row placement, corrected mention/thread badges and collapsible groups with search reveal; username/nickname preference is now applied through the account-scoped formatter; broader matrix verification remains open.
- Per-conversation desktop/mobile notification modes, including mention/followed-thread choices for ordinary channels; independent Peter mode saves/restoration live verified, full notification delivery matrix still open.
- Server snooze/daily quiet-hour and alert preferences; manual pause/resume live verified, recurring/global alert edits fixture-tested.
- Private history archiving and channel/conversation closing with acknowledgement and durable account-scoped receipt recovery; live dispatch and broader lifecycle validation remain open.
- Joined/available channel browser; public join and named-channel leave have fixture coverage, with live membership testing still open.
- Native Settings (⌘,) with macOS Open at Login status, an optional menu-bar icon and download-folder preferences; native interface localization and full tray comparison remain open.
- Account-session Downloads history with progress, cancel/retry, Open/Show in Folder, missing-file checks and clear without deleting files; remembered Save folder and explicit default Downloads reset.
- QuickConnect direct/relay routing with TLS hostname and NAS identity validation; untrusted certificates stay rejected.

The earlier optimized core build restored its own saved session and passed native-to-web
and web-to-native messaging plus General-to-Peter closed-window notification navigation.
Main/thread native upload cancellation, download cancellation/retry/byte equality,
action failure recovery, history pagination and a physical sleep/wake cycle were
verified through the shared native views/model. The last full source run passed 1,138 Swift
tests (2026-11-11); subsequent evidence records state which checks were rerun. Detailed proof and limitations are in `reference/synology-chat/release-audit.md`.

**Enable notifications** requests macOS permission. Preview content and sound follow
server preferences. Closing the window retains live updates and badges; quitting
stops them. Screen sharing can suppress banners. Badges follow unread counts
independently of whether alerts are enabled.

Native interface size: **⌘+**/**⌘=** larger, **⌘−** smaller, **⌘0** actual size.
**Control-⌘F** toggles full screen. Scaling keeps the current conversation and draft;
separate native dialogs keep their normal size.

Keyboard controls: **⌘F** search, **⌘N** people picker, **⌘R** refresh while retaining
the draft, **⌘Return** send/save, **Escape** dismiss/cancel. Return inserts a new line.
With macOS Keyboard Navigation enabled, **Control-Tab** exits a multiline composer
forward and **Control-Shift-Tab** exits backward. Labelled message menus expose the
same actions as right-click. Messages and captions validate the server's 2,000 UTF-16
unit limit without truncating drafts. Uncertain writes keep the draft and require
checking recent messages before retrying.

## Encryption and compatibility limits

Existing encryption keys can be unlocked locally. Message/reply/edit consumers,
encrypted attachment upload/download and in-memory thumbnails use authenticated
crypto; lock clears sensitive drafts/caches and cancels transfers. Encrypted uploads
have a 32 MiB plaintext cap. Passwords and unlocked keys are never saved or sent to
the NAS. Independent JavaScript/native fixtures and a local shared unlock/lock UI
fixture verify the formats and consumers. This account has no initialized encrypted
chat, so live encrypted NAS interoperability remains unverified. Key setup/reset
and archive management are not implemented. Encrypted notification previews stay generic.

Live OTP challenges and notification cold-start clicks are not claimed; their
branches are model/fixture-tested. Current runtime acceptance covers this Mac/NAS,
not all Synology versions or older macOS/Intel hardware. Backend internals may change.
VoiceOver usability is an optional inconclusive check, not a required core-chat gate;
standard native accessibility labels and keyboard support remain present.

Swift memory has no forensic-zeroization guarantee. Forced termination can leave
owner-only staging files; explicit attachment Save exports plaintext. The encrypted
download cap bounds decryption after download. See the scoped privacy reviews for details.

## Development and verification

```sh
swift test
python3 -B scripts/parity-status.py --json
./scripts/package-native-preview.sh
open "build/Synology Chat API Preview.app"
```

The separate debug preview skips automatic Keychain access. Its explicit **Use
official app session** bridge imports an existing session into memory without saving
or revoking it. Developer probes and local encrypted fixtures do not ship in the
normal release. Synthetic tests need no NAS credentials. Test messages were limited
to the authorized Peter conversation; the separately approved management test left
one self-only private test channel with no messages.

The operation index and investigation are in `reference/synology-chat/`. Cached
vendor assets and investigation tools are excluded from the app package. Open-source
notices ship with the native app. The full-parity gate checks every inventory outcome for explicit fresh acceptance.
The older `release-status.py` certificate covers the previous core scope only;
passing unit tests does not establish full parity.

## Preserved wrapper

Open `build/Synology Chat Native.app` to use the original web-backed application.
Its Settings retain Modern Dark, Modern Light and Original Synology themes, server
selection and the existing WebKit session store. Its themes are CSS-only.

Only explicitly running `scripts/package-app.sh` rebuilds the wrapper; native API
and preview packaging do not replace it. The wrapper's original packaged executable,
plist and icon hashes were verified unchanged. The installed official app's files
were not replaced; its pre-existing signature-provenance limitation remains documented.

The modern native redesign is in progress in the development preview. Its first
foundation includes the sidebar, message hierarchy, initials avatars, account menu
and integrated composer. The optimized normal app is retained unchanged during
this work. See `evidence/2026-10-16/modern-foundation-review.json`.

The development preview now opens image attachments in a native viewer with fit,
zoom, loaded-image navigation, Save original and explicit Save & Open. Main/thread
flows and original-byte equality were verified with synthetic Peter images. Older
gallery fetching and animated images remain open; encrypted viewing is fixture-tested.
The current preview passes 353 tests; the optimized normal app remains retained unchanged.

The development preview renders clickable http/https links and Synology labelled
links in messages and search results. Basic link cards use server metadata and
authenticated NAS image proxy responses, respecting global/per-card hiding and
unsafe-link flags. This NAS currently hides cards globally; that setting was left
unchanged. Visible cards and unsafe confirmation were verified using the local
debug-only fixture; real public-link opening and hidden behavior were verified in
Peter. Full formatting and embedded link media remain open.

The development preview now offers all 1,784 built-in Synology emoji reaction
mappings through a searchable native picker with eight categories and skin tones.
Country-name search and participant hover names are included. Skin-tone and flag
reaction set/delete were live-tested in Peter and removed afterward. Sticker image
packs, recent reactions and vendor keyword aliases remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/reaction-catalog-review.json`.

The development preview loads the NAS sticker catalogue and sprite assets into a
native searchable pack picker. Sticker-type messages and thread replies were
independently verified in Peter and render in the official web client. Image
stickers are not valid reactions in the official client; the reaction picker
therefore remains emoji-only. Dedicated encrypted-sticker verification and search
rendering remain open. See `reference/synology-chat/evidence/2026-10-16/sticker-review.json`.

Native messages, threads and search results now render Synology-style emphasis,
lists, quotes and code with plain-text code copying. Code URLs remain literal;
ordinary labelled links and emoji shorthand still render. A synthetic Peter post
was compared with the official renderer. Nested block grammar and composer
formatting controls remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/formatting-review.json`.

The native main/thread composers now use selection-aware plain-text editors with
local undo history, a member mention chooser and emoji/sticker tabs. Mention/emoji
insertions preserve the surrounding draft; canonical mentions were live-verified
against server mention IDs and official rendering in Peter. Native Undo/Redo,
keyboard sending and refresh draft preservation were checked. Typed autocomplete,
profile popovers and recent emoji remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/mention-composer-review.json`.

Both native composers now have selection-aware bold, italic, strike, inline-code,
quote, list and fenced-code controls with local CmdB/CmdI/CmdShiftC shortcuts.
Formatting participates in Undo/Redo and preserves the surrounding draft.
Toolbar-generated main/thread messages were read back and rendered by the
official client. Comfortable/compact layouts were inspected. Advanced parser
edge cases and active-format indicators remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/format-toolbar-review.json`.

Native message hashtags now open channel-scoped results using the backend hashtag
filter. The channel catalogue, additional keyword filtering and Open message
navigation were live-verified in Peter, with NAS indexing and official rendering
matching the synthetic test. Code and encrypted-channel exclusions are retained.
Autocomplete and additional-tag management remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/hashtag-review.json`.

Native message search now offers structured author, mention, content, attachment
extension and local-day date filters. Nine read-only checks against synthetic
Peter messages matched exact results, and native exclusion/error/clear recovery
flows were exercised. Suggestions and multi-value filter construction remain
open. Evidence: `reference/synology-chat/evidence/2026-10-16/advanced-search-review.json`.

The native conversation header now opens **Files & links**. Files and Links tabs
use the NAS search filters, with keyword search, paging, compact image thumbnails,
image viewing, Save/Save & open, and navigation to the exact root or thread message.
The development preview passed 257 tests; live Peter checks verified image navigation,
byte-identical original saving, link/source and thread/source routing, and empty-search
recovery. Alternate sorting, encrypted library support and live multi-page coverage
remain open. Evidence: `reference/synology-chat/evidence/2026-10-16/conversation-library-review.json`.

**Saved messages** is now available in the native sidebar. Main/thread message menus
can save or remove personal bookmarks; the collection searches across conversations,
orders by save time, and opens the exact root or reply. Native Peter root/reply
save, source navigation and removal were verified, with both fixtures restored to
their original unbookmarked state. 262 tests pass. Broader encrypted, multi-page and
external-update parity remains open. Evidence:
`reference/synology-chat/evidence/2026-10-16/bookmarks-review.json`.

The native sidebar now has **Threads**, combining followed-thread pages from your
conversations with root/latest reply cards, unread and conversation filters, paging,
and exact reply navigation. Use **Following/Follow** in a thread header or
**Unfollow** in its collection card. Peter’s synthetic subscription off/on round
trip restored the exact original set; 269 tests pass. Encrypted, larger live datasets
and automatic external-update reconciliation remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/threads-review.json`.

Own-message **Read by… / Not read by…** details now have a native sheet with
participant counts, read/unread tabs, filtering and refresh. This respects the NAS
`allow_read_status` policy, which is currently **false**; the real menu stays hidden
and the setting was not changed. Enabled UI behavior is verified only with local
synthetic responses. 275 tests pass. Live enabled participant responses and profile
actions remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/read-status-review.json`.

**Pinned messages** now opens from the native conversation header. Unencrypted root
message menus offer Pin/Unpin, with canonical readback, a pin indicator, scoped
search/paging and source navigation. The existing synthetic Peter link was pinned
and unpinned with its original checked metadata and subscriptions restored. Saved
messages shares the collection layout and retained its two existing personal items
and filtering behavior. 280 tests pass. Sticky controls, alternate sorting and
broader live permissions/multi-page coverage remain open. Evidence:
`reference/synology-chat/evidence/2026-10-16/pins-review.json`.

Local attachments now open a native **Send files** review with multiple files,
independent captions, add/remove controls and per-file delivery state. Sending is
sequential; failures/Stop preserve unattempted files, and Continue never silently
retries unconfirmed deliveries. Successful batches return historical threads to
latest replies. Six synthetic Peter main/thread/context files were verified with
exact captions/destinations and byte-identical downloads. 288 tests pass. Computer
control could not reliably finish ordinary file-picker selection; live review/send
proof used guarded synthetic staging. Normal picker, encrypted batches, live partial
recovery and rich selected-file previews remain open. That milestone preceded the composer drop/paste integration described below. Evidence:
`reference/synology-chat/evidence/2026-10-16/multi-attachment-review.json`.

Main/thread native composers now intercept file drops and file/image paste into
the shared review sheet. Text paste remains ordinary editing; generated clipboard
images use bounded background preparation and private temporary staging. Private
synthetic pasteboards exercised the actual editor consumer, cancel-without-send,
caption validation, two root files and root/thread PNG uploads; all four downloads
matched original bytes. 297 tests pass. Physical cross-app drag and actual system
Command-V remain unverified; whole-window drop, promises/folders and broader
encrypted/format coverage are still open. The fixtures did not replace or read
your system clipboard contents. Evidence:
`reference/synology-chat/evidence/2026-10-16/drop-paste-review.json`.

Native audio/video playback now uses authenticated originals with private leased temporary files and native controls. Two synthetic Peter media posts, player controls and quit/recovery cleanup are verified;311 tests pass. See `reference/synology-chat/evidence/2026-10-16/media-playback-review.json`. Full feature parity remains open.

Native poll creation, editing, voting, anonymous/public results and closing are scoped live-verified against the official client and NAS in Peter.320 tests pass. See `reference/synology-chat/evidence/2026-10-16/poll-review.json`; attachment/encrypted/expiry coverage and full parity remain open.

Native snippet create/edit, language selection, code previews/expansion and full native viewing are scoped verified in Peter root/thread conversations. 332 tests pass. See `reference/synology-chat/evidence/2026-10-16/snippet-review.json`; complete syntax grammars, encrypted snippets and broader parity remain open.

Native forwarding to existing conversations is implemented with canonical source and destination checks and no automatic retries. The Peter file-copy chain and official interoperability are scoped live-verified;341 tests pass. See `reference/synology-chat/evidence/2026-10-16/forward-review.json`; new-DM initiation and broader live coverage remain open.

Native scheduled-message creation, editing and cancellation are scoped live-verified in Peter, with a pending-send manager, date/time and emoji composer, local draft retention and canonical server checks. 353 tests pass. See `reference/synology-chat/evidence/2026-10-16/schedule-review.json`; timed delivery while the preview was closed and the final exact-minute picker were verified. Full parity remains open.

11 November update: the normal API app is packaged with ordinary main/thread draft recovery, grouped timelines, multiline quote blocks, proxied link icons and dedicated image zoom keys (Control–Command–Plus/Equals, Minus,0,1). Source passes1,010 tests. The signed-in candidate verified session/draft recovery; later rendering/key changes were checked in disconnected preview. New normal-build live launch and full feature parity remain open.

11 November goal followup:1,041 tests pass. Guest sign-in, a read-only channel guest browser, richer file cards and image gestures are implemented; guest invitation workflows and reachable encryption management remain open. Encryption plans have offline native/JavaScript verification only. The normal app is updated without restarting the signed-in candidate. See `reference/synology-chat/evidence/2026-11-11/goal-followup-review.json`; full parity remains open.

Office preview followup: source and development preview now support common ordinary Office documents through macOS Quick Look; DOCX/XLSX rendering and private temporary-file cleanup verified.1,048 tests pass. This slice is staged for the next combined normal-app update; current normal remains the1,041-test package. Encrypted Office previews and broader format/live acceptance remain open.

Guest-management followup:1,064 tests pass. Invitation, expiry, resend and removal controls are implemented with saved pending results and no automatic retries; the full native roundtrip was checked against local synthetic responses only. Normal app now combines this slice with Office previews, retaining the1,041-test rollback and current signed-in candidate. Actual guest/email and full-parity acceptance remain open.

11 November identity/live update: the new native client is **Chat Native**, with a purple icon. Development preview is blue with a P; original wrapper stays green. The normal app remains at `build/Synology Chat Native API.app` for existing shortcuts, with the same bundle ID and saved sign-in.1,094 tests and6 packaging regressions pass. Purple normal restored and Live17; messages verified both ways only between Peter accounts6+10. Encryption setup/password rewrap has synthetic UI/transport proof only; reset/renewal, actual key operations and full parity remain open. Receipt:`reference/synology-chat/evidence/2026-11-11/encryption-brand-live-review.json`.

11 November appearance update:1,110 Swift tests pass. Native account theme/background settings and optional per-Mac Follow account appearance are staged in `build/candidates/Synology Chat Native API.app`; dark/plain remains the default. Initial local light/settings/draft rendering and actual NAS static wallpaper reads verified; final tint/thread and real account Apply/restore remain open. The running purple normal app is unchanged. See `reference/synology-chat/evidence/2026-11-11/appearance-review.json`.

Appearance follow-up:1,118 source tests pass (8 new DEBUG probe recovery cases). Own-account background3→0→3 and exact restore verified; final tinted dark/light main/thread and exact unsent draft retention locally rendered. Production candidate1110 and running1094 normal unchanged. Broader parity remains open; see `reference/synology-chat/evidence/2026-11-11/appearance-live-review.json`.

11 November daily-use recovery:1,138 tests pass. Responsive compact/wide header and exact draft/search routing checked locally; main/thread transport receipt retries and complete attachment validation/known-unsent local preflight are staged in optimized candidatec7bd37. Previous candidate retained; running purple normal remains98de. Current notification/badge/cold-process/physical-input and full-parity checks remain open. Receipt:`reference/synology-chat/evidence/2026-11-11/daily-use-recovery-review.json`.

Current normal update:1138 optimized buildc7bd37 is now installed and running, with own saved sign-in/Live17 restored. Prior98de retained at `.previous.app`. One owned incoming message produced exact macOS banner/sound delivery logging and native badge0→1. Desktop lock prevented visible/click/read-clear/cold-start checks. See `reference/synology-chat/evidence/2026-11-11/native1138-runtime-review.json`.

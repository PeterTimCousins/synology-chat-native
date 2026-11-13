# Synology Chat Reference and Evidence

Current feature state is recorded in `feature-parity.json`, with the active queue in
`WORKING-NOTES.md` and scoped evidence in `native-client-roadmap.json`.
`release-audit.md` covers the historical core scope; it is not full feature acceptance.
`api-investigation.json` is a historical investigation record, not the current
feature checklist. Older receipts remain historical evidence.

This folder also holds local inspection copies of the Synology Chat web assets that are loaded by a captured `dump.html`.

The cache contents are intentionally ignored by git because the upstream CSS, JavaScript, and image assets belong to Synology and should not be redistributed with this wrapper app.

Refresh the local cache with:

```sh
./scripts/cache-synology-chat-reference.sh dump.html
```

The script writes downloaded files to `reference/synology-chat/cache/` and records a `manifest.tsv` mapping each source URL to the local file path.

Native text/PDF previews verified in main/thread/Files collection;304 tests pass. Office conversion and full F033 acceptance open. See evidence/2026-10-16/document-preview-review.json.

Native audio/video player scoped verified with two byte-equal Peter attachments and quit/recovery cleanup;311 tests pass. Full F034/F035 acceptance open. See evidence/2026-10-16/media-playback-review.json.

Native polls scoped verified: create/edit, voting/withdraw, add options, anonymous/public live peer results and close;320 tests pass. Full F017 acceptance open. See evidence/2026-10-16/poll-review.json.

Native snippets scoped verified: root/thread create, own edit, searchable language picker, code preview/expansion and full native viewer;332 tests pass. Full F016 acceptance remains open. See evidence/2026-10-16/snippet-review.json.

Native forwarding scoped verified: existing-conversation picker, exact-byte file copy chain, immediate-source metadata, confirmed destination navigation and official expansion;341 tests pass. Full F020 acceptance remains open. See evidence/2026-10-16/forward-review.json.

Native scheduling scoped verified: create/edit/cancel in Peter and canonical pending-list readback;353 tests pass. Timed delivery while the preview was closed and final minute precision verified; full F018 acceptance open. See evidence/2026-10-16/schedule-review.json.

Native avatars/read-only profiles and General-to-Peter profile navigation scoped verified; see evidence/2026-10-18/profile-review.json. Profile editing and full F055 acceptance remain open.

Native personal reminders scoped verified: create/reschedule/remove, filter and source routing, canonical cleanup, official collection live interoperability;376 tests pass. Timed delivery and full F019 acceptance open. See evidence/2026-10-18/reminder-review.json.

Conversation star/hide/show and Hidden reader implemented with synthetic fault/lifecycle checks;387 tests pass. Approved Peter star/unstar/hide/open-to-restore scoped verified; see evidence/2026-10-18/organization-review.json.

Channel discovery reader/empty state and Leave/Stay cancellation live checked; join/leave transitions fixture-only. 398 tests pass; see evidence/2026-10-18/discovery-review.json.

18 October: channel details name/purpose editing now has a bounded native/server/official-client round-trip receipt in `evidence/2026-10-18/channel-details-review.json`. Original channel96 metadata was restored; membership and ordinary posts unchanged.410 Swift tests pass. Broader management and full parity remain open.

18 October: read-only Archive history now browses server categories, archive periods and paged archived posts using isolated archive IDs. Scoped live metadata comparison and reader evidence: `evidence/2026-10-18/archive-review.json`;420 Swift tests pass. Archived system descriptions, threads/search/collections/attachments/encryption and archive/close management remain open.

18 October: archive system-event actor and rename/conversion description now match the observed official historical event. Shared system rendering also reaches live messages. Archived thread navigation/pagination added with archive/thread boundary tests; populated thread live proof remains unavailable in current archive pages.430 tests pass; `evidence/2026-10-18/archive-thread-review.json`.

18 October: archive keyword search, period scoping and read-only Pinned/Saved/Files/Links collections added. Native/official keyword search returned the same1 result; result opened matching archive context and ordinary text matched. Collections empty on current backend; populated collections, multi-period and long result pagination remain fixture-only.440 tests pass; `evidence/2026-10-18/archive-search-review.json`.

18 October: archived attachments now have isolated native image/text/PDF/audio/video viewing, loaded-image navigation and Save/Save&open.450 tests pass; real-view synthetic transport verified PDF page2, image navigation/zoom, audio/video, cancellation and exact saved bytes/external TextEdit opening. Current NAS archives have no files; actual archive-file interop remains unverified pending bounded authorization. `evidence/2026-10-18/archive-attachment-review.json`.

18 October: approved bounded NAS archive proof created self-only channel97 and retained archive26 with six synthetic files. All archived hashes match originals; native text/image/PDF/audio/video loading, PDF page2, text save and populated Files/context verified.452 tests pass, including external archive stale-timeline recovery. Official archive26 six-file history, inline PNG/text and completed MP4 playback now compared; separate image/PDF/audio opening and official download bytes remain unverified. `evidence/2026-10-18/archive-live-review.json`.

18 October: native private history archive action adds review/confirmation, fresh preflight and uncertain-request reconciliation.462 tests pass; local cancellation/failure UI and live empty-history blocking verified without further NAS writes. Close/restore and native final live dispatch remain open. `evidence/2026-10-18/history-archive-action-review.json`.

18 October: channel/conversation closing now has acknowledgement, fresh status/ACL checks, closed-archive receipt reconciliation and nested close-event invalidation.473 tests pass; official/native live review-cancel and local rejected-request UI verified without new NAS mutations. Final live dispatch and durable uncertainty recovery remain open. `evidence/2026-10-18/channel-close-review.json`.

18 October: pending archive/close recovery now persists by authenticated account, before dispatch, without credentials/content or replay.485 tests pass; synthetic real-app cold restart/status UI and real-account clean bootstrap verified. Actual lost-response NAS lifecycle remains open. `evidence/2026-10-18/channel-action-journal-review.json`.

18 October: native account notification preferences add pause/resume, daily quiet hours and preview/visible-alert/sound controls with fresh checks and receipt recovery.497 tests pass; synthetic Save/refresh/validation UI checked. Approved native20minute pause/resume matched official countdown and all original preferences restored exactly. Recurring/global alert live writes and real quiet-hour delivery remain open. `evidence/2026-10-18/snooze-settings-review.json`.

18 October: native Availability control adds persistent away/automatic state with fresh profile checks and uncertain-result recovery.505 tests pass; local rendered roundtrip and real read-only status verified. Subsequent native away/automatic live roundtrip matched official and backend; exact original state restored. `evidence/2026-10-18/manual-presence-review.json`.

18 October: native nickname/description editor with fresh readonly_profile policy and dirty-field receipts.514 tests pass; native description and nickname override/clear matched official settings, with exact original profile/preferences restored. Avatar editing remains missing. `evidence/2026-10-18/profile-editor-review.json`.

18 October: profile photo picker, crop/zoom/position, metadata-free PNG upload and confirmed removal implemented with fresh policy/version and uncertain recovery guards.524 tests pass; rendered synthetic upload/remove and real existing photo reader verified. Official crop cancelled and actual photo unchanged; live writes/propagation remain open. `evidence/2026-10-18/profile-photo-review.json`.

18 October: native paired notification device list and confirmed unpair with fresh registration and uncertain recovery guards.532 tests pass; local unpair/empty UI and real two-device list/cancel checked. Real registrations unchanged; live unpair/re-pair open. Locale formats traced to DSM shared helpers; storage/catalogues unresolved. `evidence/2026-10-18/paired-devices-review.json` and `locale-contract-investigation.json`.

18 October: shared DSM UserSettings and Profile.js contracts recovered. Native regional editor and saved timestamp formats integrated;544 tests pass. Local language/timezone save and native formats/timezone live roundtrips verified with exact original restoration. Native translations/live language and official refreshed comparison remain open. `evidence/2026-10-18/regional-settings-review.json` supersedes the earlier unresolved storage note.

18 October: native Synology application launcher and shared ordering implemented from Personal.Application.Info.555 tests pass; local order/discard UI, real list/order restore and Calendar browser handoff verified. Profile text limits/counters now align with recovered255/256 limits. `evidence/2026-10-18/application-launcher-review.json` and `profile-text-limits-review.json`.

18 October: native NAS picker, pagination/multiselection and shared review implemented. 564 tests pass; one synthetic own-home TXT sent through ds_file to Peter, downloaded hash matches and official web displays the exact caption/text. Wider live NAS coverage and Drive remain open. `evidence/2026-10-18/nas-files-review.json`.

20 October: native Drive category/folder picker, link review/insertion and explicit role editor implemented;578 tests pass. Synthetic link insertion leaves access unchanged; specifically approved Peter viewer grant confirmed and exact original access restored. Labels/search, advanced/inherited policies and wider live coverage remain open. `evidence/2026-10-20/drive-files-review.json`.

20 October follow-up: Drive search and labels browser added;581 tests pass. Native label navigation rendered; exact synthetic file search live verified. Populated live labels/advanced filters remain open.

20 October: bounded animated GIF/full-size static viewer and Show message added;585 tests pass. Synthetic GIF upload byte-equal, native playing frames differ and paused frame stable. Static Full size and exact message-context navigation verified. Inline/other animation formats and broader parity remain open. `evidence/2026-10-20/animated-viewer-review.json`.

20 October: native screenshot selection/review/cancel implemented;590 tests pass. Synthetic preview/cancel and private temporary-file cleanup rendered; real capture awaits Screen Recording access. No new message or server write. `evidence/2026-10-20/screenshot-review.json`.

20 October follow-up: screenshot save-only copy added;593 tests pass. Native Save dialog cancellation/save and byte equality verified with synthetic pixels; saved copy survives review cleanup. Real capture remains unverified. `evidence/2026-10-20/screenshot-save-review.json`.

20 October: F068 native date links/private Calendar event form implemented;602 tests pass. Date preference envelope corrected against live response. Native Cancel/create and independent readback verified with no attendees/reminders; both synthetic events deleted, one Peter source message retained. Shared calendars/richer popup controls and broader recognition/comparison remain open. `evidence/2026-10-20/calendar-review.json`.

20 October: F051 native conversation conversion/history choice implemented for ordinary unencrypted conversations;612 tests pass. In-place promotion and new-channel creation/invitation, canonical membership and partial-result recovery fixture-tested. Both real native review/cancel screens checked; Peter metadata/membership/latest post unchanged. Actual conversion, encryption and wider/durable recovery remain open. `evidence/2026-10-20/promotion-review.json`.

20 October: F070 native formatted integration cards/button triggers implemented;624 tests pass,12 targeted tests rerun after debug fixture window sizing fix. Real Calendar text card rendered; native acknowledgement/canonical refresh/lost-reply/unchanged checking/changed-card refresh locally verified. No real bot action, message or configuration change; wider/live/durable/encrypted/archive parity remains open. `evidence/2026-10-20/bot-attachments-review.json`.

20 October: F072 native slash command catalogue/suggestions/review/execute, local help and nickname shortcut added;638 tests pass. One real default Jitsi invocation generated invitation399431958770 in Peter and native link matches server URL hash. Help and nickname prefill/cancel/discard-refresh checked; profile unchanged. Empty server replies now have explicit acknowledgement; no repeat invocation for that repair. No browser/media join. Wider/custom/localization/keyboard/durable/encrypted/thread comparison remains open. `evidence/2026-10-20/slash-commands-review.json`.

20 October: F071 partial webhook management added;653 tests pass. Native editor saves and cancelled creation verified against two disabled own-account integrations in Peter, backend create/configuration/token replacement/soft deletion checked. Both fixtures removed; NAS added two automatic removal notices in Peter. No authored chat messages, incoming posts or outgoing callbacks. Avatars/stickers, actual delivery and broader/durable recovery remain. `evidence/2026-10-20/webhook-review.json`.

20 October: F069 partial bot browser and personal subscription controls added;675 tests pass (22 new). Native real catalogue/search, cancelled unsubscribe review and existing Calendar Open verified with unchanged Calendar/Drive subscriptions and scoped post identifiers. Isolated native subscribe/lost-reply unsubscribe/read-only recovery/resubscribe preserved the draft. Private account-scoped receipts survive relaunch without replay; canonical second-check and pre-dispatch cancellation covered. Real subscription mutation effects, full official comparison/configuration and wider cases remain. `evidence/2026-10-20/bot-subscription-review.json`.

20 October: F082 partial quick switcher added;695 tests pass (20 new). Own-window ⌘K/Ctrl-K, arrow selection, Return, Escape/toggle, category/search and unrelated-modal isolation live verified in Peter; synthetic unsent draft survived and was cleared exactly. No new conversation or message; latest772 unchanged. New starts have explicit review and durable typed receipt storage; existing22 bot-journal tests retain version1 compatibility. Current installed1.2.4 background verified against update cache; old1.2.3 extraction is not current. Full keyboard/menu/zoom/preferences and wider comparison remain. `evidence/2026-10-20/quick-switch-review.json`.

20 October: F081 partial download manager added;717 Swift tests pass (22 new, plus archive receipt assertions). Current-session progress/cancel/retry/open/reveal/search/clear, ordinary/encrypted/archive tracking and remembered/default Save folder. Live synthetic Peter save matched62 bytes/SHA and0600; missing/restored files, Finder reveal and clear-preserves-file checked. Desktop startup/tray/language, Pause and wider comparison remain. `evidence/2026-10-20/download-manager-review.json`.

20 October: F081 partial desktop Settings added;726 Swift tests pass (9 new preference cases). Cmd-comma/app/account routes work signed out/connected; real macOS login registration read back On then restored Off. Menu-bar preference survives quit/relaunch and was restored Off; download settings and Cmd-K modal isolation checked. Interface localization, direct tray click/unread/snooze and actual next-login launch remain open. `evidence/2026-10-20/desktop-settings-review.json`.

20 October: F082 partial native interface zoom and macOS menus;732 Swift tests pass (6 new zoom cases). Cmd-equals/plus/minus/0 and modal isolation live checked in Peter; keyboard and menu full-screen round trips preserved a synthetic unsent draft, then cleared it exactly. Zoom reset and original window state restored; no message/latest-post change. Standard app/window menu roles added; their wider live/official comparisons and display/accessibility stress remain open. `evidence/2026-10-20/interface-zoom-review.json`.

20 October: F046 partial conversation-start migration;746 Swift tests pass (14 new migration/group/profile cases). New conversation picker, profile Message and quick switcher share durable initiation; fresh identity/ACL/membership, pre-dispatch journal/second check, exact-set reuse and no replay across relaunch. Reviewed existing destinations cannot silently become new starts. Live Cmd-N Peter selection/refresh/reuse/cancel preserved and cleared a synthetic draft; latest772/members[6,10]/count17 unchanged. New/group dispatch and uncertainty/review UI still need broader verification. `evidence/2026-10-20/conversation-start-review.json`.

20 October: F059 partial per-conversation notification editor;759 Swift tests pass (13 new). Header Conversation actions offers desktop/mobile modes with dirty-field saves, fresh identity/member/source/conflict checks, canonical readback and refresh after uncertainty. Live Peter None/All/None combinations restored exact original All/All/mute=false; discard prompt checked. Self-only channel96 mention/default choices inspected with raw defaults unchanged. No messages. Delivery/mobile/current official UI acceptance remains. `evidence/2026-10-20/channel-alert-review.json`.

20 October: F066 partial sidebar grouping/sorting/collapse/preferences;772 Swift tests pass (13 new). Live pin-unread account round trip restored original settings and synthetic draft; collapse/search/expand checked in Peter. Account had no unread channels, so dynamic transition proof remains fixtures. Recovered display-name preference mismatch recorded separately as missing F084; evolving inventory now84 rows. `evidence/2026-10-20/sidebar-review.json`.

20 October: F084 partial name display implemented;787 Swift tests pass (15 new). Account-scoped formatter/editor, derived label/cache refresh, bot/guest rules, alias search and canonical mention handles. Live Peter93 Costwise→Peter→Costwise mode round trip, member/profile labels and sidebar/new-picker/quick aliases verified; raw identity hashes/other prefs unchanged, synthetic draft preserved then cleared, no message. Full surface/locale/guest/bot/lifecycle/official matrix remains open. `evidence/2026-10-20/name-format-review.json`.

20 October: F004/F007 partial shared local recent emoji (24 exact variants) and per-account remembered tone;794 Swift tests pass (7 new). Main insertion/reopen/restart/reaction-picker persistence verified without sending; Default tone restored and unsent draft cleared. Official sync/aliases/full input acceptance open. `evidence/2026-10-20/emoji-preferences-review.json`.

20 October: F006 partial participant details panel added as a native enhancement beyond the official named tooltip;803 Swift tests pass (9 new). Fresh backend snapshot, emoji/person filters, identities/profile controls, refresh/retry/cancellation/account guards. Live own-heart add/details/remove on synthetic Peter768 restored original empty reactions. Multi-person fixtures only; full input/accessibility/thread acceptance open. `evidence/2026-10-20/reaction-details-review.json`.

20 October: F014 partial typed @ autocomplete in main/thread native composers;813 Swift tests pass (10 new). Fresh context-bound actual members, aliases, keyboard/pointer selection, canonical token insertion, Undo and Unicode caret/suffix preservation. Live Peter tests used only cleared unsent drafts; broad grammar/IME/other composer/accessibility acceptance remains open. `evidence/2026-10-20/typed-mentions-review.json`.

20 October: F015 partial typed # autocomplete uses scoped backend catalogue in main/thread composers;819 Swift tests pass (6 new). Marker-separated task state, vendor hashtag grammar, key/pointer/Undo and Unicode-safe replacement. Live existing tag used only in cleared unsent drafts; catalogue/post/membership unchanged. Additional-tag management and broad input/lifecycle acceptance remain open. `evidence/2026-10-20/typed-hashtags-review.json`.

20 October: F015 partial added-tag manager and attributed browse chips;827 Swift tests pass (8 new). Fresh Post.Hashtag v1 single-tag set/delete and canonical receipts/uncertainty guards. Live found hashtags includes all indexed tags; labels/checks corrected. Synthetic Peter768 add/browse/open/remove restored original post/index/catalogue; no authored message. Broad integration/permissions/lifecycle/official acceptance open. `evidence/2026-10-20/additional-hashtags-review.json`.

20 October: F021 partial Keep on top and3 sort modes;836 Swift tests pass (9 new). Fresh/canonical/uncertainty pin guards and accessible collection identities. Live reply-key0 discovery corrected to server-order fallback; final native orders match backend. Own temporary pins/flags/subscriptions restored, NAS2 automatic notices retained. Full acceptance open. `evidence/2026-10-20/pin-order-review.json`.

20 October: F026 partial file-browser sorts/type filters/refresh/counts;844 Swift tests pass (8 new). Read-only native/backend exact ID order checks for31 files/2 pages and6 images in4 option combinations; Links4 results and transitions verified. Catalogue and latest774 unchanged; encrypted/snapshot/URL-dedup/accessibility/official acceptance open. `evidence/2026-10-20/library-file-options-review.json`.

20 October: F026 partial per-URL metadata cards, exact grouping/source navigation/promotion and NAS-only images;855 Swift tests pass (11 new). Live4 originals and5-source duplicate test verified; own775 soft-deleted and402 confirmed without retry, original catalogue restored. Public card screenshot inspected in final build. Larger/multi-URL/media/concurrent/accessibility/official matrix open. `evidence/2026-10-20/link-library-review.json`.

20 October: Collection live reconciliation (F021/F022/F026 partial);868 Swift tests pass (13 new). Account/channel-scoped canonical events, tombstones and full-loaded-range rebases protect against stale pages. Live two-URL own776 create/edit/delete updated an open Links browser without refresh and restored original4 catalogue. Reconnect/full live collection matrix and full parity remain open. `evidence/2026-10-20/collection-reconciliation-review.json`.

20 October: Collection reconnect recovery (F021/F022/F026 partial);874 tests pass (6 new). Live real-socket probe missed own777 create/save, edit/unstar and delete, recovered each handshake, retained31 loaded files/3 pins/draft and restored2 saved/4 links. Receipt-bound soft-delete402 confirmed. Full mutation/permission/encryption/official matrix remains open. `evidence/2026-10-20/collection-recovery-review.json`.

20 October: F031 partial anchored image-only main/thread gallery paging;881 tests pass (7 new). Native5-image arrow sequence matches backend, older640 source jump fixed/live verified; thread750/root735 shows1 isolated image and source return. No server writes. Larger pages fixture-only; library/encrypted/lifecycle/official rendered UI acceptance open. `evidence/2026-10-20/image-gallery-review.json`.

20 October: F026/F031 partial Files-gallery paging in original result order plus nested source-browser dismissal;887 tests pass (6 new). Live31 files/2 pages in both sorts: newest5→6 and filename3→6 images; exact hashes and parent loaded-page retention verified. Final main/thread source returns expose source after closing both sheets. Read-only baseline unchanged. `evidence/2026-10-20/library-gallery-review.json`.

20 October: F004/F007 partial NAS-backed recent emoji:896 tests pass (9 new). Official24-entry exact MRU imported/synchronized with serialized fresh Chat namespace writes and canonical confirmation; failed-response replay blocked, local tone retained. Live9→10 unsent Heart selection and exact9 restore/restart verified; unrelated settings hashes identical and no message sent. `evidence/2026-10-20/emoji-recent-sync-review.json`.

20 October: F044 partial raw search operators/multi-value arrays and friendly identity suggestions;905 tests pass (9 new). Exact native/backend IDs/order in8 read-only Peter queries, including31 files/2 pages; content/author suggestion and invalid-date clearing verified. Account baseline unchanged. `evidence/2026-10-20/search-operators-review.json`.

20 October: F044 partial caret-aware AppKit search field, keyboard suggestion selection and native date field/calendar;914 tests pass (9 new). Live middle-token completion preserved trailing filter and paged31 exact files; Return-without-selection/pins3, filetype/GIF and date/GIF, Escape and clear verified. Graphical calendar accessibility/arrow+Space/Use date path verified; pointer day selection open. `evidence/2026-10-20/search-completion-review.json`.

20 October: F019 partial timed private reminders;921 tests pass (7 new). Server-generated self-only reminder copy, original sender/date and exact Peter source navigation verified. No matching notification event/macOS delivery observed; alerts remain open. Schedule0/source unchanged/unread0; system-bot test copy remains after one cleanup attempt, no replay. `evidence/2026-10-20/reminder-delivery-review.json`.

20 October: F044 partial ordinary-text author/conversation/operator suggestions, bot mention exclusion and bounded scrolling keyboard list;927 tests pass (6 new). Native author completion preserved trailing date and returned31 exact backend IDs/2pages; plain Return0, conversation completion and13-item last-row/date keyboard path verified. Official filetype:/# value completion intentionally absent. Read-only test. `evidence/2026-10-20/search-general-review.json`.

20 October: F038/F039 partial local image previews in attachment review and real NSOpenPanel/Finder Command-V integration;935 tests pass (8 new). Native two-file picker and three-file paste preserved captions/drafts and cancelled without sending. Failed thumbnail Retry recovered pixels and refreshed46→939 bytes after replacing the synthetic fixture. Final compatible build rendered pasted images; source files and account baseline unchanged. Physical drag/raw image clipboard/thread/encrypted/official acceptance open. `evidence/2026-10-20/system-attachments-review.json`.

11 November: integrated draft recovery, startup member-name resilience, drop consumer, viewer zoom and emoji keyboard improvements;988 tests pass. Optimized candidate built; live launch smoke and physical drag completion remain open. See `evidence/2026-11-11/daily-use-integration-review.json`. Full parity unaccepted.

11 November followup:1,010 tests pass; multiline quote blocks, NAS-proxied favicons/image dimensions, day/continuation grouping and reliable scoped image keys verified in local native fixtures. Optimized normal build packaged; previous native and wrapper retained. The signed-in988 candidate remains running. Receipt: `evidence/2026-11-11/rich-ui-review.json`. Full parity open.

11 November goal followup:1,041 tests pass. Guest authentication and read-only guest inventory, richer attachment cards and image gestures integrated. Offline encryption plans independently verified; no account-key writes. See `evidence/2026-11-11/goal-followup-review.json`. Full parity open.

Office preview followup:1,048 tests pass; actual DOCX/XLSX rendering/private lifecycle verified in disconnected preview. Normal app remains1041 pending next batch. Evidence:`evidence/2026-11-11/office-preview-review.json`.

Guest-management followup:1,064 tests pass; local invitation/expiry/resend/removal and independent source review recorded in `evidence/2026-11-11/guest-management-review.json`. Combined optimized normal includes Office previews. No real invitation or NAS change.

Current normal is purple **Chat Native**,1094 tests; blue P preview is separate, wrapper green unchanged. Native saved restore/Live17 and bounded real messages778/779/780 verified between own accounts only; synthetic encryption setup/rewrap and source review/race fix recorded in `evidence/2026-11-11/encryption-brand-live-review.json`. Full parity open.

11 November current baseline: installed official app is1.2.5-240.4, universalarm64/x86_64. Bounded static wrapper comparison supersedes earlier “current1.2.4” notes for current-version claims; those remain dated historical evidence. F081 downloadedOpen confirmation and F074 certificate-rejection savedlogin behavior require native policy/runtime comparison. See `evidence/2026-11-11/official125-baseline-review.json`. No full current runtime/NAS UI acceptance claimed.

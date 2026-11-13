# MacBook continuation — 13 November 2026

Resume the full native Synology Chat replacement goal. This is a work-in-progress checkpoint, not a release or full parity claim. Start with this file, WORKING-NOTES.md (latest entries), feature-parity.json/.txt, native-client-roadmap.json and native-viewport-rollout-contract.json.

## Transfer and setup

All product sources, resource bundles, tests and synthetic fixtures, pinned Swift dependency resolution, packaging assets/scripts, API contract notes and feature registers are committed. macOS 13+ and an Apple silicon Mac with Xcode command-line tools/Swift 5.9+ are required. SwiftPM resolves swift-sodium 0.11.0 from the pinned Package.resolved. Python 3 is used by packaging tools; Node is used only for optional interoperability/probe scripts, not the Swift app build. Build from a fresh checkout with `swift package resolve`, then `swift build --jobs 4`. Do not reuse original-machine .build caches.

Start safe synthetic work without a NAS sign-in. `bash scripts/package-preview-checks.sh --regional-ax` builds the isolated Regional Accessibility Checks app. `--timeline` builds Chat Timeline Checks. Launch only these isolated apps for desktop checks until the user authorizes any broader scope on the MacBook. Use the computer-use tool for UI, not shell-driven mouse/key automation. Only one coordinated UI activity at a time.

`bash scripts/package-api-app.sh --candidate` stages an optimized client without replacing the normal client. Read its flags first. Never promote/restart the user's working app merely to check a build. Keychain sessions and account state remain on the original Mac, are not in Git and should not be copied through GitHub. A first live sign-in on the MacBook may require Peter to sign in in the app. Never ask for a password in chat or publish/revoke an existing session.

Raw local evidence (screenshots, full runtime/test logs, account receipts) remains on the original Mac, excluded from this public repository. local-evidence-inventory.json records relative paths, sizes and hashes; a missing raw artifact on the MacBook is not proof of acceptance. handoff-evidence contains terminal test-result extracts sufficient to identify current failures. Reproduce checks locally when needed. Source fixtures are self-contained and do not require raw evidence/cache files to compile.

## Current test state and immediate work

Last full suite: 1854 tests, SIX assertion failures in ONE existing default-reader test: NativeThreadReconnectViewportTests.testStandardReconnectRetainsRealOlderReplyPixelAndReconcilesCanonicalWindow. On canonical refresh, predecessor139 grows and reader140/offset0 becomes139/offset-225 at100ms/200ms/1s. Native opt-in reader passes; normal default remains guarded LazyVStack. Do not skip the case, weaken tolerance or switch defaults merely to make it green.

Latest source addition: DEBUG NativeTimelineChecks action mode + NativeTimelineActionFixtureTests, six new cases. Latest focused selection22/0 includes six new cases plus production viewport/rich/editor contracts. Full suite and optimized mode have NOT been rerun after these latest fixture-only additions; expected count is not an observed result. Previous optimized mode50/0; mode includes8 explicit test files and does not compile DEBUG fixture tests.

Current pending investigation: inspect NativeTimelineViewport.swift, NativeScrollVisibility.swift and standard thread reader in NativeMessageRow.swift. Canonical neighbor height change moves the older reader. This stop occurred after reads only; no new production fix has been made. Tests independently observe actual NSScrollView/row-marker geometry in hidden windows. Preserve original scroll/document identity and exact row/pixel position, manual input ownership, navigation tokens and account/channel/thread isolation.

Suggested focused command:

```sh
env -u NATIVE_PRODUCTION_VIEWPORT_CHECKS -u NATIVE_PRODUCTION_VIEWPORT_EVIDENCE swift test --disable-automatic-resolution --jobs 4 --filter NativeThreadReconnectViewportTests
```

Normal full suite: same command without filter. Optimized selected contracts: `NATIVE_PRODUCTION_VIEWPORT_CHECKS=1 swift test -c release --disable-automatic-resolution --jobs 4`. Run builds/tests centrally, not concurrently across agents. Do not restart a running handle because a poll timed out.

## Visible UI state and limits

Latest approved desktop phase was SETTINGS ONLY. Actual current DEBUG isolated settings: Profile/Name repeated reentry, username/nickname Save/Refresh/unsaved protection, Availability away/automatic, date-format Save/Refresh, 24-hour preview/unsaved protection, London timezone Save/Refresh all verified; original values/draft restored, fixture quit. No live NAS writes in that phase. Keyboard radio focus remains unverified. User's normal signed-in app/photo/thread untouched.

Earlier native timeline fixture action mode exists but visible reaction/menu/edit/pending-save/image acceptance remains unfinished. Toggle Synthetic actions then Native reader in the fixture. Default remains read-only. Synthetic reaction writes only IDs1003/1006; own edits only1003/1004 and reply1102; generated PNG1008 is96x64. Hold next Save/Release Save/Inspect actions allow an actual visible pending-save check without a NAS. Fake gallery pagination and emoji recent-settings writes are unsupported; do not mislabel fixture limitations as product bugs. Fixture API cases are not visible menu/button proof. No final action UI acceptance recorded.

Native viewport is opt-in/unadopted. Actual host tests cover pixel anchors, bounded hosts, rich content, environments, exact TextEditor identity/selection/undo/focus through offscreen resize and same-reader reconnect. Save conflict preflight checks immutable original baseline, scoped owner/session and exact wire readback. No observed server CAS; post-preflight race remains. Current DEBUG own-Peter live model edit/readback and stale conflict refusal verified, not optimized packaged/physical/socket proof.

## Work still required for the full goal

Keep all84feature requirements and modern Slack-inspired dark UI scope. Do not infer parity from counts. Prioritize the default-reader regression; actual visible message controls/pending editing/image/viewer; current optimized own-account send/incoming/socket/notification/read-receipt behavior and official comparison; remaining settings/rich/channel workflows, keyboard/IME/accessibility and whole-app visual acceptance. Physical file drops into main and thread were user-confirmed; do not unnecessarily repeat their personal photo upload.

Standing test permission: own-account and synthetic tests allowed. Do not message, notify or interact with other users. Any live communication requires freshly verifying the two Peter account identities and exact conversation membership; historical known IDs own6/10 andDM93 are hints, not current authority. Preserve original wrapper, user data, saved auth and rollback builds. Current original-machine normal/staged build hashes are recorded in WORKING-NOTES and latest settings reviews. No app packages or credentials are transferred through this source checkpoint.

The user requested a stop and migration to the MacBook so computer use does not disrupt the original Mac. Do not resume original-Mac desktop work. No compiler/test/probe was running at this breakpoint; isolated settings app closed. The earlier timeline fixture may still be open; it was not operated under the later settings-only permission. Goal remains unfinished and paused for this handoff.

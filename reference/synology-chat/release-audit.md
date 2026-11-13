> Historical core-workflow assessment. The active full-parity goal is not achieved.
> Use `python3 -B scripts/parity-status.py --json` for current goal acceptance.
> New redesign source differs from this historical baseline.

# Native API core workflow acceptance certificate

**GO** for the recorded11 core local workflows at HEAD `9447bd9a8b7b4013c60b17f695d6a6ff409af28c` with the pinned dirty working tree below. The active successor goal is full desktop parity plus modern native UI; that goal is not achieved.

Pinned at 2026-10-16T18:26:16.940879+01:00 to tree `2433d17707e71e27a68057d91b59e3c1eef8bb99`, branch `main`, index SHA-256 `8728d429f97b0a33235d56751f1b00a3bb4c1f2aa0b9c182dc103f644b4cb7fc`, working inputs `5d1ef4637a6388dc8ba48cccac5766c110234a9cba9df5ccef55cafac3b9f475`. Adjacent JSON names every input and dirty path.

| Measure | Result |
| --- | --- |
| Canonical acceptance |11/11 =100% |
| Engineering/evidence |104/104 =100% |
| Cumulative checks |Security, simplicity, coherence, compatibility, retained rollout and final audit closed within explicit scope |
| Assessment freshness |Current source/test/log/artifact hashes match; strict normal signature verifies |
| Next-release clearance |No successor release defined; this certifies the requested local deliverable only |

| Outcome | Canonical status | Evidence | Reachable | Remaining gate |
| --- | --- | --- | --- | --- |
| R1: Independent authentication and session lifecycle | accepted | 10/10 (100%) | yes | None within scope |
| R2: Conversations, members, history and pagination | accepted | 10/10 (100%) | yes | None within scope |
| R3: Sending, live updates and reconnect | accepted | 10/10 (100%) | yes | None within scope |
| R4: Attachment transfers and interaction | accepted | 10/10 (100%) | yes | None within scope |
| R5: Thread replies, reactions, author edits and soft deletion | accepted | 10/10 (100%) | yes | None within scope |
| R6: Unread state, presence, notifications and badge | accepted | 10/10 (100%) | yes | None within scope |
| R7: Improved native dark interface | accepted | 8/8 (100%) | yes | None within scope |
| R8: Encrypted conversation support when applicable | accepted | 8/8 (100%) | yes | None within scope |
| R9: QuickConnect support | accepted | 10/10 (100%) | yes | None within scope |
| R10: Preserve original wrapper and official app | accepted | 9/9 (100%) | yes | None within scope |
| R11: Runnable native replacement delivery | accepted | 9/9 (100%) | yes | None within scope |

The newly requested modern Slack-inspired redesign (F083) remains unimplemented and is not certified by this historical core-workflow acceptance.

## Cumulative acceptance

This certificate does not establish full official-app feature parity. The broader comparison in `feature-parity.txt`/`feature-parity.json` identifies missing features, including full reactions/stickers, rich links and image viewing. All11 core outcomes were reviewed against current reachable native source, unchanged208-test runtime inputs and retained live/UI/independent readback proof. The native normal208 bundle restores its own saved session, exchanges correctly typed messages with the official client, and reopens from General into Peter at the exact notified message. Native shared views/model cover author actions, paging, transfer cancellation/recovery and failure/draft recovery. Original wrapper hashes and previous native backup are preserved. See `evidence/2026-10-16/final-native-objective-audit.json` for per-requirement evidence.

Spoken VoiceOver verification was an additional check introduced during development, not a requirement of the requested dark native client. It remains inconclusive and explicitly optional after the user questioned its necessity. Keyboard/AX support remains implemented; no speech certification is claimed. Original accessibility settings are restored.

## Limits


- Local Apple silicon Mac/current NAS acceptance only; no notarization or older macOS/Intel runtime certification.
- No current encrypted NAS account or live OTP challenge: existing-key crypto and OTP are fixture-covered, no live interoperability claim. Encryption setup/reset/archive management is outside applicable current use.
- No indefinite uptime guarantee; one real sleep/wake plus deterministic lifecycle and live automatic transport recovery.
- Swift memory cannot guarantee forensic zeroization; forced termination may leave owner-only staging; explicit save exports plaintext; encrypted download cap applies after transfer.
- Existing official vendor signature provenance is unestablished; original wrapper and official package isolation were preserved.
- Notification cold-start queue is model-tested; actual closed-window click is live-proven. No live cold-start click claim.
- Backend APIs are observed vendor internals and may change with NAS updates.

## Blockers and next work

No required implementation, user-input, open-decision, external-evidence, retained-operation or unknown blocker remains for this local objective. No pending user action. Optional future work: screen-reader usability, live encrypted NAS/OTP proof when applicable, broader hardware/server compatibility and signed/notarized public distribution. These are not claims of the current certificate.

The source remains an uncommitted dirty working tree; no commit, push or public release was requested. Run `python3 -B scripts/release-status.py --json` to verify freshness and acceptance.

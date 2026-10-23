# Maestro Limit

Maestro Limit is a macOS menu bar app and desktop widget for keeping Codex allowance, reset times, and data freshness visible. It reads your signed-in local Codex CLI, adapts polling to your Mac's power source, and can keep eligible reset windows rolling with a minimal request while plugged in.

Built on [Codex Limit Widget](https://github.com/sergeylopukhov/codex-limit-widget). This fork is maintained at [Calabor-Hoc/codex-limit-widget](https://github.com/Calabor-Hoc/codex-limit-widget).

## Requirements and installation

- macOS 14 or later.
- Xcode with Swift 6 support to build from source.
- Codex CLI installed and signed in for usage readings and optional rollover requests.

Build the shared scheme from this repository:

```sh
xcodebuild -project CodexLimitWidget.xcodeproj \
  -scheme CodexLimitWidget -configuration Debug \
  -derivedDataPath build/MaestroLimit \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

The app is produced at `build/MaestroLimit/Build/Products/Debug/Maestro Limit.app`. Copy it to `/Applications/Maestro Limit.app` and launch it. Ad-hoc signing is for local use; distribution signing and notarization require your own Apple signing setup.

Right-click the desktop, choose **Edit Widgets**, search for **Maestro Limit**, and add Small, Medium, or Large. After renaming an older Custom installation, remove its existing widgets and add the Maestro Limit widgets.

Maestro Limit has a separate bundle identifier, URL scheme, data directory, and local bridge port from the original app. The two apps can coexist. Its own internal identifiers and data directory remain stable across the product rename, preserving settings and history.

Updates are installed locally from this fork. Automatic downloads and installation of upstream releases are disabled.

## Menu bar

Detailed mode displays:

```text
97% FH 82%
```

The unlabeled percentage on the left is the weekly remainder. **FH** identifies the five-hour remainder on the right. A missing limit window is omitted. Existing credit-balance fallback behavior remains available for exhausted limits when Codex reports credits.

Compact mode shows a single selected percentage with an optional colored meter and colored digits. Left-click and right-click actions can independently open the context menu, popover, settings, or Codex. The context menu supports manual refresh, copying status, and quitting.

The popover shows allowance meters, reset times, and account details. An optional global shortcut toggles the detailed limits window. The custom settings window supports **Command-W** to close.

## Desktop widgets

Small, Medium, and Large are available in Dark, Beige, or System appearance. The layouts prioritize allowance percentages and readable reset and sync information. Widget cards omit the app-name heading, the redundant Remaining caption, and Plan.

- **Small:** five-hour reset at the top, SYNCED directly below, a large primary percentage, then weekly reset above the weekly meter.
- **Medium:** SYNCED aligned left and RESETS aligned right on the top row; a larger primary percentage and reset details fill the body. Weekly percentage appears with its meter rather than being repeated in the body.
- **Large:** primary allowance, weekly meter and reset, streak, longest turn, daily average, lifetime tokens, daily totals, and a seven-day chart when usage history is available.

Accounts without a five-hour window use the weekly window as the primary metric. Settings control reset information, last-sync visibility, appearance, language, and the action opened by a widget click. Last-sync visibility is enabled by default.

Reset times use the Mac's local time zone, **24-hour format**, and minute precision. Weekly resets include a weekday.

SYNCED expresses the age of the last successful reading:

| Age | Example |
| --- | --- |
| Under one hour | `0min ago`, `1min ago`, `59min ago` |
| One through nine hours | `1h ago`, `1.5h ago`, `9h ago` |
| More than nine hours | `stale` |

Hours are truncated to one decimal place. Freshness is based on the real successful sync timestamp, never on when a view happened to render.

## Power-aware polling and widget updates

While the app is running and the Mac is awake:

| Power source | Data polling |
| --- | --- |
| AC power | Approximately every 30 seconds |
| Battery, or unknown power state | Approximately every 5 minutes |

The app checks power every 30 seconds. Connecting or disconnecting power takes effect on the next check. Polls do not overlap authentication, CLI installation, or another data refresh. A half-second tolerance handles timer jitter. Sleeping or quitting pauses execution; manual refresh remains available.

The menu bar follows the app's readings. Widget updates have a separate lifecycle:

- Successful polls publish the latest payload to the local bridge.
- Changed data requests a WidgetKit timeline reload; unchanged data requests one after 15 minutes.
- Timeline entries advance relative sync age without sending extra CLI or LLM requests: every minute during the first hour, then at each tenth-hour change, ending at `stale` after nine hours. At most 142 entries keep rendered timelines small enough for all widget sizes, including Medium. Entries remain aligned to the actual sync timestamp even if the app stops.
- WidgetKit decides when reload requests and timeline entries are displayed. A 30-second app poll does **not** guarantee a 30-second desktop widget refresh.

If a usage-statistics request fails, the previous statistics can be retained. Statistics older than six hours are treated as expired. Failed allowance polls preserve the last successful reading and its timestamp.

## Keep reset windows rolling

**Keep reset windows rolling (AC only)** is a simple continuous scheduler in General settings. It is enabled by default in this personalized build and can be switched off at any time.

**Next 5-hour reset target** lets you schedule a one-time desired reset date and time. Select a local time at least five hours ahead and click **Schedule**. For an 11:00 target tomorrow, Maestro keeps rolling until 01:00, holds all automatic turns from 01:00 to 06:00 (including weekly-triggered turns), then resumes eligible rolling at 06:00. This leaves room for a new five-hour window ending around 11:00. **Clear target** returns to continuous rolling; the target also stops restricting rolling once its time has passed.

The target is a plan, not a provider-side reservation. Sleep, battery power, network failures, exhausted quota, and your own intervening Codex usage can delay or prevent it. Maestro cannot move an already active window. The existing 60-second expiry buffer still applies when a boundary falls exactly at the planned start. After waking on AC power it evaluates one current opportunity, without replaying missed requests. Schedule changes, hold decisions, planned times, lateness, and observed reset offsets are recorded in the daily logs.

For accounts where the next usage window starts on the first request after expiry, Maestro Limit can send a minimal Codex turn after the observed boundary. It uses the existing allowance polling instead of adding a second usage poller.

The scheduler:

1. Tracks observed five-hour and weekly reset boundaries across restarts. It does not bootstrap an unknown, unused window.
2. Waits until an eligible boundary has passed, plus a **60-second buffer**. It does not send early into the old window.
3. Requires a recent successful reading, known weekly usage below 99%, available five-hour allowance when present, and AC power.
4. Skips a window that fresh usage has already shown to be active.
5. Combines simultaneous due opportunities into one turn; sent attempts are at least one hour apart.
6. Queries the installed Codex model catalog without starting a turn. It selects visible `gpt-6-luna`, otherwise `gpt-5.6-luna`; if neither is available, it sends nothing.
7. Rechecks power, the enable switch, the schedule, and fresh usage after the model probe. It reserves the opportunity on disk immediately before sending. The isolated, ephemeral, read-only CLI turn asks only for “OK”, uses low reasoning, and ignores user config and project context.
8. Rereads allowance after the attempt and logs whether a future reset and actual usage confirm a new window.

Requests consume subscription allowance. This feature cannot create extra quota, bypass an exhausted limit, reset an active window, or force an earlier weekly reset. The provider controls window behavior; a successful turn alone is not confirmation that either reset moved.

A request that may have been sent is not automatically retried, including after a timeout, process failure, or app restart. Read-only probe failures and missing supported models do not consume an opportunity; later polls can check again. Uncertain sends remain reserved. A corrupted reservation file fails closed. Switching to battery or disabling the feature before sending cancels that attempt; a request already sent cannot be undone. No new automatic turn begins on battery.

The Mac must be awake, signed in, and running Maestro Limit. After waking, the scheduler evaluates the current state rather than replaying every missed window.

The minimal scheduling approach is inspired by [UsageLoop](https://github.com/benthompsondev/usageloop). Maestro Limit offers a one-time five-hour target rather than recurring daily or weekly routines.

## Execution logs and diagnostics

Runtime logs are persisted as daily JSONL files:

```text
~/Library/Application Support/CodexLimitWidgetCustom/polling-logs/polling-YYYY-MM-DD.jsonl
```

The stable directory name preserves earlier Custom-version logs. File dates and timestamps use UTC; convert them to local time when reviewing.

Each record includes timestamp, process ID, app version, log schema, event name, power source, and polling interval. Relevant events include:

- `power_source_changed`: previous and current power source.
- `waiting`, `skipped_busy`, `refresh_started`, `refresh_finished`: measured interval since the previous attempt, request duration, success, last successful sync, and polling errors.
- `rollover_decision`: enabled state, eligibility reason, observed and tracked resets, usage percentages, reservations, and previous attempt time.
- `rollover_model_probe_started`, `rollover_no_supported_model`, `rollover_started`: capability checks and selected model.
- `rollover_finished`, `rollover_uncertain`: exit status or error category, duration, and retry suppression.
- `rollover_verified`: which reset opportunities were confirmed after the readback.
- Reservation failures and cancellation because of power or settings changes.

A daily review can distinguish actual refresh attempts from waiting, model-turn success from reset confirmation, and AC/battery behavior across app sessions. Sleep and app-exit gaps are not by themselves proof of a scheduler failure. Missing battery or transition samples mean that behavior still needs observation.

Logs do not store credentials, prompts, model replies, or conversations. They remain local; raw logs are not included in Git. Logs currently have no automatic retention limit. The settings Diagnostics tab also exposes connection state, latest successful sync, refresh errors, and Reset data. The rollover reservation ledger remains separate so a data reset cannot accidentally resend an uncertain turn.

## Local data and privacy

Settings, allowance snapshots, widget payloads, notification history, rollover reservations, and audit logs are stored locally under:

```text
~/Library/Application Support/CodexLimitWidgetCustom/
```

The app and extension communicate through the dedicated loopback endpoint `127.0.0.1:38348`. Widget links use `codexlimitwidgetcustom://`; these internal names intentionally remain stable.

Codex owns authentication and provider communication. Allowance reads use its local app-server. Optional rollover turns use the installed CLI and existing signed-in subscription, without requiring a separate API key. Maestro Limit does not upload usage or audit logs to a service of its own.

## Development and verification

```sh
xcodebuild -project CodexLimitWidget.xcodeproj \
  -scheme CodexLimitWidget -configuration Debug \
  -derivedDataPath build/MaestroLimit \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

Tests cover existing snapshot/preferences behavior, remaining-level boundaries, relative-age formatting, power-specific polling intervals, rollover buffering and deduplication, active-window/exhaustion guards, and reservation serialization.

Builds and synthetic tests do not replace observing real AC/battery transitions or a provider-confirmed reset rollover. Use the persisted logs to assess those after real usage. No rollover turn is sent merely to make a test pass.

## Credits

Maestro Limit is an independent fork of [sergeylopukhov/codex-limit-widget](https://github.com/sergeylopukhov/codex-limit-widget), with continuous-window scheduling informed by [benthompsondev/usageloop](https://github.com/benthompsondev/usageloop). It is not affiliated with or endorsed by OpenAI. Legacy upstream screenshots and translated documentation may depict the original app; this README describes Maestro Limit.

# Claude Usage Visualizer — Architecture

Menu bar widget that tracks Claude Code usage against Max plan limits in real
time. Built entirely on local data: no Anthropic API calls (there is no public
API for Max-plan rate-limit state).

## UI

```
┌─────────────────────────────────────────────────┐
│                   macOS Menu Bar                 │
│              ┌──────────────────┐                │
│              │  NSStatusItem    │                │
│              │  icon + % / tok  │                │
│              └───────┬──────────┘                │
└──────────────────────┼──────────────────────────┘
                       │ click
                       ▼
┌─────────────────────────────────────────────────┐
│              NSPopover (360×560)                 │
│                                                  │
│  UsageHeaderView   142/225 msgs · 2h14m          │
│  BurnRateGauge     9.2k/m HOT                    │
│  ModelBreakdownView   Opus/Sonnet/Haiku bar      │
│  SessionListView   per-session tokens + model    │
│  InsightsView      top 3 suggestions + Apply     │
│  BreakNudgeView    cute break card (conditional) │
│  WeeklyUsageView   7-day sparkline               │
│  Footer            live · gear · refresh · quit  │
└─────────────────────────────────────────────────┘
```

## MVVM + actors

```
Views (SwiftUI) ←→ ViewModels (@MainActor) ←→ Services (actor)
                                                  │
                       TranscriptWatcher ──────────┤   FSEvents on ~/.claude/projects
                       SessionRegistry ───────────┤   ~/.claude/sessions/*.json + kill(pid,0)
                       UsageAggregator ───────────┤   7-day ring buffer → 5h blocks, burn rate
                       InsightsEngine ────────────┤   pure heuristics → suggestions + nudge
                       ApplyService  (MainActor) ─┤   pasteboard, settings.json confirm sheet
                       NudgeScheduler (MainActor)─┘   UNUserNotificationCenter
```

## Data flow

1. `TranscriptWatcher` starts on launch; cold-scans existing `.jsonl` files
   (backfilling last 7 days), seeds byte-offsets, then subscribes via FSEvents
   and a 30s polling fallback.
2. New assistant turns are parsed into `UsageEvent`, streamed to
   `UsageAggregator` which dedups by `requestId` and maintains a 7-day ring
   buffer.
3. Every `refreshIntervalSeconds` (default 3s) the view model calls
   `aggregator.currentSnapshot()` which reconstructs 5-hour blocks anchored on
   the first assistant turn of each block and computes burn rate (EWMA of the
   last 5 min).
4. `InsightsEngine.evaluate(snapshot, tier)` returns up to 3 ranked
   `OptimizationSuggestion`s plus an optional `BreakNudge`.
5. `AppDelegate` observes `UsageViewModel.$statusIcon` and `$snapshot` via
   Combine and mirrors the state into the menu bar (icon + optional
   tokens/min or %-of-block title).

## Files

See `/ClaudeUsageVisualizer/` — full tree mirrors the sibling
`mac-storage-visalizer`:

- `App/` — `@main` + `AppDelegate` with NSStatusItem/NSPopover
- `Models/` — Sendable value types (`UsageEvent`, `UsageBlock`, `BurnRate`, …)
- `ViewModels/` — `@MainActor` observables
- `Views/` — SwiftUI components
- `Services/` — actor-based pipeline
- `Utilities/` — FSEvents wrapper, JSONL reader, formatters, theme
- `Resources/` — `Info.plist` (LSUIElement=true), entitlements (sandbox=false),
  assets

## Why no sandbox?

Reading `~/.claude/projects` requires home-dir access. The sibling storage
visualizer takes the same approach. Full Disk Access is not required because
`~/.claude` is inside the user's home, not protected. Distribution path is
direct (not Mac App Store).

## Testing

- `Scripts/dev-replay.sh --rate 6000 --model opus --minutes 10` appends
  synthetic `message.usage` lines under a scratch project dir to simulate a
  high-burn session. Status icon should ramp warm → hot → critical within a
  minute; break nudges + insight rankings should respond.
- Run the app alongside a real `claude` CLI session. New messages propagate via
  FSEvents within ~2s.
- Kill the `claude` PID to confirm the session row flips to idle within 3s.

## Known caveats

- `225 msgs / 5h` is the published Max 5x soft cap — real server-side limits
  vary by load. UI labels this as "estimated".
- Weekly cap is undocumented by Anthropic; shown as raw totals for now.
- `kill(pid, 0)` can't distinguish suspended from running; acceptable for v1.
- Opus 4.7 tokenizer produces up to 35% more tokens than 4.6 for the same
  text — cost figures reflect actual tokens, not character counts.

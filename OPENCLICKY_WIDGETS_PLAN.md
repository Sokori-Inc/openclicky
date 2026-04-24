# OpenClicky Widgets Plan

## Goal

Add optional macOS desktop/widgets support for OpenClicky so users can keep lightweight, glanceable views of active agents, recent task outcomes, voice/session stats, and useful OpenClicky context without opening the HUD or settings.

Widgets should complement the menu-bar companion. They should not replace voice-first interaction, the floating response card, or the advanced Agent Mode dashboard.

## Implementation Status

Started on 2026-04-24.

Implemented:

- Shared widget snapshot models.
- App-side widget snapshot writer with App Group container and Application Support fallback.
- Settings controls for enabling widgets and controlling sensitive widget content.
- WidgetKit extension target with Active Agents, Today Stats, and Needs Attention widgets.
- Deep links from widgets back to OpenClicky agents, settings, logs, and memory.
- Agent Mode prompt context for `widget-snapshot.json`.

Still to verify in Xcode:

- Signing/provisioning for `group.com.jkneen.openclicky`.
- Widget gallery installation and layout rendering across all widget families.
- End-to-end deep-link behavior from a live desktop widget.

## Product Shape

Initial widget set:

1. Active Agents
   - Shows running, ready, failed, and recently completed agents.
   - Small: count and latest status.
   - Medium: top three agent tasks with status captions.
   - Large: active agents plus latest useful result or blocker.

2. Today With OpenClicky
   - Shows daily task count, voice interactions, agent completions, failures needing review, and latest saved memory/task outcome.
   - Useful as a lightweight stats widget.

3. Needs Attention
   - Shows failed agents, flagged log-review comments, missing credentials, or permission issues.
   - Tapping opens the relevant OpenClicky window: settings, log viewer, memory, or Agent Mode dashboard.

Later widgets:

1. Current Focus
   - Shows the currently focused app/window and relevant OpenClicky suggestion.
   - Requires careful privacy gating because it reflects desktop context.

2. Memory Highlights
   - Shows recent durable memories and learned workflows.
   - Useful for tuning and self-improving agents.

## Architecture

Use a WidgetKit extension with a shared App Group container.

Shared data flow:

1. OpenClicky app owns live state.
2. App writes a compact widget snapshot JSON file into the App Group container.
3. App calls `WidgetCenter.shared.reloadTimelines(ofKind:)` after meaningful changes.
4. Widget extension reads the snapshot and renders static SwiftUI views.

Do not make widgets query live process state directly. WidgetKit timelines are snapshot-based and can run outside the main app process.

Recommended shared files:

- `widget-snapshot.json`
- `widget-agent-summaries.jsonl` if history is needed later
- `widget-review-comments-summary.json`

Suggested model:

```swift
struct OpenClickyWidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    var activeAgents: [WidgetAgentSummary]
    var todayStats: WidgetTodayStats
    var needsAttention: [WidgetAttentionItem]
    var latestMemorySummary: String?
}

struct WidgetAgentSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var status: String
    var caption: String?
    var updatedAt: Date
}
```

## App Changes

Add `OpenClickyWidgetStateStore` in the main app:

- Builds snapshots from `CompanionManager.codexAgentSessions`, `agentDockItems`, message logs, review comments, permissions, and memory state.
- Writes JSON atomically to the App Group container.
- Throttles writes so active streaming does not spam WidgetKit.
- Publishes refreshes on important transitions:
  - agent created
  - agent status changes
  - agent final response received
  - agent failure
  - review comment saved
  - permission/configuration status changes

Add Settings section:

- Widgets enabled toggle
- Include agent task names toggle
- Include memory snippets toggle
- Include focused-app context toggle, off by default
- Open macOS widget gallery/action guidance if possible

## Widget Extension

Create a new target:

- `OpenClickyWidgets`
- Bundle identifier: `com.jkneen.openclicky.widgets`
- Uses WidgetKit and SwiftUI.
- Shares a small model file with the app target.
- Reads snapshots from the App Group container.

Widget kinds:

- `OpenClickyActiveAgentsWidget`
- `OpenClickyTodayStatsWidget`
- `OpenClickyNeedsAttentionWidget`

Supported families:

- `.systemSmall`
- `.systemMedium`
- `.systemLarge`

Use restrained macOS styling:

- Dense, readable status-first layout.
- No decorative marketing cards.
- Use OpenClicky accent colors sparingly.
- Avoid showing sensitive prompt text by default.

## Deep Links

Widgets should open OpenClicky to the relevant window:

- `openclicky://agents`
- `openclicky://agent/<session-id>`
- `openclicky://settings`
- `openclicky://logs`
- `openclicky://memory`

Add URL handling in `leanring_buddyApp.swift` or app delegate equivalent and route through `CompanionManager`.

## Privacy

Default to conservative content:

- Show task title/status, not full prompts or raw responses.
- Hide screenshots, raw logs, API errors with credentials, and memory bodies.
- Require explicit settings toggles before showing memory snippets or focused-app context.
- Respect Advanced Mode: advanced widgets can exist, but sensitive agent/log detail should only appear when enabled.

## Agent Integration

Agents should be able to use flagged widget/log issues:

- Keep `agent-review-comments.md` as the source of truth for human comments on logs.
- Add widget snapshot files to Agent Mode task briefs when the user asks about widget/task/status behavior.
- When a user says “fix the widget issues” or “review flagged widget comments,” the agent should read:
  - `agent-review-comments.md`
  - `widget-snapshot.json`
  - recent `messages-*.jsonl`

## Implementation Phases

Phase 1: Shared Snapshot Foundation

- Add App Group entitlement/configuration.
- Add shared Codable widget snapshot models.
- Add `OpenClickyWidgetStateStore`.
- Write snapshot from current app state.
- Add unit tests for snapshot generation and privacy filtering.

Phase 2: Active Agents Widget

- Add WidgetKit extension target.
- Render active agent summaries in small/medium/large families.
- Wire timeline reloads to agent status changes.
- Add deep links to Agent Mode/dashboard.

Phase 3: Stats And Attention Widgets

- Add Today Stats widget from message-log and agent-completion counters.
- Add Needs Attention widget from failed agents, missing permissions, and flagged log comments.
- Add deep links to settings/log viewer.

Phase 4: Settings And Privacy Controls

- Add widget settings in the proper macOS Settings window.
- Add toggles for sensitive fields.
- Add “Open log review comments” and “Open widget snapshot” actions for debugging.

Phase 5: Polish And Verification

- Verify layouts across widget sizes.
- Verify stale snapshot behavior when OpenClicky is not running.
- Verify app launch/deep-link routing.
- Verify no secrets or raw screenshots appear in widget data.

## Open Questions

- App Group identifier: likely `group.com.jkneen.openclicky`, but confirm against signing/provisioning before implementation.
- Whether widgets should be available only when Advanced Mode is enabled, or whether basic Active Agents/Needs Attention widgets should be available for normal users.
- How much agent prompt/result text is acceptable on the desktop by default.
- Whether Today Stats should reset by local day or rolling twenty-four-hour window.

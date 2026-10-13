# REDESIGN-AUDIT — leadqualify-ai (2026-10-13)

Embeddable AI lead-qualifier chat widget + owner lead inbox (Node, zero deps).
Identity on arrival: "night-shift dispatch" — ink sidebar, ember accent, heat tiers.
Already strong from prior sweeps; this pass closes the competitor gap that matters.

## Competitors referenced
- **Pipedrive** — kanban pipeline board (stages as columns, deal cards), deal-rotting
  indicators when idle too long, kanban/list/forecast view toggle.
- **HubSpot** — lifecycle stages (Lead → MQL → SQL → Opportunity → Customer),
  scored prioritization, activity timeline.
- **Intercom / Drift** — polished embeddable chat widget (bubble → panel, quick
  replies, typing indicator, online/offline state).

## Gaps found (visual / functional / flow)

### Functional
1. **No pipeline board.** Pipedrive's signature is the visual pipeline. The inbox is
   list-only; there is no concept of moving a lead through stages (New → Contacted
   → Quoted → Won/Lost). Leads are "new" or "contacted" forever.
2. **No rotting/stall detection.** Pipedrive flags deals idle too long; nothing here
   surfaces a lead sitting untouched in a stage for days.
3. CSV export omits any stage/funnel position (only `status` new/contacted).

### Visual
4. Inbox list view is already on-identity ("night-shift dispatch") — keep and refine,
   don't re-theme. Board view must match the same identity.
5. Demo site and widget are already polished and on-identity; no redesign needed there.

### Flow
6. Owner flow dead-ends at "Mark as contacted" — no path to quoted/won/lost, so
   there's no funnel to report on. Adding stages unlocks a real sales funnel.

## Redesign plan
- **Pipeline board view** in the inbox (List | Board toggle, Pipedrive-style):
  columns New → Contacted → Quoted → Won / Lost, per-column counts, stage
  advance/back buttons on cards, tier heat stripe + score preserved.
- **Rotting indicator**: lead idle > 7 days in a non-terminal stage gets a
  "stalling" badge (Pipedrive's deal-rotting equivalent).
- **Server**: `stage` field on leads (migration from legacy `status` on read),
  `POST /api/lead/:id/stage` with stage validation, `stageTs` timestamps per stage,
  stage column in CSV export.
- Keep: all existing features (filters, search, notes, import/export, follow-up
  queue, stats), same night-shift identity, no rounded edges, no paid services.

## Non-goals
- Drag-and-drop between columns (arrow/buttons are fine, keyboard-accessible).
- Custom user-defined pipelines (Pipedrive power feature; out of scope).
- Widget/demo redesign — already premium.

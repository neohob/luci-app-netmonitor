# monthly-rollup — ADR

**task-brief:** `monthly-rollup`  
**Date:** 2026-11-16

## Context

Detail DB grows ~68万 samples/day (~150MB+/day at current rates). Full multi-month detail makes overview/device queries unusable under LuCI ~20s RPC. Need calendar-month detail + compact history.

## Decision drivers (from prior Q&A; grill deferred — user resting / 「不要问了」)

1. **Why calendar month, not rolling N days?** Aligns with human calendar UI and a clear month-boundary job; rolling N days still leaves large windows as N grows.
2. **Why Top 100 per device, not global Top N?** User confirmed device-centric usage; global would hide per-device destinations. Space: ~232 KiB/device-month at Top100 vs detail GBs.
3. **Why merge remainder into 「其他」?** Option 2 from capacity discussion — preserves month totals without unbounded target cardinality.
4. **Why UI on device detail only?** Conductor choice: overview stays current-month detail; past history is device-scoped; avoids overview RPC explosion.
5. **Why samples-first for rollup?** Samples are the canonical byte counters; sessions are derived. Fallback to sessions if samples missing for that window.
6. **Why keep monthly forever?** Footprint tiny; no user request for monthly TTL in this release.

## Round-1 review amendments (2026-11-16)

| Finding | Decision |
|---------|----------|
| **F1** Blocker | Roll **all** complete months with leftover detail before purge; never delete unrolled months with data |
| **F2** | UCI retention no longer drives detail purge; align estimate / allowed_ranges / settings / W16 |
| **F3** | Restore last_seen-capable device listing (drive-by regression — not intentional) |
| **F4** | UI calendar month from router `now`/`status` |
| **F5** | One editable view source; versioned copies must match (assert in tests) |
| **F6** | Single purge authority for past-month detail (rollup path) |
| **F7** | Rollup fail ≠ skip GC; distinct warning; no purge of unrolled data |
| **F8** | Hot path uses covering index (or drop unused migration) |
| F9, F11, F12 | Fix in same pass (shared sentinel, CSS bust, strict `parse_month`) |
| F10, F13 | `wontfix` this release (api split / schema history noise) |

## Alternatives considered

| Alt | Rejected because |
|-----|------------------|
| Rolling 7/30 day detail only | Still large; no compact history |
| Top 20 / Top 50 | User chose Top 100 for coverage |
| Global Top N across all devices | Wrong product semantics |
| Keep all targets monthly | Cardinality risk; user chose merge-other |
| Hourly rollup for overview | Separate future work |

## Consequences

- Lose timed session drill-down for past months (accepted).
- First day of month: one-time heavier DB work (GROUP BY month window + DELETE).
- Settings copy must stop implying long rolling detail retention.
- Devices with >100 targets lose named rows beyond Top100 (bytes preserved in 其他).

## Grill record (locked without further user prompts)

Challenges that would normally be asked were answered in chat:

- Top N space tradeoff → Top 100  
- Global vs per-device → per-device  
- UI location → device detail  
- Semantics of Top = sum then rank → confirmed

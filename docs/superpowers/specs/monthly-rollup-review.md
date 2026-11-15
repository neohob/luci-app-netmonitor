STATUS: ROUND_DONE

# monthly-rollup review — Round 2

**Scope:** uncommitted working tree vs `b600db8` (0.5.4 → 0.6.0 monthly-rollup), post FIX-R1.  
**Method:** `/thermos` — [Thermo nuclear bug review](55eef0c2-36af-4048-b57c-b361b57d1df6) + [Thermo nuclear CQ review](7b28bce0-3f57-4760-a8cd-d0ffd8e53f3d); parent synthesis. Materials: acceptance A1–A8, both diffs, whitebox W1–W23 PASS, ledger, ADR, optional testplan.

## Findings (this round)

| 问题 | 位置 | 理由 | 严重度 |
|------|------|------|--------|
| Settings/overview 仍把空洞 UCI 保留期限说成现行「保留 N」/「按当前保留期限」 | `settings.js:61,93`; `overview.js:113-115` | A7 文案残留；cutoff/estimate/confirm 已日历月（W18）；不回滚错误 purge | Nit |
| Cache-bust 命名不一致：`overview_055` vs `device_06x`，包已 0.6.0 | `menu.d/...json`; W14/W20 | 身份断言已锁 fork（F5 fixed）；命名账本噪音 | Nit |
| `poll` 把 `retention_pass` 的 GC `ok` 绑成 `rok` | `collector.lua` retention_pass / poll | 易误读为 rollup 成功；逻辑正确（F7 已分 `rollup_failed`） | Nit |

## Round-1 closures (verified)

| ID | Status | Evidence |
|----|--------|----------|
| F1 | fixed | `rollup_complete_months` + discover oldest-first; purge only rolled months; **W16** |
| F2 | fixed | cutoff=`month_start`; estimate `calendar_month`; confirm unused; settings help; **W18** |
| F3 | fixed | `devices_from_pairs` last_seen OR samples; **W19** |
| F4 | fixed | `clampDayToRouterMonth` + router today/month; **W21** |
| F5 | fixed | device.js≡device_06x / overview≡overview_055; **W20** (ADR assert-over-generator) |
| F6 | fixed | `retention_sql` no sample/session DELETE; sole `purge_month_detail` |
| F7 | fixed | GC always runs; `rollup_failed` meta/warning; **W17** |
| F8 | fixed | `INDEXED BY idx_samples_ts_device_target`; **W22** |
| F9 | fixed | `api` uses `rollup.OTHER_TARGET` |
| F10 | wontfix | ADR: api split / pair_cache deferred (~850 LOC) |
| F11 | fixed | `common.js` `?v=0.6.0` |
| F12 | fixed | strict `parse_month`; **W23** |
| F13 | wontfix | ADR: schema v4+v5 jump noise |

## Synthesis

- Both thermos paths: **REVIEW_PASS**; parent agrees. No new Blocker/Should-Fix.
- Whitebox W1–W23 (incl. W16–W23 FIX-R1 coverage) supports A1–A8; F1 multi-month loss closed.
- Overlapping residual: hollow UCI **copy** (F14). CQ-only: naming skew (F15), return-binding clarity (F16). Weight as open Nits only.
- F10/F13 remain `wontfix` per ADR — not blockers.

## Open after Round 2

| ID | Sev | Status | Note |
|----|-----|--------|------|
| F14 | Nit | open | Align overview/settings retention phrasing with calendar-month |
| F15 | Nit | open | Optional rename `overview_055` → `overview_06x` (or generate) |
| F16 | Nit | open | Optional rename retention_pass/poll locals for clarity |
| F10, F13 | Nit | wontfix | ADR |

ROUND: 2
BLOCKERS_OPEN: 0
SHOULD_FIX_OPEN: 0
REVIEW_PASS: F1–F9/F11/F12 fixed with W16–W23; F10/F13 wontfix; only Nit F14–F16 open

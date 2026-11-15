# monthly-rollup review ledger

Cumulative review findings across rounds. Current round detail: `monthly-rollup-review.md`.

## Rounds

| Round | Date | Verdict | Blockers | Should-Fix | Nits | Notes |
|-------|------|---------|----------|------------|------|-------|
| 1 | 2026-11-16 | REVIEW_FAIL | 1 | 7 | 5 | `/thermos`; W1–W15 claimed PASS; F1 Blocker M-2+ loss |
| 2 | 2026-11-16 | REVIEW_PASS | 0 | 0 | 3 open (+2 wontfix) | `/thermos` post FIX-R1; W1–W23 PASS; F1–F9/F11/F12 fixed; F10/F13 wontfix |

## Findings (cumulative)

| ID | Round | Status | Sev | Summary | Evidence / notes |
|----|-------|--------|-----|---------|------------------|
| F1 | 1 | **fixed** (R2) | Blocker | Only previous month rolled; older detail purged without `monthly_traffic` | R2: `rollup.discover_complete_months_with_detail` + `rollup_complete_months`; `collector.retention_pass`; **W16** |
| F2 | 1 | **fixed** (R2) | Should-Fix | `retention_cutoff` ignores UCI; estimate / confirm / allowed_ranges / settings copy lie | R2: cutoff=`month_start`; estimate `calendar_month`; confirm unused; settings help; **W18**. Residual banner phrasing → F14 |
| F3 | 1 | **fixed** (R2) | Should-Fix | `devices`/`overview` omit last_seen-only devices (drive-by) | R2: `devices_from_pairs` last_seen OR samples; **W19** |
| F4 | 1 | **fixed** (R2) | Should-Fix | Device calendar clamp uses browser TZ; API uses router TZ | R2: `clampDayToRouterMonth` + status today/month; **W21** |
| F5 | 1 | **fixed** (R2) | Should-Fix | LuCI view cache-bust forks (`device.js`≡`device_06x.js`, `overview_055`) | R2: identity assert **W20**; ADR accept assert-over-generator. Naming skew → F15 |
| F6 | 1 | **fixed** (R2) | Should-Fix | Dual purge paths (rollup window DELETE + `retention_sql`) drift risk | R2: `retention_sql` no sample/session DELETE; sole `purge_month_detail` |
| F7 | 1 | **fixed** (R2) | Should-Fix | Rollup failure short-circuits entire retention GC | R2: GC always runs; `rollup_failed` meta/warning; **W17** |
| F8 | 1 | **fixed** (R2) | Should-Fix | `pair_rows` `INDEXED BY idx_samples_ts`; new covering index unused | R2: `INDEXED BY idx_samples_ts_device_target`; **W22** |
| F9 | 1 | **fixed** (R2) | Nit | `__other__` sentinel duplicated across rollup/API | R2: `api` uses `rollup.OTHER_TARGET` |
| F10 | 1 | **wontfix** (R2) | Nit | `api.lua` growth + process-global `pair_cache` | ADR: api split deferred; ~850 LOC + pair_cache remain |
| F11 | 1 | **fixed** (R2) | Nit | CSS `?v=0.5.5-ovfast` while PKG 0.6.0 | R2: `common.js` `?v=0.6.0` |
| F12 | 1 | **fixed** (R2) | Nit | `parse_month` accepts `2026-13` / `2026-00` via os.time normalize | R2: strict reject; **W23** |
| F13 | 1 | **wontfix** (R2) | Nit | Schema jump bundles unrelated v4 index with v5 monthly | ADR: schema history noise |
| F14 | 2 | **open** | Nit | UI still surfaces hollow UCI retention as live (“保留 N unit” / 「按当前保留期限」) while purge/estimate are calendar-month | `overview.js:113-115`; `settings.js:61,93` vs help `settings.js:208` + `api.estimate` (**W18**) |
| F15 | 2 | **open** | Nit | Cache-bust naming skew: menu `overview_055` under PKG 0.6.0 while device is `device_06x` | `menu.d/...json`; W14/W20 hard-code names |
| F16 | 2 | **open** | Nit | `poll` binds `retention_pass` first return (GC `ok`) as `rok` — easy to misread vs rollup success | `collector.lua` retention_pass + poll |

## Acceptance snapshot (Round 2)

| AC | White-box | Review risk |
|----|-----------|-------------|
| A1 | W3–W4, W12 PASS | OK |
| A2 | W4–W5, W8 PASS | OK |
| A3 | W6, W9 PASS | OK (F1 closed) |
| A3b | W16, W17 PASS | OK |
| A4 | W10, W21 PASS | OK |
| A5 | W11–W14 PASS | OK |
| A6 | W7 PASS | OK |
| A7 | W14–W15, W18 PASS | OK logic; F14 copy nit |
| A8 | W19 PASS | OK |

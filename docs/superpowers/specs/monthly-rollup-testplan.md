# monthly-rollup — Test plan

Maps to acceptance **A1–A7** in `monthly-rollup-design.md`.  
**W*** = white-box (code pane implements + self-proves; test pane re-runs).  
**B*** = black-box / on-device (test pane only).

## White-box

| ID | Covers | Phase | Pre | Steps | Expect | Judge |
|----|--------|-------|-----|-------|--------|-------|
| W1 | A3,A4 | 1 | fixed `now` mid-month | `month_key` / `month_start` / `next_month_start` | key=`YYYY-MM`; start=local 1st 00:00; next=1st next month | unit |
| W2 | A3 | 1 | `now` = last day of month 23:59 | bounds | still same month_key; next_month crosses | unit |
| W3 | A1 | 2 | empty DB + v4 DB fixture | `schema.apply` | VERSION=5; `monthly_traffic` exists; v4 indexes kept | unit |
| W4 | A1,A2 | 3 | device D with 105 targets in prior month samples | `rollup_previous_month` | ≤101 rows for D; top 100 named; `__other__` = sum of 5 leftovers up/down | unit |
| W5 | A2 | 3 | ties / equal totals | rollup | deterministic order (document tie-break: target key ASC after total DESC) | unit |
| W6 | A3 | 3 | prior-month samples+sessions seeded | after rollup | zero samples/sessions with ts in prior month; current month untouched | unit |
| W7 | A6 | 3 | already rolled month present | run rollup again | row count unchanged; no duplicate PK; detail still empty | unit |
| W8 | A2 | 3 | samples empty, sessions only for prior month | rollup | uses sessions sums; still Top100+其他 | unit |
| W9 | A3 | 3 | current month samples only | retention/rollup | no purge of current; no false monthly insert for current | unit |
| W16 | A3b | 3 | detail for M-2 and M-1 still in DB; never rolled | one `retention_pass` | both months in `monthly_traffic`; no samples/sessions left in either; current intact | unit |
| W17 | A3b,F7 | 3 | inject rollup insert failure (or mock) mid multi-month | retention_pass | unrolled months’ detail still present; distinct rollup error/warning | unit |
| W18 | A7,F2 | 4 | cfg retention_unit=day value=7 early in month | `allowed_ranges` / estimate / confirm | no false “range exceeds UCI days”; copy/estimate match calendar month | unit |
| W19 | A8,F3 | 4 | device with last_seen in range, zero samples | `devices`/`overview` | device still listed | unit |
| W10 | A4 | 4 | days spanning prev+current in DB | `device_detail` days list | only current-month days; `day=prev` → error or empty | unit |
| W11 | A5 | 4 | monthly rows for 2 months | `device_months` | both keys sorted desc | unit |
| W12 | A1,A5 | 4 | Top100+其他 seeded | `device_month_summary` | totals match; 其他 present; sorted by total desc | unit |
| W13 | A5 | 4 | ACL JSON | parse methods | `device_months`, `device_month_summary` in read ACL | static |
| W14 | A5,A7 | 5 | menu + device view files | grep/menu | cache-bust path; 「往月」 or month-summary UI present; settings copy mentions current-month detail | file assert |
| W15 | A7 | 5 | Makefiles | read PKG_VERSION | both packages `0.6.0` | file assert |
| W20 | F5 | 5 | device.js vs device_06x.js (and overview vs overview_055 if both shipped) | byte or semantic identity assert | no divergent forks | file assert |
| W21 | F4 | 5 | status/router now ≠ browser month edge (fixture) | UI clamp helper uses injected router now | calendar month follows router | unit/js or lua helper |
| W22 | F8 | 4 | pair_rows SQL | grep INDEXED BY | uses covering index or documented drop of unused index | static |
| W23 | F12 | 1 | `parse_month('2026-13')` / `2026-00` | call | `nil` + bad_month (no normalize) | unit |

**Mutation / fake-green (code pane must run once):**

- Mutate Top N to 50 in `/tmp` copy → W4 must FAIL.
- Mutate `month_start` off-by-one day → W6 or W10 must FAIL.
- Run harness with `-e` / filter `_NOPE` equivalent → no silent pass on missing test name.

## Black-box

| ID | Covers | Phase | Pre | Steps | Expect | Judge |
|----|--------|-------|-----|-------|--------|-------|
| B1 | A4 | 6 | router with multi-day detail in current month | open device detail | calendar only shows current-month days | device |
| B2 | A1–A3,A6 | 6 | seed or wait across month boundary (or inject `now` via test hook if exposed); trigger retention | inspect DB | prior month in `monthly_traffic`; detail purged; re-trigger no dup | device/semi |
| B3 | A5 | 6 | at least one rolled month | 「往月汇总」 pick month | table shows Top destinations + 其他; no session expand | device |
| B4 | A7 | 6 | open settings | read retention help | text says detail=current month / past=monthly summary | device |
| B5 | A5 | 6 | ubus as luci user | `call netmonitor device_months` / `device_month_summary` | ACL allows; sensible JSON | device |

## Coverage matrix

| AC | White-box | Black-box |
|----|-----------|-----------|
| A1 | W3, W4, W12 | B2 |
| A2 | W4, W5, W8 | B2 |
| A3 | W1, W6, W9 | B2 |
| A3b | W16, W17 | B2 |
| A4 | W1, W10, W21 | B1 |
| A5 | W11, W12, W13, W14 | B3, B5 |
| A6 | W7 | B2 |
| A7 | W14, W15, W18 | B4 |
| A8 | W19 | B1 |

# monthly-rollup — Glossary

| Term | Meaning |
|------|---------|
| **Current calendar month** | Interval `[month_start(now), next_month_start(now))` in router local TZ |
| **Prior / previous month** | The calendar month immediately before the current one |
| **Detail** | `traffic_samples` + `sessions` rows (timed, per-destination granular) |
| **Monthly rollup** | Job that aggregates prior-month detail into `monthly_traffic` then deletes that detail |
| **Top 100** | Per `device`, the 100 `target` keys with largest `(bytes_up+bytes_down)` after summing the month |
| **其他 / `__other__`** | Synthetic target holding sum of all non–Top-100 targets for that device+month |
| **month key** | String `YYYY-MM` identifying a calendar month |
| **device_months** | ubus method listing months that have `monthly_traffic` for a MAC |
| **device_month_summary** | ubus method returning Top100+其他 rows for one MAC+month |
| **往月汇总** | Device-detail UI for browsing past months via the two methods above |

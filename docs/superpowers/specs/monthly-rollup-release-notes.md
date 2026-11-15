STATUS: READY

# monthly-rollup 0.6.0 release notes (ORDER-NM-ROLLUP-RELEASE)

## Build
- Command: `./scripts/build_release.sh` → rc=0
- Artifacts:
  - `dist/netmonitor_0.6.0-1_all.ipk`
  - `dist/luci-app-netmonitor_0.6.0-1_all.ipk`
  - `dist/luci-app-netmonitor_0.6.0-1_all.run`
  - `dist/SHA256SUMS` (includes 0.6.0 hashes)

## GitHub release
- Created: https://github.com/neohob/luci-app-netmonitor/releases/tag/v0.6.0
- Uploaded: netmonitor + luci-app ipk, .run, SHA256SUMS

## Deploy / device smoke
**未做** — SSH probe failed (BatchMode publickey).

Keys tried → `root@192.168.100.1`:
- `~/.ssh/id_rsa` → `Permission denied (publickey,password).`
- `~/.ssh/tencent_cloud_private_key_neo` → `Permission denied (publickey,password).`
- No `id_ed25519` present under `~/.ssh/`.

No invent of B1–B5 PASS. Deploy via `deploy-goop.sh` not run.

## Tree check
- `netmonitor/Makefile` + `luci-app-netmonitor/Makefile` PKG_VERSION=0.6.0
- README already documents 0.6.0
- No design/ADR/plan/testplan edits; no git commit

---
✅ PIPELINE_DONE: 0.6.0 ipk/run built + gh release uploaded; device smoke 未做 (SSH denied)

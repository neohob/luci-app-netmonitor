#!/usr/bin/env bash
# Build universal OpenWrt .ipk (PKGARCH=all) + iStore-style .run installer.
#
# Usage:
#   ./scripts/build_release.sh [outdir]
#
# Outputs (default dist/):
#   netmonitor_<ver>_all.ipk
#   luci-app-netmonitor_<ver>_all.ipk
#   luci-app-netmonitor_<ver>_all.run
#   SHA256SUMS
#
# OpenWrt .ipk is a gzip-compressed tar (NOT ar). Member order:
#   ./debian-binary ./data.tar.gz ./control.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-"$ROOT/dist"}"
mkdir -p "$OUT"

NM_VER=$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/netmonitor/Makefile" | head -1)
NM_REL=$(sed -n 's/^PKG_RELEASE:=//p' "$ROOT/netmonitor/Makefile" | head -1)
LUCI_VER=$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/luci-app-netmonitor/Makefile" | head -1)
LUCI_REL=$(sed -n 's/^PKG_RELEASE:=//p' "$ROOT/luci-app-netmonitor/Makefile" | head -1)
[ -n "$NM_VER" ] && [ -n "$NM_REL" ] && [ -n "$LUCI_VER" ] && [ -n "$LUCI_REL" ] \
  || { echo "cannot read PKG_VERSION/PKG_RELEASE from Makefiles" >&2; exit 1; }

NM_FULL="${NM_VER}-${NM_REL}"
LUCI_FULL="${LUCI_VER}-${LUCI_REL}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM

tgz() {
  # Portable: prefer gtar, fall back to tar with BSD-friendly flags
  local dir="$1" out="$2"
  ( cd "$dir" && COPYFILE_DISABLE=1 tar --format=ustar --exclude='._*' --exclude='.DS_Store' -czf "$out" . )
}

make_ipk() {
  local name="$1" ver="$2" control_file="$3" data_dir="$4" out_ipk="$5"
  local s="$STAGE/ipk-$name"
  rm -rf "$s"
  mkdir -p "$s/control" "$s/data"
  cp -a "$data_dir/." "$s/data/"
  echo "2.0" > "$s/debian-binary"
  cp "$control_file" "$s/control/control"
  # Optional scripts
  if [ -f "$STAGE/extra-control/$name/postinst" ]; then
    cp "$STAGE/extra-control/$name/postinst" "$s/control/postinst"
    chmod 755 "$s/control/postinst"
  fi
  if [ -f "$STAGE/extra-control/$name/prerm" ]; then
    cp "$STAGE/extra-control/$name/prerm" "$s/control/prerm"
    chmod 755 "$s/control/prerm"
  fi
  if [ -f "$STAGE/extra-control/$name/conffiles" ]; then
    cp "$STAGE/extra-control/$name/conffiles" "$s/control/conffiles"
  fi
  tgz "$s/data" "$s/data.tar.gz"
  ( cd "$s/control" && COPYFILE_DISABLE=1 tar --format=ustar --exclude='._*' -czf "$s/control.tar.gz" . )
  ( cd "$s" && COPYFILE_DISABLE=1 tar --format=ustar -czf "$out_ipk" ./debian-binary ./data.tar.gz ./control.tar.gz )
  echo "built $out_ipk"
}

# ---- netmonitor data tree ----
NM_DATA="$STAGE/nm-data"
mkdir -p "$NM_DATA"/{etc/config,etc/init.d,etc/uci-defaults,usr/sbin,usr/libexec/rpcd,usr/lib/lua/netmonitor}
cp "$ROOT/netmonitor/files/netmonitor.config" "$NM_DATA/etc/config/netmonitor"
cp "$ROOT/netmonitor/files/netmonitor.init" "$NM_DATA/etc/init.d/netmonitor"
cp "$ROOT/netmonitor/files/netmonitor.uci-defaults" "$NM_DATA/etc/uci-defaults/90-netmonitor"
cp "$ROOT/netmonitor/files/netmonitor-collector" "$NM_DATA/usr/sbin/netmonitor-collector"
cp "$ROOT/netmonitor/files/netmonitor-dns-sniff" "$NM_DATA/usr/sbin/netmonitor-dns-sniff"
cp "$ROOT/netmonitor/files/netmonitor-asn-update" "$NM_DATA/usr/sbin/netmonitor-asn-update"
cp "$ROOT/netmonitor/files/rpcd-netmonitor" "$NM_DATA/usr/libexec/rpcd/netmonitor"
cp "$ROOT/netmonitor/files/lib/netmonitor/"*.lua "$NM_DATA/usr/lib/lua/netmonitor/"
chmod 755 "$NM_DATA/etc/init.d/netmonitor" \
  "$NM_DATA/etc/uci-defaults/90-netmonitor" \
  "$NM_DATA/usr/sbin/netmonitor-collector" \
  "$NM_DATA/usr/sbin/netmonitor-dns-sniff" \
  "$NM_DATA/usr/sbin/netmonitor-asn-update" \
  "$NM_DATA/usr/libexec/rpcd/netmonitor"

mkdir -p "$STAGE/extra-control/netmonitor"
cat > "$STAGE/extra-control/netmonitor/control" <<EOF
Package: netmonitor
Version: $NM_FULL
Depends: lua, sqlite3-cli, ip-tiny
Section: net
Architecture: all
Installed-Size: $(du -sk "$NM_DATA" | awk '{print $1 * 1024}')
Description: Per-device traffic collector (conntrack + DNS + SQLite)
EOF
echo "/etc/config/netmonitor" > "$STAGE/extra-control/netmonitor/conffiles"
cat > "$STAGE/extra-control/netmonitor/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -f /etc/uci-defaults/90-netmonitor ] && ( . /etc/uci-defaults/90-netmonitor ) && rm -f /etc/uci-defaults/90-netmonitor
/etc/init.d/netmonitor enable 2>/dev/null || true
/etc/init.d/netmonitor restart 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
exit 0
EOF
cat > "$STAGE/extra-control/netmonitor/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/netmonitor stop 2>/dev/null || true
/etc/init.d/netmonitor disable 2>/dev/null || true
exit 0
EOF

NM_IPK="$OUT/netmonitor_${NM_FULL}_all.ipk"
make_ipk netmonitor "$NM_FULL" "$STAGE/extra-control/netmonitor/control" "$NM_DATA" "$NM_IPK"

# ---- luci-app-netmonitor data tree ----
LUCI_DATA="$STAGE/luci-data"
mkdir -p "$LUCI_DATA/usr/share/luci/menu.d" "$LUCI_DATA/usr/share/rpcd/acl.d"
mkdir -p "$LUCI_DATA/www/luci-static/resources/view/netmonitor"
mkdir -p "$LUCI_DATA/www/luci-static/resources/netmonitor"
cp "$ROOT/luci-app-netmonitor/root/usr/share/luci/menu.d/luci-app-netmonitor.json" "$LUCI_DATA/usr/share/luci/menu.d/"
cp "$ROOT/luci-app-netmonitor/root/usr/share/rpcd/acl.d/luci-app-netmonitor.json" "$LUCI_DATA/usr/share/rpcd/acl.d/"
cp "$ROOT/luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/"*.js "$LUCI_DATA/www/luci-static/resources/view/netmonitor/"
cp "$ROOT/luci-app-netmonitor/htdocs/luci-static/resources/netmonitor/"* "$LUCI_DATA/www/luci-static/resources/netmonitor/" 2>/dev/null || true

mkdir -p "$STAGE/extra-control/luci-app-netmonitor"
cat > "$STAGE/extra-control/luci-app-netmonitor/control" <<EOF
Package: luci-app-netmonitor
Version: $LUCI_FULL
Depends: luci-base, netmonitor
Section: luci
Architecture: all
Installed-Size: $(du -sk "$LUCI_DATA" | awk '{print $1 * 1024}')
Description: LuCI traffic monitor — device topology, daily sessions
EOF
cat > "$STAGE/extra-control/luci-app-netmonitor/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
exit 0
EOF

LUCI_IPK="$OUT/luci-app-netmonitor_${LUCI_FULL}_all.ipk"
make_ipk luci-app-netmonitor "$LUCI_FULL" "$STAGE/extra-control/luci-app-netmonitor/control" "$LUCI_DATA" "$LUCI_IPK"

# ---- .run self-extractor (iStore / shell install) ----
# Payload layout:
#   data/          combined filesystem tree (both packages)
#   files.list
# Header supports: install | uninstall
R="$STAGE/run"
mkdir -p "$R/data"
cp -a "$NM_DATA/." "$R/data/"
cp -a "$LUCI_DATA/." "$R/data/"
# Also ship ipks inside for opkg-based installs (optional)
mkdir -p "$R/data/tmp/netmonitor-ipks"
cp -a "$NM_IPK" "$LUCI_IPK" "$R/data/tmp/netmonitor-ipks/" 2>/dev/null || {
  mkdir -p "$R/ipks"
  cp -a "$NM_IPK" "$LUCI_IPK" "$R/ipks/"
}
( cd "$R/data" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$R/files.list"

APP=luci-app-netmonitor
FULL="$LUCI_FULL"
cat > "$R/head" <<HDR
#!/bin/sh
# $APP $FULL
# luci-app-netmonitor 自解压安装器（universal / 与 CPU 架构无关）。
#
#   sh <文件名>.run              安装或升级
#   sh <文件名>.run uninstall    卸载（保留 /etc/config/netmonitor 与数据库）
#
# 装完在 LuCI：「管控 -> 流量监控」
set -eu

APP=$APP
INIT=netmonitor
VER=$FULL
NM_DESTDIR="\${NM_DESTDIR:-}"

if [ -z "\$NM_DESTDIR" ] && [ "\$(id -u)" != "0" ]; then
  echo "请用 root 运行（或设置 NM_DESTDIR=... 做沙箱安装）" >&2
  exit 1
fi

TMP=\$(mktemp -d /tmp/\$APP.XXXXXX) || exit 1
trap 'rm -rf "\$TMP"' EXIT INT TERM

LINE=\$(awk '/^__PAYLOAD_BELOW__\$/ {print NR + 1; exit}' "\$0")
[ -n "\$LINE" ] || { echo "找不到内嵌数据" >&2; exit 1; }
mkdir -p "\$TMP/x"
tail -n +"\$LINE" "\$0" | tar -xzf - -C "\$TMP/x"

FILES="\$TMP/x/files.list"
[ -f "\$FILES" ] || { echo "内嵌数据不完整" >&2; exit 1; }

clear_cache() {
  rm -f /tmp/luci-indexcache* 2>/dev/null || true
  rm -rf /tmp/luci-modulecache 2>/dev/null || true
}

install_pkg() {
  echo "==> 安装 \$APP \$VER"
  while read -r p; do
    [ -n "\$p" ] || continue
    case "\$p" in
      tmp/*) continue ;;
    esac
    dest="\$NM_DESTDIR/\$p"
    case "\$p" in
      etc/config/netmonitor)
        if [ -e "\$dest" ]; then
          cp -f "\$TMP/x/data/\$p" "\$dest.nm-new"
          echo "  保留已有 \$p，新版本存为 \$p.nm-new"
          continue
        fi
        ;;
    esac
    mkdir -p "\$(dirname "\$dest")"
    cp -f "\$TMP/x/data/\$p" "\$dest"
  done < "\$FILES"
  chmod 755 "\$NM_DESTDIR/etc/init.d/\$INIT" 2>/dev/null || true
  chmod 755 "\$NM_DESTDIR/usr/sbin/netmonitor-collector" 2>/dev/null || true
  chmod 755 "\$NM_DESTDIR/usr/libexec/rpcd/netmonitor" 2>/dev/null || true

  if [ -n "\$NM_DESTDIR" ]; then
    echo "==> done (sandbox NM_DESTDIR=\$NM_DESTDIR, skipped service restart)"
    return 0
  fi

  if [ -f /etc/uci-defaults/90-netmonitor ]; then
    ( cd / && sh /etc/uci-defaults/90-netmonitor ) || true
    rm -f /etc/uci-defaults/90-netmonitor
  fi
  clear_cache
  /etc/init.d/\$INIT enable 2>/dev/null || true
  /etc/init.d/\$INIT restart 2>/dev/null || true
  /etc/init.d/rpcd restart 2>/dev/null || true
  /etc/init.d/uhttpd restart 2>/dev/null || true
  echo "==> 完成。LuCI：管控 -> 流量监控"
}

uninstall_pkg() {
  echo "==> 卸载 \$APP"
  if [ -z "\$NM_DESTDIR" ] && [ -x /etc/init.d/\$INIT ]; then
    /etc/init.d/\$INIT stop 2>/dev/null || true
    /etc/init.d/\$INIT disable 2>/dev/null || true
  fi
  while read -r p; do
    [ -n "\$p" ] || continue
    case "\$p" in
      etc/config/*|tmp/*) continue ;;
    esac
    rm -f "\$NM_DESTDIR/\$p"
  done < "\$FILES"
  sort -r "\$FILES" | while read -r p; do
    [ -n "\$p" ] || continue
    rmdir "\$NM_DESTDIR/\$(dirname "\$p")" 2>/dev/null || true
  done
  if [ -z "\$NM_DESTDIR" ]; then
    clear_cache
    /etc/init.d/rpcd restart 2>/dev/null || true
  fi
  echo "==> 已卸载（配置与数据库保留）"
}

case "\${1:-install}" in
  install|"")       install_pkg ;;
  uninstall|remove) uninstall_pkg ;;
  *) echo "用法: sh \$0 [install|uninstall]" >&2; exit 1 ;;
esac
exit 0
__PAYLOAD_BELOW__
HDR

# payload = files.list + data/
mkdir -p "$R/payload-root"
cp "$R/files.list" "$R/payload-root/files.list"
cp -a "$R/data" "$R/payload-root/data"
tgz "$R/payload-root" "$STAGE/payload.tar.gz"

RUN="$OUT/${APP}_${FULL}_all.run"
cat "$R/head" "$STAGE/payload.tar.gz" > "$RUN"
chmod 755 "$RUN"
echo "built $RUN"

( cd "$OUT" && shasum -a 256 \
  "netmonitor_${NM_FULL}_all.ipk" \
  "luci-app-netmonitor_${LUCI_FULL}_all.ipk" \
  "luci-app-netmonitor_${LUCI_FULL}_all.run" > SHA256SUMS )
echo "==> artifacts in $OUT"
ls -la "$OUT"

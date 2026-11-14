#!/usr/bin/env bash
# Deploy netmonitor + luci-app-netmonitor to an OpenWrt router over SSH.
#
# Usage:
#   export GOOP_KEY=~/.ssh/id_ed25519          # SSH private key
#   export GOOP_HOST=root@192.168.1.1          # router SSH target
#   ./scripts/deploy-goop.sh
#
# Or use the prebuilt .run / .ipk from GitHub Releases instead.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${GOOP_KEY:?set GOOP_KEY to your SSH private key path}"
HOST="${GOOP_HOST:?set GOOP_HOST like root@192.168.1.1}"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$HOST")
SCP=(scp -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

echo "==> deps (sqlite3-cli)"
"${SSH[@]}" 'opkg update >/tmp/nm-opkg-update.log 2>&1 || true
opkg list-installed | grep -q "^sqlite3-cli " || opkg install sqlite3-cli
which sqlite3
lua -v'

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/netmonitor"/{etc/config,etc/init.d,etc/uci-defaults,usr/sbin,usr/libexec/rpcd,usr/lib/lua/netmonitor}
cp "$ROOT/netmonitor/files/netmonitor.config" "$STAGE/netmonitor/etc/config/netmonitor"
cp "$ROOT/netmonitor/files/netmonitor.init" "$STAGE/netmonitor/etc/init.d/netmonitor"
cp "$ROOT/netmonitor/files/netmonitor.uci-defaults" "$STAGE/netmonitor/etc/uci-defaults/90-netmonitor"
cp "$ROOT/netmonitor/files/netmonitor-collector" "$STAGE/netmonitor/usr/sbin/netmonitor-collector"
cp "$ROOT/netmonitor/files/rpcd-netmonitor" "$STAGE/netmonitor/usr/libexec/rpcd/netmonitor"
cp "$ROOT/netmonitor/files/lib/netmonitor/"*.lua "$STAGE/netmonitor/usr/lib/lua/netmonitor/"
chmod 755 "$STAGE/netmonitor/etc/init.d/netmonitor" \
  "$STAGE/netmonitor/etc/uci-defaults/90-netmonitor" \
  "$STAGE/netmonitor/usr/sbin/netmonitor-collector" \
  "$STAGE/netmonitor/usr/libexec/rpcd/netmonitor"

mkdir -p "$STAGE/luci"/{usr/share/luci/menu.d,usr/share/rpcd/acl.d}
mkdir -p "$STAGE/luci/www/luci-static/resources/view/netmonitor"
mkdir -p "$STAGE/luci/www/luci-static/resources/netmonitor"
cp "$ROOT/luci-app-netmonitor/root/usr/share/luci/menu.d/luci-app-netmonitor.json" "$STAGE/luci/usr/share/luci/menu.d/"
cp "$ROOT/luci-app-netmonitor/root/usr/share/rpcd/acl.d/luci-app-netmonitor.json" "$STAGE/luci/usr/share/rpcd/acl.d/"
cp "$ROOT/luci-app-netmonitor/htdocs/luci-static/resources/view/netmonitor/"*.js "$STAGE/luci/www/luci-static/resources/view/netmonitor/"
cp "$ROOT/luci-app-netmonitor/htdocs/luci-static/resources/netmonitor/"* "$STAGE/luci/www/luci-static/resources/netmonitor/"

echo "==> upload"
"${SSH[@]}" 'mkdir -p /tmp/nm-deploy'
"${SCP[@]}" -r "$STAGE/netmonitor" "$STAGE/luci" "$HOST:/tmp/nm-deploy/"

echo "==> install on router"
"${SSH[@]}" 'set -e
cd /tmp/nm-deploy
[ -f /etc/config/netmonitor ] || cp -a netmonitor/etc/config/netmonitor /etc/config/netmonitor
cp -a netmonitor/etc/init.d/netmonitor /etc/init.d/netmonitor
cp -a netmonitor/etc/uci-defaults/90-netmonitor /etc/uci-defaults/90-netmonitor
cp -a netmonitor/usr/sbin/netmonitor-collector /usr/sbin/netmonitor-collector
mkdir -p /usr/libexec/rpcd /usr/lib/lua/netmonitor
cp -a netmonitor/usr/libexec/rpcd/netmonitor /usr/libexec/rpcd/netmonitor
cp -a netmonitor/usr/lib/lua/netmonitor/*.lua /usr/lib/lua/netmonitor/
cp -a luci/usr/share/luci/menu.d/luci-app-netmonitor.json /usr/share/luci/menu.d/
cp -a luci/usr/share/rpcd/acl.d/luci-app-netmonitor.json /usr/share/rpcd/acl.d/
mkdir -p /www/luci-static/resources/view/netmonitor /www/luci-static/resources/netmonitor
cp -a luci/www/luci-static/resources/view/netmonitor/* /www/luci-static/resources/view/netmonitor/
cp -a luci/www/luci-static/resources/netmonitor/* /www/luci-static/resources/netmonitor/
chmod 755 /etc/init.d/netmonitor /usr/sbin/netmonitor-collector /usr/libexec/rpcd/netmonitor /etc/uci-defaults/90-netmonitor
if [ ! -f /etc/netmonitor.uci-defaults.done ]; then
  sh /etc/uci-defaults/90-netmonitor && touch /etc/netmonitor.uci-defaults.done || true
fi
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart 2>/dev/null || true
rm -rf /tmp/luci-* 2>/dev/null || true
ubus -v list netmonitor | head -20
'

echo "==> done"

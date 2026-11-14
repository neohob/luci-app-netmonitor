include $(TOPDIR)/rules.mk

PKG_NAME:=netmonitor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/netmonitor
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Per-device traffic collector (conntrack + DNS + SQLite)
  DEPENDS:=+lua +sqlite3-cli +ip-tiny
  PKGARCH:=all
endef

define Package/netmonitor/description
  Samples nf_conntrack byte counters, correlates destinations with dnsmasq
  DNS answers and DHCP leases, and stores device -> destination traffic
  and sessions in SQLite. Exposes the netmonitor ubus object via rpcd.
endef

define Package/netmonitor/conffiles
/etc/config/netmonitor
endef

define Build/Compile
endef

define Package/netmonitor/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_CONF) ./files/netmonitor.config $(1)/etc/config/netmonitor
	$(INSTALL_BIN) ./files/netmonitor.init $(1)/etc/init.d/netmonitor
	$(INSTALL_BIN) ./files/netmonitor.uci-defaults $(1)/etc/uci-defaults/90-netmonitor
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/netmonitor-collector $(1)/usr/sbin/netmonitor-collector
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/rpcd-netmonitor $(1)/usr/libexec/rpcd/netmonitor
	$(INSTALL_DIR) $(1)/usr/lib/lua/netmonitor
	$(INSTALL_DATA) ./files/lib/netmonitor/*.lua $(1)/usr/lib/lua/netmonitor/
endef

$(eval $(call BuildPackage,netmonitor))

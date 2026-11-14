include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI 流量监控 (netmonitor)
LUCI_DESCRIPTION:=设备流量拓扑、设备列表与按天会话明细
LUCI_DEPENDS:=+luci-base +netmonitor
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-netmonitor
PKG_VERSION:=0.4.2
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

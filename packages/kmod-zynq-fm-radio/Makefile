include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=kmod-zynq-fm-radio
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define KernelPackage/zynq-fm-radio
	SUBMENU:=Radio devices
	TITLE:=Zynq PL FM Radio V4L2 Driver
	DEPENDS:=+kmod-video-core
	FILES:=$(PKG_BUILD_DIR)/zynq_fm_radio.ko
	AUTOLOAD:=$(call AutoLoad, 90, zynq_fm_radio)
endef

define KernelPackage/zynq-fm-radio/description
	V4L2 Kernel driver for Zynq-7010 PL SDR FM Receiver.
	Provides standard /dev/radio0 interface and sysfs controls.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		$(KERNEL_MAKE_FLAGS) \
		KDIR="$(LINUX_DIR)" \
		PWD="$(PKG_BUILD_DIR)" \
		all
endef

$(eval $(call KernelPackage,zynq-fm-radio))
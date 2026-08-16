include $(TOPDIR)/rules.mk

PKG_NAME:=fm_radio
PKG_VERSION:=1.0
PKG_RELEASE:=1

# Опционально: указывает, что мы берем исходники прямо из локальной папки src/
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/fm_radio
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Zynq FM SDR Radio Control Utility
  DEPENDS:=
endef

define Package/fm_radio/description
  Утилита командной строки для управления аппаратным FM-радио (Zynq SDR).
  Позволяет устанавливать частоту и запускать автоматический поиск станций (Seek).
  Работает через /dev/mem (интерфейс AXI).
endef

# Шаг подготовки: копируем файлы из папки src/ в рабочую папку сборщика
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

# Шаг сборки: передаем команду make с нужными кросс-компиляторами
define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

# Шаг установки: копируем скомпилированный бинарник в образ прошивки (/usr/bin)
define Package/fm_radio/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/fm_radio $(1)/usr/bin/
endef

# Регистрация пакета в системе сборки
$(eval $(call BuildPackage,fm_radio))
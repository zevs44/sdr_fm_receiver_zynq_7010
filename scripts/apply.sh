#!/usr/bin/env bash
#
# apply.sh — подготовка дерева OpenWrt к сборке образа Antminer S9.
#
# Использование:
#   bash scripts/apply.sh [путь-к-openwrt]
#   по умолчанию — ./openwrt рядом с репозиторием
#
# Что делает:
#   1. накладывает все патчи из target-patches/ по порядку (с проверкой, что ложатся);
#   2. копирует битстрим в дерево сборки (если он есть);
#   3. подключает фид автора как локальный src-link и ставит все фиды;
#   4. ставит наш .config и запускает make defconfig.
#
# Код возврата 0 — дерево готово к `make world`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWRT="${1:-$HERE/openwrt}"
CFG="$HERE/configs/zynq_antminer_s9.config"
VERSION="$(tr -d '[:space:]' < "$HERE/.openwrt-version" 2>/dev/null || echo '')"

# цель и подцель берутся из конфига, чтобы не дублировать их в скрипте
TARGET="$(sed -n 's/^CONFIG_TARGET_\([a-z0-9]*\)=y$/\1/p' "$CFG" | head -1)"
SUBTARGET="$(sed -n 's/^CONFIG_TARGET_[a-z0-9]*_\([a-z0-9]*\)=y$/\1/p' "$CFG" | head -1)"
if [ -z "$TARGET" ] || [ -z "$SUBTARGET" ]; then
  echo "ОШИБКА: не удалось определить цель и подцель из $CFG" >&2
  echo "   Ожидались строки CONFIG_TARGET_<цель>=y и CONFIG_TARGET_<цель>_<подцель>=y." >&2
  exit 1
fi

if [ ! -d "$OWRT" ]; then
  echo "ОШИБКА: каталог OpenWrt не найден: $OWRT" >&2
  echo "Склонируйте его: git clone --depth 1 -b ${VERSION:-<тег>} https://github.com/openwrt/openwrt.git $OWRT" >&2
  exit 1
fi

# Дальше скрипт делает `cd "$OWRT"`; относительный путь вроде ./openwrt после
# этого удвоился бы (./openwrt/openwrt/...). В CI аргумент именно относительный,
# поэтому приводим его к абсолютному один раз здесь.
OWRT="$(cd "$OWRT" && pwd)"

echo "== 1. патчи =="
shopt -s nullglob
patches=("$HERE"/target-patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "   ПРЕДУПРЕЖДЕНИЕ: в target-patches/ нет ни одного патча."
  echo "   Сборка получится без поддержки платы и без узлов PL."
else
  for p in "${patches[@]}"; do
    name="$(basename "$p")"
    if ! (cd "$OWRT" && git apply --check -p1 "$p" 2>/dev/null); then
      echo "   ОШИБКА: патч не ложится на это дерево: $name" >&2
      echo "   Скорее всего изменилась версия OpenWrt (тег в .openwrt-version)." >&2
      echo "   Проверьте вручную: cd $OWRT && git apply --check -p1 $p" >&2
      exit 1
    fi
    (cd "$OWRT" && git apply -p1 "$p")
    echo "   ok  $name"
  done
fi

echo "== 2. файлы для FAT-раздела =="
mkdir -p "$OWRT/antminer"
for f in boot.bin u-boot.img; do
  if [ -f "$HERE/bootloader/$f" ]; then
    cp "$HERE/bootloader/$f" "$OWRT/antminer/$f"
    echo "   загрузчик: $f ($(wc -c < "$OWRT/antminer/$f") байт)"
  else
    echo "   ОШИБКА: нет bootloader/$f — образ будет незагружаемым" >&2
    exit 1
  fi
done
# Окружение необязательно: без него U-Boot работает на значениях по умолчанию,
# а nand_install проверит наличие файла сам.
if [ -f "$HERE/bootloader/uboot_env.bin" ]; then
  cp "$HERE/bootloader/uboot_env.bin" "$OWRT/antminer/uboot_env.bin"
  echo "   окружение U-Boot: uboot_env.bin ($(wc -c < "$OWRT/antminer/uboot_env.bin") байт)"
else
  echo "   ПРЕДУПРЕЖДЕНИЕ: нет bootloader/uboot_env.bin — раздел uboot_env останется пустым"
fi
if [ -f "$HERE/bitstream/system.bit.gz" ]; then
  cp "$HERE/bitstream/system.bit.gz" "$OWRT/antminer/system.bit.gz"
  echo "   битстрим: $(wc -c < "$OWRT/antminer/system.bit.gz") байт"
else
  echo "   битстрима нет — образ соберётся без PL (fpga loadb не сработает)"
fi
cp "$HERE/files/uEnv.txt" "$OWRT/antminer/uEnv.txt"
echo "   uEnv.txt: скопирован"

# Файлы корневой системы: первичная настройка и пользовательские скрипты.
# Кладём подкаталоги etc и myscripts: files/uEnv.txt нужен в FAT, а не в корне.
if [ -d "$HERE/files/etc" ]; then
  mkdir -p "$OWRT/files/etc"
  cp -a "$HERE/files/etc/." "$OWRT/files/etc/"
  find "$OWRT/files/etc/uci-defaults" -type f -exec chmod 755 {} \; 2>/dev/null || true
  echo "   files/etc: $(( $(find "$OWRT/files/etc" -type f | wc -l) )) файл(ов) в корневой ФС"
fi

# /myscripts: файлы кладутся в образ, а права ставит uci-defaults при первой
# загрузке (files/etc/uci-defaults/91-board-scripts). Права в образе не
# выставляются намеренно: разбор режимов на этапе сборки хрупок, а рантайм-права
# проверяет сама диагностика и шаг 03 qemu smoke. Установка только добавляющая:
# файлы пользователя в /myscripts не удаляются.
if [ -d "$HERE/files/myscripts" ]; then
  mkdir -p "$OWRT/files/myscripts"
  cp -a "$HERE/files/myscripts/." "$OWRT/files/myscripts/"
  echo "   files/myscripts: $(( $(find "$OWRT/files/myscripts" -type f | wc -l) )) скрипт(ов) в образе; права ставит uci-defaults"
fi

echo "== 3. feeds автора =="
cd "$OWRT"
if ! grep -q '^src-link antminer ' feeds.conf.default 2>/dev/null; then
  echo "src-link antminer $HERE/packages" >> feeds.conf.default
  echo "   подключён src-link antminer -> $HERE/packages"
else
  echo "   src-link antminer уже подключён"
fi
./scripts/feeds update -a
# Ставим ВСЕ фиды, а не только antminer: `feeds install -p antminer` подтягивает
# лишь зависимости пакетов автора, и тогда LuCI-тема, luci-ssl, i2c-tools и другие
# «необязательные» пакеты из официальных фидов остаются невидимыми для defconfig
# и молча выпадают из конфига.
./scripts/feeds install -a

echo "== 3b. конфликт /etc/init.d/mpd =="
# mpd-full и luci-app-mympd оба ставят /etc/init.d/mpd. opkg (OpenWrt 24.10,
# на которой собирает автор) ограничивается предупреждением и оставляет файл
# последнего установленного пакета; apk (25.12) считает это ошибкой установки
# и валит package/install: «trying to overwrite etc/init.d/mpd owned by
# mpd-full». Авторитетный скрипт — из luci-app-mympd: он создаёт пользователя,
# каталоги и mpd.conf при каждом старте, а не только в postinst. Поэтому
# убираем установку файла из mpd-full. Если строка исчезнет в новой версии
# фида — падаем громко, а не собираем образ с двумя владельцами одного пути.
mpd_mk="$OWRT/feeds/packages/sound/mpd/Makefile"
if [ ! -f "$mpd_mk" ]; then
  echo "   ОШИБКА: нет $mpd_mk — фид packages не установлен" >&2
  exit 1
fi
if [ "$(grep -c 'INSTALL_BIN) ./files/mpd.init' "$mpd_mk" || true)" -ne 1 ]; then
  echo "   ОШИБКА: в $mpd_mk не найдена ровно одна установка mpd.init" >&2
  echo "   Возможно, обновился пакет mpd — проверьте вручную." >&2
  exit 1
fi
sed -i 's|^\([[:space:]]*\)\$(INSTALL_BIN) \./files/mpd\.init \$(1)/etc/init\.d/mpd|\1# /etc/init.d/mpd ставит luci-app-mympd — см. scripts/apply.sh|' "$mpd_mk"
if grep -q 'INSTALL_BIN) ./files/mpd.init' "$mpd_mk"; then
  echo "   ОШИБКА: строку установки mpd.init вырезать не удалось" >&2
  exit 1
fi
echo "   ok  mpd-full больше не ставит /etc/init.d/mpd"

echo "== 4. конфигурация =="
cp "$CFG" .config
make defconfig

echo
echo "Готово. Дальше:"
echo "  cd $OWRT && make -j\$(nproc) download && make -j\$(nproc) world"
echo "Результат: $OWRT/bin/targets/${TARGET:-<цель>}/${SUBTARGET:-<подцель>}/"

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
#   3. подключает feeds автора как локальный src-link;
#   4. ставит наш .config и запускает make defconfig.
#
# Код возврата 0 — дерево готово к `make world`.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWRT="${1:-$HERE/openwrt}"

if [ ! -d "$OWRT" ]; then
  echo "ОШИБКА: каталог OpenWrt не найден: $OWRT" >&2
  echo "Склонируйте его: git clone --depth 1 -b v25.12.6 https://github.com/openwrt/openwrt.git $OWRT" >&2
  exit 1
fi

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
if [ -f "$HERE/bitstream/system.bit.gz" ]; then
  cp "$HERE/bitstream/system.bit.gz" "$OWRT/antminer/system.bit.gz"
  echo "   битстрим: $(wc -c < "$OWRT/antminer/system.bit.gz") байт"
else
  echo "   битстрима нет — образ соберётся без PL (fpga loadb не сработает)"
fi
cp "$HERE/files/uEnv.txt" "$OWRT/antminer/uEnv.txt"
echo "   uEnv.txt: скопирован"

echo "== 3. feeds автора =="
cd "$OWRT"
if ! grep -q '^src-link antminer ' feeds.conf.default 2>/dev/null; then
  echo "src-link antminer $HERE/packages" >> feeds.conf.default
  echo "   подключён src-link antminer -> $HERE/packages"
else
  echo "   src-link antminer уже подключён"
fi
./scripts/feeds update -a
./scripts/feeds install -a -p antminer

echo "== 4. конфигурация =="
cp "$HERE/configs/zynq_antminer_s9.config" .config
make defconfig

echo
echo "Готово. Дальше:"
echo "  cd $OWRT && make -j\$(nproc) download && make -j\$(nproc) world"
echo "Результат: $OWRT/bin/targets/zynq/generic/"

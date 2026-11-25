#!/usr/bin/env bash
#
# update_expected_artifacts.sh — пересчитывает scripts/expected-artifacts.sha256.
#
# Использование:
#   bash scripts/update_expected_artifacts.sh
#
# Зачем: хеши входных файлов (загрузчик, битстрим, uEnv.txt) проверяются до
# сборки. После любой правки этих файлов хеш нужно обновить, иначе шаг
# «Verify input artifacts» останавливает сборку. Скрипт убирает ручной шаг.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/expected-artifacts.sha256"

cd "$ROOT"

files=()
for f in bootloader/boot.bin bootloader/u-boot.img bootloader/uboot_env.bin \
         bitstream/system.bit.gz files/uEnv.txt; do
  if [ -f "$f" ]; then
    files+=("$f")
  else
    echo "ПРЕДУПРЕЖДЕНИЕ: файла нет, пропущен: $f" >&2
  fi
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "ОШИБКА: нечего хешировать — нет ни одного входного файла" >&2
  exit 1
fi

{
  echo "# Контрольные суммы входных двоичных файлов."
  echo "# Проверяются до сборки: sha256sum -c scripts/expected-artifacts.sha256"
  echo "# Ловит битый коммит, порчу переводов строк и подмену артефакта."
  echo "# Обновление: bash scripts/update_expected_artifacts.sh"
  # На Windows sha256sum пишет «*путь» (двоичный режим); приводим к обычным
  # двум пробелам, чтобы файл одинаково выглядел на всех системах.
  sha256sum "${files[@]}" | sed 's/ \*/  /'
} > "$OUT"

echo "обновлено: $OUT"
sha256sum -c "$OUT"

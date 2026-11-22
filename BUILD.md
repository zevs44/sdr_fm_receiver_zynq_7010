# Сборка образа OpenWrt для Antminer S9

Форк репозитория `alexsys87/sdr_fm_receiver_zynq_7010`: пакеты автора + слой сборки
свежего OpenWrt. Что именно изменено относительно оригинала — в [`FORK_CHANGES.md`](FORK_CHANGES.md).

Справочные материалы по плате и дизайну — в [`docs/`](docs/README.md): аудиопотоки,
распиновка колодок, пересборка битстрима (на английском и русском).

## Что получается на выходе

`sdcard.img.gz` — образ для SD-карты:

| Раздел | Содержимое |
|---|---|
| FAT, 16 МБ | `boot.bin`, `u-boot.img`, `uEnv.txt`, `system.bit.gz`, `fit.itb` |
| squashfs + overlay | корневая система OpenWrt с пакетами автора |

Запись на карту — обычным `dd`/balenaEtcher; прошивка платы не требует JTAG.

## Требования

- Linux или WSL2 (сборка OpenWrt на Windows не поддерживается).
- ~40 ГБ свободного места, 4+ ГБ RAM.
- Пакеты сборки: `build-essential clang flex bison g++ gawk gcc-multilib g++-multilib
  gettext git libncurses-dev libssl-dev python3 python3-setuptools rsync unzip
  zlib1g-dev file libelf-dev wget ca-certificates ccache`.

## Локальная сборка

```bash
# 1. дерево OpenWrt нужной версии
git clone --depth 1 -b "$(cat .openwrt-version)" https://github.com/openwrt/openwrt.git openwrt

# 2. патчи, фиды, конфигурация
bash scripts/apply.sh ./openwrt

# 3. сборка
cd openwrt
make -j"$(nproc)" download
make -j"$(nproc)" world
```

Результат: `openwrt/bin/targets/zynq/generic/*.img.gz`.

## Сборка в GitHub Actions

Workflow `.github/workflows/build.yml` запускается:

- вручную (`workflow_dispatch`, можно указать тег OpenWrt);
- при изменениях в `packages/`, `target-patches/`, `configs/`, `files/`, `scripts/apply.sh`.

Образ и итоговый `.config` выкладываются артефактом `sdcard-<тег>`.

`.github/workflows/watch-upstream.yml` раз в 6 часов проверяет новые стабильные релизы
OpenWrt: если тег новее, чем в `.openwrt-version`, обновляет файл и запускает сборку.

## Битстрим

`bitstream/system.bit.gz` собирается **локально** в Vivado — в CI это невозможно
(лицензия node-locked). Подробности — [`bitstream/README.md`](bitstream/README.md).

Без файла образ соберётся, но PL останется пустым: радио и звук работать не будут.

## Переход на новую версию OpenWrt

Версия задаётся **в одном месте** — файле `.openwrt-version`. Всё остальное
подхватывается автоматически: workflow читает файл, `apply.sh` берёт цель и
подцель из конфига.

| Что | Где | Сейчас | Когда менять |
|---|---|---|---|
| Версия OpenWrt | `.openwrt-version` | `v25.12.6` | при выходе релиза; watcher делает это сам |
| Репозиторий OpenWrt | `build.yml` → `env.OPENWRT_REPO` | `https://github.com/openwrt/openwrt.git` | при переходе на форк или зеркало |
| Каталог сборки | `build.yml` → `env.OPENWRT_DIR` | `openwrt` | почти никогда |
| Цель / подцель | `build.yml` → `env.TARGET` / `env.SUBTARGET` | `zynq` / `generic` | при смене платформы |
| Префикс артефакта | `build.yml` → `env.ARTIFACT_PREFIX` | `sdcard` | косметика |
| Таймаут сборки | `build.yml` → `timeout-minutes` | `330` | если сборка стала дольше |
| Репозиторий для слежения | `watch-upstream.yml` → `env.OPENWRT_REPO` | `openwrt/openwrt` | при переходе на форк |
| Файл версии | `watch-upstream.yml` → `env.VERSION_FILE` | `.openwrt-version` | почти никогда |
| Фильтр стабильных тегов | `watch-upstream.yml` → `env.STABLE_TAG_REGEX` | `^v[0-9]+\.[0-9]+\.[0-9]+$` | если нужны rc-сборки |
| Цель и устройство | `configs/zynq_antminer_s9.config` | `CONFIG_TARGET_zynq*`, `..._DEVICE_bitmain_zynq-antminer-s9` | при смене платы |

Порядок перехода:

1. Изменить `.openwrt-version` (или дождаться watcher'а).
2. Запустить сборку вручную: `gh workflow run build.yml`.
3. Если патч не лёг — пересобрать его на новой базе, см. `target-patches/README.md`.
4. Записать изменение в `FORK_CHANGES.md`.

## Если сборка упала

| Симптом | Причина | Что делать |
|---|---|---|
| `патч не ложится на это дерево` | сменилась версия OpenWrt | пересобрать патч на новой базе, см. `target-patches/README.md` |
| `No rule to make target .../system.bit.gz` | патч `0200` не применился | проверить порядок патчей в `target-patches/` |
| пакет автора не собирается | дрейф API ядра или LuCI | править пакет, запись в `FORK_CHANGES.md` |
| `No space left on device` | мало места | освободить диск, `make clean` |
| образ есть, но плата не грузится | нет `boot.bin`/`uEnv.txt` в FAT | проверить, что `apply.sh` отработал без ошибок |

Логи сборки: `openwrt/logs/`; в CI они выкладываются артефактом при падении.

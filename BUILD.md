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
make -j"$(nproc)" -k world

# 4. проверки (из корня репозитория)
sha256sum -c scripts/expected-artifacts.sha256      # входные двоичные файлы
bash scripts/check_config.sh ./openwrt              # defconfig ничего не выбросил
bash scripts/verify_image.sh ./openwrt/bin/targets/zynq/generic   # образ работоспособен
```

Результат: `openwrt/bin/targets/zynq/generic/*.img.gz`.

## Сборка в GitHub Actions

Workflow `.github/workflows/01_build.yml` запускается:

- вручную (`workflow_dispatch`, можно указать тег OpenWrt, пакет и параллельность);
- при изменениях в `packages/`, `target-patches/`, `configs/`, `files/`,
  `bootloader/`, `bitstream/`, `scripts/`, `.github/workflows/01_build.yml`.

Образ и итоговый `.config` выкладываются артефактом `sdcard-<тег>`.
`build.log`, `retry.log`, `.config`, `build-info.txt`, `patch-status.txt` и `openwrt/logs/`
выкладываются артефактом `build-logs-<run_id>` — **всегда**, не только при падении:
без успешного лога не с чем сравнивать.

Сборка идёт как `make -k world`: при ошибке она не останавливается на первом
пакете, а доводит проход и печатает **все** сломанные пакеты. Это экономит
полный прогон (~1,5 ч) на каждый следующий дефект.

`.github/workflows/02_watch-upstream.yml` раз в 6 часов проверяет новые стабильные релизы
OpenWrt: если тег новее, чем в `.openwrt-version`, обновляет файл и запускает сборку.

`.github/workflows/03_cleanup-runs.yml` раз в сутки удаляет старые **успешные** прогоны
(по умолчанию — `02_watch-upstream.yml`, старше 10 дней), чтобы история Actions не росла
бесконечно. Неуспешные прогоны не удаляются никогда: это история отладки. Параметры
(`workflow`, `older_than_days`, `dry_run`) задаются при ручном запуске; `workflow: all`
чистит все workflow репозитория. GitHub считает workflow по пути файла, поэтому прогоны,
созданные до переименования (`build.yml`, `watch-upstream.yml`), к новым файлам не относятся
и под фильтр по имени файла не попадают — разово их можно удалить с `workflow: all`.

### Что проверяется до и после сборки

| Проверка | Где | Что ловит |
|---|---|---|
| `shellcheck`, `actionlint` | джоба `lint` | ошибки в скриптах и YAML workflow |
| `scripts/expected-artifacts.sha256` + магия битстрима | шаг «Verify input artifacts» | битый коммит, порча переводов строк, подмена двоичного файла |
| ожидаемые файлы в диффе | шаг «Audit patch layer» | патч лёг частично или не лёг вовсе |
| `scripts/check_config.sh` | шаг «Verify config» | `defconfig` молча выбросил пакет или поменял значение |
| `scripts/verify_image.sh` | шаг «Verify image» | образ без битстрима, без kmod, с чужим деревом устройства |

Проверки запускаются и локально:

```bash
sha256sum -c scripts/expected-artifacts.sha256
bash scripts/check_config.sh ./openwrt
bash scripts/verify_image.sh ./openwrt/bin/targets/zynq/generic
```

`verify_image.sh` требует `sfdisk`, `mtools`, `dosfstools`, `squashfs-tools`.
Отсутствие битстрима считается провалом: такой образ грузится, но PL остаётся
пустым. Осознанно собрать образ без него: `ALLOW_MISSING_BITSTREAM=1`.

## Загрузчик

`boot.bin`, `u-boot.img` и `uboot_env.bin` **не собираются**: они поставляются
готовыми в `bootloader/` и копируются в образ. U-Boot из OpenWrt 25.12 (версия
2019.07) для этой платы не собирается — поддержка в upstream написана под
U-Boot 2026.04, а FSBL для платы строится в Vitis, а не в OpenWrt.

Поэтому пакет `uboot-zynq` в бэкпорте намеренно исключён. Подробности и
контрольные суммы — [`bootloader/README.md`](bootloader/README.md).

## Битстрим

`bitstream/system.bit.gz` собирается **локально** в Vivado — в CI это невозможно
(лицензия node-locked). Подробности — [`bitstream/README.md`](bitstream/README.md).

Без файла образ соберётся, но PL останется пустым: радио и звук работать не будут.

## Модули ядра и официальные репозитории

**Модули ядра из официального репозитория в этот образ не установятся.** Это не
поломка сборки, а свойство системы пакетов OpenWrt.

Каждый kmod объявляет точную зависимость от пакета `kernel`:

```
EXTRA_DEPENDS := kernel (=$(LINUX_VERSION)~$(LINUX_VERMAGIC)-r$(LINUX_RELEASE))
```

`LINUX_VERMAGIC` вычисляется из конфигурации ядра. Официальные модули собраны с
вермагией `6.12.112-1-ae24847679775ceb14a3d3c24ef38548` — это видно по имени
каталога на `downloads.openwrt.org`. Наша конфигурация отличается: добавлено
устройство и включены свои kmod-пакеты, поэтому вермагия другая, а значит и версия
пакета `kernel` другая.

| Что ставится | Результат |
|---|---|
| kmod из официального репозитория | отказ: невыполнимая зависимость `kernel (=...)` |
| обычный пакет (пользовательский) без kmod-зависимостей | обычно ставится: архитектура `arm_cortex-a9_neon` и musl совпадают |
| пакет, тянущий kmod | отказ по той же причине |

Что делать:

1. **Включать нужные kmod в конфиг сборки** — самый простой путь. Модуль попадёт
   в образ, и ставить его в рантайме не придётся.
2. **Публиковать свой репозиторий kmod.** Сборка создаёт
   `bin/targets/zynq/generic/kmods/<версия-ядра>-<вермагия>/`. Достаточно выложить
   этот каталог и указать адрес в конфигурации пакетного менеджера образа.

Свести вермагию к официальной нельзя: наше устройство само по себе добавляет
символы в конфигурацию ядра.

> В OpenWrt 25.12 пакетный менеджер — **apk** (файлы `.apk`), а не `opkg`.
> Рецепты и команды из старых инструкций (`opkg install`) не применимы.

## Переход на новую версию OpenWrt

Версия задаётся **в одном месте** — файле `.openwrt-version`. Всё остальное
подхватывается автоматически: workflow читает файл, `apply.sh` берёт цель и
подцель из конфига.

| Что | Где | Сейчас | Когда менять |
|---|---|---|---|
| Версия OpenWrt | `.openwrt-version` | `v25.12.6` | при выходе релиза; watcher делает это сам |
| Репозиторий OpenWrt | `01_build.yml` → `env.OPENWRT_REPO` | `https://github.com/openwrt/openwrt.git` | при переходе на форк или зеркало |
| Каталог сборки | `01_build.yml` → `env.OPENWRT_DIR` | `openwrt` | почти никогда |
| Цель / подцель | `01_build.yml` → `env.TARGET` / `env.SUBTARGET` | `zynq` / `generic` | при смене платформы |
| Префикс артефакта | `01_build.yml` → `env.ARTIFACT_PREFIX` | `sdcard` | косметика |
| Таймаут сборки | `01_build.yml` → `timeout-minutes` | `330` | если сборка стала дольше |
| Параллельность make | `01_build.yml` → `env.DEFAULT_JOBS` | `4` (не больше `nproc`) | при OOM — снижать; при большом раннере — поднимать |
| Репозиторий для слежения | `02_watch-upstream.yml` → `env.OPENWRT_REPO` | `openwrt/openwrt` | при переходе на форк |
| Файл версии | `02_watch-upstream.yml` → `env.VERSION_FILE` | `.openwrt-version` | почти никогда |
| Фильтр стабильных тегов | `02_watch-upstream.yml` → `env.STABLE_TAG_REGEX` | `^v[0-9]+\.[0-9]+\.[0-9]+$` | если нужны rc-сборки |
| Цель и устройство | `configs/zynq_antminer_s9.config` | `CONFIG_TARGET_zynq*`, `..._DEVICE_bitmain_zynq-antminer-s9` | при смене платы |

Порядок перехода:

1. Изменить `.openwrt-version` (или дождаться watcher'а).
2. Запустить сборку вручную: `gh workflow run 01_build.yml`.
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
| `Verify config` упал на `CONFIG_PACKAGE_*` | `defconfig` выбросил пакет: нет в фидах или не разрешилась зависимость | смотреть шаг «Verify config», чинить зависимость пакета |
| `Verify image` упал | собрался, но образ неработоспособен | таблица `PASS/FAIL` в шаге; битстрим, kmod, дерево устройства |
| сборка упала, но имени пакета нет | падение на установке пакетов или сборке образа | шаг `Build` печатает хвост `build.log`; целиком — в артефакте `build-logs-<run_id>` |

Логи сборки: `openwrt/logs/`; в CI они выкладываются артефактом `build-logs-<run_id>`
вместе с `build.log`, `.config`, `build-info.txt` и `patch-status.txt`.

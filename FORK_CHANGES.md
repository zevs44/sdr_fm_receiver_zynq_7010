# Изменения относительно upstream

> **Форк:** https://github.com/zevs44/sdr_fm_receiver_zynq_7010
> **Родитель:** https://github.com/alexsys87/sdr_fm_receiver_zynq_7010
> **Актуально на:** 2026-11-23

## Зачем этот файл

Единственный источник правды о том, чем этот форк отличается от исходного репозитория.
Ветка `main` может уйти далеко вперёд, но прочитать её историю целиком — не способ понять
замысел. Здесь каждая строка отвечает на три вопроса: **что** изменено, **зачем** и **где**.

## Правила ведения

1. Каждое изменение в форке — отдельная запись в журнале ниже. Изменение без записи считается
   ошибкой ведения.
2. Записи не удаляются. Отменённое изменение помечается статусом `отменено` с причиной —
   история решений важнее аккуратного вида.
3. Для каждой записи указываются затронутые файлы (пути от корня репозитория).
4. Синхронизация с upstream записями не сопровождается: это не наше изменение.
5. Плановые работы перечислены отдельным разделом и переезжают в журнал по мере выполнения.

## Синхронизация с upstream

```bash
# один раз
git remote add upstream https://github.com/alexsys87/sdr_fm_receiver_zynq_7010.git

# при обновлении автора
git fetch upstream
git merge upstream/main
git push origin main

# либо средствами gh
gh repo sync zevs44/sdr_fm_receiver_zynq_7010 --branch main
```

## Текущее состояние

На 2026-11-22 добавлен слой сборки: патчи, конфигурация, `uEnv.txt`, скрипт подготовки дерева
и два workflow. **Изменений в пакетах автора пока нет** — они подключаются как feed без правок.
Битстрим ещё не добавлен, поэтому образ собирается без PL.

## Журнал изменений

| № | Дата | Область | Что изменено | Зачем | Файлы | Статус |
|---|---|---|---|---|---|---|
| 1 | 2026-11-22 | документация | Добавлен реестр отличий от upstream | чтобы форк оставался читаемым при расхождении с оригиналом | `FORK_CHANGES.md` | сделано |
| 2 | 2026-11-22 | сборка | Бэкпорт поддержки платы из upstream `e050bb7`: `board.d/02_network`, `image/Makefile`, два DTS-патча (изменения `uboot-zynq` из коммита исключены, см. запись 13) | в ветке 25.12 платы нет | `target-patches/0001_openwrt-backport-antminer-s9.patch` | сделано, проверено на 25.12 |
| 3 | 2026-11-22 | сборка | Копирование `system.bit.gz` в FAT-раздел и подмена `uEnv.txt` на наш | штатный образ не грузит битстрим | `target-patches/0200_zynq-sdcard-bitstream-and-uenv.patch` | сделано |
| 4 | 2026-11-22 | конфигурация | Конфиг сборки: цель `zynq/generic`, устройство `bitmain_zynq-antminer-s9`, squashfs, пакеты автора | воспроизводимый состав образа | `configs/zynq_antminer_s9.config` | сделано |
| 5 | 2026-11-22 | загрузка | `uEnv.txt` с `fpga loadb` и `clk_ignore_unused` | без загрузки PL нет радио и звука | `files/uEnv.txt` | сделано |
| 6 | 2026-11-22 | CI | Сборка образа и слежение за релизами OpenWrt | сборка силами GitHub, реакция на новые версии | `.github/workflows/build.yml`, `.github/workflows/watch-upstream.yml` | сделано |
| 7 | 2026-11-22 | инфраструктура | Скрипт подготовки дерева, фиксация версии, LF-переводы строк, документация сборки | воспроизводимость и защита от CRLF в патчах | `scripts/apply.sh`, `.openwrt-version`, `.gitattributes`, `.gitignore`, `BUILD.md` | сделано |
| 8 | 2026-11-22 | документация | `docs/` — аудиопотоки, распиновка колодок, пересборка битстрима; каждый документ на английском и русском | материал полезен вне этого проекта; проектные решения и частная специфика в публикацию не входят | `docs/README.md`, `docs/README.ru.md`, `docs/audio-path*.md`, `docs/rebuild-bitstream*.md` | сделано |
| 9 | 2026-11-22 | безопасность | Действия в workflow закреплены по SHA коммита; добавлен `dependabot.yml` для их обновления | тег можно перепривязать к чужому коммиту, SHA — нельзя | `.github/workflows/*.yml`, `.github/dependabot.yml` | сделано |
| 10 | 2026-11-22 | документация | Шесть SVG-схем выгружены в `docs/img/` и встроены в оба языка | схема читается быстрее таблицы; взяты только те, что описывают штатный дизайн | `docs/img/*.svg`, `docs/*.md` | сделано |
| 11 | 2026-11-22 | документация | В SVG добавлены `xmlns` и явные `width`/`height` | без пространства имён отдельный `.svg` не отображается: GitHub отдаёт его как `image/svg+xml` с `nosniff`, и браузер не считает файл SVG | `docs/img/*.svg` | исправлено |
| 12 | 2026-11-22 | артефакт | Добавлен `bitstream/system.bit.gz` — штатный дизайн автора из релиза `v1.0.0` (SHA-256 `7171a034…`) | без битстрима образ не поднимает PL, а собрать его в CI нельзя (node-locked лицензия Vivado) | `bitstream/system.bit.gz`, `bitstream/README.md`, `.github/workflows/build.yml` | сделано; заменить на собственную сборку |
| 13 | 2026-11-22 | сборка | Из бэкпорта убраны изменения `package/boot/uboot-zynq`; загрузчик поставляется готовым (`bootloader/`) | U-Boot 2019.07 из 25.12 не собирается для `antminer-s9`: поддержка в upstream написана под 2026.04. Так же поступает автор в `Antminer_S9_OpenWRT` | `target-patches/0001_*.patch`, `target-patches/0200_*.patch`, `bootloader/*`, `scripts/apply.sh`, `BUILD.md` | сделано |
| 14 | 2026-11-22 | пакеты | `csdr`: `PKG_VERSION` `2019-02-27` → `2019.02.27`, исходная дата вынесена в `PKG_SOURCE_DATE` | apk в OpenWrt 25.12 отвергает версии с несколькими дефисами: «package version is invalid». Проверены все 19 пакетов — несовместим был только этот | `packages/csdr/Makefile` | сделано |
| 15 | 2026-11-22 | пакеты | `kmod-zynq-fm-radio`: `no_llseek` заменён макросом `ZYNQ_FM_NO_LLSEEK` (в ядре 6.0 `no_llseek` удалён, используется `noop_llseek`) | пакет не собирался на ядре 6.12: `'no_llseek' undeclared` | `packages/kmod-zynq-fm-radio/src/zynq_fm_radio.c` | сделано |
| 16 | 2026-11-22 | конфигурация | Включены kmod для nftables: `kmod-nft-core`, `-queue`, `-nat`, `-compat`, `kmod-nf-conntrack`, плюс `nftables-json` и `ca-bundle` | `b4` ставится в рантайме официальным скриптом, но требует эти модули; с официальных фидов они не встанут из-за версии ядра. `kmod-nft-conntrack` в 25.12 нет — conntrack даёт `kmod-nf-conntrack` | `configs/zynq_antminer_s9.config` | сделано |
| 17 | 2026-11-23 | CI | Диагностика падений: `build.log` выкладывается артефактом и печатается в лог шага; ловятся вложенные `make[1]/make[2]: ***`, ошибки образа и установки, `No space left`, OOM; выводятся диск и память | прогон `45062377171` упал без единой улики: весь вывод `make world` уходил в `build.log`, который не сохранялся, а `grep "make: \*\*\*"` не видел вложенных make. Причину восстановить было нельзя | `.github/workflows/build.yml` | сделано |
| 18 | 2026-11-23 | CI | `make -k world` вместо `make world`: в лог попадают **все** сломанные пакеты за один прогон; параллельность `-j` вынесена в вход и ограничена `min(nproc,4)`; ретраи на `make download`; таймауты шагов; кэш ccache сохранён из того каталога, куда сборка действительно пишет | цикл «один сломанный пакет — один прогон в 1,5 ч»; сетевые сбои роняли сборку; `actions/cache` кэшировал `~/.ccache`, а `CCACHE_DIR` указывал на `$GITHUB_WORKSPACE/.ccache` — кэш не работал вовсе | `.github/workflows/build.yml` | сделано |
| 19 | 2026-11-23 | проверки | Добавлены `scripts/expected-artifacts.sha256`, `scripts/check_config.sh`, `scripts/verify_image.sh` и соответствующие шаги CI. Джоба `lint` — `shellcheck` + `actionlint` (actionlint скачивается по версии с проверкой SHA-256) | CI был зелёным при любом непустом `*.img.gz`: образ без битстрима или без kmod проходил все проверки. `defconfig` молча выбрасывал пакеты, патчи могли лечь частично, бинарные файлы — испортиться | `scripts/expected-artifacts.sha256`, `scripts/check_config.sh`, `scripts/verify_image.sh`, `.github/workflows/build.yml`, `BUILD.md` | сделано |
| 20 | 2026-11-23 | CI | `actions/checkout` v4.4.0 → v7.0.1, `actions/cache` v4.3.0 → v6.1.0, `actions/upload-artifact` v4.6.2 → v7.0.2 (все на `node24`) | GitHub принудительно перевёл действия с `node20` на `node24` и предупреждал в каждом прогоне; рано или поздно старые версии перестанут запускаться. Используемые входы в новых версиях сохранены | `.github/workflows/build.yml`, `.github/workflows/watch-upstream.yml` | сделано |
| 21 | 2026-11-23 | сборка | `apply.sh` ставит **все** фиды (`feeds install -a`), а не только фид автора | `feeds install -p antminer` подтягивал лишь зависимости пакетов автора: `luci-theme-bootstrap`, `luci-ssl-openssl`, `i2c-tools` и метапакет `luci` оставались невидимыми для `defconfig` и молча выпадали из образа. Нашла новая проверка `check_config.sh` (прогон `45139814623`) | `scripts/apply.sh` | сделано |
| 22 | 2026-11-23 | конфигурация | Добавлен `CONFIG_DEVEL=y` (нужен для `CONFIG_CCACHE`), убран мёртвый `CONFIG_TARGET_ROOTFS_UBIFS` | `CCACHE` объявлен как `bool "Use ccache" if DEVEL`; без `DEVEL` символ выбрасывался и ccache не работал вовсе — отсюда пустая статистика в `build-info.txt`. Символа `TARGET_ROOTFS_UBIFS` в 25.12 нет | `configs/zynq_antminer_s9.config` | сделано |
| 23 | 2026-11-23 | конфигурация | Убран `CONFIG_PACKAGE_kmod-nft-compat` | он тянет `+kmod-nf-ipt` → `ip_tables.ko`, а в `target/linux/generic/config-6.12` стоит `# CONFIG_NETFILTER_XTABLES is not set`, поэтому `KCONFIG:=$(KCONFIG_NF_IPT)` не применяется и модуль не собирается: прогон `45140805950` упал на `ERROR: module '.../ip_tables.ko' is missing` → `package/kernel/linux failed to build`. b4 работает через нативный nftables и xtables-совместимость не требует | `configs/zynq_antminer_s9.config` | сделано |
| 24 | 2026-11-23 | CI | При падении без имени пакета повторяется именно упавшая цель (`package/install` и т.п.) с `V=s`; `ccache -s` читает настоящий каталог кэша; кэш сохраняется и при упавшей сборке | `include/verbose.mk` в обычном режиме отправляет вывод вложенных make в `/dev/null`, поэтому `package/install` упал **без единой строки ошибки** (прогон `45150175437`). `actions/cache` сохраняет кэш только при успехе (`post-if: success()`), а отлаживаем мы падения — каждая повторная сборка шла с нуля | `.github/workflows/build.yml` | сделано |
| 25 | 2026-11-23 | конфигурация | Убран `CONFIG_PACKAGE_csdr`, оставлен только `csdr2` | прогон `45166188455` упал на `package/install`: `csdr2` пытался перезаписать `usr/bin/csdr`, `nmux`, `fm_stereo_decode`, `resample_upsample_f` и `usr/lib/libcsdr.so`, принадлежащие `csdr` — оба пакета ставят одни и те же пути, а apk (в отличие от opkg) считает это ошибкой. В образе автора есть только `csdr2`; старый `csdr` никому не нужен (упоминается лишь в комментариях `mpx_stream.c`) | `configs/zynq_antminer_s9.config` | сделано |
| 26 | 2026-11-23 | сборка | `apply.sh` после `feeds install -a` вырезает установку `/etc/init.d/mpd` из фида `packages/sound/mpd` (с проверкой, что строка найдена ровно один раз) | тот же прогон: `luci-app-mympd` и `mpd-full` оба ставят `/etc/init.d/mpd` → `trying to overwrite ... owned by mpd-full-0.23.16-r1`. Под opkg (24.10 у автора) это было предупреждение, под apk — ошибка. Авторитетный скрипт — из `luci-app-mympd`: он создаёт пользователя, каталоги и `mpd.conf` при каждом старте | `scripts/apply.sh`, `packages/luci-app-mympd/Makefile` | сделано |
| 27 | 2026-11-23 | сборка | `apply.sh` приводит `$OWRT` к абсолютному пути до первого `cd` | прогон `45252265300` упал за 4,5 мин: в CI путь передаётся относительным (`./openwrt`), скрипт делает `cd "$OWRT"`, и `$OWRT/feeds/...` превращался в `./openwrt/openwrt/feeds/...`. Локально по умолчанию путь абсолютный, поэтому ошибка не воспроизводилась | `scripts/apply.sh` | сделано |
| 28 | 2026-11-23 | сборка | Патч `0200` объявляет свои переменные образа через `DEVICE_VARS += BOOTBIN_FILE UBOOT_IMG_FILE UBOOT_ENV_FILE UENV_FILE` | прогон `45254649968` упал на `target/linux install` (сборка образа): переменные `BOOTBIN_FILE`/`UBOOT_IMG_FILE`/`UENV_FILE`/`UBOOT_ENV_FILE` не входят в `DEVICE_VARS`/`DEFAULT_DEVICE_VARS`, поэтому `Device/Export` не делает их привязанными к устройству — в образе использовалось значение **последнего** описанного устройства (`xlnx_zynq-zc702`), и `mcopy` искал несуществующий `xlnx_zynq-zc702-boot.bin`. У автора этих переменных не было: он брал `$(STAGING_DIR_IMAGE)/$(DEVICE_NAME)-boot.bin`, а `DEVICE_NAME` входит в `DEVICE_VARS` | `target-patches/0200_zynq-sdcard-bitstream-and-uenv.patch` | сделано |
| 29 | 2026-11-23 | CI | При падении цели `target/*` повтор идёт в `target/install` (а не `/compile`); вывод повтора пишется в `retry.log` и выкладывается артефактом; строки ` make[N] -C` (флаг, не цель) больше не принимаются за имя упавшей цели | тот же прогон: диагностика повторила `target/linux/compile`, эта стадия уже прошла — реальная ошибка сборки образа снова осталась невидимой. `target/install` тянет `compile` за собой, поэтому покрывает обе стадии | `.github/workflows/build.yml` | сделано |
| 30 | 2026-11-24 | CI | Workflow пронумерованы: `build.yml` → `01_build.yml`, `watch-upstream.yml` → `02_watch-upstream.yml`; номера добавлены и в `name:` (в интерфейсе GitHub порядок иначе теряется). Ссылки обновлены в `BUILD_WORKFLOW`, фильтре путей, `BUILD.md` | тот же закон имён, что у папок и файлов проекта (`NN_`), и предсказуемый порядок в списке Actions | `.github/workflows/01_build.yml`, `.github/workflows/02_watch-upstream.yml`, `BUILD.md` | сделано |
| 31 | 2026-11-24 | CI | Новый workflow `03_cleanup-runs.yml`: раз в сутки удаляет успешные прогоны старше 10 дней (по умолчанию — только `02_watch-upstream.yml`, параметр `workflow: all` — все workflow). Неуспешные прогоны не удаляются никогда; есть `dry_run` и сводка в Step Summary | watcher запускается раз в 6 часов — около 1460 прогонов в год, почти все успешные и пустые; история Actions росла без пользы. Проверено на прогоне `45358386224` (`dry_run`, `all`): 3 успешных, 2 под удаление. GitHub считает workflow по пути файла, поэтому прогоны до переименования под фильтр по имени файла не попадают — их чистит только `workflow: all` | `.github/workflows/03_cleanup-runs.yml`, `BUILD.md` | сделано |
| 32 | 2026-11-24 | конфигурация | `kmod-zynq-fm-radio` переведён из `=m` в `=y`, добавлен `CONFIG_PACKAGE_mympd=y` | прогон `45354756963`: сборка образа прошла, но `verify_image.sh` нашёл, что `zynq_fm_radio.ko` и `/usr/bin/mympd` в образе отсутствуют. В OpenWrt `=m` означает «собрать пакет, но не ставить в образ»; `luci-app-mympd` зависит от `mpd`/`mpc`, но не от демона `mympd` | `configs/zynq_antminer_s9.config` | сделано |
| 33 | 2026-11-24 | проверки | `verify_image.sh` проверяет файлы FAT-раздела через `mdir -i image ::имя` вместо разбора `mdir -b ::`; листинг печатается в лог | тот же прогон: шесть файлов были в образе (`mtype`/`mcopy` их читали), но `grep -x` не совпал ни с одним именем из `mdir -b` — формат листинга зависит от версии mtools | `scripts/verify_image.sh` | сделано |
| 34 | 2026-11-24 | документация | Исправлена распиновка J2/J4/J5 в `docs/audio-path*.md`: J2 11=V12(R)/12=W13(L), J4 11=W14(R)/12=Y14(L), J5 11=V15/12=W15, T16 = J5 пин 5 | сверка со схемой платы (лист 6, символ U1E) и файлом AMD `xc7z010clg400pkg.txt`: прежняя таблица была сдвинута на один пин, T16 ошибочно числился на J4. Пины J1 и J9 были верны | `docs/audio-path.md`, `docs/audio-path.ru.md` | сделано |
| 35 | 2026-11-24 | проверки | **QEMU-проверка образа**: `scripts/qemu_smoke.sh` + джоба `qemu` в `01_build.yml` + отдельный `04_qemu-smoke.yml` для запуска по любому прогону без пересборки. Образ грузится в `xilinx-zynq-a9`: из `fit.itb` достаются ядро и DTB, ядро заворачивается в uImage с адресами `0x8000`, образ подключается как SD, консоль — второй UART (`0xE0001000`, `ttyPS0`). PASS = дошло до init | статическая проверка `verify_image.sh` не видит, грузится ли ядро и монтируется ли корень. Первый зелёный прогон `45396702542`: squashfs смонтирован, F2FS-overlay создан, `procd` дошёл до init, `zynq_fm_radio` загрузился (PHY в QEMU нет — ожидаемо) | `scripts/qemu_smoke.sh`, `.github/workflows/01_build.yml`, `.github/workflows/04_qemu-smoke.yml`, `BUILD.md` | сделано |
| 36 | 2026-11-24 | CI | `02_watch-upstream.yml` перед закреплением новой версии проверяет, что патч-слой на неё ложится: клон тега + `git apply --check` каждого патча; при провале версия не закрепляется | иначе `.openwrt-version` указывал бы на сломанную версию и каждая следующая сборка падала бы на `apply.sh`, пока человек не заметит | `.github/workflows/02_watch-upstream.yml`, `BUILD.md` | сделано |
| 37 | 2026-11-24 | CI | `concurrency` сборки: на `main` идущая сборка больше не отменяется (`cancel-in-progress: false`), на ветках — отменяется; группа включает `github.ref` | пуш во время 1,5-часовой сборки убивал её вместе с готовым артефактом; теперь новая постановка встаёт в очередь | `.github/workflows/01_build.yml` | сделано |
| 38 | 2026-11-24 | документация | В `BUILD.md` и `target-patches/README.md` описано, что делать, когда бэкпорт `0001` станет лишним (плата уйдёт в стабильную ветку 26.x), и что список файлов шага «Audit patch layer» нужно менять вместе с патчем | переход на новую версию не должен упираться в неочевидное «патч не ложится» | `BUILD.md`, `target-patches/README.md` | сделано |
| 39 | 2026-11-24 | device tree | `0300_zynq-antminer-s9-pl.patch` — узлы PL: `axi_i2s_adi@43c00000`, `fm-radio@43c60000`, `audio_clock` (12.288 МГц), `sound` с двумя DAI-link, `playback/capture-codec` | без узлов драйвер радио и ALSA-карта не появляются. Адреса сверены с `design_1.bd`; источник — DTB образа автора. Патч проверен `git apply` на DTS из `0001` | `target-patches/0300_zynq-antminer-s9-pl.patch` | сделано |
| 40 | 2026-11-24 | NAND | Пакет `nand-install` (`/sbin/nand_install`) по шаблону L3: проверки, сигнатуры, размеры, dry-run с меткой, подтверждение `INSTALL`, `flock`, журнал, двухэтапная запись, `mtd verify`; корневая ФС — из `/rom`. Цель `zynq` получает признак `nand` (патч `0400`), после чего доступны штатные `ubi-utils`/`nand-utils` из ядра OpenWrt | без `ubiformat`/`ubiattach` установка в NAND невозможна; в 25.12 эти пакеты есть, но скрыты за `@NAND_SUPPORT`, которого у zynq не было. Копия `mtd-utils` из второго репозитория не понадобилась — конфликтует с ядром («Not overriding core package») | `packages/nand-install/`, `target-patches/0400_zynq-nand-feature.patch`, `configs/zynq_antminer_s9.config` | сделано |
| 41 | 2026-11-24 | конфигурация | Включены `CONFIG_KERNEL_SND`, `SND_SOC`, `SND_SOC_ADI`, `SND_SOC_ADI_AXI_I2S`, `SND_SIMPLE_CARD`, `SND_SOC_SPDIF` | в конфигурации ядра не было ALSA SoC: без этого узлы DTS бесполезны — карта `audio` не появится | `configs/zynq_antminer_s9.config` | сделано |

## Планируемые изменения

| № | Область | Что | Зачем | Статус |
|---|---|---|---|---|
| P1 | сборка | Бэкпорт поддержки платы в 25.12 (без U-Boot) | в 25.12.6 поддержки Antminer S9 нет | **сделано** (патч `0001`) |
| P2 | device tree | `0100_zynq-antminer-s9-pl.patch` — узлы `fm-radio`, `axi_i2s_adi`, `sound`, `audio_clock`. Источник узлов — DTB из образа автора (`sdr_fm_receiver` v1.0.0): адреса `fm-radio@43c60000` и `axi_i2s_adi@43c00000` совпадают с нашим `design_1.bd`; DTS второго репозитория автора описывает PL майнера и не подходит | V4L2-драйвер и ALSA без DTS-узлов не работают | планируется (пересборка образа, Vivado не нужен) |
| P3 | загрузка | `system.bit.gz` в FAT + `fpga loadb`; готовый загрузчик | образ без битстрима не поднимет PL | **сделано**: `bootloader/`, `bitstream/`, патч `0200` |
| P4 | CI | Сборка и слежение за релизами | сборка силами GitHub | **сделано** (скелет) |
| P5 | пакеты | Адаптация feed-пакетов под kernel 6.12 / musl / apk | исходные пакеты собраны под более старое ядро и opkg | **в работе**: `csdr` исправлен, остальное проверяется сборкой |
| P6 | битстрим | `bitstream/system.bit.gz` — результат Vivado с выводом I2S на J1 | без него нет внешнего I2S | **частично**: лежит штатный битстрим автора |
| P7 | NAND | Разделы NAND в дереве устройства и `/sbin/nand_install` по шаблону из `zevs44/antminer-l3-openwrt` (`docs/14-NAND-Install-Pattern.md`): проверка сигнатур и размеров, `mtd verify`, `sync`, двухэтапная запись (сначала система, потом загрузчик), метка dry-run с ограничением по времени | установка системы с SD во время работы платы; в исходном скрипте автора загрузчик пишется до проверки. Шаблон даёт порядок проверок и защиту от повторной записи | `packages/nand-install/` | сделано |
| P8 | NAND | `--dry-run` с меткой, лог в `/tmp`, отказ при нехватке места, `flock` | ошибка на загрузчике окирпичивает плату; журнал нужен для разбора сбоя | сделано |
| P9 | NAND | Кнопка в LuCI: `luci-app-commands` с предупреждением либо собственное приложение с подтверждением ввода и `flock` | запуск установки без консоли | планируется (скрипт готов) |
| P10 | NAND | Корневая ФС пишется из `/rom` (read-only squashfs), а не копированием работающей системы через `tar`; готовый `rootfs.ubi` не нужен | копия работающей ФС зависит от её состояния и захватывает SD-карту; `/rom` — исходная система без overlay | `packages/nand-install/files/nand_install` | сделано |

Разбор исходного скрипта автора, найденные дефекты и предложения по улучшению —
в документе проекта `13_nand_install.md` (вне этого репозитория).

## Что не меняется

- `README.md`, `README.ru.md` — текст автора остаётся как есть; наши замечания живут здесь,
  а не в его документе.
- `vivado_2023.2/` — исходный проект не правится на месте; наши изменения вносятся скриптами
  и отдельными копиями.
- `packages/` — правится только при необходимости; каждое изменение попадает в журнал.

## Как посмотреть различия

```bash
git log --oneline upstream/main..main      # наши коммиты поверх автора
git diff upstream/main --stat              # какие файлы затронуты
git diff upstream/main                     # полный дифф
```

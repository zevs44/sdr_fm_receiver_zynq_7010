# Отличия форка от исходного репозитория

> **Форк:** https://github.com/zevs44/sdr_fm_receiver_zynq_7010
> **Родитель:** https://github.com/alexsys87/sdr_fm_receiver_zynq_7010
> **Актуально на:** 2026-11-26

Это описание **текущей разницы** между двумя репозиториями, а не история
разработки: что взято у автора, что изменено и что добавлено. Форк содержит
только дельты и специфику под свои требования.

## Коротко

Форк = **репозиторий автора + слой сборки OpenWrt 25.12 + специфика под
PCM5102**. Ни один файл автора не удалён. Всё, что не требовало изменений,
взято у автора как есть: его сборка проверена на плате.

## 1. Взято у автора без изменений

| Что | Откуда |
|---|---|
| Проект Vivado: блок-дизайн, RTL, IP, `sdr_recv.xdc` | `vivado_2023.2/` |
| Все 19 пакетов | `packages/` (изменены только четыре файла — раздел 2) |
| Описание проекта | `README.md`, `README_ru.md` |
| Загрузчик `boot.bin`, `u-boot.img`, `uboot_env.bin` | релиз автора, папка `bootloader/` |
| Штатный битстрим | релиз автора, `bitstream/system.bit.gz` |

В репозитории автора бинарных файлов нет, поэтому загрузчик и битстрим взяты
из его релиза и лежат в форке с описанием происхождения и контрольными
суммами.

## 2. Изменённые файлы автора

| Файл | Изменение | Причина |
|---|---|---|
| `packages/csdr/Makefile` | версия `2019-02-27` → `2019.02.27`, исходная дата в `PKG_SOURCE_DATE` | apk в OpenWrt 25.12 отвергает версии с несколькими дефисами |
| `packages/kmod-zynq-fm-radio/src/zynq_fm_radio.c` | `no_llseek` → макрос `ZYNQ_FM_NO_LLSEEK` (`noop_llseek` на ядре ≥ 6.0) | в Linux 6.0 функция удалена |
| `packages/luci-app-mympd/Makefile` | уточнён комментарий о конфликте `/etc/init.d/mpd` | под apk конфликт двух пакетов на один путь — ошибка установки, а не предупреждение |
| `packages/luci-app-audiosrc/` (`root/etc/config/audiosrc`, `init.d`, rpcd, view) | исходный выбор источника — `mympd` вместо `radio` | на этой плате основной сценарий — воспроизведение из myMPD; выбор пользователя сохраняется, меняется только исходное значение |

## 3. Добавленный слой сборки OpenWrt

### 3.1 Патчи к дереву OpenWrt (`target_patches/`)

| Патч | Что делает | Зачем |
|---|---|---|
| `0001_openwrt_backport_antminer_s9.patch` | бэкпорт поддержки платы из upstream (`e050bb7`): `board.d/02_network`, устройство в `image/Makefile`, два DTS-патча. Изменения `uboot-zynq` исключены — загрузчик поставляется готовым | в ветке 25.12 платы нет |
| `0200_zynq_sdcard_bitstream_and_uenv.patch` | в `Build/zynq-sdcard` файлы FAT берутся из нашей папки `antminer/`: `boot.bin`, `u-boot.img`, `uEnv.txt`, плюс `system.bit.gz` и `uboot_env.bin`; переменные образа объявлены в `DEVICE_VARS` | штатный образ не грузит битстрим и наш `uEnv.txt` |
| `0300_zynq_antminer_s9_pl.patch` | узлы PL в DTS: `axi_i2s_adi@43c00000`, `fm-radio@43c60000`, `audio_clock`, `sound` | без узлов нет `/dev/radio0` и ALSA-карты |
| `0310_zynq_antminer_s9_nand.patch` | таблица разделов NAND в DTS (`boot`, `uboot`, `fpga`, `uboot_env`, `kernel`, `rootfs`), раскладка автора | без меток `/proc/mtd` пуст и `nand_install` не находит разделы |
| `0400_zynq_nand_feature.patch` | добавляет признак `nand` в `FEATURES` цели | открывает штатные `ubi-utils`/`nand-utils`, скрытые за `@NAND_SUPPORT` |
| `0500_zynq_sound_config.patch` | включает в конфиге ядра `CONFIG_SOUND` и `CONFIG_SND*`: ALSA SoC, ADI AXI-I2S, simple-card, SPDIF | без `CONFIG_SOUND` kconfig отбрасывает все `SND*` без сообщения об ошибке — звука в образе нет |
| `0600_zynq_nand_config.patch` | включает `CONFIG_MTD_RAW_NAND`, `CONFIG_MTD_NAND_PL35X`, `CONFIG_PL353_SMC`, `CONFIG_MTD_UBI`, `CONFIG_UBIFS_FS` | драйвер NAND скрыт за `MTD_RAW_NAND`; без UBI/UBIFS `nand_install` не смонтирует том |

### 3.2 Конфигурация и файлы образа

- `configs/zynq_antminer_s9.config` — цель `zynq/generic`, устройство
  `bitmain_zynq-antminer-s9`, squashfs, пакеты автора и необходимые дополнения
  (LuCI с темой и TLS, `i2c-tools`, `mympd`, `nand-install`, утилиты mtd/ubi).
- `files/uEnv.txt` — загрузочное окружение U-Boot: `fpga loadb` и
  `clk_ignore_unused`.
- `files/etc/uci-defaults/99_antminer_setup` — первичная настройка при первой
  загрузке: сеть, IPv6, время, MAC и hostname (раздел 3.6).
- `files/etc/fw_env.config` — где `fw_printenv` ищет окружение U-Boot: раздел
  NAND `uboot_env` (`/dev/mtd3`, смещение 0, размер 0x80000). Без файла
  `uboot-envtools` (входит в `DEFAULT_PACKAGES` цели) печатает ошибки в журнал.
- `files/myscripts/run-diag-board.sh` — диагностика платы в каталоге
  `/myscripts`. Файлы кладутся в образ оверлеем `files/`; права `0777` на
  каталог и скрипт ставит uci-defaults при первой загрузке, в образе они не
  выставляются (разбор режимов на сборке хрупок, а в рантайме права проверяет
  сама диагностика). Если uci-defaults не сработал — `chmod 777 /myscripts` на
  плате. Установка только добавляющая: файлы пользователя не удаляются.
- `files/etc/uci-defaults/91_board_scripts` — кнопки `DIAG: проверка платы`
  в LuCI и повторная проверка прав каталога.
- `.openwrt-version` — единственный источник версии OpenWrt.

### 3.3 Скрипты

| Скрипт | Назначение |
|---|---|
| `scripts/apply.sh` | накладывает патчи (с проверкой), копирует загрузчик/битстрим/`uEnv.txt`, копирует `files/etc` в корневую файловую систему, подключает фид автора, ставит все фиды, убирает дубль `/etc/init.d/mpd` из фида, применяет конфиг и `defconfig` |
| `scripts/check_config.sh` | сверяет запрошенный конфиг с итоговым (пакеты, которые `defconfig` исключил) и проверяет обязательные опции ядра в `target/linux/zynq/config-6.*` (имя файла ищется шаблоном — переживает смену версии ядра) |
| `scripts/verify_image.sh` | проверяет образ: разделы, файлы FAT, сигнатуры, содержимое rootfs, узлы PL и разделы NAND в DTB, `/sbin/nand_install`, `/myscripts/run-diag-board.sh`, первичную настройку, `/etc/fw_env.config` |
| `scripts/update_expected_artifacts.sh` | пересчитывает `scripts/expected_artifacts.sha256` по загрузчику, битстриму и `uEnv.txt`; убирает ручное обновление хешей |
| `scripts/qemu_smoke.sh` | загружает образ в QEMU (`xilinx-zynq-a9`), ждёт init, затем через консоль запускает `/myscripts/run-diag-board.sh --profile qemu` и требует `RESULT: PASS` |
| `scripts/expected_artifacts.sha256` | контрольные суммы загрузчика, битстрима и `uEnv.txt` |

### 3.4 CI (GitHub Actions)

| Workflow | Назначение |
|---|---|
| `01_build.yml` | единый конвейер из четырёх пронумерованных шагов: `01 lint` → `02 build` → `03 qemu smoke` → `04 release`. Шаги связаны зависимостями (`build` после `lint`; `release` — `needs: qemu` c условием `!cancelled()`, потому что на теге шаги 02–03 пропущены). Сборка образа (линт, проверки входов и конфига, `make -k world`, диагностика падений, проверка образа, QEMU, артефакты), QEMU-проверка в том же прогоне без пересборки и публикация GitHub Release по тегу `v*` из успешного прогона (файл образа, SHA-256, список изменений). Шаг `03 qemu smoke` запускает диагностику платы и валит прогон без `RESULT: PASS` — релиз берёт только проверенный образ. Тег — версия образа проекта (`v1.1.0`, `v1.2.0`), версия OpenWrt выводится заголовком в описании релиза (`## OPENWRT 25.12.6`) |
| `80_cleanup_runs.yml` | раз в сутки удаляет старые успешные прогоны (по умолчанию — watcher, старше 10 дней) |
| `10_manual_qemu_check.yml` | ручная перепроверка готового образа: берёт артефакт `sdcard-*` из указанного прогона и запускает `scripts/qemu_smoke.sh` из текущей ветки. Нужна, когда изменились проверки, а пересобирать образ не требуется; конвейер не затрагивает |
| `11_inspect_artifact.yml` | ручной осмотр образа из прогона: права и состав `rootfs` |
| `81_watch_upstream.yml` | раз в 6 часов проверяет новые стабильные релизы OpenWrt; перед закреплением версии проверяет, что патчи на неё ложатся |

### 3.5 Документация

- `docs/` — аудиопотоки, распиновка колодок, пересборка битстрима, установка
  в NAND, проверка платы (`04_board_check.md` и `.ru.md`) — на английском и русском;
- `build.md` — сборка образа и проверки;
- `fork_changes.md` — этот документ.

### 3.6 Первичная настройка при загрузке

Скрипт `files/etc/uci-defaults/99_antminer_setup` попадает в образ и
выполняется один раз при первой загрузке, после чего OpenWrt удаляет файл.

| Что настраивается | Значение |
|---|---|
| Сеть | единственный интерфейс `eth0` по DHCP; `wan`, `wan6`, `br-lan` и все `device` удалены и созданы заново; `packet_steering = 1` (два ядра) |
| IPv6 | выключен: `dhcpv6`, `ra`, `ula_prefix`, `delegate`; служба `odhcpd` отключена |
| Время | `Europe/Moscow`, `MSK-3`; NTP-серверы заданы явно: `0.ru.pool.ntp.org`, `1.ru.pool.ntp.org`, `0.europe.pool.ntp.org` |
| MAC | локально администрируемый (`02:…`), генерируется при первой загрузке, хранится в `/etc/antminer-mac` |
| Hostname | `owrt-zynq7010-XXXX`, где `XXXX` — последние 4 шестнадцатеричных знака MAC |

Проверка на плате: `uci show network`, `uci get system.@system[0].hostname`,
`cat /etc/antminer-mac`, `ip -4 addr show eth0`.

## 4. Добавленные пакеты

### `nand-install`

Установка OpenWrt с SD-карты во внутреннюю NAND: `/sbin/nand_install`.

**Идея автора** — скрипт из его второго проекта
[`Antminer_S9_OpenWRT`](https://github.com/alexsys87/Antminer_S9_OpenWRT).
Сохранён порядок записи (разделы NAND по имени, затем UBI для корневой файловой системы) и
добавлены защиты:

- проверка источника загрузки (не из NAND) и разделов `/proc/mtd`;
- проверка сигнатур и размеров файлов;
- `--dry-run` с меткой на 10 минут: запись без свежего пробного запуска
  запрещена;
- подтверждение словом `INSTALL`;
- `flock` от параллельного запуска;
- журнал в `/tmp/nand_install.log`;
- два этапа: сначала система, потом загрузчик;
- проверка чтением (`mtd verify`);
- корневая файловая система копируется из `/rom` (read-only squashfs), а не из работающей
  системы;
- две команды в LuCI через `luci-app-commands` (раздел «Система → Команды»):
  пробный запуск и установка; установка работает только со свежей меткой
  пробного запуска.

## 5. Специфика под PCM5102 (вне этого репозитория)

Битстрим в `bitstream/` — штатный, из релиза автора. Своя сборка делается
локально в Vivado скриптом `01_rebuild_i2s_out.tcl` из рабочей папки проекта и
в репозиторий не входит:

- выход I2S для PCM5102 — на колодку **J6** (U14/U15/U18);
- RF-антенна приёмника — на **J8** (V16/W16);
- выход FM-передатчика — на **J8** (Y19).

## 6. Что не меняется

- `README.md`, `README_ru.md` — текст автора;
- `vivado_2023.2/` — проект не правится на месте;
- `packages/` — только четыре файла из раздела 2.

## 7. Как посмотреть различия

```bash
git log --oneline upstream/main..main      # коммиты поверх автора
git diff upstream/main --stat              # затронутые файлы
git diff upstream/main                     # полный дифф
```

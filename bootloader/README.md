# Загрузчик

Готовые двоичные файлы загрузчика не собираются в этом репозитории, а поставляются
как артефакты — так же, как битстрим.

## Почему не собираем U-Boot

Пакет `uboot-zynq` в OpenWrt 25.12 собирает **U-Boot 2019.07**, а поддержка этой
платы в upstream написана под U-Boot 2026.04 (ветка master). Сборка 2019.07 для
варианта `antminer-s9` не собирается, и починка потребовала бы бэкпорта всего пакета.

Тот же автор в своём репозитории
[alexsys87/Antminer_S9_OpenWRT](https://github.com/alexsys87/Antminer_S9_OpenWRT)
поступает так же: кладёт готовые `boot.bin` и `u-boot.img` в `staging_dir/image`
и копирует их в образ, не собирая загрузчик.

## Что лежит

| Файл | Размер | SHA-256 | Что это |
|---|---|---|---|
| `boot.bin` | 79 263 | `950d19c6e5bfd9d8…` | FSBL: инициализация PS, поиск и загрузка U-Boot |
| `u-boot.img` | 915 008 | `f86c48050993d6af…` | U-Boot (FIT, `bootm`, `fpga loadb`, чтение `uEnv.txt`) |
| `uboot_env.bin` | 524 288 | `a5811783049db88f…` | сохранённое окружение U-Boot с командой `uenvcmd` |

Источник — релиз `v1.0.0` (2026-08-16) репозитория
[alexsys87/sdr_fm_receiver_zynq_7010](https://github.com/alexsys87/sdr_fm_receiver_zynq_7010),
FAT-раздел образа `openwrt-zynq-s9-antminer_s9-ext4-sdcard.img.xz`.

`boot.bin` совпадает байт-в-байт с версией из overlay-сборки автора
(`Antminer_S9-boot.bin`), то есть FSBL у обоих его проектов один.

## Как это попадает в образ

1. `scripts/apply.sh` копирует три файла и `files/uEnv.txt` в `<openwrt>/antminer/`.
2. Патч `0200` подменяет источники в `Build/zynq-sdcard` на `$(TOPDIR)/antminer/…`.
3. Образ получает FAT-раздел с `boot.bin`, `u-boot.img`, `uEnv.txt`,
   `uboot_env.bin`, `system.bit.gz`, `fit.itb`.

## Как заменить

Если понадобится собрать загрузчик самостоятельно, помните: FSBL для этой платы
строится в Vitis под конкретную PS-конфигурацию (DDR, клоки, MIO), а не в OpenWrt.
Проверенный FSBL проще сохранить.

Порядок замены: положить новый файл, обновить таблицу выше (размер и SHA-256),
закоммитить, записать изменение в `fork_changes.md`, пересобрать образ.

## Проверка

Из корня репозитория:

```bash
# контрольные суммы всех входных двоичных файлов сразу
sha256sum -c scripts/expected_artifacts.sha256

# либо только загрузчик
sha256sum bootloader/*
```

`boot.bin` начинается с векторов ARM (`fe ff ff ea` ×4), а не с заголовка Xilinx:
это готовый FSBL, а не bit-файл. Достоверная проверка — контрольная сумма;
машиночитаемый список — `scripts/expected_artifacts.sha256` в корне репозитория.

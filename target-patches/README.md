# Патчи к дереву OpenWrt

Накладываются по порядку имён файлов скриптом `scripts/apply.sh` на чистое дерево
`openwrt/openwrt`, склонированное по тегу из `.openwrt-version`.

| Файл | Что делает | Источник |
|---|---|---|
| `0001_openwrt-backport-antminer-s9.patch` | Поддержка платы Bitmain Antminer S9: `uboot-zynq` (сборка U-Boot + патч SD-boot), `board.d/02_network`, устройство в `image/Makefile`, два DTS-патча (PS) | upstream commit `e050bb7`, автор Zoltan HERPAI |
| `0200_zynq-sdcard-bitstream-and-uenv.patch` | В `Build/zynq-sdcard`: копирование `system.bit.gz` в FAT-раздел и подмена `uEnv.txt` на наш (с `fpga loadb`). Свои переменные образа (`BOOTBIN_FILE` и др.) добавлены в `DEVICE_VARS` — без этого `Device/Export` берёт значение последнего описанного устройства | наш патч |

## Почему бэкпорт, а не сборка из master

Поддержка платы появилась в OpenWrt **2026-06-14**, уже после выхода ветки 25.12.
Собирать из master — значит зависеть от нестабильной ветки. Бэкпорт проверен: патч
`0001` ложится на файлы ветки `openwrt-25.12` без конфликтов.

## Что в бэкпорте есть и чего нет

Есть — только PS: Ethernet, NAND, SD, UART, LED, память.

Нет — всё, что делает плату FM-приёмником:

- узлов PL в device tree (`fm-radio`, `axi_i2s_adi`, `sound`);
- загрузки битстрима;
- наших пакетов (они подключаются как feed, а не патчем).

Узлы PL добавляются отдельным патчем `0100_*` — он появится на этапе 3.

## Как добавить патч

1. Сделать изменение в чистом дереве OpenWrt нужной версии.
2. `git diff > ../target-patches/NNNN_короткое-имя.patch` (нумерация — по порядку применения).
3. Проверить: `cd openwrt && git apply --check -p1 ../target-patches/NNNN_*.patch`.
4. Записать изменение в `FORK_CHANGES.md`.

## Если патч перестал ложиться

`apply.sh` останавливается с кодом 1 и печатает имя патча. Это происходит при смене
версии OpenWrt. Порядок действий:

```bash
cd openwrt
git apply --check -p1 ../target-patches/0001_openwrt-backport-antminer-s9.patch
# посмотреть, какие строки не совпали, и пересобрать патч на новой базе
```

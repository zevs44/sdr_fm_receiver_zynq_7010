/* ============================================================================
 *  fmtx -- управление FM-передатчиком fm_transmitter_axi (Zynq-7010)
 *
 *  Прямой доступ к AXI4-Lite регистрам через mmap /dev/mem, без драйвера.
 *  Ранее называлось fm_ctrl / пакет fm-ctrl.
 *
 *  КАРТА РЕГИСТРОВ (сверена с RTL-шапкой fm_transmitter_axi.v):
 *    0x00 CTRL          RW  bit0 TX_EN, bit1 STEREO_EN, bits3:2 PREEMPH
 *                           (0=off, 1=50us, 2=75us, 3 ведёт себя как 50us)
 *    0x04 FTW_LOWER     RW  FTW[31:0],  FTW = FREQ_HZ / CLK_RF_HZ * 2^40
 *    0x08 FTW_UPPER     RW  FTW[39:32] в [7:0]
 *    0x0C DEV_GAIN      RW  беззнаковый Q8.8, только [15:0]
 *                           peak_dev = mpx_peak * (GAIN/256) * CLK_RF / 2^40
 *    0x10..0x40 RDS0..12 RW 416-битный сдвиговый регистр (13 слов);
 *                           запись 0x40 -- КОММИТ кадра целиком
 *    0x44 MPX_FIFO_STAT RO  только при MPX_EXPORT_ENABLE=1;
 *                           [16]=overflow (сбрасывается чтением ЭТОГО регистра)
 *    0x48 MPX_FIFO_DATA RO  чтение = pop одного сэмпла (здесь не используется)
 *    0x4C MPX_SHIFT     RW  сдвиг вправо перед насыщением до int16 (reset 8)
 * ========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <time.h>

#define FM_BASE_DEFAULT 0x43C90000UL
#define REG_SPAN        0x50UL      /* 0x00..0x4C включительно */
#define CLK_RF_HZ       250000000ULL /* clk_rf в fm_transmitter_axi ретаймлен под 250 МГц */
#define TWO_POW_40      1099511627776.0

/* Индексы AXI регистров (в 32-битных словах) */
#define REG_CTRL          0   /* 0x00 */
#define REG_FTW_L         1   /* 0x04 */
#define REG_FTW_U         2   /* 0x08 */
#define REG_DEV_GAIN      3   /* 0x0C (Q8.8 gain) */
#define REG_RDS_BASE      4   /* 0x10 */
#define REG_RDS_WORDS     13  /* 0x10..0x40 */
#define REG_MPX_STAT      17  /* 0x44 (RO, чтение сбрасывает overflow) */
#define REG_MPX_DATA      18  /* 0x48 (RO, чтение = pop) -- намеренно не читаем */
#define REG_MPX_SHIFT     19  /* 0x4C */

/* RDS константы */
#define RDS_PI_DEFAULT 0x8000 /* Идентификатор станции по умолчанию (перекрывается -P) */
#define RDS_POLY       0x5B9  /* Полином для расчета CRC */

#define RDS_PS_LEN     8      /* Длина названия станции (Group 0B) */
#define RDS_RT_LEN     64     /* Длина RadioText (Group 2A, 16 сегментов по 4 символа) */

/* Регистр 0x0C -- НЕ сдвиг, а беззнаковый Q8.8 множитель (см. DEVIATION
 * в шапке fm_transmitter_axi.v). Опция -d принимает девиацию в кГц, которую
 * даёт композит полной шкалы, и сама считает множитель. */
#define DEV_GAIN_MAX   65535U            /* 16 бит */
#define MPX_FULL_SCALE 8388607.0         /* пик композита, +/-2^23-1          */
#define PILOT_FRACTION 0.1126            /* уровень пилота, 3688/32768         */

/* Выше этого композит уезжает за пределы, которые приёмник способен
 * демодулировать: при 250 кГц дискретизации однозначно берётся максимум
 * +/-125 кГц девиации. Измерено в эфире: старый DEV_SHIFT=8 (488 кГц полной
 * шкалы) не давал вообще ничего, 5 (61 кГц) -- пилот 6.87 кГц и 100% RDS. */
#define DEV_KHZ_SANE   80.0
#define DEV_KHZ_MIN    10.0              /* ниже этого почти наверняка старое
                                            значение сдвига, а не килогерцы   */

/* Границы FM-диапазона -- только для предупреждения; сам передатчик
 * ограничен лишь разрядностью FTW. */
#define BAND_MHZ_LO    76.0
#define BAND_MHZ_HI    108.0

/* MPX_SHIFT: арифметический сдвиг, поле узкое, ограничиваем разумным 0..31. */
#define MPX_SHIFT_MAX  31

/* Сколько ждать между кадрами в режиме ротации: ПЛИС перезагружает кадр
 * каждые 416/1187.5 = 350.3 мс, спим чуть дольше, чтобы гарантированно не
 * подменить кадр дважды за один цикл. */
#define RT_FRAME_MS    360

/* REG_FTW_U хранит только старшие 8 бит 40-битного FTW. Всё, что выше,
 * записать физически некуда, поэтому частота ограничена сверху величиной,
 * при которой (ftw >> 32) ещё помещается в байт. */
#define FTW_UPPER_MAX 0xFFULL

/* Максимум кадров в ротации: 1 PS + до 4 кадров RadioText + 1 ECC. */
#define MAX_FRAMES 6

/* Путь к памяти. Переопределяется переменной окружения FMTX_MEM_DEV --
 * нужно только для offline-тестов (подставляется обычный файл вместо
 * /dev/mem), в рабочем режиме не используется. */
#define MEM_DEV_DEFAULT "/dev/mem"

/* Функция вычисления 10-битной контрольной суммы (Syndrome) и добавления Offset */
static uint32_t make_rds_block(uint16_t data, uint16_t offset) {
    uint32_t block = (uint32_t)data << 10;
    uint32_t poly = (uint32_t)RDS_POLY << 15;

    /* Деление по модулю 2 */
    for (int i = 25; i >= 10; i--) {
        if (block & (1U << i)) {
            block ^= poly;
        }
        poly >>= 1;
    }

    uint32_t crc = block & 0x3FF;
    return (((uint32_t)data << 10) | (crc ^ offset)); /* 26-битный блок */
}

/* ── Сборка кадров RDS ────────────────────────────────────────────────────
 * В сдвиговый регистр ПЛИС помещается ровно 416 бит = 4 группы по 104. Кадр
 * повторяется в эфире каждые 350.3 мс. Отсюда два режима:
 *   - PS (группа 0B) укладывается целиком: 4 группы = 4 сегмента = 8 символов;
 *   - RadioText (группа 2A) требует до 16 сегментов, то есть до 4 кадров, и
 *     ECC (группа 1A) тоже требует отдельного кадра -- поэтому и то, и другое
 *     передаётся только в режиме демона, чередуясь с кадрами PS.
 */

static void pack_blocks(const uint32_t blocks[16], uint32_t *out_words) {
    uint8_t bitstream[416];
    int bit_idx = 0;

    for (int b = 0; b < 16; b++) {
        for (int i = 25; i >= 0; i--) {
            bitstream[bit_idx++] = (uint8_t)((blocks[b] >> i) & 1);
        }
    }

    /* Упаковываем 416 бит в 13 32-битных регистров для AXI.
     * ПЛИС читает бит 415 первым, поэтому bitstream[0] должен попасть
     * в 31-й бит 12-го регистра. */
    for (int i = 0; i < REG_RDS_WORDS; i++) out_words[i] = 0;

    for (int i = 0; i < 416; i++) {
        if (bitstream[i]) {
            /* 1U, не 1: при i%32==0 сдвиг 1<<31 -- это переполнение знакового
             * int, то есть неопределённое поведение. */
            out_words[12 - (i / 32)] |= (1U << (31 - (i % 32)));
        }
    }
}

/* Группа 0B: PI / служебные биты / PI повторно / два символа PS */
static void build_group_0b(uint32_t *blk, uint16_t pi, uint8_t pty, int stereo,
                           int seg, const unsigned char *ps) {
    /* Раньше блок B собирался как константа 0x0808 | grp, из-за чего бит DI
     * (bit 2) всегда оставался нулём.
     *
     * DI -- это НЕ одно поле, а четыре отдельных флага, передаваемых по
     * одному на сегмент, номер сегмента выбирает который именно:
     *   сегмент 0 -> d3 = динамический PTY
     *   сегмент 1 -> d2 = компрессия
     *   сегмент 2 -> d1 = artificial head
     *   сегмент 3 -> d0 = СТЕРЕО (1) / моно (0)
     * С нулём во всех четырёх станция формально объявляла себя моно,
     * даже когда пилот-тон излучался. */
    uint8_t di_bit = (seg == 3) ? (stereo ? 1 : 0) : 0;

    uint16_t b = (uint16_t)((0x0u << 12) |                      /* group type 0 */
                            (1u   << 11) |                      /* version B    */
                            (0u   << 10) |                      /* TP = 0       */
                            (((uint32_t)pty & 0x1F) << 5) |
                            (0u   <<  4) |                      /* TA = 0       */
                            (1u   <<  3) |                      /* M/S = 1 (Music) */
                            ((uint32_t)di_bit << 2) |
                            ((uint32_t)seg & 0x3));

    blk[0] = make_rds_block(pi, 0x0FC);   /* Offset A  */
    blk[1] = make_rds_block(b,  0x198);   /* Offset B  */
    blk[2] = make_rds_block(pi, 0x350);   /* Offset C' (0B: PI повторно) */
    blk[3] = make_rds_block((uint16_t)(((uint16_t)ps[seg * 2] << 8) | ps[seg * 2 + 1]),
                            0x1B4);       /* Offset D  */
}

/* Группа 1A, Variant 0: Extended Country Code (ECC). Раскладка блока 3
 * (Slow Labelling Code) для Variant 0 -- b15 LA=0 (не связываем с другой
 * программой), b14:12 variant=000 (ECC), b11:8 EPP=0000 (paging не
 * используется), b7:0 сам ECC. При LA=0 и EPP=0 всё слово блока 3
 * численно равно ECC.
 *
 * Блок D -- Programme Item Number, которым этот проект не управляет;
 * 0x0000 читается приёмником как "PIN не используется" (день 0 невалиден,
 * реальные дни начинаются с 1). */
static void build_group_1a(uint32_t *blk, uint16_t pi, uint8_t pty, uint8_t ecc) {
    uint16_t b = (uint16_t)((0x1u << 12) |                      /* group type 1 */
                            (0u   << 11) |                      /* version A    */
                            (0u   << 10) |                      /* TP = 0       */
                            (((uint32_t)pty & 0x1F) << 5) |
                            (0u   <<  0));                      /* paging: не используется */

    blk[0] = make_rds_block(pi,            0x0FC); /* Offset A */
    blk[1] = make_rds_block(b,             0x198); /* Offset B */
    blk[2] = make_rds_block((uint16_t)ecc, 0x168); /* Offset C (version A -> данные) */
    blk[3] = make_rds_block(0x0000,        0x1B4); /* Offset D: PIN не используется */
}

/* Группа 2A: PI / служебные биты / 4 символа RadioText (2 в блоке C, 2 в D).
 * Версия A, поэтому блок C несёт текст и идёт со смещением C, а не C'. */
static void build_group_2a(uint32_t *blk, uint16_t pi, uint8_t pty, int ab,
                           int seg, const unsigned char *rt) {
    uint16_t b = (uint16_t)((0x2u << 12) |                      /* group type 2 */
                            (0u   << 11) |                      /* version A    */
                            (0u   << 10) |                      /* TP = 0       */
                            (((uint32_t)pty & 0x1F) << 5) |
                            ((uint32_t)(ab ? 1 : 0) << 4) |     /* A/B flag     */
                            ((uint32_t)seg & 0xF));

    blk[0] = make_rds_block(pi, 0x0FC);   /* Offset A */
    blk[1] = make_rds_block(b,  0x198);   /* Offset B */
    blk[2] = make_rds_block((uint16_t)(((uint16_t)rt[seg * 4 + 0] << 8) | rt[seg * 4 + 1]),
                            0x168);       /* Offset C */
    blk[3] = make_rds_block((uint16_t)(((uint16_t)rt[seg * 4 + 2] << 8) | rt[seg * 4 + 3]),
                            0x1B4);       /* Offset D */
}

/* Кадр ECC: сегменты PS 0,1,2 (без сегмента 3 -- на нём в build_group_0b
 * сидит бит DI/стерео, который на этой фазе ротации просто на секунду не
 * обновится, что не проблема -- он приходит на других фазах) плюс одна
 * группа 1A с ECC в четвёртом слоте. PS в этом кадре временно неполон:
 * это нормально, кадр стоит лишь на одной фазе ротации, а следующая же
 * фаза PS -- снова полный. */
static void frame_ecc(const unsigned char *ps, uint16_t pi, uint8_t pty,
                      int stereo, uint8_t ecc, uint32_t *out_words) {
    uint32_t blocks[16];
    for (int g = 0; g < 3; g++)
        build_group_0b(&blocks[g * 4], pi, pty, stereo, g, ps);
    build_group_1a(&blocks[12], pi, pty, ecc);
    pack_blocks(blocks, out_words);
}

/* Кадр из 4 групп 0B: всё название станции целиком */
static void frame_ps(const unsigned char *ps, uint16_t pi, uint8_t pty,
                     int stereo, uint32_t *out_words) {
    uint32_t blocks[16];
    for (int g = 0; g < 4; g++)
        build_group_0b(&blocks[g * 4], pi, pty, stereo, g, ps);
    pack_blocks(blocks, out_words);
}

/* Кадр из 4 групп 2A: сегменты base..base+3 RadioText (16 символов) */
static void frame_rt(const unsigned char *rt, uint16_t pi, uint8_t pty,
                     int ab, int base_seg, uint32_t *out_words) {
    uint32_t blocks[16];
    for (int g = 0; g < 4; g++)
        build_group_2a(&blocks[g * 4], pi, pty, ab, (base_seg + g) & 0xF, rt);
    pack_blocks(blocks, out_words);
}

static void fill_ps(unsigned char *ps, const char *name) {
    /* Работаем с unsigned char: при знаковом char (x86, а также ARM с
     * -fsigned-char) любой байт со старшим битом расширялся знаком при
     * сборке слова блока, и блок RDS уезжал в мусор. */
    memset(ps, ' ', RDS_PS_LEN);
    for (int i = 0; i < RDS_PS_LEN && name[i] != '\0'; i++)
        ps[i] = (unsigned char)name[i];
}

/* Возвращает число кадров RadioText (1..4), реально нужных для этого текста.
 * Раньше всегда крутились все 4 кадра (16 сегментов), даже для текста в 10
 * символов -- то есть 8-фазный цикл ~2.9 с вместо 4-фазного ~1.4 с, и
 * половина эфирного времени уходила на передачу пробелов после CR. */
static int fill_rt(unsigned char *rt, const char *text) {
    size_t n = strlen(text);
    if (n > RDS_RT_LEN) n = RDS_RT_LEN;
    memset(rt, ' ', RDS_RT_LEN);
    memcpy(rt, text, n);
    /* Стандарт требует завершать текст короче 64 символов возвратом каретки,
     * иначе приёмник показывает хвост из пробелов до полной длины. */
    size_t used = n;
    if (n < RDS_RT_LEN) {
        rt[n] = 0x0D;
        used = n + 1;
    }
    int segs   = (int)((used + 3) / 4);        /* сегментов по 4 символа */
    int frames = (segs + 3) / 4;               /* кадров по 4 сегмента   */
    if (frames < 1) frames = 1;
    if (frames > 4) frames = 4;
    return frames;
}

static void print_usage(const char *prog) {
    printf("ZYNQ FM Transmitter Control (fmtx)\n");
    printf("Usage: %s [options]\n", prog);
    printf("  -f <freq>   Set frequency in MHz (e.g., 99.5)\n");
    printf("  -e <0|1>    Enable/Disable TX\n");
    printf("  -s <0|1>    Enable/Disable Stereo\n");
    printf("  -p <0-2>    Pre-emphasis (0=Off, 1=50us, 2=75us)\n");
    printf("  -d <kHz>    Peak deviation for a full-scale composite.\n");
    printf("              Register 0x0C is a Q8.8 gain, not a shift: this\n");
    printf("              option takes kHz and computes it. 60 puts the pilot at\n");
    printf("              the standard 6.75 kHz; above %.0f a 250 kHz receiver\n", DEV_KHZ_SANE);
    printf("              cannot demodulate the result.\n");
    printf("  -t \"TEXT\"   Set RDS Station Name / PS (up to %d chars)\n", RDS_PS_LEN);
    printf("  -R \"TEXT\"   Set RDS RadioText (up to %d chars). Needs -t and runs\n", RDS_RT_LEN);
    printf("              as a foreground daemon: RadioText needs up to 16 segments\n");
    printf("              but the hardware buffer holds only 4 groups, so frames of\n");
    printf("              PS and RadioText are rotated through it until Ctrl-C.\n");
    printf("              Only the frames the text actually needs are rotated.\n");
    printf("  -P <pi>     Set RDS PI code, 0..0xFFFF (default 0x%04X).\n", RDS_PI_DEFAULT);
    printf("              Accepts 0x-prefixed hex. Applied with -t.\n");
    printf("  -y <0-31>   Set RDS PTY (Programme Type). Applied with -t.\n");
    printf("  -C <ecc>    Set RDS Extended Country Code, 0..0xFF. Needs -t. The\n");
    printf("              hardware frame has no room left once PS fills it, so this\n");
    printf("              also runs as a rotation daemon like -R (alone: PS/ECC\n");
    printf("              alternate; combined with -R: ECC joins that rotation).\n");
    printf("  -m <0-%d>   Set MPX_SHIFT (0x4C, raw-MPX export scaling).\n", MPX_SHIFT_MAX);
    printf("  -M          Show raw-MPX FIFO status (0x44). Note: reading that\n");
    printf("              register clears its overflow flag, so this is not a\n");
    printf("              passive probe -- keep it out of -i for that reason.\n");
    printf("  -b <addr>   AXI base address (default 0x%08lX)\n", FM_BASE_DEFAULT);
    printf("  -i          Show current AXI register info (non-destructive)\n");
    printf("  -h          This help\n");
}

/* ── Разбор аргументов ──────────────────────────────────────────────────
 * Значения проверяются до открытия /dev/mem и до единой записи в регистры.
 * Иначе, например, "-e 1 -f 300" успевал бы включить несущую на мусорной
 * частоте прежде, чем дело дошло бы до ошибки. */

static int parse_long(const char *s, long *out) {
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0') return -1;
    *out = v;
    return 0;
}

/* База 0: принимает и 0x8000, и 32768. Нужна для -P/-C/-b, где
 * шестнадцатеричная запись естественнее. */
static int parse_ulong_auto(const char *s, unsigned long *out) {
    char *end;
    errno = 0;
    unsigned long v = strtoul(s, &end, 0);
    if (errno != 0 || end == s || *end != '\0') return -1;
    *out = v;
    return 0;
}

static int parse_bool(const char *s, int *out) {
    long v;
    if (parse_long(s, &v) != 0 || (v != 0 && v != 1)) return -1;
    *out = (int)v;
    return 0;
}

typedef struct {
    int      have_freq;   uint64_t ftw;    double freq_mhz;
    int      have_enable; int enable;
    int      have_stereo; int stereo;
    int      have_pre;    uint32_t pre;
    int      have_dev;    uint32_t dev_gain;  double dev_khz;
    int      have_rds;    const char *rds;
    int      have_rt;     const char *rt;
    int      have_pi;     uint16_t pi;
    int      have_pty;    uint8_t  pty;
    int      have_ecc;    uint8_t  ecc;
    int      have_mpxsh;  uint32_t mpx_shift;
    int      have_mpxst;
    int      have_info;
    unsigned long base;
} opts_t;

static int parse_freq(const char *arg, opts_t *o) {
    char *end;
    errno = 0;
    double freq_mhz = strtod(arg, &end);

    if (errno != 0 || end == arg || *end != '\0') {
        fprintf(stderr, "Error: '%s' is not a valid frequency\n", arg);
        return -1;
    }
    /* Приведение отрицательного double к uint64_t -- неопределённое
     * поведение, а не просто "большое число". */
    if (!(freq_mhz > 0.0)) {
        fprintf(stderr, "Error: frequency must be positive (got %g MHz)\n", freq_mhz);
        return -1;
    }

    /* Округление, а не отбрасывание: 87.9 * 1e6 в double -- это
     * 87899999.999999..., и (uint64_t) давал 87899999 Гц, то есть
     * систематический сдвиг на 1 Гц вниз почти на каждой частоте. */
    uint64_t freq_hz = (uint64_t)(freq_mhz * 1000000.0 + 0.5);

    /* ftw = freq_hz * 2^40 / CLK_RF_HZ
     *
     * Прямое freq_hz * 2^40 переполняет uint64_t для любой
     * реальной FM-частоты (например, 77 МГц -> ~8.5e19, а
     * UINT64_MAX ~1.8e19). Переполнение тихое, и в FTW
     * попадает мусор без какой-либо ошибки.
     *
     * Раскладываем 2^40 = 2^8 * 2^32 и считаем через
     * частное/остаток, чтобы каждое промежуточное значение
     * оставалось в пределах 64 бит. */
    uint64_t a = freq_hz << 8;          /* freq_hz * 256, влезает в 64 бит */
    uint64_t q = a / CLK_RF_HZ;
    uint64_t r = a % CLK_RF_HZ;
    uint64_t ftw = (q << 32) + ((r << 32) / CLK_RF_HZ);

    /* Раньше старший байт просто маскировался (& 0xFF), поэтому, скажем,
     * -f 300 молча уезжало в эфир на 50 МГц. */
    if ((ftw >> 32) > FTW_UPPER_MAX) {
        /* Предел -- вся 40-битная шкала, то есть почти ровно CLK_RF_HZ,
         * а не CLK_RF*255/256, как печаталось раньше. */
        fprintf(stderr,
                "Error: %g MHz is out of range (max %.6f MHz for clk_rf = %llu Hz)\n",
                freq_mhz,
                (double)CLK_RF_HZ * (TWO_POW_40 - 1.0) / TWO_POW_40 / 1e6,
                (unsigned long long)CLK_RF_HZ);
        return -1;
    }

    if (freq_mhz < BAND_MHZ_LO || freq_mhz > BAND_MHZ_HI) {
        fprintf(stderr, "Warning: %g MHz is outside the %.0f-%.0f MHz FM band\n",
                freq_mhz, BAND_MHZ_LO, BAND_MHZ_HI);
    }

    o->have_freq = 1;
    o->ftw       = ftw;
    o->freq_mhz  = freq_mhz;
    return 0;
}

/* Порядок по возрастанию адреса обязателен: 0x40 записывается последним и
 * служит коммитом -- ПЛИС защёлкивает весь кадр целиком именно по этой
 * записи, поэтому в эфир не попадает наполовину обновлённый кадр. Барьер
 * перед последним словом гарантирует, что компилятор не переупорядочит
 * запись коммита относительно остальных двенадцати. */
static void write_rds_frame(volatile uint32_t *fm_regs, const uint32_t *words) {
    for (int i = 0; i < REG_RDS_WORDS - 1; i++)
        fm_regs[REG_RDS_BASE + i] = words[i];
    __sync_synchronize();
    fm_regs[REG_RDS_BASE + REG_RDS_WORDS - 1] = words[REG_RDS_WORDS - 1];
}

static volatile sig_atomic_t stop_requested = 0;
static void on_signal(int sig) { (void)sig; stop_requested = 1; }

static void install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    /* Без SA_RESTART: nanosleep должен прерваться, чтобы цикл увидел флаг. */
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

/* Сон до абсолютного момента: раньше nanosleep отсчитывал 360 мс ПОСЛЕ
 * пересборки кадра, поэтому фактический период был 360 мс + время работы и
 * медленно уползал относительно 350.3 мс ПЛИС. */
static void sleep_until(struct timespec *deadline, long period_ms) {
    deadline->tv_nsec += (period_ms % 1000) * 1000000L;
    deadline->tv_sec  += period_ms / 1000;
    if (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_nsec -= 1000000000L;
        deadline->tv_sec  += 1;
    }
    while (!stop_requested) {
        int rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, deadline, NULL);
        if (rc == 0 || rc != EINTR) break;
    }
}

/* Ротация PS с "довесками", которые не помещаются в один статический кадр:
 * буфер ПЛИС держит ровно 4 группы (416 бит), а и RadioText (до 16
 * сегментов), и ECC (нужен отдельный кадр, чтобы не резать PS) требуют
 * кадров сверх этого. Общая схема: PS, extra[0], PS, extra[1], ..., PS,
 * extra[N-1], повтор.
 *
 * Все кадры собираются ОДИН раз до входа в цикл: содержимое по ходу работы
 * не меняется, а каждая пересборка -- это 16 вычислений CRC-10 плюс
 * распаковка 416 бит, и раньше это делалось заново каждые 360 мс. */
static void rds_rotation_loop(volatile uint32_t *fm_regs,
                              const unsigned char *ps, const unsigned char *rt,
                              uint16_t pi, uint8_t pty, int stereo,
                              int have_rt, int rt_frames,
                              int have_ecc, uint8_t ecc) {
    uint32_t frames[MAX_FRAMES][REG_RDS_WORDS];
    int n_extra = 0;
    struct timespec deadline;

    frame_ps(ps, pi, pty, stereo, frames[0]);
    if (have_rt) {
        for (int f = 0; f < rt_frames; f++)
            frame_rt(rt, pi, pty, 0 /* A/B flag: текст не меняется на ходу */,
                     f * 4, frames[1 + n_extra++]);
    }
    if (have_ecc)
        frame_ecc(ps, pi, pty, stereo, ecc, frames[1 + n_extra++]);

    printf("RDS rotation running (%s%s%s, %d phases, Ctrl-C to stop)\n",
           have_rt ? "RadioText" : "", (have_rt && have_ecc) ? " + " : "",
           have_ecc ? "ECC" : "", 2 * n_extra);
    fflush(stdout);

    clock_gettime(CLOCK_MONOTONIC, &deadline);

    int extra_i = 0;
    int tick = 0; /* 0 = кадр PS, 1 = кадр "довеска" */
    while (!stop_requested) {
        if (tick == 0) {
            write_rds_frame(fm_regs, frames[0]);
        } else {
            write_rds_frame(fm_regs, frames[1 + extra_i]);
            extra_i = (extra_i + 1) % n_extra;
        }
        tick ^= 1;
        sleep_until(&deadline, RT_FRAME_MS);
    }
    /* Уходим, оставив в эфире кадр PS, а не половину довеска. */
    write_rds_frame(fm_regs, frames[0]);
    printf("\nstopped, PS frame restored\n");
}

int main(int argc, char *argv[]) {
    int fd;
    void *map_base;
    volatile uint32_t *fm_regs;
    opts_t o;
    int opt;

    if (argc == 1) {
        print_usage(argv[0]);
        return 0;
    }

    memset(&o, 0, sizeof(o));
    o.base = FM_BASE_DEFAULT;

    /* ── Проход 1: разбор и проверка, без единого обращения к железу ── */
    while ((opt = getopt(argc, argv, "f:e:s:p:d:t:R:P:y:C:m:b:Mih")) != -1) {
        switch (opt) {
            case 'f':
                if (parse_freq(optarg, &o) != 0) return 1;
                break;
            case 'e':
                if (parse_bool(optarg, &o.enable) != 0) {
                    fprintf(stderr, "Error: -e expects 0 or 1 (got '%s')\n", optarg);
                    return 1;
                }
                o.have_enable = 1;
                break;
            case 's':
                if (parse_bool(optarg, &o.stereo) != 0) {
                    fprintf(stderr, "Error: -s expects 0 or 1 (got '%s')\n", optarg);
                    return 1;
                }
                o.have_stereo = 1;
                break;
            case 'p': {
                long v;
                /* Было atoi(optarg) & 0x03 -- маска пропускала режим 3,
                 * которого нет в документации, прямо в CTRL. */
                if (parse_long(optarg, &v) != 0 || v < 0 || v > 2) {
                    fprintf(stderr, "Error: -p expects 0, 1 or 2 (got '%s')\n", optarg);
                    return 1;
                }
                o.pre = (uint32_t)v;
                o.have_pre = 1;
                break;
            }
            case 'd': {
                char *dend;
                errno = 0;
                double kHz = strtod(optarg, &dend);
                if (errno != 0 || dend == optarg || *dend != '\0') {
                    fprintf(stderr, "Error: -d expects a deviation in kHz (got '%s')\n", optarg);
                    return 1;
                }
                if (!(kHz > 0.0)) {
                    fprintf(stderr, "Error: deviation must be positive (got %g kHz)\n", kHz);
                    return 1;
                }
                /* Раньше -d был степенью двойки (сдвиг). Ловим старую привычку:
                 * "-d 5" теперь означало бы 5 кГц полной шкалы, то есть эфир
                 * почти без модуляции, и это молча "работало" бы. */
                if (kHz < DEV_KHZ_MIN) {
                    fprintf(stderr,
                            "Error: -d takes kHz, not a shift. %g kHz would be near-silent; "
                            "did you mean -d 60?\n", kHz);
                    return 1;
                }
                /* gain = dev / (full-scale mpx * CLK_RF / 2^40), в Q8.8 */
                double lsb_hz = (double)CLK_RF_HZ / TWO_POW_40;
                double gain   = (kHz * 1000.0) / (MPX_FULL_SCALE * lsb_hz);
                double q88    = gain * 256.0;
                if (!(q88 >= 1.0) || q88 > (double)DEV_GAIN_MAX) {
                    fprintf(stderr, "Error: %g kHz is out of range for a Q8.8 gain\n", kHz);
                    return 1;
                }
                if (kHz > DEV_KHZ_SANE) {
                    fprintf(stderr,
                            "Warning: %g kHz overdrives the composite; a 250 kHz receiver "
                            "cannot demodulate it (60 is the tested value)\n", kHz);
                }
                /* Округление без lround(): единственное обращение к libm в
                 * файле, из-за которого пакет тянул -lm. */
                o.dev_gain = (uint32_t)(q88 + 0.5);
                o.dev_khz  = kHz;
                o.have_dev = 1;
                break;
            }
            case 't':
                if (strlen(optarg) > RDS_PS_LEN) {
                    fprintf(stderr, "Warning: RDS name '%s' is longer than %d chars, truncating\n",
                            optarg, RDS_PS_LEN);
                }
                o.rds = optarg;
                o.have_rds = 1;
                break;
            case 'R':
                if (optarg[0] == '\0') {
                    /* Пустой -R запускал демон, который крутил кадры из одного
                     * CR: со стороны выглядело как работающий RadioText, в
                     * эфире -- пустой текст. Стоп ротации делается остановкой
                     * процесса, а не пустой строкой. */
                    fprintf(stderr, "Error: -R needs non-empty text "
                                    "(stop the rotation instead of sending an empty one)\n");
                    return 1;
                }
                if (strlen(optarg) > RDS_RT_LEN) {
                    fprintf(stderr, "Warning: RadioText is longer than %d chars, truncating\n",
                            RDS_RT_LEN);
                }
                o.rt = optarg;
                o.have_rt = 1;
                break;
            case 'P': {
                unsigned long v;
                if (parse_ulong_auto(optarg, &v) != 0 || v > 0xFFFF) {
                    fprintf(stderr, "Error: -P expects 0..0xFFFF (got '%s')\n", optarg);
                    return 1;
                }
                o.pi = (uint16_t)v;
                o.have_pi = 1;
                break;
            }
            case 'y': {
                long v;
                if (parse_long(optarg, &v) != 0 || v < 0 || v > 31) {
                    fprintf(stderr, "Error: -y expects 0..31 (got '%s')\n", optarg);
                    return 1;
                }
                o.pty = (uint8_t)v;
                o.have_pty = 1;
                break;
            }
            case 'C': {
                unsigned long v;
                if (parse_ulong_auto(optarg, &v) != 0 || v > 0xFF) {
                    fprintf(stderr, "Error: -C expects 0..0xFF (got '%s')\n", optarg);
                    return 1;
                }
                o.ecc = (uint8_t)v;
                o.have_ecc = 1;
                break;
            }
            case 'm': {
                long v;
                if (parse_long(optarg, &v) != 0 || v < 0 || v > MPX_SHIFT_MAX) {
                    fprintf(stderr, "Error: -m expects 0..%d (got '%s')\n",
                            MPX_SHIFT_MAX, optarg);
                    return 1;
                }
                o.mpx_shift = (uint32_t)v;
                o.have_mpxsh = 1;
                break;
            }
            case 'M':
                o.have_mpxst = 1;
                break;
            case 'b': {
                unsigned long v;
                if (parse_ulong_auto(optarg, &v) != 0 || (v % 4UL) != 0) {
                    fprintf(stderr, "Error: -b expects a word-aligned address (got '%s')\n", optarg);
                    return 1;
                }
                o.base = v;
                break;
            }
            case 'i':
                o.have_info = 1;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }

    if (optind < argc) {
        fprintf(stderr, "Error: unexpected argument '%s'\n", argv[optind]);
        return 1;
    }

    /* PI и PTY попадают в эфир только вместе с перезаписью кадра, то есть
     * при -t. Молча проигнорировать их было бы хуже, чем сказать вслух. */
    if (o.have_rt && !o.have_rds) {
        fprintf(stderr, "Error: -R needs -t as well (PS and RadioText frames alternate)\n");
        return 1;
    }
    if (o.have_ecc && !o.have_rds) {
        fprintf(stderr, "Error: -C needs -t as well (the whole RDS frame is rebuilt at once)\n");
        return 1;
    }
    if ((o.have_pi || o.have_pty) && !o.have_rds) {
        fprintf(stderr, "Error: -P/-y only take effect together with -t "
                        "(the whole RDS frame is rebuilt at once)\n");
        return 1;
    }

    /* Обработчики ставим до первой записи в регистры: SIGTERM, пришедший
     * между mmap и входом в цикл ротации, раньше убивал процесс молча. */
    install_signal_handlers();

    /* ── Проход 2: применение ─────────────────────────────────────────── */
    const char *mem_dev = getenv("FMTX_MEM_DEV");
    if (!mem_dev || !*mem_dev) mem_dev = MEM_DEV_DEFAULT;

    if ((fd = open(mem_dev, O_RDWR | O_SYNC)) == -1) {
        fprintf(stderr, "Error opening %s: %s\n", mem_dev, strerror(errno));
        return 1;
    }

    /* Длина отображения считается от смещения внутри страницы, а не берётся
     * равной одной странице: при -b, попавшем близко к концу страницы, окно
     * регистров 0x00..0x4C иначе выходило бы за отображённую область. */
    long page_sz_l = sysconf(_SC_PAGESIZE);
    unsigned long page_sz = (page_sz_l > 0) ? (unsigned long)page_sz_l : 4096UL;
    unsigned long page_off = o.base & (page_sz - 1);
    unsigned long map_len  = ((page_off + REG_SPAN + page_sz - 1) / page_sz) * page_sz;

    map_base = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                    (off_t)(o.base & ~(page_sz - 1)));
    if (map_base == MAP_FAILED) {
        fprintf(stderr, "Error mmap %s at 0x%08lX: %s\n", mem_dev, o.base, strerror(errno));
        close(fd);
        return 1;
    }

    fm_regs = (volatile uint32_t *)((char *)map_base + page_off);

    uint32_t ctrl = fm_regs[REG_CTRL];

    if (o.have_freq) {
        fm_regs[REG_FTW_L] = (uint32_t)(o.ftw & 0xFFFFFFFF);
        fm_regs[REG_FTW_U] = (uint32_t)((o.ftw >> 32) & 0xFF);
        printf("Freq set to %.3f MHz (FTW=0x%02X%08X)\n",
               o.freq_mhz, (unsigned)((o.ftw >> 32) & 0xFF), (unsigned)(o.ftw & 0xFFFFFFFF));
    }

    if (o.have_dev) {
        fm_regs[REG_DEV_GAIN] = o.dev_gain;
        printf("Deviation: %.1f kHz full scale (gain %u = %.3f in Q8.8), pilot %.2f kHz\n",
               o.dev_khz, o.dev_gain, o.dev_gain / 256.0, o.dev_khz * PILOT_FRACTION);
    }

    if (o.have_mpxsh) {
        fm_regs[REG_MPX_SHIFT] = o.mpx_shift;
        printf("MPX_SHIFT set to %u\n", o.mpx_shift);
    }

    unsigned char ps_buf[RDS_PS_LEN], rt_buf[RDS_RT_LEN];
    int rt_frames = 0;
    uint16_t rds_pi  = o.have_pi  ? o.pi  : (uint16_t)RDS_PI_DEFAULT;
    uint8_t  rds_pty = o.have_pty ? o.pty : 0;
    /* Бит DI d0 объявляет стерео/моно. Берём то состояние, которое
     * действительно окажется в CTRL после этого запуска: заданное -s,
     * либо уже стоящее в регистре. */
    int rds_stereo = o.have_stereo ? o.stereo : (int)((ctrl >> 1) & 1);

    if (o.have_rds) {
        uint32_t rds_words[REG_RDS_WORDS];
        fill_ps(ps_buf, o.rds);
        frame_ps(ps_buf, rds_pi, rds_pty, rds_stereo, rds_words);
        write_rds_frame(fm_regs, rds_words);
        printf("RDS set: PS='%.*s' PI=0x%04X PTY=%u DI=%s\n",
               RDS_PS_LEN, o.rds, rds_pi, rds_pty, rds_stereo ? "stereo" : "mono");
    }

    if (o.have_enable) {
        if (o.enable) ctrl |=  (1U << 0);
        else          ctrl &= ~(1U << 0);
        printf("TX %s\n", o.enable ? "Enabled" : "Disabled");
    }
    if (o.have_stereo) {
        if (o.stereo) ctrl |=  (1U << 1);
        else          ctrl &= ~(1U << 1);
        printf("Stereo %s\n", o.stereo ? "Enabled" : "Disabled");
    }
    if (o.have_pre) {
        ctrl &= ~(3U << 2);
        ctrl |= (o.pre << 2);
        printf("Pre-emphasis mode: %u\n", o.pre);
    }

    /* CTRL пишется последним и только если его действительно меняли: несущая
     * поднимается уже после того, как FTW/DEV/RDS легли в регистры. Раньше
     * CTRL переписывался при любом запуске, включая "-i" и разбор с ошибкой. */
    if (o.have_enable || o.have_stereo || o.have_pre) {
        fm_regs[REG_CTRL] = ctrl;
    }

    /* -i печатается в конце, чтобы показывать актуальное состояние: раньше
     * "-e 1 -i" выводил CTRL, прочитанный до применения флагов.
     * MPX_FIFO_STAT (0x44) сюда не входит намеренно: его чтение сбрасывает
     * флаг overflow, то есть портит показания параллельного читателя FIFO.
     * Для него есть отдельный -M. */
    if (o.have_info) {
        uint32_t c = fm_regs[REG_CTRL];
        uint32_t g = fm_regs[REG_DEV_GAIN] & 0xFFFF;
        printf("--- Current AXI Status (base 0x%08lX) ---\n", o.base);
        printf("CTRL Register: 0x%08X (TX=%u STEREO=%u PREEMPH=%u)\n",
               c, c & 1u, (c >> 1) & 1u, (c >> 2) & 3u);
        printf("FTW Lower    : 0x%08X\n", fm_regs[REG_FTW_L]);
        printf("FTW Upper    : 0x%08X\n", fm_regs[REG_FTW_U]);
        printf("Dev Gain     : 0x%08X (%.3f, full scale %.1f kHz)\n",
               g, g / 256.0,
               (g / 256.0) * MPX_FULL_SCALE * ((double)CLK_RF_HZ / TWO_POW_40) / 1000.0);
        /* Обратная развёртка FTW в МГц -- удобнее, чем сверять слова вручную. */
        uint64_t ftw_rb = ((uint64_t)(fm_regs[REG_FTW_U] & 0xFF) << 32)
                        | (uint64_t)fm_regs[REG_FTW_L];
        printf("Frequency    : %.3f MHz (from FTW read-back)\n",
               (double)ftw_rb * (double)CLK_RF_HZ / TWO_POW_40 / 1e6);
        printf("MPX_SHIFT    : %u\n", fm_regs[REG_MPX_SHIFT] & 0x1F);
    }

    if (o.have_mpxst) {
        uint32_t st = fm_regs[REG_MPX_STAT];
        printf("MPX FIFO stat: 0x%08X (entries=%u overflow=%u empty=%u)\n",
               st, st & 0xFFFFu, (st >> 16) & 1u, (st >> 17) & 1u);
    }

    /* Демон запускается последним: несущая, девиация и CTRL уже выставлены,
     * так что ротация начинается на полностью настроенном передатчике.
     * Входим сюда и по -R, и по -C -- обеим нужен один и тот же механизм
     * подмены кадров, раз статический кадр PS не оставляет для них места. */
    if (o.have_rt || o.have_ecc) {
        if (o.have_rt) {
            rt_frames = fill_rt(rt_buf, o.rt);
            printf("RadioText: '%.*s' (%d frame%s)\n",
                   RDS_RT_LEN, o.rt, rt_frames, rt_frames == 1 ? "" : "s");
        } else {
            memset(rt_buf, ' ', sizeof(rt_buf)); /* не используется, но не мусор */
        }
        if (o.have_ecc) {
            printf("ECC: 0x%02X\n", o.ecc);
        }
        rds_rotation_loop(fm_regs, ps_buf, rt_buf, rds_pi, rds_pty, rds_stereo,
                          o.have_rt, rt_frames, o.have_ecc, o.ecc);
    }

    if (munmap(map_base, map_len) == -1) perror("munmap error");
    close(fd);

    return 0;
}

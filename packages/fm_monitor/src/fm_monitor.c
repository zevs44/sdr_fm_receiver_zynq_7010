/*
 * fm_monitor.c - Real-time console monitor for the axi_sdr_fm AXI4-Lite core.
 *
 * Memory-maps the IP core's register window and continuously displays every
 * register of the current map (0x00-0x80): NCO tuning word, status/RSSI,
 * volume, control bits, RDS PI/PS/PTY/TP/TA/M-S/RadioText, RDS block error
 * statistics, and the RDS / MPX / audio export FIFO status. Optionally tunes
 * the receiver and sets VOLUME / MPX_SHIFT / CONTROLS before monitoring.
 *
 * The core's AXI address bus is [7:0], so the peripheral needs an address
 * segment of at least 256 bytes in Vivado's Address Editor (4K recommended).
 * With the old 64-byte segment every read above 0x3C returns an interconnect
 * decode error instead of the new registers.
 *
 * DESTRUCTIVE READS: RDS_FIFO_DATA (0x24), MPX_FIFO_DATA (0x30) and
 * AUDIO_FIFO_DATA (0x3C) pop one FIFO entry per read, and the three
 * *_FIFO_STAT registers clear their overflow flag on read. This monitor
 * therefore never touches the DATA registers (unless --rds-blocks is given),
 * reads each STAT register exactly once per frame, and latches the overflow
 * flags in software - they would otherwise be lost as soon as they are shown.
 *
 * Build: gcc -O2 -Wall -Wextra -std=c11 -o fm_monitor fm_monitor.c
 * Usage: fm_monitor --help
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/*  Register map (axi_sdr_fm.v)                                        */
/* ------------------------------------------------------------------ */

#define DEFAULT_BASE_ADDRESS   0x43C60000UL
#define DEFAULT_DEV            "/dev/mem"
#define REG_WINDOW_SIZE        0x84UL          /* 0x00 .. 0x80 inclusive */

#define REG_TUNING_WORD        0x00u   /* RW                            */
#define REG_RDS_PS_0           0x04u   /* RO                            */
#define REG_RDS_PS_1           0x08u   /* RO                            */
#define REG_RESERVED_0C        0x0Cu   /* --                            */
#define REG_STATUS             0x10u   /* RO                            */
#define REG_VOLUME             0x14u   /* RW                            */
#define REG_CONTROLS           0x18u   /* RW                            */
#define REG_RDS_PI             0x1Cu   /* RO                            */
#define REG_RDS_FIFO_STAT      0x20u   /* RO, overflow clear-on-read    */
#define REG_RDS_FIFO_DATA      0x24u   /* RO, read = pop                */
#define REG_RDS_ERR_STATS      0x28u   /* RO                            */
#define REG_MPX_FIFO_STAT      0x2Cu   /* RO, overflow clear-on-read    */
#define REG_MPX_FIFO_DATA      0x30u   /* RO, read = pop                */
#define REG_MPX_SHIFT          0x34u   /* RW                            */
#define REG_AUDIO_FIFO_STAT    0x38u   /* RO, overflow clear-on-read    */
#define REG_AUDIO_FIFO_DATA    0x3Cu   /* RO, read = pop                */
#define REG_RDS_FLAGS          0x40u   /* RO                            */
#define REG_RDS_RT_BASE        0x44u   /* RO, 16 registers up to 0x80   */
#define RDS_RT_REGS            16u
#define REG_RDS_RT_LAST        (REG_RDS_RT_BASE + 4u * (RDS_RT_REGS - 1u))

/* STATUS (0x10) */
#define ST_STEREO_LOCK(v)      ((v) & 0x1u)
#define ST_STATION_FOUND(v)    (((v) >> 1) & 0x1u)
#define ST_RSSI(v)             (((v) >> 2) & 0x3FFFFu)  /* 18-bit raw level */
#define ST_RDS_SYNC(v)         (((v) >> 20) & 0x1u)

/* CONTROLS (0x18) */
#define CTRL_MUTE_EN           (1u << 0)
#define CTRL_BASS_BOOST_EN     (1u << 1)
#define CTRL_RDS_EN            (1u << 2)
#define CTRL_DEEMPH            (1u << 3)
#define CTRL_MONO              (1u << 4)
#define CTRL_KNOWN_MASK        0x1Fu

/* RDS_FIFO_STAT (0x20): [7:0]=count, [8]=overflow, [9]=empty */
#define RDSF_COUNT(v)          ((v) & 0xFFu)
#define RDSF_OVERFLOW(v)       (((v) >> 8) & 0x1u)
#define RDSF_EMPTY(v)          (((v) >> 9) & 0x1u)

/* RDS_FIFO_DATA (0x24) */
#define RDSD_WORD(v)           ((v) & 0xFFFFu)
#define RDSD_BLOCK_ID(v)       (((v) >> 16) & 0x7u)
#define RDSD_CORRECTED(v)      (((v) >> 19) & 0x1u)
#define RDSD_UNCORRECTABLE(v)  (((v) >> 20) & 0x1u)

/* RDS_ERR_STATS (0x28) - free-running 16-bit counters, wrap */
#define ERRS_CORRECTED(v)      ((v) & 0xFFFFu)
#define ERRS_UNCORRECTABLE(v)  (((v) >> 16) & 0xFFFFu)

/* MPX/AUDIO FIFO_STAT (0x2C / 0x38): count in [15:0] (zero-padded above
 * MPX_FIFO_ADDR_W), [16]=overflow, [17]=empty. Masking with 0xFFFF stays
 * correct for any FIFO depth. */
#define SFIFO_COUNT(v)         ((v) & 0xFFFFu)
#define SFIFO_OVERFLOW(v)      (((v) >> 16) & 0x1u)
#define SFIFO_EMPTY(v)         (((v) >> 17) & 0x1u)

/* RDS_FLAGS (0x40) */
#define FLG_PTY(v)             ((v) & 0x1Fu)
#define FLG_TP(v)              (((v) >> 5) & 0x1u)
#define FLG_TA(v)              (((v) >> 6) & 0x1u)
#define FLG_MS(v)              (((v) >> 7) & 0x1u)

/* NCO: tuning_word = round(freq_MHz * 2^32 / clk_MHz) */
#define NCO_MODULUS            4294967296.0

#define DEFAULT_NCO_CLK_MHZ    250.0    /* = CLK_RF_HZ                  */
#define DEFAULT_RSSI_FULL      2000u    /* = RSSI_THRESH_HI             */
#define DEFAULT_INTERVAL_MS    200
#define RDS_LOG_LINES          6

/* IEC 62106 programme types (European RDS table, not RBDS) */
static const char *const pty_name[32] = {
    "None",             "News",             "Current Affairs",  "Information",
    "Sport",            "Education",        "Drama",            "Culture",
    "Science",          "Varied",           "Pop Music",        "Rock Music",
    "Easy Listening",   "Light Classics",   "Serious Classics", "Other Music",
    "Weather",          "Finance",          "Children's Progs", "Social Affairs",
    "Religion",         "Phone In",         "Travel",           "Leisure",
    "Jazz Music",       "Country Music",    "National Music",   "Oldies Music",
    "Folk Music",       "Documentary",      "Alarm Test",       "Alarm"
};

static const char *const block_name[8] = { "A", "B", "C", "D", "?", "?", "?", "?" };

/* ------------------------------------------------------------------ */
/*  Globals                                                            */
/* ------------------------------------------------------------------ */

static volatile sig_atomic_t g_running = 1;
static int g_color  = 1;        /* ANSI colours          */
static int g_screen = 1;        /* cursor / erase control */
static volatile uint32_t *g_regs;

static void handle_signal(int sig)
{
    (void)sig;
    g_running = 0;
}

/* Print one line and erase whatever the previous frame left on it. The old
 * version padded strings by hand after the colour escapes, which breaks as
 * soon as a field is longer than its predecessor. */
static void oline(const char *fmt, ...)
{
    char buf[512];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    fputs(buf, stdout);
    if (g_screen)
        fputs("\033[K", stdout);
    fputc('\n', stdout);
}

static const char *co(const char *seq)
{
    return g_color ? seq : "";
}

#define C_RESET   co("\033[0m")
#define C_GREEN   co("\033[1;32m")
#define C_RED     co("\033[1;31m")
#define C_CYAN    co("\033[1;36m")
#define C_YELLOW  co("\033[1;33m")

/* Colourised ON/OFF; several may appear in one printf, hence the ring. */
static const char *flag_str(int v)
{
    static char buf[8][32];
    static unsigned idx;
    char *b = buf[idx++ & 7u];

    snprintf(b, sizeof(buf[0]), "%s%s%s", v ? C_GREEN : "", v ? "ON " : "OFF",
             v ? C_RESET : "");
    return b;
}

static void hline(void)
{
    oline("----------------------------------------------------------------------");
}

/* ------------------------------------------------------------------ */
/*  Register access                                                    */
/* ------------------------------------------------------------------ */

static inline uint32_t reg_rd(uint32_t off)
{
    return g_regs[off / 4u];
}

static inline void reg_wr(uint32_t off, uint32_t val)
{
    g_regs[off / 4u] = val;
}

/* One coherent snapshot of every non-destructive register. */
typedef struct {
    uint32_t tuning;
    uint32_t ps0, ps1;
    uint32_t reserved_0c;
    uint32_t status;
    uint32_t volume;
    uint32_t controls;
    uint32_t rds_pi;
    uint32_t rds_fifo_stat;
    uint32_t rds_err;
    uint32_t mpx_fifo_stat;
    uint32_t mpx_shift;
    uint32_t audio_fifo_stat;
    uint32_t rds_flags;
    uint32_t rt[RDS_RT_REGS];
} snap_t;

static void snap_read(snap_t *s)
{
    s->tuning      = reg_rd(REG_TUNING_WORD);
    s->ps0         = reg_rd(REG_RDS_PS_0);
    s->ps1         = reg_rd(REG_RDS_PS_1);
    s->reserved_0c = reg_rd(REG_RESERVED_0C);
    s->status      = reg_rd(REG_STATUS);
    s->volume      = reg_rd(REG_VOLUME);
    s->controls    = reg_rd(REG_CONTROLS);
    s->rds_pi      = reg_rd(REG_RDS_PI);
    s->rds_err     = reg_rd(REG_RDS_ERR_STATS);
    s->mpx_shift   = reg_rd(REG_MPX_SHIFT);
    s->rds_flags   = reg_rd(REG_RDS_FLAGS);

    /* Each of these clears its overflow flag as a side effect: read exactly
     * once per frame, and never again from the raw dump. */
    s->rds_fifo_stat   = reg_rd(REG_RDS_FIFO_STAT);
    s->mpx_fifo_stat   = reg_rd(REG_MPX_FIFO_STAT);
    s->audio_fifo_stat = reg_rd(REG_AUDIO_FIFO_STAT);

    /* RadioText coherency: reading RDS_RT_0 latches all 64 characters into
     * the core's shadow register, so it MUST come first, then 0x48 upwards.
     * The accesses go through a volatile pointer, so they cannot be
     * reordered by the compiler. */
    s->rt[0] = reg_rd(REG_RDS_RT_BASE);
    for (unsigned i = 1; i < RDS_RT_REGS; i++)
        s->rt[i] = reg_rd(REG_RDS_RT_BASE + 4u * i);
}

/* Snapshot lookup for the raw dump; 0 = pop-on-read register (not shown). */
static int snap_get(const snap_t *s, uint32_t off, uint32_t *out)
{
    switch (off) {
    case REG_TUNING_WORD:     *out = s->tuning;          return 1;
    case REG_RDS_PS_0:        *out = s->ps0;             return 1;
    case REG_RDS_PS_1:        *out = s->ps1;             return 1;
    case REG_RESERVED_0C:     *out = s->reserved_0c;     return 1;
    case REG_STATUS:          *out = s->status;          return 1;
    case REG_VOLUME:          *out = s->volume;          return 1;
    case REG_CONTROLS:        *out = s->controls;        return 1;
    case REG_RDS_PI:          *out = s->rds_pi;          return 1;
    case REG_RDS_FIFO_STAT:   *out = s->rds_fifo_stat;   return 1;
    case REG_RDS_ERR_STATS:   *out = s->rds_err;         return 1;
    case REG_MPX_FIFO_STAT:   *out = s->mpx_fifo_stat;   return 1;
    case REG_MPX_SHIFT:       *out = s->mpx_shift;       return 1;
    case REG_AUDIO_FIFO_STAT: *out = s->audio_fifo_stat; return 1;
    case REG_RDS_FLAGS:       *out = s->rds_flags;       return 1;
    default:
        if (off >= REG_RDS_RT_BASE && off <= REG_RDS_RT_LAST) {
            *out = s->rt[(off - REG_RDS_RT_BASE) / 4u];
            return 1;
        }
        return 0;
    }
}

static const char *reg_name(uint32_t off)
{
    static char buf[16];

    switch (off) {
    case REG_TUNING_WORD:     return "tuning_word";
    case REG_RDS_PS_0:        return "rds_ps_0";
    case REG_RDS_PS_1:        return "rds_ps_1";
    case REG_RESERVED_0C:     return "reserved";
    case REG_STATUS:          return "status";
    case REG_VOLUME:          return "volume";
    case REG_CONTROLS:        return "controls";
    case REG_RDS_PI:          return "rds_pi";
    case REG_RDS_FIFO_STAT:   return "rds_fifo_stat";
    case REG_RDS_FIFO_DATA:   return "rds_fifo_data";
    case REG_RDS_ERR_STATS:   return "rds_err_stats";
    case REG_MPX_FIFO_STAT:   return "mpx_fifo_stat";
    case REG_MPX_FIFO_DATA:   return "mpx_fifo_data";
    case REG_MPX_SHIFT:       return "mpx_shift";
    case REG_AUDIO_FIFO_STAT: return "audio_fifo_stat";
    case REG_AUDIO_FIFO_DATA: return "audio_fifo_data";
    case REG_RDS_FLAGS:       return "rds_flags";
    default:
        if (off >= REG_RDS_RT_BASE && off <= REG_RDS_RT_LAST) {
            snprintf(buf, sizeof(buf), "rds_rt_%u",
                     (unsigned)((off - REG_RDS_RT_BASE) / 4u));
            return buf;
        }
        return "unmapped";
    }
}

/* ------------------------------------------------------------------ */
/*  Decoding helpers                                                   */
/* ------------------------------------------------------------------ */

/* Non-printable -> space. Goes through unsigned char so the result does not
 * depend on whether plain char is signed (x86) or unsigned (ARM). */
static char printable(uint32_t byte)
{
    unsigned char c = (unsigned char)(byte & 0xFFu);
    return (c < 32 || c > 126) ? ' ' : (char)c;
}

static void ps_to_text(uint32_t ps0, uint32_t ps1, char out[9])
{
    out[0] = printable(ps0 >> 24);
    out[1] = printable(ps0 >> 16);
    out[2] = printable(ps0 >> 8);
    out[3] = printable(ps0);
    out[4] = printable(ps1 >> 24);
    out[5] = printable(ps1 >> 16);
    out[6] = printable(ps1 >> 8);
    out[7] = printable(ps1);
    out[8] = '\0';
}

/* 64 characters, 4 per register, MSB = earliest character. A message shorter
 * than 64 characters is terminated with 0x0D per IEC 62106, so stop there
 * instead of printing the space padding. */
static void rt_to_text(const uint32_t rt[RDS_RT_REGS], char out[65])
{
    int n = 0;

    for (unsigned i = 0; i < 64u; i++) {
        uint32_t w = rt[i / 4u];
        unsigned char c = (unsigned char)((w >> (8u * (3u - (i % 4u)))) & 0xFFu);
        if (c == 0x0D)
            break;
        out[n++] = printable(c);
    }
    while (n > 0 && out[n - 1] == ' ')
        n--;
    out[n] = '\0';
}

static void bar(char *dst, int width, uint32_t value, uint32_t full)
{
    int filled = 0;

    if (full > 0u) {
        double f = (double)value * (double)width / (double)full;
        filled = (f <= 0.0) ? 0 : (f >= (double)width ? width : (int)f);
    }
    for (int i = 0; i < width; i++)
        dst[i] = (i < filled) ? '#' : '-';
    dst[width] = '\0';
}

static double now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------------ */
/*  Persistent state between frames                                    */
/* ------------------------------------------------------------------ */

typedef struct {
    /* Overflow flags are clear-on-read, so they are latched here. */
    unsigned rds_ovf_events;
    unsigned mpx_ovf_events;
    unsigned audio_ovf_events;
    /* Rate estimation for the free-running RDS block counters. */
    int      have_prev;
    double   prev_t;
    uint16_t prev_ok, prev_bad;
    double   rate_ok, rate_bad;
    /* Optional raw RDS block log (--rds-blocks). */
    char     log[RDS_LOG_LINES][72];
    int      log_used;
} state_t;

typedef struct {
    double   nco_clk_mhz;
    uint32_t rssi_full;
    int      show_raw;
    int      rds_blocks;
} view_opts_t;

static void log_push(state_t *st, const char *line)
{
    if (st->log_used < RDS_LOG_LINES) {
        snprintf(st->log[st->log_used++], sizeof(st->log[0]), "%s", line);
    } else {
        memmove(st->log[0], st->log[1],
                sizeof(st->log[0]) * (RDS_LOG_LINES - 1));
        snprintf(st->log[RDS_LOG_LINES - 1], sizeof(st->log[0]), "%s", line);
    }
}

/* Destructive: every read of RDS_FIFO_DATA pops one entry. Only called with
 * --rds-blocks, and never while another consumer (e.g. the V4L2 driver) is
 * expected to be draining the same FIFO. */
static void drain_rds_fifo(const snap_t *s, state_t *st)
{
    unsigned count = RDSF_COUNT(s->rds_fifo_stat);
    char line[72];

    if (count > 32u)
        count = 32u;                    /* FIFO is 32 deep */

    for (unsigned i = 0; i < count; i++) {
        uint32_t d = reg_rd(REG_RDS_FIFO_DATA);
        snprintf(line, sizeof(line), "block %s  info 0x%04X  %s",
                 block_name[RDSD_BLOCK_ID(d)], (unsigned)RDSD_WORD(d),
                 RDSD_UNCORRECTABLE(d) ? "UNCORRECTABLE"
                                       : (RDSD_CORRECTED(d) ? "ok" : "-"));
        log_push(st, line);
    }
}

/* ------------------------------------------------------------------ */
/*  Rendering                                                          */
/* ------------------------------------------------------------------ */

static void render(const snap_t *s, state_t *st, const view_opts_t *o)
{
    char rssi_bar[32], volume_bar[32];
    char ps[9], rt[65], rt1[33], rt2[33];

    uint32_t rssi     = ST_RSSI(s->status);
    int stereo_lock   = (int)ST_STEREO_LOCK(s->status);
    int station_found = (int)ST_STATION_FOUND(s->status);
    int rds_sync      = (int)ST_RDS_SYNC(s->status);

    uint32_t volume   = s->volume & 0xFu;
    uint32_t controls = s->controls;
    int mute_en       = (controls & CTRL_MUTE_EN)       ? 1 : 0;
    int bass_boost_en = (controls & CTRL_BASS_BOOST_EN) ? 1 : 0;
    int rds_en        = (controls & CTRL_RDS_EN)        ? 1 : 0;
    int deemph        = (controls & CTRL_DEEMPH)        ? 1 : 0;
    int mono          = (controls & CTRL_MONO)          ? 1 : 0;

    double freq_mhz = (double)s->tuning * o->nco_clk_mhz / NCO_MODULUS;

    uint32_t pty = FLG_PTY(s->rds_flags);
    uint16_t ok  = (uint16_t)ERRS_CORRECTED(s->rds_err);
    uint16_t bad = (uint16_t)ERRS_UNCORRECTABLE(s->rds_err);

    ps_to_text(s->ps0, s->ps1, ps);
    rt_to_text(s->rt, rt);
    snprintf(rt1, sizeof(rt1), "%.32s", rt);
    snprintf(rt2, sizeof(rt2), "%.32s", (strlen(rt) > 32) ? rt + 32 : "");
    bar(rssi_bar, 20, rssi, o->rssi_full);
    bar(volume_bar, 15, volume, 15u);

    /* 16-bit free-running counters -> per-second rates (wrap-safe). */
    double t = now_seconds();
    if (!st->have_prev) {
        st->have_prev = 1;
        st->prev_t = t; st->prev_ok = ok; st->prev_bad = bad;
    } else if (t - st->prev_t >= 1.0) {
        double dt = t - st->prev_t;
        st->rate_ok  = (double)(uint16_t)(ok  - st->prev_ok)  / dt;
        st->rate_bad = (double)(uint16_t)(bad - st->prev_bad) / dt;
        st->prev_t = t; st->prev_ok = ok; st->prev_bad = bad;
    }
    double rate_tot = st->rate_ok + st->rate_bad;
    double bler = (rate_tot > 0.0) ? 100.0 * st->rate_bad / rate_tot : 0.0;

    /* Latch the clear-on-read overflow flags. */
    if (RDSF_OVERFLOW(s->rds_fifo_stat))    st->rds_ovf_events++;
    if (SFIFO_OVERFLOW(s->mpx_fifo_stat))   st->mpx_ovf_events++;
    if (SFIFO_OVERFLOW(s->audio_fifo_stat)) st->audio_ovf_events++;

    const char *mode_col, *mode_txt;
    if (mono) {
        mode_col = ""; mode_txt = "MONO (forced by CONTROLS[4])";
    } else if (stereo_lock) {
        mode_col = C_CYAN; mode_txt = "STEREO (pilot locked)";
    } else {
        mode_col = ""; mode_txt = "MONO (no pilot lock)";
    }

    if (g_screen)
        fputs("\033[H", stdout);

    oline("======================================================================");
    oline("        axi_sdr_fm - Real-Time Register Monitor (0x00-0x80)");
    oline("======================================================================");

    if (s->tuning == 0xFFFFFFFFu && s->status == 0xFFFFFFFFu) {
        oline(" %s!! Every register reads as 0xFFFFFFFF: wrong base address, or the%s",
              C_RED, C_RESET);
        oline(" %s!! bitstream does not contain this peripheral.%s", C_RED, C_RESET);
    } else if (s->reserved_0c != 0u || s->rds_flags == 0xFFFFFFFFu) {
        oline(" %s!! Suspicious reads above 0x0C: check that the AXI address segment%s",
              C_RED, C_RESET);
        oline(" %s!! is at least 256 bytes (4K recommended), not the old 64.%s",
              C_RED, C_RESET);
    }

    oline(" Tuning word:   0x%08" PRIX32 "  ->  %10.4f MHz   (NCO clk %.3f MHz)",
          s->tuning, freq_mhz, o->nco_clk_mhz);
    oline(" Station:       %s%s%s",
          station_found ? C_GREEN : C_RED,
          station_found ? "FOUND" : "NO SIGNAL", C_RESET);
    oline(" Audio mode:    %s%s%s", mode_col, mode_txt, C_RESET);
    oline(" Signal level:  [%s] RSSI %6" PRIu32 " / %" PRIu32 " (RSSI_THRESH_HI)",
          rssi_bar, rssi, o->rssi_full);
    hline();

    oline(" RDS sync:      %s%s%s   RDS_EN: %s",
          rds_sync ? C_GREEN : C_RED,
          rds_sync ? "SYNC" : "NO SYNC", C_RESET, flag_str(rds_en));
    oline(" PI code:       0x%04X", (unsigned)(s->rds_pi & 0xFFFFu));
    oline(" PS name:       %s[ %s ]%s", C_YELLOW, ps, C_RESET);
    oline(" PTY:           %2" PRIu32 " (%s)    TP:%s TA:%s  M/S: %s",
          pty, pty_name[pty], flag_str((int)FLG_TP(s->rds_flags)),
          flag_str((int)FLG_TA(s->rds_flags)),
          FLG_MS(s->rds_flags) ? "Music" : "Speech");
    oline(" RadioText:     %s%s%s", C_YELLOW, rt1[0] ? rt1 : "(empty)", C_RESET);
    oline("                %s%s%s", C_YELLOW, rt2, C_RESET);
    oline(" RDS blocks:    ok %5u (%.1f/s)   bad %5u (%.1f/s)   BLER %5.1f%%",
          (unsigned)ok, st->rate_ok, (unsigned)bad, st->rate_bad, bler);
    hline();

    oline(" RDS FIFO:      %3" PRIu32 "/32 entries   empty:%u   overflow:%s (events: %u)",
          RDSF_COUNT(s->rds_fifo_stat), (unsigned)RDSF_EMPTY(s->rds_fifo_stat),
          RDSF_OVERFLOW(s->rds_fifo_stat) ? "YES" : "no ", st->rds_ovf_events);
    oline(" MPX FIFO:      %5" PRIu32 " samples   empty:%u   overflow:%s (events: %u)"
          "   MPX_SHIFT=%" PRIu32,
          SFIFO_COUNT(s->mpx_fifo_stat), (unsigned)SFIFO_EMPTY(s->mpx_fifo_stat),
          SFIFO_OVERFLOW(s->mpx_fifo_stat) ? "YES" : "no ", st->mpx_ovf_events,
          s->mpx_shift & 0xFu);
    oline(" AUDIO FIFO:    %5" PRIu32 " samples   empty:%u   overflow:%s (events: %u)"
          "   (L/R entries, not pairs)",
          SFIFO_COUNT(s->audio_fifo_stat), (unsigned)SFIFO_EMPTY(s->audio_fifo_stat),
          SFIFO_OVERFLOW(s->audio_fifo_stat) ? "YES" : "no ", st->audio_ovf_events);
    hline();

    oline(" Volume:        [%s] %2" PRIu32 "/15", volume_bar, volume);
    oline(" Controls:      0x%08" PRIX32 "  MUTE:%s BASS:%s RDS:%s DEEMPH:%s MONO:%s",
          controls, flag_str(mute_en), flag_str(bass_boost_en), flag_str(rds_en),
          flag_str(deemph), flag_str(mono));
    if (controls & ~CTRL_KNOWN_MASK)
        oline("                %sreserved bits [31:5] are non-zero: 0x%08" PRIX32 "%s",
              C_RED, controls & ~CTRL_KNOWN_MASK, C_RESET);

    if (o->rds_blocks) {
        hline();
        oline(" Last raw RDS blocks (popped from the FIFO by this monitor):");
        for (int i = 0; i < RDS_LOG_LINES; i++)
            oline("   %s", (i < st->log_used) ? st->log[i] : "");
    }

    if (o->show_raw) {
        hline();
        oline(" Raw register dump:");
        for (uint32_t off = 0; off <= REG_RDS_RT_LAST; off += 8u) {
            char cell[2][48];
            for (unsigned j = 0; j < 2u; j++) {
                uint32_t a = off + 4u * j;
                uint32_t v;
                if (a > REG_RDS_RT_LAST)
                    cell[j][0] = '\0';
                else if (snap_get(s, a, &v))
                    snprintf(cell[j], sizeof(cell[0]),
                             "0x%02X %-15s = 0x%08" PRIX32,
                             (unsigned)a, reg_name(a), v);
                else
                    snprintf(cell[j], sizeof(cell[0]),
                             "0x%02X %-15s = (pop on read)",
                             (unsigned)a, reg_name(a));
            }
            oline("   %-37s%s", cell[0], cell[1]);
        }
    }

    oline("======================================================================");
    oline(" Press Ctrl+C to exit...");
}

/* ------------------------------------------------------------------ */
/*  Command line                                                       */
/* ------------------------------------------------------------------ */

static void usage(const char *argv0)
{
    printf(
"Usage: %s [options]\n"
"\n"
"Real-time monitor for the axi_sdr_fm AXI4-Lite register map (0x00-0x80).\n"
"\n"
"Access options:\n"
"  -b, --base ADDR      physical base address (default 0x%08lX)\n"
"  -d, --dev PATH       device to map (default %s; a plain file can be\n"
"                       used together with --base 0 for offline testing)\n"
"  -c, --clk MHZ        NCO reference clock in MHz (default %.1f, = CLK_RF_HZ)\n"
"\n"
"Display options:\n"
"  -i, --interval MS    refresh interval in ms (default %d)\n"
"  -1, --once           print a single frame and exit\n"
"  -R, --raw            add a raw dump of every register\n"
"  -r, --rds-blocks     also pop the raw RDS block FIFO (DESTRUCTIVE: this\n"
"                       consumes entries another reader would not see)\n"
"  -S, --rssi-full N    RSSI value for a full bar (default %u = RSSI_THRESH_HI)\n"
"  -n, --no-color       plain output, no ANSI escapes\n"
"\n"
"Write options (applied once at startup, before monitoring):\n"
"  -f, --freq MHZ       tune: writes TUNING_WORD = round(MHz * 2^32 / clk)\n"
"  -V, --volume N       write VOLUME (0-15)\n"
"  -s, --shift N        write MPX_SHIFT (0-15)\n"
"  -C, --controls HEX   write CONTROLS (bit0 MUTE, 1 BASS, 2 RDS, 3 DEEMPH,\n"
"                       4 MONO)\n"
"  -h, --help           this text\n"
"\n"
"Note: the core's address bus is [7:0], so its address segment in Vivado\n"
"must be at least 256 bytes (4K recommended) or reads above 0x3C fail.\n",
        argv0, DEFAULT_BASE_ADDRESS, DEFAULT_DEV, DEFAULT_NCO_CLK_MHZ,
        DEFAULT_INTERVAL_MS, DEFAULT_RSSI_FULL);
}

int main(int argc, char **argv)
{
    static const struct option long_opts[] = {
        { "base",      required_argument, NULL, 'b' },
        { "dev",       required_argument, NULL, 'd' },
        { "clk",       required_argument, NULL, 'c' },
        { "interval",  required_argument, NULL, 'i' },
        { "once",      no_argument,       NULL, '1' },
        { "raw",       no_argument,       NULL, 'R' },
        { "rds-blocks",no_argument,       NULL, 'r' },
        { "rssi-full", required_argument, NULL, 'S' },
        { "no-color",  no_argument,       NULL, 'n' },
        { "freq",      required_argument, NULL, 'f' },
        { "volume",    required_argument, NULL, 'V' },
        { "shift",     required_argument, NULL, 's' },
        { "controls",  required_argument, NULL, 'C' },
        { "help",      no_argument,       NULL, 'h' },
        { NULL, 0, NULL, 0 }
    };

    unsigned long base   = DEFAULT_BASE_ADDRESS;
    const char   *devpath = DEFAULT_DEV;
    long          interval_ms = DEFAULT_INTERVAL_MS;
    int           once = 0, no_color = 0;
    view_opts_t   opts = { DEFAULT_NCO_CLK_MHZ, DEFAULT_RSSI_FULL, 0, 0 };

    double   want_freq = -1.0;
    long     want_vol = -1, want_shift = -1;
    long long want_ctrl = -1;

    int c;
    while ((c = getopt_long(argc, argv, "b:d:c:i:1RrS:nf:V:s:C:h", long_opts,
                            NULL)) != -1) {
        char *end = NULL;
        switch (c) {
        case 'b': base = strtoul(optarg, &end, 0); break;
        case 'd': devpath = optarg; break;
        case 'c': opts.nco_clk_mhz = strtod(optarg, &end); break;
        case 'i': interval_ms = strtol(optarg, &end, 0); break;
        case '1': once = 1; break;
        case 'R': opts.show_raw = 1; break;
        case 'r': opts.rds_blocks = 1; break;
        case 'S': opts.rssi_full = (uint32_t)strtoul(optarg, &end, 0); break;
        case 'n': no_color = 1; break;
        case 'f': want_freq = strtod(optarg, &end); break;
        case 'V': want_vol = strtol(optarg, &end, 0); break;
        case 's': want_shift = strtol(optarg, &end, 0); break;
        case 'C': want_ctrl = (long long)strtoul(optarg, &end, 0); break;
        case 'h': usage(argv[0]); return EXIT_SUCCESS;
        default:  usage(argv[0]); return EXIT_FAILURE;
        }
        if (end && *end != '\0') {
            fprintf(stderr, "Invalid value for -%c: %s\n", c, optarg);
            return EXIT_FAILURE;
        }
    }

    if (opts.nco_clk_mhz <= 0.0) {
        fprintf(stderr, "NCO clock must be positive\n");
        return EXIT_FAILURE;
    }
    if (interval_ms < 10)
        interval_ms = 10;
    if (want_freq >= 0.0 && want_freq >= opts.nco_clk_mhz) {
        fprintf(stderr, "Frequency %.3f MHz is not below the NCO clock %.3f MHz\n",
                want_freq, opts.nco_clk_mhz);
        return EXIT_FAILURE;
    }
    if (want_vol > 15 || want_shift > 15) {
        fprintf(stderr, "Volume and MPX shift must be in the range 0-15\n");
        return EXIT_FAILURE;
    }

    int want_write = (want_freq >= 0.0) || (want_vol >= 0) ||
                     (want_shift >= 0) || (want_ctrl >= 0);

    /* Terminal capabilities. --once produces plain, pipe-friendly output. */
    g_color  = !no_color && isatty(STDOUT_FILENO);
    g_screen = !once && isatty(STDOUT_FILENO);

    /* sigaction, not signal(): no SA_RESTART, so the nanosleep below is
     * interrupted and the program exits immediately on Ctrl+C. */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    int fd = open(devpath, (want_write ? O_RDWR : O_RDONLY) | O_SYNC);
    if (fd < 0 && want_write == 0 && errno == EACCES)
        fd = open(devpath, O_RDONLY | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "Cannot open %s: %s%s\n", devpath, strerror(errno),
                (errno == EACCES || errno == EPERM) ? " (root required)" : "");
        return EXIT_FAILURE;
    }

    /* mmap offsets must be page aligned. 0x43C60000 happens to be, but any
     * base given on the command line need not be. */
    long pagesize = sysconf(_SC_PAGESIZE);
    if (pagesize <= 0)
        pagesize = 4096;
    off_t  page_base = (off_t)(base & ~((unsigned long)pagesize - 1ul));
    size_t page_off  = (size_t)(base - (unsigned long)page_base);
    size_t map_len   = page_off + REG_WINDOW_SIZE;
    map_len = ((map_len + (size_t)pagesize - 1u) / (size_t)pagesize) * (size_t)pagesize;

    int prot = PROT_READ | (want_write ? PROT_WRITE : 0);
    void *map_base = mmap(NULL, map_len, prot, MAP_SHARED, fd, page_base);
    if (map_base == MAP_FAILED) {
        fprintf(stderr, "mmap(%s, 0x%lX) failed: %s\n", devpath, base,
                strerror(errno));
        close(fd);
        return EXIT_FAILURE;
    }
    g_regs = (volatile uint32_t *)((volatile char *)map_base + page_off);

    if (want_freq >= 0.0) {
        uint32_t tw = (uint32_t)(want_freq / opts.nco_clk_mhz * NCO_MODULUS + 0.5);
        reg_wr(REG_TUNING_WORD, tw);
    }
    if (want_vol >= 0)
        reg_wr(REG_VOLUME, (uint32_t)want_vol & 0xFu);
    if (want_shift >= 0)
        reg_wr(REG_MPX_SHIFT, (uint32_t)want_shift & 0xFu);
    if (want_ctrl >= 0)
        reg_wr(REG_CONTROLS, (uint32_t)want_ctrl);

    if (g_screen)
        fputs("\033[2J\033[H\033[?25l", stdout);   /* clear, home, hide cursor */

    state_t st;
    memset(&st, 0, sizeof(st));

    do {
        snap_t s;
        snap_read(&s);
        if (opts.rds_blocks)
            drain_rds_fifo(&s, &st);
        render(&s, &st, &opts);
        fflush(stdout);

        if (once)
            break;

        struct timespec ts = {
            .tv_sec  = interval_ms / 1000,
            .tv_nsec = (interval_ms % 1000) * 1000000L
        };
        nanosleep(&ts, NULL);
    } while (g_running);

    if (g_screen)
        fputs("\033[?25h\033[0m", stdout);         /* show cursor, reset attrs */
    if (!once)
        printf("\nShutting down...\n");
    fflush(stdout);

    munmap(map_base, map_len);
    close(fd);
    return EXIT_SUCCESS;
}

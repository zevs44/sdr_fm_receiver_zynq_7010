// =============================================================================
//  fm_radio - userspace control utility for the axi_sdr_fm receiver IP
//
//  Talks to the FPGA over raw /dev/mem (mmap of the AXI4-Lite slave), no
//  kernel driver required. Mirrors the register map documented in
//  axi_sdr_fm.v (address bus [7:0], registers 0x00 .. 0x80).
//
//  Build:  $(CC) -O2 -Wall -Wextra -o fm_radio fm_radio.c      (no libm)
// =============================================================================

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/mman.h>

// ============================================================================
// SYSTEM CONFIGURATION
// ============================================================================
#define DEFAULT_AXI_BASE    0x43C60000UL   // override with -b or FM_RADIO_BASE
#define DEFAULT_CLK_RF_HZ   250000000.0    // override with -k or FM_RADIO_CLK

#define REG_SPAN            0x84UL         // 0x00 .. 0x80 inclusive

/* Register byte offsets (see axi_sdr_fm.v) */
#define REG_TUNING          0x00   // RW  NCO tuning word
#define REG_RDS_PS0         0x04   // RO  PS chars 1-4 (MSB = first char)
#define REG_RDS_PS1         0x08   // RO  PS chars 5-8
#define REG_STATUS          0x10   // RO  see STS_* below
#define REG_VOLUME          0x14   // RW  [3:0] volume 0-15
#define REG_CONTROLS        0x18   // RW  see CTRL_* below
#define REG_RDS_PI          0x1C   // RO  [15:0] programme identification
#define REG_RDS_FIFO_STAT   0x20   // RO  [7:0]=count [8]=ovf(clr-on-read) [9]=empty
#define REG_RDS_FIFO_DATA   0x24   // RO  read = pop
#define REG_RDS_ERR_STATS   0x28   // RO  [15:0]=good [31:16]=bad, free running
#define REG_MPX_FIFO_STAT   0x2C   // RO  [15:0]=count [16]=ovf(clr-on-read) [17]=empty
#define REG_MPX_FIFO_DATA   0x30   // RO  [15:0]=signed sample, read = pop
#define REG_MPX_SHIFT       0x34   // RW  [3:0] arithmetic right shift
#define REG_AUD_FIFO_STAT   0x38   // RO  [15:0]=count [16]=ovf(clr-on-read) [17]=empty
#define REG_AUD_FIFO_DATA   0x3C   // RO  sign-extended sample, read = pop
#define REG_RDS_FLAGS       0x40   // RO  [4:0]=PTY [5]=TP [6]=TA [7]=M/S
#define REG_RDS_RT0         0x44   // RO  RadioText, 16 regs 0x44..0x80
#define RDS_RT_REGS         16

/* CONTROLS (0x18) bit masks */
#define CTRL_MUTE_EN        (1u << 0)
#define CTRL_BASS_BOOST_EN  (1u << 1)
#define CTRL_RDS_EN         (1u << 2)
#define CTRL_DEEMPH_75US    (1u << 3)
#define CTRL_MONO_EN        (1u << 4)

/* STATUS (0x10) fields */
#define STS_STEREO_LOCK     (1u << 0)
#define STS_STATION_FOUND   (1u << 1)
#define STS_RSSI_SHIFT      2
#define STS_RSSI_MASK       0x3FFFFu        // 18 bit
#define STS_RDS_SYNC        (1u << 20)

/* FIFO status field helpers (count is zero padded up to bit 15 in HW) */
#define FIFO_COUNT_MASK     0xFFFFu
#define RDS_FIFO_OVF        (1u << 8)
#define RDS_FIFO_EMPTY      (1u << 9)
#define SMP_FIFO_OVF        (1u << 16)
#define SMP_FIFO_EMPTY      (1u << 17)

/* Band plan (kHz, integers - never accumulate floats over a scan) */
#define FREQ_MIN_KHZ        76000
#define FREQ_MAX_KHZ        108000
#define DEFAULT_STEP_KHZ    100

/* Settling time for the CIC chain, RSSI averager and pilot PLL */
#define DEFAULT_SETTLE_MS   100

/* Post-resampler audio format produced by the PL */
#define AUDIO_RATE_HZ       48000
#define DEFAULT_AUDIO_W     24              // AUDIO_DATA_WIDTH parameter

// ============================================================================
// GLOBALS
// ============================================================================
static volatile uint32_t *axi_regs = NULL;
static void              *map_base = MAP_FAILED;
static size_t             map_len  = 0;

static unsigned long g_base     = DEFAULT_AXI_BASE;
static double        g_clk_hz   = DEFAULT_CLK_RF_HZ;
static int           g_step_khz = DEFAULT_STEP_KHZ;
static int           g_audio_w  = DEFAULT_AUDIO_W;
static int           g_settle_ms = DEFAULT_SETTLE_MS;

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

/* nanosleep instead of usleep: POSIX.1-2008 removed the latter, and this
   keeps the build free of feature-test-macro surprises on musl. */
static void delay_us(unsigned long us)
{
    struct timespec ts;
    ts.tv_sec  = (time_t)(us / 1000000UL);
    ts.tv_nsec = (long)(us % 1000000UL) * 1000L;
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR && !g_stop)
        ;
}

// ============================================================================
// LOW LEVEL REGISTER ACCESS
// ============================================================================
static inline uint32_t reg_rd(unsigned off) { return axi_regs[off >> 2]; }
static inline void     reg_wr(unsigned off, uint32_t v) { axi_regs[off >> 2] = v; }

static int map_registers(void)
{
    const char *dev = getenv("FM_RADIO_MEM_DEV");
    long page       = sysconf(_SC_PAGESIZE);
    unsigned long page_base, page_off;
    int fd;

    if (page <= 0) page = 4096;
    if (!dev || !*dev) dev = "/dev/mem";

    fd = open(dev, O_RDWR | O_SYNC);
    if (fd == -1) {
        fprintf(stderr, "Error: cannot open %s: %s%s\n", dev, strerror(errno),
                (errno == EACCES || errno == EPERM) ? " (root required)" : "");
        return -1;
    }

    page_base = g_base & ~((unsigned long)page - 1UL);
    page_off  = g_base - page_base;
    /* Map enough pages to cover 0x00..0x80 even from a non page aligned base */
    map_len   = ((page_off + REG_SPAN + (size_t)page - 1) / (size_t)page) * (size_t)page;

    map_base = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                    (off_t)page_base);
    if (map_base == MAP_FAILED) {
        fprintf(stderr, "Error: mmap of 0x%08lX failed: %s\n", g_base, strerror(errno));
        close(fd);
        return -1;
    }
    close(fd);                       /* the mapping stays valid after close() */

    axi_regs = (volatile uint32_t *)((char *)map_base + page_off);
    return 0;
}

static void unmap_registers(void)
{
    if (map_base != MAP_FAILED) {
        munmap(map_base, map_len);
        map_base = MAP_FAILED;
        axi_regs = NULL;
    }
}

/* Cheap sanity check: an unmapped / mis-addressed slave usually reads all-ones
   (interconnect decode error) or the peripheral is simply not there. */
static void warn_if_no_peripheral(void)
{
    uint32_t a = reg_rd(REG_STATUS), b = reg_rd(REG_TUNING);
    if (a == 0xFFFFFFFFu && b == 0xFFFFFFFFu)
        fprintf(stderr,
                "Warning: all registers read 0xFFFFFFFF at base 0x%08lX - wrong base "
                "address, bitstream not loaded, or the AXI segment is smaller than "
                "256 bytes.\n", g_base);
}

// ============================================================================
// FREQUENCY <-> TUNING WORD
// ============================================================================
/* The 1-bit RF front end samples directly at clk_rf, so a station above
   Nyquist (clk/2) is received on its alias. Rounding, not truncation. */
static uint32_t freq_to_tuning(double mhz)
{
    double hz     = mhz * 1e6;
    double target = hz;
    double w;

    if (hz > g_clk_hz / 2.0) target = g_clk_hz - hz;
    if (target < 0.0) target = 0.0;

    w = (target * 4294967296.0) / g_clk_hz + 0.5;
    if (w > 4294967295.0) w = 4294967295.0;
    return (uint32_t)w;
}

/* Exact inverse of the above: reconstruct the in-band candidate. */
static double tuning_to_freq(uint32_t tw)
{
    double target = ((double)tw * g_clk_hz) / 4294967296.0 / 1e6;
    double alias  = g_clk_hz / 1e6 - target;
    double lo = FREQ_MIN_KHZ / 1000.0 - 0.05, hi = FREQ_MAX_KHZ / 1000.0 + 0.05;

    if (target >= lo && target <= hi) return target;   /* 1st Nyquist zone */
    if (alias  >= lo && alias  <= hi) return alias;    /* folded */
    return target;                                     /* out of band, report raw */
}

static void set_frequency(double mhz) { reg_wr(REG_TUNING, freq_to_tuning(mhz)); }
static double get_frequency(void)     { return tuning_to_freq(reg_rd(REG_TUNING)); }

// ============================================================================
// STATUS / CONTROL
// ============================================================================
typedef struct {
    int      stereo;
    int      found;
    int      rds_sync;
    uint32_t rssi;
} fm_status_t;

static void get_status(fm_status_t *s)
{
    uint32_t v = reg_rd(REG_STATUS);
    s->stereo   = (v & STS_STEREO_LOCK)   ? 1 : 0;
    s->found    = (v & STS_STATION_FOUND) ? 1 : 0;
    s->rds_sync = (v & STS_RDS_SYNC)      ? 1 : 0;
    s->rssi     = (v >> STS_RSSI_SHIFT) & STS_RSSI_MASK;
}

static void set_volume(unsigned vol)
{
    if (vol > 15) vol = 15;
    reg_wr(REG_VOLUME, vol);
}

static void set_control_bit(uint32_t mask, int enable)
{
    uint32_t v = reg_rd(REG_CONTROLS);
    if (enable) v |= mask; else v &= ~mask;
    reg_wr(REG_CONTROLS, v);
}

// ============================================================================
// RDS HELPERS
// ============================================================================
static const char *pty_rds[32] = {
    "None", "News", "Current Affairs", "Information", "Sport", "Education",
    "Drama", "Culture", "Science", "Varied", "Pop Music", "Rock Music",
    "Easy Listening", "Light Classical", "Serious Classical", "Other Music",
    "Weather", "Finance", "Children's Programmes", "Social Affairs", "Religion",
    "Phone In", "Travel", "Leisure", "Jazz Music", "Country Music",
    "National Music", "Oldies Music", "Folk Music", "Documentary",
    "Alarm Test", "Alarm"
};

static const char *pty_rbds[32] = {
    "None", "News", "Information", "Sports", "Talk", "Rock", "Classic Rock",
    "Adult Hits", "Soft Rock", "Top 40", "Country", "Oldies", "Soft",
    "Nostalgia", "Jazz", "Classical", "Rhythm and Blues", "Soft R&B",
    "Foreign Language", "Religious Music", "Religious Talk", "Personality",
    "Public", "College", "Unassigned", "Unassigned", "Unassigned",
    "Unassigned", "Unassigned", "Weather", "Emergency Test", "ALERT!"
};

/* The PTY code table depends on the region, which is exactly what the
   de-emphasis selection already tells us (75 us => RBDS/North America). */
static const char *pty_name(unsigned pty, uint32_t controls)
{
    if (pty > 31) return "?";
    return (controls & CTRL_DEEMPH_75US) ? pty_rbds[pty] : pty_rds[pty];
}

static void sanitize(char *s)
{
    size_t i, n = strlen(s);
    for (i = 0; i < n; i++)
        if (!isprint((unsigned char)s[i])) s[i] = '.';
    while (n > 0 && s[n - 1] == ' ') s[--n] = '\0';
}

static void get_rds_ps(char out[9])
{
    uint32_t a = reg_rd(REG_RDS_PS0);
    uint32_t b = reg_rd(REG_RDS_PS1);
    int i;
    for (i = 0; i < 4; i++) out[i]     = (char)((a >> (24 - 8 * i)) & 0xFF);
    for (i = 0; i < 4; i++) out[4 + i] = (char)((b >> (24 - 8 * i)) & 0xFF);
    out[8] = '\0';
    sanitize(out);
}

/* RadioText: 0x44 MUST be read first - that read latches all 64 characters
   into the PL shadow register, the other 15 registers read out of it. */
static void get_rds_rt(char out[65])
{
    uint32_t w[RDS_RT_REGS];
    int i, j, n = 0;

    w[0] = reg_rd(REG_RDS_RT0);                 /* takes the snapshot */
    for (i = 1; i < RDS_RT_REGS; i++)
        w[i] = reg_rd(REG_RDS_RT0 + 4 * (unsigned)i);

    for (i = 0; i < RDS_RT_REGS; i++) {
        for (j = 0; j < 4; j++) {
            char c = (char)((w[i] >> (24 - 8 * j)) & 0xFF);
            if (c == 0x0D) goto done;           /* IEC 62106 terminator */
            out[n++] = c;
        }
    }
done:
    out[n] = '\0';
    sanitize(out);
}

// ============================================================================
// STATUS OUTPUT
// ============================================================================
static void print_status(void)
{
    fm_status_t st;
    uint32_t ctrl = reg_rd(REG_CONTROLS);
    uint32_t vol  = reg_rd(REG_VOLUME) & 0x0F;
    uint32_t tw   = reg_rd(REG_TUNING);
    uint32_t err  = reg_rd(REG_RDS_ERR_STATS);
    uint32_t flags, pi;
    char ps[9], rt[65];

    get_status(&st);
    pi    = reg_rd(REG_RDS_PI) & 0xFFFF;
    flags = reg_rd(REG_RDS_FLAGS);
    get_rds_ps(ps);
    get_rds_rt(rt);

    printf("Frequency         : %.2f MHz (tuning word 0x%08X)\n", tuning_to_freq(tw), tw);
    printf("Station found     : %s\n", st.found ? "YES" : "NO");
    printf("Stereo pilot lock : %s\n", st.stereo ? "YES" : "NO");
    printf("Signal RSSI level : %u\n", st.rssi);
    printf("Volume level      : %u/15\n", vol);
    printf("Mute              : %s\n", (ctrl & CTRL_MUTE_EN) ? "ON" : "OFF");
    printf("Forced mono       : %s\n", (ctrl & CTRL_MONO_EN) ? "ON" : "OFF");
    printf("Bass boost        : %s\n", (ctrl & CTRL_BASS_BOOST_EN) ? "ON" : "OFF");
    printf("De-emphasis       : %s\n",
           (ctrl & CTRL_DEEMPH_75US) ? "75 us (US/KR)" : "50 us (EU/RU/JP)");
    printf("RDS decoder       : %s\n", (ctrl & CTRL_RDS_EN) ? "ENABLED" : "DISABLED");
    printf("RDS sync          : %s\n", st.rds_sync ? "YES" : "NO");
    printf("RDS PI            : 0x%04X\n", pi);
    printf("RDS PS            : \"%s\"\n", ps);
    printf("RDS PTY           : %u (%s)\n", flags & 0x1F, pty_name(flags & 0x1F, ctrl));
    printf("RDS TP / TA       : %s / %s\n",
           (flags & (1u << 5)) ? "YES" : "NO", (flags & (1u << 6)) ? "YES" : "NO");
    printf("RDS M/S           : %s\n", (flags & (1u << 7)) ? "Music" : "Speech");
    printf("RDS RadioText     : \"%s\"\n", rt);
    printf("RDS blocks ok/bad : %u / %u (free running, wraps at 65535)\n",
           err & 0xFFFF, err >> 16);
}

static void json_escape(const char *in, char *out, size_t outsz)
{
    size_t o = 0;
    for (; *in && o + 2 < outsz; in++) {
        if (*in == '"' || *in == '\\') { out[o++] = '\\'; out[o++] = *in; }
        else out[o++] = *in;
    }
    out[o] = '\0';
}

static void print_status_json(void)
{
    fm_status_t st;
    uint32_t ctrl  = reg_rd(REG_CONTROLS);
    uint32_t vol   = reg_rd(REG_VOLUME) & 0x0F;
    uint32_t tw    = reg_rd(REG_TUNING);
    uint32_t err   = reg_rd(REG_RDS_ERR_STATS);
    uint32_t pi, flags;
    char ps[9], rt[65], eps[32], ert[192];

    get_status(&st);
    pi    = reg_rd(REG_RDS_PI) & 0xFFFF;
    flags = reg_rd(REG_RDS_FLAGS);
    get_rds_ps(ps);
    get_rds_rt(rt);
    json_escape(ps, eps, sizeof(eps));
    json_escape(rt, ert, sizeof(ert));

    printf("{\"frequency\":%.2f,\"tuning_word\":%u,\"found\":%d,\"stereo\":%d,"
           "\"rssi\":%u,\"volume\":%u,\"mute\":%d,\"mono\":%d,\"bass_boost\":%d,"
           "\"deemphasis_us\":%d,\"rds_enabled\":%d,\"rds_sync\":%d,\"pi\":%u,"
           "\"ps\":\"%s\",\"pty\":%u,\"pty_name\":\"%s\",\"tp\":%d,\"ta\":%d,"
           "\"ms\":\"%s\",\"radiotext\":\"%s\",\"rds_blocks_ok\":%u,"
           "\"rds_blocks_bad\":%u}\n",
           tuning_to_freq(tw), tw, st.found, st.stereo, st.rssi, vol,
           (ctrl & CTRL_MUTE_EN) ? 1 : 0, (ctrl & CTRL_MONO_EN) ? 1 : 0,
           (ctrl & CTRL_BASS_BOOST_EN) ? 1 : 0,
           (ctrl & CTRL_DEEMPH_75US) ? 75 : 50,
           (ctrl & CTRL_RDS_EN) ? 1 : 0, st.rds_sync, pi, eps,
           flags & 0x1F, pty_name(flags & 0x1F, ctrl),
           (flags & (1u << 5)) ? 1 : 0, (flags & (1u << 6)) ? 1 : 0,
           (flags & (1u << 7)) ? "music" : "speech", ert,
           err & 0xFFFF, err >> 16);
}

static void print_rds(void)
{
    uint32_t ctrl  = reg_rd(REG_CONTROLS);
    uint32_t flags = reg_rd(REG_RDS_FLAGS);
    uint32_t pi    = reg_rd(REG_RDS_PI) & 0xFFFF;
    uint32_t err   = reg_rd(REG_RDS_ERR_STATS);
    fm_status_t st;
    char ps[9], rt[65];

    get_status(&st);
    get_rds_ps(ps);
    get_rds_rt(rt);

    if (!(ctrl & CTRL_RDS_EN))
        printf("Note: RDS decoder is disabled (CONTROLS bit 2) - use -rds-en 1\n\n");

    printf("RDS sync      : %s\n", st.rds_sync ? "YES" : "NO");
    printf("PI code       : 0x%04X\n", pi);
    printf("PS name       : \"%s\"\n", ps);
    printf("PTY           : %u (%s)\n", flags & 0x1F, pty_name(flags & 0x1F, ctrl));
    printf("TP / TA       : %s / %s\n",
           (flags & (1u << 5)) ? "YES" : "NO", (flags & (1u << 6)) ? "YES" : "NO");
    printf("Music / Speech: %s\n", (flags & (1u << 7)) ? "Music" : "Speech");
    printf("RadioText     : \"%s\"\n", rt);
    printf("Blocks ok/bad : %u / %u\n", err & 0xFFFF, err >> 16);
}

// ============================================================================
// MONITOR
// ============================================================================
static void monitor(unsigned interval_ms)
{
    printf("Monitoring (Ctrl-C to stop)...\n");
    while (!g_stop) {
        fm_status_t st;
        uint32_t flags = reg_rd(REG_RDS_FLAGS);
        char ps[9], rt[65];

        get_status(&st);
        get_rds_ps(ps);
        get_rds_rt(rt);

        printf("%7.2f MHz  RSSI %6u  %s %s %s  PTY %2u  PS \"%-8s\"  RT \"%.40s\"\n",
               get_frequency(), st.rssi,
               st.found    ? "SIG" : "---",
               st.stereo   ? "ST " : "MO ",
               st.rds_sync ? "RDS" : "---",
               flags & 0x1F, ps, rt);
        fflush(stdout);
        delay_us((unsigned long)interval_ms * 1000UL);
    }
    printf("\nStopped.\n");
}

// ============================================================================
// SEEK / SCAN
// ============================================================================
static int khz_wrap(int khz, int dir)
{
    khz += dir * g_step_khz;
    if (khz > FREQ_MAX_KHZ) khz = FREQ_MIN_KHZ;
    if (khz < FREQ_MIN_KHZ) khz = FREQ_MAX_KHZ;
    return khz;
}

/* Returns 0 on success, 1 if nothing was found (band fully swept). */
static int seek_station(int start_khz, int direction)
{
    int channels = (FREQ_MAX_KHZ - FREQ_MIN_KHZ) / g_step_khz + 1;
    uint32_t saved_tw = reg_rd(REG_TUNING);
    int khz = start_khz, i;

    printf("Starting SEEK %s from %.2f MHz...\n",
           (direction > 0) ? "UP" : "DOWN", start_khz / 1000.0);

    for (i = 0; i < channels && !g_stop; i++) {
        fm_status_t st;

        khz = khz_wrap(khz, direction);
        set_frequency(khz / 1000.0);

        printf("Scanning: %.2f MHz...   \r", khz / 1000.0);
        fflush(stdout);

        delay_us((unsigned long)g_settle_ms * 1000UL);
        get_status(&st);

        if (st.found) {
            printf("\n\n---> STATION FOUND: %.2f MHz <---\n", khz / 1000.0);
            printf("Signal Level (RSSI): %u\n", st.rssi);
            printf("Stereo Pilot 19kHz : %s\n", st.stereo ? "LOCKED" : "NO");
            return 0;
        }
    }

    /* Nothing found (or interrupted): put the tuner back where it was. */
    reg_wr(REG_TUNING, saved_tw);
    printf("\n%s - returned to %.2f MHz\n",
           g_stop ? "Seek interrupted" : "Seek finished: no station found",
           tuning_to_freq(saved_tw));
    return 1;
}

static void scan_band(unsigned dwell_ms)
{
    uint32_t saved_tw = reg_rd(REG_TUNING);
    int khz, n = 0;

    printf("Scanning %.1f - %.1f MHz in %d kHz steps...\n\n",
           FREQ_MIN_KHZ / 1000.0, FREQ_MAX_KHZ / 1000.0, g_step_khz);
    printf("  Freq      RSSI  Stereo  RDS  PS\n");
    printf("  --------  ----  ------  ---  --------\n");

    for (khz = FREQ_MIN_KHZ; khz <= FREQ_MAX_KHZ && !g_stop; khz += g_step_khz) {
        fm_status_t st;
        char ps[9] = "";

        set_frequency(khz / 1000.0);
        printf("  %6.2f...\r", khz / 1000.0);
        fflush(stdout);
        delay_us((unsigned long)g_settle_ms * 1000UL);
        get_status(&st);
        if (!st.found) continue;

        if (dwell_ms) {                     /* give the RDS decoder time for PS */
            delay_us((unsigned long)dwell_ms * 1000UL);
            get_status(&st);
        }
        get_rds_ps(ps);

        printf("  %6.2f    %6u  %-6s  %-3s  %s\n", khz / 1000.0, st.rssi,
               st.stereo ? "YES" : "no", st.rds_sync ? "yes" : "-", ps);
        fflush(stdout);
        n++;
    }

    reg_wr(REG_TUNING, saved_tw);
    printf("\n%d station(s) found. Tuner restored to %.2f MHz.\n",
           n, tuning_to_freq(saved_tw));
}

// ============================================================================
// RAW RDS BLOCK FIFO
// ============================================================================
static void dump_rds_blocks(long count)
{
    static const char blk[8] = { 'A', 'B', 'C', 'D', '?', '?', '?', '?' };
    long got = 0;
    unsigned overflows = 0;

    printf("  #     block  data    status\n");
    printf("  ----  -----  ------  ----------\n");

    while (got < count && !g_stop) {
        uint32_t stat = reg_rd(REG_RDS_FIFO_STAT);   /* NB: clears overflow flag */
        uint32_t n    = stat & 0xFFu;

        if (stat & RDS_FIFO_OVF) overflows++;
        if (n == 0) { delay_us(20000); continue; }

        while (n-- && got < count) {
            uint32_t d = reg_rd(REG_RDS_FIFO_DATA);  /* read = pop */
            printf("  %4ld  %c      0x%04X  %s\n", got, blk[(d >> 16) & 7],
                   d & 0xFFFF,
                   (d & (1u << 20)) ? "uncorrectable" :
                   (d & (1u << 19)) ? "ok" : "?");
            got++;
        }
    }
    printf("\n%ld block(s), %u FIFO overflow event(s).\n", got, overflows);
}

/* Discard everything currently queued in a sample FIFO. Bounded so a
   producer that outruns us can never turn this into an infinite loop. */
static void fifo_drain(unsigned stat_off, unsigned data_off)
{
    unsigned long guard = 0;
    while (guard < 65536UL && !g_stop) {
        uint32_t n = reg_rd(stat_off) & FIFO_COUNT_MASK;
        if (n == 0) return;
        while (n-- > 0 && guard < 65536UL) { reg_rd(data_off); guard++; }
    }
}

// ============================================================================
// RAW MPX CAPTURE
// ============================================================================
static int capture_mpx(const char *path, long samples)
{
    int      to_stdout = !strcmp(path, "-");
    FILE    *f         = to_stdout ? stdout : fopen(path, "wb");
    long     got       = 0;
    unsigned overflows = 0;
    int      rc        = 0;

    if (!f) {
        fprintf(stderr, "Error: cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }

    /* Drain whatever is stale in the FIFO first (bounded: never spin forever
       if the producer somehow outruns the drain). */
    fifo_drain(REG_MPX_FIFO_STAT, REG_MPX_FIFO_DATA);

    while (got < samples && !g_stop && rc == 0) {
        uint32_t stat = reg_rd(REG_MPX_FIFO_STAT);
        uint32_t n    = stat & FIFO_COUNT_MASK;

        if (stat & SMP_FIFO_OVF) overflows++;
        if (n == 0) { delay_us(1000); continue; }

        while (n-- > 0 && got < samples) {
            int16_t s = (int16_t)(reg_rd(REG_MPX_FIFO_DATA) & 0xFFFF);
            uint8_t le[2] = { (uint8_t)((uint16_t)s & 0xFF),
                              (uint8_t)(((uint16_t)s >> 8) & 0xFF) };
            if (fwrite(le, 1, 2, f) != 2) {
                fprintf(stderr, "\nError: write failed: %s\n", strerror(errno));
                rc = 1;
                break;
            }
            got++;
        }
    }

    if (to_stdout) fflush(f);
    else           fclose(f);

    fprintf(stderr, "\nCaptured %ld MPX samples (s16le, 250 kHz), %u overflow event(s).\n",
            got, overflows);
    if (overflows)
        fprintf(stderr, "Overflows mean the poller could not keep up - samples were lost.\n");
    return rc;
}

// ============================================================================
// AUDIO CAPTURE (48 kHz stereo, post volume/mute/resampler)
// ============================================================================
static void wav_put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static void wav_put16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
}

static int wav_write_header(FILE *f, uint32_t data_bytes)
{
    uint8_t h[44];
    memcpy(h, "RIFF", 4);       wav_put32(h + 4, 36 + data_bytes);
    memcpy(h + 8, "WAVEfmt ", 8); wav_put32(h + 16, 16);
    wav_put16(h + 20, 1);       wav_put16(h + 22, 2);            /* PCM, stereo */
    wav_put32(h + 24, AUDIO_RATE_HZ);
    wav_put32(h + 28, AUDIO_RATE_HZ * 2 * 2);                    /* byte rate */
    wav_put16(h + 32, 4);       wav_put16(h + 34, 16);           /* align, bits */
    memcpy(h + 36, "data", 4);  wav_put32(h + 40, data_bytes);
    return fwrite(h, 1, sizeof(h), f) == sizeof(h) ? 0 : -1;
}

static int capture_audio(const char *path, double seconds)
{
    long     want      = (long)(seconds * AUDIO_RATE_HZ + 0.5) * 2;  /* L+R entries */
    long     got       = 0;
    unsigned overflows = 0;
    int      to_stdout = !strcmp(path, "-");
    FILE    *f         = to_stdout ? stdout : fopen(path, "wb");
    int      shift     = g_audio_w - 16;
    int      rc        = 0;

    if (!f) {
        fprintf(stderr, "Error: cannot open %s: %s\n", path, strerror(errno));
        return 1;
    }
    if (shift < 0) shift = 0;

    /* Drain stale data, let a couple of fresh pairs accumulate, then align:
       entries are written L,R back to back, so an odd count means the head is
       an R sample - pop one to restore L/R interleaving. */
    fifo_drain(REG_AUD_FIFO_STAT, REG_AUD_FIFO_DATA);
    delay_us(2000);
    if ((reg_rd(REG_AUD_FIFO_STAT) & FIFO_COUNT_MASK) & 1u) reg_rd(REG_AUD_FIFO_DATA);

    if (!to_stdout && wav_write_header(f, 0) != 0) {
        fprintf(stderr, "Error: cannot write WAV header: %s\n", strerror(errno));
        fclose(f);
        return 1;
    }

    while (got < want && !g_stop && rc == 0) {
        uint32_t stat = reg_rd(REG_AUD_FIFO_STAT);
        uint32_t n    = stat & FIFO_COUNT_MASK;

        if (stat & SMP_FIFO_OVF) overflows++;
        if (got + (long)n > want) n = (uint32_t)(want - got);
        n &= ~1u;                       /* never split an L/R pair */
        if (n == 0) { delay_us(2000); continue; }

        while (n-- > 0) {
            int32_t v = (int32_t)reg_rd(REG_AUD_FIFO_DATA);   /* sign extended */
            int16_t s = (int16_t)(v >> shift);
            uint8_t le[2] = { (uint8_t)((uint16_t)s & 0xFF),
                              (uint8_t)(((uint16_t)s >> 8) & 0xFF) };
            if (fwrite(le, 1, 2, f) != 2) {
                fprintf(stderr, "\nError: write failed: %s\n", strerror(errno));
                rc = 1;
                break;
            }
            got++;
        }
    }

    if (to_stdout) {
        fflush(f);
    } else {
        /* Patch the RIFF/data sizes now that the real length is known. */
        if (fseek(f, 0, SEEK_SET) == 0) wav_write_header(f, (uint32_t)(got * 2));
        fclose(f);
    }

    fprintf(stderr, "\nCaptured %ld frames (%.2f s, s16le 48 kHz stereo), "
                    "%u overflow event(s).\n", got / 2, (got / 2.0) / AUDIO_RATE_HZ,
            overflows);
    if (overflows)
        fprintf(stderr, "Overflows mean dropped samples - AXI polling is not a real-time "
                        "audio path, use the I2S/ALSA output for playback.\n");
    return rc;
}

// ============================================================================
// REGISTER DUMP
// ============================================================================
static void dump_registers(int include_destructive)
{
    static const struct { unsigned off; const char *name; int pops; } map[] = {
        { REG_TUNING,        "TUNING_WORD",    0 },
        { REG_RDS_PS0,       "RDS_PS_0",       0 },
        { REG_RDS_PS1,       "RDS_PS_1",       0 },
        { REG_STATUS,        "STATUS",         0 },
        { REG_VOLUME,        "VOLUME",         0 },
        { REG_CONTROLS,      "CONTROLS",       0 },
        { REG_RDS_PI,        "RDS_PI",         0 },
        { REG_RDS_FIFO_STAT, "RDS_FIFO_STAT",  0 },
        { REG_RDS_FIFO_DATA, "RDS_FIFO_DATA",  1 },
        { REG_RDS_ERR_STATS, "RDS_ERR_STATS",  0 },
        { REG_MPX_FIFO_STAT, "MPX_FIFO_STAT",  0 },
        { REG_MPX_FIFO_DATA, "MPX_FIFO_DATA",  1 },
        { REG_MPX_SHIFT,     "MPX_SHIFT",      0 },
        { REG_AUD_FIFO_STAT, "AUDIO_FIFO_STAT",0 },
        { REG_AUD_FIFO_DATA, "AUDIO_FIFO_DATA",1 },
        { REG_RDS_FLAGS,     "RDS_FLAGS",      0 },
    };
    size_t i;
    int k;

    printf("Note: reading *_FIFO_STAT clears its overflow flag in hardware.\n\n");
    for (i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        if (map[i].pops && !include_destructive) {
            printf("  0x%02X  %-16s  (skipped: reading pops the FIFO, use -regs all)\n",
                   map[i].off, map[i].name);
            continue;
        }
        printf("  0x%02X  %-16s  0x%08X\n", map[i].off, map[i].name, reg_rd(map[i].off));
    }
    /* RadioText block: 0x44 first, so the shadow stays coherent. */
    printf("  0x%02X  %-16s  0x%08X\n", REG_RDS_RT0, "RDS_RT_0", reg_rd(REG_RDS_RT0));
    for (k = 1; k < RDS_RT_REGS; k++)
        printf("  0x%02X  RDS_RT_%-9d  0x%08X\n", REG_RDS_RT0 + 4 * (unsigned)k, k,
               reg_rd(REG_RDS_RT0 + 4 * (unsigned)k));
}

// ============================================================================
// ARGUMENT HELPERS
// ============================================================================
static int parse_long(const char *s, long *out, long lo, long hi, const char *what)
{
    char *end;
    long v;
    errno = 0;
    v = strtol(s, &end, 0);
    if (errno || end == s || *end) {
        fprintf(stderr, "Error: %s: '%s' is not a number\n", what, s);
        return -1;
    }
    if (v < lo || v > hi) {
        fprintf(stderr, "Error: %s must be between %ld and %ld (got %ld)\n", what, lo, hi, v);
        return -1;
    }
    *out = v;
    return 0;
}

static int parse_freq(const char *s, double *out)
{
    char *end;
    double v;
    errno = 0;
    v = strtod(s, &end);
    if (errno || end == s || *end) {
        fprintf(stderr, "Error: '%s' is not a frequency\n", s);
        return -1;
    }
    if (v < FREQ_MIN_KHZ / 1000.0 || v > FREQ_MAX_KHZ / 1000.0) {
        fprintf(stderr, "Error: frequency must be between %.1f and %.1f MHz\n",
                FREQ_MIN_KHZ / 1000.0, FREQ_MAX_KHZ / 1000.0);
        return -1;
    }
    *out = v;
    return 0;
}

static int freq_to_khz(double mhz)
{
    return (int)(mhz * 1000.0 + 0.5);
}

// ============================================================================
// USAGE
// ============================================================================
static void print_usage(const char *prog)
{
    printf("Zynq FM SDR Control Utility (axi_sdr_fm)\n");
    printf("Usage: %s [global options] <command> [value]\n\n", prog);
    printf("Global options (must come before the command):\n");
    printf("  -b <addr>        AXI base address (default 0x%08lX, env FM_RADIO_BASE)\n",
           (unsigned long)DEFAULT_AXI_BASE);
    printf("  -k <hz>          clk_rf frequency (default %.0f, env FM_RADIO_CLK)\n",
           DEFAULT_CLK_RF_HZ);
    printf("  -s <khz>         channel step for seek/scan (default %d)\n", DEFAULT_STEP_KHZ);
    printf("  -w <bits>        AUDIO_DATA_WIDTH of the build (default %d)\n", DEFAULT_AUDIO_W);
    printf("  -d <ms>          Settle time per channel for seek/scan (default %d)\n\n",
           DEFAULT_SETTLE_MS);
    printf("Information:\n");
    printf("  -c, --current    Show frequency, status, audio settings and RDS\n");
    printf("  -j, --json       Same information as a single JSON object\n");
    printf("  -rds             RDS only (PI, PS, PTY, TP/TA, M/S, RadioText, errors)\n");
    printf("  -m [ms]          Live monitor until Ctrl-C (default 1000 ms)\n");
    printf("  -regs [all]      Dump the register map ('all' also pops the FIFOs)\n\n");
    printf("Tuning:\n");
    printf("  -f <freq>        Tune to a frequency in MHz (e.g. %s -f 101.9)\n", prog);
    printf("  -up [freq]       Seek UP from <freq> or from the current frequency\n");
    printf("  -down [freq]     Seek DOWN from <freq> or from the current frequency\n");
    printf("  -scan [ms]       Sweep the whole band, list stations (dwell for RDS PS)\n\n");
    printf("Audio controls:\n");
    printf("  -vol <0-15>      Set output volume level (0 = MIN, 15 = MAX)\n");
    printf("  -mute <0/1>      Disable (0) or enable (1) audio mute\n");
    printf("  -mono <0/1>      Force mono (1) or allow stereo (0)\n");
    printf("  -bass <0/1>      Bass boost off (0) / on (1)\n");
    printf("  -rds-en <0/1>    Enable (1) or disable (0) the RDS decoder\n");
    printf("  -eu              De-emphasis 50 us (Europe/Russia/Japan)\n");
    printf("  -us              De-emphasis 75 us (USA/South Korea)\n\n");
    printf("Capture and debug:\n");
    printf("  -mpxshift [0-15] Show or set the raw MPX export shift\n");
    printf("  -mpx <file> <n>  Capture n raw MPX samples (s16le, 250 kHz, '-' = stdout)\n");
    printf("  -rec <file> <s>  Record s seconds of audio to a WAV file ('-' = raw stdout)\n");
    printf("  -rdsraw [n]      Dump n raw RDS blocks from the FIFO (default 64)\n");
    printf("  -h, --help       This help\n");
}

// ============================================================================
// MAIN
// ============================================================================
int main(int argc, char *argv[])
{
    const char *prog = argv[0];
    const char *env;
    char *cmd;
    int rc = EXIT_SUCCESS;
    long tmp;

    if ((env = getenv("FM_RADIO_BASE")) && *env) g_base   = strtoul(env, NULL, 0);
    if ((env = getenv("FM_RADIO_CLK"))  && *env) g_clk_hz = strtod(env, NULL);

    /* ---- global options ---- */
    while (argc >= 3 && argv[1][0] == '-' && argv[1][1] != '\0' &&
           argv[1][2] == '\0' && strchr("bkswd", argv[1][1])) {
        switch (argv[1][1]) {
        case 'b': g_base   = strtoul(argv[2], NULL, 0); break;
        case 'k': g_clk_hz = strtod(argv[2], NULL);     break;
        case 's':
            if (parse_long(argv[2], &tmp, 10, 1000, "-s (step)")) return EXIT_FAILURE;
            g_step_khz = (int)tmp;
            break;
        case 'w':
            if (parse_long(argv[2], &tmp, 8, 32, "-w (audio width)")) return EXIT_FAILURE;
            g_audio_w = (int)tmp;
            break;
        case 'd':
            if (parse_long(argv[2], &tmp, 1, 5000, "-d (settle time)")) return EXIT_FAILURE;
            g_settle_ms = (int)tmp;
            break;
        }
        argv += 2;
        argc -= 2;
    }
    if (g_clk_hz < 1e6) {
        fprintf(stderr, "Error: clk_rf (%.0f Hz) is implausible\n", g_clk_hz);
        return EXIT_FAILURE;
    }

    if (argc < 2) { print_usage(prog); return EXIT_FAILURE; }
    cmd = argv[1];

    /* Help never needs hardware access (and therefore never needs root). */
    if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help")) { print_usage(prog); return EXIT_SUCCESS; }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (map_registers() != 0) return EXIT_FAILURE;
    warn_if_no_peripheral();

    if (!strcmp(cmd, "-c") || !strcmp(cmd, "--current")) {
        print_status();
    }
    else if (!strcmp(cmd, "-j") || !strcmp(cmd, "--json")) {
        print_status_json();
    }
    else if (!strcmp(cmd, "-rds")) {
        print_rds();
    }
    else if (!strcmp(cmd, "-m") || !strcmp(cmd, "--monitor")) {
        long ms = 1000;
        if (argc == 3 && parse_long(argv[2], &ms, 50, 60000, "-m (interval)")) rc = EXIT_FAILURE;
        else monitor((unsigned)ms);
    }
    else if (!strcmp(cmd, "-regs")) {
        dump_registers(argc == 3 && !strcmp(argv[2], "all"));
    }
    else if (!strcmp(cmd, "-f")) {
        double f;
        if (argc != 3 || parse_freq(argv[2], &f)) rc = EXIT_FAILURE;
        else { set_frequency(f); printf("Tuned to %.2f MHz\n", f); }
    }
    else if (!strcmp(cmd, "-up") || !strcmp(cmd, "-down")) {
        int dir = !strcmp(cmd, "-up") ? 1 : -1;
        double f;
        if (argc == 3) {
            if (parse_freq(argv[2], &f)) rc = EXIT_FAILURE;
        } else if (argc == 2) {
            f = get_frequency();
            if (f < FREQ_MIN_KHZ / 1000.0 || f > FREQ_MAX_KHZ / 1000.0)
                f = FREQ_MIN_KHZ / 1000.0;      /* uninitialized tuner */
        } else {
            fprintf(stderr, "Error: %s takes at most one frequency\n", cmd);
            rc = EXIT_FAILURE;
        }
        if (rc == EXIT_SUCCESS && seek_station(freq_to_khz(f), dir)) rc = EXIT_FAILURE;
    }
    else if (!strcmp(cmd, "-scan")) {
        long dwell = 0;
        if (argc == 3 && parse_long(argv[2], &dwell, 0, 10000, "-scan (dwell)")) rc = EXIT_FAILURE;
        else scan_band((unsigned)dwell);
    }
    else if (!strcmp(cmd, "-vol")) {
        if (argc != 3 || parse_long(argv[2], &tmp, 0, 15, "-vol")) rc = EXIT_FAILURE;
        else { set_volume((unsigned)tmp); printf("Volume set to %ld/15\n", tmp); }
    }
    else if (!strcmp(cmd, "-mute") || !strcmp(cmd, "-mono") ||
             !strcmp(cmd, "-bass") || !strcmp(cmd, "-rds-en")) {
        uint32_t mask = !strcmp(cmd, "-mute") ? CTRL_MUTE_EN :
                        !strcmp(cmd, "-mono") ? CTRL_MONO_EN :
                        !strcmp(cmd, "-bass") ? CTRL_BASS_BOOST_EN : CTRL_RDS_EN;
        if (argc != 3 || parse_long(argv[2], &tmp, 0, 1, cmd)) rc = EXIT_FAILURE;
        else {
            set_control_bit(mask, (int)tmp);
            printf("%s is now %s\n", cmd + 1, tmp ? "ON" : "OFF");
        }
    }
    else if (!strcmp(cmd, "-us")) {
        set_control_bit(CTRL_DEEMPH_75US, 1);
        printf("De-emphasis set to 75 us (USA/South Korea)\n");
    }
    else if (!strcmp(cmd, "-eu")) {
        set_control_bit(CTRL_DEEMPH_75US, 0);
        printf("De-emphasis set to 50 us (Europe/Russia/Japan)\n");
    }
    else if (!strcmp(cmd, "-mpxshift")) {
        if (argc == 2) printf("MPX shift: %u\n", reg_rd(REG_MPX_SHIFT) & 0x0F);
        else if (argc != 3 || parse_long(argv[2], &tmp, 0, 15, "-mpxshift")) rc = EXIT_FAILURE;
        else { reg_wr(REG_MPX_SHIFT, (uint32_t)tmp); printf("MPX shift set to %ld\n", tmp); }
    }
    else if (!strcmp(cmd, "-mpx")) {
        if (argc != 4 || parse_long(argv[3], &tmp, 1, 100000000L, "-mpx (samples)"))
            rc = EXIT_FAILURE;
        else rc = capture_mpx(argv[2], tmp) ? EXIT_FAILURE : EXIT_SUCCESS;
    }
    else if (!strcmp(cmd, "-rec")) {
        char *end;
        double secs;
        errno = 0;
        secs = (argc == 4) ? strtod(argv[3], &end) : 0.0;
        if (argc != 4 || errno || end == argv[3] || *end || secs <= 0.0 || secs > 3600.0) {
            fprintf(stderr, "Error: usage: %s -rec <file.wav> <seconds 0..3600>\n", prog);
            rc = EXIT_FAILURE;
        } else rc = capture_audio(argv[2], secs) ? EXIT_FAILURE : EXIT_SUCCESS;
    }
    else if (!strcmp(cmd, "-rdsraw")) {
        long n = 64;
        if (argc == 3 && parse_long(argv[2], &n, 1, 1000000L, "-rdsraw (count)")) rc = EXIT_FAILURE;
        else dump_rds_blocks(n);
    }
    else {
        fprintf(stderr, "Unknown command: %s\n\n", cmd);
        print_usage(prog);
        rc = EXIT_FAILURE;
    }

    unmap_registers();
    return rc;
}

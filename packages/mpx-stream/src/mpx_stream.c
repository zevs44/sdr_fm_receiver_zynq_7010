/* =============================================================================
 *  mpx_stream - stream a raw MPX or post-resampler audio FIFO for redsea,
 *               a file, the network, or ALSA
 * =============================================================================
 *  Usage:
 *      mpx_stream --source mpx   | redsea --input mpx -r 250k
 *      mpx_stream --source audio -o alsa:default
 *      mpx_stream --source audio -o file:capture.raw
 *      mpx_stream --source audio -o tcp:192.168.1.50:9999
 *
 *  Two sources, same underlying FIFO+AXI4-Lite mechanism (see either
 *  module's own header for its full register map):
 *    --source mpx   (default) axi_sdr_fm_mpx or axi_sdr_fm's raw MPX
 *                    composite -- mono, signed 16-bit, 250 kHz nominal,
 *                    registers at 0x2C (STAT) / 0x30 (DATA).
 *    --source audio  axi_sdr_fm ONLY (axi_sdr_fm_mpx has no audio chain
 *                    to tap -- it removes fm_stereo_demod/audio_resampler
 *                    entirely) -- post-resampler stereo audio, the same
 *                    signal already feeding fm_ds_dac/i2s_tx (after
 *                    volume/mute, 48 kHz nominal), interleaved L,R,L,R...,
 *                    registers at 0x38 (STAT) / 0x3C (DATA).
 *
 *  *** AUDIO SAMPLE FORMAT -- read this before piping it anywhere. ***
 *  The DATA register sign-extends the FPGA's AUDIO_DATA_WIDTH-bit sample
 *  into a 32-bit word without rescaling it. With the default
 *  AUDIO_DATA_WIDTH=24 that means: 4 bytes per sample, little endian, 24
 *  significant bits RIGHT-JUSTIFIED, top byte just sign. In ALSA terms
 *  that is exactly S24_LE (physical width 32, logical width 24) -- NOT
 *  S32_LE, and NOT S24_3LE (which is the packed 3-byte variant).
 *  Consumers must be told S24_LE:
 *      ... | aplay -D plughw:0,0 -t raw -r 48000 -f S24_LE -c 2
 *  Calling it S32_LE makes the consumer read +-2^23 as 1/256 of full
 *  scale -- a 48 dB attenuation that sounds like silence. Calling it
 *  S16_LE (or forgetting -c 2) misaligns the frames entirely and reads
 *  low-order bits as full-scale samples, which sounds like loud noise.
 *  If you built the FPGA with a different AUDIO_DATA_WIDTH, pass
 *  --audio-bits to match; the -o alsa backend picks its format from it.
 *
 *  Both sources share tuning_word at 0x00; axi_sdr_fm's other registers
 *  (rds_ps, status, volume, controls, RDS FIFO, REG_MPX_SHIFT, etc.) live
 *  at addresses this tool doesn't otherwise touch.
 *
 *  Output backends (-o / --output, default stdout):
 *    stdout                    original behavior, pipe to redsea/csdr/aplay/etc.
 *    file:PATH                 raw samples, e.g. file:capture.raw
 *    tcp:HOST:PORT             connects once, streams over a TCP socket
 *    udp:HOST:PORT             connects once, sends MTU-safe UDP datagrams
 *    alsa:DEVICE               direct playback via libasound (e.g. alsa:default,
 *                              alsa:hw:0,0, alsa:plughw:0,0 -- plughw lets ALSA
 *                              convert the format/rate if the raw hw: device
 *                              doesn't natively support S16/S32 or the exact
 *                              rate; hw: expects an exact match)
 *  Note: --source mpx isn't really meant for -o alsa -- it's the raw
 *  undecoded MPX composite, not demodulated audio, so it would just sound
 *  like noise. -o alsa is for --source audio; --source mpx normally still
 *  wants something like redsea downstream, or csdr for further DSP (see
 *  earlier conversation for that pipeline).
 *
 *  Neither module has a kernel driver for either export path (no V4L2/
 *  ALSA binding decodes or exposes them), so this tool talks to the
 *  AXI4-Lite registers directly via mmap(/dev/mem), the same approach
 *  fm-ctrl uses for fm_transmitter_axi.
 *
 *  *** SET AXI_MPX_BASE_DEFAULT BELOW (or pass -b) to match your Vivado
 *  *** Address Editor assignment for WHICHEVER instance you're targeting
 *  *** -- axi_sdr_fm_mpx and axi_sdr_fm are separate IP instances in the
 *  *** block design and will generally sit at different addresses. This
 *  *** file has no way to know either value on its own, so the constant
 *  *** below is a placeholder, not read from a real address map.
 *
 *  Frequency setting (tuning_word at 0x00, applies to either source since
 *  both derive from the same RF front end): -f/--freq takes Hz (or a
 *  convenient rtl_fm-style "87.9M" suffix) and computes the tuning_word
 *  using the same NCO convention as fm-ctrl: a 32-bit phase accumulator
 *  clocked at clk_rf=250MHz, i.e. tuning_word = round(freq_hz * 2^32 /
 *  250e6) -- taken on the strength of that being the confirmed, matching
 *  convention, not independently derived or checked against real
 *  hardware. -t/--tune-raw writes an already-computed raw register value
 *  instead, and is mutually exclusive with -f. -s/--shift (REG_MPX_SHIFT)
 *  only applies to --source mpx -- the audio path's level is instead
 *  governed by axi_sdr_fm's own existing REG_VOLUME (0x14) and MUTE_EN
 *  (0x18 bit 0). REG_VOLUME resets to 0 on every FPGA reset, so --source
 *  audio is silent by default until something sets it -- -V/--volume
 *  (0-15) does that here, so a fresh reset doesn't need a separate tool
 *  or LuCI just to hear anything.
 * =============================================================================
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <getopt.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

#ifdef MPX_STREAM_NO_ALSA
/* Selftest build: avoid a hard dependency on libasound for the pure-logic
 * checks that don't touch it. The real build always has ALSA available. */
#else
#include <alsa/asoundlib.h>
#endif

/* ---- register map: shared by both sources for tuning_word; each source
 * has its own STAT/DATA pair (see file header). ---- */
#define REG_TUNING_WORD     0x00u   /* RW, both sources */
#define REG_MPX_SHIFT       0x34u   /* RW, [3:0], mpx source only */
#define REG_VOLUME          0x14u   /* RW, [3:0], audio source only -- axi_sdr_fm's own existing register */

#define STAT_EMPTY_BIT      17
#define STAT_OVERFLOW_BIT   16
#define STAT_COUNT_MASK     0x7FFu  /* bits[10:0] -- matches the default 1024-deep FIFOs on both sources;
                                     * if either was instantiated with a different *_FIFO_DEPTH, the
                                     * remaining count bits above the real ADDR_W are just always-zero
                                     * padding on the RTL side, so this wider mask still reads correctly. */

typedef struct {
    const char *name;
    unsigned    reg_stat;
    unsigned    reg_data;
    int         sample_bytes;   /* 2 = mono s16 (mpx), 4 = stereo-interleaved s32 (audio) */
    int         channels;
    unsigned    nominal_rate_hz;
} source_desc_t;

static const source_desc_t SRC_MPX   = { "mpx",   0x2Cu, 0x30u, 2, 1, 250000u };
static const source_desc_t SRC_AUDIO = { "audio", 0x38u, 0x3Cu, 4, 2, 48000u  };

#define AXI_MPX_BASE_DEFAULT 0x43D00000UL   /* PLACEHOLDER -- see header comment above */
#define AXI_REG_WINDOW       0x40u          /* registers span 0x00-0x3C */

/* ---- Hz <-> tuning_word conversion (see file header) ---- */
#define NCO_WIDTH_BITS  32
#define NCO_CLK_HZ      250000000UL
#define FM_BAND_LOW_HZ  87500000.0
#define FM_BAND_HIGH_HZ 108000000.0

static uint32_t freq_to_tuning_word(double freq_hz, int verbose) {
    if (verbose && (freq_hz < FM_BAND_LOW_HZ || freq_hz > FM_BAND_HIGH_HZ))
        fprintf(stderr,
            "mpx_stream: NOTE - %.6f MHz is outside the usual FM broadcast band "
            "(87.5-108 MHz); proceeding anyway.\n", freq_hz / 1e6);
    double scale = (double)(1ULL << NCO_WIDTH_BITS) / (double)NCO_CLK_HZ;
    double ftw = freq_hz * scale;
    if (ftw < 0.0) {
        fprintf(stderr, "mpx_stream: WARNING - negative frequency, clamping tuning_word to 0\n");
        ftw = 0.0;
    } else if (ftw > 4294967295.0) {
        fprintf(stderr, "mpx_stream: WARNING - frequency exceeds what a 32-bit tuning_word "
                         "can represent at clk_rf=%luHz, clamping to max\n", NCO_CLK_HZ);
        ftw = 4294967295.0;
    }
    return (uint32_t)(ftw + 0.5);
}

static int parse_freq_hz(const char *s, double *out_hz) {
    char *end;
    double val = strtod(s, &end);
    if (end == s) return -1;
    if (*end == 'M' || *end == 'm') { val *= 1e6; end++; }
    else if (*end == 'k' || *end == 'K') { val *= 1e3; end++; }
    if (*end != '\0') return -1;
    *out_hz = val;
    return 0;
}

/* ---- reg access abstraction (unchanged design from the earlier version:
 * kept separate from main() so the same core loop logic can be, and has
 * been, exercised against a scripted fake register set off-target) ---- */
typedef struct {
    uint32_t (*read)(void *ctx, unsigned offset);
    void     (*write)(void *ctx, unsigned offset, uint32_t val);
    void      *ctx;
} reg_if_t;

typedef struct {
    volatile uint32_t *regs;
    void               *map_base;
    size_t              map_len;
    int                 fd;
} mem_dev_t;

static uint32_t memdev_read(void *ctx, unsigned off) {
    mem_dev_t *d = (mem_dev_t *)ctx;
    return d->regs[off / 4];
}
static void memdev_write(void *ctx, unsigned off, uint32_t val) {
    mem_dev_t *d = (mem_dev_t *)ctx;
    d->regs[off / 4] = val;
}
static int memdev_open(mem_dev_t *d, unsigned long base) {
    long pagesize = sysconf(_SC_PAGESIZE);
    if (pagesize <= 0) pagesize = 4096;
    unsigned long page_base = base & ~((unsigned long)pagesize - 1);
    unsigned long page_off  = base - page_base;

    d->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (d->fd < 0) { perror("open /dev/mem (need root)"); return -1; }
    d->map_len = page_off + AXI_REG_WINDOW;
    d->map_base = mmap(NULL, d->map_len, PROT_READ | PROT_WRITE, MAP_SHARED,
                        d->fd, (off_t)page_base);
    if (d->map_base == MAP_FAILED) { perror("mmap"); close(d->fd); return -1; }
    d->regs = (volatile uint32_t *)((uint8_t *)d->map_base + page_off);
    return 0;
}
static void memdev_close(mem_dev_t *d) {
    munmap(d->map_base, d->map_len);
    close(d->fd);
}

typedef struct { uint32_t count; int empty; int overflow; } stat_t;
static stat_t decode_stat(uint32_t raw) {
    stat_t s;
    s.count    = raw & STAT_COUNT_MASK;
    s.empty    = (int)((raw >> STAT_EMPTY_BIT) & 1u);
    s.overflow = (int)((raw >> STAT_OVERFLOW_BIT) & 1u);
    return s;
}

/* =============================================================================
 * Output sink abstraction. write() returns:
 *    0  ok
 *   -1  fatal error, already reported to stderr -- caller should stop
 *   -2  peer/consumer went away (EPIPE, ALSA disconnect) -- quiet, expected
 *       shutdown, caller should stop without treating it as a failure
 * =============================================================================
 */
typedef struct output_sink {
    int  (*write)(struct output_sink *sink, const uint8_t *buf, size_t len);
    void (*close)(struct output_sink *sink);
    void  *ctx;
} output_sink_t;

/* ---- stdout / file (both just a raw fd, looped to handle short writes) ---- */
typedef struct { int fd; } fd_sink_ctx_t;

static int fd_sink_write(output_sink_t *sink, const uint8_t *buf, size_t len) {
    fd_sink_ctx_t *c = (fd_sink_ctx_t *)sink->ctx;
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(c->fd, buf + off, len - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EPIPE) return -2;
            perror("mpx_stream: write");
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}
static void fd_sink_close(output_sink_t *sink) {
    fd_sink_ctx_t *c = (fd_sink_ctx_t *)sink->ctx;
    if (c->fd != STDOUT_FILENO) close(c->fd);
    free(c);
}
static int open_stdout_sink(output_sink_t *sink) {
    fd_sink_ctx_t *c = malloc(sizeof(*c));
    if (!c) return -1;
    c->fd = STDOUT_FILENO;
    sink->write = fd_sink_write;
    sink->close = fd_sink_close;
    sink->ctx = c;
    return 0;
}
static int open_file_sink(output_sink_t *sink, const char *path) {
    fd_sink_ctx_t *c = malloc(sizeof(*c));
    if (!c) return -1;
    c->fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (c->fd < 0) { perror("mpx_stream: open output file"); free(c); return -1; }
    sink->write = fd_sink_write;
    sink->close = fd_sink_close;
    sink->ctx = c;
    return 0;
}

/* ---- TCP: connect once, then it's just a fd (short-write loop reused) ---- */
static int tcp_connect(const char *host, const char *port) {
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int err = getaddrinfo(host, port, &hints, &res);
    if (err != 0) {
        fprintf(stderr, "mpx_stream: resolving %s:%s: %s\n", host, port, gai_strerror(err));
        return -1;
    }
    int fd = -1;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) { fprintf(stderr, "mpx_stream: couldn't connect to %s:%s\n", host, port); return -1; }
    return fd;
}
static int open_tcp_sink(output_sink_t *sink, const char *host, const char *port) {
    fd_sink_ctx_t *c = malloc(sizeof(*c));
    if (!c) return -1;
    c->fd = tcp_connect(host, port);
    if (c->fd < 0) { free(c); return -1; }
    sink->write = fd_sink_write;
    sink->close = fd_sink_close;
    sink->ctx = c;
    return 0;
}

/* ---- UDP: connected socket (plain write() works), chunked to stay under
 * a conservative MTU-safe payload size so datagrams don't fragment. ---- */
typedef struct { int fd; size_t max_payload; } udp_sink_ctx_t;
#define UDP_SAFE_PAYLOAD 1200u

static int udp_sink_write(output_sink_t *sink, const uint8_t *buf, size_t len) {
    udp_sink_ctx_t *c = (udp_sink_ctx_t *)sink->ctx;
    size_t off = 0;
    while (off < len) {
        size_t chunk = (len - off) < c->max_payload ? (len - off) : c->max_payload;
        ssize_t w = write(c->fd, buf + off, chunk);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == ECONNREFUSED) return -2;  /* no listener -- treat like a closed peer */
            perror("mpx_stream: udp write");
            return -1;
        }
        off += (size_t)w;
    }
    return 0;
}
static void udp_sink_close(output_sink_t *sink) {
    udp_sink_ctx_t *c = (udp_sink_ctx_t *)sink->ctx;
    close(c->fd);
    free(c);
}
static int open_udp_sink(output_sink_t *sink, const char *host, const char *port) {
    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    int err = getaddrinfo(host, port, &hints, &res);
    if (err != 0) {
        fprintf(stderr, "mpx_stream: resolving %s:%s: %s\n", host, port, gai_strerror(err));
        return -1;
    }
    int fd = -1;
    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) { fprintf(stderr, "mpx_stream: couldn't set up UDP socket to %s:%s\n", host, port); return -1; }
    udp_sink_ctx_t *c = malloc(sizeof(*c));
    if (!c) { close(fd); return -1; }
    c->fd = fd;
    c->max_payload = UDP_SAFE_PAYLOAD;
    sink->write = udp_sink_write;
    sink->close = udp_sink_close;
    sink->ctx = c;
    return 0;
}

/* ---- ALSA: direct playback via libasound ---- */
#ifndef MPX_STREAM_NO_ALSA
typedef struct { snd_pcm_t *pcm; int bytes_per_frame; } alsa_sink_ctx_t;

static int alsa_sink_write(output_sink_t *sink, const uint8_t *buf, size_t len) {
    alsa_sink_ctx_t *c = (alsa_sink_ctx_t *)sink->ctx;
    snd_pcm_uframes_t frames = len / (snd_pcm_uframes_t)c->bytes_per_frame;
    const uint8_t *p = buf;
    while (frames > 0) {
        snd_pcm_sframes_t n = snd_pcm_writei(c->pcm, p, frames);
        if (n < 0) {
            if (n == -EPIPE) {
                /* underrun -- standard ALSA recovery is snd_pcm_prepare() then retry */
                fprintf(stderr, "mpx_stream: ALSA underrun, recovering\n");
                if (snd_pcm_prepare(c->pcm) < 0) {
                    fprintf(stderr, "mpx_stream: ALSA prepare-after-underrun failed\n");
                    return -1;
                }
                continue;
            } else if (n == -ESTRPIPE) {
                while (snd_pcm_resume(c->pcm) == -EAGAIN) usleep(10000);
                snd_pcm_prepare(c->pcm);
                continue;
            } else if (n == -ENODEV) {
                return -2;  /* device gone -- quiet shutdown */
            } else {
                fprintf(stderr, "mpx_stream: ALSA write error: %s\n", snd_strerror((int)n));
                return -1;
            }
        }
        p += (size_t)n * (size_t)c->bytes_per_frame;
        frames -= (snd_pcm_uframes_t)n;
    }
    return 0;
}
static void alsa_sink_close(output_sink_t *sink) {
    alsa_sink_ctx_t *c = (alsa_sink_ctx_t *)sink->ctx;
    snd_pcm_drain(c->pcm);
    snd_pcm_close(c->pcm);
    free(c);
}
/* ---- ALSA format selection -------------------------------------------
 * The audio DATA register sign-extends the FPGA's AUDIO_DATA_WIDTH-bit
 * sample into the full 32-bit word WITHOUT rescaling, so a full-scale
 * 24-bit sample reads as +-2^23 inside a 32-bit field. That is exactly
 * ALSA's S24_LE ("24 significant bits, right-justified in a 4-byte
 * container" -- physical width 32, logical width 24), NOT S32_LE.
 * Calling it S32_LE makes ALSA treat +-2^23 as 1/256 of full scale: a
 * 48 dB attenuation, which sounds like silence. (An earlier version of
 * this file did exactly that, and also claimed in a comment that
 * emitting 32-bit words "sidesteps the S24_LE-vs-S24_3LE packing
 * question" -- it doesn't. S24_3LE is the packed 3-byte variant; S24_LE
 * is the padded 4-byte one, and the padded one is what this produces.)
 * Kept as a separate pure function so the mapping is checkable without
 * opening a device. */
static snd_pcm_format_t alsa_format_for(const source_desc_t *src, int audio_bits) {
    if (src->sample_bytes == 2) return SND_PCM_FORMAT_S16_LE;   /* mpx: mono s16, no padding involved */
    switch (audio_bits) {
        case 16: return SND_PCM_FORMAT_S16_LE;
        case 24: return SND_PCM_FORMAT_S24_LE;   /* the common case: AUDIO_DATA_WIDTH=24 */
        case 32: return SND_PCM_FORMAT_S32_LE;
        default: return SND_PCM_FORMAT_UNKNOWN;
    }
}

static int open_alsa_sink(output_sink_t *sink, const char *device,
                           const source_desc_t *src, int audio_bits) {
    snd_pcm_format_t fmt = alsa_format_for(src, audio_bits);
    if (fmt == SND_PCM_FORMAT_UNKNOWN) {
        fprintf(stderr, "mpx_stream: --audio-bits %d has no matching ALSA format (use 16, 24, or 32)\n",
                audio_bits);
        return -1;
    }
    snd_pcm_t *pcm;
    int err = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        fprintf(stderr, "mpx_stream: ALSA open '%s': %s\n", device, snd_strerror(err));
        return -1;
    }
    /* latency param (last arg, microseconds) chosen generously (500ms) --
     * this tool polls in ~1KiB-ish bursts rather than a tight real-time
     * loop, so a small ALSA buffer would underrun on ordinary scheduling
     * jitter alone. Tune down if you need lower latency and your system
     * can keep up. */
    err = snd_pcm_set_params(pcm, fmt, SND_PCM_ACCESS_RW_INTERLEAVED,
                              (unsigned)src->channels, src->nominal_rate_hz, 1, 500000);
    if (err < 0) {
        fprintf(stderr, "mpx_stream: ALSA set_params on '%s' (%s, %dch, %uHz): %s\n",
                device, snd_pcm_format_name(fmt),
                src->channels, src->nominal_rate_hz, snd_strerror(err));
        snd_pcm_close(pcm);
        return -1;
    }
    alsa_sink_ctx_t *c = malloc(sizeof(*c));
    if (!c) { snd_pcm_close(pcm); return -1; }
    c->pcm = pcm;
    /* Frame size follows the PHYSICAL container width, not audio_bits --
     * S24_LE frames are 4 bytes per sample, same as S32_LE, which is what
     * the loop below packs. */
    c->bytes_per_frame = src->sample_bytes * src->channels;
    sink->write = alsa_sink_write;
    sink->close = alsa_sink_close;
    sink->ctx = c;
    return 0;
}
#endif /* MPX_STREAM_NO_ALSA */

typedef struct {
    uint64_t samples;
    uint64_t overflow_events;
} run_stats_t;

/* ---- core polling/streaming loop --------------------------------------
 * Source- and sink-generic: pops whatever's queued each poll, packs each
 * 32-bit register read into src->sample_bytes little-endian bytes, and
 * flushes through sink->write() whenever the batch fills or the FIFO
 * reports empty. Idle (FIFO empty) calls idle_sleep() once per poll
 * rather than busy-spinning. Returns 0 on clean shutdown (*stop set, or
 * the sink reporting -2/peer-gone), -1 on a sink error.
 */
static int run_stream_loop(reg_if_t *regs, const source_desc_t *src, output_sink_t *sink,
                            volatile sig_atomic_t *stop,
                            uint8_t *out_buf, size_t out_buf_cap_samples,
                            int verbose, double report_interval_sec,
                            void (*idle_sleep)(void),
                            run_stats_t *stats)
{
    size_t buf_n_bytes = 0;
    size_t out_buf_cap_bytes = out_buf_cap_samples * (size_t)src->sample_bytes;
    struct timespec last_report;
    clock_gettime(CLOCK_MONOTONIC, &last_report);

    while (!*stop) {
        uint32_t raw = regs->read(regs->ctx, src->reg_stat);
        stat_t st = decode_stat(raw);

        if (st.overflow) {
            stats->overflow_events++;
            if (verbose)
                fprintf(stderr, "mpx_stream: %s FIFO overflow detected (userspace not keeping up)\n", src->name);
        }

        if (st.empty) {
            if (buf_n_bytes > 0) {
                int rc = sink->write(sink, out_buf, buf_n_bytes);
                if (rc != 0) return (rc == -2) ? 0 : -1;
                buf_n_bytes = 0;
            }
            if (idle_sleep) idle_sleep();
        } else {
            uint32_t count = st.count;
            for (uint32_t i = 0; i < count && !*stop; i++) {
                uint32_t d = regs->read(regs->ctx, src->reg_data);  /* read = pop */
                if (src->sample_bytes == 2) {
                    out_buf[buf_n_bytes++] = (uint8_t)(d & 0xFFu);
                    out_buf[buf_n_bytes++] = (uint8_t)((d >> 8) & 0xFFu);
                } else {
                    out_buf[buf_n_bytes++] = (uint8_t)(d & 0xFFu);
                    out_buf[buf_n_bytes++] = (uint8_t)((d >> 8) & 0xFFu);
                    out_buf[buf_n_bytes++] = (uint8_t)((d >> 16) & 0xFFu);
                    out_buf[buf_n_bytes++] = (uint8_t)((d >> 24) & 0xFFu);
                }
                stats->samples++;
                if (buf_n_bytes + (size_t)src->sample_bytes > out_buf_cap_bytes) {
                    int rc = sink->write(sink, out_buf, buf_n_bytes);
                    if (rc != 0) return (rc == -2) ? 0 : -1;
                    buf_n_bytes = 0;
                }
            }
        }

        if (verbose) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double dt = (double)(now.tv_sec - last_report.tv_sec) +
                        (now.tv_nsec - last_report.tv_nsec) / 1e9;
            if (dt >= report_interval_sec) {
                fprintf(stderr, "mpx_stream: %s: %llu samples, %llu overflow events\n", src->name,
                        (unsigned long long)stats->samples,
                        (unsigned long long)stats->overflow_events);
                last_report = now;
            }
        }
    }
    if (buf_n_bytes > 0) {
        int rc = sink->write(sink, out_buf, buf_n_bytes);
        (void)rc;  /* best effort on the way out */
    }
    return 0;
}

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static void idle_sleep_1ms(void) {
    /* At the fastest nominal source rate (250 kHz, mpx), one sample =
     * 4us; sleeping 1ms between empty-FIFO polls risks up to ~250 samples
     * backing up, well inside the default 1024-deep FIFOs. Watch -v's
     * overflow counter -- if it climbs, this margin isn't enough on your
     * hardware/CPU load. */
    struct timespec ts = {0, 1000000L};
    nanosleep(&ts, NULL);
}

#ifndef MPX_STREAM_NO_MAIN
static void print_usage(const char *argv0, unsigned long base_default) {
    fprintf(stderr,
        "Usage: %s [--source mpx|audio] [-b axi_base_addr] [-s shift0-15] [-V volume0-15]\n"
        "                 [-f freq | -t tuning_word] [-o sink] [--audio-bits N] [-v]\n"
        "Streams a raw sample FIFO from axi_sdr_fm / axi_sdr_fm_mpx.\n"
        "\n"
        "  --source mpx|audio    which FIFO to read (default mpx). audio needs\n"
        "                        axi_sdr_fm (axi_sdr_fm_mpx has no audio chain).\n"
        "  -b, --base ADDR       AXI4-Lite physical base address (default 0x%08lX --\n"
        "                        check your Vivado Address Editor, this is a placeholder)\n"
        "  -s, --shift N         set REG_MPX_SHIFT (0-15) before streaming (mpx source only)\n"
        "  -V, --volume N        set axi_sdr_fm's REG_VOLUME (0-15) before streaming\n"
        "                        (audio source only -- resets to 0 on FPGA reset, so\n"
        "                        audio is silent until something sets it)\n"
        "  -f, --freq FREQ       tune to FREQ before streaming, e.g. 87.9M, 87900000, 87900k\n"
        "  -t, --tune-raw WORD   write an already-computed raw tuning_word (exclusive with -f)\n"
        "  -o, --output SINK     stdout (default) | file:PATH | tcp:HOST:PORT |\n"
        "                        udp:HOST:PORT | alsa:DEVICE\n"
        "  --audio-bits N        FPGA AUDIO_DATA_WIDTH: 16, 24 (default), or 32.\n"
        "                        Audio samples are N significant bits right-justified\n"
        "                        in 4 little-endian bytes -- for N=24 that is ALSA's\n"
        "                        S24_LE (NOT S32_LE, NOT the packed S24_3LE).\n"
        "  -v, --verbose         print periodic stats to stderr\n"
        "\n"
        "Examples:\n"
        "  %s -b 0x43D00000 -f 87.9M | redsea --input mpx -r 250k\n"
        "  %s --source audio -b 0x43C60000 -f 101.9M -V 10 -o alsa:plughw:0,0\n"
        "  %s --source audio -b 0x43C60000 -f 101.9M -V 10 | aplay -D plughw:0,0 -t raw -r 48000 -f S24_LE -c 2\n"
        "  %s --source audio -b 0x43C60000 -o file:capture.raw\n",
        argv0, base_default, argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv) {
    unsigned long base = AXI_MPX_BASE_DEFAULT;
    int shift = -1;
    int volume = -1;
    long tuning_word = -1;
    double freq_hz = 0.0;
    int have_freq = 0;
    int verbose = 0;
    const source_desc_t *src = &SRC_MPX;
    const char *output_arg = "stdout";
    int audio_bits = 24;   /* must match the FPGA's AUDIO_DATA_WIDTH parameter (default 24) */

    static struct option long_opts[] = {
        {"base",       required_argument, 0, 'b'},
        {"shift",      required_argument, 0, 's'},
        {"volume",     required_argument, 0, 'V'},
        {"tune-raw",   required_argument, 0, 't'},
        {"freq",       required_argument, 0, 'f'},
        {"output",     required_argument, 0, 'o'},
        {"source",     required_argument, 0, 'S'},
        {"audio-bits", required_argument, 0, 'B'},
        {"verbose",    no_argument,       0, 'v'},
        {"help",       no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };
    int c;
    while ((c = getopt_long(argc, argv, "b:s:V:t:f:o:S:B:vh", long_opts, NULL)) != -1) {
        switch (c) {
            case 'b': base = strtoul(optarg, NULL, 0); break;
            case 's': shift = (int)strtol(optarg, NULL, 0); break;
            case 'V': volume = (int)strtol(optarg, NULL, 0); break;
            case 't': tuning_word = strtol(optarg, NULL, 0); break;
            case 'f':
                if (parse_freq_hz(optarg, &freq_hz) != 0) {
                    fprintf(stderr, "mpx_stream: couldn't parse -f/--freq value '%s' "
                                    "(try e.g. 87.9M, 87900000, or 87900k)\n", optarg);
                    return 1;
                }
                have_freq = 1;
                break;
            case 'o': output_arg = optarg; break;
            case 'B':
                audio_bits = (int)strtol(optarg, NULL, 0);
                if (audio_bits != 16 && audio_bits != 24 && audio_bits != 32) {
                    fprintf(stderr, "mpx_stream: --audio-bits must be 16, 24, or 32 "
                                    "(match your FPGA's AUDIO_DATA_WIDTH), got '%s'\n", optarg);
                    return 1;
                }
                break;
            case 'S':
                if (strcmp(optarg, "mpx") == 0) src = &SRC_MPX;
                else if (strcmp(optarg, "audio") == 0) src = &SRC_AUDIO;
                else {
                    fprintf(stderr, "mpx_stream: --source must be 'mpx' or 'audio', got '%s'\n", optarg);
                    return 1;
                }
                break;
            case 'v': verbose = 1; break;
            case 'h': print_usage(argv[0], AXI_MPX_BASE_DEFAULT); return 0;
            default:  print_usage(argv[0], AXI_MPX_BASE_DEFAULT); return 1;
        }
    }
    if (shift != -1 && (shift < 0 || shift > 15)) {
        fprintf(stderr, "mpx_stream: --shift must be 0-15\n");
        return 1;
    }
    if (volume != -1 && (volume < 0 || volume > 15)) {
        fprintf(stderr, "mpx_stream: --volume must be 0-15\n");
        return 1;
    }
    if (have_freq && tuning_word >= 0) {
        fprintf(stderr, "mpx_stream: -f/--freq and -t/--tune-raw are mutually exclusive\n");
        return 1;
    }
    if (shift >= 0 && src == &SRC_AUDIO && verbose)
        fprintf(stderr, "mpx_stream: NOTE - --shift (REG_MPX_SHIFT) has no effect on --source audio; "
                         "writing it anyway, but the audio level is governed by axi_sdr_fm's own "
                         "volume/controls registers instead.\n");
    if (volume >= 0 && src == &SRC_MPX && verbose)
        fprintf(stderr, "mpx_stream: NOTE - --volume (axi_sdr_fm's REG_VOLUME) has no effect on "
                         "--source mpx -- it only feeds audio_resampler, downstream of where the MPX "
                         "tap is taken. Writing it anyway (harmless either way, and axi_sdr_fm_mpx "
                         "doesn't even have this register, so it's simply unused there).\n");

    /* ---- output sink selection ---- */
    output_sink_t sink;
    memset(&sink, 0, sizeof(sink));
    if (strcmp(output_arg, "stdout") == 0) {
        if (open_stdout_sink(&sink) != 0) return 1;
    } else if (strncmp(output_arg, "file:", 5) == 0) {
        if (open_file_sink(&sink, output_arg + 5) != 0) return 1;
    } else if (strncmp(output_arg, "tcp:", 4) == 0) {
        char hostport[256];
        strncpy(hostport, output_arg + 4, sizeof(hostport) - 1);
        hostport[sizeof(hostport) - 1] = '\0';
        char *colon = strrchr(hostport, ':');
        if (!colon) { fprintf(stderr, "mpx_stream: -o tcp:HOST:PORT needs both host and port\n"); return 1; }
        *colon = '\0';
        if (open_tcp_sink(&sink, hostport, colon + 1) != 0) return 1;
    } else if (strncmp(output_arg, "udp:", 4) == 0) {
        char hostport[256];
        strncpy(hostport, output_arg + 4, sizeof(hostport) - 1);
        hostport[sizeof(hostport) - 1] = '\0';
        char *colon = strrchr(hostport, ':');
        if (!colon) { fprintf(stderr, "mpx_stream: -o udp:HOST:PORT needs both host and port\n"); return 1; }
        *colon = '\0';
        if (open_udp_sink(&sink, hostport, colon + 1) != 0) return 1;
    } else if (strncmp(output_arg, "alsa:", 5) == 0) {
#ifdef MPX_STREAM_NO_ALSA
        fprintf(stderr, "mpx_stream: built without ALSA support\n");
        return 1;
#else
        if (open_alsa_sink(&sink, output_arg + 5, src, audio_bits) != 0) return 1;
#endif
    } else {
        fprintf(stderr, "mpx_stream: unrecognized -o/--output '%s'\n", output_arg);
        print_usage(argv[0], AXI_MPX_BASE_DEFAULT);
        return 1;
    }

    mem_dev_t dev;
    if (memdev_open(&dev, base) != 0) { sink.close(&sink); return 1; }
    reg_if_t regs = { .read = memdev_read, .write = memdev_write, .ctx = &dev };

    {
        uint32_t probe = regs.read(regs.ctx, src->reg_stat);
        if (probe == 0xFFFFFFFFu) {
            fprintf(stderr,
                "mpx_stream: WARNING - REG_%s_FIFO_STAT read back as all 1s at base 0x%08lX.\n"
                "  This usually means nothing is mapped at that address (wrong -b/--base --\n"
                "  check your Vivado Address Editor). Continuing anyway in case this reading\n"
                "  is a coincidence, but expect garbage output if it isn't.\n",
                (src == &SRC_AUDIO) ? "AUDIO" : "MPX", base);
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    if (shift >= 0) {
        regs.write(regs.ctx, REG_MPX_SHIFT, (uint32_t)shift);
        if (verbose) fprintf(stderr, "mpx_stream: REG_MPX_SHIFT <- %d\n", shift);
    }
    if (volume >= 0) {
        regs.write(regs.ctx, REG_VOLUME, (uint32_t)volume);
        if (verbose) fprintf(stderr, "mpx_stream: REG_VOLUME <- %d\n", volume);
    }
    if (tuning_word >= 0) {
        regs.write(regs.ctx, REG_TUNING_WORD, (uint32_t)tuning_word);
        if (verbose) fprintf(stderr, "mpx_stream: tuning_word <- 0x%08lX (raw)\n", (unsigned long)tuning_word);
    } else if (have_freq) {
        uint32_t ftw = freq_to_tuning_word(freq_hz, verbose);
        regs.write(regs.ctx, REG_TUNING_WORD, ftw);
        if (verbose)
            fprintf(stderr, "mpx_stream: tuning_word <- 0x%08X (%.4f MHz)\n", ftw, freq_hz / 1e6);
    }

    if (verbose)
        fprintf(stderr, "mpx_stream: source=%s (%d ch, %d bytes/sample, %u Hz nominal), output=%s\n",
                src->name, src->channels, src->sample_bytes, src->nominal_rate_hz, output_arg);

    enum { BATCH_SAMPLES = 512 };
    uint8_t buf[BATCH_SAMPLES * 4];   /* 4 = largest sample_bytes across sources */
    run_stats_t stats = {0, 0};

    int rc = run_stream_loop(&regs, src, &sink, &g_stop, buf, BATCH_SAMPLES,
                              verbose, 5.0, idle_sleep_1ms, &stats);

    sink.close(&sink);
    memdev_close(&dev);
    if (verbose)
        fprintf(stderr, "mpx_stream: exiting, %llu samples streamed, %llu overflow events\n",
                (unsigned long long)stats.samples, (unsigned long long)stats.overflow_events);
    return rc == 0 ? 0 : 1;
}
#endif /* MPX_STREAM_NO_MAIN */

/* =============================================================================
 * Off-target logic test (not part of the delivered tool -- built and run
 * separately, against scripted fake hardware and real local sockets/files/
 * an ALSA null device, since no real Zynq target is available here).
 * =============================================================================
 */
#ifdef MPX_STREAM_SELFTEST
#include <assert.h>

/* ---- fake hardware: parameterized by which offsets it responds to as
 * STAT/DATA, so the same model drives both mpx-shaped and audio-shaped
 * tests. Values are kept as int32_t regardless of source; the loop's own
 * byte-packing (2 vs 4 bytes) is what's under test, not this model. ---- */
typedef struct {
    int32_t  fifo[4096];
    uint32_t depth;
    uint32_t head, tail, count;
    int      overflow_flag;
    int32_t  next_value;
    int      value_step;      /* increments next_value by this each push (allows negative-value coverage) */
    int      stop_after_n_stat_reads;
    int      stat_reads;
    int      fill_per_stat_read;
    unsigned reg_stat;
    unsigned reg_data;
} fake_hw_t;

static void fake_push(fake_hw_t *hw, int32_t v) {
    if (hw->count == hw->depth) { hw->overflow_flag = 1; return; }
    hw->fifo[hw->head] = v;
    hw->head = (hw->head + 1) % hw->depth;
    hw->count++;
}
static uint32_t fake_read(void *ctx, unsigned off) {
    fake_hw_t *hw = (fake_hw_t *)ctx;
    if (off == hw->reg_stat) {
        hw->stat_reads++;
        if (hw->stop_after_n_stat_reads < 0 || hw->stat_reads <= hw->stop_after_n_stat_reads) {
            for (int i = 0; i < hw->fill_per_stat_read; i++) {
                fake_push(hw, hw->next_value);
                hw->next_value += hw->value_step;
            }
        }
        uint32_t raw = (hw->count & STAT_COUNT_MASK)
                     | ((uint32_t)(hw->count == 0) << STAT_EMPTY_BIT)
                     | ((uint32_t)hw->overflow_flag << STAT_OVERFLOW_BIT);
        hw->overflow_flag = 0;
        return raw;
    } else if (off == hw->reg_data) {
        if (hw->count == 0) return 0xFFFFFFFFu;
        int32_t v = hw->fifo[hw->tail];
        hw->tail = (hw->tail + 1) % hw->depth;
        hw->count--;
        return (uint32_t)v;
    }
    return 0;
}
static void fake_write(void *ctx, unsigned off, uint32_t val) { (void)ctx; (void)off; (void)val; }

static fake_hw_t             *g_test_hw   = NULL;
static volatile sig_atomic_t *g_test_stop = NULL;
static void test_idle_sleep(void) {
    if (g_test_hw && g_test_hw->count == 0 &&
        g_test_hw->stat_reads > g_test_hw->stop_after_n_stat_reads && g_test_stop)
        *g_test_stop = 1;
}

static char *read_whole_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    assert(f);
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    assert(len >= 0);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len);
    assert(buf || len == 0);
    size_t n = fread(buf, 1, (size_t)len, f);
    assert(n == (size_t)len);
    fclose(f);
    *out_len = (size_t)len;
    return buf;
}

/* ---- mpx-shaped (2 bytes/sample), via the real file sink ---- */
static void test_mpx_drain_file_sink(void) {
    fake_hw_t hw; memset(&hw, 0, sizeof(hw));
    hw.depth = 64; hw.reg_stat = SRC_MPX.reg_stat; hw.reg_data = SRC_MPX.reg_data;
    hw.fill_per_stat_read = 3; hw.value_step = 1; hw.stop_after_n_stat_reads = 20;
    reg_if_t regs = { .read = fake_read, .write = fake_write, .ctx = &hw };

    char tmpl[] = "/tmp/mpx_selftest_XXXXXX";
    int fdtmp = mkstemp(tmpl);
    assert(fdtmp >= 0);
    close(fdtmp);
    output_sink_t sink;
    assert(open_file_sink(&sink, tmpl) == 0);

    uint8_t buf[16 * 2];
    run_stats_t stats = {0, 0};
    volatile sig_atomic_t stop = 0;
    g_test_hw = &hw; g_test_stop = &stop;

    int result = run_stream_loop(&regs, &SRC_MPX, &sink, &stop, buf, 16, 0, 1e9, test_idle_sleep, &stats);
    sink.close(&sink);
    assert(result == 0);
    assert(stats.samples == 60);
    assert(stats.overflow_events == 0);

    size_t len; char *data = read_whole_file(tmpl, &len);
    assert(len == 60 * 2);
    int16_t *samples = (int16_t *)data;
    for (int i = 0; i < 60; i++) assert(samples[i] == i);
    free(data);
    unlink(tmpl);

    printf("PASS: mpx source (s16le) drain via file sink, byte-exact (%llu samples)\n",
           (unsigned long long)stats.samples);
}

/* ---- audio-shaped (4 bytes/sample), including negative values, via the
 * real file sink -- this is the part that's genuinely new (2-byte path
 * was already covered by the mpx test above; this exercises the 4-byte
 * packing branch and sign handling) ---- */
static void test_audio_drain_file_sink(void) {
    fake_hw_t hw; memset(&hw, 0, sizeof(hw));
    hw.depth = 64; hw.reg_stat = SRC_AUDIO.reg_stat; hw.reg_data = SRC_AUDIO.reg_data;
    hw.fill_per_stat_read = 4; hw.value_step = -12345; hw.next_value = 1000000;
    hw.stop_after_n_stat_reads = 15;  /* 60 samples, alternating sign as it walks negative */
    reg_if_t regs = { .read = fake_read, .write = fake_write, .ctx = &hw };

    char tmpl[] = "/tmp/mpx_selftest_XXXXXX";
    int fdtmp = mkstemp(tmpl);
    assert(fdtmp >= 0);
    close(fdtmp);
    output_sink_t sink;
    assert(open_file_sink(&sink, tmpl) == 0);

    uint8_t buf[16 * 4];
    run_stats_t stats = {0, 0};
    volatile sig_atomic_t stop = 0;
    g_test_hw = &hw; g_test_stop = &stop;

    int result = run_stream_loop(&regs, &SRC_AUDIO, &sink, &stop, buf, 16, 0, 1e9, test_idle_sleep, &stats);
    sink.close(&sink);
    assert(result == 0);
    assert(stats.samples == 60);

    size_t len; char *data = read_whole_file(tmpl, &len);
    assert(len == 60 * 4);
    int32_t *samples = (int32_t *)data;
    int32_t expect = 1000000;
    for (int i = 0; i < 60; i++) { assert(samples[i] == expect); expect += -12345; }
    free(data);
    unlink(tmpl);

    printf("PASS: audio source (s32le) drain via file sink, byte-exact incl. negative values (%llu samples)\n",
           (unsigned long long)stats.samples);
}

static void test_overflow_drops_newest(void) {
    fake_hw_t hw; memset(&hw, 0, sizeof(hw));
    hw.depth = 8; hw.reg_stat = SRC_MPX.reg_stat; hw.reg_data = SRC_MPX.reg_data;
    hw.fill_per_stat_read = 20; hw.value_step = 1; hw.stop_after_n_stat_reads = 1;
    reg_if_t regs = { .read = fake_read, .write = fake_write, .ctx = &hw };

    char tmpl[] = "/tmp/mpx_selftest_XXXXXX";
    int fdtmp = mkstemp(tmpl);
    assert(fdtmp >= 0);
    close(fdtmp);
    output_sink_t sink;
    assert(open_file_sink(&sink, tmpl) == 0);

    uint8_t buf[64 * 2];
    run_stats_t stats = {0, 0};
    volatile sig_atomic_t stop = 0;
    g_test_hw = &hw; g_test_stop = &stop;

    int result = run_stream_loop(&regs, &SRC_MPX, &sink, &stop, buf, 64, 0, 1e9, test_idle_sleep, &stats);
    sink.close(&sink);
    assert(result == 0);
    assert(stats.samples == 8);
    assert(stats.overflow_events == 1);

    size_t len; char *data = read_whole_file(tmpl, &len);
    assert(len == 8 * 2);
    int16_t *samples = (int16_t *)data;
    for (int i = 0; i < 8; i++) assert(samples[i] == i);
    free(data);
    unlink(tmpl);

    printf("PASS: overflow retains oldest 8 (0..7), drops newest 12 (8..19), flagged once\n");
}

/* ---- TCP sink: real loopback listener in a forked child, real
 * open_tcp_sink()/run_stream_loop() in the parent ---- */
static void test_tcp_sink(void) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    assert(lfd >= 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(lfd, 1) == 0);
    socklen_t alen = sizeof(addr);
    assert(getsockname(lfd, (struct sockaddr *)&addr, &alen) == 0);
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%u", (unsigned)ntohs(addr.sin_port));

    int pipefd[2];
    assert(pipe(pipefd) == 0);
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        close(pipefd[0]);
        int cfd = accept(lfd, NULL, NULL);
        size_t total = 0;
        uint8_t rbuf[4096];
        ssize_t n;
        while ((n = read(cfd, rbuf, sizeof(rbuf))) > 0) total += (size_t)n;
        close(cfd);
        ssize_t w = write(pipefd[1], &total, sizeof(total));
        (void)w;
        close(pipefd[1]);
        _exit(0);
    }
    close(pipefd[1]);
    close(lfd);

    fake_hw_t hw; memset(&hw, 0, sizeof(hw));
    hw.depth = 64; hw.reg_stat = SRC_MPX.reg_stat; hw.reg_data = SRC_MPX.reg_data;
    hw.fill_per_stat_read = 3; hw.value_step = 1; hw.stop_after_n_stat_reads = 20;
    reg_if_t regs = { .read = fake_read, .write = fake_write, .ctx = &hw };

    output_sink_t sink;
    assert(open_tcp_sink(&sink, "127.0.0.1", port_str) == 0);

    uint8_t buf[16 * 2];
    run_stats_t stats = {0, 0};
    volatile sig_atomic_t stop = 0;
    g_test_hw = &hw; g_test_stop = &stop;
    int result = run_stream_loop(&regs, &SRC_MPX, &sink, &stop, buf, 16, 0, 1e9, test_idle_sleep, &stats);
    sink.close(&sink);  /* closes the TCP connection -> child's read() sees EOF */
    assert(result == 0);

    size_t received = 0;
    int wstatus;
    waitpid(pid, &wstatus, 0);
    ssize_t n = read(pipefd[0], &received, sizeof(received));
    close(pipefd[0]);
    assert(n == (ssize_t)sizeof(received));
    assert(received == stats.samples * 2);

    printf("PASS: TCP sink, real loopback connection, %zu bytes received matches %llu samples sent\n",
           received, (unsigned long long)stats.samples);
}

/* ---- UDP sink: same shape, datagrams instead of a stream. Loopback UDP
 * on the same host is not expected to drop packets in practice, so a
 * straightforward byte-count comparison is a reasonable check here. ---- */
static void test_udp_sink(void) {
    int lfd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(lfd >= 0);
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    socklen_t alen = sizeof(addr);
    assert(getsockname(lfd, (struct sockaddr *)&addr, &alen) == 0);
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%u", (unsigned)ntohs(addr.sin_port));

    int pipefd[2];
    assert(pipe(pipefd) == 0);
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        close(pipefd[0]);
        size_t total = 0;
        uint8_t rbuf[4096];
        struct timeval tv = {0, 300000};  /* 300ms of silence => assume sender is done */
        setsockopt(lfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        for (;;) {
            ssize_t n = recv(lfd, rbuf, sizeof(rbuf), 0);
            if (n <= 0) break;
            total += (size_t)n;
        }
        close(lfd);
        ssize_t w = write(pipefd[1], &total, sizeof(total));
        (void)w;
        close(pipefd[1]);
        _exit(0);
    }
    close(pipefd[1]);
    close(lfd);

    fake_hw_t hw; memset(&hw, 0, sizeof(hw));
    hw.depth = 64; hw.reg_stat = SRC_MPX.reg_stat; hw.reg_data = SRC_MPX.reg_data;
    hw.fill_per_stat_read = 3; hw.value_step = 1; hw.stop_after_n_stat_reads = 20;
    reg_if_t regs = { .read = fake_read, .write = fake_write, .ctx = &hw };

    output_sink_t sink;
    assert(open_udp_sink(&sink, "127.0.0.1", port_str) == 0);

    uint8_t buf[16 * 2];
    run_stats_t stats = {0, 0};
    volatile sig_atomic_t stop = 0;
    g_test_hw = &hw; g_test_stop = &stop;
    int result = run_stream_loop(&regs, &SRC_MPX, &sink, &stop, buf, 16, 0, 1e9, test_idle_sleep, &stats);
    sink.close(&sink);
    assert(result == 0);

    size_t received = 0;
    int wstatus;
    waitpid(pid, &wstatus, 0);
    ssize_t n = read(pipefd[0], &received, sizeof(received));
    close(pipefd[0]);
    assert(n == (ssize_t)sizeof(received));
    assert(received == stats.samples * 2);

    printf("PASS: UDP sink, real loopback datagrams, %zu bytes received matches %llu samples sent\n",
           received, (unsigned long long)stats.samples);
}

#ifndef MPX_STREAM_NO_ALSA
/* ---- ALSA format mapping. This is the check that would have caught the
 * original S32_LE-instead-of-S24_LE bug (24-bit values sign-extended into
 * a 32-bit word are S24_LE; calling them S32_LE attenuates by 48 dB).
 * Verified against libasound's own width introspection rather than
 * against hardcoded expectations, so it stays honest if ALSA's
 * definitions ever surprise us. ---- */
static void test_alsa_format_mapping(void) {
    snd_pcm_format_t f24 = alsa_format_for(&SRC_AUDIO, 24);
    assert(f24 == SND_PCM_FORMAT_S24_LE);
    /* the property that actually matters: 4-byte container, 24 significant bits */
    assert(snd_pcm_format_physical_width(f24) == 32);
    assert(snd_pcm_format_width(f24) == 24);

    snd_pcm_format_t f32 = alsa_format_for(&SRC_AUDIO, 32);
    assert(f32 == SND_PCM_FORMAT_S32_LE);
    assert(snd_pcm_format_physical_width(f32) == 32);
    assert(snd_pcm_format_width(f32) == 32);

    snd_pcm_format_t f16 = alsa_format_for(&SRC_AUDIO, 16);
    assert(f16 == SND_PCM_FORMAT_S16_LE);

    /* mpx is genuinely 16-bit mono with no padding, independent of audio_bits */
    assert(alsa_format_for(&SRC_MPX, 24) == SND_PCM_FORMAT_S16_LE);
    assert(alsa_format_for(&SRC_MPX, 32) == SND_PCM_FORMAT_S16_LE);

    assert(alsa_format_for(&SRC_AUDIO, 20) == SND_PCM_FORMAT_UNKNOWN);

    /* The container width the loop packs (sample_bytes) must match the
     * format's physical width, or frames would be miscounted. */
    assert(snd_pcm_format_physical_width(f24) / 8 == SRC_AUDIO.sample_bytes);
    assert(snd_pcm_format_physical_width(alsa_format_for(&SRC_MPX, 24)) / 8 == SRC_MPX.sample_bytes);

    printf("PASS: ALSA format mapping (24->S24_LE 32phys/24logical, 32->S32_LE, mpx->S16_LE, container widths agree)\n");
}

/* ---- ALSA sink: real libasound API sequence against the built-in "null"
 * device (no real hardware needed/available here). This can't verify
 * audio CONTENT (null discards it) but does exercise open/set_params/
 * writei/close exactly as they'd run against real hardware. ---- */
static void test_alsa_sink(void) {
    fake_hw_t hw; memset(&hw, 0, sizeof(hw));
    hw.depth = 64; hw.reg_stat = SRC_AUDIO.reg_stat; hw.reg_data = SRC_AUDIO.reg_data;
    hw.fill_per_stat_read = 4; hw.value_step = 1000; hw.stop_after_n_stat_reads = 10;
    reg_if_t regs = { .read = fake_read, .write = fake_write, .ctx = &hw };

    output_sink_t sink;
    int rc = open_alsa_sink(&sink, "null", &SRC_AUDIO, 24);
    if (rc != 0) {
        printf("SKIP: ALSA null device unavailable in this environment\n");
        return;
    }

    uint8_t buf[16 * 4];
    run_stats_t stats = {0, 0};
    volatile sig_atomic_t stop = 0;
    g_test_hw = &hw; g_test_stop = &stop;
    int result = run_stream_loop(&regs, &SRC_AUDIO, &sink, &stop, buf, 16, 0, 1e9, test_idle_sleep, &stats);
    sink.close(&sink);
    assert(result == 0);
    assert(stats.samples == 40);

    printf("PASS: ALSA sink, real libasound open/set_params(S24_LE,2ch,48kHz)/writei/close against null device (%llu samples)\n",
           (unsigned long long)stats.samples);
}
#endif

static void test_freq_conversion(void) {
    assert(freq_to_tuning_word(0.0, 0) == 0u);
    assert(freq_to_tuning_word(125000000.0, 0) == 2147483648u);
    assert(freq_to_tuning_word(62500000.0, 0)  == 1073741824u);

    double freq = 87900000.0;
    uint32_t ftw = freq_to_tuning_word(freq, 0);
    double step = (double)NCO_CLK_HZ / (double)(1ULL << NCO_WIDTH_BITS);
    double back = (double)ftw * (double)NCO_CLK_HZ / (double)(1ULL << NCO_WIDTH_BITS);
    assert(back > freq - step && back < freq + step);

    assert(freq_to_tuning_word(-1000.0, 0) == 0u);
    assert(freq_to_tuning_word(1e12, 0) == 4294967295u);

    double hz;
    assert(parse_freq_hz("87900000", &hz) == 0 && hz == 87900000.0);
    assert(parse_freq_hz("87.9M", &hz) == 0 && hz == 87900000.0);
    assert(parse_freq_hz("87900k", &hz) == 0 && hz == 87900000.0);
    assert(parse_freq_hz("bogus", &hz) != 0);
    assert(parse_freq_hz("87.9X", &hz) != 0);

    printf("PASS: freq<->tuning_word (exact points, round-trip, clamping, -f parsing)\n");
}

int main(void) {
    test_mpx_drain_file_sink();
    test_audio_drain_file_sink();
    test_overflow_drops_newest();
    test_tcp_sink();
    test_udp_sink();
#ifndef MPX_STREAM_NO_ALSA
    test_alsa_format_mapping();
    test_alsa_sink();
#endif
    test_freq_conversion();
    printf("SELFTEST PASS\n");
    return 0;
}
#endif /* MPX_STREAM_SELFTEST */

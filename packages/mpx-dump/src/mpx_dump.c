/*
 * mpx_dump.c -- dumps N seconds of the raw MPX composite stream out of
 * axi_sdr_fm.v's MPX export FIFO (registers 0x2C/0x30/0x34) into a file of
 * raw signed 16-bit little-endian samples at 250 kHz.
 *
 * Usage:
 *   mpx_dump <phys_base_hex> <seconds> <output.raw> [shift]
 *
 *   phys_base_hex : physical base address of the axi_sdr_fm AXI4-Lite
 *                   peripheral (see notes below on how to find it)
 *   seconds       : capture duration, e.g. 5
 *   output.raw    : output file path (raw s16le, mono, 250000 Hz)
 *   shift         : optional -- write this value to MPX_SHIFT (0x34)
 *                   before capturing. If omitted, the register is left at
 *                   whatever it currently holds (reset default = 1) and
 *                   its value is only reported, not changed.
 *
 * Build (OpenWrt 23.05 SDK toolchain, target arm/zynq, musl libc):
 *   SDK toolchain gcc, path is:
 *     <SDK>/staging_dir/toolchain-arm_(cortex variant)/bin/
 *       arm-openwrt-linux-muslgnueabi-gcc
 *   invoked as:
 *     <that gcc> -O2 -Wall -o mpx_dump mpx_dump.c -lrt
 *
 * Run as root on the target (needed for /dev/mem and SCHED_FIFO):
 *   chrt -f 99 ./mpx_dump 0x43d00000 5 /tmp/mpx_5s.raw
 *   scp /tmp/mpx_5s.raw user@host:
 *
 * Notes:
 *   - Register 0x30 (MPX_FIFO_DATA) is read-to-pop: reading it both
 *     returns the oldest queued sample and removes it from the FIFO.
 *   - The FIFO is only MPX_FIFO_DEPTH entries deep (1024 by default) and
 *     fills at 250 kHz = one entry every 4 us -- with no interrupt line,
 *     this program must keep up by tight polling, hence SCHED_FIFO.
 *   - Bit 16 of MPX_FIFO_STAT (0x2C) is the overflow flag, clear-on-read
 *     of that same register. This program checks it on every poll and
 *     reports if any samples were ever dropped -- if so, the capture is
 *     not glitch-free and should be repeated (usually fixed by running
 *     under `chrt -f 99` and closing anything else CPU-heavy).
 *   - The exported sample is mpx (the true fm_cordic_discrim composite)
 *     right-shifted by MPX_SHIFT and saturated to 16 bits (fm_mpx_scale.v).
 *     To reconstruct the composite in the same units rds_decode.v consumes
 *     internally, multiply each sample by 2^shift. This program prints the
 *     shift value in effect so you don't have to track it separately.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sched.h>
#include <errno.h>
#include <time.h>

#define REG_MPX_FIFO_STAT 0x2C
#define REG_MPX_FIFO_DATA 0x30
#define REG_MPX_SHIFT     0x34
#define MAP_SIZE           0x1000
#define SAMPLE_RATE_HZ     250000

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr,
            "usage: %s <phys_base_hex> <seconds> <output.raw> [shift]\n",
            argv[0]);
        return 1;
    }

    uint32_t phys_base = (uint32_t)strtoul(argv[1], NULL, 0);
    double   seconds    = atof(argv[2]);
    const char *outpath = argv[3];
    int have_shift = (argc >= 5);
    uint32_t set_shift = have_shift ? (uint32_t)strtoul(argv[4], NULL, 0) : 0;

    size_t target_samples = (size_t)(seconds * SAMPLE_RATE_HZ + 0.5);
    if (target_samples == 0) {
        fprintf(stderr, "seconds must be > 0\n");
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (need root)");
        return 1;
    }

    uint32_t page_mask = (uint32_t)(sysconf(_SC_PAGESIZE) - 1);
    off_t page_base = phys_base & ~(off_t)page_mask;
    size_t page_off  = phys_base & page_mask;

    void *map = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                      fd, page_base);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }
    volatile uint32_t *regs = (volatile uint32_t *)((uint8_t *)map + page_off);

    if (have_shift) {
        regs[REG_MPX_SHIFT / 4] = set_shift;
        /* register writes on this bus are synchronous by the time the
         * next read below observes them -- no extra delay needed */
    }
    uint32_t shift_now = regs[REG_MPX_SHIFT / 4] & 0xF;
    fprintf(stderr, "MPX_SHIFT = %u (multiply samples by 2^%u to recover "
                     "true fm_cordic_discrim units)\n", shift_now, shift_now);

    /* Try for real-time scheduling so the polling loop isn't preempted for
     * long enough to let the 1024-entry FIFO overflow (which happens in
     * ~4.1 ms at 250 kHz if this thread stalls). Not fatal if it fails
     * (e.g. not root) -- capture still runs, just with a higher overflow
     * risk; the overflow counter below will tell you if it mattered. */
    struct sched_param sp = { .sched_priority = 90 };
    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
        fprintf(stderr, "warning: SCHED_FIFO failed (%s) -- run as root / "
                         "use chrt -f 99 for a clean capture\n", strerror(errno));
    }

    int16_t *buf = malloc(target_samples * sizeof(int16_t));
    if (!buf) {
        fprintf(stderr, "malloc failed for %zu samples\n", target_samples);
        munmap(map, MAP_SIZE);
        close(fd);
        return 1;
    }

    /* drain any stale entries left over from before this run started */
    while (1) {
        uint32_t stat = regs[REG_MPX_FIFO_STAT / 4];
        if (stat & (1u << 17)) break;       /* empty */
        (void)regs[REG_MPX_FIFO_DATA / 4];  /* pop and discard */
    }
    /* clear any latched overflow from before this run (read-clears) */
    (void)regs[REG_MPX_FIFO_STAT / 4];

    fprintf(stderr, "capturing %zu samples (%.2f s)...\n",
            target_samples, seconds);

    size_t n = 0;
    uint32_t overflow_hits = 0;
    uint64_t t0 = now_ns();
    while (n < target_samples) {
        uint32_t stat = regs[REG_MPX_FIFO_STAT / 4];
        if (stat & (1u << 16)) overflow_hits++;   /* clear-on-read, so count it here */
        if (stat & (1u << 17)) continue;          /* empty right now, spin */
        uint32_t raw = regs[REG_MPX_FIFO_DATA / 4];
        buf[n++] = (int16_t)(raw & 0xFFFF);
    }
    uint64_t t1 = now_ns();

    fprintf(stderr, "done in %.3f s wall clock (target %.3f s)\n",
            (t1 - t0) / 1e9, seconds);
    if (overflow_hits) {
        fprintf(stderr, "WARNING: FIFO overflow detected %u time(s) during "
                         "capture -- samples were dropped, this dump has "
                         "gaps. Re-run under `chrt -f 99`.\n", overflow_hits);
    } else {
        fprintf(stderr, "no overflow observed -- capture should be gap-free\n");
    }

    FILE *f = fopen(outpath, "wb");
    if (!f) {
        perror("fopen output");
        free(buf);
        munmap(map, MAP_SIZE);
        close(fd);
        return 1;
    }
    fwrite(buf, sizeof(int16_t), target_samples, f);
    fclose(f);
    free(buf);
    munmap(map, MAP_SIZE);
    close(fd);

    fprintf(stderr, "wrote %s (%zu samples, %zu bytes, s16le mono @ %d Hz)\n",
            outpath, target_samples, target_samples * sizeof(int16_t),
            SAMPLE_RATE_HZ);
    return 0;
}

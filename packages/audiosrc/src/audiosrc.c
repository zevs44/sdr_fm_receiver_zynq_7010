/*
 * audiosrc - minimal 32-bit MMIO register read/write tool over /dev/mem,
 * dedicated to the i2s_axi_mux_top channel-select register.
 *
 * Written to replace devmem2 for luci-app-audiosrc: single fixed access
 * width (32-bit, matching AXI4-Lite s_axi_wdata), a volatile-qualified
 * pointer for the actual access (devmem2 itself omits this), and a
 * write is only reported successful if reading the register back
 * afterwards matches what was written. The register address is fixed
 * at compile time below (AUDIOSRC_REG_ADDR) and is no longer taken from
 * argv - this tool controls exactly one register, nothing else.
 *
 * Usage:
 *   audiosrc            read the register, print it
 *   audiosrc <value>     write it, verify by reading back
 *
 * Exit codes:
 *   0  success
 *   1  usage / argument error
 *   2  /dev/mem open or mmap failure
 *   3  write succeeded but readback did not match (not verified)
 *
 * Prints exactly one line on success: "0x%08X\n" with the register's
 * final value. No other output on success, to stay trivially scriptable.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#ifndef DEVMEM_PATH
#define DEVMEM_PATH "/dev/mem"
#endif

/* i2s_axi_mux_top channel-select register. Overridable at build time
 * (tests/test_audiosrc.sh uses -DAUDIOSRC_REG_ADDR=0x1000 and similar)
 * so the test suite isn't forced to back a 1.1GB fake /dev/mem file just
 * to reach the real physical address. The shipped OpenWrt package build
 * (Makefile) does not override it, so the installed binary always uses
 * this one value. */
#ifndef AUDIOSRC_REG_ADDR
#define AUDIOSRC_REG_ADDR 0x43C80000UL
#endif

#if ((AUDIOSRC_REG_ADDR) == 0) || ((AUDIOSRC_REG_ADDR) & 0x3)
#error "AUDIOSRC_REG_ADDR must be non-zero and 4-byte aligned"
#endif

#define MAP_SIZE  4096UL
#define MAP_MASK  (MAP_SIZE - 1)

static int parse_u32(const char *s, uint32_t *out) {
    char *end;
    errno = 0;
    unsigned long long v = strtoull(s, &end, 0);
    if (errno != 0 || end == s || *end != '\0' || v > 0xFFFFFFFFULL) {
        return -1;
    }
    *out = (uint32_t)v;
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 2) {
        fprintf(stderr,
            "Usage: %s [value]\n"
            "  no value    read the 32-bit register and print it\n"
            "  with value  write it, then verify by reading back\n"
            "Operates on a fixed register (0x%08lX), compiled in - not an argument.\n",
            argv[0], (unsigned long)AUDIOSRC_REG_ADDR);
        return 1;
    }

    const uint32_t addr = (uint32_t)AUDIOSRC_REG_ADDR;
    uint32_t wval = 0;
    int do_write = (argc == 2);

    if (do_write && parse_u32(argv[1], &wval) != 0) {
        fprintf(stderr, "%s: invalid value '%s'\n", argv[0], argv[1]);
        return 1;
    }

    int fd = open(DEVMEM_PATH, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "%s: open %s: %s\n", argv[0], DEVMEM_PATH, strerror(errno));
        return 2;
    }

    off_t page_base = (off_t)(addr & ~(uint32_t)MAP_MASK);
    void *map = mmap(NULL, MAP_SIZE, do_write ? (PROT_READ | PROT_WRITE) : PROT_READ,
                      MAP_SHARED, fd, page_base);
    if (map == MAP_FAILED) {
        fprintf(stderr, "%s: mmap: %s\n", argv[0], strerror(errno));
        close(fd);
        return 2;
    }

    volatile uint32_t *reg = (volatile uint32_t *)((uint8_t *)map + (addr & MAP_MASK));

    if (do_write) {
        *reg = wval;
        __sync_synchronize();
        uint32_t rb = *reg;
        if (rb != wval) {
            fprintf(stderr, "%s: wrote 0x%08X to 0x%08X but read back 0x%08X\n",
                    argv[0], wval, addr, rb);
            munmap(map, MAP_SIZE);
            close(fd);
            return 3;
        }
        printf("0x%08X\n", rb);
    } else {
        printf("0x%08X\n", *reg);
    }

    munmap(map, MAP_SIZE);
    close(fd);
    return 0;
}

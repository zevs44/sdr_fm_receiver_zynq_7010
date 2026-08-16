// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * zynq_fm_radio.c — V4L2 FM Radio driver for Zynq-7010 PL SDR receiver
 *
 * Provides standard /dev/radioN interface (V4L2) and sysfs knobs for:
 *   frequency, rssi, stereo, station_found, rds_sync, rds_ps, rds_pi,
 *   rds_pty, rds_pty_name, rds_tp, rds_ta, rds_ms, rds_rt, rds_block_stats,
 *   status, seek_up, seek_down, volume, mute, bass_boost, rds_en,
 *   deemph, mono, mpx_shift.
 *
 * Also provides two misc chardevs for hardware capabilities that don't fit
 * the V4L2 tuner model:
 *   /dev/zynq_fm_mpx    raw 16-bit signed MPX composite samples
 *   /dev/zynq_fm_audio  post-resampler 48 kHz stereo audio, 32-bit signed,
 *                       interleaved L,R,L,R... (see REG_AUDIO_FIFO_DATA
 *                       below for the sign-extension/S24_LE caveat)
 *
 * RDS support:
 *   The PL decoder recovers PI, PTY, TP, TA, M/S, the 8-char Program
 *   Service name and the 64-char RadioText, and exposes all of them as
 *   registers.  It also queues the real, undecoded raw RDS blocks (as
 *   received off air, corrected or not by its own checkword logic) in a
 *   32-entry hardware FIFO.  The driver:
 *     - drains that raw block FIFO into standard v4l2_rds_data entries so
 *       rds-ctl (and any other v4l2 RDS client) reads exactly what the
 *       station transmitted -- including fields the PL's scalar registers
 *       never captured, such as the DI (decoder identification) bit;
 *     - publishes the scalar fields (PTY/TP/TA/M-S/PS/RT) through the
 *       standard read-only V4L2 controls (V4L2_CID_RDS_RX_*), so plain
 *       `v4l2-ctl -L` shows them;
 *     - mirrors them on sysfs (rds_pi, rds_pty, rds_pty_name, rds_tp,
 *       rds_ta, rds_ms, rds_ps, rds_rt).
 *
 * V4L2 controls -- all of them are *standard* IDs, so any V4L2 client
 * (v4l2-ctl, rds-ctl, gnomeradio, kradio, libv4l2 apps) understands them
 * without driver-specific knowledge.  The name in brackets is the one
 * v4l2-ctl derives from the core's control name and accepts on -c/-C:
 *   V4L2_CID_AUDIO_VOLUME              [volume]        0..15
 *   V4L2_CID_AUDIO_MUTE                [mute]          bool
 *   V4L2_CID_AUDIO_LOUDNESS            [loudness]      bool, drives the PL
 *                                                      bass-boost bit
 *   V4L2_CID_RDS_RECEPTION             [rds_reception] bool
 *   V4L2_CID_TUNE_DEEMPHASIS           [de_emphasis]   menu, 1=50us 2=75us
 *   V4L2_CID_RDS_RX_PTY                [rds_program_type]         read-only
 *   V4L2_CID_RDS_RX_PS_NAME            [rds_ps_name]              read-only
 *   V4L2_CID_RDS_RX_RADIO_TEXT         [rds_radio_text]           read-only
 *   V4L2_CID_RDS_RX_TRAFFIC_PROGRAM    [rds_traffic_program]      read-only
 *   V4L2_CID_RDS_RX_TRAFFIC_ANNOUNCEMENT [rds_traffic_announcement] read-only
 *   V4L2_CID_RDS_RX_MUSIC_SPEECH       [rds_music]                read-only
 * Mono/stereo is *not* a control: it is the standard tuner audmode, set with
 * VIDIOC_S_TUNER (`v4l2-ctl -t mono` / `-t stereo`) and reported by
 * VIDIOC_G_TUNER.  The sysfs nodes below keep their historical names
 * (bass_boost, rds_en, deemph, mono) as a stable non-V4L2 path.
 *
 * Compatible with v4l-utils / v4l2-ctl / rds-ctl on OpenWRT and any
 * V4L2 FM client.  Requires Linux 5.15+.
 *
 * Hardware register map (AXI4-Lite, axi_sdr_fm):
 *   0x00  REG_TUNING   (R/W)  32-bit DDS/NCO tuning word
 *   0x04  REG_RDS_PS_0 (R)    RDS Program Service Name chars 1-4
 *   0x08  REG_RDS_PS_1 (R)    RDS Program Service Name chars 5-8
 *   0x0C  reserved
 *   0x10  REG_STATUS   (R)    Bit 0     — stereo pilot locked
 *                              Bit 1     — station found (RSSI hysteresis)
 *                              Bits 19:2 — 18-bit unsigned RSSI
 *                              Bit 20    — rds_sync
 *   0x14  REG_VOLUME   (R/W)  Bits 3:0  — volume 0..15
 *   0x18  REG_CONTROLS (R/W)  Bit 0 — MUTE_EN
 *                              Bit 1 — BASS_BOOST_EN
 *                              Bit 2 — RDS_EN
 *                              Bit 3 — DEEMPH  (0=75µs, 1=50µs)
 *                              Bit 4 — MONO    (1=force mono)
 *                              Bits 31:5 — reserved
 *   0x1C  REG_RDS_PI   (R)    Bits 15:0 — RDS Programme Identification
 *   0x20  REG_RDS_FIFO_STAT(R) Bits 7:0 — entries queued in the raw block
 *                              FIFO (depth 32); Bit 8 — overflow
 *                              (clear-on-read of THIS register); Bit 9 —
 *                              FIFO empty (informational).
 *   0x24  REG_RDS_FIFO_DATA(R) Bits 15:0 — raw 16-bit RDS block word, MSB
 *                              first (matches the msb/lsb split used
 *                              everywhere else in this driver, e.g. PI);
 *                              Bits 18:16 — block id (0=A,1=B,2=C,3=D);
 *                              Bit 19 — corrected (passed checkword);
 *                              Bit 20 — uncorrectable (failed checkword).
 *                              Reading pops one queue entry — check
 *                              REG_RDS_FIFO_STAT first, reading while
 *                              empty returns stale data rather than
 *                              underflowing.
 *   0x28  REG_RDS_ERR_STATS(R)  Bits 15:0  — corrected-block counter
 *                              (free-running, wraps); Bits 31:16 —
 *                              uncorrectable-block counter (free-running,
 *                              wraps). Exposed as sysfs rds_block_stats.
 *   0x2C  REG_MPX_FIFO_STAT(R)  Bit 16 — overflow (clear-on-read of THIS
 *                              register); Bit 17 — FIFO empty. Backs
 *                              /dev/zynq_fm_mpx.
 *   0x30  REG_MPX_FIFO_DATA(R)  Bits 15:0 — signed 16-bit raw MPX composite
 *                              sample (same tap point fm_stereo_demod's
 *                              input uses). Reading pops one entry.
 *   0x34  REG_MPX_SHIFT(R/W)    Bits 3:0 — arithmetic right-shift applied
 *                              before saturating to the 16-bit FIFO sample
 *                              (reset value 1). Exposed as sysfs mpx_shift.
 *   0x38  REG_AUDIO_FIFO_STAT(R) Bit 16 — overflow (clear-on-read of THIS
 *                              register); Bit 17 — FIFO empty. Backs
 *                              /dev/zynq_fm_audio.
 *   0x3C  REG_AUDIO_FIFO_DATA(R) One post-resampler audio sample,
 *                              sign-extended from AUDIO_DATA_WIDTH (24 by
 *                              default) to 32 bits. Entries alternate
 *                              L, R, L, R... Reading pops one entry.
 *   0x40  REG_RDS_FLAGS(R)    Bits 4:0  — PTY (Programme Type)
 *                              Bit 5     — TP  (Traffic Programme)
 *                              Bit 6     — TA  (Traffic Announcement)
 *                              Bit 7     — M/S (1=Music, 0=Speech)
 *   0x44..0x80 REG_RDS_RT_n (R)  RadioText, 16 registers x 4 chars,
 *                              MSB = earliest character.
 *                              READ 0x44 FIRST: that read latches all 64
 *                              characters in the PL into a shadow register
 *                              and returns chars 1-4 from the live value at
 *                              that same instant; 0x48..0x80 then read out
 *                              of the shadow.  Reading them in any other
 *                              order can straddle a decoder update and mix
 *                              old and new text.  hw_read_rds_rt() does this
 *                              correctly and holds radio->lock for the whole
 *                              sequence so two callers cannot interleave.
 *
 * FPGA clock:  250 MHz  (undersampling, Nyquist zone 2 for 125-250 MHz)
 * Tuning word: target_hz × 2^32 / 250 000 000
 * Aliasing:    if freq > Fs/2 → target = Fs − freq
 */

#include <linux/module.h>
#include <linux/version.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>
#include <linux/math64.h>
#include <linux/of.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/delay.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/list.h>
#include <linux/atomic.h>
#include <linux/wait.h>
#include <linux/poll.h>
#include <linux/workqueue.h>
#include <linux/sched.h>
#include <linux/miscdevice.h>
#include <linux/videodev2.h>
#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-event.h>
#include <media/v4l2-fh.h>

/* ---------- constants ---------- */

#define DRIVER_NAME		"zynq-fm-radio"
#define CARD_NAME		"Zynq PL FM Radio"

/* AXI register offsets */
#define REG_TUNING		0x00
#define REG_RDS_PS_0		0x04
#define REG_RDS_PS_1		0x08
#define REG_STATUS		0x10
#define REG_VOLUME		0x14
#define REG_CONTROLS		0x18
#define REG_RDS_PI		0x1C
#define REG_RDS_FIFO_STAT	0x20
#define REG_RDS_FIFO_DATA	0x24
#define REG_RDS_ERR_STATS	0x28
#define REG_MPX_FIFO_STAT	0x2C
#define REG_MPX_FIFO_DATA	0x30
#define REG_MPX_SHIFT		0x34
#define REG_AUDIO_FIFO_STAT	0x38
#define REG_AUDIO_FIFO_DATA	0x3C
#define REG_RDS_FLAGS		0x40
#define REG_RDS_RT_BASE		0x44	/* 16 consecutive 32-bit registers */

/* RDS_FLAGS bit-fields */
#define RDS_FLAGS_PTY_MASK	0x1F
#define RDS_FLAGS_TP		BIT(5)
#define RDS_FLAGS_TA		BIT(6)
#define RDS_FLAGS_MS		BIT(7)

/* RDS_FIFO_STAT bit-fields */
#define RDS_FIFO_STAT_COUNT_MASK	0xFF
#define RDS_FIFO_STAT_OVERFLOW		BIT(8)
#define RDS_FIFO_STAT_EMPTY		BIT(9)

/* RDS_FIFO_DATA bit-fields */
#define RDS_FIFO_DATA_WORD_MASK	0xFFFF
#define RDS_FIFO_DATA_BLOCK_SHIFT	16
#define RDS_FIFO_DATA_BLOCK_MASK	0x7
#define RDS_FIFO_DATA_CORRECTED	BIT(19)
#define RDS_FIFO_DATA_UNCORRECTABLE	BIT(20)

/* Hardware raw-block FIFO depth (rds_block_fifo #(.DEPTH(32)) in axi_sdr_fm.v) */
#define RDS_FIFO_DEPTH		32

/*
 * MPX_FIFO_STAT / AUDIO_FIFO_STAT share the same layout: a count field
 * (width tracks the FIFO's own depth parameter, unused here -- emptiness is
 * all the raw-sample readers below need) plus overflow/empty at fixed bit
 * positions regardless of that width.
 */
#define STREAM_FIFO_STAT_OVERFLOW	BIT(16)
#define STREAM_FIFO_STAT_EMPTY		BIT(17)

/* MPX_SHIFT: 4-bit arithmetic right-shift, reset value 1 */
#define MPX_SHIFT_MASK		0x0F

/* RadioText geometry */
#define RDS_RT_CHARS		64
#define RDS_RT_REGS		(RDS_RT_CHARS / 4)
#define RDS_PS_CHARS		8

/* Status bit-fields */
#define STATUS_STEREO		BIT(0)
#define STATUS_FOUND		BIT(1)
#define STATUS_RSSI_SHIFT	2
#define STATUS_RSSI_MASK	0x3FFFF		/* 18-bit */
#define STATUS_RDS_SYNC		BIT(20)

/* Volume */
#define VOL_MASK		0x0F		/* 4 bits */
#define VOL_MAX			15

/* Controls register bit-fields */
#define CTRL_MUTE_EN		BIT(0)
#define CTRL_BASS_BOOST_EN	BIT(1)
#define CTRL_RDS_EN		BIT(2)
#define CTRL_DEEMPH		BIT(3)
#define CTRL_MONO		BIT(4)
#define CTRL_ALL_BITS		(CTRL_MUTE_EN | CTRL_BASS_BOOST_EN | \
				 CTRL_RDS_EN | CTRL_DEEMPH | CTRL_MONO)

/* FPGA clock */
#define CLK_RF_HZ		250000000ULL

/*
 * V4L2 frequency units when V4L2_TUNER_CAP_LOW is set: 62.5 Hz per unit.
 * Conversion helpers (integer arithmetic, no floats in the kernel):
 *   1 MHz = 16 000 units      (1 000 000 / 62.5)
 *   0.1 MHz step = 1 600 units
 */
#define V4L2_UNITS_PER_MHZ	16000U
#define FREQ_MIN_MHZ		76U
#define FREQ_MAX_MHZ		108U
#define FREQ_STEP_KHZ		100U		/* 100 kHz = 0.1 MHz */

#define FREQ_V4L2_MIN		(FREQ_MIN_MHZ * V4L2_UNITS_PER_MHZ)
#define FREQ_V4L2_MAX		(FREQ_MAX_MHZ * V4L2_UNITS_PER_MHZ)
#define FREQ_V4L2_STEP		(FREQ_STEP_KHZ * V4L2_UNITS_PER_MHZ / 1000U)

/* Time for FPGA filters / RSSI averager to settle during seek */
#define TUNE_SETTLE_MS		100
/* Maximum seek steps before giving up (full band) */
#define SEEK_MAX_STEPS		((FREQ_V4L2_MAX - FREQ_V4L2_MIN) / FREQ_V4L2_STEP + 1)

/*
 * Tuner capability set, shared by VIDIOC_G_TUNER and VIDIOC_ENUM_FREQ_BANDS.
 * Keeping it in one place is not just tidiness: v4l2-compliance requires the
 * union of every band's capability field to be *exactly* the tuner's own, so
 * the two lists drifting apart is an immediate failure.
 *
 * V4L2_TUNER_CAP_RDS_BLOCK_IO advertises the raw v4l2_rds_data block stream
 * that read() on this node provides.  rds-ctl's device auto-detection walks
 * /dev/radio*, calls VIDIOC_G_TUNER on each and discards every node without
 * this bit -- so while it was missing, a bare `rds-ctl` reported "No
 * RDS-capable device found" and only `rds-ctl -d /dev/radio0` worked.
 * v4l2-compliance also rejects a radio node that sets V4L2_CAP_READWRITE
 * without it.
 *
 * V4L2_TUNER_CAP_RDS_CONTROLS advertises the hardware-parsed fields published
 * through the V4L2_CID_RDS_RX_* controls.  This driver genuinely offers both
 * paths, and V4L2_TUNER_CAP_RDS on its own (with neither method bit) is an
 * invalid combination.
 *
 * V4L2_TUNER_CAP_HWSEEK_PROG_LIM advertises that VIDIOC_S_HW_FREQ_SEEK
 * honours a caller-supplied rangelow/rangehigh, which zynq_fm_s_hw_freq_seek()
 * does; without the bit an application is supposed to leave those fields zero.
 *
 * V4L2_TUNER_CAP_FREQ_BANDS is deliberately not in here: the V4L2 core ORs it
 * into every G_TUNER result itself (v4l_g_tuner()), but does *not* touch a
 * driver-supplied ENUM_FREQ_BANDS result, so it is added by hand there only.
 */
#define ZYNQ_FM_TUNER_CAPS	(V4L2_TUNER_CAP_LOW | \
				 V4L2_TUNER_CAP_STEREO | \
				 V4L2_TUNER_CAP_RDS | \
				 V4L2_TUNER_CAP_RDS_BLOCK_IO | \
				 V4L2_TUNER_CAP_RDS_CONTROLS | \
				 V4L2_TUNER_CAP_HWSEEK_BOUNDED | \
				 V4L2_TUNER_CAP_HWSEEK_WRAP | \
				 V4L2_TUNER_CAP_HWSEEK_PROG_LIM)

/* ---------- RDS ring buffer ---------- */

/*
 * Ring buffer holds v4l2_rds_data entries.  Each RDS Group 0A produces
 * 4 entries (blocks A-D).  256 entries ≈ 64 groups ≈ 5.6 seconds of data
 * at real RDS rate.
 */
#define RDS_BUF_BLOCKS		256
#define RDS_BUF_MASK		(RDS_BUF_BLOCKS - 1)

/*
 * PI is read straight out of REG_RDS_PI now.  Before that register was
 * wired out of the PL this driver substituted a 0xFFFF placeholder; if the
 * decoder has not latched a PI yet the register simply reads 0.
 */

/*
 * Work interval in ms.  Real RDS sends ~11.4 groups/s (~87.6 ms per group).
 * We use 90 ms to stay close to the real cadence.
 */
#define RDS_WORK_INTERVAL_MS	90

/* ---------- private data ---------- */

/*
 * Per-open-file state.  Each open file handle carries its own read index into
 * the shared rds_buf ring, so two readers (say the LuCI backend polling
 * rds-ctl while another rds-ctl runs over ssh) each see the complete block
 * stream instead of stealing entries from one another.
 *
 * That used to be a single radio-wide read index: every read() consumed from
 * it, so with two readers each got a disjoint subset of the blocks. Neither
 * then saw four consecutive blocks A,B,C,D, which is exactly what
 * libv4l2rds requires -- so both reported large group-error counts and
 * assembled fields (DI in particular, which is built one bit per group from
 * four consecutive segments) out of fragments of the real stream.
 */
struct zynq_fm_fh {
	struct v4l2_fh		fh;		/* must stay first (container_of) */
	struct list_head	node;		/* on radio->rds_readers */
	unsigned int		rd;		/* this handle's read index */
};

struct zynq_fm_radio {
	struct v4l2_device	v4l2_dev;
	struct video_device	vdev;
	struct v4l2_ctrl_handler ctrl_handler;
	struct mutex		lock;		/* serialises HW access */
	void __iomem		*regs;
	struct device		*dev;
	u32			freq;		/* cached, in V4L2 62.5 Hz units */

	/* RDS read() support */
	struct v4l2_rds_data	rds_buf[RDS_BUF_BLOCKS];
	unsigned int		rds_wr;		/* write index (producer) */
	struct list_head	rds_readers;	/* struct zynq_fm_fh list */
	spinlock_t		rds_lock;	/* protects rds_buf/wr/readers */
	wait_queue_head_t	rds_wq;		/* wakeup for read()/poll() */
	struct delayed_work	rds_work;	/* periodic raw-FIFO drain + control push */
	bool			rds_active;	/* false once remove() starts tearing down */

	/* Read-only V4L2 controls mirroring the decoder's RDS output */
	struct v4l2_ctrl	*ctrl_rds_pty;
	struct v4l2_ctrl	*ctrl_rds_ps;
	struct v4l2_ctrl	*ctrl_rds_rt;
	struct v4l2_ctrl	*ctrl_rds_tp;
	struct v4l2_ctrl	*ctrl_rds_ta;
	struct v4l2_ctrl	*ctrl_rds_ms;

	/*
	 * Raw MPX composite / post-resampler audio sample export
	 * (MPX_FIFO_* and AUDIO_FIFO_* registers). Neither fits the V4L2 tuner
	 * model, so each gets its own misc chardev instead. The design has
	 * no interrupt line at all (see axi_sdr_fm.v's port comments), so
	 * read()/poll() cannot be woken by a real event; stream_kick_work
	 * just wakes both waitqueues every couple of ms while at least one
	 * of the two devices is open, and the readers themselves re-poll
	 * the hardware FIFO_STAT registers each time they wake.
	 */
	struct miscdevice	mpx_miscdev;
	struct miscdevice	audio_miscdev;
	wait_queue_head_t	mpx_wq;
	wait_queue_head_t	audio_wq;
	atomic_t		stream_openers;		/* mpx + audio combined */
	struct delayed_work	stream_kick_work;
};

/* ================================================================
 * Low-level hardware helpers
 * ================================================================ */

static void hw_set_tuning(struct zynq_fm_radio *radio, u32 freq_v4l2)
{
	u64 freq_hz   = (u64)freq_v4l2 * 625ULL / 10ULL;
	u64 target_hz = freq_hz;
	u64 temp;
	u32 tuning_word;

	/* Nyquist aliasing: if freq > Fs/2 -> target = Fs - f */
	if (freq_hz > (CLK_RF_HZ / 2ULL))
		target_hz = CLK_RF_HZ - freq_hz;

	/* 64-bit safe math for 250 MHz */
	temp = target_hz * 4294967296ULL;
	tuning_word = (u32)div64_u64(temp, CLK_RF_HZ);

	iowrite32(tuning_word, radio->regs + REG_TUNING);
	radio->freq = freq_v4l2;
}

static inline u32 hw_read_status(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_STATUS);
}

static inline int hw_rssi(u32 status)
{
	return (int)((status >> STATUS_RSSI_SHIFT) & STATUS_RSSI_MASK);
}

static inline bool hw_stereo(u32 status)
{
	return !!(status & STATUS_STEREO);
}

static inline bool hw_station_found(u32 status)
{
	return !!(status & STATUS_FOUND);
}

static inline bool hw_rds_sync(u32 status)
{
	return !!(status & STATUS_RDS_SYNC);
}

/*
 * Read RDS Program Service name (8 ASCII characters) from two 32-bit
 * registers.  Each register holds 4 chars packed big-endian (MSB = first
 * char).  The output buffer must be at least 9 bytes (8 chars + NUL).
 * Non-printable characters are replaced with spaces.
 */
static void hw_read_rds_ps(struct zynq_fm_radio *radio, char *out)
{
	u32 ps0 = ioread32(radio->regs + REG_RDS_PS_0);
	u32 ps1 = ioread32(radio->regs + REG_RDS_PS_1);
	int i;

	out[0] = (ps0 >> 24) & 0xFF;
	out[1] = (ps0 >> 16) & 0xFF;
	out[2] = (ps0 >>  8) & 0xFF;
	out[3] = (ps0 >>  0) & 0xFF;
	out[4] = (ps1 >> 24) & 0xFF;
	out[5] = (ps1 >> 16) & 0xFF;
	out[6] = (ps1 >>  8) & 0xFF;
	out[7] = (ps1 >>  0) & 0xFF;
	out[8] = '\0';

	/* Sanitise: replace non-printable chars with space */
	for (i = 0; i < 8; i++) {
		if (out[i] < 0x20 || out[i] > 0x7E)
			out[i] = ' ';
	}
}

/* RDS Programme Identification code (0 until the decoder latches one) */
static inline u16 hw_read_rds_pi(struct zynq_fm_radio *radio)
{
	return (u16)(ioread32(radio->regs + REG_RDS_PI) & 0xFFFF);
}

/*
 * RDS_FLAGS holds PTY/TP/TA/M-S, all latched together in the PL when a
 * group completes, so a single 32-bit read is already a consistent snapshot
 * and needs no stability filtering of its own.
 */
static inline u32 hw_read_rds_flags(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_RDS_FLAGS);
}

static inline u8   rds_flags_pty(u32 f) { return f & RDS_FLAGS_PTY_MASK; }
static inline bool rds_flags_tp(u32 f)  { return !!(f & RDS_FLAGS_TP); }
static inline bool rds_flags_ta(u32 f)  { return !!(f & RDS_FLAGS_TA); }
static inline bool rds_flags_ms(u32 f)  { return !!(f & RDS_FLAGS_MS); }

/*
 * Raw RDS block FIFO (REG_RDS_FIFO_STAT / REG_RDS_FIFO_DATA).  This carries
 * the actual, undecoded block words straight from rds_decode -- corrected
 * (or not) by the PL's own checkword logic, but otherwise exactly what the
 * station transmitted.  In particular block B's bit 2 (DI) and bits 1:0
 * (segment address) are real here, unlike REG_RDS_FLAGS which only ever
 * captured PTY/TP/TA/M-S.  Reading REG_RDS_FIFO_DATA pops one entry in
 * hardware, so callers must check REG_RDS_FIFO_STAT's empty bit first.
 */
static inline u32 hw_read_rds_fifo_stat(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_RDS_FIFO_STAT);
}

static inline bool hw_rds_fifo_empty(u32 stat)
{
	return !!(stat & RDS_FIFO_STAT_EMPTY);
}

/* Pops one entry as a side effect -- call only when hw_rds_fifo_empty() is false */
static inline u32 hw_read_rds_fifo_data(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_RDS_FIFO_DATA);
}

static inline u8 rds_fifo_block_id(u32 word)
{
	return (word >> RDS_FIFO_DATA_BLOCK_SHIFT) & RDS_FIFO_DATA_BLOCK_MASK;
}

/*
 * Build the v4l2_rds_data status byte: block id in the low 3 bits (the
 * hardware's 0=A/1=B/2=C/3=D numbering already matches V4L2_RDS_BLOCK_A..D).
 *
 * Only V4L2_RDS_BLOCK_ERROR is ever added. The PL exposes bit 19 as
 * "corrected" but it is really just "passed the checkword" -- it is set for
 * every good block and is the exact complement of bit 20, so mapping it to
 * V4L2_RDS_BLOCK_CORRECTED would claim that 100% of received blocks needed
 * error correction, which is what libv4l2rds counts into
 * rds_statistics.block_corrected_cnt and what rds-ctl then reports (and the
 * LuCI plugin displays). The hardware does not distinguish "clean" from
 * "corrected", so the honest mapping is clean-or-corrected -> no flag,
 * uncorrectable -> ERROR.
 */
static inline u8 rds_fifo_block_flags(u32 word)
{
	u8 flags = rds_fifo_block_id(word);

	if (word & RDS_FIFO_DATA_UNCORRECTABLE)
		flags |= V4L2_RDS_BLOCK_ERROR;

	return flags;
}

/*
 * RDS_ERR_STATS: free-running hardware block-quality counters, driven
 * directly off the raw block stream (see the register map in axi_sdr_fm.v).
 * Independent of anything rds-ctl computes itself from the blocks it reads
 * via the raw FIFO -- this is the PL's own tally since the last reset.
 */
static inline u32 hw_read_rds_err_stats(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_RDS_ERR_STATS);
}

static inline u16 rds_err_stats_corrected(u32 v)     { return v & 0xFFFF; }
static inline u16 rds_err_stats_uncorrectable(u32 v) { return v >> 16; }

/*
 * Raw MPX composite export (MPX_FIFO_STAT/DATA, MPX_SHIFT). Same tap point
 * fm_stereo_demod's own input uses: L+R baseband + 19 kHz pilot + 38 kHz
 * L-R DSB-SC + 57 kHz RDS subcarrier, still fully undecoded, intended for
 * external tools (redsea, csdr, mpx_stream) via the misc chardev below.
 */
static inline u32 hw_read_mpx_fifo_stat(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_MPX_FIFO_STAT);
}

static inline bool hw_mpx_fifo_empty(u32 stat)
{
	return !!(stat & STREAM_FIFO_STAT_EMPTY);
}

/* Pops one entry -- call only when hw_mpx_fifo_empty() is false */
static inline s16 hw_read_mpx_fifo_data(struct zynq_fm_radio *radio)
{
	return (s16)(ioread32(radio->regs + REG_MPX_FIFO_DATA) & 0xFFFF);
}

static inline void hw_set_mpx_shift(struct zynq_fm_radio *radio, u32 shift)
{
	iowrite32(shift & MPX_SHIFT_MASK, radio->regs + REG_MPX_SHIFT);
}

static inline u32 hw_get_mpx_shift(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_MPX_SHIFT) & MPX_SHIFT_MASK;
}

/*
 * Post-resampler stereo audio export (AUDIO_FIFO_STAT/DATA) -- the same
 * 48 kHz signal already feeding fm_ds_dac/i2s_tx (post volume/mute), for
 * lossless digital capture instead of round-tripping through the DAC.
 * Entries alternate L, R, L, R...; each read pops one entry and is already
 * sign-extended to 32 bits by the PL (see the register map for the
 * AUDIO_DATA_WIDTH / S24_LE caveat -- this driver passes the raw 32-bit
 * value through unchanged).
 */
static inline u32 hw_read_audio_fifo_stat(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_AUDIO_FIFO_STAT);
}

static inline bool hw_audio_fifo_empty(u32 stat)
{
	return !!(stat & STREAM_FIFO_STAT_EMPTY);
}

/* Pops one entry -- call only when hw_audio_fifo_empty() is false */
static inline s32 hw_read_audio_fifo_data(struct zynq_fm_radio *radio)
{
	return (s32)ioread32(radio->regs + REG_AUDIO_FIFO_DATA);
}

/* Programme Type names, IEC 62106 (European RDS, not US RBDS) */
static const char * const rds_pty_names[32] = {
	"None",            "News",            "Current affairs", "Information",
	"Sport",           "Education",       "Drama",           "Culture",
	"Science",         "Varied",          "Pop music",       "Rock music",
	"Easy listening",  "Light classics",  "Serious classics","Other music",
	"Weather",         "Finance",         "Children's",      "Social affairs",
	"Religion",        "Phone-in",        "Travel",          "Leisure",
	"Jazz music",      "Country music",   "National music",  "Oldies music",
	"Folk music",      "Documentary",     "Alarm test",      "Alarm",
};

/*
 * Read the 64-character RadioText.
 *
 * The first register (0x44) MUST be read first: that read latches all 64
 * characters into a shadow register inside the PL and returns chars 1-4
 * from the live value at the same instant, so the remaining 15 registers
 * come from one coherent moment.  The caller must hold radio->lock for the
 * whole sequence, otherwise a second reader could take its own snapshot in
 * the middle of ours and we would splice two different texts together.
 *
 * out must be at least RDS_RT_CHARS + 1 bytes.  Non-printable characters
 * become spaces, and the 0x0D terminator the standard uses for messages
 * shorter than 64 characters truncates the string there.
 */
static void hw_read_rds_rt(struct zynq_fm_radio *radio, char *out)
{
	u32 w;
	int i, n;

	for (i = 0; i < RDS_RT_REGS; i++) {
		w = ioread32(radio->regs + REG_RDS_RT_BASE + i * 4);
		out[i * 4 + 0] = (w >> 24) & 0xFF;
		out[i * 4 + 1] = (w >> 16) & 0xFF;
		out[i * 4 + 2] = (w >>  8) & 0xFF;
		out[i * 4 + 3] = (w >>  0) & 0xFF;
	}

	n = RDS_RT_CHARS;
	for (i = 0; i < RDS_RT_CHARS; i++) {
		if (out[i] == 0x0D) {	/* standard end-of-message */
			n = i;
			break;
		}
		if (out[i] < 0x20 || out[i] > 0x7E)
			out[i] = ' ';
	}

	/* Trim the trailing space padding stations send to fill the field */
	while (n > 0 && out[n - 1] == ' ')
		n--;

	out[n] = '\0';
}

/* Map 18-bit RSSI to 16-bit V4L2 signal (0..65535) */
static inline u16 hw_signal_strength(u32 status)
{
	int rssi = hw_rssi(status);
	int scaled = rssi * 32; /* Shift left by 5 to map ~2000 to ~65000 */

	if (scaled > 65535)
		scaled = 65535;

	return (u16)scaled;
}

/* ---------- volume / controls register helpers ---------- */

static void hw_set_volume(struct zynq_fm_radio *radio, u32 vol)
{
	iowrite32(vol & VOL_MASK, radio->regs + REG_VOLUME);
}

static u32 hw_get_volume(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_VOLUME) & VOL_MASK;
}

static u32 hw_read_controls(struct zynq_fm_radio *radio)
{
	return ioread32(radio->regs + REG_CONTROLS);
}

static void hw_write_controls(struct zynq_fm_radio *radio, u32 val)
{
	iowrite32(val & CTRL_ALL_BITS, radio->regs + REG_CONTROLS);
}

/* Read-modify-write a single bit in REG_CONTROLS */
static void hw_set_control_bit(struct zynq_fm_radio *radio, u32 bit, bool on)
{
	u32 val = hw_read_controls(radio);

	if (on)
		val |= bit;
	else
		val &= ~bit;

	hw_write_controls(radio, val);
}

/* ================================================================
 * RDS ring buffer & raw-block passthrough
 * ================================================================
 *
 * The PL hardware decodes RDS internally and exposes the result two ways:
 *
 *   - as scalar registers (PI, PTY/TP/TA/M-S, the 8-character Program
 *     Service name, the 64-character RadioText) -- pushed to the standard
 *     V4L2 RDS controls and mirrored on sysfs below;
 *   - as a 32-entry FIFO of the real, undecoded raw blocks it received off
 *     air (REG_RDS_FIFO_STAT/REG_RDS_FIFO_DATA), corrected or flagged
 *     uncorrectable by its own checkword logic, exactly as transmitted.
 *
 * rds-ctl (v4l-utils) expects to read() raw v4l2_rds_data blocks from
 * /dev/radioN, so this driver drains the hardware FIFO and forwards those
 * blocks essentially unmodified -- a passthrough, not a re-encoding. This
 * used to be re-synthesised here from the scalar registers alone (fake
 * Group 0A/2A blocks built from PTY/TP/TA/M-S/PS/RT), which worked for
 * everything those four scalar fields carry but had no way to produce
 * fields the PL never latched into a register at all -- notably the DI
 * (decoder identification) bit, and any group type other than 0A/2A (e.g.
 * 0B/1A Area Coverage/ECC). The raw FIFO has always carried the real block
 * B word including DI; forwarding it directly rather than reconstructing
 * fixes that instead of adding another register for one more bit.
 *
 * A delayed_work still runs at ~90 ms intervals: it drains whatever the
 * FIFO has accumulated since the last tick (real RDS cadence is ~87.6 ms/
 * group, ~22 ms/block, so a handful of blocks per tick is normal and never
 * comes close to the FIFO's own 32-entry depth) and, separately, re-reads
 * and re-publishes the scalar registers through the V4L2 controls/sysfs.
 */

/* Push one v4l2_rds_data entry into the ring buffer (caller holds rds_lock) */
static inline void rds_buf_put(struct zynq_fm_radio *radio,
			       u8 msb, u8 lsb, u8 block)
{
	unsigned int wr = radio->rds_wr;
	struct zynq_fm_fh *r;

	radio->rds_buf[wr].msb   = msb;
	radio->rds_buf[wr].lsb   = lsb;
	radio->rds_buf[wr].block = block;
	wr = (wr + 1) & RDS_BUF_MASK;
	radio->rds_wr = wr;

	/*
	 * The ring is a broadcast buffer: entries are never freed, they are
	 * overwritten.  A reader whose read index is the slot we just moved
	 * onto has had its oldest unread entry overwritten, so drag it
	 * forward -- that reader loses the oldest block rather than suddenly
	 * seeing a full ring of future data as if it were a backlog.
	 */
	list_for_each_entry(r, &radio->rds_readers, node)
		if (r->rd == wr)
			r->rd = (r->rd + 1) & RDS_BUF_MASK;
}

/* Entries this handle has yet to read (caller holds rds_lock) */
static inline unsigned int rds_buf_count(struct zynq_fm_radio *radio,
					 struct zynq_fm_fh *fh)
{
	return (radio->rds_wr - fh->rd) & RDS_BUF_MASK;
}

static void rds_work_handler(struct work_struct *work)
{
	struct zynq_fm_radio *radio =
		container_of(work, struct zynq_fm_radio, rds_work.work);
	char ps[RDS_PS_CHARS + 1];
	char rt[RDS_RT_CHARS + 1];
	/* Local staging for drained blocks -- filled under radio->lock,
	 * pushed into rds_buf under rds_lock afterwards (see below). */
	u8 stage_msb[RDS_FIFO_DEPTH], stage_lsb[RDS_FIFO_DEPTH], stage_flags[RDS_FIFO_DEPTH];
	unsigned int nblocks = 0;
	unsigned int navail;
	u32 st, flags_reg, stat;
	u8 pty;
	bool tp, ta, ms, synced;
	unsigned long flags;
	unsigned int i;

	/*
	 * Read HW state.  All MMIO happens under radio->lock; hw_read_rds_rt()
	 * in particular must not be split by another reader (see its
	 * comment), and popping the raw FIFO must not interleave with any
	 * other register access either.
	 */
	mutex_lock(&radio->lock);
	st     = hw_read_status(radio);
	synced = hw_rds_sync(st);
	if (synced) {
		flags_reg = hw_read_rds_flags(radio);
		hw_read_rds_ps(radio, ps);
		hw_read_rds_rt(radio, rt);
	}

	/*
	 * Drain the raw block FIFO regardless of rds_sync -- it queues
	 * whatever came off air block by block, independently of whether the
	 * scalar decoder currently considers itself synchronised, and a
	 * consumer reading raw blocks (rather than the scalar registers) is
	 * exactly the case where losing that distinction matters.
	 *
	 * The queued count drives this, not just the EMPTY bit: on a
	 * bitstream that predates the raw-block FIFO (or whose address
	 * segment is too small, so the interconnect returns 0 -- see the
	 * BLOCK-DESIGN NOTE in axi_sdr_fm.v), REG_RDS_FIFO_STAT reads back
	 * as 0, which means EMPTY=0 as well. Believing that bit alone would
	 * pop a full FIFO's worth of all-zero words every tick and feed
	 * userspace a stream of fake "block A, data 0x0000" entries -- which
	 * decodes to nothing at all, since libv4l2rds needs A,B,C,D in
	 * order. Requiring a non-zero count makes that case read as an
	 * empty queue instead, which is the truthful answer.
	 */
	stat = hw_read_rds_fifo_stat(radio);
	navail = stat & RDS_FIFO_STAT_COUNT_MASK;
	if (navail > RDS_FIFO_DEPTH)
		navail = RDS_FIFO_DEPTH;		/* can't happen; clamp anyway */
	if (hw_rds_fifo_empty(stat))
		navail = 0;

	while (nblocks < navail) {
		u32 word = hw_read_rds_fifo_data(radio);	/* pops one entry */

		stage_msb[nblocks]   = (word >> 8) & 0xFF;
		stage_lsb[nblocks]   = word & 0xFF;
		stage_flags[nblocks] = rds_fifo_block_flags(word);
		nblocks++;
	}
	mutex_unlock(&radio->lock);

	if (nblocks) {
		spin_lock_irqsave(&radio->rds_lock, flags);
		for (i = 0; i < nblocks; i++)
			rds_buf_put(radio, stage_msb[i], stage_lsb[i],
				    stage_flags[i]);
		spin_unlock_irqrestore(&radio->rds_lock, flags);

		wake_up_interruptible(&radio->rds_wq);
	}

	if (!synced)
		goto reschedule;

	pty = rds_flags_pty(flags_reg);
	tp  = rds_flags_tp(flags_reg);
	ta  = rds_flags_ta(flags_reg);
	ms  = rds_flags_ms(flags_reg);

	/*
	 * Publish through the standard read-only controls.  Done here rather
	 * than from g_volatile_ctrl for the two string controls, because a
	 * volatile string has to be produced into ctrl->p_new on demand while
	 * these values are naturally push-driven; keeping both string and
	 * scalar controls on the same path also means one consistent snapshot
	 * feeds all six.  v4l2_ctrl_s_ctrl*() take the control handler's own
	 * lock, which is not radio->lock, and we no longer hold radio->lock
	 * here anyway.  pi is intentionally not republished here: it never
	 * had its own V4L2 control (only sysfs, read straight off the
	 * register elsewhere), and it now also reaches userspace for free as
	 * block A of every drained group.
	 */
	v4l2_ctrl_s_ctrl(radio->ctrl_rds_pty, pty);
	v4l2_ctrl_s_ctrl(radio->ctrl_rds_tp, tp);
	v4l2_ctrl_s_ctrl(radio->ctrl_rds_ta, ta);
	v4l2_ctrl_s_ctrl(radio->ctrl_rds_ms, ms);
	v4l2_ctrl_s_ctrl_string(radio->ctrl_rds_ps, ps);
	v4l2_ctrl_s_ctrl_string(radio->ctrl_rds_rt, rt);

reschedule:
	if (READ_ONCE(radio->rds_active))
		schedule_delayed_work(&radio->rds_work,
				      msecs_to_jiffies(RDS_WORK_INTERVAL_MS));
}

/*
 * The drain runs for the whole lifetime of the device, not just while a file
 * handle happens to be open.
 *
 * It used to start on the first open() and be cancelled on the last close(),
 * which lost blocks in two ways.  The PL's raw-block FIFO is only 32 entries
 * deep and fills at ~45 blocks/s, so with the drain stopped it overflows in
 * well under a second and keeps overflowing; when a reader next appeared it
 * got a queue that had been silently dropping blocks, and the surviving ones
 * no longer formed whole A,B,C,D groups.  Worse, the open count counts *any*
 * open of /dev/radioN -- every `v4l2-ctl --get-freq` the web UI runs on its
 * polling tick opens and closes the device -- so the drain was being stopped
 * and restarted constantly even with nothing reading RDS.  That is the
 * mechanism behind group errors appearing while the block error count stays
 * at zero: no block failed its checkword, whole groups were simply
 * incomplete by the time they reached userspace.
 *
 * Cost of leaving it on is a handful of register reads every 90 ms.
 */
static void rds_start(struct zynq_fm_radio *radio)
{
	WRITE_ONCE(radio->rds_active, true);
	schedule_delayed_work(&radio->rds_work,
			      msecs_to_jiffies(RDS_WORK_INTERVAL_MS));
}

static void rds_stop(struct zynq_fm_radio *radio)
{
	/*
	 * Clear the flag first: the handler re-arms itself, so cancelling
	 * without this can race with a re-arm and leave the work queued
	 * after cancel_delayed_work_sync() has returned.
	 */
	WRITE_ONCE(radio->rds_active, false);
	cancel_delayed_work_sync(&radio->rds_work);
}

/* ================================================================
 * Raw MPX / post-resampler audio sample export (misc chardevs)
 * ================================================================
 *
 * MPX_FIFO_* and AUDIO_FIFO_* have been sitting in the register map since
 * the raw-MPX/audio export FIFOs were added to axi_sdr_fm.v, but nothing
 * in-kernel ever read them -- the only consumer was a userspace /dev/mem
 * poller (mpx_dump.c) built for one-off capture, bypassing this driver
 * entirely and racing any other register access it might do at the same
 * time. These two misc devices are the proper replacement: /dev/zynq_fm_mpx
 * streams signed 16-bit raw MPX composite samples, /dev/zynq_fm_audio
 * streams the post-resampler 48 kHz stereo audio (signed 32-bit,
 * interleaved L,R,L,R...), both read()able like any other character
 * device and usable directly by e.g. redsea/csdr/mpx_stream instead of a
 * bespoke /dev/mem tool.
 *
 * Neither FIFO has an interrupt, so there is no event to block on. Reads
 * poll the FIFO_STAT register directly; when empty, the caller blocks on
 * a waitqueue that stream_kick_work wakes every 2 ms for as long as either
 * device is open (stream_openers > 0), and the reader just re-checks the
 * hardware on each wakeup. This mirrors what a tight userspace polling
 * loop already did, just with lower/steadier latency and without the
 * /dev/mem races.
 */

static void stream_kick_handler(struct work_struct *work)
{
	struct zynq_fm_radio *radio =
		container_of(work, struct zynq_fm_radio, stream_kick_work.work);

	wake_up_interruptible(&radio->mpx_wq);
	wake_up_interruptible(&radio->audio_wq);

	if (atomic_read(&radio->stream_openers) > 0)
		schedule_delayed_work(&radio->stream_kick_work,
				      msecs_to_jiffies(2));
}

static void stream_open_inc(struct zynq_fm_radio *radio)
{
	if (atomic_inc_return(&radio->stream_openers) == 1)
		schedule_delayed_work(&radio->stream_kick_work,
				      msecs_to_jiffies(2));
}

static void stream_open_dec(struct zynq_fm_radio *radio)
{
	atomic_dec(&radio->stream_openers);
}

static bool mpx_fifo_currently_empty(struct zynq_fm_radio *radio)
{
	u32 stat;

	mutex_lock(&radio->lock);
	stat = hw_read_mpx_fifo_stat(radio);
	mutex_unlock(&radio->lock);

	return hw_mpx_fifo_empty(stat);
}

static int mpx_dev_open(struct inode *inode, struct file *filp)
{
	/* The misc core stashes the miscdevice* in private_data before
	 * calling us; recover the enclosing radio and swap it in for the
	 * rest of this file's ops. */
	struct miscdevice *mdev = filp->private_data;
	struct zynq_fm_radio *radio =
		container_of(mdev, struct zynq_fm_radio, mpx_miscdev);

	filp->private_data = radio;
	stream_open_inc(radio);
	return nonseekable_open(inode, filp);
}

static int mpx_dev_release(struct inode *inode, struct file *filp)
{
	struct zynq_fm_radio *radio = filp->private_data;

	stream_open_dec(radio);
	return 0;
}

static ssize_t mpx_dev_read(struct file *filp, char __user *ubuf,
			     size_t count, loff_t *ppos)
{
	struct zynq_fm_radio *radio = filp->private_data;
	size_t written = 0;

	if (count < sizeof(s16))
		return -EINVAL;

	while (written + sizeof(s16) <= count) {
		u32 stat;
		s16 sample;

		mutex_lock(&radio->lock);
		stat = hw_read_mpx_fifo_stat(radio);
		if (!hw_mpx_fifo_empty(stat)) {
			sample = hw_read_mpx_fifo_data(radio);
			mutex_unlock(&radio->lock);

			if (copy_to_user(ubuf + written, &sample, sizeof(sample)))
				return written ? written : -EFAULT;
			written += sizeof(sample);
			continue;
		}
		mutex_unlock(&radio->lock);

		if (written)
			break;		/* hand back what we already have */
		if (filp->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible_timeout(radio->mpx_wq,
				!mpx_fifo_currently_empty(radio),
				msecs_to_jiffies(50)) < 0)
			return -EINTR;
		/* Woken by the 2 ms kicker or timed out either way -- there is
		 * no interrupt to signal real availability, so just re-poll. */
	}

	return written;
}

static __poll_t mpx_dev_poll(struct file *filp, struct poll_table_struct *wait)
{
	struct zynq_fm_radio *radio = filp->private_data;

	poll_wait(filp, &radio->mpx_wq, wait);
	return mpx_fifo_currently_empty(radio) ? 0 : (EPOLLIN | EPOLLRDNORM);
}

static const struct file_operations mpx_dev_fops = {
	.owner   = THIS_MODULE,
	.open    = mpx_dev_open,
	.release = mpx_dev_release,
	.read    = mpx_dev_read,
	.poll    = mpx_dev_poll,
	.llseek  = no_llseek,
};

static bool audio_fifo_currently_empty(struct zynq_fm_radio *radio)
{
	u32 stat;

	mutex_lock(&radio->lock);
	stat = hw_read_audio_fifo_stat(radio);
	mutex_unlock(&radio->lock);

	return hw_audio_fifo_empty(stat);
}

static int audio_dev_open(struct inode *inode, struct file *filp)
{
	struct miscdevice *mdev = filp->private_data;
	struct zynq_fm_radio *radio =
		container_of(mdev, struct zynq_fm_radio, audio_miscdev);

	filp->private_data = radio;
	stream_open_inc(radio);
	return nonseekable_open(inode, filp);
}

static int audio_dev_release(struct inode *inode, struct file *filp)
{
	struct zynq_fm_radio *radio = filp->private_data;

	stream_open_dec(radio);
	return 0;
}

static ssize_t audio_dev_read(struct file *filp, char __user *ubuf,
			       size_t count, loff_t *ppos)
{
	struct zynq_fm_radio *radio = filp->private_data;
	size_t written = 0;

	if (count < sizeof(s32))
		return -EINVAL;

	while (written + sizeof(s32) <= count) {
		u32 stat;
		s32 sample;

		mutex_lock(&radio->lock);
		stat = hw_read_audio_fifo_stat(radio);
		if (!hw_audio_fifo_empty(stat)) {
			sample = hw_read_audio_fifo_data(radio);
			mutex_unlock(&radio->lock);

			if (copy_to_user(ubuf + written, &sample, sizeof(sample)))
				return written ? written : -EFAULT;
			written += sizeof(sample);
			continue;
		}
		mutex_unlock(&radio->lock);

		if (written)
			break;
		if (filp->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible_timeout(radio->audio_wq,
				!audio_fifo_currently_empty(radio),
				msecs_to_jiffies(50)) < 0)
			return -EINTR;
	}

	return written;
}

static __poll_t audio_dev_poll(struct file *filp, struct poll_table_struct *wait)
{
	struct zynq_fm_radio *radio = filp->private_data;

	poll_wait(filp, &radio->audio_wq, wait);
	return audio_fifo_currently_empty(radio) ? 0 : (EPOLLIN | EPOLLRDNORM);
}

static const struct file_operations audio_dev_fops = {
	.owner   = THIS_MODULE,
	.open    = audio_dev_open,
	.release = audio_dev_release,
	.read    = audio_dev_read,
	.poll    = audio_dev_poll,
	.llseek  = no_llseek,
};

/* ================================================================
 * V4L2 control framework
 * ================================================================ */

static int zynq_fm_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct zynq_fm_radio *radio =
		container_of(ctrl->handler, struct zynq_fm_radio, ctrl_handler);

	mutex_lock(&radio->lock);
	switch (ctrl->id) {
	case V4L2_CID_AUDIO_VOLUME:
		hw_set_volume(radio, ctrl->val);
		break;
	case V4L2_CID_AUDIO_MUTE:
		hw_set_control_bit(radio, CTRL_MUTE_EN, ctrl->val);
		break;
	case V4L2_CID_AUDIO_LOUDNESS:
		hw_set_control_bit(radio, CTRL_BASS_BOOST_EN, ctrl->val);
		break;
	case V4L2_CID_RDS_RECEPTION:
		hw_set_control_bit(radio, CTRL_RDS_EN, ctrl->val);
		break;
	case V4L2_CID_TUNE_DEEMPHASIS:
		/*
		 * Menu value -> single CTRL_DEEMPH bit.  The hardware has no
		 * "de-emphasis off" mode, so V4L2_DEEMPHASIS_DISABLED is
		 * masked out of the menu and cannot arrive here.
		 */
		hw_set_control_bit(radio, CTRL_DEEMPH,
				   ctrl->val == V4L2_DEEMPHASIS_50_uS);
		break;
	default:
		mutex_unlock(&radio->lock);
		return -EINVAL;
	}
	mutex_unlock(&radio->lock);
	return 0;
}

static int zynq_fm_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
	struct zynq_fm_radio *radio =
		container_of(ctrl->handler, struct zynq_fm_radio, ctrl_handler);
	u32 cval;

	mutex_lock(&radio->lock);
	switch (ctrl->id) {
	case V4L2_CID_AUDIO_VOLUME:
		ctrl->val = hw_get_volume(radio);
		break;
	case V4L2_CID_AUDIO_MUTE:
		cval = hw_read_controls(radio);
		ctrl->val = !!(cval & CTRL_MUTE_EN);
		break;
	case V4L2_CID_AUDIO_LOUDNESS:
		cval = hw_read_controls(radio);
		ctrl->val = !!(cval & CTRL_BASS_BOOST_EN);
		break;
	case V4L2_CID_RDS_RECEPTION:
		cval = hw_read_controls(radio);
		ctrl->val = !!(cval & CTRL_RDS_EN);
		break;
	case V4L2_CID_TUNE_DEEMPHASIS:
		cval = hw_read_controls(radio);
		ctrl->val = (cval & CTRL_DEEMPH) ? V4L2_DEEMPHASIS_50_uS
						 : V4L2_DEEMPHASIS_75_uS;
		break;
	default:
		mutex_unlock(&radio->lock);
		return -EINVAL;
	}
	mutex_unlock(&radio->lock);
	return 0;
}

static const struct v4l2_ctrl_ops zynq_fm_ctrl_ops = {
	.s_ctrl		  = zynq_fm_s_ctrl,
	.g_volatile_ctrl  = zynq_fm_g_volatile_ctrl,
};

/*
 * No v4l2_ctrl_config structs any more: every control this driver exposes now
 * has a standard V4L2 ID, so the core supplies the name, type, menu strings
 * and default flags.  Never override the .name of a standard control -- that
 * is exactly what userspace matches on, and a private spelling makes the
 * control invisible to generic clients.
 *
 * What the previous private controls became:
 *   "Bass Boost"  -> V4L2_CID_AUDIO_LOUDNESS   (standard boolean; loudness is
 *                    the V4L2 name for a low-frequency boost switch, and
 *                    unlike V4L2_CID_AUDIO_BASS it is a checkbox, not a
 *                    slider, which is what the PL bit actually is)
 *   "RDS Enable"  -> V4L2_CID_RDS_RECEPTION    (standard boolean)
 *   "De-emphasis" -> V4L2_CID_TUNE_DEEMPHASIS  (standard FM-RX menu:
 *                    0 = None, 1 = 50 us, 2 = 75 us -- note that the old
 *                    boolean used 0 = 75 us, 1 = 50 us, so 1 still means
 *                    50 us but 75 us moved from 0 to 2)
 *   "Force Mono"  -> dropped; mono/stereo is the tuner audmode, handled by
 *                    zynq_fm_s_tuner()/zynq_fm_g_tuner() (`v4l2-ctl -t mono`).
 *                    Having a second, private way to poke the same CTRL_MONO
 *                    bit is precisely the kind of thing generic clients
 *                    cannot discover.
 */

static int zynq_fm_init_controls(struct zynq_fm_radio *radio)
{
	struct v4l2_ctrl *ctrl;

	v4l2_ctrl_handler_init(&radio->ctrl_handler, 16);

	/* Standard: Volume (0..15) */
	ctrl = v4l2_ctrl_new_std(&radio->ctrl_handler, &zynq_fm_ctrl_ops,
				 V4L2_CID_AUDIO_VOLUME, 0, VOL_MAX, 1,
				 VOL_MAX);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_VOLATILE |
			       V4L2_CTRL_FLAG_EXECUTE_ON_WRITE;

	/* Standard: Mute (boolean) */
	ctrl = v4l2_ctrl_new_std(&radio->ctrl_handler, &zynq_fm_ctrl_ops,
				 V4L2_CID_AUDIO_MUTE, 0, 1, 1, 0);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_VOLATILE |
			       V4L2_CTRL_FLAG_EXECUTE_ON_WRITE;

	/* Standard: Loudness / bass boost (boolean) */
	ctrl = v4l2_ctrl_new_std(&radio->ctrl_handler, &zynq_fm_ctrl_ops,
				 V4L2_CID_AUDIO_LOUDNESS, 0, 1, 1, 0);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_VOLATILE |
			       V4L2_CTRL_FLAG_EXECUTE_ON_WRITE;

	/*
	 * Standard: RDS reception (boolean).
	 *
	 * Default is 1.  A client such as rds-ctl or libv4l2rds simply opens
	 * the node and starts reading blocks; it has no reason to suspect the
	 * decoder needs switching on first, and with the old default of 0 it
	 * saw an eternally silent stream after a fresh modprobe.  Enabling the
	 * PL decoder costs one register bit and nothing else.
	 */
	ctrl = v4l2_ctrl_new_std(&radio->ctrl_handler, &zynq_fm_ctrl_ops,
				 V4L2_CID_RDS_RECEPTION, 0, 1, 1, 1);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_VOLATILE |
			       V4L2_CTRL_FLAG_EXECUTE_ON_WRITE;

	/*
	 * Standard: De-emphasis (FM-RX class menu).
	 *
	 * The PL has a single de-emphasis bit and no bypass, so
	 * V4L2_DEEMPHASIS_DISABLED is masked out of the menu; what is left is
	 * "50 Microseconds" (1) and "75 Microseconds" (2).  Default stays
	 * 75 us, which is what the old boolean's def = 0 meant.
	 */
	ctrl = v4l2_ctrl_new_std_menu(&radio->ctrl_handler, &zynq_fm_ctrl_ops,
				      V4L2_CID_TUNE_DEEMPHASIS,
				      V4L2_DEEMPHASIS_75_uS,
				      BIT(V4L2_DEEMPHASIS_DISABLED),
				      V4L2_DEEMPHASIS_75_uS);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_VOLATILE |
			       V4L2_CTRL_FLAG_EXECUTE_ON_WRITE;

	/*
	 * Standard read-only RDS receive controls, so `v4l2-ctl -L` shows the
	 * decoded fields without needing sysfs or rds-ctl.  These are pushed
	 * from rds_work_handler (see the note there), so they are NOT marked
	 * volatile: marking them read-only also keeps v4l2_ctrl_handler_setup()
	 * from calling s_ctrl on them, which would fail since s_ctrl does not
	 * know these IDs.  v4l2_ctrl_fill() in the core already sets
	 * V4L2_CTRL_FLAG_READ_ONLY on all six, so the explicit flag assignments
	 * below are belt and braces rather than load-bearing; the driver-side
	 * pushes still work because __v4l2_ctrl_s_ctrl() does not enforce
	 * READ_ONLY (only the VIDIOC_S_[EXT_]CTRL path does).
	 *
	 * They now stay current for as long as the device exists, since the
	 * work that pushes them runs for the driver's whole lifetime rather
	 * than only while a file handle is open.
	 */
	radio->ctrl_rds_pty = v4l2_ctrl_new_std(&radio->ctrl_handler,
						&zynq_fm_ctrl_ops,
						V4L2_CID_RDS_RX_PTY,
						0, 31, 1, 0);
	radio->ctrl_rds_ps  = v4l2_ctrl_new_std(&radio->ctrl_handler,
						&zynq_fm_ctrl_ops,
						V4L2_CID_RDS_RX_PS_NAME,
						0, RDS_PS_CHARS, 1, 0);
	radio->ctrl_rds_rt  = v4l2_ctrl_new_std(&radio->ctrl_handler,
						&zynq_fm_ctrl_ops,
						V4L2_CID_RDS_RX_RADIO_TEXT,
						0, RDS_RT_CHARS, 1, 0);
	radio->ctrl_rds_tp  = v4l2_ctrl_new_std(&radio->ctrl_handler,
						&zynq_fm_ctrl_ops,
						V4L2_CID_RDS_RX_TRAFFIC_PROGRAM,
						0, 1, 1, 0);
	radio->ctrl_rds_ta  = v4l2_ctrl_new_std(&radio->ctrl_handler,
						&zynq_fm_ctrl_ops,
						V4L2_CID_RDS_RX_TRAFFIC_ANNOUNCEMENT,
						0, 1, 1, 0);
	radio->ctrl_rds_ms  = v4l2_ctrl_new_std(&radio->ctrl_handler,
						&zynq_fm_ctrl_ops,
						V4L2_CID_RDS_RX_MUSIC_SPEECH,
						0, 1, 1, 0);

	if (radio->ctrl_rds_pty)
		radio->ctrl_rds_pty->flags |= V4L2_CTRL_FLAG_READ_ONLY;
	if (radio->ctrl_rds_ps)
		radio->ctrl_rds_ps->flags  |= V4L2_CTRL_FLAG_READ_ONLY;
	if (radio->ctrl_rds_rt)
		radio->ctrl_rds_rt->flags  |= V4L2_CTRL_FLAG_READ_ONLY;
	if (radio->ctrl_rds_tp)
		radio->ctrl_rds_tp->flags  |= V4L2_CTRL_FLAG_READ_ONLY;
	if (radio->ctrl_rds_ta)
		radio->ctrl_rds_ta->flags  |= V4L2_CTRL_FLAG_READ_ONLY;
	if (radio->ctrl_rds_ms)
		radio->ctrl_rds_ms->flags  |= V4L2_CTRL_FLAG_READ_ONLY;

	if (radio->ctrl_handler.error) {
		v4l2_ctrl_handler_free(&radio->ctrl_handler);
		return radio->ctrl_handler.error;
	}

	radio->v4l2_dev.ctrl_handler = &radio->ctrl_handler;
	return 0;
}

/* ================================================================
 * V4L2 ioctl handlers
 * ================================================================ */

static int zynq_fm_querycap(struct file *file, void *priv,
			    struct v4l2_capability *cap)
{
	strscpy(cap->driver,   DRIVER_NAME, sizeof(cap->driver));
	strscpy(cap->card,     CARD_NAME,   sizeof(cap->card));
	strscpy(cap->bus_info, "platform:" DRIVER_NAME, sizeof(cap->bus_info));
	return 0;
}

static int zynq_fm_g_tuner(struct file *file, void *priv,
			   struct v4l2_tuner *t)
{
	struct zynq_fm_radio *radio = video_drvdata(file);
	u32 st, cval;

	if (t->index != 0)
		return -EINVAL;

	strscpy(t->name, "FM", sizeof(t->name));
	t->type       = V4L2_TUNER_RADIO;
	/* The core ORs in V4L2_TUNER_CAP_FREQ_BANDS on the way out. */
	t->capability = ZYNQ_FM_TUNER_CAPS;
	t->rangelow   = FREQ_V4L2_MIN;
	t->rangehigh  = FREQ_V4L2_MAX;

	mutex_lock(&radio->lock);
	st   = hw_read_status(radio);
	cval = hw_read_controls(radio);
	mutex_unlock(&radio->lock);

	t->signal     = hw_signal_strength(st);
	t->rxsubchans = hw_stereo(st) ? V4L2_TUNER_SUB_STEREO
				      : V4L2_TUNER_SUB_MONO;
	if (hw_rds_sync(st))
		t->rxsubchans |= V4L2_TUNER_SUB_RDS;
	t->audmode    = (cval & CTRL_MONO) ? V4L2_TUNER_MODE_MONO
					    : V4L2_TUNER_MODE_STEREO;
	return 0;
}

static int zynq_fm_s_tuner(struct file *file, void *priv,
			   const struct v4l2_tuner *t)
{
	struct zynq_fm_radio *radio = video_drvdata(file);

	if (t->index != 0)
		return -EINVAL;

	/*
	 * V4L2 standard: audmode selects mono/stereo reception.
	 * Map to CTRL_MONO bit in the FPGA controls register.
	 */
	mutex_lock(&radio->lock);
	hw_set_control_bit(radio, CTRL_MONO,
			   t->audmode == V4L2_TUNER_MODE_MONO);
	mutex_unlock(&radio->lock);

	return 0;
}

static int zynq_fm_g_frequency(struct file *file, void *priv,
			       struct v4l2_frequency *f)
{
	struct zynq_fm_radio *radio = video_drvdata(file);

	if (f->tuner != 0)
		return -EINVAL;

	f->type = V4L2_TUNER_RADIO;
	mutex_lock(&radio->lock);
	f->frequency = radio->freq;
	mutex_unlock(&radio->lock);
	return 0;
}

static int zynq_fm_s_frequency(struct file *file, void *priv,
			       const struct v4l2_frequency *f)
{
	struct zynq_fm_radio *radio = video_drvdata(file);
	u32 freq;

	if (f->tuner != 0)
		return -EINVAL;

	freq = clamp(f->frequency, FREQ_V4L2_MIN, FREQ_V4L2_MAX);

	mutex_lock(&radio->lock);
	hw_set_tuning(radio, freq);
	mutex_unlock(&radio->lock);
	return 0;
}

/* Hardware-assisted seek (blocking with unlocked sleep) */
static int zynq_fm_s_hw_freq_seek(struct file *file, void *priv,
				  const struct v4l2_hw_freq_seek *seek)
{
	struct zynq_fm_radio *radio = video_drvdata(file);
	u32 freq, orig_freq;
	u32 low = FREQ_V4L2_MIN, high = FREQ_V4L2_MAX;
	int i;

	if (seek->tuner != 0 || seek->type != V4L2_TUNER_RADIO)
		return -EINVAL;

	/*
	 * Seek blocks for up to tens of seconds; the V4L2 spec requires
	 * returning EWOULDBLOCK for non-blocking file handles.
	 */
	if (file->f_flags & O_NONBLOCK)
		return -EWOULDBLOCK;

	/* Optional caller-supplied seek range (must lie within the band) */
	if (seek->rangelow || seek->rangehigh) {
		if (seek->rangelow < FREQ_V4L2_MIN ||
		    seek->rangehigh > FREQ_V4L2_MAX ||
		    seek->rangelow >= seek->rangehigh)
			return -ERANGE;
		low  = seek->rangelow;
		high = seek->rangehigh;
	}

	mutex_lock(&radio->lock);
	freq = orig_freq = radio->freq;
	mutex_unlock(&radio->lock);

	for (i = 0; i < SEEK_MAX_STEPS; i++) {
		if (seek->seek_upward) {
			freq += FREQ_V4L2_STEP;
			if (freq > high) {
				if (seek->wrap_around)
					freq = low;
				else
					goto not_found;
			}
		} else {
			if (freq <= low + FREQ_V4L2_STEP - 1) {
				if (seek->wrap_around)
					freq = high;
				else
					goto not_found;
			} else {
				freq -= FREQ_V4L2_STEP;
			}
		}

		/* Update frequency */
		mutex_lock(&radio->lock);
		hw_set_tuning(radio, freq);
		mutex_unlock(&radio->lock);

		/* Wait for lock without holding the mutex */
		msleep(TUNE_SETTLE_MS);

		/* Check status */
		mutex_lock(&radio->lock);
		if (hw_station_found(hw_read_status(radio))) {
			mutex_unlock(&radio->lock);
			return 0;
		}
		mutex_unlock(&radio->lock);
	}

not_found:
	/*
	 * Per the V4L2 spec, the original frequency must be restored when
	 * no station is found.
	 */
	mutex_lock(&radio->lock);
	hw_set_tuning(radio, orig_freq);
	mutex_unlock(&radio->lock);
	return -ENODATA;
}

static int zynq_fm_enum_freq_bands(struct file *file, void *priv,
				   struct v4l2_frequency_band *band)
{
	if (band->tuner != 0 || band->index != 0)
		return -EINVAL;

	band->type       = V4L2_TUNER_RADIO;
	/*
	 * V4L2_TUNER_CAP_FREQ_BANDS must be added by hand here: the core only
	 * ORs it into G_TUNER results, and v4l2-compliance both requires the
	 * bit to be present in every band and requires the union of all band
	 * capabilities to equal the tuner's own.
	 */
	band->capability = ZYNQ_FM_TUNER_CAPS | V4L2_TUNER_CAP_FREQ_BANDS;
	band->rangelow   = FREQ_V4L2_MIN;
	band->rangehigh  = FREQ_V4L2_MAX;
	band->modulation = V4L2_BAND_MODULATION_FM;
	return 0;
}

static const struct v4l2_ioctl_ops zynq_fm_ioctl_ops = {
	.vidioc_querycap	= zynq_fm_querycap,
	.vidioc_g_tuner		= zynq_fm_g_tuner,
	.vidioc_s_tuner		= zynq_fm_s_tuner,
	.vidioc_g_frequency	= zynq_fm_g_frequency,
	.vidioc_s_frequency	= zynq_fm_s_frequency,
	.vidioc_s_hw_freq_seek	= zynq_fm_s_hw_freq_seek,
	.vidioc_enum_freq_bands	= zynq_fm_enum_freq_bands,

	/* Control ioctls handled automatically by V4L2 core via ctrl_handler */
};

/* ================================================================
 * File operations (with RDS read / poll support)
 * ================================================================ */

static int zynq_fm_open(struct file *file)
{
	struct video_device *vdev = video_devdata(file);
	struct zynq_fm_radio *radio = video_drvdata(file);
	struct zynq_fm_fh *fh;
	unsigned long flags;

	fh = kzalloc(sizeof(*fh), GFP_KERNEL);
	if (!fh)
		return -ENOMEM;

	/*
	 * Hand-rolled instead of v4l2_fh_open(), which allocates a bare
	 * struct v4l2_fh -- we need our own read index alongside it.
	 * v4l2_fh_init() picks up vdev->ctrl_handler, so the control ioctls
	 * keep working exactly as before.
	 */
	v4l2_fh_init(&fh->fh, vdev);
	v4l2_fh_add(&fh->fh);
	file->private_data = &fh->fh;

	spin_lock_irqsave(&radio->rds_lock, flags);
	/*
	 * Start at the current write position: a new reader gets blocks from
	 * now on, not a ring's worth of stale backlog decoded as if it were
	 * live.  Note this no longer resets the ring itself -- doing that on
	 * every 0->1 open discarded blocks belonging to readers that were
	 * still running, and fired on unrelated opens (plain v4l2-ctl calls)
	 * too.
	 */
	fh->rd = radio->rds_wr;
	list_add(&fh->node, &radio->rds_readers);
	spin_unlock_irqrestore(&radio->rds_lock, flags);

	return 0;
}

static int zynq_fm_release(struct file *file)
{
	struct zynq_fm_radio *radio = video_drvdata(file);
	struct zynq_fm_fh *fh =
		container_of(file->private_data, struct zynq_fm_fh, fh);
	unsigned long flags;

	spin_lock_irqsave(&radio->rds_lock, flags);
	list_del(&fh->node);
	spin_unlock_irqrestore(&radio->rds_lock, flags);

	v4l2_fh_del(&fh->fh);
	v4l2_fh_exit(&fh->fh);
	kfree(fh);
	file->private_data = NULL;

	return 0;
}

/*
 * read() — returns v4l2_rds_data blocks to userspace.
 *
 * The buffer must be a multiple of sizeof(struct v4l2_rds_data) = 3.
 * Blocks if no data is available (unless O_NONBLOCK).
 */
static ssize_t zynq_fm_read(struct file *file, char __user *buf,
			    size_t count, loff_t *ppos)
{
	struct zynq_fm_radio *radio = video_drvdata(file);
	struct zynq_fm_fh *fh =
		container_of(file->private_data, struct zynq_fm_fh, fh);
	size_t block_size = sizeof(struct v4l2_rds_data);	/* 3 */
	unsigned int avail, to_copy, chunk;
	unsigned long flags;
	ssize_t copied = 0;
	int ret;

	if (count < block_size)
		return -EINVAL;

	/* Truncate to whole blocks */
	count -= count % block_size;

	/* Wait for data */
	if (file->f_flags & O_NONBLOCK) {
		spin_lock_irqsave(&radio->rds_lock, flags);
		avail = rds_buf_count(radio, fh);
		spin_unlock_irqrestore(&radio->rds_lock, flags);
		if (avail == 0)
			return -EAGAIN;
	} else {
		ret = wait_event_interruptible(radio->rds_wq,
			({
				spin_lock_irqsave(&radio->rds_lock, flags);
				avail = rds_buf_count(radio, fh);
				spin_unlock_irqrestore(&radio->rds_lock, flags);
				avail > 0;
			}));
		if (ret)
			return ret;
	}

	/*
	 * Copy data to userspace.
	 *
	 * copy_to_user() may sleep, so it must not run under the spinlock;
	 * but reading rds_buf[] without the lock races with the producer
	 * (the work handler may overwrite the tail while we copy).  Snapshot
	 * bounded chunks into a stack buffer under the lock, then copy the
	 * snapshot to userspace with the lock dropped.
	 */
	to_copy = count / block_size;

	while (to_copy > 0) {
		struct v4l2_rds_data tmp[32];
		unsigned int i;

		chunk = min_t(unsigned int, to_copy, ARRAY_SIZE(tmp));

		spin_lock_irqsave(&radio->rds_lock, flags);
		avail = rds_buf_count(radio, fh);
		if (chunk > avail)
			chunk = avail;
		for (i = 0; i < chunk; i++) {
			tmp[i] = radio->rds_buf[fh->rd];
			fh->rd = (fh->rd + 1) & RDS_BUF_MASK;
		}
		spin_unlock_irqrestore(&radio->rds_lock, flags);

		if (chunk == 0)
			break;

		if (copy_to_user(buf + copied, tmp, chunk * block_size))
			return copied ? copied : -EFAULT;

		copied  += chunk * block_size;
		to_copy -= chunk;
	}

	return copied;
}

static __poll_t zynq_fm_poll(struct file *file,
			     struct poll_table_struct *wait)
{
	struct zynq_fm_radio *radio = video_drvdata(file);
	struct zynq_fm_fh *fh =
		container_of(file->private_data, struct zynq_fm_fh, fh);
	unsigned long flags;
	__poll_t mask = 0;

	poll_wait(file, &radio->rds_wq, wait);

	spin_lock_irqsave(&radio->rds_lock, flags);
	if (rds_buf_count(radio, fh) > 0)
		mask = EPOLLIN | EPOLLRDNORM;
	spin_unlock_irqrestore(&radio->rds_lock, flags);

	return mask;
}

static const struct v4l2_file_operations zynq_fm_fops = {
	.owner		= THIS_MODULE,
	.open		= zynq_fm_open,
	.release	= zynq_fm_release,
	.read		= zynq_fm_read,
	.poll		= zynq_fm_poll,
	.unlocked_ioctl	= video_ioctl2,
};

/* ================================================================
 * sysfs attributes
 * ================================================================ */

/* show: "101.9\n" */
static ssize_t frequency_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 f, mhz_x10;

	mutex_lock(&radio->lock);
	f = radio->freq;
	mutex_unlock(&radio->lock);

	mhz_x10 = f / (V4L2_UNITS_PER_MHZ / 10);
	return sysfs_emit(buf, "%u.%u\n", mhz_x10 / 10, mhz_x10 % 10);
}

/* store: echo "101.9" or "101" */
static ssize_t frequency_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int integer_part = 0, frac_part = 0;
	const char *dot;
	u32 freq_v4l2;

	if (kstrtouint(buf, 10, &integer_part) != 0) {
		if (sscanf(buf, "%u", &integer_part) != 1)
			return -EINVAL;
	}

	dot = strchr(buf, '.');
	if (dot && dot[1] >= '0' && dot[1] <= '9')
		frac_part = dot[1] - '0';

	freq_v4l2 = (integer_part * 10 + frac_part) * (V4L2_UNITS_PER_MHZ / 10);

	if (freq_v4l2 < FREQ_V4L2_MIN || freq_v4l2 > FREQ_V4L2_MAX)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_tuning(radio, freq_v4l2);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(frequency);

/* RSSI: raw 18-bit value */
static ssize_t rssi_show(struct device *dev,
			 struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", hw_rssi(st));
}
static DEVICE_ATTR_RO(rssi);

/* Stereo pilot lock: 1 / 0 */
static ssize_t stereo_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", hw_stereo(st) ? 1 : 0);
}
static DEVICE_ATTR_RO(stereo);

/* Station-found flag: 1 / 0 */
static ssize_t station_found_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", hw_station_found(st) ? 1 : 0);
}
static DEVICE_ATTR_RO(station_found);

/* RDS sync flag: 1 / 0 */
static ssize_t rds_sync_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", hw_rds_sync(st) ? 1 : 0);
}
static DEVICE_ATTR_RO(rds_sync);

/* RDS Program Service name (up to 8 chars, empty if no sync) */
static ssize_t rds_ps_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	char ps[9];
	u32 st;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		hw_read_rds_ps(radio, ps);
	else
		ps[0] = '\0';
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%s\n", ps);
}
static DEVICE_ATTR_RO(rds_ps);

/* RDS Programme Identification, hex (empty if no sync) */
static ssize_t rds_pi_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st;
	u16 pi = 0;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		pi = hw_read_rds_pi(radio);
	mutex_unlock(&radio->lock);

	if (!hw_rds_sync(st))
		return sysfs_emit(buf, "\n");

	return sysfs_emit(buf, "%04X\n", pi);
}
static DEVICE_ATTR_RO(rds_pi);

/* RDS Programme Type, numeric 0..31 (-1 if no sync) */
static ssize_t rds_pty_show(struct device *dev,
			    struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st, f = 0;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		f = hw_read_rds_flags(radio);
	mutex_unlock(&radio->lock);

	if (!hw_rds_sync(st))
		return sysfs_emit(buf, "-1\n");

	return sysfs_emit(buf, "%u\n", rds_flags_pty(f));
}
static DEVICE_ATTR_RO(rds_pty);

/* RDS Programme Type as text (IEC 62106 European table) */
static ssize_t rds_pty_name_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st, f = 0;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		f = hw_read_rds_flags(radio);
	mutex_unlock(&radio->lock);

	if (!hw_rds_sync(st))
		return sysfs_emit(buf, "\n");

	return sysfs_emit(buf, "%s\n", rds_pty_names[rds_flags_pty(f)]);
}
static DEVICE_ATTR_RO(rds_pty_name);

/* Traffic Programme flag (-1 if no sync) */
static ssize_t rds_tp_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st, f = 0;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		f = hw_read_rds_flags(radio);
	mutex_unlock(&radio->lock);

	if (!hw_rds_sync(st))
		return sysfs_emit(buf, "-1\n");

	return sysfs_emit(buf, "%d\n", rds_flags_tp(f) ? 1 : 0);
}
static DEVICE_ATTR_RO(rds_tp);

/* Traffic Announcement flag (-1 if no sync) */
static ssize_t rds_ta_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st, f = 0;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		f = hw_read_rds_flags(radio);
	mutex_unlock(&radio->lock);

	if (!hw_rds_sync(st))
		return sysfs_emit(buf, "-1\n");

	return sysfs_emit(buf, "%d\n", rds_flags_ta(f) ? 1 : 0);
}
static DEVICE_ATTR_RO(rds_ta);

/* Music/Speech flag: 1 = music, 0 = speech (-1 if no sync) */
static ssize_t rds_ms_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st, f = 0;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		f = hw_read_rds_flags(radio);
	mutex_unlock(&radio->lock);

	if (!hw_rds_sync(st))
		return sysfs_emit(buf, "-1\n");

	return sysfs_emit(buf, "%d\n", rds_flags_ms(f) ? 1 : 0);
}
static DEVICE_ATTR_RO(rds_ms);

/* RadioText (up to 64 chars, empty if no sync) */
static ssize_t rds_rt_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	char rt[RDS_RT_CHARS + 1];
	u32 st;

	mutex_lock(&radio->lock);
	st = hw_read_status(radio);
	if (hw_rds_sync(st))
		hw_read_rds_rt(radio, rt);
	else
		rt[0] = '\0';
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%s\n", rt);
}
static DEVICE_ATTR_RO(rds_rt);

/* Combined human-readable status */
static ssize_t status_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 st, f, mhz_x10, vol, ctrl, rflags = 0;
	char ps[RDS_PS_CHARS + 1];
	char rt[RDS_RT_CHARS + 1];
	u16 pi = 0;
	bool synced;

	mutex_lock(&radio->lock);
	st     = hw_read_status(radio);
	f      = radio->freq;
	vol    = hw_get_volume(radio);
	ctrl   = hw_read_controls(radio);
	synced = hw_rds_sync(st);
	if (synced) {
		pi     = hw_read_rds_pi(radio);
		rflags = hw_read_rds_flags(radio);
		hw_read_rds_ps(radio, ps);
		hw_read_rds_rt(radio, rt);
	} else {
		ps[0] = '\0';
		rt[0] = '\0';
	}
	mutex_unlock(&radio->lock);

	mhz_x10 = f / (V4L2_UNITS_PER_MHZ / 10);

	return sysfs_emit(buf,
		"frequency=%u.%u MHz stereo=%d station_found=%d rssi=%d "
		"volume=%u mute=%d bass_boost=%d rds_en=%d "
		"deemph=%s mono=%d rds_sync=%d rds_pi=%04X rds_pty=%u (%s) "
		"rds_tp=%d rds_ta=%d rds_ms=%s rds_ps=\"%s\" rds_rt=\"%s\"\n",
		mhz_x10 / 10, mhz_x10 % 10,
		hw_stereo(st) ? 1 : 0,
		hw_station_found(st) ? 1 : 0,
		hw_rssi(st),
		vol,
		!!(ctrl & CTRL_MUTE_EN),
		!!(ctrl & CTRL_BASS_BOOST_EN),
		!!(ctrl & CTRL_RDS_EN),
		(ctrl & CTRL_DEEMPH) ? "50us" : "75us",
		!!(ctrl & CTRL_MONO),
		synced ? 1 : 0,
		pi,
		rds_flags_pty(rflags), rds_pty_names[rds_flags_pty(rflags)],
		rds_flags_tp(rflags) ? 1 : 0,
		rds_flags_ta(rflags) ? 1 : 0,
		rds_flags_ms(rflags) ? "music" : "speech",
		ps, rt);
}
static DEVICE_ATTR_RO(status);

/* Seek up: echo 1 > seek_up  (blocks until station found or full sweep) */
static ssize_t seek_up_store(struct device *dev,
			     struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 freq;
	int i;

	mutex_lock(&radio->lock);
	freq = radio->freq;
	mutex_unlock(&radio->lock);

	for (i = 0; i < SEEK_MAX_STEPS; i++) {
		freq += FREQ_V4L2_STEP;
		if (freq > FREQ_V4L2_MAX)
			freq = FREQ_V4L2_MIN;

		mutex_lock(&radio->lock);
		hw_set_tuning(radio, freq);
		mutex_unlock(&radio->lock);

		msleep(TUNE_SETTLE_MS);

		mutex_lock(&radio->lock);
		if (hw_station_found(hw_read_status(radio))) {
			mutex_unlock(&radio->lock);
			break;
		}
		mutex_unlock(&radio->lock);
	}

	return count;
}
static DEVICE_ATTR_WO(seek_up);

/* Seek down: echo 1 > seek_down */
static ssize_t seek_down_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 freq;
	int i;

	mutex_lock(&radio->lock);
	freq = radio->freq;
	mutex_unlock(&radio->lock);

	for (i = 0; i < SEEK_MAX_STEPS; i++) {
		if (freq <= FREQ_V4L2_MIN)
			freq = FREQ_V4L2_MAX;
		else
			freq -= FREQ_V4L2_STEP;

		mutex_lock(&radio->lock);
		hw_set_tuning(radio, freq);
		mutex_unlock(&radio->lock);

		msleep(TUNE_SETTLE_MS);

		mutex_lock(&radio->lock);
		if (hw_station_found(hw_read_status(radio))) {
			mutex_unlock(&radio->lock);
			break;
		}
		mutex_unlock(&radio->lock);
	}

	return count;
}
static DEVICE_ATTR_WO(seek_down);

/* ---------- Volume sysfs (0..15) ---------- */

static ssize_t volume_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 vol;

	mutex_lock(&radio->lock);
	vol = hw_get_volume(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%u\n", vol);
}

static ssize_t volume_store(struct device *dev,
			    struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > VOL_MAX)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_volume(radio, val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(volume);

/* ---------- Mute sysfs (0/1) ---------- */

static ssize_t mute_show(struct device *dev,
			 struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 ctrl;

	mutex_lock(&radio->lock);
	ctrl = hw_read_controls(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", !!(ctrl & CTRL_MUTE_EN));
}

static ssize_t mute_store(struct device *dev,
			  struct device_attribute *attr,
			  const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > 1)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_control_bit(radio, CTRL_MUTE_EN, !!val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(mute);

/* ---------- Bass Boost sysfs (0/1) ---------- */

static ssize_t bass_boost_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 ctrl;

	mutex_lock(&radio->lock);
	ctrl = hw_read_controls(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", !!(ctrl & CTRL_BASS_BOOST_EN));
}

static ssize_t bass_boost_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > 1)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_control_bit(radio, CTRL_BASS_BOOST_EN, !!val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(bass_boost);

/* ---------- RDS Enable sysfs (0/1) ---------- */

static ssize_t rds_en_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 ctrl;

	mutex_lock(&radio->lock);
	ctrl = hw_read_controls(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", !!(ctrl & CTRL_RDS_EN));
}

static ssize_t rds_en_store(struct device *dev,
			    struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > 1)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_control_bit(radio, CTRL_RDS_EN, !!val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(rds_en);

/* ---------- De-emphasis sysfs (0=75µs / 1=50µs) ---------- */

static ssize_t deemph_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 ctrl;

	mutex_lock(&radio->lock);
	ctrl = hw_read_controls(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", !!(ctrl & CTRL_DEEMPH));
}

static ssize_t deemph_store(struct device *dev,
			    struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > 1)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_control_bit(radio, CTRL_DEEMPH, !!val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(deemph);

/* ---------- Mono sysfs (0=stereo auto / 1=force mono) ---------- */

static ssize_t mono_show(struct device *dev,
			 struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 ctrl;

	mutex_lock(&radio->lock);
	ctrl = hw_read_controls(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%d\n", !!(ctrl & CTRL_MONO));
}

static ssize_t mono_store(struct device *dev,
			  struct device_attribute *attr,
			  const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > 1)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_control_bit(radio, CTRL_MONO, !!val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(mono);

/* ---------- RDS block-quality stats (0x28, free-running since reset) ---------- */

static ssize_t rds_block_stats_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 v;

	mutex_lock(&radio->lock);
	v = hw_read_rds_err_stats(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "corrected=%u uncorrectable=%u\n",
			   rds_err_stats_corrected(v),
			   rds_err_stats_uncorrectable(v));
}
static DEVICE_ATTR_RO(rds_block_stats);

/* ---------- Raw-MPX export shift (0x34, see MPX_SHIFT register note) ---------- */

static ssize_t mpx_shift_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	u32 v;

	mutex_lock(&radio->lock);
	v = hw_get_mpx_shift(radio);
	mutex_unlock(&radio->lock);

	return sysfs_emit(buf, "%u\n", v);
}

static ssize_t mpx_shift_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct zynq_fm_radio *radio = dev_get_drvdata(dev);
	unsigned int val;
	int ret;

	ret = kstrtouint(buf, 10, &val);
	if (ret)
		return ret;
	if (val > MPX_SHIFT_MASK)
		return -EINVAL;

	mutex_lock(&radio->lock);
	hw_set_mpx_shift(radio, val);
	mutex_unlock(&radio->lock);

	return count;
}
static DEVICE_ATTR_RW(mpx_shift);

/* ---------- sysfs group ---------- */

static struct attribute *zynq_fm_attrs[] = {
	&dev_attr_frequency.attr,
	&dev_attr_rssi.attr,
	&dev_attr_stereo.attr,
	&dev_attr_station_found.attr,
	&dev_attr_rds_sync.attr,
	&dev_attr_rds_ps.attr,
	&dev_attr_rds_pi.attr,
	&dev_attr_rds_pty.attr,
	&dev_attr_rds_pty_name.attr,
	&dev_attr_rds_tp.attr,
	&dev_attr_rds_ta.attr,
	&dev_attr_rds_ms.attr,
	&dev_attr_rds_rt.attr,
	&dev_attr_status.attr,
	&dev_attr_seek_up.attr,
	&dev_attr_seek_down.attr,
	&dev_attr_volume.attr,
	&dev_attr_mute.attr,
	&dev_attr_bass_boost.attr,
	&dev_attr_rds_en.attr,
	&dev_attr_deemph.attr,
	&dev_attr_mono.attr,
	&dev_attr_rds_block_stats.attr,
	&dev_attr_mpx_shift.attr,
	NULL,
};

static const struct attribute_group zynq_fm_attr_group = {
	.attrs = zynq_fm_attrs,
};

static const struct attribute_group *zynq_fm_attr_groups[] = {
	&zynq_fm_attr_group,
	NULL,
};

/* ================================================================
 * Platform driver probe / remove
 * ================================================================ */

static int zynq_fm_radio_probe(struct platform_device *pdev)
{
	struct zynq_fm_radio *radio;
	int ret;

	radio = devm_kzalloc(&pdev->dev, sizeof(*radio), GFP_KERNEL);
	if (!radio)
		return -ENOMEM;

	radio->dev = &pdev->dev;
	mutex_init(&radio->lock);
	spin_lock_init(&radio->rds_lock);
	INIT_LIST_HEAD(&radio->rds_readers);
	init_waitqueue_head(&radio->rds_wq);
	INIT_DELAYED_WORK(&radio->rds_work, rds_work_handler);
	init_waitqueue_head(&radio->mpx_wq);
	init_waitqueue_head(&radio->audio_wq);
	atomic_set(&radio->stream_openers, 0);
	INIT_DELAYED_WORK(&radio->stream_kick_work, stream_kick_handler);
	platform_set_drvdata(pdev, radio);

	/* Map AXI registers (must cover 0x00..0x1B → at least 0x1C bytes) */
	radio->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(radio->regs))
		return PTR_ERR(radio->regs);

	/* Initialise V4L2 control framework */
	ret = zynq_fm_init_controls(radio);
	if (ret) {
		dev_err(&pdev->dev, "ctrl handler init failed: %d\n", ret);
		return ret;
	}

	/* Register V4L2 device */
	ret = v4l2_device_register(&pdev->dev, &radio->v4l2_dev);
	if (ret) {
		dev_err(&pdev->dev, "v4l2_device_register failed: %d\n", ret);
		goto err_ctrl;
	}

	/* Fill in video_device */
	strscpy(radio->vdev.name, CARD_NAME, sizeof(radio->vdev.name));
	radio->vdev.v4l2_dev    = &radio->v4l2_dev;
	radio->vdev.fops        = &zynq_fm_fops;
	radio->vdev.ioctl_ops   = &zynq_fm_ioctl_ops;
	radio->vdev.release     = video_device_release_empty;
	radio->vdev.vfl_type    = VFL_TYPE_RADIO;
	radio->vdev.device_caps = V4L2_CAP_TUNER | V4L2_CAP_RADIO |
				  V4L2_CAP_HW_FREQ_SEEK |
				  V4L2_CAP_RDS_CAPTURE |
				  V4L2_CAP_READWRITE;
	radio->vdev.ctrl_handler = &radio->ctrl_handler;
	video_set_drvdata(&radio->vdev, radio);

	ret = video_register_device(&radio->vdev, VFL_TYPE_RADIO, -1);
	if (ret) {
		dev_err(&pdev->dev, "video_register_device failed: %d\n", ret);
		goto err_v4l2;
	}

	/*
	 * Raw MPX / post-resampler audio sample export -- see the
	 * "Raw MPX / post-resampler audio sample export" section above.
	 * Registered after the video device so a failure here does not
	 * leave /dev/radioN half-initialised; torn down in the reverse
	 * order on any later failure and in remove().
	 */
	radio->mpx_miscdev.minor = MISC_DYNAMIC_MINOR;
	radio->mpx_miscdev.name  = "zynq_fm_mpx";
	radio->mpx_miscdev.fops  = &mpx_dev_fops;
	ret = misc_register(&radio->mpx_miscdev);
	if (ret) {
		dev_err(&pdev->dev, "mpx misc_register failed: %d\n", ret);
		goto err_vdev;
	}

	radio->audio_miscdev.minor = MISC_DYNAMIC_MINOR;
	radio->audio_miscdev.name  = "zynq_fm_audio";
	radio->audio_miscdev.fops  = &audio_dev_fops;
	ret = misc_register(&radio->audio_miscdev);
	if (ret) {
		dev_err(&pdev->dev, "audio misc_register failed: %d\n", ret);
		goto err_mpx_misc;
	}

	/*
	 * sysfs attributes are created by the driver core via
	 * zynq_fm_radio_driver.driver.dev_groups (devm_device_add_groups()
	 * was removed from the kernel in 6.8).
	 */

	/* Default frequency (not a V4L2 control — write directly) */
	//hw_set_tuning(radio, 100U * V4L2_UNITS_PER_MHZ);

	/*
	 * Push default values for all V4L2 controls to hardware via s_ctrl.
	 * This synchronises the framework's cached cur.val with the actual
	 * register state, so that subsequent set-ctrl calls always reach HW.
	 */
	ret = v4l2_ctrl_handler_setup(&radio->ctrl_handler);
	if (ret) {
		dev_err(&pdev->dev, "ctrl handler setup failed: %d\n", ret);
		goto err_audio_misc;
	}

	/*
	 * Start the RDS drain last, once nothing else can fail -- it re-arms
	 * itself, so starting it before a possible error return would leave
	 * work queued against a half-torn-down device.  It runs until
	 * remove() calls rds_stop().
	 */
	rds_start(radio);

	dev_info(&pdev->dev,
		 "registered as /dev/%s  ( vol=%d, RDS read support)\n",
		 video_device_node_name(&radio->vdev), VOL_MAX);
	return 0;

err_audio_misc:
	misc_deregister(&radio->audio_miscdev);
err_mpx_misc:
	misc_deregister(&radio->mpx_miscdev);
err_vdev:
	video_unregister_device(&radio->vdev);
err_v4l2:
	v4l2_device_unregister(&radio->v4l2_dev);
err_ctrl:
	v4l2_ctrl_handler_free(&radio->ctrl_handler);
	return ret;
}

/*
 * platform_driver::remove() returns void since Linux 6.11 (and the old
 * int-returning variant was removed entirely later on).  Keep both
 * signatures so the driver builds on every kernel from 5.15 onwards.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
static void zynq_fm_radio_remove(struct platform_device *pdev)
#else
static int zynq_fm_radio_remove(struct platform_device *pdev)
#endif
{
	struct zynq_fm_radio *radio = platform_get_drvdata(pdev);

	/* Stop RDS work if still running */
	rds_stop(radio);

	/* Stop the raw-sample poll kicker and unregister its two devices */
	cancel_delayed_work_sync(&radio->stream_kick_work);
	misc_deregister(&radio->audio_miscdev);
	misc_deregister(&radio->mpx_miscdev);

	video_unregister_device(&radio->vdev);
	v4l2_device_unregister(&radio->v4l2_dev);
	v4l2_ctrl_handler_free(&radio->ctrl_handler);

	dev_info(&pdev->dev, "removed\n");
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)
	return 0;
#endif
}

/* ================================================================
 * Device-tree match table
 * ================================================================ */

static const struct of_device_id zynq_fm_radio_of_match[] = {
	{ .compatible = "xlnx,zynq-fm-radio-1.0" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, zynq_fm_radio_of_match);

static struct platform_driver zynq_fm_radio_driver = {
	.probe	= zynq_fm_radio_probe,
	.remove	= zynq_fm_radio_remove,
	.driver	= {
		.name		= DRIVER_NAME,
		.of_match_table	= zynq_fm_radio_of_match,
		.dev_groups	= zynq_fm_attr_groups,
	},
};
module_platform_driver(zynq_fm_radio_driver);

MODULE_AUTHOR("Alex V.");
MODULE_DESCRIPTION("V4L2 FM Radio driver for Zynq PL SDR receiver (with RDS)");
MODULE_LICENSE("GPL");

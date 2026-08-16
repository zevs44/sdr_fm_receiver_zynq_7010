# Makefile for zynq-fm-radio out-of-tree kernel module
#
# Usage (cross-compile for Zynq ARM):
#   make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KDIR=/path/to/kernel
#
# Usage (OpenWRT):
#   Point KDIR to your OpenWRT build's linux source, e.g.:
#   make ARCH=arm CROSS_COMPILE=arm-openwrt-linux-gnueabi- \
#        KDIR=$(TOPDIR)/build_dir/target-arm_cortex-a9+neon_musl_eabi/linux-zynq/linux-5.15.x
#

obj-m := zynq_fm_radio.o

KDIR  ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

	.PHONY: all clean

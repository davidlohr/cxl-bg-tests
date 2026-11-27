#!/bin/bash
# t5-actfw.sh - three devices that run Activate FW in the background.
#
# Needs qemu/0002-*.patch. Activation takes five seconds on both, and
# on the second one it then fails with "Activation Failed, FW Rolled
# Back": the firmware upload has to wait for it, and say how it ended.
# The third takes longer than the kernel is willing to wait (opt-in
# group actfwtmo, five and a half minutes).
BG_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BG_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-object memory-backend-ram,id=m2,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
	-device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=3 \
	-device cxl-rp,port=2,bus=cxl.1,id=rp2,chassis=0,slot=4 \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0,x-fw-activate-ms=5000 \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1,x-fw-activate-ms=5000,x-fw-activate-fail=on \
	-device cxl-type3,bus=rp2,volatile-memdev=m2,id=mem2,x-fw-activate-ms=330000 \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G

#!/bin/bash
# t2-pair.sh - two devices, one mailbox each.
#
# The background slot is per device: an operation on one must leave the
# other free to start its own, and neither driver instance may see the
# other's state.
BG_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BG_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
	-device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=3 \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0 \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1 \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G

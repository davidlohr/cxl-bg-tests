#!/bin/bash
# t4-quad.sh - four devices behind two host bridges, one mailbox each.
#
# Enough devices to give each a different owner of its background slot
# at the same time - the kernel's sanitize, a userspace command, one
# that cannot be aborted, a firmware transfer the kernel polls for -
# and to put several users on every one of them. All four are 1G, so
# the durations are those of t1.
BG_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BG_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-object memory-backend-ram,id=m1,size=1G \
	-object memory-backend-ram,id=m2,size=1G \
	-object memory-backend-ram,id=m3,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device pxb-cxl,bus_nr=222,bus=pcie.0,id=cxl.2 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
	-device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=3 \
	-device cxl-rp,port=2,bus=cxl.2,id=rp2,chassis=0,slot=4 \
	-device cxl-rp,port=3,bus=cxl.2,id=rp3,chassis=0,slot=5 \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0 \
	-device cxl-type3,bus=rp1,volatile-memdev=m1,id=mem1 \
	-device cxl-type3,bus=rp2,volatile-memdev=m2,id=mem2 \
	-device cxl-type3,bus=rp3,volatile-memdev=m3,id=mem3 \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.targets.1=cxl.2,cxl-fmw.0.size=4G

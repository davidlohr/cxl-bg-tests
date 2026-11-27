#!/bin/bash
# t1-single.sh - one volatile Type 3 device under a root port.
#
# Everything the background command machinery does is per mailbox, so
# one device is the whole topology. 1G is what sets the durations the
# suite leans on: QEMU runs Sanitize for 8s on a device of that size
# and Scan Media for about 8ms per megabyte scanned.
BG_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BG_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0 \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G

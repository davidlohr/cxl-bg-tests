#!/bin/bash
# t3-noirq.sh - the device of t1, booted without MSI/MSI-X.
#
# The background command completion interrupt is optional, for the
# device and for the driver: without a vector the driver leaves it
# disabled and finds completions by polling, from the delayed work for
# the operations it does not wait for and in slices for the ones it
# does. QEMU has no knob to make the mailbox interrupt incapable, so
# the vectors are taken away from the whole guest instead.
BG_TESTS_DIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
EXTRA_APPEND="$EXTRA_APPEND pci=nomsi"
source "$BG_TESTS_DIR/topo-lib.sh"

launch_qemu \
	-object memory-backend-ram,id=m0,size=1G \
	-device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
	-device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
	-device cxl-type3,bus=rp0,volatile-memdev=m0,id=mem0 \
	-M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G

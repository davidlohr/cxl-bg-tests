#!/bin/bash
# Host-side orchestrator: boot each topology, push the guest driver, run
# it, and keep the TAP, the kernel log and the serial console. Exit 0
# iff every suite passes and no console carries a splat.
#
#   ./run-all.sh                 every suite
#   ./run-all.sh t1              one suite
#   TEST_GROUPS="fw sanitize" ./run-all.sh t1     only those test groups
BG_TESTS_DIR="$(dirname "$(readlink -f "$0")")"
source "$BG_TESTS_DIR/topo-lib.sh"
OUT=${OUT:-$RUNDIR/results}
mkdir -p "$OUT"

declare -A TOPO=( [t1]=t1-single.sh [t2]=t2-pair.sh [t3]=t3-noirq.sh
		  [t4]=t4-quad.sh [t5]=t5-actfw.sh )
# test groups each suite runs by default (empty: all single-device ones)
declare -A SGROUPS=( [t1]="" [t2]="pair" [t3]="noirq fw poplog"
		     [t4]="quadfw quadmatrix quadbarrage quadsanitize quadunbind quadroles"
		     [t5]="actfw" )
ORDER="t1 t2 t3 t4 t5"

run_suite() {
	local suite=$1 topo=$BG_TESTS_DIR/topos/${TOPO[$1]} rc=0 n

	echo "=== $suite (${TOPO[$suite]})"
	export CONSOLE_ARCHIVE=$OUT/$suite.console
	rm -rf "$CONSOLE_ARCHIVE" "$OUT/$suite".{tap,dmesg}
	bash "$topo" || { echo "not ok - $suite: qemu failed to launch"; return 1; }
	if ! wait_for_guest 180; then
		stop_qemu; console_archive
		return 1
	fi
	guest_ssh "rm -rf /root/cxl-bg-tests; mkdir -p /root/cxl-bg-tests"
	guest_scp "$BG_TESTS_DIR"/guest/*.{sh,py} root@localhost:/root/cxl-bg-tests/
	guest_ssh "NO_BAIL=$NO_BAIL STRESS_SECS=${STRESS_SECS:-30} RACE_SECS=${RACE_SECS:-60} \
		bash /root/cxl-bg-tests/run-tests.sh ${TEST_GROUPS:-${SGROUPS[$suite]}}" | tee "$OUT/$suite.tap"
	guest_ssh dmesg > "$OUT/$suite.dmesg" 2>/dev/null
	stop_qemu
	console_archive

	grep -q '^# passed: [0-9]* *failed: 0$' "$OUT/$suite.tap" || rc=1
	grep -q '^Bail out!' "$OUT/$suite.tap" && rc=1
	# the guest closed its plan before the host looked at the console
	n=$(cat "$CONSOLE_ARCHIVE"/*.log 2>/dev/null | splat_filter |
		grep -cE -- "$SPLAT_RE")
	if [ "${n:-0}" != 0 ]; then
		echo "not ok - $suite: $n splat line(s) on the console"
		cat "$CONSOLE_ARCHIVE"/*.log | splat_filter |
			grep -E -m5 -- "$SPLAT_RE" | sed 's/^/# /'
		rc=1
	else
		echo "ok - $suite: console clean"
	fi
	return $rc
}

FAILED=
for s in ${*:-$ORDER}; do
	[ -n "${TOPO[$s]}" ] || { echo "unknown suite '$s' (choices: $ORDER)" >&2; exit 2; }
	run_suite "$s" || FAILED="$FAILED $s"
done
echo "==================================================="
echo "suites failed: $(wc -w <<<"$FAILED")${FAILED:+ (${FAILED# })} (results in $OUT)"
[ -z "$FAILED" ]

#!/bin/bash
# run-tests.sh - in-guest driver for the CXL mailbox background command
# tests. Emits TAP. Pushed into the guest next to cxlmbox.py by run-all.
#
#   run-tests.sh [group...]     default: every group, in order
#
# Background commands as userspace are sent through the RAW interface:
# QEMU implements one background-capable command that the kernel
# exposes by uapi id, Populate Log, and only group poplog uses it. RAW
# needs CONFIG_CXL_MEM_RAW_COMMANDS and the debugfs raw_allow_all
# override, and costs one WARN on first use.
#
# Durations come from QEMU's models, on the 1G device of the topology:
#   Sanitize                 8s
#   Scan Media               ~8.2ms per MiB scanned, 1ms minimum
#   Media Operations (zero)  4s, and it cannot be aborted
#   Transfer FW              2s per part
#   Populate Log             4s (Component State Dump Log)
# Percentage Complete moves on a one second tick, and QEMU honours a
# Request Abort only below 85%.
#
# Groups outside the default list: pair and the quad* ones need more
# than one device, noirq a boot without MSI, actfw a QEMU that runs
# Activate FW in the background, and staleuntracked is a reproducer
# that is expected to fail.
D=$(dirname "$(readlink -f "$0")")
MBOX="python3 $D/cxlmbox.py"

OP_IDENTIFY=0x4000
OP_HEALTH=0x4200
OP_ABORT=0x0005
OP_POISON_LIST=0x4300
OP_SCAN_MEDIA=0x4304
OP_SCAN_RESULTS=0x4305
OP_MEDIA_OP=0x4402
ID_IDENTIFY=1

T=0; PASS=0; FAIL=0
ok()   { T=$((T+1)); PASS=$((PASS+1)); echo "ok $T - $*"; }
nok()  { T=$((T+1)); FAIL=$((FAIL+1)); echo "not ok $T - $*"; }
skip() { T=$((T+1)); PASS=$((PASS+1)); echo "ok $T - $1 # SKIP $2"; }
diag() { echo "# $*"; }
# check <description> <command...>
check() { local d=$1; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }
bail() { echo "Bail out! $*"; echo "1..$T"; exit 1; }

field() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p"; }
reg()   { $MBOX regs "$MEM" | field "$1"; }
le64()  { printf '%016x' "$1" | fold -w2 | tac | tr -d '\n'; }
le32()  { printf '%08x' "$1" | fold -w2 | tac | tr -d '\n'; }

# raw <opcode> [payload] [out] -> "errno=.. retval=.. ms=.. out=.."
raw()    { $MBOX raw "$MEM" "$1" ${2:+"$2"} ${3:+--out "$3"}; }
ident()  { $MBOX cmd "$MEM" $ID_IDENTIFY "" --out 0x43; }
# Get Health Info is the one command the driver lets through during a
# sanitize. QEMU does not implement it, so it goes out RAW and what
# matters is that it reached the device (errno 0), not what the device
# made of it (Unsupported).
health() { raw $OP_HEALTH "" 0x12; }

# scan <bytes>: Scan Media over [0, bytes), no event log
scan() { raw $OP_SCAN_MEDIA "$(le64 0)$(le64 $(($1 / 64)))01"; }
SCAN_LONG=$((768 << 20))	# ~6.3s
SCAN_SHORT=64			# 1ms
# zero 4K through Media Operations: class 1 (sanitize), subclass 1 (zero)
media_zero() { raw $OP_MEDIA_OP "01010000$(le32 1)$(le64 0)$(le64 4096)"; }

# wait_idle [secs]: until hardware reports no background operation
wait_idle() {
	local n=$(( ${1:-15} * 10 ))
	while [ $n -gt 0 ]; do
		[ "$(reg sts_bg_op)" = 0 ] && return 0
		sleep 0.1; n=$((n-1))
	done
	return 1
}

# settle: hardware idle and the driver caught up with it. The poller
# first looks one second after the command, the interrupt sooner.
settle() { wait_idle "${1:-15}" && sleep 1.3; }

# wait_state_change <secs>: poll(2) on security/state, as a sanitize
# waiter would. Succeeds iff the driver notifies within the timeout.
wait_state_change() {
	python3 - "$MEMDIR/security/state" "$1" <<'EOF'
import select, sys
f = open(sys.argv[1]); f.read()
p = select.poll(); p.register(f, select.POLLPRI | select.POLLERR)
sys.exit(0 if p.poll(float(sys.argv[2]) * 1000) else 1)
EOF
}

# One read of the registers, then fields of that same snapshot: two reads
# can straddle QEMU's one second tick.
snap()  { L=$($MBOX regs "$MEM"); }
sf()    { field "$1" <<<"$L"; }
# since <text>: lines of the kernel log after the mark that carry it
since() { dmesg_since | grep -cF -- "$1"; }
er()    { echo "$(field errno <<<"$1")$(field retval <<<"$1")"; }

now_ms() { date +%s%3N; }
# dmesg_since <marker>: kernel log after the marker line
mark() { MARK="cxl-bg-tests mark $RANDOM$RANDOM"; echo "$MARK" > /dev/kmsg; }
dmesg_since() { dmesg | sed -n "/$MARK/,\$p"; }

setup() {
	MEM=${MEM:-$(ls /sys/bus/cxl/devices | grep -m1 '^mem[0-9]')}
	[ -n "$MEM" ] || bail "no CXL memory device"
	MEMDIR=/sys/bus/cxl/devices/$MEM
	PDEV=$(dirname "$(readlink -f "$MEMDIR")")
	BDF=$(basename "$PDEV")
	mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
	echo 1 > /sys/kernel/debug/cxl/mbox/raw_allow_all 2>/dev/null
	diag "device $MEM at $BDF, kernel $(uname -r)"
}

# The memdev is recreated, likely under a new name, on every rebind.
refind() {
	local i
	for i in $(seq 50); do
		MEM=$(ls "$PDEV" 2>/dev/null | grep -m1 '^mem[0-9]')
		[ -n "$MEM" ] && [ -e "/dev/cxl/$MEM" ] && break
		sleep 0.1
	done
	MEMDIR=/sys/bus/cxl/devices/$MEM
	[ -n "$MEM" ]
}

# ---------------------------------------------------------------------
g_preflight() {
	local r
	check "mailbox registers readable" $MBOX regs "$MEM"

	# CXL 4.0 8.2.9.4.6: Background Operation is set while a command
	# runs in the background. QEMU before "hw/cxl: Use runtime for bg
	# cmd running semantics" (see qemu/) reports it set until the first
	# background command completes; a kernel that trusts the bit then
	# refuses every background command.
	if [ "$(reg sts_bg_op)" != 0 ]; then
		nok "device idle at boot: Background Operation clear"
		# NO_BAIL=1: carry on, to see what the kernel makes of it
		[ -n "$NO_BAIL" ] ||
			bail "QEMU reports a background operation that does not exist; apply qemu/0001-*.patch"
		HAVE_RAW=1
		return
	fi
	ok "device idle at boot: Background Operation clear"

	r=$(raw $OP_IDENTIFY "" 0x43)
	if [ "$(field errno <<<"$r")" = 0 ]; then
		HAVE_RAW=1
		ok "RAW commands available"
	else
		HAVE_RAW=0
		skip "RAW commands available" "$r (CONFIG_CXL_MEM_RAW_COMMANDS?)"
	fi
}

# ---------------------------------------------------------------------
# CXL 4.0 Table 8-206: Background Command Complete Interrupt is a plain
# RW bit in the same register as the doorbell.
g_irq() {
	if [ "$(reg cap_bg_irq)" != 1 ]; then
		skip "background completion interrupt stays enabled" \
		     "device not interrupt capable"
		return
	fi
	ident >/dev/null; ident >/dev/null
	check "background completion interrupt stays enabled across commands" \
		test "$(reg ctrl_bg_irq)" = 1
}

# ---------------------------------------------------------------------
# Transfer FW: a background command the kernel waits for, in slices.
g_fw() {
	local fw=/sys/class/firmware/$MEM blob=/tmp/cxl-bg-fw.bin r t0 ms st

	if [ ! -d "$fw" ]; then
		skip "firmware upload" "no $fw"
		return
	fi
	# two parts of 1920 bytes: INITIATE then END, 2s each
	dd if=/dev/urandom of=$blob bs=128 count=30 status=none
	mark
	( echo 1 > $fw/loading; cat $blob > $fw/data; echo 0 > $fw/loading ) &
	sleep 1

	# the sender sleeps without the mbox_mutex
	r=$(ident)
	ms=$(field ms <<<"$r")
	if [ "$(field errno <<<"$r")" = 0 ] && [ "${ms:-9999}" -lt 500 ]; then
		ok "Identify not held behind a polled Transfer FW (${ms}ms)"
	else
		nok "Identify not held behind a polled Transfer FW ($r)"
	fi
	check "hardware runs Transfer FW in the background" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x201

	if [ "$HAVE_RAW" = 1 ]; then
		r=$(scan $SCAN_SHORT)
		check "userspace background command refused while the kernel polls ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
	fi
	wait

	t0=$(now_ms)
	while st=$(cat $fw/status 2>/dev/null); [ "$st" != idle ]; do
		[ $(( $(now_ms) - t0 )) -gt 30000 ] && break
		sleep 0.2
	done
	check "firmware upload completes (status=$st error='$(cat $fw/error 2>/dev/null)')" \
		test "$st" = idle -a -z "$(cat $fw/error 2>/dev/null)"
	check "no background command timeout" \
		sh -c '! dmesg | grep -q "timeout waiting for background"'
	check "hardware idle after the upload" wait_idle 5
	rm -f $blob
}

# ---------------------------------------------------------------------
# Sanitize: a background command the kernel does not wait for.
g_sanitize() {
	local t0 ms r

	if [ ! -e "$MEMDIR/security/sanitize" ]; then
		skip "sanitize" "not supported"
		return
	fi
	settle
	mark
	t0=$(now_ms)
	if ! echo 1 > "$MEMDIR/security/sanitize"; then
		nok "sanitize starts"
		return
	fi
	ms=$(( $(now_ms) - t0 ))
	check "sanitize returns at once (${ms}ms)" test "$ms" -lt 1500
	check "security state reads sanitize" \
		test "$(cat "$MEMDIR/security/state")" = sanitize
	r=$(health)
	check "Get Health Info allowed during sanitize ($r)" \
		test "$(field errno <<<"$r")" = 0
	r=$(ident)
	check "Identify refused during sanitize ($r)" \
		test "$(field errno <<<"$r")" = EBUSY
	if [ "$HAVE_RAW" = 1 ]; then
		r=$(scan $SCAN_SHORT)
		check "userspace background command cannot evict a sanitize ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
		r=$(raw $OP_ABORT)
		check "userspace Request Abort cannot reach a sanitize either ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
		check "... it was never sent" test "$(since 'Sending command: 0x0005')" = 0
		check "hardware still runs the sanitize" \
			test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4400
	fi

	check "poll(2) on security/state wakes up" wait_state_change 20
	ms=$(( $(now_ms) - t0 ))
	check "security state leaves sanitize" \
		test "$(cat "$MEMDIR/security/state")" != sanitize
	# Hardware takes 8s, plus up to a couple more the first time: QEMU
	# overwrites the backing memory before it signals completion, and
	# has to fault all of it in. The poller looks at 1s and then at
	# 12s, so only the interrupt ends it in between. Timed from the
	# kernel log, the test's own commands above are too slow for that.
	if [ "$(reg cap_bg_irq)" = 1 ]; then
		ms=$(dmesg_since | sed -n 's/^\[ *\([0-9.]*\)\].*operation (0x4400) \(started\|ended\).*/\1 \2/p' |
			awk '$2 == "started" { s = $1 } $2 == "ended" { e = $1 }
			     END { print (s && e) ? int((e - s) * 1000) : 99999 }')
		check "completion delivered by interrupt, not found by the poller (${ms}ms)" \
			test "$ms" -lt 11500
	fi
	r=$(ident)
	check "Identify works again (errno=$(field errno <<<"$r"))" test "$(field errno <<<"$r")" = 0
}

# ---------------------------------------------------------------------
# A background command sent by userspace is never waited for either.
g_user() {
	local r

	[ "$HAVE_RAW" = 1 ] || { skip "userspace background commands" "no RAW"; return; }
	settle
	mark
	r=$(scan $SCAN_LONG)
	check "Scan Media returns Background Command Started ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
	check "... without waiting for it" test "$(field ms <<<"$r")" -lt 500
	check "hardware runs it in the background" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4304
	r=$(ident)
	check "other commands still served (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
	check "hardware completes it" wait_idle 15
	check "completed, not aborted (pct=$(reg bg_pct) rc=$(reg bg_rc))" \
		test "$(reg bg_pct)$(reg bg_rc)" = 1000x0
	sleep 1.3
	check "driver notices the completion" \
		sh -c "dmesg | sed -n '/$MARK/,\$p' | grep -q 'background operation (0x4304) ended'"
}

# ---------------------------------------------------------------------
# CXL 4.0 8.2.10.1.5 Request Abort Background Operation, and who may
# use it on whom.
g_abort() {
	local r

	[ "$HAVE_RAW" = 1 ] || { skip "abort" "no RAW"; return; }
	settle
	mark
	scan $SCAN_LONG >/dev/null
	sleep 0.5
	r=$(scan $SCAN_LONG)
	check "a userspace command evicts a running userspace command ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
	check "... by aborting it" \
		sh -c "dmesg | sed -n '/$MARK/,\$p' | grep -q 'background operation aborted'"
	check "hardware runs the second one" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4304

	if [ -e "$MEMDIR/security/sanitize" ]; then
		sleep 0.5
		mark
		if echo 1 > "$MEMDIR/security/sanitize"; then
			ok "a kernel command evicts a running userspace command"
		else
			nok "a kernel command evicts a running userspace command"
		fi
		check "hardware runs the sanitize" \
			test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4400
		check "sanitize completes" wait_state_change 20
	fi
	settle

	# Media Operations cannot be aborted on QEMU: neither userspace
	# nor the kernel gets past it, and the device says why with a
	# return code past the end of what the driver's table once held.
	mark
	r=$(media_zero)
	if [ "$(field errno <<<"$r")$(field retval <<<"$r")" != 00x1 ]; then
		skip "non-abortable operation" "Media Operations: $r"
		return
	fi
	ok "Media Operations starts in the background"
	r=$(scan $SCAN_SHORT)
	check "userspace cannot evict a non-abortable operation ($r)" \
		test "$(field errno <<<"$r")" = EBUSY
	if [ -e "$MEMDIR/security/sanitize" ]; then
		if echo 1 > "$MEMDIR/security/sanitize" 2>/dev/null; then
			nok "the kernel cannot evict a non-abortable operation"
		else
			ok "the kernel cannot evict a non-abortable operation"
		fi
		check "... and does not believe it started a sanitize" \
			test "$(cat "$MEMDIR/security/state")" != sanitize
	fi
	check "the refusal is decoded (return code 0x20)" \
		sh -c "dmesg | sed -n '/$MARK/,\$p' | grep -q 'does not support abort'"
	check "hardware still runs the Media Operation" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4402
	check "... to completion" wait_idle 10
	sleep 1.3
	r=$(scan $SCAN_SHORT)
	check "background commands accepted again ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
}

# ---------------------------------------------------------------------
# Hardware done, driver yet to notice: the next background command has
# to clean up after the previous one, with the poller about to run or
# already waiting for the mailbox.
g_backtoback() {
	local i r bad=0

	[ "$HAVE_RAW" = 1 ] || { skip "back to back" "no RAW"; return; }
	settle
	for i in $(seq 40); do
		r=$(scan $SCAN_SHORT)
		[ "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1 ] ||
			{ bad=$((bad+1)); diag "iteration $i: $r"; }
		# sweep the gap across the poller's one second mark
		sleep "0.$(printf '%02d' $(( (i * 7) % 100 )))"
		[ $((i % 4)) = 0 ] && sleep 0.9
	done
	check "40 one-millisecond operations back to back, none refused" \
		test "$bad" = 0
	settle 5
	check "driver and hardware agree the device is idle" \
		test "$(reg sts_bg_op)" = 0
}

# ---------------------------------------------------------------------
# The same, aimed: background commands back to back from two threads
# while two more keep the mailbox busy, so that the poller, kicked by
# the completion interrupt, runs into a held mbox_mutex. The next
# background command then ends the operation with the poller blocked,
# and must not wait for it.
g_cancelrace() {
	local secs=${RACE_SECS:-60} out=/tmp/cxl-bg-hammer.out i

	[ "$HAVE_RAW" = 1 ] || { skip "cancel race" "no RAW"; return; }
	settle
	rm -f $out
	# detached: if the mailbox deadlocks, its threads never return
	setsid $MBOX race "$MEM" "$secs" > $out 2>&1 < /dev/null &
	for i in $(seq $((secs + 30))); do
		grep -q '^\(done\|hung\)' $out 2>/dev/null && break
		sleep 1
	done
	if grep -q '^done' $out; then
		ok "no command hangs ending an operation under the poller ($(cat $out))"
	else
		nok "no command hangs ending an operation under the poller ($(cat $out))"
		bail "mailbox deadlocked"
	fi
}

# ---------------------------------------------------------------------
# The driver goes away with an operation in flight, and comes back to
# a device that is still running it.
g_unbind() {
	local r

	[ "$HAVE_RAW" = 1 ] || { skip "unbind" "no RAW"; return; }
	settle
	scan $SCAN_LONG >/dev/null
	sleep 0.3
	echo "$BDF" > /sys/bus/pci/drivers/cxl_pci/unbind
	check "driver unbinds with an operation in flight" \
		test ! -e "$PDEV/driver"
	sleep 1.5		# the poller's first deadline passes unbound
	echo "$BDF" > /sys/bus/pci/drivers/cxl_pci/bind
	if ! refind; then
		nok "driver rebinds"
		bail "no memdev after rebind"
	fi
	ok "driver rebinds ($MEM)"
	echo 1 > /sys/kernel/debug/cxl/mbox/raw_allow_all
	check "hardware still runs the operation it was left with" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4304
	r=$(ident)
	check "commands served by the new instance (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
	if [ -e "$MEMDIR/security/sanitize" ]; then
		if echo 1 > "$MEMDIR/security/sanitize" 2>/dev/null; then
			nok "an operation the driver did not start is not evicted"
		else
			ok "an operation the driver did not start is not evicted"
		fi
	fi
	check "hardware completes it" wait_idle 15
	r=$(scan $SCAN_SHORT)
	check "background commands accepted afterwards ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
}

# ---------------------------------------------------------------------
g_stress() {
	local secs=${STRESS_SECS:-30} end r fw=/sys/class/firmware/$MEM
	local out=/tmp/cxl-bg-stress

	[ "$HAVE_RAW" = 1 ] || { skip "stress" "no RAW"; return; }
	settle
	rm -rf $out; mkdir -p $out
	end=$(( $(date +%s) + secs ))
	dd if=/dev/urandom of=$out/fw.bin bs=128 count=30 status=none

	# anything but success or busy is a finding
	( while [ "$(date +%s)" -lt $end ]; do
		health | grep -v 'errno=\(0\|EBUSY\) ' >> $out/health.bad
	  done ) &
	( while [ "$(date +%s)" -lt $end ]; do
		ident | grep -v 'errno=\(0\|EBUSY\) ' >> $out/ident.bad
	  done ) &
	( i=0; while [ "$(date +%s)" -lt $end ]; do
		i=$((i+1))
		scan $(( (1 + RANDOM % 4096) * 65536 )) |
			grep -v 'errno=\(0\|EBUSY\) ' >> $out/scan.bad
		sleep "0.$(printf '%02d' $((RANDOM % 100)))"
	  done ) &
	( while [ "$(date +%s)" -lt $end ]; do
		media_zero | grep -v 'errno=\(0\|EBUSY\) ' >> $out/media.bad
		sleep "$((RANDOM % 3)).$((RANDOM % 10))"
	  done ) &
	( while [ "$(date +%s)" -lt $end ]; do
		echo 1 > "$MEMDIR/security/sanitize" 2>/dev/null
		sleep "$((2 + RANDOM % 4))"
	  done ) &
	( while [ "$(date +%s)" -lt $end ] && [ -d $fw ]; do
		{ echo 1 > $fw/loading; cat $out/fw.bin > $fw/data
		  echo 0 > $fw/loading; } 2>/dev/null
		sleep "$((1 + RANDOM % 3))"
	  done ) &
	wait

	check "${secs}s of mixed commands: nothing but success or busy" \
		sh -c "! cat $out/*.bad 2>/dev/null | grep -q ."
	cat $out/*.bad 2>/dev/null | head -5 | sed 's/^/# /'
	[ -d $fw ] && echo 1 > $fw/cancel 2>/dev/null
	check "hardware goes idle" wait_idle 40
	sleep 1.5
	check "security state not stuck in sanitize" \
		sh -c "sleep 12; test \"\$(cat $MEMDIR/security/state)\" != sanitize"
	r=$(scan $SCAN_SHORT)
	check "background commands accepted afterwards ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
	r=$(ident)
	check "plain commands accepted afterwards (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
}

# ---------------------------------------------------------------------
# One background slot per device, not per driver.
g_pair() {
	local a=$MEM b r

	b=$(ls /sys/bus/cxl/devices | grep '^mem[0-9]' | grep -v "^$a\$" | head -1)
	[ "$HAVE_RAW" = 1 ] && [ -n "$b" ] ||
		{ skip "two devices" "needs RAW and a second memdev"; return; }
	settle
	scan $SCAN_LONG >/dev/null
	MEM=$b
	check "second device idle while the first is busy" \
		test "$(reg sts_bg_op)" = 0
	r=$(scan $SCAN_LONG)
	check "second device starts its own operation ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
	sleep 0.5
	r=$(scan $SCAN_LONG)		# evicts the one on the second device
	check "evicting on the second device ($r)" \
		test "$(field errno <<<"$r")$(field retval <<<"$r")" = 00x1
	MEM=$a
	check "... leaves the first one running, unaborted" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4304
	check "first device completes (pct=$(reg bg_pct))" wait_idle 15
	check "first device was not aborted (rc=$(reg bg_rc) pct=$(reg bg_pct))" \
		test "$(reg bg_pct)$(reg bg_rc)" = 1000x0
	MEM=$b
	check "second device completes" wait_idle 15
	MEM=$a
}

# ---------------------------------------------------------------------
# CXL 4.0 8.2.10.1.5: "If the background operation is interrupted, the
# Success return code shall be returned, the Percentage Complete field
# [...] shall indicate a value smaller than 100, and the Background
# Operation bit shall be cleared". Table 8-210 then has Aborted for its
# return code. Userspace asks for the abort itself here, so that nothing
# overwrites the register before it is read; the driver, which was not
# told, has to find out from hardware.
g_rawabort() {
	local r

	[ "$HAVE_RAW" = 1 ] || { skip "Request Abort from userspace" "no RAW"; return; }
	settle
	mark
	scan $SCAN_LONG >/dev/null
	sleep 1.5
	r=$(raw $OP_ABORT)
	check "Request Abort Background Operation succeeds ($r)" test "$(er "$r")" = 00x0
	snap
	check "Background Operation cleared, opcode kept ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)" = 00x4304
	check "Percentage Complete below 100 ($(sf bg_pct))" test "$(sf bg_pct)" -lt 100
	check "return code is Aborted ($(sf bg_rc))" test "$(sf bg_rc)" = 0x12
	r=$(scan $SCAN_LONG)
	check "the next background command starts ($r)" test "$(er "$r")" = 00x1
	check "... the driver let go of the one it lost, aborting nothing" \
		test "$(since '(0x4304) started')/$(since '(0x4304) ended')/$(since 'background operation aborted')/$(since 'Sending command: 0x0005')" = 2/1/0/1

	# the same request against an operation that cannot be aborted
	settle
	r=$(media_zero)
	if [ "$(er "$r")" != 00x1 ]; then
		skip "Request Abort against a non-abortable operation" "Media Operations: $r"
		return
	fi
	r=$(raw $OP_ABORT)
	check "Request Abort Not Supported by Background Operation ($r)" \
		test "$(er "$r")" = 00x20
	check "the operation runs on" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4402
	check "... to completion" wait_idle 10
	snap
	check "completed, not aborted (pct=$(sf bg_pct) rc=$(sf bg_rc))" \
		test "$(sf bg_pct)$(sf bg_rc)" = 1000x0
}

# ---------------------------------------------------------------------
# 8.2.10.1.5: "the device may choose to interrupt the ongoing background
# operation or may choose to continue its execution until completion".
# QEMU continues once the operation is 85% done, and still answers
# Success: the driver must not take Success for "aborted".
g_abortdeclined() {
	local r try pct last ok=0 mono=1 t0 bytes=902400000	# 85% at 6s, done at 8s

	[ "$HAVE_RAW" = 1 ] || { skip "abort declined" "no RAW"; return; }
	for try in 1 2 3; do
		settle
		mark
		scan $bytes >/dev/null
		last=0; t0=$(now_ms)
		while [ $(( $(now_ms) - t0 )) -lt 12000 ]; do
			snap
			pct=$(sf bg_pct)
			[ "$(sf sts_bg_op)" = 1 ] || break
			[ "$pct" -lt "$last" ] && mono=0
			last=$pct
			[ "$pct" -ge 85 ] && break
			sleep 0.05
		done
		r=$(scan $SCAN_SHORT)
		snap
		# still running after the attempt: it was made in time
		[ "$(sf sts_bg_op)$(sf bg_opcode)" = 10x4304 ] && [ "$last" -ge 85 ] &&
			[ "$(er "$r")" != 00x1 ] && { ok=1; break; }
		diag "try $try: missed the window (pct=$last, $r)"
	done
	if [ $ok = 0 ]; then
		skip "abort declined" "operation never caught between 85% and done"
		return
	fi
	check "Percentage Complete never went backwards" test $mono = 1
	check "eviction refused once hardware declines to abort, at ${last}% ($r)" \
		test "$(field errno <<<"$r")" = EBUSY
	check "... the driver did ask, and did not take Success for an abort" \
		test "$(since 'Sending command: 0x0005')/$(since 'background operation aborted')" = 1/0
	if [ -e "$MEMDIR/security/sanitize" ]; then
		if echo 1 > "$MEMDIR/security/sanitize" 2>/dev/null; then
			nok "the kernel's sanitize is refused the same way"
		else
			ok "the kernel's sanitize is refused the same way"
		fi
		check "... and does not believe it started" \
			test "$(cat "$MEMDIR/security/state")" != sanitize
	fi
	check "the operation completes" wait_idle 10
	snap
	check "completed, not aborted (pct=$(sf bg_pct) rc=$(sf bg_rc))" \
		test "$(sf bg_pct)$(sf bg_rc)" = 1000x0
	sleep 1.3
	check "the driver ends it once, when it completes" \
		test "$(since '(0x4304) started')/$(since '(0x4304) ended')" = 1/1
	r=$(scan $SCAN_SHORT)
	check "background commands accepted again ($r)" test "$(er "$r")" = 00x1
}

# ---------------------------------------------------------------------
# The running operation is evicted before the device has seen the
# command that evicts it. If the device then turns that command down,
# nothing runs, and the driver has to agree with that.
g_evictfail() {
	local r

	[ "$HAVE_RAW" = 1 ] || { skip "eviction by a refused command" "no RAW"; return; }
	settle
	mark
	scan $SCAN_LONG >/dev/null
	sleep 1.5
	# Scan Media from an address that is not 64 byte aligned
	r=$(raw $OP_SCAN_MEDIA "$(le64 32)$(le64 1)01")
	check "device refuses the evicting command: Invalid Input ($r)" \
		test "$(er "$r")" = 00x2
	snap
	check "nothing runs: the evicted operation reads Aborted ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_rc)" = 00x43040x12
	check "the driver tracks nothing either" \
		test "$(since '(0x4304) started')/$(since 'background operation aborted')/$(since '(0x4304) ended')" = 1/1/1
	r=$(scan $SCAN_SHORT)
	check "background commands accepted ($r)" test "$(er "$r")" = 00x1
}

# ---------------------------------------------------------------------
# Table 8-209: "additional background commands shall be rejected with
# the busy return code". The driver keeps the commands it knows about
# from getting that far; one it does not gate gets the answer from the
# device, and that answer has to reach userspace as it is.
g_devbusy() {
	local r disc=000000000000000000000200	# Media Operations: Discovery

	[ "$HAVE_RAW" = 1 ] || { skip "device busy" "no RAW"; return; }
	settle
	mark
	r=$(raw $OP_MEDIA_OP $disc 16)
	if [ "$(er "$r")" != 00x0 ]; then
		skip "device busy" "Media Operations Discovery: $r"
		return
	fi
	ok "a background capable opcode completes at once when the request is quick"
	check "... and is not tracked as a background operation" \
		test "$(reg sts_bg_op)/$(since '(0x4402) started')" = 0/0
	scan $SCAN_LONG >/dev/null
	sleep 0.5
	r=$(media_zero)
	check "second background command: Busy from the device ($r)" \
		test "$(er "$r")" = 00x6
	r=$(raw $OP_MEDIA_OP $disc 16)
	check "... whatever the request ($r)" test "$(er "$r")" = 00x6
	check "the running operation was not asked to abort" \
		test "$(since 'Sending command: 0x0005')/$(since 'background operation aborted')" = 0/0
	check "... and still runs" test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x4304
	check "... to completion" wait_idle 15
	snap
	check "completed, not aborted (pct=$(sf bg_pct) rc=$(sf bg_rc))" \
		test "$(sf bg_pct)$(sf bg_rc)" = 1000x0
}

# ---------------------------------------------------------------------
# 8.2.10.9.4.1 Get Poison List: bit 2 of the flags is Scan Media in
# Progress. A foreground command that reports on the background one.
g_poison() {
	local r
	pl() { raw $OP_POISON_LIST "$(le64 0)$(le64 $(( (1 << 30) / 64 )))" 32; }
	flags() { field out <<<"$1" | cut -c1-2; }

	[ "$HAVE_RAW" = 1 ] || { skip "poison list" "no RAW"; return; }
	settle
	r=$(pl)
	if [ "$(er "$r")" != 00x0 ]; then
		skip "Scan Media in Progress" "Get Poison List: $r"
		return
	fi
	check "Get Poison List: no scan in progress when idle ($(flags "$r"))" \
		test "$(flags "$r")" = 00
	scan $SCAN_LONG >/dev/null
	sleep 0.5
	r=$(pl)
	check "Scan Media in Progress while it runs ($(flags "$r"))" \
		test "$(er "$r")$(flags "$r")" = 00x004
	check "hardware completes the scan" wait_idle 15
	r=$(pl)
	check "cleared once it completes ($(flags "$r"))" test "$(flags "$r")" = 00
	r=$(raw $OP_SCAN_RESULTS "" 32)
	check "Get Scan Media Results served afterwards ($r)" test "$(er "$r")" = 00x0
	settle
	scan $SCAN_LONG >/dev/null
	sleep 1.5
	raw $OP_ABORT >/dev/null
	r=$(pl)
	check "cleared when the scan is aborted ($(flags "$r"))" \
		test "$(flags "$r")" = 00
	# the driver was not told about that abort: resync it
	scan $SCAN_SHORT >/dev/null
}

# ---------------------------------------------------------------------
# A firmware upload cancelled between two parts: the kernel is waiting
# for one Transfer FW to complete in the background, and has to send
# another, the abort, once it has.
g_fwcancel() {
	local fw=/sys/class/firmware/$MEM blob=/tmp/cxl-bg-fw4.bin t0 ms st

	if [ ! -d "$fw" ]; then
		skip "firmware upload cancel" "no $fw"
		return
	fi
	settle
	mark
	dd if=/dev/urandom of=$blob bs=128 count=60 status=none	# four parts
	t0=$(now_ms)
	( echo 1 > $fw/loading; cat $blob > $fw/data; echo 0 > $fw/loading ) &
	sleep 1
	echo 1 > $fw/cancel
	wait
	while st=$(cat $fw/status 2>/dev/null); [ "$st" != idle ]; do
		[ $(( $(now_ms) - t0 )) -gt 8000 ] && break
		sleep 0.1
	done
	ms=$(( $(now_ms) - t0 ))
	check "cancelled upload ends after the part in flight (${ms}ms, status=$st)" \
		test "$st" = idle -a "$ms" -lt 5000
	check "... as a user abort (error='$(cat $fw/error 2>/dev/null)')" \
		test "$(cat $fw/error 2>/dev/null)" = transferring:user-abort
	snap
	check "the part in flight was let to complete ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_pct)$(sf bg_rc)" = 00x2011000x0
	check "one part went to the background, then the abort" \
		test "$(since '(0x0201) started')/$(since 'Sending command: 0x0201')" = 1/2
	check "no error aborting the transfer" \
		test "$(since 'Error aborting FW transfer')" = 0

	# the device would refuse a new transfer had the abort not reached it
	dd if=/dev/urandom of=$blob bs=128 count=30 status=none
	echo 1 > $fw/loading; cat $blob > $fw/data; echo 0 > $fw/loading
	t0=$(now_ms)
	while st=$(cat $fw/status 2>/dev/null); [ "$st" != idle ]; do
		[ $(( $(now_ms) - t0 )) -gt 15000 ] && break
		sleep 0.2
	done
	check "a new upload goes through (status=$st error='$(cat $fw/error 2>/dev/null)')" \
		test "$st" = idle -a -z "$(cat $fw/error 2>/dev/null)"
	rm -f $blob
}

# ---------------------------------------------------------------------
# Populate Log (0404h), CXL 4.0 8.2.10.5.5: "This may be a background
# operation." QEMU with qemu/0005-*.patch runs it for four seconds on
# the Component State Dump Log and lets it be aborted, and the kernel
# has a uapi command id for it. It is the first, and so far the only,
# background command the suite sends as CXL_MEM_SEND_COMMAND by command
# id rather than RAW: no CONFIG_CXL_MEM_RAW_COMMANDS, no raw_allow_all,
# no taint, and the same asynchronous tracking as the RAW ones get.
#
# The kernel tells userspace that the operation started and nothing
# more: how it ended is in the Background Command Status register,
# which this reads behind the driver's back, and in the log itself.
ID_GET_SUPPORTED_LOGS=3
ID_GET_LOG=8
ID_GET_TIMESTAMP=21
ID_GET_LOG_CAPS=22
ID_POPULATE_LOG=25
UUID_CEL=0da9c0b5bf414b788f7996b1623b3f17
UUID_CSDL=b3fab4cf01b64332943e5e9962f23567
UUID_NONE=5ca1ab1e0000400080000000deadbeef	# not in Table 8-250

poplog()  { $MBOX cmd "$MEM" $ID_POPULATE_LOG "$1"; }
logcaps() { $MBOX cmd "$MEM" $ID_GET_LOG_CAPS "$1" --out 4; }
# getlog <uuid> <offset> <length>
getlog()  { $MBOX cmd "$MEM" $ID_GET_LOG "$1$(le32 "$2")$(le32 "$3")" --out "$3"; }
# ledec <hex>: a little endian field of a payload, in decimal
ledec()   { echo $(( 0x$(fold -w2 <<<"$1" | tac | tr -d '\n') )); }
# wait_since <text> <count> <secs>: until the kernel log has it that often
wait_since() {
	local n=$(($3 * 10))
	while [ $n -gt 0 ]; do
		[ "$(since "$1")" -ge "$2" ] && return 0
		sleep 0.1; n=$((n-1))
	done
	return 1
}
# wait_running <opcode> <secs>: until hardware runs that in the background
wait_running() {
	local n=$(($2 * 10))
	while [ $n -gt 0 ]; do
		snap
		[ "$(sf sts_bg_op)$(sf bg_opcode)" = "1$1" ] && return 0
		sleep 0.1; n=$((n-1))
	done
	return 1
}
# bg_ms <opcode>: from "started" to "ended" in the kernel log, since the mark
bg_ms() {
	dmesg_since | sed -n "s/^\[ *\([0-9.]*\)\].*operation ($1) \(started\|ended\).*/\1 \2/p" |
		awk '$2 == "started" { s = $1 } $2 == "ended" { e = $1 }
		     END { print (s && e) ? int((e - s) * 1000) : 99999 }'
}

# victim: have a Populate Log run that is young enough to be aborted.
# QEMU runs it for four seconds, moves Percentage Complete once a
# second and declines a Request Abort from 85% (0005h: the device "may
# choose to continue its execution until completion"), so past the
# first tick the one that runs is left to complete and another started.
victim() {
	local i r
	for i in 1 2 3; do
		snap
		[ "$(sf sts_bg_op)$(sf bg_opcode)" = 10x404 ] &&
			[ "$(sf bg_pct)" -le 25 ] && return 0
		wait_idle 10
		r=$(poplog $UUID_CSDL)
		[ "$(er "$r")" = 00x1 ] || diag "victim: Populate Log: $r"
	done
	nok "a Populate Log to evict runs, below 25% ($L)"
	return 1
}

g_poplog() {
	local r q n caps size log dlen ts0 ts1 ts ms pat eff cel=0
	local fw=/sys/class/firmware/$MEM blob=/tmp/cxl-bg-fw7.bin

	# What the device has comes from its CEL, what the kernel makes of
	# it from CXL_MEM_QUERY_COMMANDS, so that a kernel which fails to
	# enable the command does not read as a device without it.
	# Table 8-250: Log Size is "the maximum number of bytes of log
	# data available to retrieve"
	r=$($MBOX cmd "$MEM" $ID_GET_SUPPORTED_LOGS "" --out 0x100)
	size=$(field out <<<"$r" | sed -n "s/.*$UUID_CEL\(.\{8\}\).*/\1/p")
	if [ -z "$size" ]; then
		nok "Get Supported Logs has the CEL ($r)"
		return
	fi
	q=$(getlog $UUID_CEL 0 $(ledec "$size"))
	if [ "$(er "$q")" != 00x0 ]; then
		nok "Get Log reads the CEL ($(er "$q"))"
		return
	fi
	# Table 8-254: Opcode, then Command Effect, two bytes each
	eff=$(field out <<<"$q" | fold -w8 | sed -n 's/^0404\(....\)$/\1/p')
	if [ -z "$eff" ]; then
		skip "Populate Log" "not in the CEL of $MEM (qemu/0005-*.patch?)"
		return
	fi
	eff=$(ledec "$eff")
	if ! q=$($MBOX query "$MEM" 2>&1); then
		nok "CXL_MEM_QUERY_COMMANDS ($(tail -1 <<<"$q"))"
		return
	fi
	n=$(field "cmd$ID_POPULATE_LOG" <<<"$q")
	if [ -z "$n" ]; then
		nok "the kernel has a uapi command for Populate Log, which the CEL of $MEM has"
		return
	fi
	# "Bit[6]: Background Operation", "Bit[8]: Request Abort Background
	# Operation Supported"; cxl_walk_cel(): "only enable uapi bgcmds
	# that may be canceled"
	q=$(printf 'effects 0x%04x, flags %s' $eff $n)
	case $(( (eff >> 6) & 1 ))$(( (eff >> 8) & 1 )) in
	11)
		if [ $((n & 1)) = 0 ]; then
			nok "the kernel enables Populate Log by uapi id: the CEL has it as a background command that can be aborted ($q)"
			return
		fi
		ok "the kernel enables Populate Log by uapi id: the CEL has it as a background command that can be aborted ($q)"
		;;
	10)
		check "the kernel leaves a Populate Log that cannot be aborted disabled ($q)" \
			test $((n & 1)) = 0
		skip "Populate Log" "in the background, and not abortable on $MEM"
		return
		;;
	*)
		skip "Populate Log" "not a background command on $MEM ($q)"
		return
		;;
	esac

	size=$(field out <<<"$r" | sed -n "s/.*$UUID_CSDL\(.\{8\}\).*/\1/p")
	if [ -z "$size" ]; then
		skip "Populate Log" "no Component State Dump Log ($r)"
		return
	fi
	size=$(ledec "$size")
	ok "Get Supported Logs has the Component State Dump Log ($size bytes)"

	# Table 8-269, Bit[1]: Populate Log Supported
	r=$(logcaps $UUID_CSDL)
	caps=$(field out <<<"$r")
	if [ "$(er "$r")" != 00x0 ] || [ $(( 0x${caps:0:2} & 2 )) = 0 ]; then
		skip "Populate Log" "Populate Log Supported not set for that log ($r)"
		return
	fi
	ok "Get Log Capabilities: Populate Log Supported for it ($caps)"
	# 8.2.10.5.3: "shall return Invalid Log if the specified Log
	# Identifier is not supported by the component"
	r=$(logcaps $UUID_NONE)
	check "Get Log Capabilities: Invalid Log for a log the device lacks ($r)" \
		test "$(er "$r")" = 00x17
	r=$(logcaps $UUID_CEL)
	[ "$(er "$r")" = 00x0 ] && [ $(( 0x$(field out <<<"$r" | cut -c1-2) & 2 )) = 0 ] && cel=1

	# --- one Populate Log, left alone
	settle
	mark
	ts0=$(ledec "$($MBOX cmd "$MEM" $ID_GET_TIMESTAMP "" --out 8 | field out)")
	r=$(poplog $UUID_CSDL)
	check "Populate Log by uapi id: errno 0, retval Background Command Started ($r)" \
		test "$(er "$r")" = 00x1
	check "... without waiting for it" test "$(field ms <<<"$r")" -lt 500
	snap
	check "hardware runs opcode 0404h in the background ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)" = 10x404
	r=$(ident)
	check "other commands still served (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
	# 8.2.10.5.2.3, Get Log with Offset = 0: "Return Retry Required
	# if the log contents are not fully populated"
	r=$(getlog $UUID_CSDL 0 $size)
	check "Get Log while it populates: Retry Required ($(er "$r"))" \
		test "$(er "$r")" = 00x5
	check "hardware completes it" wait_idle 10
	snap
	check "completed with Success, at 100% ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_pct)$(sf bg_rc)" = 00x4041000x0
	# The driver only prints "ended" for an operation it tracked. The
	# poller looks at one second and at twelve; hardware takes four.
	if [ "$(sf ctrl_bg_irq)" = 1 ]; then
		wait_since '(0x0404) ended' 1 3
		ms=$(bg_ms 0x0404)
		check "the driver tracked it: completion delivered by interrupt (${ms}ms)" \
			test "$ms" -lt 11500
	else
		wait_since '(0x0404) ended' 1 14
		ms=$(bg_ms 0x0404)
		check "the driver tracked it: completion found by the poller, at twelve seconds (${ms}ms)" \
			test "$ms" -ge 11500 -a "$ms" -lt 13500
	fi
	check "started and ended once, nothing aborted" \
		test "$(since '(0x0404) started')/$(since '(0x0404) ended')/$(since 'background operation aborted')/$(since 'Sending command: 0x0005')" = 1/1/0/0
	ts1=$(ledec "$($MBOX cmd "$MEM" $ID_GET_TIMESTAMP "" --out 8 | field out)")
	r=$(ident)
	check "Identify served afterwards (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0

	# Table 8-256: Data Length at 00h, Timestamp at 08h "at the time
	# the Component State Dump Data was generated", Flags at 20h with
	# Bit[0] Auto Populate Data "cleared to 0 if [...] generated
	# using Populate Log", data from 40h and vendor specific: QEMU
	# counts bytes.
	r=$(getlog $UUID_CSDL 0 $size)
	log=$(field out <<<"$r")
	check "Get Log reads the log back ($(er "$r"), $((${#log} / 2)) bytes)" \
		test "$(er "$r")" = 00x0 -a ${#log} = $((size * 2))
	dlen=$(ledec "${log:0:8}")
	check "... Component State Dump Data Length $dlen, Auto Populate Data clear" \
		test "$dlen" -gt 0 -a "$dlen" -le $((size - 64)) -a $(( 0x${log:64:2} & 1 )) = 0
	ts=$(ledec "${log:16:16}")
	check "... Timestamp from while it ran ($ts0 <= $ts <= $ts1)" \
		test "$ts0" -le "$ts" -a "$ts" -le "$ts1"
	pat=$(printf '%02x' $(seq 0 255))
	check "... the data is the pattern QEMU writes" \
		test "${log:128:$((dlen * 2))}" = "${pat:0:$((dlen * 2))}"
	# "Return Success and provide the log contents of the specified
	# offset" once a Get Log with Offset = 0 has succeeded
	r=$(getlog $UUID_CSDL 0x40 16)
	check "... and a fetch sequence carries on from there ($r)" \
		test "$(er "$r")$(field out <<<"$r")" = "00x0${pat:0:32}"

	# --- Populate Log the device turns down: the return code is all
	# userspace gets, and the driver must not track what never began
	mark
	# 8.2.10.5.5: "shall return Invalid Log if the specified Log
	# Identifier is not supported by the component"
	r=$(poplog $UUID_NONE)
	check "Populate Log for a log the device lacks: retval Invalid Log ($r)" \
		test "$(er "$r")" = 00x17
	# "shall return Invalid Input if the specified Log Identifier
	# does not have the Populate Log Supported bit set to 1"
	if [ $cel = 1 ]; then
		r=$(poplog $UUID_CEL)
		check "Populate Log for the CEL, which has no Populate Log Supported: retval Invalid Input ($r)" \
			test "$(er "$r")" = 00x2
	else
		skip "Populate Log for the CEL" "the CEL claims Populate Log Supported"
	fi
	check "the device saw them, nothing started" \
		test "$(since 'Sending command: 0x0404')/$(reg sts_bg_op)/$(since '(0x0404) started')" = $((1 + cel))/0/0
	r=$(poplog $UUID_CSDL)
	check "the next Populate Log starts ($r)" test "$(er "$r")" = 00x1
	check "... with nothing left behind for it to end or abort" \
		test "$(since '(0x0404) started')/$(since '(0x0404) ended')/$(since 'Sending command: 0x0005')" = 1/0/0
	# 8.2.10.5.2.3, nonzero Offset: "Return Interrupted if the
	# contents of the Component State Dump Log have changed since
	# the last time the component returned Success for a Get Log
	# command with Offset = 0"; they are cleared before populating
	r=$(getlog $UUID_CSDL 0x40 16)
	check "the fetch sequence of before is told so: Interrupted ($(er "$r"))" \
		test "$(er "$r")" = 00x18

	# --- cxl_try_to_cancel_background(): "incoming user bgcmd ->
	# abort on-going user bgcmd". From here on Populate Log is told
	# apart from any other command by what cxl_is_background_cmd()
	# makes of it: what came before only took the uapi command and
	# the tracking of a userspace background command.
	victim || return
	mark
	r=$(poplog $UUID_CSDL)
	check "a second Populate Log evicts the one that runs ($r)" \
		test "$(er "$r")" = 00x1
	check "... by aborting it: Request Abort, ended, started anew" \
		test "$(since 'Sending command: 0x0005')/$(since 'background operation aborted')/$(since '(0x0404) ended')/$(since '(0x0404) started')" = 1/1/1/1
	check "hardware runs the second one" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x404
	if [ "$HAVE_RAW" = 1 ]; then
		victim || return
		r=$(scan $SCAN_LONG)
		check "a RAW Scan Media evicts a Populate Log ($r)" \
			test "$(er "$r")$(reg sts_bg_op)$(reg bg_opcode)" = 00x110x4304
		r=$(poplog $UUID_CSDL)
		check "a Populate Log evicts a RAW Scan Media ($r)" \
			test "$(er "$r")$(reg sts_bg_op)$(reg bg_opcode)" = 00x110x404
	fi

	# The eviction comes before the device has seen the command that
	# evicts: one it refuses leaves the abort in the register for
	# once. 8.2.10.1.5: "the Percentage Complete field [...] shall
	# indicate a value smaller than 100, and the Background Operation
	# bit shall be cleared"; Table 8-208 has Aborted (0012h) for the
	# code, reported in the Return Code field of Table 8-210.
	# That a refused command has already cost the running one its
	# life is how the kernel orders things today, not something the
	# spec asks for: this goes with cxl_pci_mbox_send().
	if [ $cel = 1 ]; then
		victim || return
		mark
		r=$(poplog $UUID_CEL)
		check "an evicting Populate Log the device refuses: Invalid Input ($r)" \
			test "$(er "$r")" = 00x2
		snap
		check "nothing runs: the evicted one reads Aborted, below 100% ($L)" \
			test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_rc)" = 00x4040x12 -a "$(sf bg_pct)" -lt 100
		check "the driver tracks nothing either" \
			test "$(since 'background operation aborted')/$(since '(0x0404) ended')/$(since '(0x0404) started')" = 1/1/0
		r=$(poplog $UUID_CSDL)
		check "Populate Log accepted again ($r)" test "$(er "$r")" = 00x1
	fi

	# --- "incoming kernel bgcmd -> abort on-going user bgcmd", and
	# not the other way around: a Transfer FW the kernel waits for
	if [ -d "$fw" ]; then
		dd if=/dev/urandom of=$blob bs=128 count=30 status=none
		victim || return
		mark
		fw_upload $blob
		check "a firmware upload evicts a Populate Log: hardware runs Transfer FW" \
			wait_running 0x201 3
		check "... the kernel aborted it" \
			test "$(since 'Sending command: 0x0005')/$(since 'background operation aborted')/$(since '(0x0404) ended')" = 1/1/1
		r=$(poplog $UUID_CSDL)
		check "Populate Log refused while the kernel polls for Transfer FW ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
		check "... it was never sent" test "$(since 'Sending command: 0x0404')" = 0
		fw_idle 20
		check "the upload completes (status=$(cat $fw/status) error='$(cat $fw/error 2>/dev/null)')" \
			test "$(cat $fw/status)" = idle -a -z "$(cat $fw/error 2>/dev/null)"
		rm -f $blob
	fi
	# ... and a sanitize the kernel does not wait for
	if [ -e "$MEMDIR/security/sanitize" ]; then
		settle
		victim || return
		mark
		if echo 1 > "$MEMDIR/security/sanitize"; then
			ok "the kernel's sanitize evicts a Populate Log"
		else
			nok "the kernel's sanitize evicts a Populate Log"
		fi
		check "... by aborting it, hardware runs the sanitize" \
			test "$(since 'background operation aborted')/$(reg sts_bg_op)$(reg bg_opcode)" = 1/10x4400
		r=$(poplog $UUID_CSDL)
		check "Populate Log cannot evict a sanitize ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
		check "... it was never sent" test "$(since 'Sending command: 0x0404')" = 0
		check "sanitize completes" wait_state_change 20
	fi

	# --- and after all of that
	settle
	mark
	r=$(poplog $UUID_CSDL)
	check "Populate Log starts again ($r)" test "$(er "$r")" = 00x1
	check "... and completes" wait_idle 10
	snap
	check "... with Success, at 100% ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_pct)$(sf bg_rc)" = 00x4041000x0
	# leave with the driver idle too: without the interrupt that
	# takes until the poller's second look
	if [ "$(sf ctrl_bg_irq)" = 1 ]; then
		wait_since '(0x0404) ended' 1 3
	else
		wait_since '(0x0404) ended' 1 14
	fi
	check "... and the driver is done with it: started and ended once, nothing aborted" \
		test "$(since '(0x0404) started')/$(since '(0x0404) ended')/$(since 'background operation aborted')" = 1/1/0
	r=$(getlog $UUID_CSDL 0 $size)
	check "... the log is populated ($(er "$r"), Data Length $(ledec "$(field out <<<"$r" | cut -c1-8)"))" \
		test "$(er "$r")" = 00x0 -a "$(ledec "$(field out <<<"$r" | cut -c1-8)")" -gt 0
}

# ---------------------------------------------------------------------
# No interrupt at all (pci=nomsi): completion is something the driver
# has to go and look for. The poller looks one second after the command
# and then eleven seconds later.
g_noirq() {
	local r t0 ms

	snap
	if [ "$(sf cap_bg_irq)$(sf ctrl_bg_irq)" != 10 ]; then
		skip "polled completion" "interrupt in use (boot with pci=nomsi)"
		return
	fi
	ok "device is interrupt capable, the driver did not enable it"
	[ "$HAVE_RAW" = 1 ] || { skip "polled completion" "no RAW"; return; }

	settle; sleep 12
	mark
	scan $SCAN_LONG >/dev/null	# 6.3s: done between the two looks
	check "hardware completes the operation" wait_idle 10
	sleep 0.5
	check "the driver has not looked yet" test "$(since '(0x4304) ended')" = 0
	r=$(ident)
	check "plain commands served meanwhile (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
	r=$(scan $SCAN_SHORT)
	check "the next background command does the poller's work ($r)" \
		test "$(er "$r")" = 00x1
	check "... ending the finished one, aborting nothing" \
		test "$(since '(0x4304) started')/$(since '(0x4304) ended')/$(since 'background operation aborted')" = 2/1/0
	sleep 13
	check "the poller ends the last one by itself" \
		test "$(since '(0x4304) ended')" = 2

	if [ ! -e "$MEMDIR/security/sanitize" ]; then
		skip "polled sanitize" "not supported"
		return
	fi
	mark
	t0=$(now_ms)
	echo 1 > "$MEMDIR/security/sanitize" || { nok "sanitize starts"; return; }
	wait_idle 11
	if [ $(( $(now_ms) - t0 )) -lt 11000 ]; then
		check "hardware done, driver yet to look: state still reads sanitize" \
			test "$(cat "$MEMDIR/security/state")" = sanitize
		r=$(ident)
		check "... and Identify is still refused ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
	else
		skip "window between hardware and poller" "sanitize took too long"
	fi
	check "poll(2) on security/state wakes up at the poller's next look" \
		wait_state_change 8
	ms=$(dmesg_since | sed -n 's/^\[ *\([0-9.]*\)\].*operation (0x4400) \(started\|ended\).*/\1 \2/p' |
		awk '$2 == "started" { s = $1 } $2 == "ended" { e = $1 }
		     END { print (s && e) ? int((e - s) * 1000) : 99999 }')
	check "completion found by the poller, at twelve seconds (${ms}ms)" \
		test "$ms" -ge 11500 -a "$ms" -lt 13500
	r=$(ident)
	check "Identify works again (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
}

# ---------------------------------------------------------------------
# NOT RUN BY DEFAULT: a reproducer, expected to fail on a driver that
# only gates the background commands it has a name for.
#
# Hardware idle, driver still tracking the operation that was there (an
# abort raises no interrupt, so that lasts until the poller's next
# look). A background capable command the driver does not know as one,
# Media Operations here, is then sent without the clean up the known
# ones get: the device starts it, the driver finds its slot taken, WARNs
# and returns EBUSY for an operation that is running.
g_staleuntracked() {
	local r

	[ "$HAVE_RAW" = 1 ] || { skip "stale untracked" "no RAW"; return; }
	settle
	mark
	scan $SCAN_LONG >/dev/null
	sleep 1.5
	raw $OP_ABORT >/dev/null
	r=$(media_zero)
	snap
	check "device started the Media Operation ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)" = 10x4402
	check "... and userspace is told so ($r)" test "$(er "$r")" = 00x1
	check "... without a warning" \
		sh -c "! dmesg | sed -n '/$MARK/,\$p' | grep -q 'WARNING:.*__cxl_pci_mbox_send_cmd'"
	wait_idle 10
	sleep 13
	r=$(scan $SCAN_SHORT)
	check "background commands accepted afterwards ($r)" test "$(er "$r")" = 00x1
}

# ---------------------------------------------------------------------
# Activate FW in the background (topology t5, QEMU with qemu/0002-*):
# the kernel does not wait for it with the mailbox, the firmware upload
# does, and reports what the Background Command Status register says
# once it is over. The first device by BDF activates, the second fails
# with "Activation Failed, FW Rolled Back".
#
# fw_upload <blob>: start an upload on $MEM, return once it is written
fw_upload() {
	local fw=/sys/class/firmware/$MEM
	echo 1 > $fw/loading; cat "$1" > $fw/data; echo 0 > $fw/loading
}
# fw_idle <secs>: wait for the upload on $MEM to end
fw_idle() {
	local t0=$(now_ms)
	while [ "$(cat /sys/class/firmware/$MEM/status 2>/dev/null)" != idle ]; do
		[ $(( $(now_ms) - t0 )) -gt $(($1 * 1000)) ] && return 1
		sleep 0.1
	done
}
# wait_activating <secs>: until hardware runs Activate FW
wait_activating() {
	local n=$(($1 * 10))
	while [ $n -gt 0 ]; do
		[ "$(reg sts_bg_op)$(reg bg_opcode)" = 10x202 ] && return 0
		sleep 0.1; n=$((n-1))
	done
	return 1
}
dev_since() { dmesg_since | grep -F -- "$BDF" | grep -cF -- "$1"; }

g_actfw() {
	local a=$MEM good bad m fw blob=/tmp/cxl-bg-fw5.bin r st t0 ms

	set -- $(for m in $(ls /sys/bus/cxl/devices | grep '^mem[0-9]'); do
		echo "$(basename "$(dirname "$(readlink -f /sys/bus/cxl/devices/$m)")") $m"
	  done | sort | awk '{print $2}')
	good=$1 bad=$2
	if [ -z "$bad" ] || [ ! -d /sys/class/firmware/$good ]; then
		skip "background Activate FW" "needs two memdevs with firmware upload"
		return
	fi
	dd if=/dev/urandom of=$blob bs=128 count=30 status=none

	# --- activation that succeeds
	MEM=$good; MEMDIR=/sys/bus/cxl/devices/$MEM
	BDF=$(basename "$(dirname "$(readlink -f "$MEMDIR")")")
	fw=/sys/class/firmware/$MEM
	settle
	mark
	fw_upload $blob
	if ! wait_activating 15; then
		skip "background Activate FW" "Activate FW did not go to the background (qemu/0002-*.patch?)"
		fw_idle 20; MEM=$a; MEMDIR=/sys/bus/cxl/devices/$MEM
		BDF=$(basename "$(dirname "$(readlink -f "$MEMDIR")")")
		return
	fi
	ok "Activate FW runs in the background"
	sleep 1.5
	check "the upload waits for it (status=$(cat $fw/status))" \
		test "$(cat $fw/status)" = programming
	r=$(ident)
	check "other commands are served meanwhile ($(field errno <<<"$r"), $(field ms <<<"$r")ms)" \
		test "$(field errno <<<"$r")" = 0 -a "$(field ms <<<"$r")" -lt 500
	if [ "$HAVE_RAW" = 1 ]; then
		r=$(scan $SCAN_SHORT)
		check "a userspace background command cannot evict it ($r)" \
			test "$(field errno <<<"$r")" = EBUSY
	fi
	check "the upload ends" fw_idle 20
	snap
	check "... once hardware is done ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_pct)$(sf bg_rc)" = 00x2021000x0
	check "... without an error (error='$(cat $fw/error)')" \
		test -z "$(cat $fw/error)"
	check "started and ended once" \
		test "$(dev_since '(0x0202) started')/$(dev_since '(0x0202) ended')" = 1/1

	# --- activation that fails
	MEM=$bad; MEMDIR=/sys/bus/cxl/devices/$MEM
	BDF=$(basename "$(dirname "$(readlink -f "$MEMDIR")")")
	fw=/sys/class/firmware/$MEM
	settle
	mark
	fw_upload $blob
	check "second device: Activate FW runs in the background" wait_activating 15
	check "the upload ends" fw_idle 20
	snap
	check "hardware says the activation failed ($L)" \
		test "$(sf sts_bg_op)$(sf bg_opcode)$(sf bg_rc)" = 00x2020xc
	check "... and so does the upload (error='$(cat $fw/error)')" \
		test "$(cat $fw/error)" = programming:hw-error
	check "... and the kernel log" \
		test "$(since "$MEM: Error activating firmware")" = 1
	MEM=$good
	check "the first device is not told of it (error='$(cat /sys/class/firmware/$good/error)')" \
		test -z "$(cat /sys/class/firmware/$good/error)"
	MEM=$bad
	fw_upload $blob
	check "a new upload on the failed device starts its own activation" \
		wait_activating 15
	fw_idle 20

	# --- the driver goes away while the upload waits
	MEM=$good; MEMDIR=/sys/bus/cxl/devices/$MEM
	PDEV=$(dirname "$(readlink -f "$MEMDIR")"); BDF=$(basename "$PDEV")
	settle
	mark
	fw_upload $blob
	if wait_activating 15; then
		sleep 1
		t0=$(now_ms)
		echo "$BDF" > /sys/bus/pci/drivers/cxl_pci/unbind
		ms=$(( $(now_ms) - t0 ))
		check "unbind does not wait for the activation (${ms}ms)" \
			test ! -e "$PDEV/driver" -a "$ms" -lt 3000
		check "... nor try to abort a transfer that is over" \
			test "$(since 'Error aborting FW transfer')" = 0
		sleep 0.5
		echo "$BDF" > /sys/bus/pci/drivers/cxl_pci/bind
		if refind; then
			ok "driver rebinds ($MEM)"
			echo 1 > /sys/kernel/debug/cxl/mbox/raw_allow_all
			check "hardware finishes the activation it was left with" wait_idle 10
			r=$(ident)
			check "commands served by the new instance (errno=$(field errno <<<"$r"))" \
				test "$(field errno <<<"$r")" = 0
		else
			nok "driver rebinds"
		fi
	else
		nok "third upload reaches the activation"
	fi
	rm -f $blob
}

# NOT RUN BY DEFAULT, it takes five and a half minutes: the third device
# of t5 needs longer to activate than the upload waits (5 minutes).
g_actfwtmo() {
	local m slow fw blob=/tmp/cxl-bg-fw6.bin t0 ms r

	set -- $(for m in $(ls /sys/bus/cxl/devices | grep '^mem[0-9]'); do
		echo "$(basename "$(dirname "$(readlink -f /sys/bus/cxl/devices/$m)")") $m"
	  done | sort | awk '{print $2}')
	slow=$3
	[ -n "$slow" ] || { skip "Activate FW timeout" "needs the third device of t5"; return; }
	MEM=$slow; MEMDIR=/sys/bus/cxl/devices/$MEM
	BDF=$(basename "$(dirname "$(readlink -f "$MEMDIR")")")
	fw=/sys/class/firmware/$MEM
	dd if=/dev/urandom of=$blob bs=128 count=30 status=none
	settle
	mark
	fw_upload $blob
	if ! wait_activating 15; then
		skip "Activate FW timeout" "Activate FW did not go to the background"
		return
	fi
	t0=$(now_ms)
	check "the upload gives up" fw_idle 320
	ms=$(( $(now_ms) - t0 ))
	check "... after the timeout (${ms}ms)" test "$ms" -gt 295000
	check "... saying so (error='$(cat $fw/error)')" \
		test "$(cat $fw/error)" = programming:timeout
	check "hardware is still at it ($(reg sts_bg_op)$(reg bg_opcode))" \
		test "$(reg sts_bg_op)$(reg bg_opcode)" = 10x202
	r=$(ident)
	check "commands are served (errno=$(field errno <<<"$r"))" \
		test "$(field errno <<<"$r")" = 0
	check "the activation completes" wait_idle 40
	sleep 13
	fw_upload $blob
	check "the next upload starts its own activation" wait_activating 15
	rm -f $blob
}

# ---------------------------------------------------------------------
# Several devices, several users on each: see multi.py.
multi() {
	local line
	while IFS= read -r line; do
		case "$line" in
		PASS\ *) ok "${line#PASS }" ;;
		FAIL\ *) nok "${line#FAIL }" ;;
		SKIP\ *) skip "${line#SKIP }" "see description" ;;
		*) diag "$line" ;;
		esac
	done < <(STRESS_SECS=${STRESS_SECS:-30} python3 "$D/multi.py" "$1" 2>&1)
}
g_quadfw()       { multi fw; }
g_quadmatrix()   { multi matrix; }
g_quadbarrage()  { multi barrage; }
g_quadsanitize() { multi sanitize; }
g_quadunbind()   { multi unbind; }
g_quadroles()    { multi roles; }

GROUPS_ALL="irq fw fwcancel sanitize user abort rawabort abortdeclined evictfail devbusy poison poplog backtoback cancelrace unbind stress"
setup
g_preflight
for g in ${*:-$GROUPS_ALL}; do
	diag "--- $g"
	"g_$g"
done
echo "1..$T"
echo "# passed: $PASS  failed: $FAIL"
exit $((FAIL != 0))

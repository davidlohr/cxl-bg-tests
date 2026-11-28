# CXL mailbox background command test suite

Boots QEMU with a few CXL Type 3 topologies and runs an in-guest TAP
driver against the kernel's handling of mailbox background commands
(CXL 4.0 8.2.9.4): the commands the kernel polls for itself (Transfer
FW), the ones it tracks asynchronously (Sanitize, Activate FW), the ones
userspace may start and the kernel may abort (Request Abort Background
Operation, 0005h), the completion interrupt and the poller that stands
in for it, and all of it with several users on several devices at once.

Kernel side is the CXL mailbox background command series for
`drivers/cxl` (asynchronous Activate FW, lockless synchronous polling,
userspace background commands, Populate Log).
Structure and style follow davidlohr/cxl-bi-tests and
davidlohr/uio-tests.

## QEMU

QEMU needs the patches under `qemu/`:

- `0001-hw-cxl-Use-runtime-for-bg-cmd-running-semantics.patch`: without
  it the device reports a background operation in progress from boot
  until the first one completes, and the preflight check bails out.
- `0002-hw-cxl-testing-aid-Activate-FW-in-the-background.patch`: a
  testing aid, not for upstream. Adds `x-fw-activate-ms` and
  `x-fw-activate-fail` to `cxl-type3` so that Activate FW runs in the
  background and can fail. Only t5 needs it, and skips without it.
- `0003-hw-cxl-Fix-CEL-command-effect-bit-positions.patch`: moves the
  CEL's Request Abort Background Operation Supported to bit 8 (CXL 4.0
  Table 8-254), where the kernel looks for it before it enables a
  background command by uapi id; QEMU had it at bit 7, and the bits
  after it off by one.
- `0004-hw-cxl-Set-CEL-11-10-Valid-for-the-FM-DCD-commands.patch`: the
  FM DCD commands report a configuration change after a Conventional
  and a CXL Reset, which only counts with CEL[11:10] Valid set. No
  suite reaches these commands.
- `0005-hw-cxl-Add-Populate-Log-and-Get-Log-Capabilities.patch`: adds
  the Component State Dump Log, Get Log Capabilities (0402h) and
  Populate Log (0404h), a background command that can be aborted.
  Only `poplog` needs it, and skips without it.

## Kernel

`CONFIG_CXL_MEM_RAW_COMMANDS=y` is required for most of the suite: QEMU
implements one background-capable command that the kernel exposes by
uapi id, Populate Log, and `poplog` is the only group to use it. Every
other userspace background command goes out through the RAW ioctl,
with the debugfs `cxl/mbox/raw_allow_all` override for the opcodes the
kernel keeps to itself (Scan Media, Media Operations). The
first RAW command taints the kernel and prints one WARN, which the
console scan filters out; any other splat fails the suite.

The suites are meant to run on a debug kernel (KASAN, lockdep, UBSAN).

## Suites

| Suite | Topology | Test groups |
|-------|----------|-------------|
| **t1** | One 1G device | `irq fw fwcancel sanitize user abort rawabort abortdeclined evictfail devbusy poison poplog backtoback cancelrace unbind stress` |
| **t2** | Two devices | `pair` |
| **t3** | One device, booted with `pci=nomsi` | `noirq fw poplog` |
| **t4** | Four devices behind two host bridges | `quadfw quadmatrix quadbarrage quadsanitize quadunbind quadroles` |
| **t5** | Three devices that run Activate FW in the background (success, failure, slower than the kernel waits) | `actfw` |

Every suite starts with a preflight: the mailbox registers can be read,
the device reports no background operation at boot (it does without
`qemu/0001`), and RAW commands are available.

## Test groups

"Evict" below is the kernel sending Request Abort Background Operation
to the running operation so that a new background command can take its
place. Userspace background commands are Scan Media and Media
Operations sent through the RAW ioctl, unless stated otherwise.

### One device (`guest/run-tests.sh`)

The kernel's own background commands:

- `irq`: the Background Command Complete Interrupt enable is still set
  in Mailbox Control after other commands rang the doorbell.
- `fw`: a two part firmware upload. The kernel polls for each Transfer
  FW without holding the mailbox: Identify is served meanwhile, a
  userspace background command gets `EBUSY`, and the upload completes
  without a timeout.
- `fwcancel`: an upload cancelled between two parts. The part in flight
  is left to complete, the abort of the transfer follows it, the upload
  ends as a user abort, and a new upload goes through.
- `sanitize`: the write returns at once and the security state reads
  `sanitize`. While it runs Get Health Info is allowed, Identify is
  refused, and neither a userspace background command nor a userspace
  Request Abort reaches the device. poll(2) on `security/state` wakes
  up, and the completion comes from the interrupt, not the poller.

Userspace background commands:

- `user`: Scan Media returns Background Command Started without
  waiting, other commands are served while it runs, it completes
  unaborted and the driver notices.
- `abort`: who may evict whom. A userspace command evicts a userspace
  command, and so does the kernel's sanitize. Media Operations cannot
  be aborted on QEMU: neither gets past it, the sanitize is not taken
  as started, and the device's refusal (return code 0020h) is decoded.
- `rawabort`: userspace sends Request Abort itself. The status register
  reads Background Operation clear, below 100%, return code Aborted;
  the driver, which was not told, lets go of the operation it lost.
  Against Media Operations the device answers Request Abort Not
  Supported by Background Operation and the operation runs on.
- `abortdeclined`: QEMU answers Success to a Request Abort past 85% and
  carries on. The driver must not take that for an abort: the evicting
  command and the kernel's sanitize are both refused, and the operation
  completes and is ended once.
- `evictfail`: the evicting command is one the device refuses (a
  misaligned Scan Media). The evicted operation is gone all the same,
  and the driver has to track nothing.
- `devbusy`: Media Operations is background capable but not gated by
  the driver. Sent while a scan runs, the device's own Busy reaches
  userspace as it is and the scan is not asked to abort.
- `poison`: Get Poison List reports Scan Media in Progress while a scan
  runs, and clears it once the scan completes or is aborted.
- `poplog`: Populate Log, the one background command sent by uapi
  command id instead of RAW. The kernel enables it from the CEL, it
  populates the Component State Dump Log, and Get Log reads back what
  QEMU wrote, with Retry Required while it populates and Interrupted
  for a fetch sequence it overtook. Then the same evictions as above:
  by another Populate Log, by and of a RAW Scan Media, by a firmware
  upload and by a sanitize, and by a command the device refuses.

Races and lifetime:

- `backtoback`: forty one-millisecond scans, the gap between them swept
  across the poller's one second mark. Each has to clean up after one
  that hardware has finished and the driver has not yet noticed.
- `cancelrace`: the same from two threads for `RACE_SECS`, with two
  more keeping the mailbox busy, so that the poller blocks on the
  mailbox while the next command ends the operation. Nothing may hang.
- `unbind`: the driver is unbound with an operation in flight and bound
  again. Hardware still runs it, the new instance serves commands and
  does not evict an operation it did not start.
- `stress`: `STRESS_SECS` of Identify, Get Health Info, Scan Media,
  Media Operations, sanitize and firmware uploads at once. Every
  command ends in success or busy, and the device is idle and in
  service afterwards.

Other topologies:

- `pair` (t2): the background slot is per mailbox. An operation and an
  eviction on one device leave the other's operation running.
- `noirq` (t3): without an interrupt the driver has to go and look. The
  poller looks after one second and again eleven seconds later; in
  between the next background command ends the finished one, and a
  finished sanitize still reads `sanitize` until the poller's look.
- `actfw` (t5): Activate FW in the background. The upload waits for it
  while other commands are served and a userspace background command
  is refused. The first device activates, the second fails and the
  upload and the kernel log say so. The first is then unbound while
  another upload waits: the unbind does not wait for the activation.

### Four devices (`guest/multi.py`, t4)

All of these check that what happens on one device is not seen on
another.

- `quadfw`: an upload on every device at once. They run in parallel,
  each device serves Identify and refuses a userspace background
  command. Then one device sanitizes: its upload is refused, alone.
- `quadmatrix`: four owners of the background slot at the same instant
  (sanitize, Scan Media, Media Operations, Transfer FW). A userspace
  background command evicts only on the device running the scan.
- `quadbarrage`: a different number of users start a background command
  on each device in the same instant. Each evicts the one before, and
  the last one completes.
- `quadsanitize`: four writers race for the sanitize of each device.
  One wins per device, the others are told busy, and every waiter wakes
  up to a finished sanitize.
- `quadunbind`: one device loses its driver and gets it back under
  load. Its users get `ENXIO`, and the operations in flight on the
  other devices complete unaborted.
- `quadroles`: each device keeps one role (sanitize, firmware upload,
  evicting scans, Media Operations) going round for a while, with plain
  users on all of them.

### Not run by default

- `actfwtmo` (t5): the upload gives up on an activation that outlasts
  it, hardware carries on, and the next upload starts its own. Takes
  five and a half minutes.
- `staleuntracked` (t1): a reproducer for a background-capable opcode
  the driver does not track (Media Operations, RAW only) sent while its
  tracking is stale. Expected to fail.

## Running

    ./run-all.sh                 every suite
    ./run-all.sh t1              one suite
    TEST_GROUPS="fw sanitize" ./run-all.sh t1     only those groups

Exit status is 0 iff every suite passes and no console carries a splat.

## Configuration

Environment variables consumed by `topo-lib.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `QEMU` | `qemu-system-x86_64` | QEMU binary, see [QEMU](#qemu). |
| `KERNEL` | `$HOME/code/linux-torvalds/arch/x86/boot/bzImage` | bzImage under test. |
| `IMG` | `$HOME/img/cxl-test.qcow2` | Guest rootfs. |
| `ROOTDEV` | `/dev/sda1` | Guest root partition. |
| `SSH_KEY` | *(unset)* | Optional ssh identity file. |
| `EXTRA_APPEND` | *(empty)* | Extra kernel command-line arguments. |
| `SSHPORT` | `27310` | Host port forwarded to guest sshd. |
| `RUNDIR` | `/tmp/cxl-bg-tests` | Work directory (console log, qmp socket, results). |
| `OUT` | `$RUNDIR/results` | Results directory (`<suite>.tap`, `<suite>.dmesg`, consoles). |
| `STRESS_SECS` | `30` | Duration of the stress groups. |
| `RACE_SECS` | `60` | Duration of the cancel race group. |
| `NO_BAIL` | *(unset)* | Carry on past a failed preflight. |

## Known limitations

- Durations are QEMU's: Sanitize 8s per 1G, Scan Media about 8.2ms per
  MiB, Media Operations (zero) 4s and not abortable, Transfer FW 2s per
  part, Populate Log 4s. Percentage Complete only moves on a one second
  tick, a Request Abort is honoured below 85%, and no interrupt is
  raised for an abort.
- QEMU raises the completion interrupt whatever the Background Command
  Complete Interrupt enable says, so the suite cannot tell whether the
  kernel keeps that bit set.
- QEMU's Sanitize always succeeds; a failed sanitize is not covered.
- Populate Log is only there for the Component State Dump Log, always
  succeeds, and leaves the log empty when aborted. The kernel reports
  that a userspace background command started and nothing else, so
  `poplog` takes its outcome from the registers and from Get Log.
- t5 expects a kernel that waits for a backgrounded Activate FW and
  reports its result through the firmware upload.

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

## Kernel

`CONFIG_CXL_MEM_RAW_COMMANDS=y` is required for most of the suite: QEMU
implements no background-capable command that the kernel exposes by
uapi id, so userspace background commands go out through the RAW
ioctl, with the debugfs `cxl/mbox/raw_allow_all` override for the
opcodes the kernel keeps to itself (Scan Media, Media Operations). The
first RAW command taints the kernel and prints one WARN, which the
console scan filters out; any other splat fails the suite.

The suites are meant to run on a debug kernel (KASAN, lockdep, UBSAN).

## Suites

| Suite | Topology | Test groups |
|-------|----------|-------------|
| **t1** | One 1G device | Every single-device group: `irq fw fwcancel sanitize user abort rawabort abortdeclined evictfail devbusy poison backtoback cancelrace unbind stress` |
| **t2** | Two devices | `pair`: the background slot and its state are per mailbox |
| **t3** | One device, booted with `pci=nomsi` | `noirq fw`: completion found by the poller alone |
| **t4** | Four devices behind two host bridges | `quadfw quadmatrix quadbarrage quadsanitize quadunbind quadroles` (`guest/multi.py`): concurrent users and a different owner of the background slot on each device |
| **t5** | Three devices that run Activate FW in the background (success, failure, slower than the kernel waits) | `actfw`: the firmware upload waits for the activation and reports its result |

Groups that are not run by default:

- `actfwtmo` (t5): the upload gives up on an activation that outlasts
  it. Takes five and a half minutes.
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
  part. Percentage Complete only moves on a one second tick, a Request
  Abort is honoured below 85%, and no interrupt is raised for an abort.
- QEMU raises the completion interrupt whatever the Background Command
  Complete Interrupt enable says, so the suite cannot tell whether the
  kernel keeps that bit set.
- QEMU's Sanitize always succeeds; a failed sanitize is not covered.
- t5 expects a kernel that waits for a backgrounded Activate FW and
  reports its result through the firmware upload.

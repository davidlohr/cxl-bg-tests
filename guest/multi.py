#!/usr/bin/env python3
# multi.py - several devices, several users on each, all at once.
#
#   multi.py <test>         one of: fw matrix barrage sanitize unbind roles
#
# Runs against every CXL memory device of the guest (at least two, the
# tests are written for four) and prints one verdict per line, which
# run-tests.sh turns into TAP:
#
#   PASS <description>
#   FAIL <description>
#   SKIP <description>
#   anything else is a diagnostic
#
# What every test is after is the same thing: the background slot, the
# poller, the completion interrupt and the state the driver keeps about
# them are per mailbox. Whatever happens on one device - an eviction, a
# sanitize, a firmware upload, an unbind - must not be seen on another,
# however many users are on each.
#
# Durations are QEMU's, for the 1G devices of the topology: Sanitize 8s,
# Scan Media ~8.2ms per MiB, Media Operations (zero) 4s and not
# abortable, Transfer FW 2s per part. Percentage Complete only moves on
# a one second tick, and a Request Abort is honoured below 85%.
import ctypes
import errno
import fcntl
import os
import select
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import cxlmbox                                          # noqa: E402
from cxlmbox import CXL_MEM_SEND_COMMAND, CMD_ID_RAW   # noqa: E402

ID_IDENTIFY = 1
OP_ABORT = 0x0005
OP_FW = 0x0201
OP_HEALTH = 0x4200
OP_SCAN = 0x4304
OP_SANITIZE = 0x4400
OP_MEDIA = 0x4402
RC_STARTED = 0x1
RC_UNSUPPORTED = 0x3
SCAN_LONG = 768 << 20
DYNDBG = "/sys/kernel/debug/dynamic_debug/control"

now = time.monotonic


def ename(e):
    return errno.errorcode.get(e, str(e)) if e else "0"


def verdict(desc, cond, detail=""):
    print("%s %s%s" % ("PASS" if cond else "FAIL", desc,
                       " (%s)" % detail if detail else ""), flush=True)
    return cond


def diag(msg):
    print(msg, flush=True)


def xfer(fd, opcode, payload=b"", out=0, cmd_id=CMD_ID_RAW):
    """One CXL_MEM_SEND_COMMAND. Returns (errno, hardware return code)."""
    inbuf = ctypes.create_string_buffer(payload, len(payload) or 1)
    outbuf = ctypes.create_string_buffer(out or 1)
    req = bytearray(struct.pack(
        "<IIHHIIIQIIQ", cmd_id, 0, opcode if cmd_id == CMD_ID_RAW else 0,
        0, 0, len(payload), 0, ctypes.addressof(inbuf) if payload else 0,
        out, 0, ctypes.addressof(outbuf) if out else 0))
    try:
        fcntl.ioctl(fd, CXL_MEM_SEND_COMMAND, req)
    except OSError as e:
        return e.errno, 0
    return 0, struct.unpack_from("<I", req, 12)[0]


def sysfs_write(path, data):
    """0 or the errno of the write."""
    try:
        fd = os.open(path, os.O_WRONLY)
    except OSError as e:
        return e.errno
    try:
        os.write(fd, data if isinstance(data, bytes) else data.encode())
    except OSError as e:
        return e.errno
    finally:
        os.close(fd)
    return 0


def sysfs_read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as e:
        return "<%s>" % ename(e.errno)


class Dev:
    def __init__(self, mem):
        self.mem = mem
        self.dir = "/sys/bus/cxl/devices/" + mem
        self.pdev = cxlmbox.pci_dev(mem)
        self.bdf = os.path.basename(self.pdev)
        self.fw = "/sys/class/firmware/" + mem
        self.mb = cxlmbox.Mailbox(mem)
        self.fd = self.open()

    def __str__(self):
        return self.bdf

    def open(self):
        return os.open("/dev/cxl/" + self.mem, os.O_RDWR)

    def regs(self):
        return self.mb.regs()

    def hw(self):
        """What hardware runs: (Background Operation, opcode)."""
        r = self.regs()
        return r["sts_bg_op"], r["bg_opcode"]

    def done(self):
        """Last operation ran to completion: (pct, return code)."""
        r = self.regs()
        return r["bg_pct"], r["bg_rc"]

    def ident(self, fd=None):
        return xfer(fd or self.fd, 0, b"", 0x43, ID_IDENTIFY)

    def health(self, fd=None):
        return xfer(fd or self.fd, OP_HEALTH, b"", 0x12)

    def scan(self, nbytes, fd=None):
        return xfer(fd or self.fd, OP_SCAN,
                    struct.pack("<QQB", 0, nbytes // 64, 1))

    def media_zero(self, fd=None):
        return xfer(fd or self.fd, OP_MEDIA,
                    struct.pack("<BBHIQQ", 1, 1, 0, 1, 0, 4096))

    def state(self):
        return sysfs_read(self.dir + "/security/state")

    def sanitize(self):
        return sysfs_write(self.dir + "/security/sanitize", "1")

    def wait_idle(self, secs):
        end = now() + secs
        while now() < end:
            if not self.regs()["sts_bg_op"]:
                return True
            time.sleep(0.05)
        return False

    def wait_state(self, secs):
        """Until security/state leaves sanitize."""
        end = now() + secs
        while now() < end:
            if self.state() != "sanitize":
                return True
            time.sleep(0.1)
        return False

    def fw_start(self, blob):
        for name, data in (("loading", "1"), ("data", blob), ("loading", "0")):
            e = sysfs_write("%s/%s" % (self.fw, name), data)
            if e:
                return e
        return 0

    def fw_wait(self, secs):
        end = now() + secs
        while now() < end:
            if sysfs_read(self.fw + "/status") == "idle":
                return True
            time.sleep(0.05)
        return False

    def fw_error(self):
        return sysfs_read(self.fw + "/error")


class Waiter(threading.Thread):
    """poll(2) on security/state, as a sanitize waiter would."""

    def __init__(self, dev, secs):
        super().__init__(daemon=True)
        self.dev, self.secs = dev, secs
        self.woke = None
        self.reread = None
        self.f = open(dev.dir + "/security/state")
        self.f.read()                 # the baseline poll(2) compares to
        self.start()

    def run(self):
        p = select.poll()
        p.register(self.f, select.POLLPRI | select.POLLERR)
        if p.poll(self.secs * 1000):
            self.woke = now()
            self.f.seek(0)
            self.reread = self.f.read().strip()


class Log:
    def mark(self):
        self.m = "cxl-bg-tests mark %d" % time.monotonic_ns()
        with open("/dev/kmsg", "w") as f:
            f.write(self.m + "\n")

    def lines(self):
        """Kernel log since the mark; None if the mark scrolled away."""
        out = subprocess.run(["dmesg"], capture_output=True, text=True,
                             errors="replace").stdout.splitlines()
        for i in range(len(out) - 1, -1, -1):
            if self.m in out[i]:
                return out[i + 1:]
        return None

    def count(self, dev, what, lines=None):
        lines = self.lines() if lines is None else lines
        if lines is None:
            return -1
        return sum(1 for ln in lines if dev.bdf in ln and what in ln)


def quiet(on):
    """Stop the per command debug output while users hammer the mailbox:
    it would scroll everything else out of the log buffer."""
    for mod in ("cxl_pci", "cxl_core"):
        sysfs_write(DYNDBG, "module %s %sp" % (mod, "-" if on else "+"))


def settle(devs, secs=20):
    """Hardware idle on every device, and the driver caught up with it."""
    ok = all([d.wait_idle(secs) for d in devs])
    time.sleep(1.3)
    return ok


def sleep_until(t):
    d = t - now()
    if d > 0:
        time.sleep(d)


class Tally:
    """Outcomes of one user's commands, in order of first appearance."""

    def __init__(self):
        self.n = {}
        self.seq = []

    def add(self, key):
        self.n[key] = self.n.get(key, 0) + 1
        if not self.seq or self.seq[-1] != key:
            self.seq.append(key)

    def only(self, *keys):
        return all(k in keys for k in self.n)

    def __str__(self):
        return " ".join("%s/0x%x:%d" % (ename(e), rc, c)
                        for (e, rc), c in self.n.items()) or "nothing"


def user(dev, fn, stop, tally, pause=0.005):
    """A user: its own fd, one command after the other until stop."""
    def run():
        fd = dev.open()
        while now() < stop:
            tally.add(fn(fd))
            time.sleep(pause)
        os.close(fd)
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def join(threads, secs=60):
    end = now() + secs
    for t in threads:
        t.join(max(0.1, end - now()))
    return not any(t.is_alive() for t in threads)


def have_fw(devs):
    return all(os.path.isdir(d.fw) for d in devs)


def have_sanitize(devs):
    # the attribute is there without cxl_mem, the command is not
    return all(os.path.exists(d.dir + "/security/sanitize") and
               os.path.exists(d.dir + "/driver") for d in devs)


# ---------------------------------------------------------------------
# Transfer FW on every device at once. The kernel waits for each part,
# without the mailbox: nothing about one upload may hold up another.
def t_fw(devs, log):
    if not have_fw(devs):
        print("SKIP parallel firmware uploads: no firmware upload interface")
        return
    settle(devs)
    log.mark()
    blob = os.urandom(3840)           # two parts, 2s each
    t0 = now()
    started = [d.fw_start(blob) for d in devs]
    verdict("firmware upload starts on every device",
            not any(started), " ".join(ename(e) for e in started))
    sleep_until(t0 + 1.0)             # inside the first part, everywhere
    hw, idents, scans = [], [], []
    for d in devs:
        hw.append(d.hw())
        t = now()
        e, _ = d.ident()
        idents.append((e, (now() - t) * 1000))
        scans.append(d.scan(64)[0])
    verdict("every device runs its own Transfer FW in the background",
            all(h == (1, OP_FW) for h in hw),
            " ".join("%d/0x%x" % h for h in hw))
    verdict("Identify served on each, behind no other device's upload",
            all(e == 0 and ms < 500 for e, ms in idents),
            " ".join("%s:%dms" % (ename(e), ms) for e, ms in idents))
    verdict("userspace background command refused on each while the kernel polls",
            all(e == errno.EBUSY for e in scans),
            " ".join(ename(e) for e in scans))
    fin = [d.fw_wait(20) for d in devs]
    took = now() - t0
    errs = [d.fw_error() for d in devs]
    verdict("every upload completes", all(fin) and not any(errs),
            " ".join("'%s'" % e for e in errs))
    # one after the other they would take 4s each
    verdict("... in parallel (%.1fs for %d devices)" % (took, len(devs)),
            took < 7.5)
    lines = log.lines()
    n = [log.count(d, "(0x0201) started", lines) for d in devs]
    verdict("two parts sent to each device, none timed out",
            all(c == 2 for c in n) and
            not any(log.count(d, "timeout waiting for background", lines)
                    for d in devs), " ".join(map(str, n)))

    # One device is busy with something else: its upload fails, alone.
    if not have_sanitize(devs):
        print("SKIP upload against a sanitizing device: no sanitize")
        return
    settle(devs)
    victim = devs[1]
    e = victim.sanitize()
    if e or victim.state() != "sanitize":
        verdict("sanitize starts on %s" % victim, False, ename(e))
        victim.wait_state(30)
        return
    started = [d.fw_start(blob) for d in devs]
    fin = [d.fw_wait(20) for d in devs]
    errs = [d.fw_error() for d in devs]
    verdict("upload refused on the sanitizing device",
            fin[1] and errs[1] != "", "'%s'" % errs[1])
    verdict("... and on that one only",
            all(f and not e for i, (f, e) in enumerate(zip(fin, errs))
                if i != 1),
            " ".join("'%s'" % e for e in errs))
    verdict("the refused upload did not disturb the sanitize",
            victim.hw()[1] == OP_SANITIZE, "0x%x" % victim.hw()[1])
    verdict("sanitize completes", victim.wait_state(30))
    settle(devs)
    e = victim.fw_start(blob)
    verdict("upload works on it afterwards",
            not e and victim.fw_wait(20) and victim.fw_error() == "",
            "'%s'" % victim.fw_error())


# ---------------------------------------------------------------------
# Four devices, four different owners of the background slot at the
# same instant: the kernel's Sanitize, a userspace Scan Media, a
# userspace Media Operation that cannot be aborted, and a Transfer FW
# the kernel polls for. What each device then accepts depends on its
# own state alone.
def t_matrix(devs, log):
    if len(devs) < 4 or not have_fw(devs) or not have_sanitize(devs):
        print("SKIP state matrix: needs four devices with sanitize and firmware upload")
        return
    san, usr, med, fwd = devs[:4]
    settle(devs)
    base = [d.state() for d in devs]
    log.mark()
    waiter = Waiter(san, 30)
    time.sleep(0.2)
    t0 = now()
    e_fw = fwd.fw_start(os.urandom(3840))
    e_san = san.sanitize()
    r_usr = usr.scan(SCAN_LONG)
    r_med = med.media_zero()
    verdict("four operations start, one per device",
            (e_fw, e_san, r_usr, r_med) == (0, 0, (0, RC_STARTED), (0, RC_STARTED)),
            "fw=%s sanitize=%s scan=%s/0x%x media=%s/0x%x" % (
                ename(e_fw), ename(e_san), ename(r_usr[0]), r_usr[1],
                ename(r_med[0]), r_med[1]))
    sleep_until(t0 + 0.6)

    hw = [d.hw() for d in devs]
    verdict("each device runs its own",
            hw == [(1, OP_SANITIZE), (1, OP_SCAN), (1, OP_MEDIA), (1, OP_FW)],
            " ".join("%d/0x%x" % h for h in hw))
    st = [d.state() for d in devs]
    verdict("only the sanitizing device reads sanitize",
            st[0] == "sanitize" and st[1:] == base[1:], " ".join(st))
    idents = [d.ident()[0] for d in (fwd, san, usr, med)]
    verdict("Identify refused by the sanitizing device, served by the others",
            idents == [0, errno.EBUSY, 0, 0],
            " ".join(ename(e) for e in idents))
    # a userspace background command: on whom can it evict what is there?
    r = [fwd.scan(64), san.scan(64), med.scan(64), usr.scan(64)]
    verdict("... not on the one the kernel polls", r[0][0] == errno.EBUSY,
            ename(r[0][0]))
    verdict("... not on the one that sanitizes", r[1][0] == errno.EBUSY,
            ename(r[1][0]))
    verdict("... not on the one whose operation cannot be aborted",
            r[2][0] == errno.EBUSY, ename(r[2][0]))
    verdict("... only on the one running a userspace operation",
            r[3] == (0, RC_STARTED), "%s/0x%x" % (ename(r[3][0]), r[3][1]))
    late = now() - t0
    hw = [d.hw() for d in devs]
    verdict("the three refusals left their devices as they were (%.1fs in)" % late,
            hw == [(1, OP_SANITIZE), (1, OP_SCAN), (1, OP_MEDIA), (1, OP_FW)]
            and late < 1.9,
            " ".join("%d/0x%x" % h for h in hw))

    verdict("Media Operation runs to completion",
            med.wait_idle(10) and med.done() == (100, 0),
            "pct=%d rc=0x%x" % med.done())
    verdict("firmware upload completes",
            fwd.fw_wait(15) and fwd.fw_error() == "", "'%s'" % fwd.fw_error())
    waiter.join(30)
    verdict("sanitize completes and its waiter wakes up",
            waiter.woke is not None and waiter.reread != "sanitize",
            str(waiter.reread))
    verdict("sanitize was not aborted", san.done() == (100, 0),
            "pct=%d rc=0x%x" % san.done())
    settle(devs)
    lines = log.lines()
    ab = [log.count(d, "background operation aborted", lines) for d in devs]
    verdict("one abort in all, on the device that was evicted",
            ab == [0, 1, 0, 0], " ".join(map(str, ab)))
    no = [log.count(d, "does not support abort", lines) for d in devs]
    verdict("one abort refused by hardware, on the Media Operation device",
            no[2] >= 1 and no[0] == no[1] == no[3] == 0,
            " ".join(map(str, no)))
    r = [d.scan(64) for d in devs]
    verdict("every device accepts a background command afterwards",
            all(x == (0, RC_STARTED) for x in r),
            " ".join("%s/0x%x" % (ename(e), rc) for e, rc in r))


# ---------------------------------------------------------------------
# N users start a background command on the same device in the same
# instant, with a different N on each device. Each one evicts the one
# before: the last wins, and that one completes.
def t_barrage(devs, log):
    counts = [2, 4, 8, 16][:len(devs)]
    total = sum(counts)
    settle(devs)
    log.mark()
    gate = threading.Barrier(total)
    res = [[] for _ in devs]

    def starter(i):
        fd = devs[i].open()
        gate.wait()
        res[i].append(devs[i].scan(SCAN_LONG, fd))
        os.close(fd)

    threads = [threading.Thread(target=starter, args=(i,), daemon=True)
               for i, n in enumerate(counts) for _ in range(n)]
    for t in threads:
        t.start()
    verdict("%d users on %d devices return" % (total, len(devs)),
            join(threads, 30))
    for i, d in enumerate(devs):
        bad = [r for r in res[i] if r != (0, RC_STARTED)]
        verdict("%s: all %d started" % (d, counts[i]),
                len(res[i]) == counts[i] and not bad,
                " ".join("%s/0x%x" % (ename(e), rc) for e, rc in bad))
    hw = [d.regs() for d in devs]
    verdict("every device runs one, not aborted",
            all(r["sts_bg_op"] == 1 and r["bg_opcode"] == OP_SCAN and
                r["bg_rc"] == 0 for r in hw),
            " ".join("%d/0x%x/0x%x" % (r["sts_bg_op"], r["bg_opcode"],
                                        r["bg_rc"]) for r in hw))
    idle = [d.wait_idle(12) for d in devs]
    fin = [d.done() for d in devs]
    verdict("the last one on every device runs to completion",
            all(idle) and all(f == (100, 0) for f in fin),
            " ".join("pct=%d,rc=0x%x" % f for f in fin))
    time.sleep(1.5)
    lines = log.lines()
    for i, d in enumerate(devs):
        n = counts[i]
        got = (log.count(d, "(0x4304) started", lines),
               log.count(d, "background operation aborted", lines),
               log.count(d, "(0x4304) ended", lines))
        verdict("%s: %d started, %d aborted, %d ended" % (d, n, n - 1, n),
                got == (n, n - 1, n), "%d/%d/%d" % got)


# ---------------------------------------------------------------------
# Four writers race for the sanitize of each device, on every device at
# once. One wins per device, and all the sanitizes then run together.
def t_sanitize(devs, log):
    writers, nwait = 4, 2
    if not have_sanitize(devs):
        print("SKIP concurrent sanitize: no sanitize")
        return
    settle(devs)
    log.mark()
    waiters = [[Waiter(d, 40) for _ in range(nwait)] for d in devs]
    time.sleep(0.3)
    gate = threading.Barrier(writers * len(devs))
    res = [[] for _ in devs]

    def writer(i):
        gate.wait()
        res[i].append(devs[i].sanitize())

    threads = [threading.Thread(target=writer, args=(i,), daemon=True)
               for i in range(len(devs)) for _ in range(writers)]
    t0 = now()
    for t in threads:
        t.start()
    verdict("%d writers on %d devices return" % (len(threads), len(devs)),
            join(threads, 30))
    for i, d in enumerate(devs):
        verdict("%s: one writer starts the sanitize, the others are told busy" % d,
                sorted(res[i]) == [0] + [errno.EBUSY] * (writers - 1),
                " ".join(ename(e) for e in res[i]))
    hw = [d.hw() for d in devs]
    st = [d.state() for d in devs]
    verdict("all devices sanitize at the same time",
            all(h == (1, OP_SANITIZE) for h in hw) and
            all(s == "sanitize" for s in st),
            " ".join("%d/0x%x/%s" % (h[0], h[1], s) for h, s in zip(hw, st)))
    idents = [d.ident()[0] for d in devs]
    verdict("Identify refused on each", all(e == errno.EBUSY for e in idents),
            " ".join(ename(e) for e in idents))
    left = [d.wait_state(40) for d in devs]
    verdict("every device leaves sanitize (%.1fs)" % (now() - t0), all(left))
    for ws in waiters:
        for w in ws:
            w.join(5)
    woke = [sum(1 for w in ws if w.woke is not None and
                w.reread != "sanitize") for ws in waiters]
    verdict("every waiter of every device woke up to a finished sanitize",
            all(n == nwait for n in woke), " ".join(map(str, woke)))
    fin = [d.done() for d in devs]
    verdict("none was aborted", all(f == (100, 0) for f in fin),
            " ".join("pct=%d,rc=0x%x" % f for f in fin))
    settle(devs)
    lines = log.lines()
    n = [(log.count(d, "(0x4400) started", lines),
          log.count(d, "(0x4400) ended", lines)) for d in devs]
    verdict("one sanitize started and ended per device",
            all(x == (1, 1) for x in n), " ".join("%d/%d" % x for x in n))
    r = [(d.ident()[0], d.scan(64)) for d in devs]
    verdict("every device back in service",
            all(x == (0, (0, RC_STARTED)) for x in r),
            " ".join("%s,%s/0x%x" % (ename(i), ename(s[0]), s[1])
                     for i, s in r))


# ---------------------------------------------------------------------
# One device loses its driver, and gets it back, with users on it and
# on all the others, and with an operation in flight on each.
def t_unbind(devs, log):
    victim = devs[1]
    others = [d for d in devs if d is not victim]
    settle(devs)
    log.mark()
    quiet(True)
    stop = now() + 8
    tallies, threads = {}, []

    def add(dev, name, fn, pause=0.005):
        t = tallies[(dev.bdf, name)] = Tally()
        threads.append(user(dev, fn, stop, t, pause))

    # bystanders: something in flight that must survive, plus plain users
    first = [others[0].scan(SCAN_LONG)]
    if len(others) > 1:
        first.append(others[1].media_zero())
    for d in others[:2]:
        add(d, "ident", d.ident)
        add(d, "ident2", d.ident)
    for d in others[2:]:
        add(d, "ident", d.ident)
        add(d, "scan", lambda fd, d=d: d.scan(64, fd), 0.3)
    # the victim: background and plain commands, back to back
    for i in range(2):
        add(victim, "ident%d" % i, victim.ident)
        add(victim, "scan%d" % i, lambda fd: victim.scan(64, fd), 0.05)

    time.sleep(1.5)
    t0 = now()
    e = sysfs_write("/sys/bus/pci/drivers/cxl_pci/unbind", victim.bdf)
    took = now() - t0
    verdict("driver unbinds under load (%.1fs)" % took,
            not e and took < 10 and not os.path.exists(victim.pdev + "/driver"),
            ename(e))
    time.sleep(1.5)
    e = sysfs_write("/sys/bus/pci/drivers/cxl_pci/bind", victim.bdf)
    verdict("driver rebinds", not e, ename(e))
    alive = not join(threads, 30)
    quiet(False)
    verdict("no user is left hanging", not alive)

    ok = (0, 0)
    gone = (errno.ENXIO, 0)
    for (bdf, name), t in tallies.items():
        if bdf != victim.bdf:
            continue
        good = (0, RC_STARTED) if name.startswith("scan") else ok
        # served until the device went away, and never again on that fd
        verdict("%s %s: served, then ENXIO for good" % (bdf, name),
                t.seq in ([good, gone], [gone]) and gone in t.n, str(t))
    for (bdf, name), t in tallies.items():
        if bdf == victim.bdf:
            continue
        good = (0, RC_STARTED) if name.startswith("scan") else ok
        verdict("%s %s: nothing but success throughout" % (bdf, name),
                t.only(good) and t.n, str(t))
    verdict("the operations in flight elsewhere started",
            all(r == (0, RC_STARTED) for r in first),
            " ".join("%s/0x%x" % (ename(e), rc) for e, rc in first))
    for d in others[:2]:
        verdict("%s: its operation ran to completion" % d,
                d.wait_idle(10) and d.done() == (100, 0),
                "pct=%d rc=0x%x" % d.done())
    lines = log.lines()
    ab = [log.count(d, "background operation aborted", lines)
          for d in others[:2]]
    verdict("... and was never aborted", not any(ab), " ".join(map(str, ab)))

    mem = None
    for _ in range(50):
        found = [n for n in os.listdir(victim.pdev) if n.startswith("mem")]
        if found and os.path.exists("/dev/cxl/" + found[0]):
            mem = found[0]
            break
        time.sleep(0.1)
    if not verdict("a new memdev shows up (%s)" % mem, mem is not None):
        return
    new = Dev(mem)
    new.wait_idle(10)
    r = (new.ident()[0], new.scan(64))
    verdict("the new instance serves plain and background commands",
            r == (0, (0, RC_STARTED)),
            "%s,%s/0x%x" % (ename(r[0]), ename(r[1][0]), r[1][1]))
    settle(others + [new])
    r = [d.scan(64) for d in others]
    verdict("the other devices accept a background command afterwards",
            all(x == (0, RC_STARTED) for x in r),
            " ".join("%s/0x%x" % (ename(e), rc) for e, rc in r))


# ---------------------------------------------------------------------
# A different owner of the background slot on each device, each going
# round and round for a while, with plain users on all of them.
def t_roles(devs, log):
    secs = float(os.environ.get("STRESS_SECS", 30))
    if len(devs) < 4 or not have_fw(devs) or not have_sanitize(devs):
        print("SKIP roles: needs four devices with sanitize and firmware upload")
        return
    san, fwd, usr, med = devs[:4]
    settle(devs)
    quiet(True)
    stop = now() + secs
    threads = []
    t = {k: Tally() for k in ("san.ident", "san.health", "fw.ident",
                              "usr.ident", "usr.scan", "med.ident")}
    out = {"san": [], "fw": [], "med": []}

    def sanitizer():
        while now() < stop:
            out["san"].append(san.sanitize())
            san.wait_state(40)

    def uploader():
        blob = os.urandom(3840)
        while now() < stop:
            e = fwd.fw_start(blob)
            fin = fwd.fw_wait(20)
            out["fw"].append((e, fin, fwd.fw_error()))

    def zeroer():
        fd = med.open()
        while now() < stop:
            r = med.media_zero(fd)
            idle = med.wait_idle(10)
            out["med"].append((r, idle, med.done()))
            time.sleep(1.3)           # the driver hears of it by interrupt
        os.close(fd)

    for fn in (sanitizer, uploader, zeroer):
        th = threading.Thread(target=fn, daemon=True)
        th.start()
        threads.append(th)
    for _ in range(2):
        threads.append(user(san, san.ident, stop, t["san.ident"]))
        threads.append(user(fwd, fwd.ident, stop, t["fw.ident"]))
        threads.append(user(usr, usr.ident, stop, t["usr.ident"]))
        threads.append(user(med, med.ident, stop, t["med.ident"]))
    threads.append(user(san, san.health, stop, t["san.health"]))
    for _ in range(4):
        threads.append(user(usr, lambda fd: usr.scan(64, fd), stop,
                            t["usr.scan"]))
    alive = not join(threads, secs + 60)
    quiet(False)
    verdict("%ds of users on four devices: all return" % secs, not alive)

    ok, busy = (0, 0), (errno.EBUSY, 0)
    verdict("sanitizing device: every sanitize starts (%d)" % len(out["san"]),
            out["san"] and not any(out["san"]),
            " ".join(ename(e) for e in out["san"]))
    verdict("... Identify served or refused, and refused at least once",
            t["san.ident"].only(ok, busy) and busy in t["san.ident"].n,
            str(t["san.ident"]))
    verdict("... Get Health Info always reaches the device",
            t["san.health"].only((0, RC_UNSUPPORTED)) and t["san.health"].n,
            str(t["san.health"]))
    verdict("firmware device: every upload completes (%d)" % len(out["fw"]),
            out["fw"] and all(not e and fin and err == ""
                              for e, fin, err in out["fw"]),
            " ".join("%s,%s,'%s'" % (ename(e), fin, err)
                     for e, fin, err in out["fw"] if e or not fin or err))
    verdict("... Identify never refused", t["fw.ident"].only(ok) and
            t["fw.ident"].n, str(t["fw.ident"]))
    verdict("evicting device: every one of %d Scan Media starts" %
            sum(t["usr.scan"].n.values()),
            t["usr.scan"].only((0, RC_STARTED)) and t["usr.scan"].n,
            str(t["usr.scan"]))
    verdict("... Identify never refused", t["usr.ident"].only(ok) and
            t["usr.ident"].n, str(t["usr.ident"]))
    bad = [(r, idle, fin) for r, idle, fin in out["med"]
           if r != (0, RC_STARTED) or not idle or fin != (100, 0)]
    verdict("Media Operation device: every one starts and completes (%d)" %
            len(out["med"]), out["med"] and not bad, str(bad))
    verdict("... Identify never refused", t["med.ident"].only(ok) and
            t["med.ident"].n, str(t["med.ident"]))

    verdict("every device goes idle", all([d.wait_idle(40) for d in devs]))
    verdict("no device left in sanitize", all([d.wait_state(40) for d in devs]),
            " ".join(d.state() for d in devs))
    fwd.fw_wait(20)
    settle(devs)
    r = [(d.ident()[0], d.scan(64)) for d in devs]
    verdict("every device back in service",
            all(x == (0, (0, RC_STARTED)) for x in r),
            " ".join("%s,%s/0x%x" % (ename(i), ename(s[0]), s[1])
                     for i, s in r))


TESTS = {"fw": t_fw, "matrix": t_matrix, "barrage": t_barrage,
         "sanitize": t_sanitize, "unbind": t_unbind, "roles": t_roles}


def main(argv):
    if len(argv) != 2 or argv[1] not in TESTS:
        raise SystemExit("usage: multi.py " + "|".join(TESTS))
    mems = sorted(n for n in os.listdir("/sys/bus/cxl/devices")
                  if n.startswith("mem") and n[3:].isdigit())
    devs = sorted((Dev(m) for m in mems), key=lambda d: d.bdf)
    if len(devs) < 2:
        print("SKIP %s: needs more than one memory device" % argv[1])
        return 0
    diag("devices: " + " ".join("%s=%s" % (d.mem, d.bdf) for d in devs))
    try:
        TESTS[argv[1]](devs, Log())
    finally:
        quiet(False)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
# cxlmbox.py - poke a CXL memory device mailbox from the guest.
#
#   cxlmbox.py regs  <memN>             mailbox registers, decoded
#   cxlmbox.py raw   <memN> <opcode> [hex-payload] [--out N]
#   cxlmbox.py cmd   <memN> <id>     [hex-payload] [--out N]
#   cxlmbox.py hammer <memN> <secs> <scan-threads> <plain-threads>
#
# "raw" and "cmd" go through CXL_MEM_SEND_COMMAND, the former as a RAW
# command (CONFIG_CXL_MEM_RAW_COMMANDS, plus debugfs raw_allow_all for
# the opcodes the kernel keeps to itself), the latter by uapi command id.
# Both print one line:
#
#   errno=<name|0> retval=0x<hw return code> ms=<elapsed> out=<hex>
#
# "regs" reads the registers behind the driver's back, through the PCI
# resource file, to see what hardware believes rather than what the
# driver tracks.
import ctypes
import errno
import fcntl
import mmap
import os
import struct
import sys
import time

CXL_MEM_SEND_COMMAND = (3 << 30) | (48 << 16) | (0xCE << 8) | 2
CMD_ID_RAW = 2

DVSEC_CXL_VENDOR = 0x1e98
DVSEC_REG_LOCATOR = 8
REGBLOCK_DEVICE = 3
CAP_ID_PRIMARY_MAILBOX = 2


def pci_dev(memdev):
    return os.path.dirname(os.path.realpath("/sys/bus/cxl/devices/" + memdev))


def find_device_regs(pdev):
    """(BAR index, offset) of the CXL Device Register block."""
    with open(pdev + "/config", "rb") as f:
        cfg = f.read()
    pos = 0x100
    while pos and pos + 12 <= len(cfg):
        hdr, = struct.unpack_from("<I", cfg, pos)
        if (hdr & 0xffff) == 0x23:
            h1, h2 = struct.unpack_from("<IH", cfg, pos + 4)
            if (h1 & 0xffff) == DVSEC_CXL_VENDOR and h2 == DVSEC_REG_LOCATOR:
                for ent in range(pos + 0xc, pos + (h1 >> 20), 8):
                    lo, hi = struct.unpack_from("<II", cfg, ent)
                    if ((lo >> 8) & 0xff) == REGBLOCK_DEVICE:
                        return lo & 7, (hi << 32) | (lo & 0xffff0000)
        pos = hdr >> 20
    raise SystemExit("no CXL device register block in " + pdev)


class Mailbox:
    def __init__(self, memdev):
        pdev = pci_dev(memdev)
        bar, off = find_device_regs(pdev)
        fd = os.open("%s/resource%d" % (pdev, bar), os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(fd, os.fstat(fd).st_size)
        os.close(fd)
        ncaps = (self.r64(off) >> 32) & 0xffff
        for i in range(ncaps):
            ent = off + 0x10 * (i + 1)
            if (self.r32(ent) & 0xffff) == CAP_ID_PRIMARY_MAILBOX:
                self.base = off + self.r32(ent + 4)
                return
        raise SystemExit("no primary mailbox capability")

    # one access of the register's own width: the device decodes by size
    def r32(self, off):
        return ctypes.c_uint32.from_buffer(self.mm, off).value

    def r64(self, off):
        return ctypes.c_uint64.from_buffer(self.mm, off).value

    def regs(self):
        cap = self.r32(self.base)
        ctrl = self.r32(self.base + 4)
        sts = self.r64(self.base + 0x10)
        bg = self.r64(self.base + 0x18)
        return {
            "cap_bg_irq": (cap >> 6) & 1,
            "payload_shift": cap & 0x1f,
            "ctrl_doorbell": ctrl & 1,
            "ctrl_bg_irq": (ctrl >> 2) & 1,
            "sts_bg_op": sts & 1,
            "sts_rc": (sts >> 32) & 0xffff,
            "bg_opcode": bg & 0xffff,
            "bg_pct": (bg >> 16) & 0x7f,
            "bg_rc": (bg >> 32) & 0xffff,
        }


def send(memdev, cmd_id, opcode, payload, out_size):
    inbuf = ctypes.create_string_buffer(payload, len(payload) or 1)
    outbuf = ctypes.create_string_buffer(out_size or 1)
    req = bytearray(struct.pack(
        "<IIHHIIIQIIQ", cmd_id, 0, opcode, 0, 0,
        len(payload), 0, ctypes.addressof(inbuf) if payload else 0,
        out_size, 0, ctypes.addressof(outbuf) if out_size else 0))
    err = 0
    fd = os.open("/dev/cxl/" + memdev, os.O_RDWR)
    t0 = time.monotonic()
    try:
        fcntl.ioctl(fd, CXL_MEM_SEND_COMMAND, req)
    except OSError as e:
        err = e.errno
    ms = (time.monotonic() - t0) * 1000
    os.close(fd)
    retval, = struct.unpack_from("<I", req, 12)
    osz, = struct.unpack_from("<I", req, 32)
    print("errno=%s retval=0x%x ms=%d out=%s" % (
        errno.errorcode.get(err, err) if err else 0, retval, ms,
        outbuf.raw[:osz].hex() if not err else ""))
    return 1 if err else 0


def hammer(memdev, secs, nscan, nplain):
    """Background and plain commands back to back from several threads.

    Prints "done <ioctls>" or, if any thread makes no progress for 15
    seconds, "hung" - and in that case the process cannot be expected
    to exit, its threads sleep uninterruptibly in the kernel.
    """
    import threading
    scan = struct.pack("<QQB", 0, 1, 1)          # one cache line, 1ms
    end = time.monotonic() + secs
    beat = [time.monotonic()] * (nscan + nplain)
    count = [0] * (nscan + nplain)

    def worker(i, opcode, payload, out_size):
        inbuf = ctypes.create_string_buffer(payload, len(payload) or 1)
        outbuf = ctypes.create_string_buffer(out_size or 1)
        fd = os.open("/dev/cxl/" + memdev, os.O_RDWR)
        while time.monotonic() < end:
            req = bytearray(struct.pack(
                "<IIHHIIIQIIQ", CMD_ID_RAW, 0, opcode, 0, 0,
                len(payload), 0, ctypes.addressof(inbuf) if payload else 0,
                out_size, 0, ctypes.addressof(outbuf) if out_size else 0))
            try:
                fcntl.ioctl(fd, CXL_MEM_SEND_COMMAND, req)
            except OSError:
                pass
            beat[i] = time.monotonic()
            count[i] += 1

    for i in range(nscan):
        threading.Thread(target=worker, args=(i, 0x4304, scan, 0),
                         daemon=True).start()
    for i in range(nscan, nscan + nplain):
        threading.Thread(target=worker, args=(i, 0x4000, b"", 0x43),
                         daemon=True).start()
    while time.monotonic() < end + 1:
        time.sleep(0.5)
        if time.monotonic() - min(beat) > 15 and time.monotonic() < end:
            print("hung after %d ioctls" % sum(count), flush=True)
            os._exit(2)
    print("done %d" % sum(count), flush=True)
    os._exit(0)


def race(memdev, secs):
    """One background command aimed at the poller's first deadline.

    A long Scan Media arms the poller for one second later. Three
    threads keep the mbox_mutex held with large payloads, so that the
    poller blocks on it when it fires; a single further background
    command, swept across that instant round after round, then finds
    the operation aborted with the poller neither pending nor done.
    """
    import threading
    long_scan = struct.pack("<QQB", 0, (768 << 20) // 64, 1)
    junk = bytes(2000)
    stop = time.monotonic() + secs
    beat = [time.monotonic()]
    rounds = [0]

    def ioctl(fd, opcode, payload):
        inbuf = ctypes.create_string_buffer(payload, len(payload) or 1)
        req = bytearray(struct.pack(
            "<IIHHIIIQIIQ", CMD_ID_RAW, 0, opcode, 0, 0,
            len(payload), 0, ctypes.addressof(inbuf), 0, 0, 0))
        try:
            fcntl.ioctl(fd, CXL_MEM_SEND_COMMAND, req)
        except OSError:
            pass

    def holder():
        fd = os.open("/dev/cxl/" + memdev, os.O_RDWR)
        while time.monotonic() < stop:
            ioctl(fd, 0x4000, junk)      # refused, after the copy in

    def shooter():
        fd = os.open("/dev/cxl/" + memdev, os.O_RDWR)
        while time.monotonic() < stop:
            ioctl(fd, 0x4304, long_scan)
            t0 = time.monotonic()
            # -2ms .. +8ms around the deadline, in 0.25ms steps
            at = t0 + 0.998 + (rounds[0] % 40) * 0.00025
            while time.monotonic() < at:
                pass
            rounds[0] += 1
            beat[0] = time.monotonic()

    for _ in range(3):
        threading.Thread(target=holder, daemon=True).start()
    threading.Thread(target=shooter, daemon=True).start()
    while time.monotonic() < stop + 1:
        time.sleep(0.5)
        if time.monotonic() - beat[0] > 15 and time.monotonic() < stop:
            print("hung after %d rounds" % rounds[0], flush=True)
            os._exit(2)
    print("done %d" % rounds[0], flush=True)
    os._exit(0)


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__ or "usage: cxlmbox.py regs|raw|cmd <memN> ...")
    what, memdev = argv[1], argv[2]
    if what == "regs":
        print(" ".join("%s=%s" % (k, ("0x%x" % v) if k.endswith(("rc", "opcode")) else v)
                       for k, v in Mailbox(memdev).regs().items()))
        return 0
    if what == "race":
        return race(memdev, float(argv[3]))
    if what == "hammer":
        return hammer(memdev, float(argv[3]), int(argv[4]), int(argv[5]))
    args = argv[3:]
    out_size = 0
    if "--out" in args:
        i = args.index("--out")
        out_size = int(args[i + 1], 0)
        del args[i:i + 2]
    num = int(args[0], 0)
    payload = bytes.fromhex(args[1]) if len(args) > 1 else b""
    if what == "raw":
        return send(memdev, CMD_ID_RAW, num, payload, out_size)
    if what == "cmd":
        return send(memdev, num, 0, payload, out_size)
    raise SystemExit("unknown subcommand " + what)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

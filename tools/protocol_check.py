#!/usr/bin/env python3
"""Read-only check that mirrors the app's protocol code (Poolside/Protocol).

Use it from a Mac to see whether your adapter answers before you debug the app:

    python3 tools/protocol_check.py --discover
    python3 tools/protocol_check.py --host 192.168.1.50
    python3 tools/protocol_check.py --remote "Pentair: 12-34-56" --password 1234

It logs in, reads the config and the current status, and prints them. It never
changes anything on the pool.
"""
import argparse
import socket
import struct

DISPATCHER = ("screenlogicserver.pentair.com", 500)


class Writer:
    def __init__(self):
        self.data = b""

    def int32(self, v):
        self.data += struct.pack("<i", v)

    def string(self, s):
        b = s.encode()
        self.array(b)

    def array(self, b):
        self.int32(len(b))
        self.data += b + b"\0" * ((4 - len(b) % 4) % 4)


class Reader:
    def __init__(self, data):
        self.data, self.off = data, 0

    def take(self, n):
        if self.off + n > len(self.data):
            raise ValueError("truncated")
        out = self.data[self.off:self.off + n]
        self.off += n
        return out

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def int32(self):
        return struct.unpack("<i", self.take(4))[0]

    def string(self):
        n = self.int32()
        s = self.take(n)
        self.take((4 - n % 4) % 4)
        return s.decode(errors="replace").strip("\0")


class Conn:
    def __init__(self, host, port, timeout=8):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.buf = b""

    def send(self, code, payload=b""):
        self.sock.sendall(struct.pack("<HHI", 0, code, len(payload)) + payload)

    def recv(self):
        while True:
            if len(self.buf) >= 8:
                _, code, n = struct.unpack_from("<HHI", self.buf)
                if len(self.buf) >= 8 + n:
                    body, self.buf = self.buf[8:8 + n], self.buf[8 + n:]
                    return code, body
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk

    def request(self, code, payload=b"", expect=None):
        self.send(code, payload)
        expect = expect or {code + 1}
        while True:
            got, body = self.recv()
            if got in expect:
                return got, body
            if got in (13, 30, 31):
                raise RuntimeError(f"rejected with {got}")


def encrypt_password(password, challenge):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    key = password.encode()
    key = key.ljust(16 if len(key) <= 16 else 32, b"\0")
    block = challenge.encode()[:16].ljust(16, b"\0")
    return Cipher(algorithms.AES(key), modes.ECB()).encryptor().update(block)


def login(conn, password):
    conn.sock.sendall(b"CONNECTSERVERHOST\r\n\r\n")
    _, body = conn.request(14)
    challenge = Reader(body).string()
    w = Writer()
    w.int32(348)
    w.int32(0)
    w.string("Android")
    w.array(encrypt_password(password, challenge) if password else bytes(16))
    w.int32(2)
    code, _ = conn.request(27, w.data, expect={28, 13})
    if code == 13:
        raise RuntimeError("password rejected")
    return challenge


def read_config(conn):
    w = Writer()
    w.int32(0)
    w.int32(0)
    _, body = conn.request(12532, w.data)
    r = Reader(body)
    r.int32()
    limits = [(r.u8(), r.u8()) for _ in range(2)]
    celsius = r.u8() != 0
    r.u8(), r.u8(), r.u8()
    flags = r.int32()
    r.string()
    circuits = []
    for _ in range(r.int32()):
        cid = r.int32()
        name = r.string()
        r.u8()
        func, iface = r.u8(), r.u8()
        r.take(5)
        r.u16()
        r.take(2)
        circuits.append((cid, name, func, iface))
    return {"limits": limits, "celsius": celsius, "solar": bool(flags & 1),
            "intellibrite": bool(flags & 8), "circuits": circuits}


def read_state(conn):
    w = Writer()
    w.int32(0)
    _, body = conn.request(12526, w.data)
    r = Reader(body)
    r.int32()
    freeze = r.u8() != 0
    r.take(4 + 3)
    air = r.int32()
    bodies = {}
    for _ in range(min(max(r.int32(), 0), 2)):
        t = r.int32()
        bodies[t] = dict(temp=r.int32(), heat_status=r.int32(), set=r.int32(), cool=r.int32(), mode=r.int32())
    circuits = {}
    for _ in range(r.int32()):
        cid, on = r.int32(), r.int32()
        r.take(4)
        circuits[cid] = bool(on)
    return {"air": air, "freeze": freeze, "bodies": bodies, "circuits": circuits}


DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def read_schedules(conn, kind):
    """kind 0 = recurring, 1 = run once. Read-only (message 12542)."""
    w = Writer()
    w.int32(0)
    w.int32(kind)
    _, body = conn.request(12542, w.data)
    r = Reader(body)
    events = []
    for _ in range(r.int32()):
        sid, cid, start, stop, days, flags, heat_cmd, heat_set = (r.int32() for _ in range(8))
        events.append(dict(id=sid - 699, circuit=cid, start=start, stop=stop, days=days,
                           flags=flags, heat_cmd=heat_cmd, heat_set=heat_set))
    return events


def hhmm(minutes):
    h, m = divmod(minutes, 60)
    return f"{(h % 12) or 12}:{m:02d} {'AM' if h < 12 else 'PM'}"


def discover(timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(timeout)
    s.sendto(bytes([1, 0, 0, 0, 0, 0, 0, 0]), ("255.255.255.255", 1444))
    found = []
    try:
        while True:
            data, addr = s.recvfrom(512)
            if len(data) >= 40 and struct.unpack_from("<i", data)[0] == 2:
                port = struct.unpack_from("<H", data, 8)[0]
                name = data[12:40].split(b"\0")[0].decode()
                found.append((addr[0], port, name))
    except socket.timeout:
        pass
    return found


def locate(system_name):
    conn = Conn(*DISPATCHER)
    w = Writer()
    w.string(system_name)
    w.string(system_name)
    _, body = conn.request(18003, w.data)
    r = Reader(body)
    found, license_ok = r.u8() != 0, r.u8() != 0
    host = r.string()
    port = r.u16()
    return found, host, port


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--discover", action="store_true")
    p.add_argument("--host")
    p.add_argument("--port", type=int, default=80)
    p.add_argument("--remote", metavar="SYSTEM_NAME")
    p.add_argument("--password")
    p.add_argument("--schedules", action="store_true", help="also print the schedules")
    a = p.parse_args()

    if a.discover:
        for host, port, name in discover():
            print(f"{name} at {host}:{port}")
        return
    if a.remote:
        found, host, port = locate(a.remote)
        print(f"dispatcher: found={found} at {host}:{port}")
        if not found:
            return
        a.host, a.port = host, port
    if not a.host:
        p.error("give --discover, --host or --remote")

    conn = Conn(a.host, a.port)
    challenge = login(conn, a.password)
    print(f"logged in, adapter {challenge}")
    cfg = read_config(conn)
    st = read_state(conn)
    unit = "C" if cfg["celsius"] else "F"
    print(f"air {st['air']}°{unit}, freeze={st['freeze']}, solar={cfg['solar']}, intellibrite={cfg['intellibrite']}")
    for t, b in sorted(st["bodies"].items()):
        lo, hi = cfg["limits"][t]
        print(f"{'pool' if t == 0 else 'spa'}: {b['temp']}°, set {b['set']}° ({lo}-{hi}), mode {b['mode']}, heating {b['heat_status']}")
    for cid, name, func, iface in cfg["circuits"]:
        print(f"  {cid} {name:<18} function {func:>2} tab {iface}  {'ON' if st['circuits'].get(cid) else 'off'}")
    if a.schedules:
        names = {cid: name for cid, name, _, _ in cfg["circuits"]}
        for kind, label in ((0, "Recurring schedules"), (1, "Run-once schedules")):
            events = read_schedules(conn, kind)
            print(f"\n{label}: {len(events)}")
            for e in events:
                days = ", ".join(d for i, d in enumerate(DAYS) if e["days"] >> i & 1) or "none"
                print(f"  #{e['id']} {names.get(e['circuit'], e['circuit'])}: {hhmm(e['start'])} to {hhmm(e['stop'])}, {days}"
                      f"  (flags {e['flags']}, heat cmd {e['heat_cmd']}, set {e['heat_set']})")


if __name__ == "__main__":
    main()

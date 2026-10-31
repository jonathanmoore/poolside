#!/usr/bin/env python3
"""Fake Pentair ScreenLogic adapter for testing Poolside without touching the real pool.

Run it on your Mac, then in the app pick Home WiFi and type the Mac's IP and port.

    python3 tools/mock_gateway.py --port 8080

It answers discovery on UDP 1444, the TCP login handshake, config and status reads,
and the circuit, heat and light commands. State lives in memory only.
If the `cryptography` package is installed and --password is set, it checks the
encrypted password like a real adapter does for remote logins.
"""
import argparse
import socket
import socketserver
import struct
import threading

MAC = "00-C0-33-AB-CD-EF"
NAME = "Pentair: AB-CD-EF"

state = {
    "air": 78,
    "bodies": {0: {"temp": 74, "heat_status": 0, "set": 84, "mode": 0},
               1: {"temp": 99, "heat_status": 0, "set": 102, "mode": 3}},
    # raw id: [name, function, interface, on]
    "circuits": {
        500: ["Spa", 1, 1, False],
        505: ["Pool", 2, 0, True],
        501: ["Cleaner", 5, 0, True],
        502: ["Air Blower", 0, 1, False],
        503: ["Water Feature", 0, 2, False],
        504: ["Pool Light", 16, 4, False],
        506: ["Spa Light", 16, 4, False],
        507: ["Pool High", 0, 2, False],
    },
}
lock = threading.Lock()
password = None


def sl_string(s):
    b = s.encode()
    return struct.pack("<i", len(b)) + b + b"\0" * ((4 - len(b) % 4) % 4)


def msg(code, payload=b""):
    return struct.pack("<HHI", 0, code, len(payload)) + payload


def config_payload():
    p = struct.pack("<i", 100)                 # controller id
    p += bytes([40, 104, 40, 104])             # min/max setpoint pool, spa
    p += bytes([0, 13, 0, 0])                  # degC, controller type, hw type, data
    p += struct.pack("<i", 0x8)                # equipment flags: IntelliBrite
    p += sl_string("Water Features")
    circuits = state["circuits"]
    p += struct.pack("<i", len(circuits))
    for cid, (name, func, iface, _) in sorted(circuits.items()):
        p += struct.pack("<i", cid) + sl_string(name)
        p += bytes([0, func, iface, 0, 0, 0, 0, cid - 499])
        p += struct.pack("<H", 720) + b"\0\0"
    p += struct.pack("<i", 0)                  # color table
    p += bytes(8)                              # pump circuits
    p += struct.pack("<ii", 0, 0)              # tab flags, show alarms
    return p


def status_payload():
    p = struct.pack("<i", 0) + bytes([0, 0, 0, 0, 0]) + bytes(3)
    p += struct.pack("<ii", state["air"], 2)
    for body_type in (0, 1):
        b = state["bodies"][body_type]
        p += struct.pack("<iiiiii", body_type, b["temp"], b["heat_status"], b["set"], 0, b["mode"])
    circuits = state["circuits"]
    p += struct.pack("<i", len(circuits))
    for cid, c in sorted(circuits.items()):
        p += struct.pack("<ii", cid, 1 if c[3] else 0) + bytes(4)
    p += struct.pack("<iiiiiii", 750, 700, 0, 64, 0, 0, 0)
    return p


def expected_password():
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError:
        return None
    key = password.encode()
    key = key.ljust(16 if len(key) <= 16 else 32, b"\0")
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(MAC.encode()[:16].ljust(16, b"\0"))


def handle(code, body):
    with lock:
        if code == 14:
            return msg(15, sl_string(MAC))
        if code == 27:
            if password:
                # schema, type, version string, then the 16 byte password array
                off = 8
                n = struct.unpack_from("<i", body, off)[0]
                off += 4 + n + (4 - n % 4) % 4 + 4
                sent = body[off:off + 16]
                want = expected_password()
                if want is not None and sent != want:
                    return msg(13)
            return msg(28)
        if code == 16:
            return msg(17)
        if code == 12532:
            return msg(12533, config_payload())
        if code == 12526:
            return msg(12527, status_payload())
        if code == 12530:
            _, cid, on = struct.unpack_from("<iii", body)
            if cid not in state["circuits"]:
                return msg(31)
            state["circuits"][cid][3] = bool(on)
            return msg(12531)
        if code == 12528:
            _, body_type, temp = struct.unpack_from("<iii", body)
            state["bodies"][body_type]["set"] = temp
            return msg(12529)
        if code == 12538:
            _, body_type, mode = struct.unpack_from("<iii", body)
            b = state["bodies"][body_type]
            b["mode"] = mode
            b["heat_status"] = 2 if mode and b["set"] > b["temp"] else 0
            return msg(12539)
        if code == 12556:
            _, command = struct.unpack_from("<ii", body)
            if command in (0, 1):
                for c in state["circuits"].values():
                    if c[1] == 16:
                        c[3] = bool(command)
            return msg(12557)
        return msg(30)


class Gateway(socketserver.BaseRequestHandler):
    def handle(self):
        buf = b""
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            buf += data
            if buf.startswith(b"CONNECTSERVERHOST"):
                end = buf.find(b"\r\n\r\n")
                if end < 0:
                    continue
                buf = buf[end + 4:]
            while len(buf) >= 8:
                _, code, length = struct.unpack_from("<HHI", buf)
                if len(buf) < 8 + length:
                    break
                body, buf = buf[8:8 + length], buf[8 + length:]
                print(f"<- {code}", flush=True)
                self.request.sendall(handle(code, body))


def discovery(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 1444))
    name = NAME.encode().ljust(28, b"\0")
    while True:
        data, addr = sock.recvfrom(64)
        if len(data) == 8 and data[0] == 1:
            reply = struct.pack("<i", 2) + bytes(4) + struct.pack("<hBB", port, 2, 12) + name
            sock.sendto(reply, addr)
            print(f"discovery reply to {addr[0]}", flush=True)


def main():
    global password
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--password", default=None)
    parser.add_argument("--no-discovery", action="store_true")
    args = parser.parse_args()
    password = args.password
    if not args.no_discovery:
        threading.Thread(target=discovery, args=(args.port,), daemon=True).start()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("", args.port), Gateway) as server:
        print(f"Mock {NAME} on TCP {args.port}" + ("" if args.no_discovery else ", discovery on UDP 1444"), flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()

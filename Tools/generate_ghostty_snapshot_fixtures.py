#!/usr/bin/env python3
"""Regenerates Tests/SwiftTermTests/GhosttySnapshotScenarios.swift.

Each scenario is a piece of terminal output. This script has a Ghostty core run it, through a
private Rex server, and records the snapshot that core makes of the result. The tests then feed
the same output to SwiftTerm directly, restore a second terminal from the snapshot, and compare
the two cell by cell. So the fixtures are what lets the tests check the reader against Ghostty
itself, and they only need regenerating to add a scenario or follow a new snapshot format.

The tests need only the generated file. Running this script needs a Rex server, API revision 8:

    rex server run --listen unix:///tmp/fx/r.sock --state-dir /tmp/fx/state --restore=false
    python3 Tools/generate_ghostty_snapshot_fixtures.py /tmp/fx/r.sock \\
        Tests/SwiftTermTests/GhosttySnapshotScenarios.swift
"""
import base64, json, os, socket, struct, sys, tempfile, time

E = "\x1b"
def scenarios():
    s = {}
    s["plain"] = "hello\r\nworld"
    s["styles"] = (f"{E}[1mbold{E}[0m {E}[2mfaint{E}[0m {E}[3mitalic{E}[0m {E}[5mblink{E}[0m {E}[7minv{E}[0m {E}[8mhid{E}[0m {E}[9mstrike{E}[0m\r\n"
                   f"{E}[4msingle{E}[0m {E}[4:2mdouble{E}[0m {E}[4:3mcurly{E}[0m {E}[4:4mdot{E}[0m {E}[4:5mdash{E}[0m\r\n"
                   f"{E}[31mred{E}[0m {E}[92mbright{E}[0m {E}[38;5;200mp200{E}[0m {E}[38;2;1;2;3mrgb{E}[0m {E}[48;5;33mbgp{E}[0m {E}[48;2;9;8;7mbgrgb{E}[0m\r\n"
                   f"{E}[4;58;5;9mulp{E}[0m {E}[4;58;2;4;5;6mulrgb{E}[0m\r\n"
                   f"{E}[41m{E}[Kred to the edge{E}[0m\r\n{E}[48;2;10;20;30m{E}[K{E}[0m\r\nend {E}[1;31;44mpen stays")
    s["scrollback"] = "".join(f"{E}[3{i%8}mline {i}{E}[0m\r\n" for i in range(60)) + "x" * 100 + "\r\nafter the long one"
    s["wide"] = (f"{E}[?2027h" + "你好世界 ok\r\n" + "a" * 39 + "好 wrapped wide\r\n" + "é combining\r\n" + "👍🏽 skin\r\n" + "👨‍👩‍👧 family\r\n" + "🇫🇷 flag\r\nend")
    s["links"] = (f"{E}]8;;https://example.com/a{E}\\first{E}]8;;{E}\\ plain {E}]8;id=abc;https://example.com/b{E}\\second{E}]8;;{E}\\\r\n"
                  f"{E}]8;id=abc;https://example.com/b{E}\\second again{E}]8;;{E}\\\r\n{E}]8;;https://example.com/open{E}\\still open: ")
    s["modes"] = (f"{E}[?1h{E}[?2004h{E}[?1000h{E}[?1006h{E}[?1004h{E}[?7l{E}[?45h{E}[?66h{E}[?25l{E}[4h{E}[20h{E}[?1007l{E}[?12h"
                  f"text{E}[5;20Hat")
    s["region"] = f"{E}[2;8r{E}[?6h{E}[3;4Hin the region"
    s["margins"] = f"{E}[?69h{E}[5;30s{E}[2;8r{E}[4;10Hmargins"
    s["tabs"] = f"{E}[3g{E}[1;5H{E}H{E}[1;17H{E}H{E}[1;33H{E}H{E}[2;1H\ta\tb\tc"
    s["saved"] = f"{E}[3;7H{E}[1;35m{E}7{E}[0m{E}[9;1Hmoved{E}[?1000h{E}[?1000s{E}[?1000l"
    s["title"] = f"{E}]2;A title{E}\\{E}]7;file://localhost/tmp/place{E}\\text"
    s["palette"] = f"{E}]10;rgb:01/02/03{E}\\{E}]11;rgb:04/05/06{E}\\{E}]12;rgb:07/08/09{E}\\{E}]4;1;rgb:12/34/56{E}\\{E}]4;200;rgb:aa/bb/cc{E}\\{E}[31mred"
    s["keyboard"] = f"{E}[>1u{E}[>5ukb"
    s["cursorstyle"] = f"{E}[5 qbar"
    s["alt"] = f"normal text\r\nsecond{E}[?1049h{E}[2;3Halt text{E}[1m pen"
    s["altleft"] = f"normal{E}[?1049halt{E}[?1049lback"
    s["pending"] = "z" * 40
    s["partialcsi"] = f"before{E}[3"
    s["partialosc"] = f"before{E}]2;ti"
    s["partialutf8"] = "before\xe4\xbd"  # Marked below: raw bytes, the start of a scalar.
    s["charset"] = f"{E}(0lqk{E}(B plain {E}(Apound#{E}(B"
    s["protected"] = f'{E}[1"qguarded{E}[0"q free'
    s["prompts"] = f"{E}]133;A{E}\\$ {E}]133;B{E}\\ls{E}]133;C{E}\\\r\nout\r\n{E}]133;D;0{E}\\{E}]133;A{E}\\$ "
    s["widenographeme"] = "你好 e\u0301 ok\r\n" + "b" * 39 + "好 wrapped"
    s["charsetopen"] = f"plain{E}(0lqk"
    s["charsetshift"] = f"{E})0plain\x0elqk"
    s["protectedopen"] = f'{E}[1"qguarded'
    s["altkeep"] = f"normal{E}[?47halt text{E}[?47lback"
    s["altscrollback"] = "".join(f"line {i}\r\n" for i in range(30)) + f"{E}[?1049h{E}[3;3H{E}[42malt on green{E}[K"
    s["savedopen"] = f"{E}[5;9H{E}[32m{E}7{E}[0m{E}[1;1Hhome"
    s["savedmodes"] = f"{E}[?1000h{E}[?2004h{E}[?1000;2004s{E}[?1000l{E}[?2004l"
    s["keyboardstack"] = f"{E}[>1u{E}[>3u{E}[>7u"
    s["pages"] = "".join(f"{i}\r\n" for i in range(1400)) + "the end"
    s["empty"] = ""
    return s
RAW = {"partialutf8": "before".encode() + b"\xe4\xbd"}

class WS:
    def __init__(self, path, proto, sock):
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(sock); self.buf = b""
        self.s.sendall((f"GET {path} HTTP/1.1\r\nHost: l\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\nSec-WebSocket-Version: 13\r\n"
                        f"Sec-WebSocket-Protocol: {proto}\r\n\r\n").encode())
        while b"\r\n\r\n" not in self.buf: self.buf += self.s.recv(65536)
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        assert b" 101 " in head.split(b"\r\n")[0], head
    def send(self, data, op):
        h = bytes([0x80 | op]); n = len(data); m = os.urandom(4)
        h += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.s.sendall(h + m + bytes(b ^ m[i & 3] for i, b in enumerate(data)))
    def recv(self):
        while True:
            while len(self.buf) < 2: self.more()
            n = self.buf[1] & 0x7f; at = 2
            if n == 126:
                while len(self.buf) < 4: self.more()
                n = struct.unpack(">H", self.buf[2:4])[0]; at = 4
            elif n == 127:
                while len(self.buf) < 10: self.more()
                n = struct.unpack(">Q", self.buf[2:10])[0]; at = 10
            while len(self.buf) < at + n: self.more()
            op = self.buf[0] & 15; p = self.buf[at:at + n]; self.buf = self.buf[at + n:]
            if op == 9: self.send(p, 10); continue
            if op == 8: raise EOFError
            if op in (1, 2): return p
    def more(self):
        d = self.s.recv(1 << 16)
        if not d: raise EOFError
        self.buf += d

sock = sys.argv[1]
ctl = WS("/api/control", "rex.control.v1", sock)
ctl.send(json.dumps({"type": "hello", "api_revision": 8, "api_min_revision": 8, "client": {"kind": "app", "name": "fx", "version": "1", "platform": "macos"}}).encode(), 1)
nid = 0
def call(method, payload):
    global nid
    nid += 1; i = f"f{nid}"
    ctl.send(json.dumps({"type": "request", "id": i, "method": method, "payload": payload}).encode(), 1)
    while True:
        m = json.loads(ctl.recv())
        if m.get("type") == "response" and m.get("id") == i:
            if m.get("error"): raise RuntimeError(m["error"])
            return m.get("payload")

def capture(name, vt):
    with tempfile.NamedTemporaryFile(delete=False) as f: f.write(vt)
    made = call("session.create", {"label": name, "initial_windows": [{"window_label": name, "layout": {"block": {"flavor": "com.superlogical.terminal.shell",
        "options": {"shell": "none", "command": ["/bin/sh", "-c", f"cat {f.name}; exec sleep 300"], "size": {"columns": 40, "rows": 10}}}}}]})
    sid = made["session_id"]
    view = call("session.attach", {"session_id": sid})["view"]
    bid = view["windows"][0]["layers"][0]["blocks"][0]["block_id"]
    time.sleep(0.4)
    t = call("data.connect", {"session_id": sid, "block_id": bid, "data_ref_id": "terminal", "subprotocol": "rex.data.terminal.v1"})["ticket"]
    raw = base64.urlsafe_b64decode(t + "=" * (-len(t) % 4))
    d = WS("/api/data", "rex.data.terminal.v1", sock)
    d.send(b"\x01" + raw, 2)
    first = d.recv(); assert first[0] == 0x81, first[:2]
    data = first[32:]
    while True:
        at = 10; end = None
        while len(data) >= at + 10:
            tag, n = struct.unpack("<HI", data[at:at + 6])
            nxt = at + 10 + n
            if len(data) < nxt: break
            if tag == 6: end = nxt; break
            at = nxt
        if end: break
        data += d.recv()
    d.s.close()
    call("session.destroy", {"session_id": sid})
    os.unlink(f.name)
    return data[:end]

out = ["// Generated from a Ghostty core: each scenario's output, and the snapshot Ghostty made of it.",
       "// The terminal is 40 columns by 10 rows. Regenerate with Tools/generate_ghostty_snapshot_fixtures.py.", "", "let ghosttySnapshotScenarios: [(name: String, output: String, snapshot: String)] = ["]
total = 0
for name, text in scenarios().items():
    vt = RAW.get(name, text.encode())
    snap = capture(name, vt); total += len(snap)
    out.append(f'    ("{name}", "{base64.b64encode(vt).decode()}",\n     "{base64.b64encode(snap).decode()}"),')
    print(name, len(vt), len(snap))
out.append("]\n")
open(sys.argv[2], "w").write("\n".join(out))
print("total", total)

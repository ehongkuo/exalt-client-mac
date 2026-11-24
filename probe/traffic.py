#!/usr/bin/env python3
"""Game traffic timing against a sync capture (issue #28, hardening plan Phase 2 item 2).

    probe/traffic.py record OUT.pcap            # until Ctrl-C; start it before the game
    probe/traffic.py analyze OUT.pcap [guard-N.tsv] [--json]

Decoding is a Python port of RealmHound's (MIT, github.com/pillarzz/RealmHound at 38d853f):
RC4 keys from crypto/keys.rs, framing from stream/reassembler.rs (4-byte big-endian size including
the 5-byte header, 1-byte type, RC4 over the payload only, cipher continuous per direction from the
connection's first byte) and the NewTick, Move and PlayerHit layouts from protocol/packets/.
Only the fields below are kept: no payload, Hello ticket or name is stored or printed.

shortcut: connections must be caught from their SYN (no mid-stream tick alignment); start the
recorder before the game. Mid-stream connections are skipped and counted.
"""
import argparse
import json
import os
import signal
import struct
import subprocess
import sys
from pathlib import Path

INCOMING_KEY = bytes.fromhex('c91d9eec420160730d825604e0')
OUTGOING_KEY = bytes.fromhex('5a4d2016bc16dc64883194ffd9')
PORT = 2050
NEWTICK, MOVE, PLAYERHIT, GROUNDDAMAGE, AOEACK = 10, 62, 90, 103, 89


class RC4:
    def __init__(self, key):
        s = list(range(256)); j = 0
        for i in range(256):
            j = (j + s[i] + key[i % len(key)]) & 255; s[i], s[j] = s[j], s[i]
        self.s, self.i, self.j = s, 0, 0

    def apply(self, data):
        s, i, j, out = self.s, self.i, self.j, bytearray(data)
        for n in range(len(out)):
            i = (i + 1) & 255; j = (j + s[i]) & 255; s[i], s[j] = s[j], s[i]
            out[n] ^= s[(s[i] + s[j]) & 255]
        self.i, self.j = i, j
        return bytes(out)


def frames(path):
    """(seconds, link-layer type, bytes) from a classic pcap file."""
    data = Path(path).read_bytes()
    magic = data[:4]
    order = {b'\xd4\xc3\xb2\xa1': '<', b'\xa1\xb2\xc3\xd4': '>', b'\x4d\x3c\xb2\xa1': '<', b'\xa1\xb2\x3c\x4d': '>'}.get(magic)
    if not order: raise SystemExit(f'{path}: not a classic pcap file')
    nano = magic in (b'\x4d\x3c\xb2\xa1', b'\xa1\xb2\x3c\x4d')
    link = struct.unpack(order + 'I', data[20:24])[0]
    at = 24
    while at + 16 <= len(data):
        sec, frac, size, _ = struct.unpack(order + 'IIII', data[at:at + 16]); at += 16
        yield sec + frac / (1e9 if nano else 1e6), link, data[at:at + size]; at += size


def segments(path):
    """IPv4 TCP segments on the game port: (t, src, sport, dst, dport, seq, ack, flags, payload)."""
    for t, link, raw in frames(path):
        if link == 1:
            if raw[12:14] != b'\x08\x00': continue
            ip = raw[14:]
        elif link in (0, 108):
            ip = raw[4:]
        elif link in (12, 101):
            ip = raw
        else:
            raise SystemExit(f'unsupported link type {link}')
        if len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 6: continue
        total = struct.unpack('>H', ip[2:4])[0] or len(ip)  # 0 with segmentation offload
        tcp = ip[(ip[0] & 15) * 4:min(total, len(ip))]
        if len(tcp) < 20: continue
        sport, dport, seq, ack = struct.unpack('>HHII', tcp[:12])
        if PORT not in (sport, dport): continue
        yield t, ip[12:16], sport, ip[16:20], dport, seq, ack, tcp[13], tcp[(tcp[12] >> 4) * 4:]


class Direction:
    """One direction of a connection: reassembles, decrypts and frames, keeping per-message timing."""
    def __init__(self, isn, key):
        self.base = (isn + 1) & 0xffffffff   # absolute seq of stream byte 0
        self.cipher, self.buf, self.next, self.pending = RC4(key), b'', 0, {}
        self.messages, self.retransmits = [], 0

    def add(self, t, seq, payload):
        off = (seq - self.base) & 0xffffffff
        if off >= 0x80000000 or off + len(payload) <= self.next:
            if payload: self.retransmits += 1
            return
        if off > self.next:
            self.pending.setdefault(off, (t, payload)); return
        self._append(t, payload[self.next - off:])
        while self.next in self.pending:
            t2, p2 = self.pending.pop(self.next); self._append(t2, p2)
        for o in [o for o in self.pending if o + len(self.pending[o][1]) <= self.next]: del self.pending[o]

    def _append(self, t, chunk):
        self.buf += chunk; self.next += len(chunk)
        while len(self.buf) >= 5:
            size, kind = struct.unpack('>IB', self.buf[:5])
            if size < 5 or size > 1 << 20: raise ValueError(f'bad frame size {size}')
            if len(self.buf) < size: break
            body = self.cipher.apply(self.buf[5:size])  # every payload, in order, keeps the cipher in step
            end = self.next - len(self.buf) + size     # stream offset after this message's last byte
            self.buf = self.buf[size:]
            fields = decode(kind, body)
            if fields is not None:
                self.messages.append(dict(t=t, kind=kind, end=(self.base + end) & 0xffffffff, **fields))


def decode(kind, b):
    try:
        if kind == NEWTICK:
            tick, interval, server, rtt = struct.unpack('>iiIH', b[:14]); return dict(tick=tick, interval=interval, server=server, rtt=rtt)
        if kind == MOVE:
            tick, time = struct.unpack('>ii', b[:8]); return dict(tick=tick, time=time)
        if kind == PLAYERHIT:
            bullet, owner = struct.unpack('>hi', b[:6]); return dict(bullet=bullet & 0xffff, owner=owner & 0xffffffff)
        if kind in (GROUNDDAMAGE, AOEACK):
            return dict(time=struct.unpack('>i', b[:4])[0])
    except struct.error:
        return None
    return None


def connections(path):
    """Decoded connections caught from their SYN, plus server ACK times, and a count of skipped flows."""
    conns, skipped = {}, set()
    for t, src, sport, dst, dport, seq, ack, flags, payload in segments(path):
        out = dport == PORT
        key = (src, sport, dst, dport) if out else (dst, dport, src, sport)
        if flags & 0x02:  # SYN
            if out and not flags & 0x10:
                conns[key] = dict(start=t, up=Direction(seq, OUTGOING_KEY), down=None, acks=[])
            elif key in conns and not out:
                conns[key]['down'] = Direction(seq, INCOMING_KEY)
            continue
        c = conns.get(key)
        if not c or (not out and c['down'] is None):
            skipped.add(key); continue
        if not out and flags & 0x10: c['acks'].append((t, ack))
        if payload:
            try: (c['up'] if out else c['down']).add(t, seq, payload)
            except ValueError as error: c['error'] = str(error)
    return list(conns.values()), len(skipped - set(conns))


def first_ack(acks, end, after):
    """Arrival of the first server ACK covering `end` (absolute seq) at or after `after`."""
    for t, a in acks:
        if t >= after and ((a - end) & 0xffffffff) < 0x80000000: return t
    return None


def pct(values, *ps):
    v = sorted(values)
    return {f'p{p}': round(v[min(len(v) - 1, int(p / 100 * len(v)))], 1) for p in ps} if v else {}


def stats(values):
    return dict(n=len(values), min=round(min(values), 1), **pct(values, 50, 90, 99), max=round(max(values), 1)) if values else dict(n=0)


def analyze(pcap, guard=None):
    conns, skipped = connections(pcap)
    report = dict(connections=len(conns), skipped_midstream=skipped,
                  decode_errors=[c['error'] for c in conns if 'error' in c],
                  retransmits_up=sum(c['up'].retransmits for c in conns),
                  retransmits_down=sum(c['down'].retransmits for c in conns if c['down']))
    ticks, moves, hits, upload, turnaround, field_vs, step_errors = [], [], [], [], [], [], 0
    hit_upload, move_upload = [], []
    for c in conns:
        if not c['down']: continue
        down = [m for m in c['down'].messages if m['kind'] == NEWTICK]
        up = c['up'].messages
        step_errors += sum(b['tick'] != a['tick'] + 1 for a, b in zip(down, down[1:]))
        arrive = {m['tick']: m for m in down}
        reply = {}
        for m in up:
            ack_t = first_ack(c['acks'], m['end'], m['t'])
            m['ack_ms'] = None if ack_t is None else (ack_t - m['t']) * 1e3
            if m['kind'] == MOVE:
                moves.append(m); reply.setdefault(m['tick'], m)
                if m['ack_ms'] is not None: move_upload.append(m['ack_ms'])
            elif m['kind'] == PLAYERHIT:
                hits.append(m)
                if m['ack_ms'] is not None: hit_upload.append(m['ack_ms'])
        # Local estimate of each reply's server-side round trip: NewTick arrival -> ACK of its Move.
        est = {}
        for k, m in reply.items():
            if k in arrive and m['ack_ms'] is not None:
                turn = (m['t'] - arrive[k]['t']) * 1e3; turnaround.append(turn); est[k] = turn + m['ack_ms']
        for n in down: n['est'] = {j: est.get(n['tick'] - j) for j in range(0, 6)}
        ticks += down
    report.update(ticks=len(ticks), tick_step_errors=step_errors, moves=len(moves), hits=len(hits),
                  turnaround_ms=stats(turnaround), move_ack_ms=stats(move_upload), hit_ack_ms=stats(hit_upload),
                  hits_unacked=sum(h['ack_ms'] is None for h in hits))
    # Which earlier reply does the field track?  Exact single measurement: one lag j fits tightly.
    lags = {}
    for j in range(0, 6):
        pairs = [(n['rtt'], n['est'][j]) for n in ticks if n['rtt'] and n['est'][j] is not None]
        if pairs:
            errs = [r - e for r, e in pairs]
            lags[j] = dict(n=len(pairs), median_field_minus_estimate=round(sorted(errs)[len(errs) // 2], 1),
                           median_abs_dev=round(sorted(abs(x - sorted(errs)[len(errs) // 2]) for x in errs)[len(errs) // 2], 1),
                           corr=round(corr([p[0] for p in pairs], [p[1] for p in pairs]), 3))
    report['field_vs_reply_lag'] = lags
    report['field_repeats'] = sum(b['rtt'] == a['rtt'] for a, b in zip(ticks, ticks[1:]))
    report['field_ms'] = stats([n['rtt'] for n in ticks if n['rtt']])
    if ticks:
        ref = min(n['t'] * 1e3 - n['server'] for n in ticks)
        report['download_above_min_ms'] = stats([n['t'] * 1e3 - n['server'] - ref for n in ticks])
    if guard: report['guard'] = compare(ticks, moves, hits, Path(guard).read_text(errors='replace'))
    return report


def corr(x, y):
    n = len(x)
    if n < 3: return 0.0
    mx, my = sum(x) / n, sum(y) / n
    sx = sum((a - mx) ** 2 for a in x) ** .5; sy = sum((b - my) ** 2 for b in y) ** .5
    return sum((a - mx) * (b - my) for a, b in zip(x, y)) / (sx * sy) if sx and sy else 0.0


def compare(ticks, moves, hits, log):
    """Match wire messages to guard events (phases 40-42) and bracket the clock offset."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from analyze import read_events
    events = read_events(log)
    g40 = {(e['tick_sequence'], e['server_time'] & 0xffffffff): e for e in events if e['phase'] == 40}
    g41 = {}
    for e in events:
        if e['phase'] == 41: g41.setdefault(e['tick_sequence'], []).append(e)
    g42 = {}
    for e in events:
        if e['phase'] == 42: g42.setdefault((e['owner'] & 0xffffffff, e['bullet'] & 0xffff), []).append(e)
    matched, mismatched, inbound, outbound = 0, [], [], []
    for n in ticks:
        e = g40.get((n['tick'], n['server']))
        if not e: continue
        matched += 1
        if e['bullet'] != n['rtt']: mismatched.append((n['tick'], e['bullet'], n['rtt']))
        inbound.append(e['ns'] / 1e6 - n['t'] * 1e3)      # guard clock - wire clock, plus wire-to-hook delay
    move_pairs = []
    for m in moves:
        for e in g41.get(m['tick'], []):
            move_pairs.append((m, e)); outbound.append(e['ns'] / 1e6 - m['t'] * 1e3); break
    hit_pairs = []
    for h in hits:
        for e in g42.get((h['owner'], h['bullet']), []):
            if not any(e is p[1] for p in hit_pairs):
                hit_pairs.append((h, e)); outbound.append(e['ns'] / 1e6 - h['t'] * 1e3); break
    out = dict(ticks_matched=matched, field_mismatches=len(mismatched), mismatch_examples=mismatched[:5],
               moves_matched=len(move_pairs), hits_matched=len(hit_pairs), hits_in_guard=sum(map(len, g42.values())))
    if inbound and outbound:
        lo, hi = max(outbound), min(inbound)  # offset o: outbound needs o >= g - w, inbound o <= g - w
        out['clock_offset_bracket_ms'] = dict(low=round(lo, 2), high=round(hi, 2), width=round(hi - lo, 2))
        o = lo if lo <= hi else (lo + hi) / 2
        out['hook_to_wire_ms'] = dict(moves=stats([(m['t'] * 1e3) - (e['ns'] / 1e6 - o) for m, e in move_pairs]),
                                      hits=stats([(h['t'] * 1e3) - (e['ns'] / 1e6 - o) for h, e in hit_pairs]))
        out['wire_to_hook_ms'] = stats([x - o for x in inbound])
        bound = [(h['t'] * 1e3 - (e['ns'] / 1e6 - o)) + h['ack_ms'] for h, e in hit_pairs if h['ack_ms'] is not None]
        out['hit_report_to_server_ack_ms'] = stats(bound)
    return out


def record(out):
    route = subprocess.run(['route', '-n', 'get', 'default'], capture_output=True, text=True).stdout
    iface = next((l.split(':', 1)[1].strip() for l in route.splitlines() if 'interface:' in l), 'en0')
    print(f'Recording tcp port {PORT} on {iface} to {out}; Ctrl-C to stop.', flush=True)
    p = subprocess.Popen(['tcpdump', '-i', iface, '-s', '0', '-U', '-w', out, f'tcp port {PORT}'])
    try: p.wait()
    except KeyboardInterrupt:
        p.send_signal(signal.SIGINT); p.wait()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('record'); r.add_argument('out')
    a = sub.add_parser('analyze'); a.add_argument('pcap'); a.add_argument('guard', nargs='?'); a.add_argument('--json', action='store_true')
    args = ap.parse_args()
    if args.cmd == 'record': return record(args.out)
    report = analyze(args.pcap, args.guard)
    print(json.dumps(report, indent=1 if not args.json else None))


if __name__ == '__main__':
    main()

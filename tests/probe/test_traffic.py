import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'probe'))
spec = importlib.util.spec_from_file_location('traffic', ROOT / 'probe/traffic.py')
traffic = importlib.util.module_from_spec(spec); spec.loader.exec_module(traffic)
from analyze import FIELDS

CLIENT, SERVER = bytes([10, 0, 0, 2]), bytes([192, 0, 2, 9])


def segment(t, out, seq, ack, flags, payload=b''):
    src, dst, sport, dport = (CLIENT, SERVER, 50000, 2050) if out else (SERVER, CLIENT, 2050, 50000)
    tcp = struct.pack('>HHIIBBHHH', sport, dport, seq, ack, 5 << 4, flags, 65535, 0, 0) + payload
    ip = struct.pack('>BBHHHBBH4s4s', 0x45, 0, 20 + len(tcp), 0, 0, 64, 6, 0, src, dst) + tcp
    frame = b'\0' * 12 + b'\x08\x00' + ip
    return struct.pack('<IIII', int(t), round(t % 1 * 1e6), len(frame), len(frame)) + frame


def message(cipher, kind, body):
    return struct.pack('>IB', 5 + len(body), kind) + cipher.apply(body)


class TrafficTests(unittest.TestCase):
    def test_rc4_vector(self):
        self.assertEqual(traffic.RC4(b'Key').apply(b'Plaintext').hex(), 'bbf316e8d940af0ad3')

    def test_decodes_timing_through_split_frames_and_retransmits(self):
        up, down = traffic.RC4(traffic.OUTGOING_KEY), traffic.RC4(traffic.INCOMING_KEY)
        hello = message(up, 74, b'secret-ticket' * 4)
        tick0 = message(down, 10, struct.pack('>iiIHh', 7, 200, 5000, 0, 0))
        tick1 = message(down, 10, struct.pack('>iiIHh', 8, 200, 5200, 151, 0))
        move = message(up, 62, struct.pack('>iih', 7, 1234, 0))
        hit = message(up, 90, struct.pack('>hi', 33, 4242))
        u, d = 1001, 9001  # stream byte 0 for each direction
        rows = [segment(0.000, True, 1000, 0, 0x02), segment(0.050, False, 9000, 1001, 0x12),
                segment(0.100, True, u, d, 0x18, hello),
                segment(1.000, False, d, u + len(hello), 0x18, tick0[:7]),           # split frame
                segment(1.010, False, d + 7, u + len(hello), 0x18, tick0[7:])]
        u += len(hello); d += len(tick0)
        rows += [segment(1.020, True, u, d, 0x18, move + hit),
                 segment(1.030, True, u, d, 0x18, move + hit),                       # retransmit
                 segment(1.075, False, d, u + len(move) + len(hit), 0x10),           # ACK covering both
                 segment(1.200, False, d, u + len(move) + len(hit), 0x18, tick1)]
        with tempfile.TemporaryDirectory() as folder:
            pcap = Path(folder) / 'c.pcap'
            pcap.write_bytes(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1) + b''.join(rows))
            ms = lambda s: int(s * 1e9) + 500_000_000  # guard clock = wire + 0.5 s
            guard = [dict(phase=40, ns=ms(1.012), tick_sequence=7, server_time=5000, bullet=0),
                     dict(phase=41, ns=ms(1.018), tick_sequence=7, server_time=1234),
                     dict(phase=42, ns=ms(1.019), owner=4242, bullet=33),
                     dict(phase=40, ns=ms(1.202), tick_sequence=8, server_time=5200, bullet=151)]
            lines = []
            for i, values in enumerate(guard, 1):
                row = dict.fromkeys(FIELDS, 0); row.update(id=i, **values)
                lines.append('hit_probe_v4\t' + '\t'.join(str(row[k]) for k in FIELDS))
            log = Path(folder) / 'guard.tsv'; log.write_text('\n'.join(lines) + '\n')
            report = traffic.analyze(pcap, log)
        self.assertEqual((report['ticks'], report['moves'], report['hits'], report['tick_step_errors']), (2, 1, 1, 0))
        self.assertEqual(report['retransmits_up'], 1)
        self.assertEqual(report['hit_ack_ms']['max'], 55.0)
        self.assertEqual(report['field_vs_reply_lag'][1]['median_field_minus_estimate'], 151 - 65.0)
        g = report['guard']
        self.assertEqual((g['ticks_matched'], g['field_mismatches'], g['moves_matched'], g['hits_matched']), (2, 0, 1, 1))
        self.assertEqual(g['clock_offset_bracket_ms'], dict(low=499.0, high=502.0, width=3.0))
        self.assertEqual(g['hit_report_to_server_ack_ms']['max'], 55.0)


if __name__ == '__main__':
    unittest.main()

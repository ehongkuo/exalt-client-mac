"""Check the installed binary against every audited entry and caller in the guard."""
import hashlib
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / '.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib'
data = path.read_bytes()
assert hashlib.sha256(data).hexdigest() == (ROOT / 'guard/game-build.sha256').read_text().strip(), 'Game build hash mismatch'
assert data[:4] == b'\xcf\xfa\xed\xfe', 'Expected Intel Mach-O'
segments = []
pos = 32
for _ in range(struct.unpack_from('<I', data, 16)[0]):
    command, size = struct.unpack_from('<II', data, pos)
    if command == 0x19:
        vm, _, offset, length = struct.unpack_from('<QQQQ', data, pos + 24)
        segments.append((vm, length, offset))
    pos += size

def read(address, size):
    vm, _, offset = next(s for s in segments if s[0] <= address and address + size <= s[0] + s[1])
    return data[offset + address - vm:offset + address - vm + size]

source = (ROOT / 'guard/guard.c').read_text() + '\n' + (ROOT / 'probe/hit_probe.h').read_text()
def number(name):
    values = re.findall(r'^#define ' + name + r'\s+(0x[0-9a-fA-F]+)UL', source, re.M)
    assert values and len(set(values)) == 1, name + ' missing or inconsistent'
    return int(values[0], 16)

for prefix, name in [('report','HIT_REPORT_OFFSET'), ('notify','HIT_NOTIFY_OFFSET'), ('hp','HP_ASSIGN_OFFSET'),
                     ('nexus','NEXUS_OFFSET'), ('damage','DAMAGE_OFFSET'), ('death','DEATH_SCREEN_OFFSET'),
                     ('update','UPDATE_OFFSET'), ('stats','STATS_OFFSET')]:
    value = re.search(r'static const unsigned char ' + prefix + r'_prologue\[\]=\{([^}]+)\}', source)[1]
    expected = bytes(int(part, 0) for part in value.split(','))
    assert read(number(name), len(expected)) == expected, prefix + ' entry bytes mismatch'
for name in ('POTION_OFFSET','JOIN_OFFSET','JOIN_COOLDOWN_OFFSET'):
    assert read(number(name), 4) == bytes.fromhex('55 48 89 e5'), name + ' expected audited entry'
for caller, target in [('DAMAGE_CALLER','DAMAGE_OFFSET'), ('ZERO_HP_CALLER','HP_ASSIGN_OFFSET')]:
    address = number(caller)
    call = read(address - 5, 5)
    assert call[0] == 0xe8 and address + struct.unpack('<i', call[1:])[0] == number(target), caller + ' wrong call destination'
address = number('NOTIFY_CALLER')
assert read(address - 6, 6) == bytes.fromhex('ff 90 98 08 00 00'), 'Notification virtual call mismatch'
print('Installed build verified: hash, eight hook prefixes, three action entries and three audited callers')

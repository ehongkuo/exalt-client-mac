"""Compatibility verification entrypoint retained for existing build commands."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / '.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib'
subprocess.run([sys.executable, str(ROOT / 'compatibility/manage.py'), 'verify', '--binary', str(binary)], check=True)

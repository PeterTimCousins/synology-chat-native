#!/usr/bin/env python3
"""Extract a static endpoint index from a locally cached Synology Chat bundle.

This reads inert JavaScript text. It neither executes the bundle nor accesses a server.
The generated index contains contracts and source offsets, not Synology source code.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
raw = args.bundle.read_bytes()
source = raw.decode('utf-8')
pattern = r'([A-Za-z_][A-Za-z0-9_]*):\{api:"([^"]+)",method:"([^"]+)",version:(\d+)'
operations = [dict(alias=m[1], api=m[2], method=m[3], version=int(m[4]),
                   source_character_offset=m.start(), verification='static-only')
              for m in re.finditer(pattern, source)]
if not operations:
    parser.error('No API contracts found; verify that this is synochat-common.js.')
result = dict(source_file=args.bundle.name, source_sha256=hashlib.sha256(raw).hexdigest(),
              evidence_kind='literal source extraction; not runtime validation', operations=operations)
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(f'Extracted {len(operations)} API operations into {args.output}')

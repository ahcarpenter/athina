#!/usr/bin/env python3
"""Sets every tracked file's modification time from its content.

A fresh checkout stamps every file with the time of the checkout, so a build
cache restored into it finds every source changed and recompiles it all.
SwiftPM (llbuild and the Swift driver) takes a source whose modification time
and size are the ones it recorded as unchanged. Deriving the time from the
file's git blob id gives the same content the same time in every checkout, and
different content a different one: 58 bits of the id, 28 in whole seconds
after 2001-09-09 and 30 in nanoseconds, so a stale object would need two
contents of one path to share those bits and a size.

Run from the repository root.
"""

import os
import subprocess

BASE_SECONDS = 1_000_000_000

listing = subprocess.run(
    ["git", "ls-files", "--stage", "-z"], check=True, capture_output=True
).stdout
count = 0
for entry in listing.split(b"\0"):
    if not entry:
        continue
    meta, path = entry.split(b"\t", 1)
    mode, blob, _stage = meta.split(b" ")
    if mode == b"160000":
        # A submodule, which has no content of its own here.
        continue
    bits = int(blob[:15], 16)  # 60 bits
    seconds = BASE_SECONDS + (bits >> 32)  # the top 28
    nanoseconds = (bits & 0xFFFFFFFF) % 1_000_000_000  # about 30 more
    stamp = seconds * 1_000_000_000 + nanoseconds
    try:
        os.utime(path, ns=(stamp, stamp), follow_symlinks=False)
    except FileNotFoundError:
        # Tracked but deleted in the working tree: nothing to stamp.
        continue
    count += 1
print(f"content-mtimes: stamped {count} tracked files")

#!/usr/bin/env python3
"""restore-mtimes.py — give mirrored transcripts their REAL timestamps back.

git does not record mtimes. A vault checkout therefore stamps every file with
the moment it was written to disk, so a secondary box shows the entire back
catalogue as "1 day ago" and loses all recency ordering — which is most of what
makes a transcript list navigable.

The fix is that the true time is already IN the file: every session line carries
an ISO-8601 `timestamp`. The last one is when the session actually ended, which
is exactly what an mtime should say. That is strictly better than the git commit
date, which records when the vault happened to sync (measured on one
pipeline-website session: content ended 2026-07-14, committed 2026-07-26 — a
12-day error).

Reads the tail first, because these files reach tens of MB and JSONL is
append-ordered, so the newest timestamp is essentially always in the last chunk.
Falls back to a full scan when the tail has none. Never parses JSON: a byte-level
regex for the timestamp field is ~an order of magnitude cheaper and cannot be
tripped by a truncated final line (which a live, still-being-written session
always has).

SAFE: only ever calls os.utime. Never reads a file it does not stat, never
writes file CONTENT, and skips symlinked directories so the -home-<user>-*
aliases cannot cause a file to be visited twice.
"""

import argparse
import os
import re
import sys
import time
from datetime import UTC, datetime

# "timestamp":"2026-07-14T23:50:53.136Z"  — tolerate whitespace and both quote
# styles; capture the ISO instant only.
TS_RE = re.compile(
    rb'"timestamp"\s*:\s*"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)"'
)
TAIL_BYTES = 256 * 1024
# Below this, a difference is noise (checkout jitter, sub-second rounding).
SKEW_TOLERANCE_S = 60


def iso_to_epoch(raw: bytes):
    s = raw.decode("ascii", "ignore").replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.timestamp()


def newest_timestamp(path, size):
    """Max embedded timestamp, tail-first. None when the file carries none."""
    try:
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(-TAIL_BYTES, os.SEEK_END)
            chunk = fh.read()
            stamps = TS_RE.findall(chunk)
            if not stamps and size > TAIL_BYTES:
                fh.seek(0)
                stamps = TS_RE.findall(fh.read())
    except OSError:
        return None
    epochs = [e for e in (iso_to_epoch(s) for s in stamps) if e is not None]
    return max(epochs) if epochs else None


def walk_real_dirs(root):
    """*.jsonl at any depth, never descending a symlinked directory."""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [
            d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))
        ]
        for fn in filenames:
            if fn.endswith(".jsonl"):
                yield os.path.join(dirpath, fn)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would change; touch nothing",
    )
    ap.add_argument(
        "--since",
        type=float,
        metavar="MIN",
        help="only consider files whose mtime is newer than MIN "
        "minutes ago — the incremental mode a post-pull hook "
        "wants, since a fresh checkout is exactly what has a "
        "just-now mtime",
    )
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.root):
        print(f"restore-mtimes: no such root: {args.root}", file=sys.stderr)
        return 2

    cutoff = time.time() - args.since * 60 if args.since else None
    fixed = already = nostamp = skipped = 0
    oldest_gain = 0.0

    for path in walk_real_dirs(args.root):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if cutoff is not None and st.st_mtime < cutoff:
            skipped += 1
            continue
        real = newest_timestamp(path, st.st_size)
        if real is None:
            nostamp += 1
            continue
        delta = st.st_mtime - real
        if abs(delta) <= SKEW_TOLERANCE_S:
            already += 1
            continue
        oldest_gain = max(oldest_gain, delta)
        if not args.dry_run:
            try:
                os.utime(path, (real, real))
            except OSError as e:
                print(f"restore-mtimes: {path}: {e}", file=sys.stderr)
                continue
        fixed += 1

    if not args.quiet:
        verb = "would fix" if args.dry_run else "fixed"
        print(
            f"restore-mtimes: {verb}={fixed} already-correct={already} "
            f"no-timestamp={nostamp} out-of-window={skipped}"
        )
        if fixed and oldest_gain > 0:
            print(f"  largest correction: {oldest_gain / 86400:.1f} days")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Print the symbolicated faulting frames from recent simulator crash reports.

An .ips file is a one-line JSON header followed by a JSON body. The body names
the exception and, for the triggered thread, the frames — which is the part
worth reading. Dumping the raw file instead truncates before the frames.

    python3 Scripts/dump_crash_reports.py [minutes]
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

DIRECTORY = Path.home() / "Library" / "Logs" / "DiagnosticReports"


def frames(report: dict) -> list[str]:
    images = report.get("usedImages", [])
    lines: list[str] = []
    for thread in report.get("threads", []):
        if not thread.get("triggered"):
            continue
        for index, frame in enumerate(thread.get("frames", [])[:32]):
            image = images[frame["imageIndex"]] if "imageIndex" in frame and frame["imageIndex"] < len(images) else {}
            symbol = frame.get("symbol") or f"0x{frame.get('imageOffset', 0):x}"
            lines.append(f"    {index:2}  {image.get('name', '?'):<28} {symbol}")
    return lines


def main() -> int:
    minutes = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    cutoff = time.time() - minutes * 60

    if not DIRECTORY.is_dir():
        print("(no DiagnosticReports directory)")
        return 0

    reports = sorted(
        (p for p in DIRECTORY.glob("*.ips") if p.stat().st_mtime >= cutoff),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:5]

    if not reports:
        print("(no crash reports in the window)")
        return 0

    for path in reports:
        raw = path.read_text(errors="replace")
        header, _, body = raw.partition("\n")
        print(f"===== {path.name} =====")
        try:
            summary = json.loads(header)
            print(f"  process: {summary.get('app_name')}  bundle: {summary.get('bundleID')}")
        except json.JSONDecodeError:
            pass
        try:
            report = json.loads(body)
        except json.JSONDecodeError:
            print("  (body is not JSON; raw head follows)")
            print(body[:2000])
            continue
        exception = report.get("exception", {})
        print(f"  exception: {exception.get('type')} {exception.get('signal')} codes={exception.get('codes')}")
        termination = report.get("termination", {})
        if termination:
            print(f"  termination: {termination.get('indicator')}")
        for line in frames(report):
            print(line)
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

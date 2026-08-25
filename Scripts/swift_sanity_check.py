#!/usr/bin/env python3
"""A lexical sanity check for the Swift sources.

Not a compiler — the real build runs on macOS in CI — but it walks every file
with a Swift-aware scanner (line and nested block comments, single-line,
multi-line and raw string literals, string interpolation) and reports
unbalanced brackets, unterminated literals and a few project conventions.
Catching those here saves a ten-minute round trip through a macOS runner.
"""
from __future__ import annotations

import sys
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIRECTORIES = ["Holograph", "HolographTests", "HolographUITests"]
OPENERS = {"(": ")", "[": "]", "{": "}"}
PRINT_CALL = re.compile(r"(?<![\w.])print\s*\(")
CLOSERS = {value: key for key, value in OPENERS.items()}


class Problem(Exception):
    def __init__(self, line: int, message: str):
        super().__init__(message)
        self.line = line
        self.message = message


def scan(source: str) -> None:
    index = 0
    length = len(source)
    line = 1
    brackets: list[tuple[str, int]] = []
    # A frame is (kind, delimiter, hashes, bracket_depth_on_entry). An
    # interpolation pushes a "code" frame; the ')' that returns the depth to the
    # entry value closes it rather than matching a bracket.
    frames: list[tuple[str, str | None, int, int]] = [("code", None, 0, 0)]

    def advance(count: int) -> None:
        nonlocal index, line
        line += source.count("\n", index, index + count)
        index += count

    while index < length:
        kind, delimiter, hashes, depth = frames[-1]

        if kind == "code":
            if source.startswith("//", index):
                end = source.find("\n", index)
                advance((length if end == -1 else end) - index)
                continue
            if source.startswith("/*", index):
                nesting = 0
                start_line = line
                while index < length:
                    if source.startswith("/*", index):
                        nesting += 1
                        advance(2)
                    elif source.startswith("*/", index):
                        nesting -= 1
                        advance(2)
                        if nesting == 0:
                            break
                    else:
                        advance(1)
                if nesting != 0:
                    raise Problem(start_line, "unterminated block comment")
                continue

            # Raw string: any number of '#' then a quote.
            if source[index] == "#":
                count = 0
                while index + count < length and source[index + count] == "#":
                    count += 1
                if source.startswith('"""', index + count):
                    advance(count + 3)
                    frames.append(("string", '"""', count, len(brackets)))
                    continue
                if source.startswith('"', index + count):
                    advance(count + 1)
                    frames.append(("string", '"', count, len(brackets)))
                    continue
                advance(count)
                continue

            if source.startswith('"""', index):
                advance(3)
                frames.append(("string", '"""', 0, len(brackets)))
                continue
            if source[index] == '"':
                advance(1)
                frames.append(("string", '"', 0, len(brackets)))
                continue

            character = source[index]
            if character in OPENERS:
                brackets.append((character, line))
                advance(1)
                continue
            if character in CLOSERS:
                if character == ")" and len(frames) > 1 and len(brackets) == depth:
                    # This ')' closes a string interpolation.
                    frames.pop()
                    advance(1)
                    continue
                if not brackets:
                    raise Problem(line, f"unexpected closing {character!r}")
                opener, opened_at = brackets.pop()
                if OPENERS[opener] != character:
                    raise Problem(
                        line,
                        f"closing {character!r} does not match {opener!r} opened on line {opened_at}",
                    )
                advance(1)
                continue

            advance(1)
            continue

        # Inside a string literal.
        assert delimiter is not None
        escape = "\\" + "#" * hashes
        if source.startswith(escape + "(", index):
            advance(len(escape) + 1)
            frames.append(("code", None, 0, len(brackets)))
            continue
        if source.startswith(escape, index):
            advance(len(escape) + 1)
            continue
        terminator = delimiter + "#" * hashes
        if source.startswith(terminator, index):
            advance(len(terminator))
            frames.pop()
            continue
        if delimiter == '"' and source[index] == "\n":
            raise Problem(line, "unterminated string literal")
        advance(1)

    if brackets:
        opener, opened_at = brackets[-1]
        raise Problem(opened_at, f"{opener!r} opened here is never closed")
    if len(frames) > 1:
        raise Problem(line, "unterminated string literal at end of file")


def main() -> int:
    failures: list[str] = []
    checked = 0

    for directory in DIRECTORIES:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            checked += 1
            source = path.read_text(encoding="utf-8")
            relative = path.relative_to(ROOT)

            if not source.endswith("\n"):
                failures.append(f"{relative}: file does not end with a newline")
            if "\t" in source:
                failures.append(f"{relative}: contains a tab character")

            try:
                scan(source)
            except Problem as problem:
                failures.append(f"{relative}:{problem.line}: {problem.message}")

            # A few project conventions worth enforcing mechanically.
            if directory == "Holograph":
                for number, text in enumerate(source.splitlines(), start=1):
                    stripped = text.strip()
                    if stripped.startswith("//"):
                        continue
                    if "try!" in stripped:
                        failures.append(f"{relative}:{number}: try! is not allowed in the app target")
                    if PRINT_CALL.search(stripped):
                        failures.append(f"{relative}:{number}: use OSLog rather than print in the app target")

    if failures:
        print("Swift sanity check failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print(f"Swift sanity check passed ({checked} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

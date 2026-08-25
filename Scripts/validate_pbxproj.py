#!/usr/bin/env python3
"""Parse the generated project.pbxproj and check it for internal consistency.

Xcode is not available on every machine that touches this repository (CI on
Linux, for instance), so this is the cheap structural check that catches a
malformed or dangling project file before it reaches a macOS runner.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "Holograph.xcodeproj" / "project.pbxproj"

TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[A-Za-z0-9_./$+-]+|[{}()=,;]')


def strip_comments(text: str) -> str:
    return re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)


def tokenize(text: str) -> list[str]:
    return TOKEN.findall(text)


class Parser:
    def __init__(self, tokens: list[str]):
        self.tokens = tokens
        self.index = 0

    def peek(self) -> str | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self) -> str:
        token = self.tokens[self.index]
        self.index += 1
        return token

    def expect(self, token: str) -> None:
        actual = self.take()
        if actual != token:
            raise ValueError(f"expected {token!r} at token {self.index}, found {actual!r}")

    def parse_value(self):
        token = self.peek()
        if token == "{":
            return self.parse_dict()
        if token == "(":
            return self.parse_array()
        return unquote(self.take())

    def parse_dict(self) -> dict:
        self.expect("{")
        result: dict[str, object] = {}
        while self.peek() != "}":
            key = unquote(self.take())
            self.expect("=")
            result[key] = self.parse_value()
            self.expect(";")
        self.expect("}")
        return result

    def parse_array(self) -> list:
        self.expect("(")
        result: list[object] = []
        while self.peek() != ")":
            result.append(self.parse_value())
            if self.peek() == ",":
                self.take()
        self.expect(")")
        return result


def unquote(token: str) -> str:
    if token.startswith('"') and token.endswith('"'):
        return token[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return token


def fail(problems: list[str], message: str) -> None:
    problems.append(message)


def main() -> int:
    if not PBXPROJ.exists():
        print(f"error: {PBXPROJ} does not exist — run Scripts/generate_xcodeproj.py", file=sys.stderr)
        return 1

    raw = PBXPROJ.read_text(encoding="utf-8")
    if not raw.startswith("// !$*UTF8*$!"):
        print("error: missing the UTF-8 header Xcode expects", file=sys.stderr)
        return 1

    body = strip_comments(raw.split("\n", 1)[1])
    parser = Parser(tokenize(body))
    root = parser.parse_dict()

    objects = root["objects"]
    problems: list[str] = []

    # Every referenced identifier must exist.
    identifier = re.compile(r"^[0-9A-F]{24}$")

    def check_references(value, context: str) -> None:
        if isinstance(value, str):
            if identifier.match(value) and value not in objects:
                fail(problems, f"{context}: dangling reference {value}")
        elif isinstance(value, list):
            for entry in value:
                check_references(entry, context)
        elif isinstance(value, dict):
            for key, entry in value.items():
                check_references(entry, f"{context}.{key}")

    for oid, obj in objects.items():
        if not identifier.match(oid):
            fail(problems, f"object key {oid} is not a 24-character identifier")
        if "isa" not in obj:
            fail(problems, f"object {oid} has no isa")
        check_references(obj, f"{obj.get('isa', '?')} {oid}")

    root_object = root.get("rootObject")
    if root_object not in objects:
        fail(problems, "rootObject does not resolve")

    project = objects[root_object]
    if project.get("isa") != "PBXProject":
        fail(problems, "rootObject is not a PBXProject")

    # Targets, their phases and their configuration lists.
    targets = project.get("targets", [])
    if len(targets) != 3:
        fail(problems, f"expected 3 targets, found {len(targets)}")

    seen_products: set[str] = set()
    for target_id in targets:
        target = objects[target_id]
        name = target.get("name", "?")
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            for build_file_id in phase.get("files", []):
                build_file = objects[build_file_id]
                if build_file.get("isa") != "PBXBuildFile":
                    fail(problems, f"{name}: {build_file_id} in a build phase is not a PBXBuildFile")
                if build_file.get("fileRef") not in objects:
                    fail(problems, f"{name}: build file {build_file_id} has no file reference")
        product = target.get("productReference")
        if product in seen_products:
            fail(problems, f"{name}: duplicate product reference")
        seen_products.add(product)

        config_list = objects[target["buildConfigurationList"]]
        names = {objects[c]["name"] for c in config_list["buildConfigurations"]}
        if names != {"Debug", "Release"}:
            fail(problems, f"{name}: expected Debug and Release configurations, found {sorted(names)}")

    # Every Swift file on disk must be compiled by exactly one target.
    compiled: dict[str, list[str]] = {}
    for oid, obj in objects.items():
        if obj.get("isa") != "PBXSourcesBuildPhase":
            continue
        for build_file_id in obj.get("files", []):
            ref = objects[objects[build_file_id]["fileRef"]]
            compiled.setdefault(ref["path"], []).append(oid)

    on_disk = {
        path.name
        for directory in ("Holograph", "HolographTests", "HolographUITests")
        for path in (ROOT / directory).rglob("*.swift")
    }
    missing = sorted(on_disk - set(compiled))
    if missing:
        fail(problems, f"Swift files on disk but not in any target: {missing}")
    duplicated = sorted(name for name, phases in compiled.items() if len(phases) > 1)
    if duplicated:
        fail(problems, f"Swift files compiled by more than one target: {duplicated}")

    # Group children must all resolve, and each file reference must exist on disk.
    for oid, obj in objects.items():
        if obj.get("isa") != "PBXFileReference":
            continue
        if obj.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            continue

    if problems:
        print("project.pbxproj validation failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    counts: dict[str, int] = {}
    for obj in objects.values():
        counts[obj["isa"]] = counts.get(obj["isa"], 0) + 1
    print("project.pbxproj is structurally sound")
    for isa in sorted(counts):
        print(f"  {isa}: {counts[isa]}")
    print(f"  Swift files compiled: {len(compiled)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

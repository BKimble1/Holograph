#!/usr/bin/env python3
"""Report an app's TestFlight builds and where each one is in processing.

Signs its own ES256 token from the App Store Connect `.p8` and reads back the
builds for a bundle identifier. Uses only the standard library plus `openssl`,
so it runs anywhere CI does. The key is read to sign and is never printed,
copied or sent anywhere but Apple.

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=... \
        python3 Scripts/asc_build_status.py com.example.app
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _take_integer(buf: bytes, at: int) -> tuple[bytes, int]:
    """Read one DER INTEGER, left-padded to the 32 bytes ES256 expects."""
    if buf[at] != 0x02:
        raise ValueError("expected a DER INTEGER")
    size = buf[at + 1]
    value = buf[at + 2: at + 2 + size]
    return value.lstrip(b"\x00").rjust(32, b"\x00"), at + 2 + size


def make_token(key_id: str, issuer_id: str, key_path: str) -> str:
    now = int(time.time())
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = _b64(json.dumps({
        "iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
    }).encode())

    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=f"{header}.{payload}".encode(), capture_output=True, check=True,
    ).stdout

    # openssl emits SEQUENCE{INTEGER r, INTEGER s}; ES256 wants raw r||s.
    if der[0] != 0x30:
        raise ValueError("expected a DER SEQUENCE")
    start = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    r, after_r = _take_integer(der, start)
    s, _ = _take_integer(der, after_r)
    return f"{header}.{payload}.{_b64(r + s)}"


def fetch(token: str, path: str) -> tuple[int, dict]:
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        raw = error.read() or b"{}"
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {}


def report(bundle_id: str) -> int:
    token = make_token(
        os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"]
    )

    status, body = fetch(token, f"/v1/apps?filter[bundleId]={bundle_id}&fields[apps]=name,bundleId")
    if status != 200:
        for problem in body.get("errors", []):
            print(f"  {problem.get('code')} | {problem.get('title')} | {problem.get('detail')}")
        return 1
    apps = body.get("data", [])
    if not apps:
        print(f"No App Store Connect record for {bundle_id}.")
        return 1

    app = apps[0]
    print(f"App: {app['attributes'].get('name')} ({bundle_id})")

    status, body = fetch(token, (
        f"/v1/builds?filter[app]={app['id']}&limit=10&sort=-uploadedDate"
        "&fields[builds]=version,processingState,uploadedDate,expired,minOsVersion"
    ))
    if status != 200:
        for problem in body.get("errors", []):
            print(f"  {problem.get('code')} | {problem.get('title')} | {problem.get('detail')}")
        return 1

    builds = body.get("data", [])
    if not builds:
        print("No builds yet. A freshly accepted upload takes a few minutes to appear.")
        return 0

    print(f"{'build':>8}  {'state':<12} {'min iOS':<9} uploaded")
    for entry in builds:
        attributes = entry.get("attributes", {})
        print("{:>8}  {:<12} {:<9} {}{}".format(
            attributes.get("version", "?"),
            attributes.get("processingState", "?"),
            attributes.get("minOsVersion", "?"),
            attributes.get("uploadedDate", "?"),
            "  (expired)" if attributes.get("expired") else "",
        ))
    return 0


if __name__ == "__main__":
    bundle = sys.argv[1] if len(sys.argv) > 1 else "com.idlery.holograph"
    raise SystemExit(report(bundle))

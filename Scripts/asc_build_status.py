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


def builds(token: str, app_id: str) -> list[dict]:
    status, body = fetch(token, (
        f"/v1/builds?filter[app]={app_id}&limit=10&sort=-uploadedDate"
        "&fields[builds]=version,processingState,uploadedDate,expired,minOsVersion"
    ))
    if status != 200:
        for problem in body.get("errors", []):
            print(f"  {problem.get('code')} | {problem.get('title')} | {problem.get('detail')}")
        return []
    return body.get("data", [])


def wait_for(token: str, app_id: str, version: str, timeout: float) -> dict | None:
    """Poll until `version` appears and stops being PROCESSING.

    A build Apple has just accepted takes a few minutes to show up at all, so
    sampling once right after upload reports the *previous* build and says
    nothing useful about this one.
    """
    deadline = time.monotonic() + timeout
    seen = False
    while True:
        for entry in builds(token, app_id):
            attributes = entry.get("attributes", {})
            if str(attributes.get("version")) != str(version):
                continue
            seen = True
            if attributes.get("processingState") != "PROCESSING":
                return entry
        if time.monotonic() >= deadline:
            print(
                f"Build {version} is still "
                + ("processing" if seen else "not listed yet")
                + f" after {int(timeout)}s. Run the TestFlight status workflow to check again."
            )
            return None
        time.sleep(20)


def report(bundle_id: str, awaited: str | None = None, timeout: float = 600) -> int:
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

    if awaited is not None:
        wait_for(token, app["id"], awaited, timeout)

    listed = builds(token, app["id"])
    if not listed:
        print("No builds yet. A freshly accepted upload takes a few minutes to appear.")
        return 0

    print(f"{'build':>8}  {'state':<12} {'min iOS':<9} uploaded")
    for entry in listed:
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
    # Optional second argument: a build number to wait for before reporting.
    awaited_build = sys.argv[2] if len(sys.argv) > 2 else None
    raise SystemExit(report(bundle, awaited=awaited_build or None))

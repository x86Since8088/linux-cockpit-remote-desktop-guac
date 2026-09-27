#!/usr/bin/env python3
"""make_wheel.py OUTDIR - write edyrdp_testpkg-0.0.1-py3-none-any.whl into OUTDIR.

A test fixture for edy-rdp-bootstrap's venv path. The bootstrap installs
OFFLINE ('pip install --no-index --find-links <wheels>'), so the test needs a
wheel that exists without any network, any index and any build backend - a
'pip wheel' of a setup.py would need setuptools present and is slower than the
thing under test. A wheel is a zip with a fixed layout, so it is assembled here
by hand with zipfile.

The RECORD entries carry real sha256 digests: pip verifies them on install and
refuses a wheel whose RECORD lies, so an empty RECORD is not an option. The tag
py3-none-any keeps it installable on every interpreter/platform the tests may
run on. Nothing here is shipped: tests/ is not in the payload manifest.
"""
import base64
import hashlib
import os
import sys
import zipfile

NAME = "edyrdp_testpkg"
VERSION = "0.0.1"


def main(outdir):
    dist_info = f"{NAME}-{VERSION}.dist-info"
    files = {
        f"{NAME}/__init__.py": "MARKER = 'edy-rdp bootstrap test wheel'\n",
        f"{dist_info}/METADATA": f"Metadata-Version: 2.1\nName: {NAME}\nVersion: {VERSION}\n",
        f"{dist_info}/WHEEL": (
            "Wheel-Version: 1.0\nGenerator: edy-rdp-tests\n"
            "Root-Is-Purelib: true\nTag: py3-none-any\n"
        ),
        f"{dist_info}/top_level.txt": f"{NAME}\n",
    }
    record = []
    for path, body in files.items():
        raw = body.encode()
        digest = base64.urlsafe_b64encode(hashlib.sha256(raw).digest()).rstrip(b"=").decode()
        record.append(f"{path},sha256={digest},{len(raw)}")
    record.append(f"{dist_info}/RECORD,,")   # RECORD never hashes itself
    files[f"{dist_info}/RECORD"] = "\n".join(record) + "\n"

    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, f"{NAME}-{VERSION}-py3-none-any.whl")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path, body in files.items():
            z.writestr(path, body)
    print(out)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make_wheel.py OUTDIR")
    sys.exit(main(sys.argv[1]))

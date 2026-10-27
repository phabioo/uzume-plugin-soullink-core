#!/usr/bin/env python3
"""Packages plugin/ as an unsigned <manifest id>-<version>.uzplugin (zip).

Usage (from repo root):
  python3 tools/package.py [--out DIR] [--tag vX.Y.Z]   build the package, print its path
  python3 tools/package.py --verify FILE                validate an existing package

Deterministic: sorted entries, fixed timestamps and permissions, no extra fields.
Limits follow Uzume docs/architecture/12-plugins.md.
"""
import argparse
import json
import os
import sys
import zipfile

PLUGIN_DIR = "plugin"
MAX_PACKED = 32 * 1024 * 1024
MAX_UNPACKED = 64 * 1024 * 1024
MAX_ENTRIES = 2000
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def fail(msg):
    sys.exit("package: " + msg)


def read_manifest(plugin_dir):
    with open(os.path.join(plugin_dir, "manifest.json"), encoding="utf-8") as f:
        m = json.load(f)
    for key in ("id", "version"):
        if not isinstance(m.get(key), str) or not m[key]:
            fail("manifest.json: missing " + key)
    return m


def collect(plugin_dir):
    files = []
    for root, dirs, names in os.walk(plugin_dir):
        dirs.sort()
        for n in sorted(names):
            full = os.path.join(root, n)
            if os.path.islink(full):
                fail("symlink not allowed: " + full)
            files.append((os.path.relpath(full, plugin_dir).replace(os.sep, "/"), full))
        for d in dirs:
            if os.path.islink(os.path.join(root, d)):
                fail("symlink not allowed: " + os.path.join(root, d))
    files.sort()
    return files


def build(out_dir, tag):
    m = read_manifest(PLUGIN_DIR)
    if tag is not None and tag != "v" + m["version"]:
        fail("tag %s does not match manifest version %s" % (tag, m["version"]))
    files = collect(PLUGIN_DIR)
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "%s-%s.uzplugin" % (m["id"], m["version"]))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, full in files:
            zi = zipfile.ZipInfo(name, FIXED_TIME)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o100644 << 16
            zi.create_system = 3
            with open(full, "rb") as f:
                z.writestr(zi, f.read(), zipfile.ZIP_DEFLATED, 9)
    verify(out)
    return out


def verify(path):
    if os.path.getsize(path) > MAX_PACKED:
        fail("package exceeds 32 MiB")
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        if len(infos) > MAX_ENTRIES:
            fail("more than %d entries" % MAX_ENTRIES)
        names = [i.filename for i in infos]
        if len(set(names)) != len(names):
            fail("duplicate entries")
        if sum(i.file_size for i in infos) > MAX_UNPACKED:
            fail("unpacked size exceeds 64 MiB")
        for i in infos:
            n = i.filename
            parts = n.split("/")
            if n.startswith("/") or "\\" in n or ".." in parts or "" in parts[:-1]:
                fail("bad path: " + n)
            if (i.external_attr >> 16) & 0o170000 == 0o120000:
                fail("symlink entry: " + n)
            if n == "SIGNATURE.json":
                fail("SIGNATURE.json must not be present")
        if "manifest.json" not in names:
            fail("manifest.json missing at root")
        m = json.loads(z.read("manifest.json"))
        entry = m.get("entry")
        if not isinstance(entry, str) or entry not in names:
            fail("entry file missing: %r" % (entry,))
        # .fbplugin is accepted as legacy input only; builds always write .uzplugin
        ext = ".fbplugin" if path.endswith(".fbplugin") else ".uzplugin"
        expect = "%s-%s%s" % (m["id"], m["version"], ext)
        if os.path.basename(path) != expect:
            fail("file name should be " + expect)
        if names != sorted(names):
            fail("entries not sorted")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="dist")
    ap.add_argument("--tag")
    ap.add_argument("--verify")
    a = ap.parse_args()
    if a.verify:
        verify(a.verify)
        print("ok: " + a.verify)
    else:
        print(build(a.out, a.tag))


if __name__ == "__main__":
    main()

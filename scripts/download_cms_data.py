"""
Downloads the 2025 CMS Federal IDR public use files and saves the two line-item
CSVs from each quarter into data/raw as gzip files:

    data/raw/puf_2025q1_emerg.csv.gz   (OON emergency and non-emergency)
    data/raw/puf_2025q1_air.csv.gz     (OON air ambulance)
    ...and so on for q2, q3, q4

The CMS zips are big (Q3 and Q4 are about 1.5 GB each) and most of that is an
Excel copy of the same data plus the "QPA and Offers" file, which this project
doesn't use. So instead of downloading whole zips, the script reads the zip's
table of contents with HTTP range requests and pulls only the two CSVs it needs.
That cuts the download roughly in half. If the server ever stops allowing range
requests it falls back to downloading the full zip.

Usage:
    python scripts/download_cms_data.py              # all four quarters
    python scripts/download_cms_data.py --quarters 3 4

Standard library only, nothing to pip install.
"""

import argparse
import gzip
import struct
import sys
import tempfile
import time
import urllib.request
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
URL = "https://downloads.cms.gov/files/federal-idr-puf-{year}-q{q}.zip"
CHUNK = 1024 * 1024


def tag_for(member_name):
    """Map a file inside the CMS zip to the short name used in data/raw."""
    n = member_name.lower()
    if not n.endswith(".csv"):
        return None
    if "air ambulance" in n or "air-ambulance" in n:
        return "air"
    if "emergency" in n:
        return "emerg"
    return None  # QPA and Offers file, skipped on purpose


def http_get(url, start=None, end=None):
    req = urllib.request.Request(url, headers={"User-Agent": "nsa-idr-explorer"})
    if start is not None:
        req.add_header("Range", f"bytes={start}-{end}")
    return urllib.request.urlopen(req, timeout=120)


def content_length(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "nsa-idr-explorer"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers["Content-Length"]), r.headers.get("Accept-Ranges", "")


def read_central_directory(url, size):
    tail_len = min(size, 1024 * 1024)
    with http_get(url, size - tail_len, size - 1) as r:
        if r.status != 206:
            raise RuntimeError("server ignored the range request")
        tail = r.read()
    eocd = tail.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise RuntimeError("couldn't find the end of the zip directory")
    n_entries, cd_size, cd_offset = struct.unpack("<HII", tail[eocd + 10:eocd + 20])
    if 0xFFFFFFFF in (cd_size, cd_offset):
        raise RuntimeError("zip64 file, use the full download instead")
    cd_start_in_tail = eocd - cd_size
    cd = tail[cd_start_in_tail:eocd]
    entries, p = [], 0
    for _ in range(n_entries):
        (method, comp, unc, fn_len, ex_len, cm_len, lho) = (
            struct.unpack("<H", cd[p + 10:p + 12])[0],
            struct.unpack("<I", cd[p + 20:p + 24])[0],
            struct.unpack("<I", cd[p + 24:p + 28])[0],
            struct.unpack("<H", cd[p + 28:p + 30])[0],
            struct.unpack("<H", cd[p + 30:p + 32])[0],
            struct.unpack("<H", cd[p + 32:p + 34])[0],
            struct.unpack("<I", cd[p + 42:p + 46])[0],
        )
        name = cd[p + 46:p + 46 + fn_len].decode("utf-8", errors="replace")
        entries.append({"name": name, "method": method, "comp": comp, "unc": unc, "offset": lho})
        p += 46 + fn_len + ex_len + cm_len
    return entries


def stream_member(url, entry, out_path):
    """Range-download one zip member, inflate it, and write it back out as gzip."""
    with http_get(url, entry["offset"], entry["offset"] + 29) as r:
        local = r.read()
    fn_len, ex_len = struct.unpack("<HH", local[26:30])
    data_start = entry["offset"] + 30 + fn_len + ex_len
    data_end = data_start + entry["comp"] - 1

    inflater = zlib.decompressobj(-15) if entry["method"] == 8 else None
    got, t0 = 0, time.time()
    tmp = out_path.with_suffix(out_path.suffix + ".part")
    with http_get(url, data_start, data_end) as r, gzip.open(tmp, "wb", compresslevel=6) as out:
        while True:
            block = r.read(CHUNK)
            if not block:
                break
            got += len(block)
            out.write(inflater.decompress(block) if inflater else block)
            pct = got / entry["comp"] * 100
            rate = got / max(time.time() - t0, 0.1) / 1e6
            print(f"\r    {out_path.name}: {pct:5.1f}%  ({rate:.1f} MB/s)", end="", flush=True)
        if inflater:
            out.write(inflater.flush())
    print()
    tmp.replace(out_path)


def full_download(url, year, q):
    """Fallback: download the whole zip to a temp file and extract from it."""
    print("    range requests not available, downloading the full zip instead")
    with tempfile.TemporaryDirectory() as td:
        zpath = Path(td) / "puf.zip"
        with http_get(url) as r, open(zpath, "wb") as fh:
            while True:
                block = r.read(CHUNK)
                if not block:
                    break
                fh.write(block)
        with zipfile.ZipFile(zpath) as z:
            for name in z.namelist():
                tag = tag_for(name)
                if not tag:
                    continue
                out_path = RAW / f"puf_{year}q{q}_{tag}.csv.gz"
                with z.open(name) as src, gzip.open(out_path, "wb", compresslevel=6) as dst:
                    while True:
                        block = src.read(CHUNK)
                        if not block:
                            break
                        dst.write(block)
                print(f"    wrote {out_path.name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--year", type=int, default=2025)
    ap.add_argument("--quarters", type=int, nargs="+", default=[1, 2, 3, 4])
    ap.add_argument("--force", action="store_true", help="re-download files that already exist")
    args = ap.parse_args()

    RAW.mkdir(parents=True, exist_ok=True)
    for q in args.quarters:
        url = URL.format(year=args.year, q=q)
        print(f"{args.year} Q{q}: {url}")
        expected = [RAW / f"puf_{args.year}q{q}_{t}.csv.gz" for t in ("emerg", "air")]
        if not args.force and all(p.exists() for p in expected):
            print("    already have both files, skipping (use --force to redo)")
            continue
        try:
            size, _ = content_length(url)
            entries = read_central_directory(url, size)
            wanted = [(e, tag_for(e["name"])) for e in entries if tag_for(e["name"])]
            if not wanted:
                raise RuntimeError("no line-item CSVs found in the zip")
            for e, tag in wanted:
                stream_member(url, e, RAW / f"puf_{args.year}q{q}_{tag}.csv.gz")
        except RuntimeError as err:
            print(f"    {err}")
            full_download(url, args.year, q)

    print("\nDone. Next step: python build.py")


if __name__ == "__main__":
    sys.exit(main())

from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "pydeps"))

import lz4.block  # type: ignore
import zstandard  # type: ignore


MAGIC = b"<roblox!\x89\xff\r\n\x1a\n"


def decompress_chunk(payload: bytes, expected_size: int) -> tuple[bytes, str]:
    if payload.startswith(b"\x28\xb5\x2f\xfd"):
        return zstandard.ZstdDecompressor().decompress(payload, max_output_size=expected_size), "zstd"
    try:
        return lz4.block.decompress(payload, uncompressed_size=expected_size), "lz4"
    except Exception as exc:
        raise ValueError(f"unknown compression: {payload[:8].hex()}") from exc


def iter_chunks(data: bytes):
    if not data.startswith(MAGIC):
        raise ValueError("not a Roblox binary model/place")
    offset = 32
    index = 0
    while offset + 16 <= len(data):
        name = data[offset : offset + 4]
        compressed_len, uncompressed_len, reserved = struct.unpack_from("<III", data, offset + 4)
        stored_len = compressed_len or uncompressed_len
        start = offset + 16
        end = start + stored_len
        if end > len(data):
            raise ValueError(f"chunk {index} overruns file")
        stored = data[start:end]
        if compressed_len:
            raw, codec = decompress_chunk(stored, uncompressed_len)
        else:
            raw, codec = stored, "raw"
        if len(raw) != uncompressed_len:
            raise ValueError(f"chunk {index} decoded to {len(raw)}, expected {uncompressed_len}")
        yield {
            "index": index,
            "name": name.decode("ascii", "replace"),
            "offset": offset,
            "compressed_len": compressed_len,
            "uncompressed_len": uncompressed_len,
            "reserved": reserved,
            "codec": codec,
            "raw": raw,
        }
        offset = end
        index += 1
        if name == b"END\x00":
            break
    if offset != len(data):
        print(f"warning: {len(data) - offset} trailing bytes", file=sys.stderr)


def printable_fragments(data: bytes, minimum: int = 6):
    start = None
    for i, value in enumerate(data + b"\0"):
        if value in (9, 10, 13) or 32 <= value < 127:
            if start is None:
                start = i
        elif start is not None:
            if i - start >= minimum:
                yield start, data[start:i]
            start = None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--dump-dir", type=Path)
    parser.add_argument("--needles", nargs="*", default=["linux", "opensbi", "riscv", "kernel", "panic", "boot"])
    args = parser.parse_args()

    data = args.path.read_bytes()
    version, classes, instances = struct.unpack_from("<HII", data, 14)
    print(json.dumps({"size": len(data), "version": version, "classes": classes, "instances": instances}, indent=2))
    chunks = list(iter_chunks(data))
    print("chunks:", len(chunks), Counter(c["name"] for c in chunks))
    print("codecs:", Counter(c["codec"] for c in chunks))
    if args.dump_dir:
        args.dump_dir.mkdir(parents=True, exist_ok=True)
    needle_bytes = [n.casefold().encode() for n in args.needles]
    for chunk in chunks:
        raw = chunk["raw"]
        if args.dump_dir:
            safe_name = chunk["name"].replace("\0", "_")
            (args.dump_dir / f"{chunk['index']:04d}_{safe_name}.bin").write_bytes(raw)
        low = raw.lower()
        hits = [n.decode() for n in needle_bytes if n in low]
        if hits:
            print(f"\n[{chunk['index']:04d} {chunk['name']}] hits={hits} raw={len(raw)}")
            shown = 0
            for position, fragment in printable_fragments(raw):
                frag_low = fragment.lower()
                if any(n in frag_low for n in needle_bytes):
                    text = fragment.decode("utf-8", "backslashreplace")
                    print(f"  @{position}: {text[:1000]}")
                    shown += 1
                    if shown >= 20:
                        break


if __name__ == "__main__":
    main()

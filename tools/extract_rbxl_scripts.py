from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from inspect_rbxl import iter_chunks


SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}


def read_string(data: bytes, offset: int) -> tuple[bytes, int]:
    size = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    return data[offset : offset + size], offset + size


def decode_referents(data: bytes, count: int, offset: int = 0) -> tuple[list[int], int]:
    needed = count * 4
    block = data[offset : offset + needed]
    if len(block) != needed:
        raise ValueError("truncated referent array")
    encoded = [
        (block[i] << 24)
        | (block[i + count] << 16)
        | (block[i + count * 2] << 8)
        | block[i + count * 3]
        for i in range(count)
    ]
    result: list[int] = []
    current = 0
    for value in encoded:
        delta = (value >> 1) ^ -(value & 1)
        current += delta
        result.append(current)
    return result, offset + needed


def prop_header(raw: bytes) -> tuple[int, str, int, int]:
    class_id = struct.unpack_from("<I", raw, 0)[0]
    name_raw, offset = read_string(raw, 4)
    value_type = raw[offset]
    return class_id, name_raw.decode("utf-8"), value_type, offset + 1


def parse_string_array(raw: bytes, count: int, offset: int) -> list[bytes]:
    values = []
    for _ in range(count):
        value, offset = read_string(raw, offset)
        values.append(value)
    if offset != len(raw):
        raise ValueError(f"string property has {len(raw) - offset} extra bytes")
    return values


def safe_component(value: str) -> str:
    value = re.sub(r"[<>:\"/\\|?*\x00-\x1f]", "_", value)
    return value[:100] or "unnamed"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("place", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    chunks = list(iter_chunks(args.place.read_bytes()))
    classes: dict[int, dict] = {}
    props: dict[tuple[int, str], tuple[int, bytes, int]] = {}
    parent: dict[int, int] = {}

    for chunk in chunks:
        raw = chunk["raw"]
        if chunk["name"] == "INST":
            class_id = struct.unpack_from("<I", raw, 0)[0]
            class_raw, offset = read_string(raw, 4)
            object_format = raw[offset]
            count = struct.unpack_from("<I", raw, offset + 1)[0]
            refs, _ = decode_referents(raw, count, offset + 5)
            classes[class_id] = {
                "name": class_raw.decode("utf-8"),
                "format": object_format,
                "count": count,
                "refs": refs,
            }
        elif chunk["name"] == "PROP":
            class_id, name, value_type, offset = prop_header(raw)
            props[(class_id, name)] = (value_type, raw, offset)
        elif chunk["name"] == "PRNT":
            version = raw[0]
            count = struct.unpack_from("<I", raw, 1)[0]
            children, offset = decode_referents(raw, count, 5)
            parents, offset = decode_referents(raw, count, offset)
            if offset != len(raw):
                raise ValueError("unexpected PRNT tail")
            if version != 0:
                raise ValueError(f"unsupported PRNT version {version}")
            parent.update(zip(children, parents))

    names: dict[int, str] = {}
    for class_id, cls in classes.items():
        value_type, raw, offset = props[(class_id, "Name")]
        if value_type != 0x01:
            raise ValueError(f"Name for {cls['name']} is not a string")
        values = parse_string_array(raw, cls["count"], offset)
        names.update((ref, value.decode("utf-8", "replace")) for ref, value in zip(cls["refs"], values))

    def instance_path(ref: int) -> str:
        parts = []
        seen = set()
        while ref != -1 and ref not in seen:
            seen.add(ref)
            parts.append(names.get(ref, f"ref_{ref}"))
            ref = parent.get(ref, -1)
        return "/".join(reversed(parts))

    args.output.mkdir(parents=True, exist_ok=True)
    inventory = []
    for class_id, cls in classes.items():
        if cls["name"] not in SCRIPT_CLASSES:
            continue
        _, source_raw, source_offset = props[(class_id, "Source")]
        sources = parse_string_array(source_raw, cls["count"], source_offset)
        disabled = [False] * cls["count"]
        if (class_id, "Disabled") in props:
            value_type, disabled_raw, disabled_offset = props[(class_id, "Disabled")]
            if value_type != 0x02:
                raise ValueError("Disabled is not Bool")
            disabled = [bool(v) for v in disabled_raw[disabled_offset : disabled_offset + cls["count"]]]
        for index, (ref, source, is_disabled) in enumerate(zip(cls["refs"], sources, disabled)):
            path = instance_path(ref)
            filename = f"{ref:06d}_{safe_component(path)}.luau"
            (args.output / filename).write_bytes(source)
            inventory.append(
                {
                    "class_id": class_id,
                    "class": cls["name"],
                    "class_index": index,
                    "referent": ref,
                    "path": path,
                    "disabled": is_disabled,
                    "source_bytes": len(source),
                    "file": filename,
                }
            )

    inventory.sort(key=lambda row: (row["path"].casefold(), row["class"], row["referent"]))
    (args.output / "inventory.json").write_text(json.dumps(inventory, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"extracted {len(inventory)} scripts to {args.output}")
    for row in inventory:
        low = row["path"].casefold()
        if any(term in low for term in ("linux", "opensbi", "sv32", "hart", "bypass")):
            print(f"{'DISABLED' if row['disabled'] else 'ACTIVE  '} {row['class']:<12} {row['source_bytes']:>8} {row['path']} -> {row['file']}")


if __name__ == "__main__":
    main()

from __future__ import annotations

"""Surgically replace Script.Source values in a binary Roblox place/model.

Only the PROP chunks that contain a selected Source value are rebuilt.  The
32-byte file header, every other complete stored chunk, and any bytes after the
END chunk are copied verbatim from the input file.

The preferred interface is a JSON manifest::

    {
      "replacements": [
        {
          "referent": 203,
          "path": "ServerScriptService/00_sv32_mmu_runtime",
          "file": "patched/00_sv32_mmu_runtime.luau",
          "expected_sha256": "optional hash of the old Source bytes"
        }
      ]
    }

``path`` and ``referent`` may be used independently.  Supplying both is a
useful guard: they must identify the same instance.  Source files are treated
as bytes; the patcher never normalizes their encoding or line endings.
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "pydeps"))

import lz4.block  # type: ignore
import zstandard  # type: ignore

from extract_rbxl_scripts import (
    SCRIPT_CLASSES,
    decode_referents,
    parse_string_array,
    prop_header,
    read_string,
)
from inspect_rbxl import MAGIC, iter_chunks


HEADER_SIZE = 32


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_instance_path(value: str) -> str:
    return "/".join(part for part in value.replace("\\", "/").split("/") if part)


def canonical_path(value: Path) -> str:
    """Return a comparison key suitable for detecting Windows path aliases."""
    return os.path.normcase(os.path.abspath(os.fspath(value)))


def encode_string(value: bytes) -> bytes:
    if len(value) > 0xFFFFFFFF:
        raise ValueError("a Source value is too large for the RBXL string format")
    return struct.pack("<I", len(value)) + value


@dataclass(frozen=True)
class ChunkRecord:
    index: int
    name: str
    offset: int
    compressed_len: int
    uncompressed_len: int
    reserved: int
    codec: str
    raw: bytes
    stored_bytes: bytes


@dataclass(frozen=True)
class PropertyRecord:
    class_id: int
    name: str
    value_type: int
    value_offset: int
    chunk_index: int
    raw: bytes


@dataclass(frozen=True)
class ScriptRecord:
    class_id: int
    class_name: str
    class_index: int
    referent: int
    path: str
    source: bytes
    source_chunk_index: int


@dataclass
class ModelIndex:
    data: bytes
    chunks: list[ChunkRecord]
    trailing_offset: int
    scripts: list[ScriptRecord]
    source_properties: dict[int, PropertyRecord]
    classes: dict[int, dict[str, Any]]

    @property
    def scripts_by_ref(self) -> dict[int, ScriptRecord]:
        return {script.referent: script for script in self.scripts}

    @property
    def scripts_by_path(self) -> dict[str, list[ScriptRecord]]:
        result: dict[str, list[ScriptRecord]] = {}
        for script in self.scripts:
            result.setdefault(normalize_instance_path(script.path), []).append(script)
        return result


@dataclass(frozen=True)
class ReplacementSpec:
    origin: str
    referent: int | None
    path: str | None
    class_name: str | None
    source_file: Path
    expected_sha256: str | None


@dataclass(frozen=True)
class ResolvedReplacement:
    spec: ReplacementSpec
    script: ScriptRecord
    new_source: bytes


def _chunk_stored_end(chunk: dict[str, Any]) -> int:
    stored_len = chunk["compressed_len"] or chunk["uncompressed_len"]
    return chunk["offset"] + 16 + stored_len


def build_model_index(data: bytes) -> ModelIndex:
    if len(data) < HEADER_SIZE or not data.startswith(MAGIC):
        raise ValueError("input is not a Roblox binary place/model")

    decoded_chunks = list(iter_chunks(data))
    if not decoded_chunks:
        raise ValueError("RBXL contains no chunks")

    chunks: list[ChunkRecord] = []
    for chunk in decoded_chunks:
        end = _chunk_stored_end(chunk)
        chunks.append(
            ChunkRecord(
                index=chunk["index"],
                name=chunk["name"],
                offset=chunk["offset"],
                compressed_len=chunk["compressed_len"],
                uncompressed_len=chunk["uncompressed_len"],
                reserved=chunk["reserved"],
                codec=chunk["codec"],
                raw=chunk["raw"],
                stored_bytes=data[chunk["offset"] : end],
            )
        )

    trailing_offset = _chunk_stored_end(decoded_chunks[-1])
    classes: dict[int, dict[str, Any]] = {}
    properties: dict[tuple[int, str], PropertyRecord] = {}
    parent: dict[int, int] = {}

    for chunk in chunks:
        raw = chunk.raw
        if chunk.name == "INST":
            if len(raw) < 9:
                raise ValueError(f"truncated INST chunk {chunk.index}")
            class_id = struct.unpack_from("<I", raw, 0)[0]
            class_raw, offset = read_string(raw, 4)
            if offset + 5 > len(raw):
                raise ValueError(f"truncated INST header in chunk {chunk.index}")
            object_format = raw[offset]
            count = struct.unpack_from("<I", raw, offset + 1)[0]
            refs, _ = decode_referents(raw, count, offset + 5)
            if class_id in classes:
                raise ValueError(f"duplicate INST class id {class_id}")
            classes[class_id] = {
                "name": class_raw.decode("utf-8"),
                "format": object_format,
                "count": count,
                "refs": refs,
            }
        elif chunk.name == "PROP":
            class_id, name, value_type, value_offset = prop_header(raw)
            key = (class_id, name)
            if key in properties:
                raise ValueError(f"duplicate PROP {name!r} for class id {class_id}")
            properties[key] = PropertyRecord(
                class_id=class_id,
                name=name,
                value_type=value_type,
                value_offset=value_offset,
                chunk_index=chunk.index,
                raw=raw,
            )
        elif chunk.name == "PRNT":
            if len(raw) < 5:
                raise ValueError(f"truncated PRNT chunk {chunk.index}")
            version = raw[0]
            if version != 0:
                raise ValueError(f"unsupported PRNT version {version}")
            count = struct.unpack_from("<I", raw, 1)[0]
            children, offset = decode_referents(raw, count, 5)
            parents, offset = decode_referents(raw, count, offset)
            if offset != len(raw):
                raise ValueError(f"unexpected PRNT tail in chunk {chunk.index}")
            for child, parent_ref in zip(children, parents):
                if child in parent and parent[child] != parent_ref:
                    raise ValueError(f"referent {child} has multiple parents")
                parent[child] = parent_ref

    names: dict[int, str] = {}
    for class_id, cls in classes.items():
        name_prop = properties.get((class_id, "Name"))
        if name_prop is None:
            raise ValueError(f"class {cls['name']} ({class_id}) has no Name property")
        if name_prop.value_type != 0x01:
            raise ValueError(f"Name for {cls['name']} is not a string property")
        values = parse_string_array(name_prop.raw, cls["count"], name_prop.value_offset)
        names.update(
            (ref, value.decode("utf-8", "replace"))
            for ref, value in zip(cls["refs"], values)
        )

    def instance_path(ref: int) -> str:
        parts: list[str] = []
        seen: set[int] = set()
        current = ref
        while current != -1:
            if current in seen:
                raise ValueError(f"parent cycle while resolving referent {ref}")
            seen.add(current)
            parts.append(names.get(current, f"ref_{current}"))
            current = parent.get(current, -1)
        return "/".join(reversed(parts))

    scripts: list[ScriptRecord] = []
    source_properties: dict[int, PropertyRecord] = {}
    for class_id, cls in classes.items():
        if cls["name"] not in SCRIPT_CLASSES:
            continue
        source_prop = properties.get((class_id, "Source"))
        if source_prop is None:
            raise ValueError(f"script class {cls['name']} ({class_id}) has no Source property")
        if source_prop.value_type != 0x01:
            raise ValueError(
                f"Source for {cls['name']} uses unsupported property type "
                f"0x{source_prop.value_type:02x}; expected String (0x01)"
            )
        sources = parse_string_array(source_prop.raw, cls["count"], source_prop.value_offset)
        source_properties[class_id] = source_prop
        for class_index, (ref, source) in enumerate(zip(cls["refs"], sources)):
            scripts.append(
                ScriptRecord(
                    class_id=class_id,
                    class_name=cls["name"],
                    class_index=class_index,
                    referent=ref,
                    path=instance_path(ref),
                    source=source,
                    source_chunk_index=source_prop.chunk_index,
                )
            )

    if len({script.referent for script in scripts}) != len(scripts):
        raise ValueError("duplicate script referents in model")

    return ModelIndex(
        data=data,
        chunks=chunks,
        trailing_offset=trailing_offset,
        scripts=scripts,
        source_properties=source_properties,
        classes=classes,
    )


def parse_selector_assignment(value: str, *, selector: str, origin: str) -> tuple[str, Path]:
    if "=" not in value:
        raise ValueError(f"{origin} must have the form {selector}=SOURCE_FILE")
    key, filename = value.split("=", 1)
    if not key or not filename:
        raise ValueError(f"{origin} must have a nonempty selector and SOURCE_FILE")
    return key, Path(filename)


def _optional_int(value: Any, field: str, origin: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError(f"{origin}: {field} must be an integer")
    try:
        return int(value, 0) if isinstance(value, str) else int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{origin}: invalid integer for {field}: {value!r}") from exc


def load_manifest(path: Path) -> list[ReplacementSpec]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read manifest {path}: {exc}") from exc
    rows = document.get("replacements") if isinstance(document, dict) else document
    if not isinstance(rows, list):
        raise ValueError("manifest must be a list or an object with a replacements list")

    specs: list[ReplacementSpec] = []
    for index, row in enumerate(rows):
        origin = f"{path}:replacements[{index}]"
        if not isinstance(row, dict):
            raise ValueError(f"{origin} must be an object")
        referent = _optional_int(row.get("referent", row.get("ref")), "referent", origin)
        raw_path = row.get("path")
        if raw_path is not None and not isinstance(raw_path, str):
            raise ValueError(f"{origin}: path must be a string")
        instance_path = normalize_instance_path(raw_path) if raw_path else None
        if referent is None and instance_path is None:
            raise ValueError(f"{origin}: provide referent, path, or both")
        class_name = row.get("class")
        if class_name is not None and not isinstance(class_name, str):
            raise ValueError(f"{origin}: class must be a string")
        source_name = row.get("file", row.get("source_file"))
        if not isinstance(source_name, str) or not source_name:
            raise ValueError(f"{origin}: provide a nonempty file/source_file")
        source_file = Path(source_name)
        if not source_file.is_absolute():
            source_file = path.parent / source_file
        expected = row.get("expected_sha256")
        if expected is not None:
            if not isinstance(expected, str) or len(expected) != 64:
                raise ValueError(f"{origin}: expected_sha256 must be a 64-character hex digest")
            try:
                bytes.fromhex(expected)
            except ValueError as exc:
                raise ValueError(f"{origin}: expected_sha256 is not hexadecimal") from exc
            expected = expected.lower()
        specs.append(
            ReplacementSpec(
                origin=origin,
                referent=referent,
                path=instance_path,
                class_name=class_name,
                source_file=source_file,
                expected_sha256=expected,
            )
        )
    return specs


def resolve_replacements(index: ModelIndex, specs: Iterable[ReplacementSpec]) -> list[ResolvedReplacement]:
    by_ref = index.scripts_by_ref
    by_path = index.scripts_by_path
    resolved: list[ResolvedReplacement] = []
    used_refs: dict[int, str] = {}

    for spec in specs:
        from_ref = by_ref.get(spec.referent) if spec.referent is not None else None
        if spec.referent is not None and from_ref is None:
            raise ValueError(f"{spec.origin}: no Script/LocalScript/ModuleScript has referent {spec.referent}")

        from_path: ScriptRecord | None = None
        if spec.path is not None:
            matches = by_path.get(spec.path, [])
            if not matches:
                raise ValueError(f"{spec.origin}: no script has exact path {spec.path!r}")
            if len(matches) > 1:
                details = ", ".join(f"{row.class_name} ref={row.referent}" for row in matches)
                raise ValueError(f"{spec.origin}: path {spec.path!r} is ambiguous ({details}); add referent")
            from_path = matches[0]

        script = from_ref or from_path
        assert script is not None
        if from_ref is not None and from_path is not None and from_ref.referent != from_path.referent:
            raise ValueError(
                f"{spec.origin}: referent {spec.referent} is {from_ref.path!r}, "
                f"but path {spec.path!r} is referent {from_path.referent}"
            )
        if spec.class_name is not None and script.class_name != spec.class_name:
            raise ValueError(
                f"{spec.origin}: expected class {spec.class_name!r}, found {script.class_name!r}"
            )
        if script.referent in used_refs:
            raise ValueError(
                f"{spec.origin}: referent {script.referent} is already selected by {used_refs[script.referent]}"
            )
        if not spec.source_file.is_file():
            raise ValueError(f"{spec.origin}: source file does not exist: {spec.source_file}")
        try:
            new_source = spec.source_file.read_bytes()
        except OSError as exc:
            raise ValueError(f"{spec.origin}: cannot read source file {spec.source_file}: {exc}") from exc
        old_hash = sha256(script.source)
        if spec.expected_sha256 is not None and old_hash != spec.expected_sha256:
            raise ValueError(
                f"{spec.origin}: old Source hash mismatch for ref {script.referent}: "
                f"expected {spec.expected_sha256}, found {old_hash}"
            )
        used_refs[script.referent] = spec.origin
        resolved.append(ResolvedReplacement(spec=spec, script=script, new_source=new_source))

    if not resolved:
        raise ValueError("no replacements were supplied")
    return resolved


def build_modified_source_chunks(
    index: ModelIndex, replacements: list[ResolvedReplacement]
) -> dict[int, bytes]:
    # An identical replacement is still validated and reported, but it does not
    # justify recompressing its PROP chunk.
    replacement_by_ref = {
        row.script.referent: row.new_source
        for row in replacements
        if row.new_source != row.script.source
    }
    raw_by_chunk: dict[int, bytes] = {}

    for class_id, source_prop in index.source_properties.items():
        cls = index.classes[class_id]
        if not any(ref in replacement_by_ref for ref in cls["refs"]):
            continue
        original_values = parse_string_array(
            source_prop.raw, cls["count"], source_prop.value_offset
        )
        values = [
            replacement_by_ref.get(ref, source)
            for ref, source in zip(cls["refs"], original_values)
        ]
        rebuilt = source_prop.raw[: source_prop.value_offset] + b"".join(
            encode_string(value) for value in values
        )
        raw_by_chunk[source_prop.chunk_index] = rebuilt
    return raw_by_chunk


def encode_chunk(chunk: ChunkRecord, raw: bytes) -> bytes:
    name_bytes = chunk.stored_bytes[:4]
    if chunk.codec == "raw":
        compressed_len = 0
        payload = raw
    elif chunk.codec == "lz4":
        payload = lz4.block.compress(
            raw,
            mode="high_compression",
            compression=9,
            store_size=False,
        )
        compressed_len = len(payload)
    elif chunk.codec == "zstd":
        payload = zstandard.ZstdCompressor(level=9).compress(raw)
        compressed_len = len(payload)
    else:
        raise ValueError(f"cannot re-encode unsupported codec {chunk.codec!r}")
    return name_bytes + struct.pack(
        "<III", compressed_len, len(raw), chunk.reserved
    ) + payload


def build_output(index: ModelIndex, modified_raw: dict[int, bytes]) -> bytes:
    pieces = [index.data[:HEADER_SIZE]]
    for chunk in index.chunks:
        replacement_raw = modified_raw.get(chunk.index)
        pieces.append(
            chunk.stored_bytes
            if replacement_raw is None
            else encode_chunk(chunk, replacement_raw)
        )
    pieces.append(index.data[index.trailing_offset :])
    return b"".join(pieces)


def verify_output(
    original: ModelIndex,
    output_data: bytes,
    modified_raw: dict[int, bytes],
    replacements: list[ResolvedReplacement],
) -> dict[str, Any]:
    if output_data[:HEADER_SIZE] != original.data[:HEADER_SIZE]:
        raise ValueError("verification failed: 32-byte RBXL header changed")
    output = build_model_index(output_data)
    if len(output.chunks) != len(original.chunks):
        raise ValueError("verification failed: chunk count changed")
    if output.data[output.trailing_offset :] != original.data[original.trailing_offset :]:
        raise ValueError("verification failed: trailing bytes after final chunk changed")

    changed_stored: list[int] = []
    for old, new in zip(original.chunks, output.chunks):
        if old.index != new.index or old.name != new.name:
            raise ValueError(f"verification failed: chunk identity changed at index {old.index}")
        if old.reserved != new.reserved:
            raise ValueError(f"verification failed: reserved field changed in chunk {old.index}")
        expected_raw = modified_raw.get(old.index)
        if expected_raw is None:
            if old.stored_bytes != new.stored_bytes:
                raise ValueError(
                    f"verification failed: untouched stored chunk {old.index} ({old.name}) changed"
                )
        else:
            changed_stored.append(old.index)
            if new.codec != old.codec:
                raise ValueError(
                    f"verification failed: codec changed in chunk {old.index}: "
                    f"{old.codec} -> {new.codec}"
                )
            if new.raw != expected_raw:
                raise ValueError(
                    f"verification failed: decoded payload mismatch in chunk {old.index}"
                )

    output_by_ref = output.scripts_by_ref
    selected_refs = {row.script.referent for row in replacements}
    for row in replacements:
        actual = output_by_ref.get(row.script.referent)
        if actual is None:
            raise ValueError(
                f"verification failed: patched referent {row.script.referent} disappeared"
            )
        if actual.path != row.script.path or actual.class_name != row.script.class_name:
            raise ValueError(
                f"verification failed: identity changed for referent {row.script.referent}"
            )
        if actual.source != row.new_source:
            raise ValueError(
                f"verification failed: Source mismatch for referent {row.script.referent}"
            )

    original_by_ref = original.scripts_by_ref
    for ref, old_script in original_by_ref.items():
        if ref in selected_refs:
            continue
        actual = output_by_ref.get(ref)
        if actual is None or actual.source != old_script.source:
            raise ValueError(f"verification failed: unselected Source changed for referent {ref}")

    if set(changed_stored) != set(modified_raw):
        raise ValueError("verification failed: changed chunk set differs from patch plan")
    return {
        "ok": True,
        "chunk_count": len(output.chunks),
        "modified_chunk_indexes": sorted(changed_stored),
        "unchanged_chunks_byte_exact": len(output.chunks) - len(changed_stored),
        "output_sha256": sha256(output_data),
        "output_bytes": len(output_data),
    }


def make_report(
    input_path: Path,
    output_path: Path | None,
    original: ModelIndex,
    replacements: list[ResolvedReplacement],
    modified_raw: dict[int, bytes],
    verification: dict[str, Any] | None,
    dry_run: bool,
) -> dict[str, Any]:
    return {
        "dry_run": dry_run,
        "input": str(input_path.resolve()),
        "input_bytes": len(original.data),
        "input_sha256": sha256(original.data),
        "output": str(output_path.resolve()) if output_path is not None else None,
        "modified_chunk_indexes": sorted(modified_raw),
        "replacements": [
            {
                "referent": row.script.referent,
                "class": row.script.class_name,
                "path": row.script.path,
                "source_file": str(row.spec.source_file.resolve()),
                "old_bytes": len(row.script.source),
                "new_bytes": len(row.new_source),
                "old_sha256": sha256(row.script.source),
                "new_sha256": sha256(row.new_source),
                "source_chunk_index": row.script.source_chunk_index,
                "content_changed": row.script.source != row.new_source,
            }
            for row in replacements
        ],
        "verification": verification,
    }


def print_plan(report: dict[str, Any]) -> None:
    mode = "DRY RUN" if report["dry_run"] else "PATCHED"
    print(f"{mode}: {report['input']}")
    for row in report["replacements"]:
        state = "changed" if row["content_changed"] else "identical"
        print(
            f"  ref={row['referent']} {row['class']} {row['path']}\n"
            f"    {row['old_bytes']} -> {row['new_bytes']} bytes ({state}), "
            f"chunk {row['source_chunk_index']}"
        )
    chunk_list = ", ".join(map(str, report["modified_chunk_indexes"])) or "none"
    print("  Source PROP chunks to rebuild:", chunk_list)
    if report["verification"] is not None:
        check = report["verification"]
        print(
            f"  verified: {check['unchanged_chunks_byte_exact']} untouched chunks byte-exact; "
            f"output sha256={check['output_sha256']}"
        )
    elif report["dry_run"]:
        print("  no file written")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Replace selected Script.Source values in a binary RBXL while copying "
            "every unrelated stored chunk byte-for-byte."
        )
    )
    parser.add_argument("input", type=Path, help="input .rbxl/.rbxm")
    parser.add_argument(
        "output",
        type=Path,
        nargs="?",
        help="output .rbxl/.rbxm (omit only with --dry-run)",
    )
    parser.add_argument("--manifest", type=Path, help="JSON replacement manifest")
    parser.add_argument(
        "--replace-ref",
        action="append",
        default=[],
        metavar="REF=SOURCE_FILE",
        help="replace by referent; repeatable",
    )
    parser.add_argument(
        "--replace-path",
        action="append",
        default=[],
        metavar="INSTANCE_PATH=SOURCE_FILE",
        help="replace by exact instance path; repeatable",
    )
    parser.add_argument("--dry-run", action="store_true", help="validate and print plan; write nothing")
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="skip post-build parse and byte-exact verification (not recommended)",
    )
    parser.add_argument("--report", type=Path, help="write the plan/result as JSON")
    args = parser.parse_args()

    try:
        if not args.input.is_file():
            raise ValueError(f"input file does not exist: {args.input}")
        if not args.dry_run and args.output is None:
            raise ValueError("output path is required unless --dry-run is used")
        if args.output is not None and canonical_path(args.input) == canonical_path(args.output):
            raise ValueError("refusing in-place modification; choose a different output path")

        specs: list[ReplacementSpec] = []
        if args.manifest is not None:
            specs.extend(load_manifest(args.manifest))
        for i, value in enumerate(args.replace_ref):
            raw_ref, source_file = parse_selector_assignment(
                value, selector="REF", origin=f"--replace-ref[{i}]"
            )
            referent = _optional_int(raw_ref, "referent", f"--replace-ref[{i}]")
            specs.append(
                ReplacementSpec(
                    origin=f"--replace-ref[{i}]",
                    referent=referent,
                    path=None,
                    class_name=None,
                    source_file=source_file,
                    expected_sha256=None,
                )
            )
        for i, value in enumerate(args.replace_path):
            raw_path, source_file = parse_selector_assignment(
                value, selector="INSTANCE_PATH", origin=f"--replace-path[{i}]"
            )
            specs.append(
                ReplacementSpec(
                    origin=f"--replace-path[{i}]",
                    referent=None,
                    path=normalize_instance_path(raw_path),
                    class_name=None,
                    source_file=source_file,
                    expected_sha256=None,
                )
            )

        protected: dict[str, str] = {canonical_path(args.input): "input RBXL"}
        if args.manifest is not None:
            protected[canonical_path(args.manifest)] = "replacement manifest"
        for spec in specs:
            protected[canonical_path(spec.source_file)] = f"Source file ({spec.origin})"
        if args.output is not None:
            output_key = canonical_path(args.output)
            collision = protected.get(output_key)
            if collision is not None:
                raise ValueError(f"output path would overwrite {collision}: {args.output}")
            protected[output_key] = "output RBXL"
        if args.report is not None:
            report_key = canonical_path(args.report)
            collision = protected.get(report_key)
            if collision is not None:
                raise ValueError(f"report path would overwrite {collision}: {args.report}")

        input_data = args.input.read_bytes()
        original = build_model_index(input_data)
        replacements = resolve_replacements(original, specs)
        modified_raw = build_modified_source_chunks(original, replacements)

        verification: dict[str, Any] | None = None
        if args.dry_run:
            # Build and verify in memory so dry-run exercises compression and the
            # complete output parser without creating a file.
            if not args.no_verify:
                candidate = build_output(original, modified_raw)
                verification = verify_output(
                    original, candidate, modified_raw, replacements
                )
        else:
            assert args.output is not None
            candidate = build_output(original, modified_raw)
            if not args.no_verify:
                verification = verify_output(
                    original, candidate, modified_raw, replacements
                )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temp_name: str | None = None
            try:
                fd, temp_name = tempfile.mkstemp(
                    prefix=f".{args.output.name}.",
                    suffix=".tmp",
                    dir=args.output.parent,
                )
                with os.fdopen(fd, "wb") as stream:
                    stream.write(candidate)
                    stream.flush()
                    os.fsync(stream.fileno())
                # Verify the bytes actually present on disk before publishing
                # the result.  A verification failure leaves no partial output.
                disk_data = Path(temp_name).read_bytes()
                if disk_data != candidate:
                    raise ValueError("verification failed: temporary file differs from bytes written")
                if not args.no_verify:
                    verification = verify_output(
                        original, disk_data, modified_raw, replacements
                    )
                os.replace(temp_name, args.output)
                temp_name = None
            finally:
                if temp_name is not None:
                    try:
                        Path(temp_name).unlink()
                    except FileNotFoundError:
                        pass

            if args.output.read_bytes() != candidate:
                raise ValueError("verification failed: published output differs from bytes written")

        report = make_report(
            args.input,
            args.output,
            original,
            replacements,
            modified_raw,
            verification,
            args.dry_run,
        )
        print_plan(report)
        if args.report is not None:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(
                json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        return 0
    except (OSError, ValueError, struct.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

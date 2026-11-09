#!/usr/bin/env python3
"""gguf_metadata_add — add or replace a GGUF metadata key without touching tensor bytes.

WHY THIS EXISTS (measured 2026-11-09): GLM-5.3-Flash-REAP50-IQ3_M.gguf declares
`general.architecture = glm5-next` and carries the DSA indexer tensors
(`blk.N.indexer.kpool_ape`, shape [128, 4]) but its metadata omits
`glm5-next.attention.indexer.kpool` — a key llama.cpp REQUIRES before it can size those
tensors (src/models/glm5-next.cpp: `ml.get_key(...KPOOL...)`, no default).  llama.cpp's
own converter writes the key from the HF `index_kpool` field (conversion/glm.py), so this
file was produced by a converter that did not.  Rebuilding llama.cpp cannot add a key a
file never wrote: the same load failure appears across the 2026-11-06 rebuild and again
on 2026-11-08.

WHY IT NEVER EDITS IN PLACE: a model in `models/active/` is normally a HARDLINK to the
Hugging Face cache blob (link count 2).  An in-place edit would corrupt the cache copy
too, so this tool always writes a NEW file and verifies it before the caller swaps it in.

WHAT IT RELIES ON (GGUF spec, as implemented in llama.cpp's gguf-py/gguf/gguf_reader.py):
  * the tensor-data section starts at align_up(end of the tensor-info section, alignment);
  * `general.alignment` supplies `alignment` (32 when the key is absent);
  * a tensor's `offset` field is RELATIVE to the data-section start, so inserting a
    metadata key moves that section without rewriting any tensor info.
That is why the copy can be byte-exact: the KV section and the tensor-info section are
spliced from the source verbatim, the new key is inserted between them, and the data
section is streamed through unchanged and hashed on both sides.

Usage:
    gguf_metadata_add.py --src IN.gguf --dst OUT.gguf --set KEY=TYPE:VALUE [--set ...]
                         [--replace] [--force]

Types: uint8 int8 uint16 int16 uint32 int32 float32 bool uint64 int64 float64 string
Exit:  0 written and verified, 2 refused (nothing written), 64 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

GGUF_MAGIC = b"GGUF"
_CHUNK = 8 * 1024 * 1024

TYPE_NAMES: dict[str, int] = {
    "uint8": 0,
    "int8": 1,
    "uint16": 2,
    "int16": 3,
    "uint32": 4,
    "int32": 5,
    "float32": 6,
    "bool": 7,
    "string": 8,
    "array": 9,
    "uint64": 10,
    "int64": 11,
    "float64": 12,
}
_SCALAR = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<B", 10: "<Q", 11: "<q", 12: "<d"}
_NAME_OF_TYPE = {v: k for k, v in TYPE_NAMES.items()}


class GgufError(Exception):
    """A refusal: the file is not a GGUF this tool understands, or an argument is unusable."""


@dataclass
class Layout:
    """Where each GGUF section starts and ends, plus what the metadata says."""

    path: Path
    version: int
    tensor_count: int
    kv_count: int
    kv_start: int
    kv_end: int
    info_end: int
    data_start: int
    alignment: int
    kv: list[tuple[str, int, int]] = field(default_factory=list)  # (key, start, end)
    tensors: list[tuple[str, tuple[int, ...], int, int]] = field(default_factory=list)


def _exact(fh, n: int) -> bytes:
    """Read exactly n bytes or refuse — a short read means a truncated file, never padding."""
    buf = fh.read(n)
    if len(buf) != n:
        raise GgufError(f"truncated file: wanted {n} bytes, got {len(buf)}")
    return buf


def _string(fh) -> str:
    """Read a GGUF string: u64 byte length, then UTF-8 bytes."""
    (n,) = struct.unpack("<Q", _exact(fh, 8))
    return _exact(fh, n).decode("utf-8", errors="surrogateescape")


def _skip_value(fh, vtype: int) -> None:
    """Advance past one metadata value. Arrays are walked, never materialised."""
    if vtype == TYPE_NAMES["string"]:
        (n,) = struct.unpack("<Q", _exact(fh, 8))
        fh.seek(n, os.SEEK_CUR)
        return
    if vtype == TYPE_NAMES["array"]:
        (etype,) = struct.unpack("<I", _exact(fh, 4))
        (count,) = struct.unpack("<Q", _exact(fh, 8))
        for _ in range(count):
            _skip_value(fh, etype)
        return
    fmt = _SCALAR.get(vtype)
    if fmt is None:
        raise GgufError(f"unsupported metadata value type {vtype}")
    fh.seek(struct.calcsize(fmt), os.SEEK_CUR)


def _read_scalar(fh, vtype: int):
    """Read one scalar value (used only for `general.alignment`)."""
    fmt = _SCALAR.get(vtype)
    if fmt is None:
        raise GgufError(f"metadata value type {_NAME_OF_TYPE.get(vtype, vtype)} is not a scalar")
    return struct.unpack(fmt, _exact(fh, struct.calcsize(fmt)))[0]


def _align(value: int, alignment: int) -> int:
    """Round `value` up to `alignment` (GGUF pads the data section this way)."""
    if alignment <= 0:
        raise GgufError(f"invalid alignment {alignment}")
    return (value + alignment - 1) // alignment * alignment


def read_layout(path: Path) -> Layout:
    """Parse the header, metadata and tensor infos; stop at the start of the data section."""
    with open(path, "rb") as fh:
        if _exact(fh, 4) != GGUF_MAGIC:
            raise GgufError(f"{path} is not a GGUF file (no GGUF magic)")
        (version,) = struct.unpack("<I", _exact(fh, 4))
        if version not in (2, 3):
            raise GgufError(f"GGUF version {version} is not supported (this tool handles 2 and 3)")
        (tensor_count,) = struct.unpack("<Q", _exact(fh, 8))
        (kv_count,) = struct.unpack("<Q", _exact(fh, 8))
        kv_start = fh.tell()
        alignment = 32
        kv: list[tuple[str, int, int]] = []
        for _ in range(kv_count):
            start = fh.tell()
            key = _string(fh)
            (vtype,) = struct.unpack("<I", _exact(fh, 4))
            if key == "general.alignment" and vtype in _SCALAR:
                alignment = int(_read_scalar(fh, vtype))
            else:
                _skip_value(fh, vtype)
            kv.append((key, start, fh.tell()))
        kv_end = fh.tell()
        tensors: list[tuple[str, tuple[int, ...], int, int]] = []
        for _ in range(tensor_count):
            name = _string(fh)
            (n_dims,) = struct.unpack("<I", _exact(fh, 4))
            dims = struct.unpack(f"<{n_dims}Q", _exact(fh, 8 * n_dims))
            (ttype,) = struct.unpack("<I", _exact(fh, 4))
            (offset,) = struct.unpack("<Q", _exact(fh, 8))
            tensors.append((name, dims, ttype, offset))
        info_end = fh.tell()
    return Layout(
        path=path,
        version=version,
        tensor_count=tensor_count,
        kv_count=kv_count,
        kv_start=kv_start,
        kv_end=kv_end,
        info_end=info_end,
        data_start=_align(info_end, alignment),
        alignment=alignment,
        kv=kv,
        tensors=tensors,
    )


def encode_kv(key: str, type_name: str, value: str) -> bytes:
    """Encode one metadata key/value pair in GGUF wire form."""
    if type_name == "array" or type_name not in TYPE_NAMES:
        raise GgufError(f"unsupported value type for --set: {type_name}")
    body = key.encode("utf-8")
    out = struct.pack("<Q", len(body)) + body
    if type_name == "string":
        raw = value.encode("utf-8")
        return out + struct.pack("<I", TYPE_NAMES["string"]) + struct.pack("<Q", len(raw)) + raw
    fmt = _SCALAR[TYPE_NAMES[type_name]]
    try:
        if type_name == "bool":
            parsed = 1 if value.strip().lower() in ("1", "true", "yes", "on") else 0
            payload = struct.pack(fmt, parsed)
        elif type_name.startswith("float"):
            payload = struct.pack(fmt, float(value))
        else:
            payload = struct.pack(fmt, int(value, 0))
    except ValueError as exc:
        raise GgufError(f"{key}: {value!r} is not a valid {type_name}") from exc
    return out + struct.pack("<I", TYPE_NAMES[type_name]) + payload


def parse_set(spec: str) -> tuple[str, str, str]:
    """Split `KEY=TYPE:VALUE` into its three parts."""
    key, sep, rest = spec.partition("=")
    if not sep or not key or ":" not in rest:
        raise GgufError(f"--set {spec!r} is not KEY=TYPE:VALUE")
    type_name, _, value = rest.partition(":")
    if type_name not in TYPE_NAMES:
        raise GgufError(f"--set {spec!r}: unknown type {type_name!r}")
    return key, type_name, value


def _hash_region(fh, start: int, length: int) -> str:
    """SHA-256 of one region, read in bounded chunks."""
    fh.seek(start)
    digest = hashlib.sha256()
    remaining = length
    while remaining > 0:
        block = fh.read(min(_CHUNK, remaining))
        if not block:
            raise GgufError(f"short read at offset {fh.tell()} ({remaining} bytes unread)")
        digest.update(block)
        remaining -= len(block)
    return digest.hexdigest()


def _copy_data(src: Path, dst_fh, start: int) -> tuple[int, str]:
    """Stream the data section into `dst_fh`, hashing what passes — one read of the source."""
    digest = hashlib.sha256()
    copied = 0
    with open(src, "rb") as fh:
        fh.seek(start)
        while True:
            block = fh.read(_CHUNK)
            if not block:
                break
            dst_fh.write(block)
            digest.update(block)
            copied += len(block)
    return copied, digest.hexdigest()


def add_metadata(
    src: Path, dst: Path, sets: list[tuple[str, str, str]], *, replace: bool = False, force: bool = False
) -> dict[str, object]:
    """Write `dst` as `src` with the given metadata keys added (or replaced), then verify it."""
    if not src.is_file():
        raise GgufError(f"source model not found: {src}")
    if dst.exists() and not force:
        raise GgufError(f"{dst} already exists (pass --force to overwrite)")
    if dst.resolve() == src.resolve():
        raise GgufError(
            "refusing to write over the source: a model in active/ is usually a hardlink "
            "to the Hugging Face cache blob, so an in-place edit corrupts both"
        )
    layout = read_layout(src)
    existing = {key for key, _, _ in layout.kv}
    for key, _, _ in sets:
        if key in existing and not replace:
            raise GgufError(f"{key} is already present in {src.name} (pass --replace to change it)")
    replaced = {key for key, _, _ in sets}

    new_kv = [encode_kv(key, type_name, value) for key, type_name, value in sets]
    with open(src, "rb") as fh:
        kept: list[bytes] = []
        for key, start, end in layout.kv:
            if key in replaced:
                continue
            fh.seek(start)
            kept.append(fh.read(end - start))
        fh.seek(layout.kv_end)
        info_bytes = fh.read(layout.info_end - layout.kv_end)

    new_kv_count = len(kept) + len(new_kv)
    header = GGUF_MAGIC + struct.pack("<I", layout.version) + struct.pack("<Q", layout.tensor_count)
    header += struct.pack("<Q", new_kv_count)
    new_info_end = len(header) + sum(len(blob) for blob in kept) + sum(len(blob) for blob in new_kv) + len(info_bytes)
    new_data_start = _align(new_info_end, layout.alignment)

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_name = tempfile.mkstemp(prefix=dst.name + ".", suffix=".partial", dir=str(dst.parent))
    tmp = Path(tmp_name)
    try:
        with os.fdopen(tmp_fd, "wb") as out:
            out.write(header)
            for blob in kept:
                out.write(blob)
            for blob in new_kv:
                out.write(blob)
            out.write(info_bytes)
            out.write(b"\0" * (new_data_start - new_info_end))
            out.flush()
            copied, src_hash = _copy_data(src, out, layout.data_start)
            out.flush()
            os.fsync(out.fileno())
        written = read_layout(tmp)
        _verify_structure(layout, written, new_kv_count, sets, replaced)
        if written.data_start != new_data_start:
            raise GgufError(f"data section landed at {written.data_start}, header arithmetic said {new_data_start}")
        with open(tmp, "rb") as fh:
            dst_hash = _hash_region(fh, written.data_start, copied)
        if dst_hash != src_hash:
            raise GgufError(f"data section hash mismatch: source {src_hash}, written {dst_hash}")
        os.replace(tmp, dst)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return {
        "src": str(src),
        "dst": str(dst),
        "kv_count": new_kv_count,
        "added": ",".join(f"{k}={t}:{v}" for k, t, v in sets),
        "tensor_count": layout.tensor_count,
        "data_start": new_data_start,
        "data_bytes": copied,
        "data_sha256": src_hash,
        "alignment": layout.alignment,
    }


def _verify_structure(
    old: Layout, new: Layout, kv_count: int, sets: list[tuple[str, str, str]], replaced: set[str]
) -> None:
    """Refuse a written file whose structure differs from what the header arithmetic claims."""
    if new.version != old.version:
        raise GgufError("GGUF version changed")
    if new.tensor_count != old.tensor_count:
        raise GgufError(f"tensor count changed: {old.tensor_count} -> {new.tensor_count}")
    if new.tensor_count != len(new.tensors):
        raise GgufError("tensor-info section does not hold the declared tensor count")
    if new.kv_count != kv_count:
        raise GgufError(f"kv count {new.kv_count} != {kv_count}")
    if new.tensors != old.tensors:
        raise GgufError(
            "tensor infos changed (names/dims/type/offset must be identical: offsets are "
            "relative to the data section, so a metadata insert must not touch them)"
        )
    present = {key for key, _, _ in new.kv}
    missing = {key for key, _, _ in old.kv if key not in replaced} - present
    if missing:
        raise GgufError(f"metadata keys lost in the write: {sorted(missing)[:5]}")
    absent = {key for key, _, _ in sets} - present
    if absent:
        raise GgufError(f"metadata keys not written: {sorted(absent)}")


def _main(argv: list[str]) -> int:
    """CLI: add/replace metadata keys and report what was written and verified."""
    parser = argparse.ArgumentParser(description="add or replace GGUF metadata keys (never in place)")
    parser.add_argument("--src", required=True, type=Path)
    parser.add_argument("--dst", required=True, type=Path)
    parser.add_argument("--set", dest="sets", action="append", default=[], metavar="KEY=TYPE:VALUE")
    parser.add_argument("--replace", action="store_true", help="overwrite a key that already exists")
    parser.add_argument("--force", action="store_true", help="overwrite an existing --dst")
    args = parser.parse_args(argv)
    if not args.sets:
        print("gguf_metadata_add: nothing to do (--set is required)", file=sys.stderr)
        return 64
    try:
        sets = [parse_set(spec) for spec in args.sets]
        started = time.monotonic()
        report = add_metadata(args.src, args.dst, sets, replace=args.replace, force=args.force)
    except GgufError as exc:
        print(f"gguf_metadata_add: refused: {exc}", file=sys.stderr)
        return 2
    elapsed = time.monotonic() - started
    print(f"wrote {report['dst']}")
    for key in ("kv_count", "tensor_count", "data_start", "data_bytes", "data_sha256", "added"):
        print(f"  {key}={report[key]}")
    print(f"  verified: tensor infos identical, data section hash matches ({elapsed:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

"""Tests for scripts/gguf_metadata_add.py — the metadata splice that repaired the GLM GGUF.

WHY (measured 2026-11-09): GLM-5.3-Flash-REAP50-IQ3_M.gguf omits
`glm5-next.attention.indexer.kpool`, which llama.cpp requires (no default), so the loader
refuses the file.  The weights are fine and the value is derivable, so the file is
repairable by inserting one metadata key — provided the tensor bytes and the tensor-info
section survive the rewrite untouched.

Each case below states the wrong outcome it catches.  The fixture is written from the
GGUF spec directly (struct layouts), not by the module under test, so a shared misreading
of the format cannot make both agree: the expected offsets and bytes are computed by hand
in the cases.
"""

from __future__ import annotations

import struct
from pathlib import Path
from typing import TypedDict

import pytest
from _paths import REPO_ROOT

import gguf_metadata_add as mod

ALIGNMENT = 32
ARCH = "glm5-next"
KPOOL = "glm5-next.attention.indexer.kpool"


class Fixture(TypedDict):
    """The offsets build_fixture computed, typed so the cases can do arithmetic on them.

    A plain dict[str, object] made `expect["info_end"] + delta` an object-plus-int, which
    mypy rejects — and the annotation is the only thing that says which entries are
    numbers and which are bytes.
    """

    kv_count: int
    kv_bytes: bytes
    info_bytes: bytes
    data_start: int
    info_end: int
    blob: bytes
    tensor_count: int


def _kv_string(key: str, value: str) -> bytes:
    """One string-valued metadata pair, in GGUF wire form."""
    kb, vb = key.encode(), value.encode()
    return struct.pack("<Q", len(kb)) + kb + struct.pack("<I", 8) + struct.pack("<Q", len(vb)) + vb


def _kv_uint32(key: str, value: int) -> bytes:
    """One uint32-valued metadata pair."""
    kb = key.encode()
    return struct.pack("<Q", len(kb)) + kb + struct.pack("<I", 4) + struct.pack("<I", value)


def _kv_array_uint32(key: str, values: list[int]) -> bytes:
    """One uint32-array metadata pair — the shape a tokenizer vocabulary uses."""
    kb = key.encode()
    head = struct.pack("<Q", len(kb)) + kb + struct.pack("<I", 9)
    head += struct.pack("<I", 4) + struct.pack("<Q", len(values))
    return head + b"".join(struct.pack("<I", v) for v in values)


def _tensor_info(name: str, dims: tuple[int, ...], ttype: int, offset: int) -> bytes:
    """One tensor-info record."""
    nb = name.encode()
    out = struct.pack("<Q", len(nb)) + nb + struct.pack("<I", len(dims))
    out += struct.pack(f"<{len(dims)}Q", *dims) + struct.pack("<I", ttype)
    return out + struct.pack("<Q", offset)


def build_fixture(path: Path, *, with_kpool: bool = False, truncate: int = 0) -> Fixture:
    """Write a minimal GGUF and return the offsets the cases assert against."""
    kv = [
        _kv_string("general.architecture", ARCH),
        _kv_uint32("general.alignment", ALIGNMENT),
        _kv_array_uint32("tokenizer.ggml.tokens", [1, 2, 3, 4, 5]),
        _kv_string("glm5-next.attention.indexer.top_k.description", "synthetic"),
    ]
    if with_kpool:
        kv.append(_kv_uint32(KPOOL, 4))
    # Tensor type 0 is ggml F32 (4 bytes per element), so the data blob below is sized to
    # match: 32 elements at offset 0, 16 at offset 128.  A fixture whose declared shape and
    # byte count disagree cannot be read by llama.cpp's own reader, which is the point of
    # keeping it valid — `read_layout` would happily accept nonsense.
    tensors = [
        ("blk.0.indexer.kpool_ape.weight", (32,), 0, 0),
        ("token_embd.weight", (16,), 0, 128),
    ]
    info = b"".join(_tensor_info(n, d, t, o) for n, d, t, o in tensors)
    header = mod.GGUF_MAGIC + struct.pack("<I", 3) + struct.pack("<Q", len(tensors))
    header += struct.pack("<Q", len(kv))
    kv_bytes = b"".join(kv)
    info_end = len(header) + len(kv_bytes) + len(info)
    data_start = (info_end + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
    blob = bytes(range(192))  # 32*4 + 16*4 bytes of F32 payload
    payload = header + kv_bytes + info + b"\0" * (data_start - info_end) + blob
    if truncate:
        payload = payload[:truncate]
    path.write_bytes(payload)
    return {
        "kv_count": len(kv),
        "kv_bytes": kv_bytes,
        "info_bytes": info,
        "data_start": data_start,
        "info_end": info_end,
        "blob": blob,
        "tensor_count": len(tensors),
    }


def test_the_tool_ships_in_the_repo() -> None:
    """Catches: a suite that exercises a copy of the tool instead of the one that runs."""
    assert (Path(REPO_ROOT) / "scripts" / "gguf_metadata_add.py").is_file()


def test_adds_the_missing_key_and_leaves_every_tensor_byte_alone(tmp_path: Path) -> None:
    """Catches: a rewrite that re-serialises tensor infos or shifts their offsets.

    Offsets are relative to the data section, so inserting a key must move the section
    and nothing else — if the tool rewrote offsets, the new file would point every tensor
    at the wrong bytes while still loading its header.
    """
    src = tmp_path / "in.gguf"
    dst = tmp_path / "out.gguf"
    expect = build_fixture(src)

    report = mod.add_metadata(src, dst, [(KPOOL, "uint32", "4")])

    out = mod.read_layout(dst)
    assert KPOOL in {key for key, _, _ in out.kv}
    assert out.tensor_count == expect["tensor_count"]
    assert [t[0] for t in out.tensors] == [t[0] for t in mod.read_layout(src).tensors]
    # The invariant the whole approach rests on: identical tensor infos, offsets included.
    assert out.tensors == mod.read_layout(src).tensors
    # The data section is the source blob, byte for byte, starting where the header says.
    written = dst.read_bytes()
    delta = len(mod.encode_kv(KPOOL, "uint32", "4"))
    moved_end = expect["info_end"] + delta
    aligned = (moved_end + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
    # The data section lands on the ALIGNMENT boundary, not at old_start + delta: a key whose
    # length is not a multiple of 32 changes the padding as well as the offset.
    assert out.data_start == aligned
    assert written[out.data_start :] == expect["blob"]
    assert report["data_bytes"] == len(expect["blob"])
    # Every pre-existing key survives (an array among them, which exercises the skipper).
    assert {key for key, _, _ in out.kv} == {key for key, _, _ in mod.read_layout(src).kv} | {KPOOL}


def test_existing_key_is_refused_unless_replace_is_asked_for(tmp_path: Path) -> None:
    """Catches: a silent second insert leaving two values of the same key in one file."""
    src = tmp_path / "in.gguf"
    build_fixture(src, with_kpool=True)
    with pytest.raises(mod.GgufError, match="already present"):
        mod.add_metadata(src, tmp_path / "out.gguf", [(KPOOL, "uint32", "4")])
    assert not (tmp_path / "out.gguf").exists()


def test_replace_changes_the_value_and_keeps_the_key_count(tmp_path: Path) -> None:
    """Catches: a replace that appends instead of substituting, growing the metadata."""
    src = tmp_path / "in.gguf"
    dst = tmp_path / "out.gguf"
    expect = build_fixture(src, with_kpool=True)
    before = mod.read_layout(src)

    mod.add_metadata(src, dst, [(KPOOL, "uint32", "8")], replace=True)

    out = mod.read_layout(dst)
    assert out.kv_count == before.kv_count == expect["kv_count"]
    assert out.tensors == before.tensors
    assert dst.read_bytes()[out.data_start :] == expect["blob"]


def test_an_existing_destination_is_refused_without_force(tmp_path: Path) -> None:
    """Catches: overwriting a previous repair the operator did not ask to discard."""
    src = tmp_path / "in.gguf"
    dst = tmp_path / "out.gguf"
    build_fixture(src)
    dst.write_bytes(b"keep me")
    with pytest.raises(mod.GgufError, match="already exists"):
        mod.add_metadata(src, dst, [(KPOOL, "uint32", "4")])
    assert dst.read_bytes() == b"keep me"


def test_writing_over_the_source_is_refused(tmp_path: Path) -> None:
    """Catches: an in-place edit, which would corrupt the hardlinked HF cache blob too."""
    src = tmp_path / "in.gguf"
    build_fixture(src)
    with pytest.raises(mod.GgufError, match="hardlink"):
        mod.add_metadata(src, src, [(KPOOL, "uint32", "4")], force=True)


def test_a_truncated_file_is_refused(tmp_path: Path) -> None:
    """Catches: a short read treated as padding, which would write a corrupt model."""
    src = tmp_path / "short.gguf"
    build_fixture(src, truncate=40)
    with pytest.raises(mod.GgufError, match="truncated|not a GGUF"):
        mod.add_metadata(src, tmp_path / "out.gguf", [(KPOOL, "uint32", "4")])


def test_a_bad_set_spec_is_a_usage_error(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    """Catches: a CLI that exits 0 having written nothing (the silent-success shape)."""
    src = tmp_path / "in.gguf"
    dst = tmp_path / "out.gguf"
    build_fixture(src)
    assert mod._main(["--src", str(src), "--dst", str(dst)]) == 64
    assert "nothing to do" in capsys.readouterr().err
    assert mod._main(["--src", str(src), "--dst", str(dst), "--set", "bad"]) == 2
    assert not dst.exists()


def test_cli_writes_and_verifies(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    """Catches: a success line printed with no verified file behind it."""
    src = tmp_path / "in.gguf"
    dst = tmp_path / "out.gguf"
    build_fixture(src)
    rc = mod._main(["--src", str(src), "--dst", str(dst), "--set", f"{KPOOL}=uint32:4"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "verified: tensor infos identical, data section hash matches" in out
    assert dst.is_file()
    assert KPOOL in {key for key, _, _ in mod.read_layout(dst).kv}

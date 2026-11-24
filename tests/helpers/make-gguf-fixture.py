#!/usr/bin/env python3
"""Write a metadata-only GGUF fixture for the header-parsing tests.

Why this exists: on 2026-09-16 __gguf_metadata was found reading
`phi3.rope.scaling.original_context_length` (4096, the LongRoPE *original* window)
instead of `phi3.context_length` (131072) — an unanchored `/context_length/` match with
a last-wins assignment.  It reported a 4096 window for a 131072-native model, which also
fed the autotune's ctx ceiling.  Nothing in the tree could catch it: GGUF metadata needs
no GPU, but there was no fixture to parse, so the only oracle was a real 4 GB card run.

A GGUF header is magic + version + tensor_count + kv_count, then counted
(key, type, value) triples; the parser walks that and never touches tensor data.  So a
fixture with zero tensors is sufficient, tiny, and text-free of binaries — generated at
test time rather than committed.

Usage: make-gguf-fixture.py <case> <out-path>
Cases: both-keys | rope-only | general-ctx | plain-ctx | no-ctx | junk-name |
       kv-geometry | kv-array | hybrid-kv | no-kv |
       layout-complete | layout-short | layout-split

A case may name a `tensors:` entry: block_count = the number of blk.<N>.attn_q.weight
tensors to write (so a census has something to count), plus any extra (name, type, dims)
rows.  The tensor table is written after the metadata exactly as llama.cpp's loader
expects to read it — name, n_dims, dims, ggml type, data offset — because that layout is
what `__gguf_metadata`'s census walk parses, and a fixture that aped it from memory
could not disagree with the parser (measured 2026-11-15 in ~/.openclaw).
"""

import struct
import sys

TYPE_U32 = 4
TYPE_U64 = 10
TYPE_STRING = 8
TYPE_ARRAY = 9
TYPE_F32 = 6

# ggml tensor type ids the fixtures use: F32 = 0, F16 = 1.
GGML_F32 = 0
GGML_F16 = 1

CASES = {
    # The 2026-09-16 bug: the real window AND the rope-scaling original.  The parser
    # must return 131072, never 4096.
    "both-keys": [
        ("general.architecture", TYPE_STRING, "phi3"),
        ("general.name", TYPE_STRING, "Phi 3.5 Mini Instruct"),
        ("phi3.block_count", TYPE_U32, 32),
        ("phi3.context_length", TYPE_U32, 131072),
        ("phi3.rope.scaling.original_context_length", TYPE_U32, 4096),
    ],
    # Only the rope key.  Nothing here is a usable window, so the parser must fall back
    # to its own default rather than adopt 2048 — the distinction between "not found"
    # and "found the wrong one" is the whole point.
    "rope-only": [
        ("general.architecture", TYPE_STRING, "phi3"),
        ("phi3.block_count", TYPE_U32, 32),
        ("phi3.rope.scaling.original_context_length", TYPE_U32, 2048),
    ],
    # Some conversions write the window on `general` rather than the architecture.
    "general-ctx": [
        ("general.architecture", TYPE_STRING, "llama"),
        ("general.context_length", TYPE_U32, 8192),
        ("llama.block_count", TYPE_U32, 28),
    ],
    "plain-ctx": [
        ("general.architecture", TYPE_STRING, "qwen2"),
        ("qwen2.context_length", TYPE_U32, 32768),
        ("qwen2.block_count", TYPE_U32, 28),
    ],
    "no-ctx": [
        ("general.architecture", TYPE_STRING, "llama"),
        ("llama.block_count", TYPE_U32, 24),
    ],
    # KV GEOMETRY (card bf92711c).  Qwen3-Coder-30B's shape: 48 layers, 4 KV heads, head
    # dim 128.  The autotune must price the KV cache from these three numbers rather than
    # the shape-agnostic n_layers*2.0 constant — 50.88 MiB/1k against the constant's 96.
    "kv-geometry": [
        ("general.architecture", TYPE_STRING, "qwen2"),
        ("qwen2.block_count", TYPE_U32, 48),
        ("qwen2.context_length", TYPE_U32, 131072),
        ("qwen2.attention.head_count_kv", TYPE_U32, 4),
        ("qwen2.attention.key_length", TYPE_U32, 128),
    ],
    # The ARRAY form MoE architectures write (gpt-oss, Mixtral): head_count_kv as a
    # per-layer array.  The parser's array branch is what reads it; without that branch the
    # geometry reads as ABSENT on exactly the models whose KV cost is largest.
    "kv-array": [
        ("general.architecture", TYPE_STRING, "gpt-oss"),
        ("gpt-oss.block_count", TYPE_U32, 36),
        ("gpt-oss.context_length", TYPE_U32, 131072),
        ("gpt-oss.attention.head_count_kv", TYPE_ARRAY, [8, 8, 8, 8]),
        ("gpt-oss.attention.key_length", TYPE_U32, 128),
    ],
    # A header with NO KV keys at all: the fallback direction.  The estimate must still
    # answer (the old constant) and the caller must be able to SAY it fell back.
    "no-kv": [
        ("general.architecture", TYPE_STRING, "llama"),
        ("llama.block_count", TYPE_U32, 24),
        ("llama.context_length", TYPE_U32, 8192),
    ],
    # A GGUF whose own metadata carries a junk `general.name` — what Unsloth/HF merges
    # write into a file ("Unsloth_Gguf_Bs7Prgf5", "Hf Model", "Merged").  `model scan`
    # composes each registry row from these, so the scan tests need a fixture whose name
    # must NOT replace an operator-curated registry name (measured 2026-09-17).
    "junk-name": [
        ("general.architecture", TYPE_STRING, "qwen2"),
        ("general.name", TYPE_STRING, "Unsloth_Gguf_JunkFixture"),
        ("qwen2.context_length", TYPE_U32, 32768),
        ("qwen2.block_count", TYPE_U32, 28),
    ],
    # Hybrid SSM/attention MoE (Nemotron-H / LFM3 style): layer 0 is SSM with 0 KV heads
    # while later attention layers have 2 KV heads, and file_type=39 is NVFP4.
    "hybrid-kv": [
        ("general.architecture", TYPE_STRING, "nemotron_h_moe"),
        ("general.file_type", TYPE_U32, 39),
        ("nemotron_h_moe.block_count", TYPE_U32, 89),
        ("nemotron_h_moe.context_length", TYPE_U32, 131072),
        ("nemotron_h_moe.attention.head_count_kv", TYPE_ARRAY, [0, 0, 2, 0, 0, 2, 0, 0, 2, 0, 0, 2]),
        ("nemotron_h_moe.attention.key_length", TYPE_U32, 128),
    ],
    # LAYOUT CENSUS (2026-11-24).  Inkling-2-Mini's measured shape: five blocks declared,
    # five physical blocks present, one complete model.
    "layout-complete": [
        ("general.architecture", TYPE_STRING, "llama"),
        ("llama.block_count", TYPE_U32, 5),
        ("llama.context_length", TYPE_U32, 8192),
    ],
    # The Inkling-2-Mini failure as measured: eight blocks DECLARED
    # (inkling2.block_count=48 over physical blocks 0..23, 24 -> 8 here), only five
    # carrying tensors.  A census reading block_count against the highest physical block
    # index must call this SHORT; the loader only ever said
    # "check_tensor_dims: tensor 'blk.5.attn_q.weight' not found".
    "layout-short": [
        ("general.architecture", TYPE_STRING, "llama"),
        ("llama.block_count", TYPE_U32, 8),
        ("llama.context_length", TYPE_U32, 8192),
    ],
    # One shard of a split model: split.count > 1 with the declared blocks all present.
    # It is COMPLETE by the block census and still cannot load alone.
    "layout-split": [
        ("general.architecture", TYPE_STRING, "llama"),
        ("llama.block_count", TYPE_U32, 5),
        ("llama.context_length", TYPE_U32, 8192),
        ("split.count", TYPE_U32, 3),
    ],
}

# How many physical blk.<N>.attn_q.weight tensors each layout case actually writes.
LAYOUT_TENSORS = {
    "layout-complete": 5,
    "layout-short": 5,
    "layout-split": 5,
}


def encode(key, vtype, value):
    key_b = key.encode()
    out = struct.pack("<Q", len(key_b)) + key_b + struct.pack("<I", vtype)
    if vtype == TYPE_STRING:
        val_b = value.encode()
        out += struct.pack("<Q", len(val_b)) + val_b
    elif vtype == TYPE_U32:
        out += struct.pack("<I", value)
    elif vtype == TYPE_U64:
        out += struct.pack("<Q", value)
    elif vtype == TYPE_F32:
        out += struct.pack("<f", float(value))
    elif vtype == TYPE_ARRAY:
        # GGUF array: element type (u32), count (u64), then the elements.  The parser reads
        # element 0 for the KV geometry and skips the rest by element width.
        out += struct.pack("<I", TYPE_U32) + struct.pack("<Q", len(value))
        out += b"".join(struct.pack("<I", v) for v in value)
    else:
        raise ValueError(f"unsupported fixture type {vtype}")
    return out


def encode_tensor(name, dims, ggml_type, offset):
    """One tensor-table row, in the order llama.cpp's loader reads it."""
    name_b = name.encode()
    out = struct.pack("<Q", len(name_b)) + name_b
    out += struct.pack("<I", len(dims))
    out += b"".join(struct.pack("<Q", d) for d in dims)
    out += struct.pack("<I", ggml_type)
    out += struct.pack("<Q", offset)
    return out


def main():
    case, out_path = sys.argv[1], sys.argv[2]
    if case not in CASES:
        sys.exit(f"unknown case {case!r}; known: {', '.join(CASES)}")
    n_blocks = LAYOUT_TENSORS.get(case, 0)
    tensors = []
    for n in range(n_blocks):
        tensors.append((f"blk.{n}.attn_q.weight", (16, 16), GGML_F16, n * 512))
    # A file that carries blocks always carries unblocked tensors too, so the census
    # walk meets names it must not mistake for blocks.
    if n_blocks:
        tensors.append(("token_embd.weight", (16, 16), GGML_F16, n_blocks * 512))
    body = b"".join(encode(k, t, v) for k, t, v in CASES[case])
    header = b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", len(tensors)) + struct.pack("<Q", len(CASES[case]))
    table = b"".join(encode_tensor(n, d, t, o) for n, d, t, o in tensors)
    with open(out_path, "wb") as fh:
        fh.write(header + body + table)
    print(out_path)


if __name__ == "__main__":
    main()

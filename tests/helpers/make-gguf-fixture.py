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
Cases: both-keys | rope-only | general-ctx | plain-ctx | no-ctx
"""
import struct
import sys

TYPE_U32 = 4
TYPE_U64 = 10
TYPE_STRING = 8

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
    else:
        raise ValueError(f"unsupported fixture type {vtype}")
    return out


def main():
    case, out_path = sys.argv[1], sys.argv[2]
    if case not in CASES:
        sys.exit(f"unknown case {case!r}; known: {', '.join(CASES)}")
    body = b"".join(encode(k, t, v) for k, t, v in CASES[case])
    header = b"GGUF" + struct.pack("<I", 3) + struct.pack("<Q", 0) + struct.pack("<Q", len(CASES[case]))
    with open(out_path, "wb") as fh:
        fh.write(header + body)
    print(out_path)


if __name__ == "__main__":
    main()

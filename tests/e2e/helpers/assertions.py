"""Assertion helpers for E2E testing.

Provides:
- assert_valid_pydantic: verifies Pydantic model validation and serialization
- assert_validation_error: verifies Pydantic validation failure with field/message checking
- assert_referential_integrity: verifies graph source/target endpoints exist
- assert_clean_shell_export: verifies shell export syntax and parses environment dict
- assert_no_resource_warnings: context manager asserting zero ResourceWarning leaks
"""

from __future__ import annotations

import re
import warnings
from contextlib import contextmanager
from typing import Any, Generator, TypeVar

try:
    from pydantic import BaseModel, ValidationError
except ImportError:
    BaseModel = Any  # type: ignore
    ValidationError = Exception  # type: ignore

T = TypeVar("T", bound=Any)


def assert_valid_pydantic(model_cls: type[T], data: Any) -> T:
    """Validate that data satisfies model_cls and round-trips cleanly."""
    if hasattr(model_cls, "model_validate"):
        instance = model_cls.model_validate(data)
    elif isinstance(data, dict):
        instance = model_cls(**data)
    else:
        instance = model_cls(data)

    # Verify serialization
    if hasattr(instance, "model_dump"):
        dumped = instance.model_dump()
        assert dumped is not None, f"model_dump returned None for {model_cls}"
    elif hasattr(instance, "dict"):
        dumped = instance.dict()
        assert dumped is not None, f"dict returned None for {model_cls}"

    return instance


def assert_validation_error(
    model_cls: type[Any],
    data: Any,
    field_name: str | None = None,
    match: str | None = None,
) -> Any:
    """Validate that instantiating model_cls with data raises ValidationError on field_name."""
    try:
        if hasattr(model_cls, "model_validate"):
            model_cls.model_validate(data)
        elif isinstance(data, dict):
            model_cls(**data)
        else:
            model_cls(data)
    except ValidationError as exc:
        if field_name is not None:
            field_locs = []
            for err in exc.errors():
                loc = [str(x) for x in err.get("loc", ())]
                field_locs.extend(loc)
            assert field_name in field_locs, (
                f"Expected validation error on field {field_name!r}, but got errors on: {field_locs}. Full error: {exc}"
            )
        if match is not None:
            err_str = str(exc)
            assert re.search(match, err_str, re.IGNORECASE), (
                f"Validation error message did not match {match!r}: {err_str}"
            )
        return exc
    except Exception as exc:
        raise AssertionError(f"Expected ValidationError for {model_cls}, but got {type(exc).__name__}: {exc}") from exc

    raise AssertionError(f"Expected ValidationError for {model_cls} on data {data!r}, but validation succeeded.")


def assert_referential_integrity(graph: Any) -> None:
    """Assert that all edges in a graph reference existing nodes.

    Accepts either Pydantic Graph model or dict with 'nodes' and 'edges'.
    """
    if hasattr(graph, "nodes") and hasattr(graph, "edges"):
        nodes = graph.nodes
        edges = graph.edges
    elif isinstance(graph, dict):
        nodes = graph.get("nodes", [])
        edges = graph.get("edges", [])
    else:
        raise TypeError(f"Unsupported graph object type: {type(graph)}")

    # Extract node IDs
    node_ids: set[str] = set()
    for n in nodes:
        if hasattr(n, "id"):
            node_ids.add(str(n.id))
        elif isinstance(n, dict):
            node_ids.add(str(n.get("id", "")))
        elif isinstance(n, str):
            node_ids.add(n)

    # Check each edge
    for i, edge in enumerate(edges):
        if hasattr(edge, "source") and hasattr(edge, "target"):
            src = str(edge.source)
            tgt = str(edge.target)
        elif isinstance(edge, dict):
            src = str(edge.get("source", edge.get("from", "")))
            tgt = str(edge.get("target", edge.get("to", "")))
        else:
            raise TypeError(f"Unsupported edge type at index {i}: {type(edge)}")

        assert src in node_ids, (
            f"Referential integrity violation: edge [{i}] source {src!r} not found in graph nodes: {node_ids}"
        )
        assert tgt in node_ids, (
            f"Referential integrity violation: edge [{i}] target {tgt!r} not found in graph nodes: {node_ids}"
        )


def assert_clean_shell_export(export_str: str) -> dict[str, str]:
    """Verify that export_str consists of valid bash export statements and parse them."""
    env_vars: dict[str, str] = {}
    lines = [line.strip() for line in export_str.strip().splitlines() if line.strip()]

    assert len(lines) > 0, "Shell export output was empty"

    for line in lines:
        if line.startswith("#"):
            continue
        assert line.startswith("export "), f"Line does not start with 'export ': {line!r}"

        rest = line[len("export ") :].strip()
        assert "=" in rest, f"Export statement missing '=' assignment: {line!r}"

        key, val = rest.split("=", 1)
        key = key.strip()
        assert re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key), f"Illegal shell variable name: {key!r}"

        # Strip surrounding quotes if present
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            clean_val = val[1:-1]
        else:
            clean_val = val

        env_vars[key] = clean_val

    return env_vars


@contextmanager
def assert_no_resource_warnings() -> Generator[list[warnings.WarningMessage], None, None]:
    """Assert that no ResourceWarning is emitted during execution of code block."""
    with warnings.catch_warnings(record=True) as captured:
        warnings.simplefilter("always", ResourceWarning)
        yield captured

    resource_warnings = [w for w in captured if issubclass(w.category, ResourceWarning)]
    assert not resource_warnings, (
        f"Detected {len(resource_warnings)} unclosed resource warnings: "
        f"{[f'{w.filename}:{w.lineno}: {w.message}' for w in resource_warnings]}"
    )

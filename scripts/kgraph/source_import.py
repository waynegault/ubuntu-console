"""Import an external memory source into the ``files``/``chunks`` store kgraph reads.

The graph's scored edges (``cooccurrence_count`` / ``semantic_score``) come from
the ``files`` + ``chunks`` schema handled by
``memory_import._MemoryStoreIngest``. A memory source is adapted to
``SourceRecord`` rows and written to that schema, so the existing, tested ingest
path stays the only graph builder. The ``MemorySource`` protocol is the seam a
new source implements; the markdown adapter below is the first one.

WHY A SEPARATE SOURCE STORE
    The live ``memory_*`` registry is a different schema, and its import branch
    emits no co-occurrence edges. Writing a files/chunks store and passing it to
    ``kgraph update --import-db`` reuses the scored-edge path without mutating
    the registry or adding a second graph builder.

INVESTIGATOR LAYERS 1-5
    Implement ``MemorySource`` for a layer: yield one ``SourceRecord`` per
    document/chunk, set ``source_kind`` (for example ``investigator-layer1``),
    and put the layer/case/document in ``path`` so the graph's file nodes carry
    the provenance. ``source_meta`` keeps the kind, date and section for audit;
    the graph reader ignores that table.

REF: "kgraph's memory half is STARVED, not broken" (workboard KG-SOURCE-001) —
the live memory store is the markdown under ``~/.openclaw/memory``, and the
registry is the schema the graph consumes.
"""

import hashlib
import json
import os
import re
import sqlite3
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

_DATE_STEM = re.compile(r'^\d{4}-\d{2}-\d{2}$')
_DATE_HEADING = re.compile(r'^#\s+(\d{4}-\d{2}-\d{2})\s*$')
_PROJECT = re.compile(r'<!--\s*project:\s*(.*?)\s*-->')

SOURCE_KIND_MARKDOWN = 'markdown-memory'
_CHUNK_ID_PREFIX = 'src-'
_CHUNK_ID_CHARS = 20

_SCHEMA = (
    'CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY)',
    'CREATE TABLE IF NOT EXISTS chunks ('
    'id TEXT PRIMARY KEY, path TEXT NOT NULL, start_line INTEGER, end_line INTEGER, '
    'text TEXT NOT NULL, embedding TEXT)',
    'CREATE TABLE IF NOT EXISTS source_meta ('
    'chunk_id TEXT PRIMARY KEY, source_kind TEXT NOT NULL, source_date TEXT, '
    'section TEXT, scope TEXT, metadata TEXT)',
)


@dataclass(frozen=True, slots=True)
class SourceRecord:
    """One document section a memory source contributes to the graph.

    ``path`` is what a reader/citation resolves, ``start_line``/``end_line`` are
    1-based and inclusive, and ``source_kind`` labels the adapter (for example
    ``markdown-memory`` or ``investigator-layer1``). ``metadata`` is free-form
    source provenance kept in ``source_meta``.
    """

    path: str
    start_line: int
    end_line: int
    text: str
    source_kind: str
    source_date: str | None = None
    section: str | None = None
    scope: str | None = None
    metadata: dict[str, str] = field(default_factory=dict)


class MemorySource(Protocol):
    """The seam a new source implements: yield records, write nothing."""

    def iter_records(self) -> Iterator[SourceRecord]:
        """Yield the source's document sections."""
        ...


@dataclass(frozen=True, slots=True)
class ImportResult:
    """What one write produced."""

    dbpath: str
    files: int
    chunks: int
    skipped: int


class MarkdownMemorySource:
    """Split dated markdown memory files into one record per ``##`` section.

    The live memory is ``~/.openclaw/memory/YYYY-MM-DD.md`` with a ``# DATE``
    title and ``##`` sections. A file without ``##`` headings is imported as one
    record from the body, so the adapter never drops content silently.
    """

    def __init__(self, root: str, *, min_chars: int = 1) -> None:
        if min_chars < 0:
            raise ValueError('min_chars must be non-negative')
        self.root = os.path.abspath(os.path.expanduser(root))
        self.min_chars = min_chars
        if not os.path.exists(self.root):
            raise FileNotFoundError(self.root)

    def _paths(self) -> list[Path]:
        root = Path(self.root)
        if root.is_dir():
            return sorted(root.glob('*.md'))
        return [root]

    def iter_records(self) -> Iterator[SourceRecord]:
        for path in self._paths():
            yield from self._records_for(path)

    def _records_for(self, path: Path) -> Iterator[SourceRecord]:
        lines = path.read_text(encoding='utf-8').splitlines()
        date = path.stem if _DATE_STEM.match(path.stem) else None
        for line in lines:
            match = _DATE_HEADING.match(line)
            if match:
                date = match.group(1)
                break

        starts = [i for i, line in enumerate(lines) if line.startswith('## ')]
        if not starts:
            body_start = 1 if lines and lines[0].startswith('# ') else 0
            text = '\n'.join(lines[body_start:]).strip()
            if len(text) >= self.min_chars:
                yield SourceRecord(
                    path=str(path),
                    start_line=body_start + 1,
                    end_line=len(lines),
                    text=text,
                    source_kind=SOURCE_KIND_MARKDOWN,
                    source_date=date,
                    scope='shared',
                )
            return

        for position, start in enumerate(starts):
            end = starts[position + 1] - 1 if position + 1 < len(starts) else len(lines) - 1
            while end > start and not lines[end].strip():
                end -= 1
            text = '\n'.join(lines[start:end + 1]).strip()
            if len(text) < self.min_chars:
                continue
            heading = lines[start][3:].strip()
            project = _PROJECT.search(heading)
            metadata = {'project': project.group(1)} if project else {}
            yield SourceRecord(
                path=str(path),
                start_line=start + 1,
                end_line=end + 1,
                text=text,
                source_kind=SOURCE_KIND_MARKDOWN,
                source_date=date,
                section=_PROJECT.sub('', heading).strip(),
                scope='shared',
                metadata=metadata,
            )


def _chunk_id(record: SourceRecord) -> str:
    raw = (
        f'{record.path}\x1f{record.start_line}\x1f{record.end_line}\x1f{record.text}'
    )
    digest = hashlib.sha1(raw.encode('utf-8')).hexdigest()[:_CHUNK_ID_CHARS]
    return _CHUNK_ID_PREFIX + digest


def _under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + os.sep)


def write_files_chunks(records: Iterable[SourceRecord], dbpath: str, *,
                       prune_prefix: str | None = None) -> ImportResult:
    """Write *records* to the ``files``/``chunks`` store at *dbpath*.

    Idempotent: a path's previous chunks are replaced, so a re-import cannot
    leave a section that was deleted from the source. ``prune_prefix`` removes
    rows for a source root that no longer contributes a path (a whole file
    deleted), while leaving rows from other sources alone.
    """
    rows: list[SourceRecord] = []
    skipped = 0
    for record in records:
        if not record.text or record.end_line < record.start_line:
            skipped += 1
            continue
        rows.append(record)

    dbpath = os.path.abspath(os.path.expanduser(dbpath))
    parent = os.path.dirname(dbpath)
    if parent:
        os.makedirs(parent, exist_ok=True)
    prefix = (
        os.path.abspath(os.path.expanduser(prune_prefix))
        if prune_prefix else None
    )
    paths = {record.path for record in rows}

    conn = sqlite3.connect(dbpath)
    try:
        with conn:
            for statement in _SCHEMA:
                conn.execute(statement)

            if prefix is not None:
                for (path,) in conn.execute('SELECT DISTINCT path FROM chunks').fetchall():
                    if _under(path, prefix) and path not in paths:
                        _delete_path(conn, path)
                for (path,) in conn.execute('SELECT path FROM files').fetchall():
                    if _under(path, prefix) and path not in paths:
                        conn.execute('DELETE FROM files WHERE path=?', (path,))

            for path in paths:
                _delete_path(conn, path)
                conn.execute('INSERT OR IGNORE INTO files(path) VALUES (?)', (path,))

            for record in rows:
                chunk_id = _chunk_id(record)
                conn.execute(
                    'INSERT OR REPLACE INTO chunks'
                    ' (id, path, start_line, end_line, text, embedding)'
                    ' VALUES (?, ?, ?, ?, ?, NULL)',
                    (chunk_id, record.path, record.start_line, record.end_line,
                     record.text),
                )
                metadata = (
                    json.dumps(record.metadata, sort_keys=True)
                    if record.metadata else None
                )
                conn.execute(
                    'INSERT OR REPLACE INTO source_meta'
                    ' (chunk_id, source_kind, source_date, section, scope, metadata)'
                    ' VALUES (?, ?, ?, ?, ?, ?)',
                    (chunk_id, record.source_kind, record.source_date,
                     record.section, record.scope, metadata),
                )
    finally:
        conn.close()

    return ImportResult(dbpath=dbpath, files=len(paths), chunks=len(rows),
                        skipped=skipped)


def _delete_path(conn: sqlite3.Connection, path: str) -> None:
    old_ids = [
        str(row[0]) for row in conn.execute(
            'SELECT id FROM chunks WHERE path=?', (path,)
        ).fetchall()
    ]
    conn.executemany(
        'DELETE FROM source_meta WHERE chunk_id=?',
        [(chunk_id,) for chunk_id in old_ids],
    )
    conn.execute('DELETE FROM chunks WHERE path=?', (path,))


def import_source(source: MemorySource, dbpath: str, *,
                  prune_prefix: str | None = None) -> ImportResult:
    """Collect *source* and write it to *dbpath*."""
    return write_files_chunks(
        source.iter_records(), dbpath, prune_prefix=prune_prefix
    )

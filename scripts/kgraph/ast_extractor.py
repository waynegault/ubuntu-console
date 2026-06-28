"""AST-based code-to-concept extraction using tree-sitter.

Extracts function/class/variable definitions, call graphs, and
file-level dependencies from source files (Bash, Python initially).
No API calls — deterministic, language-specific parsing.

The extractor reads a repo directory, walks the tree, and produces
a graph dict with typed nodes and labelled edges, suitable for
merging into the main kgraph.

Supported languages: bash, python (add via extra grammar install).
"""

import re
from pathlib import Path

_AST_AVAILABLE = False
try:
    from tree_sitter import Parser, Language, Query, QueryCursor
    _AST_AVAILABLE = True
except ImportError:
    Parser = None

_LANGUAGES = {}

def _load_grammars():
    """Lazy-load tree-sitter language grammars."""
    global _LANGUAGES, _AST_AVAILABLE
    if _LANGUAGES or not _AST_AVAILABLE:
        return _LANGUAGES
    try:
        import tree_sitter_bash
        import tree_sitter_python
        _LANGUAGES['bash'] = Language(tree_sitter_bash.language())
        _LANGUAGES['python'] = Language(tree_sitter_python.language())
    except ImportError:
        _AST_AVAILABLE = False
    return _LANGUAGES


# ── helpers ─────────────────────────────────────────────────────────────

def _slug(text: str) -> str:
    return re.sub(r'[^a-z0-9_]+', '_', text.lower()).strip('_')


def _query_captures(lang: Language, query_text: str, root_node) -> list[tuple]:
    """Run a tree-sitter query and return (node, capture_name) tuples.

    tree-sitter v0.25 returns matches as list of
    (pattern_index, {capture_name: [node, ...], ...})
    """
    q = Query(lang, query_text)
    cursor = QueryCursor(q)
    results = []
    for _pattern_index, captures_dict in cursor.matches(root_node):
        for cap_name, nodes in captures_dict.items():
            for node in nodes:
                results.append((node, cap_name))
    return results



# ── file extension → language lookup ──────────────────────────────────

EXT_LANG = {
    '.sh': 'bash',
    '.bash': 'bash',
    '.zsh': 'bash',
    '.py': 'python',
    '.pyw': 'python',
}

# ── Bash query patterns ───────────────────────────────────────────────

BASH_QUERIES = {
    'function_def': """
      (function_definition
        name: (word) @name
      ) @func
    """,
    'function_call': """
      (command_name
        (word) @call
      )
    """,
    'variable_def': """
      (variable_assignment
        name: (variable_name) @name
      ) @assign
    """,
    'variable_export': """
      (declaration_command
        name: (variable_name) @name
      ) @export
    """,
}

# ── Python query patterns ────────────────────────────────────────────

PYTHON_QUERIES = {
    'function_def': """
      (function_definition
        name: (identifier) @name
      ) @func
    """,
    'class_def': """
      (class_definition
        name: (identifier) @name
      ) @class
    """,
    'import': """
      (import_statement
        name: (dotted_name) @module
      )
    """,
    'import_from': """
      (import_from_statement
        module_name: (dotted_name) @module
        name: (dotted_name) @name
      )
    """,
    'function_call': """
      (call
        function: (identifier) @call
      )
    """,
    'method_call': """
      (call
        function: (attribute
          attribute: (identifier) @call
        )
      )
    """,
    'async_function': """
      (function_definition
        name: (identifier) @name
      ) @func
    """,
}


# ── public API ────────────────────────────────────────────────────────


def ast_available() -> bool:
    """Return True when tree-sitter and grammars are installed."""
    _load_grammars()
    return _AST_AVAILABLE and bool(_LANGUAGES)


def extract_repo_graph(repo_root: str, **kwargs) -> dict:
    """Walk a repo directory and extract nodes/edges via AST.

    Args:
        repo_root: Absolute path to the repository root.
        include_variables: Include variable/assignment nodes (noisier).
        max_files: Max source files to parse (0 = unlimited).

    Returns:
        A dict with 'nodes' and 'edges' lists ready for kgraph.
    """
    _load_grammars()
    if not _AST_AVAILABLE:
        return {'nodes': [], 'edges': [], '_meta': {'error': 'tree-sitter not available'}}

    include_variables = kwargs.get('include_variables', False)
    max_files = kwargs.get('max_files', 0)
    scan_subdirs = kwargs.get('subdirs', None)  # list of subdirs or None for all

    graph = {'nodes': [], 'edges': []}
    node_ids = set()
    edge_keys = set()

    def add_node(node: dict):
        nid = str(node.get('id', ''))
        if not nid or nid in node_ids:
            return
        node_ids.add(nid)
        graph['nodes'].append(node)

    def add_edge(edge: dict):
        src = str(edge.get('from', ''))
        dst = str(edge.get('to', ''))
        label = str(edge.get('label', ''))
        key = (src, dst, label)
        if not src or not dst or key in edge_keys:
            return
        edge_keys.add(key)
        graph['edges'].append(edge)

    # ── file discovery ──
    root = Path(repo_root).resolve()
    source_files = []
    for ext, lang in EXT_LANG.items():
        pattern = f'**/*{ext}'
        for fpath in root.glob(pattern):
            # Skip hidden dirs, venv, node_modules, .git
            parts = fpath.relative_to(root).parts
            if any(p.startswith('.') or p in ('venv', 'node_modules', '__pycache__', 'dist', 'build', '.git') for p in parts):
                continue
            if scan_subdirs:
                if not any(fpath.relative_to(root).as_posix().startswith(s) for s in scan_subdirs):
                    continue
            source_files.append((fpath, lang))

    if max_files and len(source_files) > max_files:
        source_files = source_files[:max_files]

    # ── per-file extraction ──
    parsers = {}
    file_node_ids = {}

    for fpath, lang in source_files:
        grammar_lang = _LANGUAGES.get(lang)
        if not grammar_lang:
            continue
        if lang not in parsers:
            parsers[lang] = Parser(grammar_lang)
        parser = parsers[lang]

        try:
            with open(fpath, 'rb') as f:
                code = f.read()
        except (OSError, IOError):
            continue

        rel_path = fpath.relative_to(root).as_posix()
        file_basename = fpath.name
        file_id = f'ast_file:{_slug(rel_path)}'
        file_node_ids[rel_path] = file_id

        add_node({
            'id': file_id,
            'label': file_basename,
            'type': 'file',
            'path': str(fpath),
            'rel_path': rel_path,
            'lang': lang,
            'source': 'ast',
        })

        tree = parser.parse(code)
        root_node = tree.root_node

        # ── function/class definitions ──
        if lang == 'python':
            _extract_python_defs(root_node, code, rel_path, file_id,
                                 add_node, add_edge, include_variables)
        elif lang == 'bash':
            _extract_bash_defs(root_node, code, rel_path, file_id,
                               add_node, add_edge, include_variables)

        # ── calls (both languages) ──
        _extract_calls(root_node, code, lang, rel_path, file_id,
                       add_node, add_edge)

    # ── inter-file refs from imports ──
    _resolve_import_edges(file_node_ids, graph, add_edge)

    graph['_meta'] = {
        'source': 'ast',
        'files_parsed': len(source_files),
        'languages': list(set(EXT_LANG.get(fpath.suffix, '') for fpath, _ in source_files)),
    }
    return graph


# ── language-specific extraction helpers ──────────────────────────────


def _extract_bash_defs(root_node, code, rel_path, file_id,
                       add_node, add_edge, include_variables):
    """Extract bash function definitions and variable assignments."""
    try:
        lang = _LANGUAGES['bash']
    except KeyError:
        return

    captures = _query_captures(lang, BASH_QUERIES['function_def'], root_node)

    func_names = set()
    for node, tag in captures:
        if tag == 'name':
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            slug = _slug(name)
            nid = f'ast_func:{slug}'
            add_node({
                'id': nid,
                'label': name.strip(),
                'type': 'function',
                'language': 'bash',
                'source': 'ast',
                'file': rel_path,
                'confidence': 'EXTRACTED',
            })
            func_names.add(name.strip())
            add_edge({
                'from': file_id,
                'to': nid,
                'label': 'defines',
                'confidence': 'EXTRACTED',
            })

    if include_variables:
        for node, tag in _query_captures(lang, BASH_QUERIES['variable_def'], root_node):
            if tag == 'name':
                name = _node_text(node, code)
                if not name or not name.strip():
                    continue
                slug = _slug(name)
                nid = f'ast_var:{slug}'
                add_node({
                    'id': nid,
                    'label': name.strip(),
                    'type': 'variable',
                    'language': 'bash',
                    'source': 'ast',
                    'confidence': 'EXTRACTED',
                })
                add_edge({
                    'from': file_id,
                    'to': nid,
                    'label': 'defines',
                    'confidence': 'EXTRACTED',
                })


def _extract_python_defs(root_node, code, rel_path, file_id,
                         add_node, add_edge, include_variables):
    """Extract Python function and class definitions."""
    try:
        lang = _LANGUAGES['python']
    except KeyError:
        return

    # Functions
    for node, tag in _query_captures(lang, PYTHON_QUERIES['function_def'], root_node):
        if tag == 'name':
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            slug = _slug(name)
            nid = f'ast_func:{slug}'
            # Check if async
            parent = node.parent
            is_async = parent and parent.type == 'function_definition' and any(
                c.type == 'async' for c in parent.children
            )
            add_node({
                'id': nid,
                'label': name.strip(),
                'type': 'function',
                'language': 'python',
                'source': 'ast',
                'async': is_async,
                'file': rel_path,
                'confidence': 'EXTRACTED',
            })
            add_edge({
                'from': file_id,
                'to': nid,
                'label': 'defines',
                'confidence': 'EXTRACTED',
            })

    # Classes
    for node, tag in _query_captures(lang, PYTHON_QUERIES['class_def'], root_node):
        if tag == 'name':
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            slug = _slug(name)
            nid = f'ast_class:{slug}'
            add_node({
                'id': nid,
                'label': name.strip(),
                'type': 'class',
                'language': 'python',
                'source': 'ast',
                'file': rel_path,
                'confidence': 'EXTRACTED',
            })
            add_edge({
                'from': file_id,
                'to': nid,
                'label': 'defines',
                'confidence': 'EXTRACTED',
            })

    # Imports
    for node, tag in _query_captures(lang, PYTHON_QUERIES['import'], root_node):
        if tag == 'module':
            module = _node_text(node, code)
            if module:
                slug = _slug(module)
                nid = f'ast_module:{slug}'
                add_node({
                    'id': nid,
                    'label': module.strip(),
                    'type': 'module',
                    'language': 'python',
                    'source': 'ast',
                    'confidence': 'EXTRACTED',
                })
                add_edge({
                    'from': file_id,
                    'to': nid,
                    'label': 'imports',
                    'confidence': 'EXTRACTED',
                })

    for node, tag in _query_captures(lang, PYTHON_QUERIES['import_from'], root_node):
        if tag == 'module':
            module = _node_text(node, code)
            if module:
                slug = _slug(module)
                nid = f'ast_module:{slug}'
                add_node({
                    'id': nid,
                    'label': module.strip(),
                    'type': 'module',
                    'language': 'python',
                    'source': 'ast',
                    'confidence': 'EXTRACTED',
                })
                add_edge({
                    'from': file_id,
                    'to': nid,
                    'label': 'imports',
                    'confidence': 'EXTRACTED',
                })


def _extract_calls(root_node, code, lang, rel_path, file_id,
                   add_node, add_edge):
    """Extract function/method call references (not definitions)."""
    try:
        grammar_lang = _LANGUAGES[lang]
    except KeyError:
        return

    if lang == 'python':
        queries = [PYTHON_QUERIES['function_call'], PYTHON_QUERIES['method_call']]
    elif lang == 'bash':
        queries = [BASH_QUERIES['function_call']]
    else:
        return

    seen_calls = set()
    for qtext in queries:
        for node, tag in _query_captures(grammar_lang, qtext, root_node):
            if tag != 'call':
                continue
            name = _node_text(node, code)
            if not name or not name.strip():
                continue
            if name.strip() in seen_calls:
                continue
            seen_calls.add(name.strip())
            slug = _slug(name)
            nid = f'ast_call:{slug}'
            add_node({
                'id': nid,
                'label': name.strip(),
                'type': 'call',
                'language': lang,
                'source': 'ast',
                'confidence': 'EXTRACTED',
            })
            add_edge({
                'from': file_id,
                'to': nid,
                'label': 'calls',
                'confidence': 'EXTRACTED',
            })


def _resolve_import_edges(file_node_ids, graph, add_edge):
    """Connect import nodes to file nodes when module name matches path."""
    nodes_by_label = {}
    for n in graph['nodes']:
        label = str(n.get('label', '')).strip().lower()
        ntype = str(n.get('type', '')).strip().lower()
        if ntype == 'module' and label:
            nodes_by_label[label] = str(n.get('id', ''))

    for n in graph['nodes']:
        ntype = str(n.get('type', '')).strip().lower()
        if ntype != 'module':
            continue
        label = str(n.get('label', '')).strip().lower()
        # Try to find a file node whose rel_path matches the module
        for rel_path, fid in file_node_ids.items():
            rel_stem = Path(rel_path).stem.lower().replace('-', '_')
            if label == rel_stem or label.endswith('.' + rel_stem):
                add_edge({
                    'from': str(n.get('id', '')),
                    'to': fid,
                    'label': 'resolves_to',
                    'confidence': 'INFERRED',
                })
                break


def _node_text(node, code: bytes) -> str:
    try:
        return code[node.start_byte:node.end_byte].decode('utf-8')
    except Exception:
        return ''

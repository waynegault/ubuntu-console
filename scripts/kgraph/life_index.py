"""Life index loading and relation merging.

Exports resolve_life_root(), load_life_index(), load_relations(), and
merge_relations() — functions that load canonical concept data from the
OpenClaw life directory and inject explicit relation edges into graphs.
"""
import os
import re
import json
from .constants import (
    CANONICAL_CONCEPTS_DEFAULT,
    LIFE_ROOT_DEFAULT,
    load_canonical_data,
    normalize_canonical_name,
)


def resolve_life_root(preferred: str | None = None) -> str:
  root = os.path.expanduser(preferred or LIFE_ROOT_DEFAULT)
  return os.path.abspath(root)


def load_life_index(life_root: str | None = None) -> dict:
  root = resolve_life_root(life_root)
  index = {
    'by_slug': {},
    'aliases': {},
    'by_type': {},
    'title_aliases': {},
    'records': [],
  }

  canonical_json = os.path.expanduser(CANONICAL_CONCEPTS_DEFAULT)
  if os.path.isfile(canonical_json):
    try:
      payload = load_canonical_data() if load_canonical_data else json.loads(open(canonical_json, 'r', encoding='utf-8').read())
      for record in payload.get('records', []):
        rec = {
          'slug': str(record.get('slug') or '').strip().lower(),
          'title': str(record.get('title') or '').strip(),
          'type': str(record.get('type') or '').strip().lower(),
          'path': str(record.get('path') or '').strip(),
          'aliases': list(record.get('aliases') or []),
          'status': str(record.get('status') or '').strip().lower(),
        }
        if not rec['slug']:
          continue
        index['records'].append(rec)
        index['by_slug'][rec['slug']] = rec
        index['by_type'].setdefault(rec['type'], []).append(rec)
        canonical_names = [rec['slug'], rec['title']] + rec['aliases']
        for alias in canonical_names:
          norm = normalize_canonical_name(str(alias or ''))
          if norm:
            index['aliases'][norm] = rec
            index['title_aliases'][norm] = rec['title']
      if index['records']:
        return index
    except Exception:
      pass

  if not os.path.isdir(root):
    return index

  type_dirs = ('people', 'agents', 'projects', 'systems', 'repos', 'decisions', 'preferences', 'workflows')
  frontmatter_pat = re.compile(r'^-\s*([a-zA-Z0-9_]+):\s*(.*)$')

  for type_dir in type_dirs:
    base = os.path.join(root, type_dir)
    if not os.path.isdir(base):
      continue
    for name in sorted(os.listdir(base)):
      if not name.endswith('.md'):
        continue
      path = os.path.join(base, name)
      try:
        text = open(path, 'r', encoding='utf-8').read()
      except Exception:
        continue
      lines = text.splitlines()
      title = ''
      metadata = {}
      aliases = []
      in_aliases = False
      for line in lines:
        if line.startswith('# '):
          title = line[2:].strip()
          continue
        m = frontmatter_pat.match(line)
        if m:
          key = m.group(1).strip().lower()
          val = m.group(2).strip()
          metadata[key] = val
          in_aliases = key == 'aliases'
          continue
        if in_aliases and re.match(r'^\s*-\s+', line):
          aliases.append(re.sub(r'^\s*-\s+', '', line).strip())
          continue
        if line.strip() and not line.startswith('  -'):
          in_aliases = False
      slug = os.path.splitext(name)[0].strip().lower()
      rec_type = (metadata.get('type') or type_dir[:-1]).strip().lower()
      record = {
        'slug': slug,
        'title': title or slug,
        'type': rec_type,
        'path': path,
        'aliases': aliases,
        'status': (metadata.get('status') or '').strip().lower(),
      }
      index['records'].append(record)
      index['by_slug'][slug] = record
      index['by_type'].setdefault(rec_type, []).append(record)
      canonical_names = [slug, title] + aliases
      for alias in canonical_names:
        norm = normalize_canonical_name(str(alias or ''))
        if norm:
          index['aliases'][norm] = record
          index['title_aliases'][norm] = record['title']
  return index


def load_relations(life_root: str | None = None) -> dict:
  """Load explicit relations from ~/.openclaw/life/relations.json."""
  root = resolve_life_root(life_root)
  rel_path = os.path.join(root, 'relations.json')
  if not os.path.exists(rel_path):
    return {'relations': []}
  try:
    with open(rel_path, 'r', encoding='utf-8') as f:
      data = json.load(f)
    return {'relations': data.get('relations', [])}
  except Exception:
    return {'relations': []}


def merge_relations(graph: dict, life_root: str | None = None) -> dict:
  """Inject explicit relation edges into the graph."""
  relations = load_relations(life_root).get('relations', [])
  if not relations:
    return graph
  nodes = graph.get('nodes', [])
  edges = graph.get('edges', [])
  # Build slug-to-node-id mapping (assuming node IDs are slugs)
  slug_to_node = {}
  for node in nodes:
    slug = node.get('slug')
    if slug:
      slug_to_node[slug] = node.get('id')
    # Also consider canonical_slug field
    canonical_slug = node.get('canonical_slug')
    if canonical_slug:
      slug_to_node[canonical_slug] = node.get('id')
  # Add edges
  for rel in relations:
    src_slug = rel.get('source')
    tgt_slug = rel.get('target')
    rel_type = rel.get('rel', 'related')
    if not src_slug or not tgt_slug:
      continue
    src_id = slug_to_node.get(src_slug)
    tgt_id = slug_to_node.get(tgt_slug)
    if not src_id or not tgt_id:
      # Optionally create placeholder nodes? For now skip.
      continue
    # Avoid duplicate edges
    edge_exists = any(
      (e.get('from') == src_id or e.get('source') == src_id) and
      (e.get('to') == tgt_id or e.get('target') == tgt_id) and
      e.get('label') == rel_type
      for e in edges
    )
    if not edge_exists:
      edges.append({
        'from': src_id,
        'to': tgt_id,
        'label': rel_type,
        'source': rel.get('source'),
        'target': rel.get('target'),
        'explicit': True,
      })
  graph['edges'] = edges
  return graph

#!/usr/bin/env python3
"""Thin shim for backward compatibility.

Run this file directly or ``python -m kgraph`` — both delegate to the
``kgraph`` package.

When this shim is loaded via ``importlib.util.spec_from_file_location``
(as the test suite does), it temporarily removes itself from
``sys.modules['kgraph']``, imports the real package, then re-exports
all public symbols into the module's global namespace so existing code
continues to work.
"""
import sys as _sys
import os as _os
import importlib as _importlib

_scripts_dir = _os.path.dirname(_os.path.abspath(__file__))
if _scripts_dir not in _sys.path:
    _sys.path.insert(0, _scripts_dir)

# When loaded via spec_from_file_location the shim may or may not be
# registered in sys.modules yet.  Remove it so the package can be
# imported cleanly.
_shim_entry = _sys.modules.get('kgraph')
if _shim_entry is not None and not hasattr(_shim_entry, '__path__'):
    del _sys.modules['kgraph']

_pkg = _importlib.import_module('kgraph')

# Re-exports: populate the shim module's own globals() dict.
_g = globals()
for _name in dir(_pkg):
    if not _name.startswith('_') or _name == '__version__':
        _g[_name] = getattr(_pkg, _name)

# Put the shim (now populated) back in sys.modules for callers that
# loaded us via spec_from_file_location.
_main_mod = _sys.modules.get(__name__)
if _main_mod is not None:
    for _name in dir(_pkg):
        if not _name.startswith('_') or _name == '__version__':
            setattr(_main_mod, _name, getattr(_pkg, _name))
if _shim_entry is not None:
    _sys.modules['kgraph'] = _shim_entry

main = _pkg.main

if __name__ == '__main__':
    # Handle --install before delegating to the package CLI, so the shim
    # script itself gets copied (the --install flag was part of the original
    # monolithic script and tests expect it).
    import shutil as _shutil
    _argv = [a for a in _sys.argv[1:] if not a.startswith('--install')]
    for i, a in enumerate(_sys.argv[1:]):
        if a == '--install':
            _dest = _sys.argv[i + 2] if i + 2 < len(_sys.argv) and not _sys.argv[i + 2].startswith('-') else _os.path.expanduser('~/.openclaw/kgraph.py')
            _parent = _os.path.dirname(_dest)
            if _parent:
                _os.makedirs(_parent, exist_ok=True)
            _shutil.copy2(__file__, _dest)
            _os.chmod(_dest, 0o755)
            print('Installed to', _dest)
            _sys.exit(0)
    main()

"""Load local package resources without a package checksum manifest."""
import json
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[2]


def checked(path):
    """Read a package file, rejecting symlinks and paths outside the package."""
    path = Path(path)
    if path.is_symlink() or not path.resolve().is_relative_to(PACKAGE):
        raise ValueError('Resource escapes the tool directory')
    return path.read_bytes()


def declaration(path, name):
    """Load a Python declaration from a local package file."""
    namespace = {'__file__': str(path), '__name__': 'tool_definition'}
    exec(compile(checked(path), str(path), 'exec'), namespace)
    return namespace[name]


def load_json(path):
    return json.loads(checked(path))

"""Read generated Waybar configs with its first-defined-wins include semantics.

Only literal paths and the quoted SWAY_NOIR_THEME_DIR reference used by this
profile are supported; tests never execute shell expressions from include paths.
"""

import json
from pathlib import Path
import re
import shlex


def load_jsonc(text):
    # Preserve strings while stripping comments and trailing commas.
    text = re.sub(
        r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/',
        lambda match: match[0] if match[0].startswith('"') else " ",
        text,
    )
    text = re.sub(
        r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])',
        lambda match: match[0] if match[0].startswith('"') else "",
        text,
    )
    return json.loads(text)


def merge_defaults(config, defaults):
    # Waybar merges objects recursively; existing scalars/arrays/null win.
    for key, value in defaults.items():
        if key not in config:
            config[key] = value
        elif isinstance(config[key], dict) and isinstance(value, dict):
            merge_defaults(config[key], value)


def load_waybar_config(path, *, theme_dir=None, depth=0):
    if depth > 100:
        raise ValueError("Recursive Waybar include")
    path = Path(path)
    if theme_dir is None:
        theme_dir = path.parent.parent
    config = load_jsonc(path.read_text())
    includes = config.pop("include", [])
    if isinstance(includes, str):
        includes = [includes]
    for include in includes:
        # Tokenize before variable expansion, just like quoted shell expansion:
        # spaces and shell metacharacters in the directory remain literal.
        words = shlex.split(include)
        if len(words) != 1:
            raise ValueError("Expected one quoted Waybar include path")
        target = words[0].replace("${SWAY_NOIR_THEME_DIR}", str(theme_dir))
        defaults = load_waybar_config(target, theme_dir=theme_dir, depth=depth + 1)
        merge_defaults(config, defaults)
    return config

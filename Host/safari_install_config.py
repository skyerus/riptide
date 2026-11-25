"""Inspect and edit the one Hermes setting needed for a scoped Codex launcher."""

from copy import deepcopy
import json
from pathlib import Path
import shutil
import sys

import yaml


def hermes_config(source, launcher, original_binary):
    config = yaml.safe_load(source)
    if not isinstance(config, dict):
        raise ValueError("Expected a Hermes YAML mapping.")
    model = config.get("model")
    if not isinstance(model, dict) or model.get("openai_runtime") != "codex_app_server":
        return None
    configured = model.get("codex_bin") or "codex"
    if not isinstance(configured, str):
        raise ValueError("Hermes model.codex_bin must name an executable.")
    binary = original_binary if configured == launcher else configured
    binary = shutil.which(str(Path(binary).expanduser())) if binary else None
    if not binary or not Path(binary).is_absolute() or binary == launcher:
        raise ValueError("Set Hermes model.codex_bin to the absolute Codex executable before installing.")

    if configured == launcher:
        return {"binary": binary, "config": source}

    root = yaml.compose(source)
    model_node = next(value for key, value in root.value if key.value == "model")
    fields = {key.value: (key, value) for key, value in model_node.value}
    quoted = json.dumps(launcher, ensure_ascii=False)
    if "codex_bin" in fields:
        _, node = fields["codex_bin"]
        revised = source[:node.start_mark.index] + quoted + source[node.end_mark.index:]
    elif model_node.flow_style:
        key, _ = fields["openai_runtime"]
        offset = key.start_mark.index
        revised = source[:offset] + f"codex_bin: {quoted}, " + source[offset:]
    else:
        key, _ = fields["openai_runtime"]
        offset, column = key.start_mark.index, key.start_mark.column
        revised = source[:offset] + f"codex_bin: {quoted}\n" + " " * column + source[offset:]

    expected = deepcopy(config)
    expected["model"]["codex_bin"] = launcher
    if yaml.safe_load(revised) != expected:
        raise ValueError("The Hermes YAML uses a shared model value. Set model.codex_bin explicitly and retry.")
    return {"binary": binary, "config": revised}


if __name__ == "__main__":
    try:
        print(json.dumps(hermes_config(sys.stdin.read(), sys.argv[1], sys.argv[2])))
    except yaml.YAMLError:
        sys.exit("Could not parse the selected Hermes config.yaml.")
    except (ValueError, StopIteration, KeyError, AttributeError, TypeError) as exc:
        sys.exit(str(exc) if type(exc) is ValueError else "Could not update model.codex_bin in the Hermes config.")

#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugins" / "simlease"
MANIFEST_PATH = PLUGIN / ".codex-plugin" / "plugin.json"
MARKETPLACE_PATH = ROOT / ".agents" / "plugins" / "marketplace.json"
SKILL = PLUGIN / "skills" / "simlease"


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AssertionError(f"unable to read valid JSON from {path}: {error}") from error
    assert isinstance(value, dict), f"{path} must contain a JSON object"
    return value


def main() -> int:
    manifest = load_json(MANIFEST_PATH)
    marketplace = load_json(MARKETPLACE_PATH)

    assert manifest["name"] == PLUGIN.name == "simlease"
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", manifest["version"])
    assert manifest["description"]
    assert manifest["author"]["name"]
    assert manifest["license"] == "MIT"
    assert manifest["skills"] == "./skills/"

    interface = manifest["interface"]
    for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
        assert interface[field], f"interface.{field} is required"
    prompts = interface.get("defaultPrompt", [])
    assert 1 <= len(prompts) <= 3
    assert all(isinstance(prompt, str) and len(prompt) <= 128 for prompt in prompts)
    for icon_field in ("composerIcon", "logo"):
        icon_path = PLUGIN / interface[icon_field].removeprefix("./")
        assert icon_path.is_file(), f"missing {icon_field}: {icon_path}"

    assert marketplace["name"] == "simlease"
    assert marketplace["interface"]["displayName"] == "SimLease"
    entries = [entry for entry in marketplace["plugins"] if entry.get("name") == "simlease"]
    assert len(entries) == 1
    entry = entries[0]
    assert entry["source"] == {"source": "local", "path": "./plugins/simlease"}
    assert entry["policy"] == {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}
    assert entry["category"] == "Engineering"

    skill_text = (SKILL / "SKILL.md").read_text()
    assert skill_text.startswith("---\nname: simlease\ndescription:")
    assert "[TODO" not in skill_text
    assert "$simlease" in (SKILL / "agents" / "openai.yaml").read_text()
    assert (SKILL / "assets" / "simlease-icon.png").is_file()
    for script_name in ("simlease", "preflight"):
        script_path = SKILL / "scripts" / script_name
        assert script_path.is_file(), f"missing {script_path}"
        assert script_path.stat().st_mode & 0o111, f"{script_path} must be executable"

    tracked_text = "\n".join(
        path.read_text(errors="ignore")
        for path in ROOT.rglob("*")
        if path.is_file() and ".git" not in path.parts and path != Path(__file__).resolve()
    )
    assert "[TODO:" not in tracked_text
    print("Codex plugin tests passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, KeyError, TypeError) as error:
        print(f"plugin validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

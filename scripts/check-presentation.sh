#!/usr/bin/env bash
# Validates .presentation/facts.yaml — the contract this repository publishes to
# slide decks (see jamesbannan/presentations).
#
# The deck is built from these facts, in a different repository, so nothing here
# fails at demo runtime. This check is what stops a demo rename or deletion from
# silently invalidating a talk.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
facts="${repo_root}/.presentation/facts.yaml"

if [[ ! -f "${facts}" ]]; then
  echo "✗ missing ${facts#"${repo_root}"/}"
  exit 1
fi

python3 - "$facts" "$repo_root" <<'PY'
import sys, pathlib

try:
    import yaml
except ImportError:
    sys.exit("✗ PyYAML is required: pip install pyyaml")

facts_path, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

try:
    facts = yaml.safe_load(facts_path.read_text()) or {}
except yaml.YAMLError as exc:
    sys.exit(f"✗ {facts_path.name} is not valid YAML: {exc}")

errors = []

architecture = facts.get("architecture")
if not isinstance(architecture, list) or not architecture:
    errors.append("architecture: expected a non-empty list")
else:
    for i, card in enumerate(architecture):
        if not isinstance(card, dict):
            errors.append(f"architecture[{i}]: expected a mapping")
        elif not card.get("arrow") and not card.get("title"):
            errors.append(f"architecture[{i}]: needs either 'title' or 'arrow'")

demos = facts.get("demos")
if not isinstance(demos, dict) or not demos:
    errors.append("demos: expected a non-empty mapping")
else:
    for name, demo in demos.items():
        where = f"demos.{name}"
        if not isinstance(demo, dict):
            errors.append(f"{where}: expected a mapping")
            continue

        for field in ("dir", "title", "intro"):
            if not demo.get(field):
                errors.append(f"{where}.{field}: missing")

        # The claim worth checking: the demo this slide describes still exists.
        demo_dir = demo.get("dir")
        if demo_dir:
            if not (root / demo_dir).is_dir():
                errors.append(f"{where}.dir: '{demo_dir}' does not exist")
            elif not (root / demo_dir / "run.sh").is_file():
                errors.append(f"{where}.dir: '{demo_dir}/run.sh' does not exist")

        steps = demo.get("steps")
        if not isinstance(steps, list) or not steps:
            errors.append(f"{where}.steps: expected a non-empty list")
        else:
            for i, step in enumerate(steps):
                if not isinstance(step, dict) or not step.get("title"):
                    errors.append(f"{where}.steps[{i}]: needs a 'title'")

if errors:
    print("✗ .presentation/facts.yaml is out of step with this repository:\n")
    for error in errors:
        print(f"  - {error}")
    print("\nUpdate the facts, or the deck in jamesbannan/presentations will be wrong.")
    sys.exit(1)

print(f"✓ .presentation/facts.yaml: {len(demos)} demos, {len(architecture)} architecture entries")
PY

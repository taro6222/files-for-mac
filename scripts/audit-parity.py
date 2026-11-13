#!/usr/bin/env python3
"""Validate and summarize the frozen upstream parity inventories."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPECS = {
    "commands": (ROOT / "docs/reference/COMMANDS.csv", "source_id", 202),
    "settings": (ROOT / "docs/reference/SETTINGS.csv", "source_key", 143),
    "screens": (ROOT / "docs/reference/SCREENS.csv", "source_path", 33),
}
REQUIRED = {"classification", "status", "evidence"}
ALLOWED_STATUSES = {
    "commands": {"awaiting-behavior-review", "implemented", "platform-alternative", "platform-excluded"},
    "settings": {"awaiting-behavior-review", "implemented", "platform-alternative", "platform-excluded"},
    "screens": {"awaiting-individual-review", "implemented", "platform-alternative", "platform-excluded"},
}


def inspect(name: str, path: Path, identity: str, expected: int) -> dict[str, object]:
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        fields = set(reader.fieldnames or [])
        missing_columns = sorted(({identity} | REQUIRED) - fields)
        rows = list(reader)
    identities = [row.get(identity, "").strip() for row in rows]
    duplicates = sorted(key for key, count in Counter(identities).items() if key and count > 1)
    blank_identities = sum(not key for key in identities)
    statuses = Counter(row.get("status", "").strip() or "<blank>" for row in rows)
    invalid_statuses = sorted(set(statuses) - ALLOWED_STATUSES[name])
    classifications = Counter(row.get("classification", "").strip() or "<blank>" for row in rows)
    missing_evidence = sum(not row.get("evidence", "").strip() for row in rows)
    resolved_without_command = 0
    if name == "commands" and "mac_command_id" in fields:
        resolved_without_command = sum(
            row.get("status", "").strip() in {"implemented", "platform-alternative"}
            and not row.get("mac_command_id", "").strip()
            for row in rows
        )
    valid = (
        not missing_columns and len(rows) == expected and not duplicates and not blank_identities
        and not missing_evidence and not invalid_statuses and not resolved_without_command
    )
    return {
        "name": name,
        "path": str(path.relative_to(ROOT)),
        "rows": len(rows),
        "expected_rows": expected,
        "statuses": dict(sorted(statuses.items())),
        "classifications": dict(sorted(classifications.items())),
        "missing_columns": missing_columns,
        "duplicate_identities": duplicates,
        "blank_identities": blank_identities,
        "missing_evidence": missing_evidence,
        "invalid_statuses": invalid_statuses,
        "resolved_without_command": resolved_without_command,
        "valid": valid,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    arguments = parser.parse_args()
    reports = [inspect(name, *spec) for name, spec in SPECS.items()]
    result = {"valid": all(report["valid"] for report in reports), "inventories": reports}
    if arguments.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        for report in reports:
            statuses = ", ".join(f"{key}={value}" for key, value in report["statuses"].items())
            print(f"{report['name']}: {report['rows']}/{report['expected_rows']} rows; {statuses}; valid={report['valid']}")
        print(f"overall_valid={result['valid']}")
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate and summarize the frozen upstream parity inventories."""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPECS = {
    "commands": (ROOT / "docs/reference/COMMANDS.csv", "source_id", 202),
    "settings": (ROOT / "docs/reference/SETTINGS.csv", "source_key", 143),
    "screens": (ROOT / "docs/reference/SCREENS.csv", "source_path", 33),
}
REQUIRED = {"classification", "status", "evidence"}
SOURCE_SHA = "99951c66928c4da714da8b1dd46039421182cbab"
CLASSIFICATIONS = {"E", "A", "V", "X"}
EVIDENCE_PATH = re.compile(r"\b(?:docs|Sources|Tests|scripts)/[\w./-]+\.(?:swift|md|sh|json|csv|py)\b")
ALLOWED_STATUSES = {
    "commands": {"awaiting-behavior-review", "implemented", "platform-alternative", "platform-excluded"},
    "settings": {"awaiting-behavior-review", "implemented", "platform-alternative", "platform-excluded"},
    "screens": {"awaiting-individual-review", "implemented", "platform-alternative", "platform-excluded"},
}


def inspect(name: str, path: Path, identity: str, expected: int) -> dict[str, object]:
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        fields = set(reader.fieldnames or [])
        required = {identity, "source_sha"} | REQUIRED
        if name == "commands":
            required.add("mac_command_id")
        missing_columns = sorted(required - fields)
        rows = list(reader)
    identities = [(row.get(identity) or "").strip() for row in rows]
    duplicates = sorted(key for key, count in Counter(identities).items() if key and count > 1)
    blank_identities = sum(not key for key in identities)
    statuses = Counter((row.get("status") or "").strip() or "<blank>" for row in rows)
    invalid_statuses = sorted(set(statuses) - ALLOWED_STATUSES[name])
    classifications = Counter((row.get("classification") or "").strip() or "<blank>" for row in rows)
    invalid_classifications = sorted(set(classifications) - CLASSIFICATIONS)
    wrong_source_sha = [key for key, row in zip(identities, rows) if row.get("source_sha") != SOURCE_SHA]
    malformed_rows = [line for line, row in enumerate(rows, 2) if None in row or None in row.values()]
    missing_evidence = sum(not (row.get("evidence") or "").strip() for row in rows)
    missing_evidence_paths = {}
    for key, row in zip(identities, rows):
        missing = sorted({ref for ref in EVIDENCE_PATH.findall(row.get("evidence") or "")
                          if not (ROOT / ref).is_file()})
        if missing:
            missing_evidence_paths[key] = missing
    resolved_without_command = 0
    if name == "commands" and "mac_command_id" in fields:
        resolved_without_command = sum(
            (row.get("status") or "").strip() in {"implemented", "platform-alternative"}
            and not (row.get("mac_command_id") or "").strip()
            for row in rows
        )
    valid = (
        not missing_columns and len(rows) == expected and not duplicates and not blank_identities
        and not missing_evidence and not invalid_statuses and not resolved_without_command
        and not invalid_classifications and not wrong_source_sha and not malformed_rows
        and not missing_evidence_paths
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
        "missing_evidence_paths": missing_evidence_paths,
        "invalid_classifications": invalid_classifications,
        "wrong_source_sha": wrong_source_sha,
        "malformed_rows": malformed_rows,
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
            for key in ("missing_columns", "duplicate_identities", "blank_identities", "missing_evidence",
                        "missing_evidence_paths", "invalid_classifications", "wrong_source_sha",
                        "malformed_rows", "invalid_statuses", "resolved_without_command"):
                if report[key]:
                    print(f"  {key}: {report[key]}")
        print(f"overall_valid={result['valid']}")
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

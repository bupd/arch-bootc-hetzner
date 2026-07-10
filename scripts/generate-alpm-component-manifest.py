#!/usr/bin/env python3
"""Generate chunkah component ownership from an installed ALPM database."""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath


DEFAULT_DB = "usr/lib/sysimage/var/lib/pacman/local"


def sections(path: Path) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    current: str | None = None
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw_line.startswith("%") and raw_line.endswith("%"):
            current = raw_line.strip("%")
            result.setdefault(current, [])
        elif current is not None and raw_line:
            result[current].append(raw_line)
    return result


def canonical_path(value: str) -> str | None:
    if not value or value.endswith("/"):
        return None
    path = PurePosixPath("/" + value.lstrip("/"))
    if ".." in path.parts:
        return None
    return str(path)


def component_records(root: Path, database: Path) -> list[tuple[str, str, str]]:
    records: dict[str, tuple[str, str, str]] = {}
    for package_dir in sorted(database.iterdir()):
        desc_path = package_dir / "desc"
        files_path = package_dir / "files"
        if not desc_path.is_file() or not files_path.is_file():
            continue
        package_names = sections(desc_path).get("NAME", [])
        if not package_names:
            continue
        component = "alpm/" + package_names[0]
        for value in sections(files_path).get("FILES", []):
            path = canonical_path(value)
            if path is None or not os.path.lexists(root / path.lstrip("/")):
                continue
            records.setdefault(path, (path, component, "weekly"))
    return [records[path] for path in sorted(records)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--database", default=DEFAULT_DB)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = args.root.resolve()
    database = root / args.database
    if not database.is_dir():
        parser.error(f"ALPM database not found: {database}")

    records = component_records(root, database)
    if not records:
        parser.error(f"ALPM database produced no component records: {database}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as output:
        output.write("# path\tcomponent\tinterval\n")
        for record in records:
            output.write("\t".join(record) + "\n")
    print(f"wrote {len(records)} ALPM component records to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

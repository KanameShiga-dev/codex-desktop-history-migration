#!/usr/bin/env python3
"""Export/import the portable subset of Codex task metadata."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any

TABLES = {
    "state": ("threads", "thread_dynamic_tools", "thread_spawn_edges"),
    "goals": ("thread_goals",),
}


def database_paths(home: Path, prefix: str) -> list[Path]:
    """Return both current and legacy Codex database locations.

    Codex Desktop has used both ~/.codex and ~/.codex/sqlite across releases.
    A migrated task must be registered in every existing state database so the
    Desktop thread list can display it after an upgrade or migration.
    """
    found: dict[Path, Path] = {}
    for root in (home, home / "sqlite"):
        if root.is_dir():
            for path in root.glob(f"{prefix}_*.sqlite"):
                found[path.resolve()] = path
    return list(found.values())


def connect_ro(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)


def rows_as_dicts(connection: sqlite3.Connection, table: str) -> list[dict[str, Any]]:
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    if not exists:
        return []
    cursor = connection.execute(f'SELECT * FROM "{table}"')
    names = [item[0] for item in cursor.description]
    return [dict(zip(names, row)) for row in cursor.fetchall()]


def export_database(home: Path, output: Path) -> None:
    result: dict[str, Any] = {"version": 1, "source_codex_home": str(home), "databases": {}}
    for kind, tables in TABLES.items():
        paths = database_paths(home, kind)
        if not paths:
            continue
        merged = {table: [] for table in tables}
        seen = {table: set() for table in tables}
        for path in paths:
            connection = connect_ro(path)
            try:
                for table in tables:
                    for row in rows_as_dicts(connection, table):
                        identity = tuple(sorted(row.items())) if table != "threads" else row.get("id")
                        if identity not in seen[table]:
                            seen[table].add(identity)
                            merged[table].append(row)
            finally:
                connection.close()
        result["databases"][kind] = {
            "source_names": [path.name for path in paths],
            "tables": merged,
        }
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")


def table_columns(connection: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')]


def remap_path(value: Any, mappings: list[tuple[str, str]]) -> Any:
    if not isinstance(value, str):
        return value
    for old, new in mappings:
        candidates = [(old, new)]
        if value.startswith("\\\\?\\") and not old.startswith("\\\\?\\"):
            # The Desktop project registry uses normal Windows paths. Keep the
            # legacy prefix out of the migrated cwd so exact project matching
            # does not hide otherwise valid threads.
            candidates.append(("\\\\?\\" + old, new))
        for source, target in candidates:
            if value == source or value.startswith(source.rstrip("\\/") + "\\") or value.startswith(source.rstrip("\\/") + "/"):
                return target + value[len(source):]
    return value


def import_rows(connection: sqlite3.Connection, table: str, rows: list[dict[str, Any]], old_home: str, new_home: str, mappings: list[tuple[str, str]]) -> int:
    columns = table_columns(connection, table)
    if not columns:
        return 0
    inserted = 0
    for original in rows:
        row = {key: value for key, value in original.items() if key in columns}
        if table == "threads" and isinstance(row.get("rollout_path"), str):
            row["rollout_path"] = row["rollout_path"].replace(old_home, new_home)
        if table == "threads":
            row["cwd"] = remap_path(row.get("cwd"), mappings)
            if isinstance(row.get("cwd"), str) and row["cwd"].startswith("\\\\?\\"):
                row["cwd"] = row["cwd"][4:]
        if not row:
            continue
        names = list(row)
        sql = f'INSERT OR IGNORE INTO "{table}" ({",".join(fchr(n) for n in names)}) VALUES ({",".join("?" for _ in names)})'
        connection.execute(sql, [row[name] for name in names])
        changed = connection.execute("SELECT changes()").fetchone()[0]
        if table == "threads" and mappings and row.get("id"):
            updated = {
                "cwd": remap_path(row.get("cwd"), mappings),
                "rollout_path": row.get("rollout_path"),
            }
            if isinstance(updated["cwd"], str) and updated["cwd"].startswith("\\\\?\\"):
                updated["cwd"] = updated["cwd"][4:]
            if "cwd" in columns and "rollout_path" in columns:
                connection.execute(
                    'UPDATE "threads" SET "cwd"=?, "rollout_path"=? WHERE "id"=?',
                    (updated["cwd"], updated["rollout_path"], row["id"]),
                )
                changed += connection.execute("SELECT changes()").fetchone()[0]
        inserted += changed
    return inserted


def normalize_existing_cwds(connection: sqlite3.Connection, mappings: list[tuple[str, str]]) -> int:
    """Normalize cwd for threads that were already present on the new PC."""
    columns = table_columns(connection, "threads")
    if "cwd" not in columns or "id" not in columns:
        return 0
    changed = 0
    for thread_id, cwd in connection.execute('SELECT "id", "cwd" FROM "threads"'):
        updated = remap_path(cwd, mappings)
        if isinstance(updated, str) and updated.startswith("\\\\?\\"):
            updated = updated[4:]
        if updated != cwd:
            connection.execute('UPDATE "threads" SET "cwd"=? WHERE "id"=?', (updated, thread_id))
            changed += 1
    return changed


def fchr(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def import_database(home: Path, input_path: Path, mappings: list[tuple[str, str]]) -> None:
    data = json.loads(input_path.read_text(encoding="utf-8"))
    old_home = data.get("source_codex_home", "")
    total = 0
    for kind, payload in data.get("databases", {}).items():
        paths = database_paths(home, kind)
        if not paths:
            print(f"skip: no {kind}_*.sqlite in {home}")
            continue
        for path in paths:
            connection = sqlite3.connect(path)
            location_total = 0
            try:
                connection.execute("PRAGMA foreign_keys=OFF")
                for table in TABLES.get(kind, ()):
                    inserted = import_rows(connection, table, payload.get("tables", {}).get(table, []), old_home, str(home), mappings)
                    total += inserted
                    location_total += inserted
                if kind == "state":
                    normalized = normalize_existing_cwds(connection, mappings)
                    total += normalized
                    location_total += normalized
                connection.commit()
            finally:
                connection.close()
            print(f"{path}: {location_total} rows imported")
    print(f"database rows imported across all Codex database locations: {total}")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    export_parser = sub.add_parser("export")
    export_parser.add_argument("--codex-home", type=Path, required=True)
    export_parser.add_argument("--output", type=Path, required=True)
    import_parser = sub.add_parser("import")
    import_parser.add_argument("--codex-home", type=Path, required=True)
    import_parser.add_argument("--input", type=Path, required=True)
    import_parser.add_argument("--path-map", action="append", default=[], metavar="OLD=NEW")
    args = parser.parse_args()
    if args.command == "export":
        export_database(args.codex_home.resolve(), args.output.resolve())
    else:
        mappings = []
        for item in args.path_map:
            if "=" not in item:
                raise SystemExit(f"invalid --path-map: {item!r}; expected OLD=NEW")
            old, new = item.split("=", 1)
            mappings.append((old, new))
        import_database(args.codex_home.resolve(), args.input.resolve(), mappings)


if __name__ == "__main__":
    main()

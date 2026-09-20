#!/usr/bin/env python3
"""Purge junk durable facts from comstar_memory SQLite (Phase 1 hygiene).

Matches the bridge heuristics that reject epistemic STT junk
("Do not know…", "don't hear you", stutter fragments).

Usage:
  python3 scripts/purge_junk_durable_facts.py --dry-run
  python3 scripts/purge_junk_durable_facts.py --dir /path/to/conversation
  COMSTAR_MEMORY_DIR=/path python3 scripts/purge_junk_durable_facts.py

Exit 0 always on success; prints JSON summary to stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

DB_NAME = "comstar_memory.sqlite3"

_EPISTEMIC = re.compile(
    r"(?i)\b(i\s+)?(don'?t|do\s+not)\s+(know|hear|understand|remember)\b|"
    r"\b(not\s+sure|no\s+idea|can'?t\s+tell|i\s+have\s+no\s+idea)\b|"
    r"\bdo\s+not\b.*\b(know|hear|understand)\b"
)

# Legacy "Do not …" prefs that were epistemic, not intentional never-rules.
_JUNK_DO_NOT = re.compile(
    r"(?i)^(do\s+not|dont)\s+(know|hear|understand|remember)\b"
)

# Greeter / status lines that should never have been facts.
_GREETERISH = re.compile(
    r"(?i)^(good\s+(morning|afternoon|evening)|welcome\s+back|"
    r"awaiting\s+your\s+voice|going\s+to\s+sleep)"
)


def is_junk_fact(text: str) -> bool:
    t = (text or "").strip()
    if not t:
        return True
    if _EPISTEMIC.search(t):
        return True
    if _JUNK_DO_NOT.search(t):
        return True
    if _GREETERISH.search(t):
        return True
    # Very short negation-only leftovers
    if re.match(r"(?i)^(do\s+not|dont)\.?$", t):
        return True
    return False


def resolve_db(dir_arg: str | None) -> Path:
    if dir_arg:
        root = Path(dir_arg).expanduser().resolve()
    else:
        env = os.environ.get("COMSTAR_MEMORY_DIR", "").strip()
        if env:
            root = Path(env).expanduser().resolve()
        else:
            root = (
                Path.home() / ".local" / "share" / "comstar" / "conversation"
            ).resolve()
    return root / DB_NAME


def purge(db: Path, *, dry_run: bool, userid: str | None) -> dict:
    if not db.is_file():
        return {
            "ok": False,
            "error": f"db_missing:{db}",
            "dry_run": dry_run,
            "junk": [],
            "deleted": 0,
        }
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    try:
        q = "SELECT id, userid, kind, text FROM facts"
        params: list[str] = []
        if userid:
            q += " WHERE userid = ?"
            params.append(userid.strip().lower())
        rows = conn.execute(q, params).fetchall()
        junk = []
        for row in rows:
            if is_junk_fact(row["text"]):
                junk.append(
                    {
                        "id": row["id"],
                        "userid": row["userid"],
                        "kind": row["kind"],
                        "text": row["text"],
                    }
                )
        deleted = 0
        if not dry_run and junk:
            for item in junk:
                conn.execute(
                    "DELETE FROM facts WHERE id = ? AND userid = ?",
                    (item["id"], item["userid"]),
                )
                deleted += 1
            # Keep FTS in sync if triggers exist; rebuild is safest on older DBs.
            try:
                conn.execute(
                    "INSERT INTO facts_fts(facts_fts) VALUES('rebuild')"
                )
            except sqlite3.Error:
                pass
            conn.commit()
        return {
            "ok": True,
            "db": str(db),
            "dry_run": dry_run,
            "scanned": len(rows),
            "junk_count": len(junk),
            "deleted": deleted,
            "junk": junk,
        }
    finally:
        conn.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--dir",
        help="Conversation store dir (contains comstar_memory.sqlite3)",
    )
    ap.add_argument("--db", help="Explicit path to comstar_memory.sqlite3")
    ap.add_argument("--userid", help="Limit to one userid")
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Report junk ids without deleting",
    )
    args = ap.parse_args()
    db = Path(args.db).expanduser().resolve() if args.db else resolve_db(args.dir)
    result = purge(db, dry_run=args.dry_run, userid=args.userid)
    print(json.dumps(result, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Export scrubbed durable facts → AO curated RAG pack (Phase 3).

Writes a pack directory (default ``comstar_resident_facts``) containing only
curated durable facts — never rolling transcript / greeter / news lines.

Usage:
  python3 scripts/export_resident_facts_rag.py --dry-run
  python3 scripts/export_resident_facts_rag.py --dir ~/.local/share/comstar/conversation \\
      --out /var/lib/comstar/rag/comstar_resident_facts

Manifest schema: pack_id, version, generated_ms, fact_count, facts[].
Exit 1 if no curated facts (pack would be empty) unless --allow-empty.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

# Reuse purge heuristics
_SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(_SCRIPTS))
from purge_junk_durable_facts import is_junk_fact  # noqa: E402

DB_NAME = "comstar_memory.sqlite3"
PACK_ID = "comstar_resident_facts"

_NEWSISH = re.compile(
    r"(?i)\b(headline|around the world|bbc|npr|reuters|world news)\b"
)
_GREETER = re.compile(
    r"(?i)^(good\s+(morning|afternoon|evening)|welcome\s+back|"
    r"awaiting\s+your\s+voice)"
)


def is_curated(text: str, kind: str) -> bool:
    t = (text or "").strip()
    if len(t) < 3:
        return False
    if is_junk_fact(t):
        return False
    if _NEWSISH.search(t) or _GREETER.search(t):
        return False
    # Prefer preference / note / identity kinds; skip empty kinds
    k = (kind or "note").lower()
    if k in ("ephemeral", "greeter", "status"):
        return False
    return True


def load_facts(db: Path, userid: str | None) -> list[dict]:
    if not db.is_file():
        return []
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    try:
        q = "SELECT id, userid, kind, text, source, updated_ms FROM facts"
        params: list[str] = []
        if userid:
            q += " WHERE userid = ?"
            params.append(userid.strip().lower())
        rows = conn.execute(q, params).fetchall()
        out = []
        for row in rows:
            if not is_curated(row["text"], row["kind"]):
                continue
            out.append(
                {
                    "id": row["id"],
                    "userid": row["userid"],
                    "kind": row["kind"],
                    "text": row["text"],
                    "source": row["source"],
                    "updated_ms": row["updated_ms"],
                }
            )
        return out
    finally:
        conn.close()


def write_pack(out_dir: Path, facts: list[dict], *, dry_run: bool) -> dict:
    manifest = {
        "pack_id": PACK_ID,
        "version": 1,
        "generated_ms": int(time.time() * 1000),
        "fact_count": len(facts),
        "schema": "comstar_resident_facts.v1",
        "facts": facts,
    }
    # Validate: no greeter/news lines
    for f in facts:
        assert is_curated(f["text"], f["kind"]), f["text"]
        assert not _NEWSISH.search(f["text"])
    if dry_run:
        return {"ok": True, "dry_run": True, "manifest": manifest, "out": str(out_dir)}

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    # One markdown doc per userid for human/AO ingestion
    by_user: dict[str, list[dict]] = {}
    for f in facts:
        by_user.setdefault(f["userid"], []).append(f)
    for uid, ufacts in by_user.items():
        lines = [f"# Resident facts: {uid}", ""]
        for f in ufacts:
            lines.append(f"- ({f['kind']}) {f['text']}")
        lines.append("")
        (out_dir / f"{uid}.md").write_text("\n".join(lines), encoding="utf-8")
    return {
        "ok": True,
        "dry_run": False,
        "out": str(out_dir),
        "fact_count": len(facts),
        "pack_id": PACK_ID,
    }


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", help="Conversation store dir")
    ap.add_argument("--db", help="Explicit sqlite path")
    ap.add_argument("--userid", help="Limit to one userid")
    ap.add_argument(
        "--out",
        default="",
        help="Pack output directory (default: <store>/rag/comstar_resident_facts)",
    )
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--allow-empty",
        action="store_true",
        help="Succeed even when no curated facts",
    )
    args = ap.parse_args()
    db = Path(args.db).expanduser().resolve() if args.db else resolve_db(args.dir)
    facts = load_facts(db, args.userid)
    if not facts and not args.allow_empty:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "empty_curated_pack",
                    "db": str(db),
                    "hint": "seed a remember/prefer fact or pass --allow-empty",
                },
                indent=2,
            )
        )
        return 1
    if args.out:
        out_dir = Path(args.out).expanduser().resolve()
    else:
        out_dir = db.parent / "rag" / PACK_ID
    result = write_pack(out_dir, facts, dry_run=args.dry_run)
    print(json.dumps(result, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())

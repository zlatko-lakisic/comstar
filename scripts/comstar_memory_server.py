#!/usr/bin/env python3
"""COMSTAR shared conversation memory — rolling turns + durable facts (Phase 1+2).

Rolling transcript:
  GET/PUT /v1/memory/<userid>

Durable facts (FTS RAG-lite; cross-terminal):
  GET  /v1/facts/<userid>?q=&limit=8   search (empty q → recent)
  POST /v1/facts/<userid>             upsert {id?, kind, text, source?}
  DELETE /v1/facts/<userid>/<id>

GET /health → {"ok": true, "facts": true}

Env:
  COMSTAR_MEMORY_DIR   store root (default ~/.local/share/comstar/conversation)
  COMSTAR_MEMORY_HOST  bind host (default 127.0.0.1; use 0.0.0.0 for LAN)
  COMSTAR_MEMORY_PORT  port (default 8792)

All per-user data lives in a fixed SQLite file under the store root — userid is
never interpolated into filesystem paths (avoids path-injection).
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SAFE = re.compile(r"^[a-z0-9_-]+$")
DB_NAME = "comstar_memory.sqlite3"


def store_dir() -> Path:
    override = os.environ.get("COMSTAR_MEMORY_DIR", "").strip()
    if override:
        return Path(os.path.realpath(override))
    return (Path.home() / ".local" / "share" / "comstar" / "conversation").resolve()


def db_path() -> Path:
    # Fixed filename only — never derived from request input.
    return Path(os.path.join(str(store_dir()), DB_NAME))


def safe_userid(raw: str) -> str | None:
    cleaned = re.sub(r"[^a-z0-9_-]", "_", raw.strip().lower())
    if not cleaned or cleaned in ("guest", "unknown") or not SAFE.match(cleaned):
        return None
    return cleaned


def safe_fact_id(raw: str) -> str | None:
    cleaned = re.sub(r"[^a-z0-9_-]", "_", raw.strip().lower())
    if not cleaned or not SAFE.match(cleaned):
        return None
    return cleaned


def connect() -> sqlite3.Connection:
    root = store_dir()
    root.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path()), timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS facts (
          id TEXT PRIMARY KEY,
          userid TEXT NOT NULL,
          kind TEXT NOT NULL,
          text TEXT NOT NULL,
          source TEXT,
          created_ms INTEGER NOT NULL,
          updated_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_facts_user ON facts(userid, updated_ms DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
          text,
          kind,
          content='facts',
          content_rowid='rowid'
        );
        CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
          INSERT INTO facts_fts(rowid, text, kind) VALUES (new.rowid, new.text, new.kind);
        END;
        CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
          INSERT INTO facts_fts(facts_fts, rowid, text, kind)
            VALUES('delete', old.rowid, old.text, old.kind);
        END;
        CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
          INSERT INTO facts_fts(facts_fts, rowid, text, kind)
            VALUES('delete', old.rowid, old.text, old.kind);
          INSERT INTO facts_fts(rowid, text, kind) VALUES (new.rowid, new.text, new.kind);
        END;
        CREATE TABLE IF NOT EXISTS rolling_memory (
          userid TEXT PRIMARY KEY,
          payload TEXT NOT NULL,
          updated_ms INTEGER NOT NULL
        );
        """
    )
    # One-time import from legacy durable_facts.sqlite3 if present and empty facts.
    _maybe_migrate_legacy_db(conn)
    _maybe_migrate_legacy_json(conn)
    return conn


def _maybe_migrate_legacy_db(conn: sqlite3.Connection) -> None:
    legacy = Path(os.path.join(str(store_dir()), "durable_facts.sqlite3"))
    if not legacy.is_file():
        return
    try:
        have = conn.execute("SELECT COUNT(*) AS n FROM facts").fetchone()["n"]
        if have:
            return
        legacy_conn = sqlite3.connect(str(legacy), timeout=5)
        legacy_conn.row_factory = sqlite3.Row
        try:
            rows = legacy_conn.execute("SELECT * FROM facts").fetchall()
        except sqlite3.Error:
            return
        finally:
            legacy_conn.close()
        for r in rows:
            conn.execute(
                """
                INSERT OR IGNORE INTO facts(id, userid, kind, text, source, created_ms, updated_ms)
                VALUES(?,?,?,?,?,?,?)
                """,
                (
                    r["id"],
                    r["userid"],
                    r["kind"],
                    r["text"],
                    r["source"],
                    r["created_ms"],
                    r["updated_ms"],
                ),
            )
        conn.commit()
    except sqlite3.Error:
        return


def _maybe_migrate_legacy_json(conn: sqlite3.Connection) -> None:
    """Import legacy per-user ``*.json`` rolling transcripts into SQLite once."""
    root = store_dir()
    try:
        names = os.listdir(root)
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        # Basename only — reject anything that is not a plain file name.
        base = os.path.basename(name)
        if base != name or not SAFE.match(base[:-5]):
            continue
        userid = base[:-5]
        exists = conn.execute(
            "SELECT 1 FROM rolling_memory WHERE userid = ?",
            (userid,),
        ).fetchone()
        if exists:
            continue
        path = os.path.join(str(root), base)
        try:
            with open(path, encoding="utf-8") as fh:
                payload = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        payload["userid"] = userid
        conn.execute(
            """
            INSERT OR IGNORE INTO rolling_memory(userid, payload, updated_ms)
            VALUES(?,?,?)
            """,
            (userid, json.dumps(payload, ensure_ascii=False), int(time.time() * 1000)),
        )
    conn.commit()


def get_rolling(userid: str) -> dict:
    conn = connect()
    try:
        row = conn.execute(
            "SELECT payload FROM rolling_memory WHERE userid = ?",
            (userid,),
        ).fetchone()
        if not row:
            return {"userid": userid, "turns": []}
        data = json.loads(row["payload"])
        if not isinstance(data, dict):
            return {"userid": userid, "turns": []}
        data["userid"] = userid
        if not isinstance(data.get("turns"), list):
            data["turns"] = []
        return data
    finally:
        conn.close()


def put_rolling(userid: str, payload: dict) -> dict:
    payload = dict(payload)
    payload["userid"] = userid
    turns = payload.get("turns")
    if not isinstance(turns, list):
        turns = []
        payload["turns"] = turns
    conn = connect()
    try:
        conn.execute(
            """
            INSERT INTO rolling_memory(userid, payload, updated_ms)
            VALUES(?,?,?)
            ON CONFLICT(userid) DO UPDATE SET
              payload=excluded.payload,
              updated_ms=excluded.updated_ms
            """,
            (userid, json.dumps(payload, ensure_ascii=False), int(time.time() * 1000)),
        )
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "userid": userid, "turns": len(turns)}


def fact_row(r: sqlite3.Row) -> dict:
    return {
        "id": r["id"],
        "userid": r["userid"],
        "kind": r["kind"],
        "text": r["text"],
        "source": r["source"],
        "created_ms": r["created_ms"],
        "updated_ms": r["updated_ms"],
    }


def search_facts(userid: str, query: str, limit: int) -> list[dict]:
    conn = connect()
    try:
        q = (query or "").strip()
        if q:
            tokens = re.findall(r"[A-Za-z0-9_]+", q)
            if tokens:
                match = " ".join(f'"{t}"' for t in tokens[:12])
                try:
                    rows = conn.execute(
                        """
                        SELECT f.* FROM facts f
                        JOIN facts_fts ON facts_fts.rowid = f.rowid
                        WHERE f.userid = ? AND facts_fts MATCH ?
                        ORDER BY f.updated_ms DESC
                        LIMIT ?
                        """,
                        (userid, match, limit),
                    ).fetchall()
                    return [fact_row(r) for r in rows]
                except sqlite3.Error:
                    pass
            like = f"%{q[:80]}%"
            rows = conn.execute(
                """
                SELECT * FROM facts
                WHERE userid = ? AND (text LIKE ? OR kind LIKE ?)
                ORDER BY updated_ms DESC
                LIMIT ?
                """,
                (userid, like, like, limit),
            ).fetchall()
            return [fact_row(r) for r in rows]
        rows = conn.execute(
            """
            SELECT * FROM facts WHERE userid = ?
            ORDER BY updated_ms DESC LIMIT ?
            """,
            (userid, limit),
        ).fetchall()
        return [fact_row(r) for r in rows]
    finally:
        conn.close()


def upsert_fact(userid: str, payload: dict) -> dict:
    kind = str(payload.get("kind") or "note").strip().lower()[:32] or "note"
    text = str(payload.get("text") or "").strip()
    if not text or len(text) > 500:
        raise ValueError("bad_text")
    source = str(payload.get("source") or "").strip()[:120] or None
    fid = str(payload.get("id") or "").strip()
    if not fid:
        norm = re.sub(r"\s+", " ", text.lower())
        fid = f"{kind}-{abs(hash(norm)) & 0xFFFFFFFF:08x}"
    if not SAFE.match(fid.replace("-", "_")) and not re.match(r"^[a-z0-9_-]+$", fid):
        fid = uuid.uuid4().hex
    now = int(time.time() * 1000)
    conn = connect()
    try:
        existing = conn.execute(
            "SELECT created_ms FROM facts WHERE id = ? AND userid = ?",
            (fid, userid),
        ).fetchone()
        created = int(existing["created_ms"]) if existing else now
        conn.execute(
            """
            INSERT INTO facts(id, userid, kind, text, source, created_ms, updated_ms)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              kind=excluded.kind,
              text=excluded.text,
              source=excluded.source,
              updated_ms=excluded.updated_ms
            """,
            (fid, userid, kind, text, source, created, now),
        )
        rows = conn.execute(
            "SELECT id FROM facts WHERE userid = ? ORDER BY updated_ms DESC",
            (userid,),
        ).fetchall()
        for extra in rows[100:]:
            conn.execute(
                "DELETE FROM facts WHERE id = ? AND userid = ?",
                (extra["id"], userid),
            )
        conn.commit()
        row = conn.execute(
            "SELECT * FROM facts WHERE id = ? AND userid = ?",
            (fid, userid),
        ).fetchone()
        return fact_row(row)
    finally:
        conn.close()


def delete_fact(userid: str, fid: str) -> bool:
    conn = connect()
    try:
        cur = conn.execute(
            "DELETE FROM facts WHERE id = ? AND userid = ?",
            (fid, userid),
        )
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if self.path.startswith("/health"):
            return
        super().log_message(fmt, *args)

    def _send(self, code: int, body: dict | list | str, ctype: str = "application/json") -> None:
        raw = body if isinstance(body, (bytes, bytearray)) else (
            body.encode("utf-8") if isinstance(body, str) else json.dumps(body).encode("utf-8")
        )
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path == "/health":
            self._send(200, {"ok": True, "facts": True})
            return

        m = re.match(r"^/v1/facts/([^/]+)$", path)
        if m:
            uid = safe_userid(m.group(1))
            if not uid:
                self._send(400, {"ok": False, "error": "bad_userid"})
                return
            qs = parse_qs(parsed.query)
            q = (qs.get("q") or [""])[0]
            try:
                limit = int((qs.get("limit") or ["8"])[0])
            except ValueError:
                limit = 8
            limit = max(1, min(limit, 32))
            try:
                facts = search_facts(uid, q, limit)
            except Exception as exc:  # noqa: BLE001
                self._send(500, {"ok": False, "error": str(exc)})
                return
            self._send(200, {"userid": uid, "facts": facts})
            return

        m = re.match(r"^/v1/memory/([^/]+)$", path)
        if not m:
            self._send(404, {"ok": False, "error": "not_found"})
            return
        uid = safe_userid(m.group(1))
        if not uid:
            self._send(400, {"ok": False, "error": "bad_userid"})
            return
        try:
            data = get_rolling(uid)
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"ok": False, "error": str(exc)})
            return
        self._send(200, data)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        m = re.match(r"^/v1/facts/([^/]+)$", path)
        if not m:
            self._send(404, {"ok": False, "error": "not_found"})
            return
        uid = safe_userid(m.group(1))
        if not uid:
            self._send(400, {"ok": False, "error": "bad_userid"})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > 32_000:
            self._send(400, {"ok": False, "error": "bad_body"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            self._send(400, {"ok": False, "error": str(exc)})
            return
        if not isinstance(payload, dict):
            self._send(400, {"ok": False, "error": "expected_object"})
            return
        try:
            fact = upsert_fact(uid, payload)
        except ValueError as exc:
            self._send(400, {"ok": False, "error": str(exc)})
            return
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"ok": False, "error": str(exc)})
            return
        self._send(200, {"ok": True, "fact": fact})

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        m = re.match(r"^/v1/facts/([^/]+)/([^/]+)$", path)
        if not m:
            self._send(404, {"ok": False, "error": "not_found"})
            return
        uid = safe_userid(m.group(1))
        fid = safe_fact_id(m.group(2))
        if not uid or not fid:
            self._send(400, {"ok": False, "error": "bad_id"})
            return
        ok = delete_fact(uid, fid)
        self._send(200 if ok else 404, {"ok": ok})

    def do_PUT(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        m = re.match(r"^/v1/memory/([^/]+)$", path)
        if not m:
            self._send(404, {"ok": False, "error": "not_found"})
            return
        uid = safe_userid(m.group(1))
        if not uid:
            self._send(400, {"ok": False, "error": "bad_userid"})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > 512_000:
            self._send(400, {"ok": False, "error": "bad_body"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:  # noqa: BLE001
            self._send(400, {"ok": False, "error": str(exc)})
            return
        if not isinstance(payload, dict):
            self._send(400, {"ok": False, "error": "expected_object"})
            return
        try:
            result = put_rolling(uid, payload)
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"ok": False, "error": str(exc)})
            return
        self._send(200, result)


def main() -> None:
    host = os.environ.get("COMSTAR_MEMORY_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = int(os.environ.get("COMSTAR_MEMORY_PORT", "8792"))
    root = store_dir()
    root.mkdir(parents=True, exist_ok=True)
    connect().close()
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"comstar-memory listening on {host}:{port} store={root} db={DB_NAME}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

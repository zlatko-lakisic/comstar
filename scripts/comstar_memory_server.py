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
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import tempfile
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SAFE = re.compile(r"^[a-z0-9_-]+$")


def store_dir() -> Path:
    override = os.environ.get("COMSTAR_MEMORY_DIR", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".local" / "share" / "comstar" / "conversation"


def db_path() -> Path:
    return store_dir() / "durable_facts.sqlite3"


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


def memory_path(userid: str) -> Path:
    """Resolve ``<store>/<userid>.json`` and reject path escape attempts."""
    root = store_dir().resolve()
    candidate = (root / f"{userid}.json").resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:  # pragma: no cover - defensive
        raise ValueError("path_escape") from exc
    return candidate


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
        """
    )
    return conn


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
            # Quote tokens for FTS; fall back to LIKE if FTS errors.
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
        # Stable-ish id from kind+normalized text for dedupe.
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
        # Cap per user
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
            fpath = memory_path(uid)
        except ValueError:
            self._send(400, {"ok": False, "error": "bad_userid"})
            return
        if not fpath.is_file():
            self._send(200, {"userid": uid, "turns": []})
            return
        try:
            data = json.loads(fpath.read_text(encoding="utf-8"))
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
        payload["userid"] = uid
        try:
            fpath = memory_path(uid)
        except ValueError:
            self._send(400, {"ok": False, "error": "bad_userid"})
            return
        root = fpath.parent
        root.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=str(root), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, indent=2, ensure_ascii=False)
                fh.write("\n")
            os.chmod(tmp_name, 0o600)
            os.replace(tmp_name, fpath)
        except Exception as exc:  # noqa: BLE001
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            self._send(500, {"ok": False, "error": str(exc)})
            return
        self._send(200, {"ok": True, "userid": uid, "turns": len(payload.get("turns") or [])})


def main() -> None:
    host = os.environ.get("COMSTAR_MEMORY_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = int(os.environ.get("COMSTAR_MEMORY_PORT", "8792"))
    root = store_dir()
    root.mkdir(parents=True, exist_ok=True)
    # Prime schema
    connect().close()
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"comstar-memory listening on {host}:{port} store={root} facts=on", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

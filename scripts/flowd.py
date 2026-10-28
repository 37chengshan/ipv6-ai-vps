#!/usr/bin/env python3
"""Sample sing-box connections and persist per-host traffic to SQLite."""
import json
import sqlite3
import time
import urllib.request

API = "http://127.0.0.1:2092/connections"
DB = "/var/lib/aether-usage/flows.db"
INTERVAL = 1
RETENTION = 8 * 86400


def connect_db():
    db = sqlite3.connect(DB, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(
        """CREATE TABLE IF NOT EXISTS flows(
               minute INTEGER NOT NULL,
               host TEXT NOT NULL,
               outbound TEXT NOT NULL,
               src TEXT NOT NULL,
               up INTEGER NOT NULL DEFAULT 0,
               down INTEGER NOT NULL DEFAULT 0,
               PRIMARY KEY (minute, host, outbound, src)
           )"""
    )
    return db


def fetch():
    with urllib.request.urlopen(API, timeout=5) as resp:
        return json.load(resp)


def snapshot(data):
    out = {}
    for conn in data.get("connections") or []:
        meta = conn.get("metadata") or {}
        out[conn["id"]] = (
            conn.get("upload") or 0,
            conn.get("download") or 0,
            meta.get("host") or meta.get("destinationIP") or "-",
            ">".join(conn.get("chains") or []) or "-",
            meta.get("sourceIP") or "-",
        )
    return out


def main():
    db = connect_db()
    try:
        seen = snapshot(fetch())
    except Exception:  # noqa: BLE001
        seen = {}
    cleanup_at = 0.0
    while True:
        started = time.time()
        try:
            data = fetch()
        except Exception:  # noqa: BLE001
            time.sleep(INTERVAL)
            continue
        minute = int(started // 60) * 60
        current = snapshot(data)
        rows = {}
        for cid, (up, down, host, out, src) in current.items():
            prev = seen.get(cid)
            if prev is None:
                last_up = last_down = 0
            else:
                last_up, last_down = prev[0], prev[1]
            delta_up = max(0, up - last_up)
            delta_down = max(0, down - last_down)
            if delta_up or delta_down:
                key = (minute, host, out, src)
                acc = rows.setdefault(key, [0, 0])
                acc[0] += delta_up
                acc[1] += delta_down
        seen = current
        if rows:
            db.executemany(
                """INSERT INTO flows(minute, host, outbound, src, up, down) VALUES(?,?,?,?,?,?)
                   ON CONFLICT(minute, host, outbound, src)
                   DO UPDATE SET up = up + excluded.up, down = down + excluded.down""",
                [(k[0], k[1], k[2], k[3], v[0], v[1]) for k, v in rows.items()],
            )
            db.commit()
        if started - cleanup_at > 3600:
            db.execute("DELETE FROM flows WHERE minute < ?", (int(time.time()) - RETENTION,))
            db.commit()
            cleanup_at = started
        time.sleep(max(0.5, INTERVAL - (time.time() - started)))


if __name__ == "__main__":
    main()

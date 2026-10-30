#!/usr/bin/env python3
# Tiny multi-client driver: each step is (client, sql). Clients connect lazily
# through Conn Mgr (port 5433) with optional startup options; autocommit so a
# client detaches after every statement outside an explicit transaction.
import sys
import psycopg2

HOST = "127.77.66.55"
PORT = 5433


class Clients:
    def __init__(self):
        self.conns = {}

    def add(self, name, user="yugabyte", options=None):
        kw = dict(host=HOST, port=PORT, user=user, dbname="yugabyte")
        if options:
            kw["options"] = options
        c = psycopg2.connect(**kw)
        c.autocommit = True
        self.conns[name] = c
        print(f"[{name}] connect user={user} options={options!r}", flush=True)

    def run(self, name, sql):
        cur = self.conns[name].cursor()
        try:
            cur.execute(sql)
            rows = cur.fetchall() if cur.description else None
        except Exception as e:
            print(f"[{name}] {sql}  -> ERROR {e}".strip(), flush=True)
            return None
        out = rows if rows is None else [r[0] if len(r) == 1 else r for r in rows]
        print(f"[{name}] {sql}  -> {out}", flush=True)
        return out

    def close(self, name):
        self.conns.pop(name).close()
        print(f"[{name}] disconnect", flush=True)

    def close_all(self):
        for n in list(self.conns):
            self.close(n)

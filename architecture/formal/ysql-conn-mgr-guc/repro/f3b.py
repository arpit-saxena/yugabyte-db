#!/usr/bin/env python3
# F3 stale-entry, reordered: B's SET exists in B's client list before A's no-op
# txn leaves a stale server-list entry; B's next statement reads work_mem.
import sys
sys.path.insert(0, "/home/ec2-user/.claude/jobs/81b07efd/tmp/repro")
from drv import Clients

D, X = "4MB", "8MB"
for user in ("u1", "yugabyte"):
    print(f"===== F3 stale-entry (reordered) user={user}")
    c = Clients()
    c.add("A", user)
    c.add("B", user, f"-c work_mem={X}")
    c.run("B", f"SET work_mem='{D}'")
    c.run("B", "select pg_backend_pid(), current_setting('work_mem')")
    c.run("A", "select pg_backend_pid()")
    c.run("A", "BEGIN")
    c.run("A", f"SET work_mem='{D}'")
    c.run("A", "ROLLBACK")
    c.run("B", "select pg_backend_pid(), current_setting('work_mem')")
    c.run("B", "select pg_backend_pid(), current_setting('work_mem')")
    print(f"-- expected for B both times: {D}")

    print(f"===== control: same but A's txn sets a different value, user={user}")
    c.run("A", "BEGIN")
    c.run("A", "SET work_mem='2MB'")
    c.run("A", "ROLLBACK")
    c.run("B", "select pg_backend_pid(), current_setting('work_mem')")
    c.close_all()

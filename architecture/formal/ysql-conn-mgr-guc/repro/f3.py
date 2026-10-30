#!/usr/bin/env python3
# F3: transaction-scoped change that leaves the value unchanged desyncs CM lists.
import sys
sys.path.insert(0, "/home/ec2-user/.claude/jobs/81b07efd/tmp/repro")
from drv import Clients

D = "4MB"   # default work_mem
X = "8MB"
for user in ("u1",):
    print(f"===== F3 stale-entry, literal RESULTS.md order, user={user}")
    c = Clients()
    c.add("A", user)
    c.run("A", "select pg_backend_pid()")
    c.run("A", "BEGIN")
    c.run("A", f"SET work_mem='{D}'")
    c.run("A", "ROLLBACK")
    c.add("B", user, f"-c work_mem={X}")
    c.run("B", "select pg_backend_pid()")
    c.run("B", f"SET work_mem='{D}'")
    c.run("B", "SHOW work_mem")
    print(f"-- expected for B: {D}")
    c.close_all()

    print(f"===== F3 stale-entry, B sets first then A's no-op txn, user={user}")
    c = Clients()
    c.add("A", user)
    c.add("B", user, f"-c work_mem={X}")
    c.run("B", "select pg_backend_pid()")
    c.run("B", f"SET work_mem='{D}'")
    c.run("B", "SHOW work_mem")
    c.run("A", "select pg_backend_pid()")
    c.run("A", "BEGIN")
    c.run("A", f"SET work_mem='{D}'")
    c.run("A", "ROLLBACK")
    c.run("B", "select pg_backend_pid()")
    c.run("B", "SHOW work_mem")
    print(f"-- expected for B: {D}")
    c.close_all()

    print(f"===== F3 missing-entry, literal RESULTS.md order, user={user}")
    c = Clients()
    c.add("A", user)
    c.run("A", "select pg_backend_pid()")
    c.run("A", f"SET work_mem='{D}'")
    c.run("A", "BEGIN")
    c.run("A", "RESET ALL")
    c.run("A", "ROLLBACK")
    c.add("B", user, f"-c work_mem={X}")
    c.run("B", "select pg_backend_pid()")
    c.run("B", "SHOW work_mem")
    print(f"-- expected for B: {X}")
    c.close_all()

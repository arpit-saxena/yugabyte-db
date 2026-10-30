#!/usr/bin/env python3
# F1: PGC_BACKEND startup option leaks to the next client on the same backend.
import sys
sys.path.insert(0, "/home/ec2-user/.claude/jobs/81b07efd/tmp/repro")
from drv import Clients

G = "yb_enable_fkey_batched_docdb_lookup_when_types_mismatch"  # PGC_BACKEND bool, default on

for user in ("u1", "yugabyte"):
    print(f"===== F1 variant 1 (A then B, sequential) user={user}")
    c = Clients()
    c.add("A", user, f"-c {G}=off -c post_auth_delay=7")
    c.run("A", "select pg_backend_pid()")
    c.run("A", f"show {G}")
    c.run("A", "show post_auth_delay")
    c.add("B", user)
    c.run("B", "select pg_backend_pid()")
    c.run("B", f"show {G}")
    c.run("B", "show post_auth_delay")
    print("-- expected for B: on / 0")
    c.close("A")
    c.run("B", "select pg_backend_pid()")
    c.run("B", f"show {G}")
    c.run("B", "show post_auth_delay")
    c.close_all()

    print(f"===== F1 variant 2 (RESULTS.md trace: c1 bK, c2 DateStyle, RESET ALL) user={user}")
    c = Clients()
    c.add("c1", user, f"-c {G}=off")
    c.add("c2", user, "-c DateStyle=SQL,DMY")
    c.run("c1", "select pg_backend_pid()")
    c.run("c1", "RESET ALL")
    c.run("c2", "RESET ALL")
    c.run("c2", "select pg_backend_pid()")
    c.run("c2", f"show {G}")
    c.run("c2", "show DateStyle")
    print("-- expected for c2: on / SQL, DMY")
    c.close_all()

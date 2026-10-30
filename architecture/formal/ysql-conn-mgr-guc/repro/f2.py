#!/usr/bin/env python3
# F2: 'G' on a GUC whose current source is SESSION changes only reset_val.
import sys
sys.path.insert(0, "/home/ec2-user/.claude/jobs/81b07efd/tmp/repro")
from drv import Clients

V1 = "SQL, DMY"
for user in ("u1", "yugabyte"):
    print(f"===== F2 user={user}")
    c = Clients()
    c.add("c1", user, "-c DateStyle=SQL,DMY")
    c.add("c2", user)
    c.run("c1", "select pg_backend_pid()")
    c.run("c1", f"SET DateStyle='{V1}'")             # step 2
    c.run("c2", f"SET DateStyle='{V1}'")             # step 3
    c.run("c1", "select pg_backend_pid()")           # step 4
    c.run("c2", "select pg_backend_pid()")
    c.run("c2", "RESET ALL; SHOW DateStyle")         # step 5
    c.run("c2", "SHOW DateStyle")
    print("-- expected for c2 after RESET ALL: ISO, MDY")
    c.run("c1", "select pg_backend_pid()")           # next c1 deploy -> double save WARNING?
    c.run("c1", "SHOW DateStyle")
    c.close_all()

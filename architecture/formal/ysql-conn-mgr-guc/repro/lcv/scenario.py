# usage: python3 scenario.py <sighup|baseline> <work_mem value> [pg_conf_csv]
import sys, time, subprocess, psycopg2
mode, val = sys.argv[1], sys.argv[2]
csv = sys.argv[3] if len(sys.argv) > 3 else "log_disconnections=on"
TSCLI = "/home/ec2-user/code/yb-agent2/build/latest/bin/yb-ts-cli"
def conn():
    c = psycopg2.connect(host="127.0.0.77", port=5433, user="yugabyte", dbname="yugabyte")
    c.autocommit = True
    return c
def probe(name, c):
    cur = c.cursor()
    cur.execute("SELECT pg_backend_pid(), current_setting('work_mem')")
    pid, wm = cur.fetchone()
    print(f"  {name}: pid={pid} work_mem={wm}", flush=True)
    return pid
print(f"== mode={mode} ALTER value={val}")
A = conn(); print("step1 A connects"); probe("A", A)
if mode == "sighup":
    print(f"step2 SIGHUP: set_flag --force ysql_pg_conf_csv {csv}")
    print(subprocess.run([TSCLI, "--server_address", "127.0.0.77:9100", "set_flag", "--force",
                          "ysql_pg_conf_csv", csv], capture_output=True, text=True))
    time.sleep(3)
C = conn(); print("step3 C connects (new auth + maybe spawn)"); probe("C", C)
print("step4 A runs a txn"); probe("A", A)
print(f"step5 C: ALTER DATABASE yugabyte SET work_mem = '{val}'")
C.cursor().execute(f"ALTER DATABASE yugabyte SET work_mem = '{val}'")
time.sleep(2)
print("step6 existing clients after ALTER (expect work_mem=%s under gradual)" % val)
probe("A", A); probe("C", C); probe("A", A)
print("step7 new client D connects"); D = conn(); probe("D", D)
print("step8 A after D"); probe("A", A); probe("C", C)

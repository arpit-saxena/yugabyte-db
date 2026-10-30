# SIGHUP-only: does an existing idle backend get expired without a new connection?
import time, subprocess, psycopg2
TSCLI = "/home/ec2-user/code/yb-agent2/build/latest/bin/yb-ts-cli"
def conn():
    c = psycopg2.connect(host="127.0.0.77", port=5433, user="yugabyte", dbname="yugabyte"); c.autocommit = True; return c
def probe(n, c):
    cur = c.cursor(); cur.execute("SELECT pg_backend_pid(), current_setting('log_disconnections')"); print(f"  {n}: pid,log_disconnections={cur.fetchone()}", flush=True)
A = conn(); print("A connects"); probe("A", A)
print("SIGHUP: set_flag --force ysql_pg_conf_csv log_disconnections=off")
subprocess.run([TSCLI, "--server_address", "127.0.0.77:9100", "set_flag", "--force", "ysql_pg_conf_csv", "log_disconnections=off"], check=True)
time.sleep(5); print("A after SIGHUP, 5s, no new connections"); probe("A", A)
time.sleep(5); probe("A", A)
D = conn(); print("new client D"); probe("D", D)
print("A after D"); probe("A", A)

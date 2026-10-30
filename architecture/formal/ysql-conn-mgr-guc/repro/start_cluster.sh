#!/bin/bash
# 1-node cluster on 127.77.66.55; Conn Mgr on :5433, PG on :6433; one backend per route.
B=/home/ec2-user/code/yb-agent2/build/latest
R=/home/ec2-user/.claude/jobs/81b07efd/tmp/repro
IP=127.77.66.55
mkdir -p $R/data/m $R/data/t
$B/bin/yb-master --fs_data_dirs=$R/data/m --master_addresses=$IP:7100 \
  --rpc_bind_addresses=$IP:7100 --webserver_interface=$IP --replication_factor=1 \
  --log_dir=$R/data/m >$R/master.out 2>&1 &
sleep 5
$B/bin/yb-tserver --fs_data_dirs=$R/data/t --tserver_master_addrs=$IP:7100 \
  --rpc_bind_addresses=$IP:9100 --webserver_interface=$IP \
  --cql_proxy_bind_address=$IP:9042 --pgsql_proxy_bind_address=$IP:6433 \
  --ysql_conn_mgr_port=5433 --enable_ysql=true --enable_ysql_conn_mgr=true \
  --ysql_conn_mgr_max_conns_per_db=1 --ysql_conn_mgr_min_conns_per_db=1 \
  --ysql_conn_mgr_superuser_sticky=false --ysql_conn_mgr_log_settings=log_debug \
  --start_redis_proxy=false --log_dir=$R/data/t >$R/tserver.out 2>&1 &

#!/bin/bash
# 1-node cluster on 127.0.0.77 (default ports free on that IP) with Conn Mgr, gradual, ttl 0.
set -e
B=/home/ec2-user/code/yb-agent2/build/latest/bin
D=/home/ec2-user/.claude/jobs/81b07efd/tmp/repro-lcv/data
IP=127.0.0.77
STRAT=${STRAT:-gradual}
AUTHB=${AUTHB:-false}
mkdir -p $D/m $D/t $D/logs/m $D/logs/t
$B/yb-master --master_addresses $IP:7100 --rpc_bind_addresses $IP:7100 --webserver_interface $IP \
  --fs_data_dirs $D/m --replication_factor 1 --log_dir $D/logs/m >$D/logs/master.out 2>&1 &
sleep 3
$B/yb-tserver --tserver_master_addrs $IP:7100 --rpc_bind_addresses $IP:9100 --webserver_interface $IP \
  --fs_data_dirs $D/t --log_dir $D/logs/t --cql_proxy_bind_address $IP:9042 \
  --enable_ysql --pgsql_proxy_bind_address $IP:6433 --ysql_conn_mgr_port 5433 \
  --enable_ysql_conn_mgr=true --allowed_preview_flags_csv=enable_ysql_conn_mgr \
  --ysql_conn_mgr_alter_guc_adoption_strategy=$STRAT \
  --ysql_conn_mgr_alter_guc_stale_backend_ttl_ms=0 \
  --ysql_conn_mgr_use_auth_backend=$AUTHB \
  --ysql_conn_mgr_log_settings=log_debug --ysql_conn_mgr_superuser_sticky=false \
  >$D/logs/tserver.out 2>&1 &

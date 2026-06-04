#!/usr/bin/env bash
# Point cortpdb_dev datasource at Windows localhost portproxy (WSL -> Windows -> LAN DB).
set -euo pipefail

LISTEN_PORT="${1:-15433}"
HOST="127.0.0.1"
PORT="$LISTEN_PORT"
DB_NAME='cortpdb_dev|v4_zeus'
JDBC="jdbc:postgresql://${HOST}:${PORT}/cortpdb_dev?useUnicode=true&characterEncoding=utf-8&useSSL=false&serverTimezone=Asia/Shanghai"
MANAGEMENT_DB="${DATA_AGENT_DB:-saa_data_agent}"
PG_USER="${PGUSER:-postgres}"
PG_PASSWORD="${PGPASSWORD:-postgres}"

PGPASSWORD="${PG_PASSWORD}" psql -h 127.0.0.1 -U "${PG_USER}" -d "${MANAGEMENT_DB}" -v ON_ERROR_STOP=1 <<SQL
UPDATE datasource
SET host='${HOST}', port=${PORT}, database_name='${DB_NAME}',
    connection_url='${JDBC}', test_status='unknown', update_time=CURRENT_TIMESTAMP
WHERE id=3;
SELECT id,name,host,port,database_name,connection_url,test_status FROM datasource WHERE id=3;
SQL

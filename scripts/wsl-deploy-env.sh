#!/usr/bin/env bash
# Install/start local PostgreSQL in WSL and initialize DataAgent databases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PG_SQL_DIR="${REPO_ROOT}/data-agent-management/src/main/resources/sql/pg"
PG_USER="${PGUSER:-postgres}"
PG_PASSWORD="${PGPASSWORD:-postgres}"
PG_HOST="${PGHOST:-127.0.0.1}"
PG_PORT="${PGPORT:-}"
MANAGEMENT_DB="${DATA_AGENT_DB:-saa_data_agent}"
PRODUCT_DB="${PRODUCT_DB:-product_db}"
CHINA_POPULATION_DB="${CHINA_POPULATION_DB:-china_population_db}"
SEEDED_DATASOURCE_HOST="${DATA_AGENT_SEEDED_DATASOURCE_HOST:-127.0.0.1}"

log() { printf '[wsl-pg] %s\n' "$*"; }
die() { printf '[wsl-pg] ERROR: %s\n' "$*" >&2; exit 1; }

if command -v flock >/dev/null 2>&1; then
  LOCK_FILE="${TMPDIR:-/tmp}/agentscope-wsl-deploy-env.lock"
  exec 9>"${LOCK_FILE}"
  flock -w 180 9 || die "Timed out waiting for another PostgreSQL initialization to finish"
fi

ensure_postgres_installed() {
  if command -v psql >/dev/null 2>&1 && command -v pg_isready >/dev/null 2>&1; then
    return
  fi
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. Install PostgreSQL manually in this WSL distro."
  log "Installing PostgreSQL via apt..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib
}

ensure_pgvector_installed() {
  local pg_major
  pg_major="$(sudo -u postgres psql -p "$(postgres_port)" -Atc "SHOW server_version_num;" | cut -c1-2)"
  if sudo -u postgres psql -p "$(postgres_port)" -d "${MANAGEMENT_DB}" -Atc "SELECT 1 FROM pg_available_extensions WHERE name = 'vector';" | grep -q 1; then
    return
  fi
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found. Install pgvector manually in this WSL distro."
  log "Installing PGVector extension package for PostgreSQL ${pg_major}..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "postgresql-${pg_major}-pgvector"
}

start_postgres() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files postgresql.service >/dev/null 2>&1; then
    sudo systemctl enable postgresql >/dev/null 2>&1 || true
    sudo systemctl start postgresql || true
  fi

  if ! sudo -u postgres pg_isready -p "$(postgres_port)" >/dev/null 2>&1; then
    sudo service postgresql start >/dev/null 2>&1 || true
  fi

  deadline=$((SECONDS + 60))
  until sudo -u postgres pg_isready -p "$(postgres_port)" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "PostgreSQL did not become ready on local socket port $(postgres_port)"
    sleep 2
  done
}

postgres_port() {
  if [[ -n "${PG_PORT}" ]]; then
    printf '%s\n' "${PG_PORT}"
    return
  fi

  if command -v pg_lsclusters >/dev/null 2>&1; then
    PG_PORT="$(pg_lsclusters --no-header 2>/dev/null | awk '$4 == "online" { found = 1; print $3; exit } NR == 1 { first = $3 } END { if (!found && first) print first }')"
  fi
  if [[ -z "${PG_PORT}" ]]; then
    PG_PORT="$(ss -ltn 2>/dev/null | awk '/127[.]0[.]0[.]1:54[0-9][0-9]/ { sub(/^.*:/, "", $4); print $4; exit }')"
  fi
  if [[ -z "${PG_PORT}" ]]; then
    PG_PORT=5432
  fi
  printf '%s\n' "${PG_PORT}"
}

postgres_public_host() {
  if [[ -n "${PG_PUBLIC_HOST:-}" ]]; then
    printf '%s\n' "${PG_PUBLIC_HOST}"
    return
  fi

  local host=""
  if command -v ip >/dev/null 2>&1; then
    host="$(ip -4 -o addr show scope global 2>/dev/null \
      | awk '$2 !~ /^(docker|br-|veth|lo|loopback)/ { split($4, a, "/"); if (a[1] !~ /^169[.]254[.]/) { print a[1]; exit } }')"
  fi
  if [[ -z "${host}" ]]; then
    host="${PG_HOST}"
  fi
  printf '%s\n' "${host}"
}

configure_postgres_network() {
  local config_file hba_file changed=0
  config_file="$(sudo -u postgres psql -p "$(postgres_port)" -Atc "SHOW config_file;" 2>/dev/null || true)"
  hba_file="$(sudo -u postgres psql -p "$(postgres_port)" -Atc "SHOW hba_file;" 2>/dev/null || true)"
  [[ -n "${config_file}" && -n "${hba_file}" ]] || return

  if ! sudo grep -Eq "^[[:space:]]*listen_addresses[[:space:]]*=[[:space:]]*'[*]'" "${config_file}"; then
    log "Configuring PostgreSQL listen_addresses=* for Windows access to WSL PostgreSQL..."
    if sudo grep -Eq "^[#[:space:]]*listen_addresses[[:space:]]*=" "${config_file}"; then
      sudo sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '*'/" "${config_file}"
    else
      printf "\nlisten_addresses = '*'\n" | sudo tee -a "${config_file}" >/dev/null
    fi
    changed=1
  fi

  if ! sudo grep -q "agentscope local dev access" "${hba_file}"; then
    log "Allowing local/private-network PostgreSQL clients for DataAgent dev..."
    sudo tee -a "${hba_file}" >/dev/null <<'EOF'

# agentscope local dev access
host all all 127.0.0.1/32 scram-sha-256
host all all 10.0.0.0/8 scram-sha-256
host all all 172.16.0.0/12 scram-sha-256
host all all 192.168.0.0/16 scram-sha-256
EOF
    changed=1
  fi

  if [[ "${changed}" -eq 1 ]]; then
    log "Restarting PostgreSQL after network configuration..."
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl restart postgresql || true
    fi
    sudo service postgresql restart >/dev/null 2>&1 || true

    deadline=$((SECONDS + 60))
    until sudo -u postgres pg_isready -p "$(postgres_port)" >/dev/null 2>&1; do
      (( SECONDS < deadline )) || die "PostgreSQL did not become ready after network configuration"
      sleep 2
    done
  fi
}

configure_postgres_user() {
  log "Configuring postgres password..."
  sudo -u postgres psql -p "$(postgres_port)" -v ON_ERROR_STOP=1 -c "ALTER USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';"
}

ensure_database() {
  local db="$1"
  if ! sudo -u postgres psql -p "$(postgres_port)" -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    log "Creating database ${db}..."
    sudo -u postgres createdb -p "$(postgres_port)" -O "${PG_USER}" "${db}"
  fi
}

run_sql() {
  local db="$1"
  local file="$2"
  log "Importing ${file} into ${db}..."
  sudo -u postgres psql -p "$(postgres_port)" -d "${db}" -v ON_ERROR_STOP=1 -f "${file}"
}

ensure_postgres_installed
start_postgres
configure_postgres_user
configure_postgres_network
ensure_database "${MANAGEMENT_DB}"
ensure_database "${PRODUCT_DB}"
ensure_database "${CHINA_POPULATION_DB}"
ensure_pgvector_installed

run_sql "${MANAGEMENT_DB}" "${PG_SQL_DIR}/schema.sql"
run_sql "${MANAGEMENT_DB}" "${PG_SQL_DIR}/data.sql"
run_sql "${PRODUCT_DB}" "${PG_SQL_DIR}/product_schema.sql"
run_sql "${PRODUCT_DB}" "${PG_SQL_DIR}/product_data.sql"
run_sql "${CHINA_POPULATION_DB}" "${PG_SQL_DIR}/china_population_db.sql"

PUBLIC_PG_HOST="$(postgres_public_host)"
log "Pointing seeded datasources at WSL PostgreSQL ${SEEDED_DATASOURCE_HOST}:$(postgres_port)..."
sudo -u postgres psql -p "$(postgres_port)" -d "${MANAGEMENT_DB}" -v ON_ERROR_STOP=1 <<SQL
UPDATE datasource
SET host = '${SEEDED_DATASOURCE_HOST}',
    port = $(postgres_port),
    connection_url = 'jdbc:postgresql://${SEEDED_DATASOURCE_HOST}:$(postgres_port)/product_db',
    status = 'active',
    test_status = 'unknown',
    update_time = NOW()
WHERE id = 1;

UPDATE datasource
SET host = '${SEEDED_DATASOURCE_HOST}',
    port = $(postgres_port),
    connection_url = 'jdbc:postgresql://${SEEDED_DATASOURCE_HOST}:$(postgres_port)/china_population_db',
    status = 'active',
    test_status = 'unknown',
    update_time = NOW()
WHERE id = 2;
SQL

log "Verifying management database..."
agent_count="$(sudo -u postgres psql -p "$(postgres_port)" -d "${MANAGEMENT_DB}" -tAc "SELECT COUNT(*) FROM agent;")"
table_count="$(sudo -u postgres psql -p "$(postgres_port)" -d "${MANAGEMENT_DB}" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';")"
product_user_count="$(sudo -u postgres psql -p "$(postgres_port)" -d "${PRODUCT_DB}" -tAc "SELECT COUNT(*) FROM users;")"
population_year_count="$(sudo -u postgres psql -p "$(postgres_port)" -d "${CHINA_POPULATION_DB}" -tAc "SELECT COUNT(*) FROM population_total;")"
datasource_port_count="$(sudo -u postgres psql -p "$(postgres_port)" -d "${MANAGEMENT_DB}" -tAc "SELECT COUNT(*) FROM datasource WHERE id IN (1, 2) AND host='${SEEDED_DATASOURCE_HOST}' AND port=$(postgres_port);")"
[[ "${agent_count}" -ge 4 ]] || die "agent seed data missing"
[[ "${table_count}" -ge 10 ]] || die "management schema appears incomplete"
[[ "${product_user_count}" -ge 5 ]] || die "product sample seed data missing"
[[ "${population_year_count}" -ge 1 ]] || die "china population seed data missing"
[[ "${datasource_port_count}" -eq 2 ]] || die "seeded datasource connection settings were not updated"

cat <<EOF

PostgreSQL deployment complete.

  Management DB:
    JDBC: jdbc:postgresql://${PG_HOST}:$(postgres_port)/${MANAGEMENT_DB}
    External JDBC: jdbc:postgresql://${PUBLIC_PG_HOST}:$(postgres_port)/${MANAGEMENT_DB}
    user: ${PG_USER}
    password: ${PG_PASSWORD}

  Product sample DB:
    App JDBC: jdbc:postgresql://${SEEDED_DATASOURCE_HOST}:$(postgres_port)/${PRODUCT_DB}
    External JDBC: jdbc:postgresql://${PUBLIC_PG_HOST}:$(postgres_port)/${PRODUCT_DB}
    user: ${PG_USER}
    password: ${PG_PASSWORD}

  China population sample DB:
    App JDBC: jdbc:postgresql://${SEEDED_DATASOURCE_HOST}:$(postgres_port)/${CHINA_POPULATION_DB}
    External JDBC: jdbc:postgresql://${PUBLIC_PG_HOST}:$(postgres_port)/${CHINA_POPULATION_DB}
    user: ${PG_USER}
    password: ${PG_PASSWORD}

EOF

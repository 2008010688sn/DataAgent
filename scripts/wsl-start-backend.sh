#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/.local/logs"
BACKEND_PORT=8065
PG_PORT="${PGPORT:-}"

postgres_port() {
  if [[ -n "${PG_PORT}" ]]; then
    printf '%s\n' "${PG_PORT}"
    return
  fi
  if command -v pg_lsclusters >/dev/null 2>&1; then
    PG_PORT="$(pg_lsclusters --no-header 2>/dev/null | awk '$4 == "online" { found = 1; print $3; exit } NR == 1 { first = $3 } END { if (!found && first) print first }')"
  fi
  if [[ -z "${PG_PORT}" ]]; then
    PG_PORT=5432
  fi
  printf '%s\n' "${PG_PORT}"
}

mkdir -p "${LOG_DIR}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

echo "Ensuring local PostgreSQL and seed data..."
bash "${SCRIPT_DIR}/wsl-deploy-env.sh"

if command -v fuser >/dev/null 2>&1; then
	fuser -k "${BACKEND_PORT}/tcp" >/dev/null 2>&1 || true
fi

export DATA_AGENT_DATASOURCE_URL="jdbc:postgresql://127.0.0.1:$(postgres_port)/saa_data_agent"
export DATA_AGENT_DATASOURCE_USERNAME=postgres
export DATA_AGENT_DATASOURCE_PASSWORD=postgres
export DATA_AGENT_DATASOURCE_SQL_INIT=never
export LANGFUSE_ENABLED="${LANGFUSE_ENABLED:-true}"
export LANGFUSE_HOST="${LANGFUSE_HOST:-http://127.0.0.1:3000}"
export LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
export LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"
export AGENTSCOPE_OBSERVABILITY_ENABLED="${AGENTSCOPE_OBSERVABILITY_ENABLED:-true}"
export AGENTSCOPE_OBSERVABILITY_USE_LANGFUSE_TRACER="${AGENTSCOPE_OBSERVABILITY_USE_LANGFUSE_TRACER:-true}"
export SERVER_ADDRESS=0.0.0.0
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Djava.net.preferIPv4Stack=true"

if grep -q $'\r' "${REPO_ROOT}/mvnw" 2>/dev/null; then
	sed -i 's/\r$//' "${REPO_ROOT}/mvnw"
fi

cd "${REPO_ROOT}"
nohup ./mvnw -pl data-agent-management spring-boot:run \
  -Dmaven.test.skip=true \
  -Dspotless.skip=true \
  -Dcheckstyle.skip=true \
  -Djacoco.skip=true \
  >"${LOG_DIR}/backend.log" 2>&1 &
echo $! >"${LOG_DIR}/backend.pid"
printf 'backend pid=%s\n' "$(cat "${LOG_DIR}/backend.pid")"

"${SCRIPT_DIR}/wsl-wait-backend.sh"

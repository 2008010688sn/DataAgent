#!/usr/bin/env bash
# Start DataAgent backend + frontend inside WSL with local PostgreSQL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/data-agent-management"
FRONTEND_DIR="${REPO_ROOT}/data-agent-frontend"
LOG_DIR="${REPO_ROOT}/.local/logs"
BACKEND_PORT=8065
FRONTEND_PORT="${FRONTEND_PORT:-5174}"
PG_PORT="${PGPORT:-}"

log() { printf '[wsl-start] %s\n' "$*"; }
die() { printf '[wsl-start] ERROR: %s\n' "$*" >&2; exit 1; }

resolve_node() {
  if command -v node >/dev/null 2>&1; then
    command -v node
    return
  fi
  for candidate in \
    "/mnt/d/Program Files/nodejs/node.exe" \
    "/mnt/c/Program Files/nodejs/node.exe"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return
    fi
  done
  die "node not found. Install Node.js in WSL or ensure Windows Node is at /mnt/d/Program Files/nodejs/"
}

stop_port() {
  local port="$1"
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" >/dev/null 2>&1 || true
  fi
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
    PG_PORT=5432
  fi
  printf '%s\n' "${PG_PORT}"
}

log "Ensuring local PostgreSQL..."
bash "${SCRIPT_DIR}/wsl-deploy-env.sh"

mkdir -p "${LOG_DIR}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

log "Stopping old listeners on ${BACKEND_PORT} and ${FRONTEND_PORT}..."
stop_port "${BACKEND_PORT}"
stop_port "${FRONTEND_PORT}"
sleep 2

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

log "Starting backend (port ${BACKEND_PORT})..."
(
  cd "${REPO_ROOT}"
  nohup ./mvnw -pl data-agent-management spring-boot:run \
    -Dmaven.test.skip=true \
    -Dspotless.skip=true \
    -Dcheckstyle.skip=true \
    -Djacoco.skip=true \
    >"${LOG_DIR}/backend.log" 2>&1 &
  echo $! >"${LOG_DIR}/backend.pid"
)

NODE_BIN="$(resolve_node)"
log "Using Node: ${NODE_BIN}"
log "Starting frontend (port ${FRONTEND_PORT})..."
(
  cd "${FRONTEND_DIR}"
  nohup "${NODE_BIN}" node_modules/vite/bin/vite.js --host 127.0.0.1 --port "${FRONTEND_PORT}" \
    >"${LOG_DIR}/frontend.log" 2>&1 &
  echo $! >"${LOG_DIR}/frontend.pid"
)

log "Waiting for backend..."
ready=false
for _ in $(seq 1 90); do
  if curl -4 -fsS "http://127.0.0.1:${BACKEND_PORT}/api/agent/list" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done

if [[ "${ready}" != true ]]; then
  log "Backend not ready yet. Check ${LOG_DIR}/backend.log"
else
  log "Backend is up."
fi

if curl -4 -fsS "http://127.0.0.1:${FRONTEND_PORT}/" >/dev/null 2>&1; then
  log "Frontend is up."
else
  log "Frontend not ready yet. Check ${LOG_DIR}/frontend.log"
fi

cat <<EOF

Services started in WSL.

  Frontend : http://127.0.0.1:${FRONTEND_PORT}/
  Backend  : http://127.0.0.1:${BACKEND_PORT}/
  Swagger  : http://127.0.0.1:${BACKEND_PORT}/swagger-ui.html

Logs:
  ${LOG_DIR}/backend.log
  ${LOG_DIR}/frontend.log

Stop:
  kill \$(cat ${LOG_DIR}/backend.pid ${LOG_DIR}/frontend.pid 2>/dev/null) 2>/dev/null || true

EOF

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/autostart.log"
CONTAINER_NAME="${HIGRESS_CONTAINER_NAME:-higress-ai-gateway}"
DOCKER_NETWORK="${HIGRESS_DOCKER_NETWORK:-higress-ai}"
REDIS_CONTAINER_NAME="${HIGRESS_REDIS_CONTAINER_NAME:-higress-ai-redis}"
REDIS_IMAGE="${HIGRESS_REDIS_IMAGE:-redis:7-alpine}"
REDIS_PROXY_SCRIPT="${SCRIPT_DIR}/expose-higress-redis.sh"
GOVERNANCE_SCRIPT="${SCRIPT_DIR}/apply-dataagent-ai-governance.sh"

mkdir -p "${LOG_DIR}" "${DATA_DIR}/logs"
exec >>"${LOG_FILE}" 2>&1

echo
echo "[$(date -Is)] Starting Higress local stack"

wait_for_docker() {
  local deadline=$((SECONDS + 120))
  while ! docker info >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "Docker is not available after waiting."
      return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start docker >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
      service docker start >/dev/null 2>&1 || true
    fi
    sleep 3
  done
}

ensure_network() {
  if ! docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1; then
    docker network create "${DOCKER_NETWORK}" >/dev/null
  fi
}

ensure_redis() {
  if ! docker inspect "${REDIS_CONTAINER_NAME}" >/dev/null 2>&1; then
    docker run -d \
      --name "${REDIS_CONTAINER_NAME}" \
      --network "${DOCKER_NETWORK}" \
      --network-alias redis.local \
      --restart unless-stopped \
      "${REDIS_IMAGE}" >/dev/null
  elif [[ "$(docker inspect -f '{{.State.Running}}' "${REDIS_CONTAINER_NAME}")" != "true" ]]; then
    docker start "${REDIS_CONTAINER_NAME}" >/dev/null
  fi

  docker network connect --alias redis.local "${DOCKER_NETWORK}" "${REDIS_CONTAINER_NAME}" >/dev/null 2>&1 || true
}

ensure_gateway() {
  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    docker start "${CONTAINER_NAME}" >/dev/null
    docker network connect "${DOCKER_NETWORK}" "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  else
    echo "Gateway container is missing; running start-higress-ai-gateway.sh."
    if [[ -z "${DASHSCOPE_API_KEY:-}" ]]; then
      local cfg="${DATA_DIR}/default.cfg"
      if [[ -f "${cfg}" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "${cfg}"
        set +a
      fi
    fi
    HIGRESS_IMAGE_TAG="${HIGRESS_IMAGE_TAG:-latest-o11y}" "${SCRIPT_DIR}/start-higress-ai-gateway.sh"
  fi
}

apply_governance() {
  if [[ -x "${GOVERNANCE_SCRIPT}" ]]; then
    HIGRESS_DATA_DIR="${DATA_DIR}" "${GOVERNANCE_SCRIPT}"
  fi
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local deadline=$((SECONDS + 120))
  while true; do
    if curl -fsS -o /dev/null --max-time 5 "${url}"; then
      echo "${name} is ready: ${url}"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "${name} did not become ready: ${url}"
      return 1
    fi
    sleep 3
  done
}

wait_for_docker
ensure_network
ensure_redis
if [[ -x "${REDIS_PROXY_SCRIPT}" ]]; then
  "${REDIS_PROXY_SCRIPT}"
fi
ensure_gateway
apply_governance
docker restart "${CONTAINER_NAME}" >/dev/null

wait_for_http "Higress console" "http://127.0.0.1:8001/dashboard"
wait_for_http "Higress Grafana" "http://127.0.0.1:8001/grafana/d/aPrPx4xDz/higress-ai-gateway-dashboard?orgId=1"

echo "[$(date -Is)] Higress local stack is ready"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
INSTALL_SCRIPT="${SCRIPT_DIR}/get-ai-gateway.sh"
GOVERNANCE_SCRIPT="${SCRIPT_DIR}/apply-dataagent-ai-governance.sh"
CONTAINER_NAME="${HIGRESS_CONTAINER_NAME:-higress-ai-gateway}"
HTTP_PORT="${HIGRESS_HTTP_PORT:-8080}"
HTTPS_PORT="${HIGRESS_HTTPS_PORT:-8443}"
CONSOLE_PORT="${HIGRESS_CONSOLE_PORT:-8001}"
IMAGE_TAG="${HIGRESS_IMAGE_TAG:-latest-o11y}"
DASHSCOPE_MODELS="${DASHSCOPE_MODELS:-qwen*,text-embedding*}"
DOCKER_NETWORK="${HIGRESS_DOCKER_NETWORK:-higress-ai}"
REDIS_CONTAINER_NAME="${HIGRESS_REDIS_CONTAINER_NAME:-higress-ai-redis}"
REDIS_IMAGE="${HIGRESS_REDIS_IMAGE:-redis:7-alpine}"
REDIS_HOST_BIND="${HIGRESS_REDIS_HOST_BIND:-127.0.0.1}"
REDIS_HOST_PORT="${HIGRESS_REDIS_HOST_PORT:-}"

ensure_redis() {
  if ! docker network inspect "${DOCKER_NETWORK}" >/dev/null 2>&1; then
    docker network create "${DOCKER_NETWORK}" >/dev/null
  fi

  if ! docker inspect "${REDIS_CONTAINER_NAME}" >/dev/null 2>&1; then
    local docker_args=(
      run -d
      --name "${REDIS_CONTAINER_NAME}"
      --network "${DOCKER_NETWORK}"
      --network-alias redis.local
      --restart unless-stopped
    )
    if [[ -n "${REDIS_HOST_PORT}" ]]; then
      docker_args+=(-p "${REDIS_HOST_BIND}:${REDIS_HOST_PORT}:6379")
    fi
    docker_args+=("${REDIS_IMAGE}")
    docker "${docker_args[@]}" >/dev/null
  elif [[ "$(docker inspect -f '{{.State.Running}}' "${REDIS_CONTAINER_NAME}")" != "true" ]]; then
    docker start "${REDIS_CONTAINER_NAME}" >/dev/null
  fi

  if [[ -n "${REDIS_HOST_PORT}" ]]; then
    local published
    published="$(docker inspect -f '{{range $port, $conf := .NetworkSettings.Ports}}{{if eq $port "6379/tcp"}}{{range $conf}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}{{end}}' "${REDIS_CONTAINER_NAME}")"
    if [[ -z "${published}" ]]; then
      echo "Redis container ${REDIS_CONTAINER_NAME} already exists without a host port mapping." >&2
      echo "Docker cannot add -p to an existing container; recreate Redis to expose ${REDIS_HOST_BIND}:${REDIS_HOST_PORT}." >&2
    fi
  fi
  docker network connect --alias redis.local "${DOCKER_NETWORK}" "${REDIS_CONTAINER_NAME}" >/dev/null 2>&1 || true
}

connect_gateway_network() {
  if docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    docker network connect "${DOCKER_NETWORK}" "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

if [[ ! -x "${INSTALL_SCRIPT}" ]]; then
  curl -fsSL 'https://higress.cn/ai-gateway/install.sh' -o "${INSTALL_SCRIPT}"
  chmod +x "${INSTALL_SCRIPT}"
fi

if [[ -z "${DASHSCOPE_API_KEY:-}" ]]; then
  echo "DASHSCOPE_API_KEY is required." >&2
  echo "Example: DASHSCOPE_API_KEY=sk-xxx ${BASH_SOURCE[0]}" >&2
  exit 1
fi

mkdir -p "${DATA_DIR}"
ensure_redis
REDIS_ENDPOINT="${REDIS_CONTAINER_NAME} on Docker network ${DOCKER_NETWORK}"
if [[ -n "${REDIS_HOST_PORT}" ]]; then
  REDIS_ENDPOINT="${REDIS_ENDPOINT}; host ${REDIS_HOST_BIND}:${REDIS_HOST_PORT}"
fi

"${INSTALL_SCRIPT}" start --non-interactive \
  --container-name "${CONTAINER_NAME}" \
  --data-folder "${DATA_DIR}" \
  --http-port "${HTTP_PORT}" \
  --https-port "${HTTPS_PORT}" \
  --console-port "${CONSOLE_PORT}" \
  --image-tag "${IMAGE_TAG}" \
  --dashscope-key "${DASHSCOPE_API_KEY}" \
  --dashscope-models "${DASHSCOPE_MODELS}"

connect_gateway_network

if [[ -x "${GOVERNANCE_SCRIPT}" ]]; then
  HIGRESS_DATA_DIR="${DATA_DIR}" "${GOVERNANCE_SCRIPT}"
  docker restart "${CONTAINER_NAME}" >/dev/null
  sleep 10
  connect_gateway_network
else
  echo "Governance script not executable: ${GOVERNANCE_SCRIPT}" >&2
fi

cat <<EOF

Higress AI Gateway:
  Gateway HTTP : http://127.0.0.1:${HTTP_PORT}
  Console      : http://127.0.0.1:${CONSOLE_PORT}
  Redis        : ${REDIS_ENDPOINT}

DataAgent model baseUrl:
  http://127.0.0.1:${HTTP_PORT}

EOF

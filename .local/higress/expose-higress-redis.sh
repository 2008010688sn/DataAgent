#!/usr/bin/env bash
set -euo pipefail

DOCKER_NETWORK="${HIGRESS_DOCKER_NETWORK:-higress-ai}"
REDIS_IMAGE="${HIGRESS_REDIS_IMAGE:-redis:7-alpine}"
PROXY_CONTAINER_NAME="${HIGRESS_REDIS_PROXY_CONTAINER_NAME:-higress-ai-redis-proxy}"
HOST_BIND="${HIGRESS_REDIS_HOST_BIND:-127.0.0.1}"
HOST_PORT="${HIGRESS_REDIS_HOST_PORT:-6380}"
TARGET_HOST="${HIGRESS_REDIS_TARGET_HOST:-redis.local}"
TARGET_PORT="${HIGRESS_REDIS_TARGET_PORT:-6379}"

if docker inspect "${PROXY_CONTAINER_NAME}" >/dev/null 2>&1; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "${PROXY_CONTAINER_NAME}")" != "true" ]]; then
    docker start "${PROXY_CONTAINER_NAME}" >/dev/null
  fi
else
  docker run -d \
    --name "${PROXY_CONTAINER_NAME}" \
    --network "${DOCKER_NETWORK}" \
    -p "${HOST_BIND}:${HOST_PORT}:6379" \
    --restart unless-stopped \
    "${REDIS_IMAGE}" \
    sh -c "nc -lk -p 6379 -e nc ${TARGET_HOST} ${TARGET_PORT}" >/dev/null
fi

published="$(docker inspect -f '{{range $port, $conf := .NetworkSettings.Ports}}{{if eq $port "6379/tcp"}}{{range $conf}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}{{end}}' "${PROXY_CONTAINER_NAME}")"

echo "Higress Redis is exposed at ${published:-${HOST_BIND}:${HOST_PORT}}"

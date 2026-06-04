#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HIGRESS_DATA_DIR:-${SCRIPT_DIR}/data}"
MCPBRIDGE="${DATA_DIR}/mcpbridges/default.yaml"
ROUTE_NAME="${HIGRESS_AI_ROUTE_NAME:-ai-route-aliyun.internal}"
REDIS_SERVICE="${HIGRESS_REDIS_SERVICE_NAME:-redis.dns}"
APP_CONSUMER="${HIGRESS_APP_CONSUMER:-dataagent-app}"
ADMIN_CONSUMER="${HIGRESS_ADMIN_CONSUMER:-dataagent-admin}"
APP_KEY="${HIGRESS_APP_KEY:-higress-local-key}"
ADMIN_KEY="${HIGRESS_ADMIN_KEY:-higress-admin-key}"
APP_TOKEN_PER_HOUR="${HIGRESS_APP_TOKEN_PER_HOUR:-5000000}"
ADMIN_TOKEN_PER_HOUR="${HIGRESS_ADMIN_TOKEN_PER_HOUR:-10000000}"
CACHE_TTL_SECONDS="${HIGRESS_CACHE_TTL_SECONDS:-3600}"

if [[ ! -f "${MCPBRIDGE}" ]]; then
  echo "Missing ${MCPBRIDGE}. Start Higress once before applying governance config." >&2
  exit 1
fi

mkdir -p \
  "${DATA_DIR}/ingresses" \
  "${DATA_DIR}/wasmplugins"

sed -i 's/domain: higress-ai-redis/domain: redis.local/' "${MCPBRIDGE}"

if ! grep -q 'domain: redis.local' "${MCPBRIDGE}"; then
  tmp_file="$(mktemp)"
  awk '
    { print }
    /name: higress-console/ { in_console = 1 }
    in_console && /type: static/ {
      print "  - domain: redis.local"
      print "    name: redis"
      print "    port: 6379"
      print "    type: dns"
      in_console = 0
    }
  ' "${MCPBRIDGE}" > "${tmp_file}"
  mv "${tmp_file}" "${MCPBRIDGE}"
fi

cat > "${DATA_DIR}/ingresses/redis.internal.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    higress.io/destination: ${REDIS_SERVICE}:6379
    higress.io/ignore-path-case: "false"
  labels:
    higress.io/resource-definer: higress
  name: redis.internal
  namespace: higress-system
  resourceVersion: "1"
spec:
  ingressClassName: higress
  rules:
  - host: redis.local
    http:
      paths:
      - backend:
          resource:
            apiGroup: networking.higress.io
            kind: McpBridge
            name: default
        path: /
        pathType: Prefix
status:
  loadBalancer: {}
EOF

cat > "${DATA_DIR}/wasmplugins/key-auth.internal.yaml" <<EOF
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-description: Authentication based on API Key.
    higress.io/wasm-plugin-title: Key Auth
  labels:
    higress.io/internal: "true"
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: "true"
    higress.io/wasm-plugin-category: auth
    higress.io/wasm-plugin-name: key-auth
    higress.io/wasm-plugin-version: 1.0.0
  name: key-auth.internal
  namespace: higress-system
  resourceVersion: "1"
spec:
  defaultConfig:
    consumers:
    - credentials:
      - ${APP_KEY}
      - Bearer ${APP_KEY}
      name: ${APP_CONSUMER}
    - credentials:
      - ${ADMIN_KEY}
      - Bearer ${ADMIN_KEY}
      name: ${ADMIN_CONSUMER}
    global_auth: true
    in_header: true
    in_query: false
    keys:
    - Authorization
    - X-API-Key
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  matchRules:
  - config:
      allow:
      - ${APP_CONSUMER}
      - ${ADMIN_CONSUMER}
    configDisable: false
    ingress:
    - ${ROUTE_NAME}
  phase: AUTHN
  priority: 310
  url: http://localhost:8002/plugins/key-auth/1.0.0/plugin.wasm
status: {}
EOF

cat > "${DATA_DIR}/wasmplugins/ai-statistics-1.0.0.yaml" <<EOF
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Statistics
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: "true"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: ai-statistics
    higress.io/wasm-plugin-version: 1.0.0
  name: ai-statistics-1.0.0
  namespace: higress-system
  resourceVersion: "1"
spec:
  defaultConfig:
    use_default_attributes: true
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  matchRules:
  - config:
      use_default_response_attributes: true
    configDisable: false
    ingress:
    - ${ROUTE_NAME}
  priority: 900
  url: http://localhost:8002/plugins/ai-statistics/1.0.0/plugin.wasm
status: {}
EOF

cat > "${DATA_DIR}/wasmplugins/ai-quota-1.0.0.yaml" <<EOF
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Quota
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: "true"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: ai-quota
    higress.io/wasm-plugin-version: 1.0.0
  name: ai-quota-1.0.0
  namespace: higress-system
  resourceVersion: "1"
spec:
  defaultConfig:
    redis_key_prefix: "dataagent:ai-quota:"
    admin_consumer: ${ADMIN_CONSUMER}
    admin_path: /quota
    enable_path_suffixes:
    - /v1/chat/completions
    redis:
      service_name: ${REDIS_SERVICE}
      service_port: 6379
      timeout: 2000
      database: 0
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  matchRules:
  - config:
      redis_key_prefix: "dataagent:ai-quota:"
      admin_consumer: ${ADMIN_CONSUMER}
      admin_path: /quota
      enable_path_suffixes:
      - /v1/chat/completions
      redis:
        service_name: ${REDIS_SERVICE}
        service_port: 6379
        timeout: 2000
        database: 0
    configDisable: false
    ingress:
    - ${ROUTE_NAME}
  phase: AUTHZ
  priority: 750
  url: http://localhost:8002/plugins/ai-quota/1.0.0/plugin.wasm
status: {}
EOF

cat > "${DATA_DIR}/wasmplugins/ai-token-ratelimit-1.0.0.yaml" <<EOF
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Token Rate Limit
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: "true"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: ai-token-ratelimit
    higress.io/wasm-plugin-version: 1.0.0
  name: ai-token-ratelimit-1.0.0
  namespace: higress-system
  resourceVersion: "1"
spec:
  defaultConfig:
    rule_name: dataagent-token-limit
    rule_items:
    - limit_by_consumer: ""
      limit_keys:
      - key: ${APP_CONSUMER}
        token_per_hour: ${APP_TOKEN_PER_HOUR}
      - key: ${ADMIN_CONSUMER}
        token_per_hour: ${ADMIN_TOKEN_PER_HOUR}
    rejected_code: 429
    rejected_msg: "Too many model tokens used in the current window"
    redis:
      service_name: ${REDIS_SERVICE}
      service_port: 6379
      timeout: 2000
      database: 0
  defaultConfigDisable: false
  failStrategy: FAIL_OPEN
  matchRules:
  - config:
      rule_name: dataagent-token-limit
      rule_items:
      - limit_by_consumer: ""
        limit_keys:
        - key: ${APP_CONSUMER}
          token_per_hour: ${APP_TOKEN_PER_HOUR}
        - key: ${ADMIN_CONSUMER}
          token_per_hour: ${ADMIN_TOKEN_PER_HOUR}
      rejected_code: 429
      rejected_msg: "Too many model tokens used in the current window"
      redis:
        service_name: ${REDIS_SERVICE}
        service_port: 6379
        timeout: 2000
        database: 0
    configDisable: false
    ingress:
    - ${ROUTE_NAME}
  phase: AUTHZ
  priority: 600
  url: http://localhost:8002/plugins/ai-token-ratelimit/1.0.0/plugin.wasm
status: {}
EOF

cat > "${DATA_DIR}/wasmplugins/ai-cache-1.0.0.yaml" <<EOF
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  annotations:
    higress.io/wasm-plugin-title: AI Cache
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: "true"
    higress.io/wasm-plugin-category: ai
    higress.io/wasm-plugin-name: ai-cache
    higress.io/wasm-plugin-version: 1.0.0
  name: ai-cache-1.0.0
  namespace: higress-system
  resourceVersion: "1"
spec:
  defaultConfig:
    cache:
      type: redis
      serviceName: ${REDIS_SERVICE}
      servicePort: 6379
      timeout: 2000
      cacheTTL: ${CACHE_TTL_SECONDS}
      cacheKeyPrefix: "dataagent:ai-cache:"
      database: 0
    cacheKeyStrategy: lastQuestion
    cacheKeyFrom: 'messages.@reverse.#(role=="user").content'
    cacheValueFrom: "choices.0.message.content"
    cacheStreamValueFrom: "choices.0.delta.content"
    enableSemanticCache: false
  defaultConfigDisable: true
  failStrategy: FAIL_OPEN
  matchRules:
  - config:
      cache:
        type: redis
        serviceName: ${REDIS_SERVICE}
        servicePort: 6379
        timeout: 2000
        cacheTTL: ${CACHE_TTL_SECONDS}
        cacheKeyPrefix: "dataagent:ai-cache:"
        database: 0
      cacheKeyStrategy: lastQuestion
      cacheKeyFrom: 'messages.@reverse.#(role=="user").content'
      cacheValueFrom: "choices.0.message.content"
      cacheStreamValueFrom: "choices.0.delta.content"
      enableSemanticCache: false
    configDisable: true
    ingress:
    - ${ROUTE_NAME}
  phase: AUTHN
  priority: 10
  url: http://localhost:8002/plugins/ai-cache/1.0.0/plugin.wasm
status: {}
EOF

echo "Applied DataAgent Higress AI governance config to ${DATA_DIR}."

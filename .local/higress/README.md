# Local Higress AI Gateway

This folder contains local-only helper files for running Higress AI Gateway in WSL/Docker and routing DataAgent model calls through it.

## Endpoints

- Gateway: `http://127.0.0.1:8080`
- Console: `http://127.0.0.1:8001`
- Redis container: `higress-ai-redis`
- Docker network: `higress-ai`
- Optional Redis GUI endpoint: `127.0.0.1:6380`

## Start

```bash
DASHSCOPE_API_KEY=sk-xxx .local/higress/start-higress-ai-gateway.sh
```

The script creates/starts Redis and connects Higress to the same Docker network. Provider credentials and generated Higress runtime files live under `.local/higress/data/`, which is git-ignored because it may contain API keys.

Expose the existing Higress Redis to local desktop tools without recreating it:

```bash
.local/higress/expose-higress-redis.sh
```

This starts a small TCP proxy on `127.0.0.1:6380`, because `127.0.0.1:6379` may already be used by other local Redis containers.

Expose Redis directly when creating a fresh Redis container:

```bash
HIGRESS_REDIS_HOST_PORT=6380 DASHSCOPE_API_KEY=sk-xxx .local/higress/start-higress-ai-gateway.sh
```

This binds Redis to `127.0.0.1:6380` by default. If the `higress-ai-redis` container already exists without a published port, use `expose-higress-redis.sh` or recreate the Redis container because Docker cannot add `-p` to an existing container.

Re-apply only the DataAgent governance plugin config:

```bash
.local/higress/apply-dataagent-ai-governance.sh
docker restart higress-ai-gateway
```

## DataAgent Model Config

The active DataAgent model configs point to Higress:

- Chat: `qwen3.6-plus`, base URL `http://127.0.0.1:8080`, API key `higress-local-key`
- Embedding: `text-embedding-v4`, base URL `http://127.0.0.1:8080`, API key `higress-local-key`

`higress-local-key` is a local gateway credential, not the upstream DashScope key. The real provider key is kept in Higress runtime config.

## Consumers

- `dataagent-app`: `Bearer higress-local-key`
- `dataagent-admin`: `Bearer higress-admin-key`

## AI Governance

The local gateway enables these plugins on `ai-route-aliyun.internal`:

- `key-auth`: authenticates DataAgent and admin calls.
- `ai-statistics`: writes token/model/cache attributes into Higress access logs.
- `ai-quota`: stores remaining quota in Redis with prefix `dataagent:ai-quota:`.
- `ai-token-ratelimit`: stores hourly token counters in Redis with prefix `higress-token-ratelimit`.
- `ai-cache`: disabled for DataAgent AgentScope chat routes. ReAct/tool-calling requests are stateful, so response caching can replay stale intermediate model output.

Initialize or reset app quota:

```bash
curl -X POST 'http://127.0.0.1:8080/v1/chat/completions/quota/refresh' \
  -H 'Authorization: Bearer higress-admin-key' \
  -H 'x-higress-llm-model: qwen3.6-plus' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'consumer=dataagent-app&quota=1000000'
```

Query app quota:

```bash
curl 'http://127.0.0.1:8080/v1/chat/completions/quota?consumer=dataagent-app' \
  -H 'Authorization: Bearer higress-admin-key' \
  -H 'x-higress-llm-model: qwen3.6-plus'
```

Inspect Redis state:

```bash
docker exec higress-ai-redis redis-cli get dataagent:ai-quota:dataagent-app
docker exec higress-ai-redis redis-cli --scan --pattern 'higress-token-ratelimit*'
docker exec higress-ai-redis redis-cli --scan --pattern 'dataagent:ai-cache:*'
```

With a Redis GUI connected to `127.0.0.1:6380`, edit the remaining quota key directly:

```text
dataagent:ai-quota:dataagent-app
```

Inspect Higress AI statistics and plugin details:

```bash
docker exec higress-ai-gateway tail -f /var/log/higress/gateway.log
```

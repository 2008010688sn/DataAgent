# PostgreSQL 初始化脚本

这些脚本是本地 PostgreSQL 版本的初始化 SQL：

- `schema.sql` / `data.sql`: DataAgent 后端管理库 `saa_data_agent`
- `product_schema.sql` / `product_data.sql`: 本地示例业务库 `product_db`
- `china_population_db.sql`: 本地人口数据示例库 `china_population_db`

后端运行时使用同内容的 classpath 脚本：

- `data-agent-management/src/main/resources/sql/pg/schema.sql`
- `data-agent-management/src/main/resources/sql/pg/data.sql`
- `data-agent-management/src/main/resources/sql/pg/product_schema.sql`
- `data-agent-management/src/main/resources/sql/pg/product_data.sql`
- `data-agent-management/src/main/resources/sql/pg/china_population_db.sql`

布尔语义字段已统一为 PostgreSQL `boolean`，包括 `api_key_enabled`、`is_recall`、`is_deleted`、`is_resource_cleaned`、`is_active`、`is_pinned`、`proxy_enabled`、`semantic_model.status`。

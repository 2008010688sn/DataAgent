# Data Agent 接入 xx-cloud 数据权限方案

## 1. 结论

Data Agent 后端可以接入 xx-cloud 的数据权限体系，但不能简单依赖现有 MyBatis-Plus 拦截器自动处理模型生成 SQL。

原因是当前 Data Agent 的查询 SQL 最终通过原生 JDBC 执行：

```text
DatasourceExplorerService.search
  -> executeSql
  -> Accessor.executeSqlAndReturnObject
  -> AbstractAccessor.accessDb
  -> SqlExecutor.executeSqlAndReturnObject
  -> Statement.executeQuery(sql)
```

这条链路不经过 MyBatis Mapper、MappedStatement、MybatisPlusInterceptor，因此 xx-cloud 现有 `DataPermissionInterceptor` 不会自动拦截。

推荐方案是：

```text
继续复用 xx-cloud 的登录态、DataPermission、DataScopeType、DataRefType、DataPermissionRule、DataPermissionHelper.buildConditions(...)
但在 Data Agent 的 SQL 执行前新增一个专用 SQL 权限改写器
```

也就是说：

```text
同一套权限来源
同一套数据权限条件生成逻辑
不同的 SQL 改写入口
```

## 2. xx-cloud 当前 SQL 改写机制

xx-cloud 的数据权限 SQL 改写是在 `db-spring-boot-starter` 公共组件里完成的。

核心注册位置：

```text
D:/workspace/xx-cloud/xx-cloud-framework/db-spring-boot-starter/src/main/java/com/xx/framework/db/configuration/BaseMybatisConfiguration.java
```

关键代码：

```java
if (properties.getDataPermission().isEnabled()) {
    interceptor.addInnerInterceptor(
        new DataPermissionInterceptor(new DataScopePermissionHandler(context))
    );
}
```

完整链路：

```text
MyBatis Mapper SQL
  -> MybatisPlusInterceptor
  -> DataPermissionInterceptor
  -> DataScopePermissionHandler.getSqlSegment(...)
  -> DataPermissionHelper.buildConditions(...)
  -> MyBatis-Plus 将条件拼回 SQL
```

其中：

`DataPermissionInterceptor`
是 MyBatis-Plus 自带的 SQL AST 改写插件，负责解析和改写 SQL。

`DataScopePermissionHandler`
是 xx-cloud 的数据权限处理器，负责告诉 MyBatis-Plus 每张表应该追加什么权限条件。

`DataPermissionHelper`
是 xx-cloud 的权限条件生成工具，负责根据当前登录人的 `DataPermission` 生成 JSqlParser 条件表达式。

## 3. DataScopePermissionHandler 和 DataPermissionHelper 能否直接使用

### 3.1 DataScopePermissionHandler

不能直接原样用于 Data Agent 的 JDBC SQL。

它实现的是：

```java
MultiDataPermissionHandler
```

这个接口只会被 MyBatis-Plus 的 `DataPermissionInterceptor` 调用。Data Agent 目前不是 MyBatis 查询链路，所以它不会自动触发。

它可以作为参考，但不建议把它直接搬过来硬调。因为它依赖 MyBatis 的 `mappedStatementId` 和 Mapper 方法上的 `@DataScope` 解析逻辑，而模型生成的动态 SQL 没有固定 Mapper 方法。

### 3.2 DataPermissionHelper

可以直接复用，而且应该复用。

核心方法：

```java
DataPermissionHelper.buildConditions(
    AuthenticationContext context,
    Table table,
    List<DataPermissionRule.Column> columns
)
```

它会复用 xx-cloud 当前登录人的数据权限：

```java
AuthenticationContext.dataPermission()
AuthenticationContext.userId()
```

并处理：

```text
DataScopeType.ALL
DataScopeType.SELF
DataScopeType.CUSTOMIZE
DataScopeType.THIS_LEVEL
DataScopeType.THIS_LEVEL_CHILDREN
DataRefType.COMPANY
DataRefType.USER
DataRefType.ORG
DataRefType.SITE
DataRefType.TWO_PROJECT
...
```

因此 Data Agent 只要调用这个方法生成条件，就可以和 xx-cloud 保持同一套权限值、同一套条件生成逻辑。

## 4. Data Agent 需要改哪些地方

### 4.1 接入 xx-cloud 公共依赖

如果 Data Agent 后端被集成进 xx-cloud Maven 工程，建议优先依赖：

```xml
<dependency>
    <groupId>com.xx.framework</groupId>
    <artifactId>common-spring-boot-starter</artifactId>
</dependency>
```

如果只希望引入数据权限和安全上下文，也可以更细粒度依赖：

```xml
<dependency>
    <groupId>com.xx.framework</groupId>
    <artifactId>db-spring-boot-starter</artifactId>
</dependency>

<dependency>
    <groupId>com.xx.framework</groupId>
    <artifactId>security-spring-boot-starter</artifactId>
</dependency>
```

需要保证数据权限开关开启：

```yaml
extend:
  mybatis-plus:
    data-permission:
      enabled: true
```

注意：这个开关只会影响 MyBatis-Plus 查询。Data Agent JDBC SQL 仍然需要专用改写器。

### 4.2 Controller 入口获取当前登录人

当前 Data Agent 的入口：

```text
data-agent-management/src/main/java/com/alibaba/cloud/ai/dataagent/controller/DataAgentController.java
```

目前 `AgentRequest` 只包含：

```text
agentId
threadId
runtimeRequestId
query
...
```

需要从 xx-cloud 的 `AuthenticationContext` 或 SaToken 登录态中获取当前用户：

```java
AuthenticationContext authenticationContext
```

入口处不要信任前端传来的 `userId`、`role`、`tenantId`、`dataPermission`。这些数据必须从 xx-cloud 已认证的服务端上下文中读取。

建议在 Controller 中注入：

```java
private final AuthenticationContext authenticationContext;
```

然后构造 Data Agent 运行时权限快照。

### 4.3 用户上下文传递方案

Data Agent 不能只依赖请求线程里的 `AuthenticationContext` 或 SaToken。

原因是 Agent 运行通常会经历：

```text
HTTP 请求线程
  -> Agent 异步执行线程
  -> AgentScope 工具调用上下文
  -> DatasourceExplorerService
  -> JDBC SQL 执行
```

跨线程后，普通 ThreadLocal 或 Web 请求上下文可能不可用。xx-cloud 的 `AuthenticationContext` 在 Web 请求中很好用，但 Data Agent 执行 SQL 时可能已经不在原请求线程。

因此推荐方案是：

```text
入口读取 xx-cloud 用户上下文
  -> 生成 AgentSecurityContext 权限快照
  -> 放入 AgentRequest
  -> 随 Agent 运行上下文和 ToolContext 传递
  -> SQL 改写时使用该快照
```

建议新增 Data Agent 运行时权限对象：

```java
public class AgentSecurityContext {

    private String userId;

    private String tenantId;

    private String tenantCode;

    private String orgId;

    private List<String> roles;

    private List<String> funcPermissions;

    private DataPermission dataPermission;

}
```

Controller 入口示例：

```java
AgentSecurityContext securityContext = new AgentSecurityContext();
securityContext.setUserId(authenticationContext.userId());
securityContext.setTenantId(authenticationContext.tenantId());
securityContext.setTenantCode(authenticationContext.tenantCode());
securityContext.setRoles(authenticationContext.rolePermissionList());
securityContext.setFuncPermissions(authenticationContext.funcPermissionList());
securityContext.setDataPermission(authenticationContext.dataPermission());
```

再写入 `AgentRequest`：

```java
AgentRequest request = AgentRequest.builder()
    .agentId(agentId)
    .threadId(threadId)
    .runtimeRequestId(runtimeRequestId)
    .query(query)
    .securityContext(securityContext)
    .build();
```

`AgentRequest` 需要新增字段：

```java
private AgentSecurityContext securityContext;
```

如果工具调用会通过 `AgentRuntimeRequestMetadata`、`ToolContextRequestResolver`、`SpringToolCallbackAgentAdapter` 传递上下文，也要同步补充权限快照，避免工具执行时拿不到当前用户。

建议同步改造以下链路：

```text
DataAgentController.streamSearch
  -> AgentRequest.securityContext
  -> AiAgentRuntimeServiceImpl / AgentRuntimeExtensionFactory
  -> SpringToolCallbackAgentAdapter
  -> ToolContextRequestResolver
  -> DatasourceExplorerService.search / previewRows / sql_guard.DATA_PROFILE
  -> DataAgentSqlPermissionRewriteService
```

同时接口层需要补充访问校验：

```text
当前用户是否有 dataagent:agent:run 权限
当前用户是否能访问该 agent
当前用户是否能访问该 thread/session
当前用户是否能访问该 datasource
```

最终 SQL 改写时优先使用 `AgentRequest.securityContext` 中的权限快照，而不是重新从当前线程读取登录态。

需要保证以下信息在 Agent 异步执行链路中可用：

```text
userId
tenantId
tenantCode
roles
funcPermissions
dataPermission
```

最重要的原则：

```text
用户上下文在入口取
权限快照随 AgentRequest 走
最终 SQL 在服务端强制改写
```

### 4.4 增加 Data Agent 表权限映射配置

xx-cloud 的 Mapper 查询通过 `@DataScope` 知道哪张表用哪个字段做数据权限。

例如：

```java
@DataScope(columns = @DataColumn(
    dataType = DataRefType.COMPANY,
    javaClass = String.class,
    name = "company_id",
    alias = "bc"
))
```

但 Data Agent 的 SQL 是模型动态生成的，没有固定 Mapper 方法，所以需要新增一份表权限映射。

建议新增配置表：

```sql
CREATE TABLE data_agent_permission_rule (
    id BIGINT PRIMARY KEY,
    datasource_id INT NOT NULL,
    table_name VARCHAR(128) NOT NULL,
    column_name VARCHAR(128) NOT NULL,
    data_ref_type VARCHAR(64) NOT NULL,
    java_class VARCHAR(128) DEFAULT 'java.lang.String',
    scope_type VARCHAR(64),
    enabled BOOLEAN DEFAULT TRUE,
    create_time TIMESTAMP,
    update_time TIMESTAMP
);
```

示例配置：

```text
project_bill_detail.company_id -> DataRefType.COMPANY
project_bill_detail.create_by  -> DataRefType.USER
project_bill_detail.site_id    -> DataRefType.SITE
project_bill_detail.tenant_id  -> tenantId
```

这份配置的作用等价于动态 SQL 版本的 `@DataScope`。

### 4.5 新增 SQL 权限改写服务

建议新增接口：

```java
public interface DataAgentSqlPermissionRewriteService {

    String rewrite(String sql, DataAgentSqlPermissionContext context);

}
```

上下文建议包含：

```java
public record DataAgentSqlPermissionContext(
    Integer datasourceId,
    String dialect,
    String tenantId,
    AgentSecurityContext securityContext,
    AuthenticationContext authenticationContext,
    Map<String, List<DataPermissionRule.Column>> ruleColumnsByTable
) {
}
```

核心处理逻辑：

```text
1. 用 JSqlParser 解析模型生成 SQL
2. 确认只允许 SELECT / WITH
3. 遍历 PlainSelect / Join / SubSelect / CTE / UNION
4. 对每个真实业务表查找 data_agent_permission_rule
5. 构造 DataPermissionRule.Column
6. 调用 DataPermissionHelper.buildConditions(...)
7. 将生成的 Expression 用 AND 注入 WHERE
8. 租户条件也在这里统一注入
9. 返回改写后的 SQL
```

伪代码：

```java
public String rewrite(String sql, DataAgentSqlPermissionContext context) {
    Statement statement = CCJSqlParserUtil.parse(sql);
    if (!(statement instanceof Select select)) {
        throw new IllegalArgumentException("Only SELECT is allowed");
    }
    rewriteSelect(select, context);
    return select.toString();
}

private void rewritePlainSelect(PlainSelect plainSelect, DataAgentSqlPermissionContext context) {
    for (Table table : extractTables(plainSelect)) {
        List<DataPermissionRule.Column> columns = context.ruleColumnsByTable()
            .get(normalize(table.getName()));

        if (columns == null || columns.isEmpty()) {
            continue;
        }

        List<Expression> expressions = DataPermissionHelper.buildConditions(
            context.authenticationContext(),
            table,
            columns
        );

        Expression permissionExpression = expressions.stream()
            .reduce(AndExpression::new)
            .orElse(null);

        if (permissionExpression != null) {
            plainSelect.setWhere(
                plainSelect.getWhere() == null
                    ? permissionExpression
                    : new AndExpression(plainSelect.getWhere(), permissionExpression)
            );
        }
    }
}
```

### 4.6 修改 Data Agent SQL 执行链路

当前执行位置：

```text
data-agent-management/src/main/java/com/alibaba/cloud/ai/dataagent/agentscope/tool/datasource/DatasourceExplorerService.java
```

当前逻辑：

```java
SqlGuardedQuery guardedQuery = guardReadonlySql(context, rawSql, limit);
ResultSetBO resultSet = filterResultSet(executeSql(context, guardedQuery.sql()), guardedQuery);
```

建议改为：

```java
SqlGuardedQuery guardedQuery = guardReadonlySql(context, rawSql, limit);

String permissionSql = sqlPermissionRewriteService.rewrite(
    guardedQuery.sql(),
    buildPermissionContext(context, graphRequest.getSecurityContext())
);

ResultSetBO resultSet = filterResultSet(executeSql(context, permissionSql), guardedQuery);
```

并将返回结果里的 SQL 从原 SQL 改为权限 SQL：

```java
.sql(permissionSql)
```

这样用户、审计、trace 都能看到最终执行 SQL。

### 4.7 AbstractAccessor 是否也要改

可以加兜底，但不建议只放在 `AbstractAccessor`。

原因：

```text
DatasourceExplorerService 层知道 agentId、datasource、可见表、可见字段、graphRequest
AbstractAccessor 层只知道 dbConfig、Connection、SQL
```

最优方案：

```text
主改写点：DatasourceExplorerService.search()
兜底保护点：AbstractAccessor.executeSqlAndReturnObject()
```

兜底点可以用于防止未来其他地方绕过 `DatasourceExplorerService` 直接执行 SQL。

### 4.8 Data Agent 后端融合到 xx-cloud 的落地方案

推荐在 `xx-cloud` 中新增独立服务模块 `xx-cloud-data-agent` 承载 Data Agent 后端，不使用现有 `xx-cloud-ai` 模块。

推荐目标结构：

```text
xx-cloud-data-agent
  pom.xml
  agent-skills
  src/main/java/com/xx/cloud/dataagent
    DataAgentApplication
    permission
    agentscope / controller / service / mapper / connector / tool / ...
  src/main/resources
    sql
    prompts
    excel
    db/data_agent.sql
    application.yml
```

落地时应按当前 `D:/workspace/agentscope/data-agent-management` 工作区代码整体搬入，包括已改动但尚未提交的源码、测试和资源文件。同时需要搬入当前 `D:/workspace/agentscope/agent-skills`，因为 Data Agent 默认通过 `spring.ai.alibaba.data-agent.skills.local-path=./agent-skills` 读取本地技能。`xx-cloud-data-agent` 不再依赖外部的 `spring-ai-alibaba-data-agent-management` 包作为壳模块，而是在 xx-cloud 内直接编译这套 Data Agent 源码。

为了让 `xx-cloud-data-agent` 的工程结构和 xx-cloud 长期维护习惯一致，建议搬入后统一包名：

```text
com.alibaba.cloud.ai.dataagent -> com.xx.cloud.dataagent
```

这属于机械包名映射，不改变 Data Agent 业务代码逻辑。需要注意的是，以后如果继续从 `agentscope/data-agent-management` 同步源码，需要先做同样的包名映射，不能再直接原样覆盖。

融合原则：

```text
静态管理能力接入 xx-cloud：agent、thread、datasource、schema、权限映射等 CRUD 使用 Data Agent 独立管理库和 MyBatis-Plus
动态 SQL 执行链路保留 Data Agent JDBC：模型生成 SQL 仍由 DatasourceExplorerService 统一执行
权限和租户由服务端强制改写：不依赖模型生成带权限 SQL
用户上下文、登录态、租户、审计统一使用 xx-cloud 基础能力
```

建议迁移范围：

```text
1. 在 xx-cloud 下新增 xx-cloud-data-agent 服务模块
2. 将 agentscope/data-agent-management 当前源码整体搬入 xx-cloud-data-agent
3. 将 agentscope/agent-skills 当前目录搬入 xx-cloud-data-agent/agent-skills
4. 将搬入源码包名统一映射为 com.xx.cloud.dataagent
5. xx-cloud-data-agent 作为独立 Spring Boot 应用，直接编译搬入后的 Data Agent 源码
6. 启动类扫描 com.xx.cloud.dataagent
7. MapperScan 覆盖 com.xx.cloud.dataagent.**.repository 与 com.xx.cloud.dataagent.mapper
8. 权限桥接代码放在 com.xx.cloud.dataagent.permission
9. 将 data_agent_permission_rule 初始化 SQL 放入 xx-cloud-data-agent/src/main/resources/db/data_agent.sql
10. 不改造、不复用现有 xx-cloud-ai 模块，避免 AI 模块承担 Data Agent 运行时依赖
```

注意：搬入源码中的原始 `DataAgentApplication` 不能继续作为第二个 `@SpringBootApplication` 参与扫描，也不建议和 xx-cloud 启动类同时保留。统一启动入口应放在 `com.xx.cloud.dataagent.DataAgentApplication`，并在该启动类上保留 `@EnableScheduling`、xx-cloud 登录态、Nacos、Feign、MapperScan 等工程能力。

xx-cloud-data-agent 按 xx-cloud 现有 Spring MVC / Servlet 服务方式接入。Data Agent 原后端如果带有 WebFlux 风格的 controller，需要做兼容处理。尤其是 SSE 接口不要在方法参数中使用 `org.springframework.http.server.reactive.ServerHttpResponse`，否则在 MVC 环境里可能无法解析参数。

推荐写法是：

```java
public ResponseEntity<Flux<ServerSentEvent<AgentResponse>>> streamSearch(...) {
    Flux<ServerSentEvent<AgentResponse>> stream = ...
    return ResponseEntity.ok()
        .contentType(MediaType.TEXT_EVENT_STREAM)
        .header("Cache-Control", "no-cache")
        .header("Connection", "keep-alive")
        .body(stream);
}
```

这样同一套 Data Agent controller 可以兼容 WebFlux 和 xx-cloud 的 MVC 栈，避免为了接入 Data Agent 把新服务或其他 xx-cloud 服务切成 reactive 应用。

依赖融合建议：

```text
优先复用 xx-cloud 已有依赖：
common-spring-boot-starter
db-spring-boot-starter
security-spring-boot-starter

Data Agent 额外依赖只补必要项：
AgentScope / Spring AI 相关运行时
spring-ai-alibaba-dashscope
JSqlParser
目标数据库 JDBC Driver
SQL 方言或元数据解析相关依赖
```

不建议把 Data Agent 的动态 SQL 查询整体改成 MyBatis-Plus Mapper。

原因：

```text
模型生成 SQL 是运行时动态文本，不天然对应固定 Mapper 方法
MyBatis-Plus 更适合 Data Agent 固定 CRUD、配置表、管理表、权限映射表
为了复用 MyBatis-Plus 数据权限拦截器而重写动态 SQL 执行链路，改动大且收益不高
动态 SQL 最终仍需要 JSqlParser 级别的安全校验、表字段校验、权限注入和审计
```

合理边界是：

```text
Data Agent 管理数据：使用 Data Agent 独立管理库 + MyBatis-Plus
Data Agent 执行模型生成 SQL：保留 JDBC，但在执行前强制经过 DataAgentSqlPermissionRewriteService
```

这样既能接入 xx-cloud 的工程体系，又不会为了套拦截器把 Data Agent 的核心执行模型改得过重。

### 4.9 xx-cloud 用户上下文融合到 Data Agent 的细化方案

用户上下文融合需要分成两个阶段处理。

第一阶段是在 xx-cloud 入口处读取当前用户：

```text
网关 / SaToken / 认证过滤器
  -> xx-cloud AuthenticationContext
  -> DataAgentController
  -> AgentSecurityContext 权限快照
```

入口层只信任服务端上下文，不信任前端请求体里的用户信息。

建议快照字段：

```text
userId
tenantId
tenantCode
orgId
roles
funcPermissions
dataPermission
```

第二阶段是把权限快照传到 Agent 工具执行链路：

```text
AgentRequest.securityContext
  -> AgentRuntimeRequestMetadata
  -> SpringToolCallbackAgentAdapter
  -> ToolContextRequestResolver
  -> DatasourceExplorerService.search
  -> DataAgentSqlPermissionRewriteService
```

这一步不能只依赖 ThreadLocal。

原因是 Data Agent 运行过程中可能跨异步线程、工具调用线程或 AgentScope 内部执行上下文。如果最终 SQL 执行时再从当前线程读取 `AuthenticationContext`，可能会读不到用户，或者读到错误的上下文。

因此最终 SQL 改写时推荐优先使用 `AgentSecurityContext` 快照，再在需要调用 `DataPermissionHelper.buildConditions(...)` 时适配成 xx-cloud 所需的 `AuthenticationContext` 语义。

适配方式有两种：

```text
方案 A：Agent 执行链路中保留原始 AuthenticationContext 引用
方案 B：基于 AgentSecurityContext 构造只读 AuthenticationContext 适配器
```

推荐优先选方案 B。

原因：

```text
AgentSecurityContext 是可序列化快照，更适合异步和工具上下文传递
不会依赖 Web 请求线程生命周期
可以避免长时间持有请求态对象
审计时也能明确看到当次执行使用的权限快照
```

需要注意的是，适配器不能重新计算权限，也不能根据 role 自己拼装权限；它只能把入口处已经从 xx-cloud 获取到的 `dataPermission`、`userId`、`tenantId` 等值交给 `DataPermissionHelper` 使用。

建议采用低耦合桥接方式落地：Data Agent 后端只定义扩展点，不直接依赖 xx-cloud；`xx-cloud-data-agent` 负责实现扩展点，把 xx-cloud 登录上下文和数据权限上下文注入 Data Agent。

Data Agent 侧建议新增一个安全上下文提供接口：

```java
public interface AgentRequestSecurityContextProvider {

    Object currentSecurityContext();

}
```

这个接口只返回 `Object`，不要在 Data Agent 模块里直接引用 `AuthenticationContext`、`AgentSecurityContext` 或 xx-cloud 的权限类。这样 Data Agent 仍然可以独立编译，xx-cloud 集成时再提供具体实现。

Data Agent 侧需要同步改造以下位置：

```text
AgentRequest.java
  -> 新增 Object securityContext

DataAgentController.java
  -> 注入 ObjectProvider<AgentRequestSecurityContextProvider>
  -> 构造 AgentRequest 时写入 currentSecurityContext()

AgentRuntimeRequestMetadata.java
  -> 新增 Object securityContext
  -> metadata 兜底恢复 AgentRequest 时不能丢失权限快照

AgentRuntimeExtensionFactory.java
  -> ToolExecutionContext 同时注册 graphRequest 和 agentRequest
  -> 注册 AgentRuntimeRequestMetadata，保证 AgentScope 工具上下文可恢复请求

ToolContextRequestResolver.java
  -> 优先从 graphRequest / agentRequest 取完整 AgentRequest
  -> 兜底从 AgentRuntimeRequestMetadata 恢复时带上 securityContext

DatasourceExplorerService.java
  -> 在 guardReadonlySql 后调用 SqlPermissionRewriteCallback
  -> 把 graphRequest 传给回调，供 xx-cloud 侧读取 securityContext
```

其中 `agentRequest` 也建议注册，原因是 `SpringToolCallbackAgentAdapter` 会优先从 ToolExecutionContext 读取 `agentRequest`。当前已有 `graphRequest` 也可以保留，作为兼容旧链路的名字。

xx-cloud-data-agent 侧需要实现两个桥接点，建议放在 `com.xx.cloud.dataagent.permission`。

第一个是当前用户快照提供者：

```java
@Component
public class XxCloudAgentRequestSecurityContextProvider
        implements AgentRequestSecurityContextProvider {

    private final DataAgentSqlPermissionFacade permissionFacade;

    @Override
    public Object currentSecurityContext() {
        return permissionFacade.currentSecurityContext();
    }

}
```

`currentSecurityContext()` 内部应从 xx-cloud 服务端登录态读取 `AuthenticationContext`，生成可序列化的 `AgentSecurityContext` 快照。快照建议包含：

```text
clientId
tenantId
tenantCode
tenantName
userId
userType
nickName
mobile
anonymous
funcPermissions
rolePermissions
dataPermission
```

第二个是 SQL 权限改写回调：

```java
@Component
public class XxCloudSqlPermissionRewriteCallback
        implements SqlPermissionRewriteCallback {

    private final DataAgentSqlPermissionFacade permissionFacade;

    @Override
    public String rewrite(Integer datasourceId, String sql, AgentRequest graphRequest) {
        Object securityContext = graphRequest == null ? null : graphRequest.getSecurityContext();
        if (securityContext instanceof AgentSecurityContext snapshot) {
            return permissionFacade.rewrite(Long.valueOf(datasourceId), sql, snapshot);
        }
        return permissionFacade.rewrite(Long.valueOf(datasourceId), sql);
    }

}
```

集成环境里不建议在拿不到用户上下文时直接放行原 SQL。更稳妥的策略是：

```text
有 AgentSecurityContext 快照：使用快照改写 SQL
没有 AgentRequest 的同步服务端直调：可兜底使用当前 AuthenticationContext
已有 AgentRequest 但缺失 AgentSecurityContext：拒绝执行，不能回退到当前线程
没有快照也没有当前 AuthenticationContext：拒绝执行，不能放行原 SQL
```

完整融合链路应变成：

```text
用户请求 Data Agent
  -> xx-cloud 认证过滤器 / SaToken 建立登录态
  -> AuthenticationContext 可用
  -> AgentRequestSecurityContextProvider 生成 AgentSecurityContext 快照
  -> DataAgentController 构造 AgentRequest.securityContext
  -> AgentRuntimeExtensionFactory 注册 graphRequest / agentRequest / runtime metadata
  -> AgentScope 工具调用进入 SpringToolCallbackAgentAdapter
  -> ToolContextRequestResolver 还原 AgentRequest
  -> DatasourceExplorerService 生成候选 SQL 并完成只读校验
  -> SqlPermissionRewriteCallback 调用 xx-cloud 权限门面
  -> AgentSecurityAuthenticationContext 将快照适配成 AuthenticationContext
  -> DataPermissionHelper.buildConditions(...) 生成数据权限条件
  -> JSqlParser 注入租户条件和数据权限条件
  -> JDBC 执行改写后的最终 SQL
```

为了保持和 xx-cloud 完全同一套权限体系，xx-cloud 侧的 `AgentSecurityContext` 不能只保存 role。role 只是角色标识，真正决定数据范围的是 `AuthenticationContext.dataPermission()`。因此快照中必须保存 `DataPermission`，并通过只读 `AuthenticationContext` 适配器交给 `DataPermissionHelper` 使用。

这部分融合的主要影响如下：

```text
优点：
1. Data Agent 不直接依赖 xx-cloud，后续仍可独立维护
2. xx-cloud 继续作为唯一认证、租户、数据权限来源
3. 跨异步线程时不会丢失用户权限
4. SQL 权限条件仍由 DataPermissionHelper 生成，逻辑和 xx-cloud Mapper 保持一致

代价：
1. AgentRequest、RuntimeMetadata、ToolContextResolver 都要传递 securityContext
2. 快照是入口时刻的权限状态，长时间运行任务不会自动感知中途权限变更
3. securityContext 需要可序列化，不能放入请求对象、连接对象等线程态资源
4. xx-cloud-data-agent 需要维护桥接实现和 Data Agent 扩展接口版本兼容
5. 缺失上下文时必须 fail closed，否则会绕过数据权限
```

这部分的验收重点是看最终 SQL 改写时使用的上下文来源：

```text
1. DataAgentController 构造的 AgentRequest 中能看到 securityContext
2. AgentScope 工具执行线程中能通过 ToolContextRequestResolver 取回同一个 securityContext
3. SqlPermissionRewriteCallback 能拿到 datasourceId、原 SQL、AgentRequest
4. DataAgentSqlPermissionFacade 使用 AgentSecurityAuthenticationContext 调用 DataPermissionHelper
5. 不同用户的数据权限快照不同，改写后的 SQL 条件也不同
6. 删除或伪造前端 userId / role 参数不影响最终权限，因为最终只信任服务端快照
```

### 4.10 融合后的验收口径

融合完成后，验收不应该只看接口是否能返回数据，而要看最终 SQL 是否严格经过同一套权限体系。

建议验收口径：

```text
1. Data Agent 接口由 xx-cloud 登录态保护
2. Data Agent Controller 能拿到 AuthenticationContext
3. AgentRequest / ToolContext 中能看到 AgentSecurityContext
4. 最终执行 SQL 前一定经过 DataAgentSqlPermissionRewriteService
5. 权限条件由 DataPermissionHelper.buildConditions(...) 生成
6. 租户条件由 Data Agent SQL 改写器补齐
7. 同用户、同表、同权限配置下，Data Agent 查询结果范围和 xx-cloud Mapper 查询结果一致
8. 无权限、缺少权限映射、SQL 无法安全改写时默认拒绝执行
9. trace 中记录原始 SQL、权限 SQL、用户、租户、命中的权限规则
```

融合方案的可行性判断：

```text
可行性：高
推荐方式：在 xx-cloud 中新增独立服务 xx-cloud-data-agent，管理面使用 MyBatis-Plus，动态 SQL 使用 JDBC + 权限改写器
主要改动：包名和依赖、用户上下文传递、SQL 权限改写、权限映射配置、审计和测试
主要影响：模块依赖变重、SQL 改写复杂度上升、权限映射需要维护、复杂 SQL 需要 fail closed
```

## 5. 如何保证和 xx-cloud 是同一套权限体系

要保证一致，需要做到以下几点。

### 5.1 复用同一个登录上下文

必须使用 xx-cloud 的：

```java
AuthenticationContext
```

不要自己从 token 中解析 role 后拼 SQL。

role 只是权限来源，最终权限范围应该来自：

```java
AuthenticationContext.dataPermission()
```

### 5.2 复用同一个权限模型

必须使用 xx-cloud 的：

```java
DataPermission
DataScopeType
DataRefType
```

不要在 Data Agent 自己定义一套类似枚举，否则后续 xx-cloud 权限维度变化时会不一致。

### 5.3 复用同一个条件生成函数

必须调用：

```java
DataPermissionHelper.buildConditions(...)
```

这样 `ALL`、`SELF`、空权限、用户维度兜底等逻辑才能和 xx-cloud 保持一致。

### 5.4 表字段映射必须准确

xx-cloud 的 `@DataScope` 本质是在告诉系统：

```text
当前 Mapper SQL 中哪张表、哪个别名、哪个字段对应哪个 DataRefType
```

Data Agent 也必须有等价配置。

例如业务表中公司字段叫：

```text
company_id
```

就必须配置：

```text
table_name = project_bill_detail
column_name = company_id
data_ref_type = COMPANY
```

如果字段配置错误，即使复用了 `DataPermissionHelper`，最终 SQL 也会和业务 Mapper 不一致。

### 5.5 租户权限不能遗漏

xx-cloud 除了数据权限插件，还有租户插件：

```java
TenantLineInnerInterceptor
```

它会给指定表追加：

```sql
tenant_id = 当前租户
```

Data Agent 的 JDBC SQL 不会自动走这个插件，因此需要在 Data Agent SQL 权限改写器中一并处理租户条件。

如果只复用 `DataPermissionHelper`，只能保证数据范围一致，不能保证租户隔离一致。

## 6. 推荐执行流程

最终执行流程建议为：

```text
用户提问
  -> xx-cloud 登录态校验
  -> 构造 AgentRequest，携带权限快照
  -> LLM 生成候选 SQL
  -> sql_guard.check 做意图和只读校验
  -> DatasourceExplorerService.guardReadonlySql 做 SELECT、表、字段校验
  -> DataAgentSqlPermissionRewriteService 注入租户和数据权限
  -> 执行最终 SQL
  -> trace 记录原始 SQL、权限 SQL、使用的权限规则
  -> 返回结果
```

## 7. 风险和处理原则

### 7.1 SQL 结构复杂

JOIN、子查询、CTE、UNION、别名都要处理。

原则：

```text
能安全改写就执行
不能确定安全改写就拒绝执行
不要放行
```

当前推荐的第一版落地策略是：

```text
FROM 子查询、CTE、UNION：由 JSqlParser 改写器递归处理
WHERE / HAVING / JOIN ON / SELECT item 中的嵌套 SELECT：先拒绝执行
```

原因是表达式里的子查询如果没有被递归改写，可能导致内层表绕过数据权限。后续可以在测试覆盖充分后再把这类 SQL 从“拒绝”扩展成“递归改写”。

### 7.2 部分表没有权限字段

如果目标表没有 `company_id`、`create_by`、`tenant_id` 等字段，无法直接套 xx-cloud 数据权限。

可选处理：

```text
1. 建授权视图
2. 通过关联表 join 到有权限字段的主表
3. 建数据权限映射表
4. 对该表禁止 Data Agent 直接查询
```

### 7.3 异步线程丢失用户上下文

Data Agent 有异步运行链路。如果只依赖请求线程里的 SaToken 或普通 ThreadLocal，可能拿不到用户。

建议：

```text
Controller 入口生成权限快照
AgentRequest / ToolContext / RuntimeMetadata 传递权限快照
执行 SQL 时优先使用快照
```

### 7.4 LLM 不能作为权限执行者

不要要求模型“生成带权限的 SQL”作为最终保障。

模型只能生成候选 SQL。最终权限必须由服务端强制注入。

## 8. 验证标准

至少需要准备以下测试。

### 8.1 和 xx-cloud Mapper 查询对比

同一个用户、同一个权限配置、同一张表：

```text
xx-cloud Mapper 查询结果
Data Agent 生成 SQL 查询结果
```

两边结果范围必须一致。

### 8.2 不同权限用户对比

准备：

```text
管理员：DataScopeType.ALL
普通公司用户：DataRefType.COMPANY
个人用户：DataRefType.USER / SELF
无权限用户
```

验证 Data Agent 最终 SQL 是否追加正确权限条件。

### 8.3 SQL 结构覆盖

至少覆盖：

```text
单表 SELECT
JOIN
子查询
WITH CTE
UNION
聚合 GROUP BY
ORDER BY + LIMIT
表别名
字段别名
```

无法安全改写的 SQL 必须拒绝执行。

### 8.4 审计验证

trace 中需要记录：

```text
原始 SQL
权限改写后 SQL
命中的 data_agent_permission_rule
当前用户 userId
tenantId
dataPermission 摘要
```

## 9. 推荐实施步骤

### 第一阶段：接入身份和公共依赖

1. 将 Data Agent 后端接入 xx-cloud 模块。
2. 引入 `common-spring-boot-starter` 或 `db-spring-boot-starter + security-spring-boot-starter`。
3. Controller 入口获取 `AuthenticationContext`。
4. 将当前用户和数据权限快照传入 Agent 执行上下文。

### 第二阶段：建立权限映射

1. 新增 `data_agent_permission_rule`。
2. 配置核心业务表的数据权限字段。
3. 和 xx-cloud 现有 `@DataScope` 配置对齐。
4. 对无法配置权限字段的表默认禁止查询。

### 第三阶段：实现 SQL 权限改写器

1. 新增 `DataAgentSqlPermissionRewriteService`。
2. 使用 JSqlParser 解析 SQL。
3. 使用 `DataPermissionHelper.buildConditions(...)` 生成数据权限条件。
4. 注入租户条件。
5. 在 `DatasourceExplorerService.search()` 中调用。
6. 在 `AbstractAccessor` 做兜底保护。

### 第四阶段：验证一致性

1. 对比 xx-cloud Mapper 查询和 Data Agent 查询结果。
2. 覆盖不同用户、不同角色、不同 DataScopeType。
3. 覆盖复杂 SQL。
4. 完善 trace 和审计。

## 10. 最终判断

这个方案可以保持 Data Agent 和 xx-cloud 使用同一套权限体系，但前提是：

```text
权限来源复用 xx-cloud
权限模型复用 xx-cloud
权限条件生成复用 DataPermissionHelper
SQL 改写由 Data Agent 自己适配 JDBC 执行链路
```

不能保证一致的情况：

```text
Data Agent 自己根据 role 拼 SQL
不复用 AuthenticationContext.dataPermission()
不配置表字段到 DataRefType 的映射
遗漏租户条件
复杂 SQL 无法安全改写但仍然放行
```

推荐落地策略：

```text
先把 Data Agent 的 SQL 执行节点变成服务端强制改写
再用 xx-cloud 的 DataPermissionHelper 统一权限条件生成
最后通过对比测试证明和 xx-cloud Mapper 查询范围一致
```

## 11. xx-cloud-data-agent 当前落地配置

当前已在 `D:/workspace/xx-cloud` 的 `data_agent_integration` 分支新增独立服务模块：

```text
D:/workspace/xx-cloud/xx-cloud-data-agent
```

该模块作为独立服务启动，不复用 `xx-cloud-ai`。Data Agent 后端源码和 `agent-skills` 已按当前 `D:/workspace/agentscope` 工作区状态搬入，并将项目自有包名统一为：

```text
com.xx.cloud.dataagent
```

### 11.1 Nacos 配置文件

Data Agent 专属 Nacos 配置已放在 resources 下：

```text
D:/workspace/xx-cloud/xx-cloud-data-agent/src/main/resources/xx-cloud-data-agent.properties
```

网关路由模板也已放在 resources 下：

```text
D:/workspace/xx-cloud/xx-cloud-data-agent/src/main/resources/nacos/xx-cloud-gateway-data-agent-route.yaml
```

同步到 Nacos 时建议使用：

```text
Data ID: xx-cloud-data-agent.properties
Group:   与当前环境的 DEV_GROUP / 生产 Group 保持一致
Namespace: 与当前环境保持一致
```

网关路由模板可以单独作为 Nacos Data ID 下发给 `xx-cloud-gateway`，或合并到现有 `xx-cloud-gateway.properties` / 路由配置中。推荐对外暴露路径为：

```text
/data-agent/**
```

网关转发规则为：

```text
/data-agent/api/skills -> lb://xx-cloud-data-agent/api/skills
```

`application.yml` 中已增加本地兜底和 Nacos 同名配置导入：

```yaml
spring:
  config:
    import:
      - optional:classpath:${spring.application.name}.properties
      - optional:nacos:${spring.application.name}.properties
```

这样本地 resources 配置可以用于兜底，Nacos 中的 `xx-cloud-data-agent.properties` 可以在真实环境覆盖同名配置。

### 11.2 启动前必须同步/准备的内容

```text
1. 将 xx-cloud-data-agent.properties 同步到 Nacos
2. 按环境确认 application.yml 中的 Nacos server-addr、namespace、group、账号密码
3. 在 xx-cloud-data-agent.properties 中配置 DATA_AGENT_DATASOURCE_URL / DATA_AGENT_DATASOURCE_USERNAME / DATA_AGENT_DATASOURCE_PASSWORD 指向 Data Agent 独立管理库，不使用业务库 db.properties
4. 保留 mybatis-plus-default.yaml 作为配置库 MyBatis-Plus 默认配置，但不要依赖它提供 Data Agent 数据源
5. xx-cloud-data-agent 不再显式引入 mybatis-spring-boot-starter，配置/管理库通过 common-spring-boot-starter -> db-spring-boot-starter 接入 xx-cloud 的 MyBatis-Plus
6. 准备 security.yaml / cloud-default.yaml 等 xx-cloud 公共配置
7. 初始化 xx-cloud-data-agent/src/main/resources/db/data_agent.sql 中的数据权限映射表
8. 按业务表补齐 data_agent_permission_rule，否则未映射表会被默认拒绝查询
6. 部署时保证 agent-skills 目录在服务工作目录下，或设置 DATA_AGENT_SKILLS_LOCAL_PATH 指向实际目录
7. 如果需要持久化向量库，将 DATA_AGENT_VECTORSTORE_TYPE 从 simple 调整为 pgvector/elasticsearch，并准备对应连接配置
```

### 11.3 当前本地验证结果

本地已验证：

```text
mvnw -f D:/workspace/xx-cloud/xx-cloud-data-agent/pom.xml -DskipTests=false package
```

测试结果：

```text
Tests run: 41, Failures: 0, Errors: 0, Skipped: 0
BUILD SUCCESS
```

同时已做 jar 启动级探活验证：

```text
java -jar target/xx-cloud-data-agent.jar --spring.profiles.active=h2 --server.port=18066
GET http://127.0.0.1:18066/actuator/health -> {"status":"UP"}
Started DataAgentApplication
```

仍需真实 xx-cloud 环境验收：

```text
1. 使用真实登录 token 验证 AuthenticationContext 可以被 DataAgentController 捕获
2. 使用真实业务库和 data_agent_permission_rule 验证 SQL 改写结果
3. 对比同一用户、同一权限、同一业务表下 xx-cloud Mapper 查询范围和 Data Agent 查询范围
4. 验证 gateway/Nacos 路由可以访问 xx-cloud-data-agent
```


# MySQL Connector/J 适配 DDB 兼容性文档

## 背景

公司内部使用的分布式数据库 DDB（基于 MySQL 5.7.20 深度定制），通过 MySQL Proxy 对外暴露标准 MySQL 协议，但在 Metadata 层面做了大量修改，导致标准 MySQL Connector/J（当前版本 8.4.0-SNAPSHOT）存在多处不兼容。

本文档记录所有已确认的不兼容问题、最终的驱动代码修改方案，以及 DBeaver 使用时的配置建议。

---

## 目标实例信息

| 项目 | 值 |
|------|-----|
| Proxy IP/Port | `10.59.187.166:6000` / `10.59.187.167:6000` |
| 逻辑库名 | `lofter_ddb_test_gz` |
| 用户名 | `public_test` |
| 密码 | `********`（请通过内部文档获取） |
| 握手包版本字符串 | `5.7.20`（不含 v3e，与 `SELECT @@version` 结果不同） |
| `SELECT @@version` | `5.7.20-v3e-blob-compress-log` |
| 事务隔离级别 | `READ-COMMITTED` |
| 默认字符集 | `utf8mb4` |

> ⚠️ **重要**：DDB 握手包里的版本号只返回 `5.7.20`，不含 `-v3e-...` 后缀。驱动通过 `getServerVersion().toString()` 得到的是 `5.7.20`，**无法通过版本字符串检测 DDB**。本驱动改造版本直接面向 DDB，不做条件判断，所有修改无条件生效。

---

## JDBC 连接配置（推荐）

```properties
# 单节点直连（推荐，替代 LBDriver）
jdbcUrl = jdbc:mysql://10.59.187.166:6000/lofter_ddb_test_gz?connectTimeout=5000&socketTimeout=1800000&characterEncoding=utf-8
driverClassName = com.mysql.cj.jdbc.Driver
username = public_test
password = ********
```

> **无需添加任何额外 JDBC 参数**（如 `useInformationSchema=false`），改造后的驱动已自动适配 DDB。

原 LBDriver 只做两个 Proxy 之间的负载均衡，无其他能力，可直接替换为标准驱动连接单节点。

---

## DDB 与标准 MySQL 的关键行为差异

### 兼容（可正常使用）✅

| 命令 | 说明 |
|------|------|
| `SELECT @@session.xxx` 批量变量查询 | 驱动初始化，完全正常 |
| `SET NAMES` / `SET character_set_results` | 正常 |
| `SET SESSION TRANSACTION ISOLATION LEVEL` | 正常 |
| `SET autocommit` / `START TRANSACTION` / `COMMIT` / `ROLLBACK` | 正常 |
| `SHOW TABLES` | 正常，返回全量逻辑表（2328 张），但格式为 DDB 扩展 11 列格式 |
| `SHOW CREATE TABLE <table>` | 正常，对任意逻辑表均有效，是获取完整元数据的唯一可靠方式 |
| `SHOW COLLATION` / `SHOW CHARSET` | 正常 |
| `SHOW ENGINES` / `SHOW WARNINGS` / `SHOW GRANTS` | 正常 |

### 不兼容（驱动已适配）❌ → ✅

| 命令 | 错误 | 驱动适配方式 |
|------|------|------------|
| `SELECT * FROM information_schema.xxx` | `ERROR 11026` | 直接使用 `SHOW` 命令替代，不走 InfoSchema 路径 |
| `SHOW FULL TABLES` | 穿透物理分片，只返回 6 条 | 改用 `SHOW TABLES` + 客户端过滤 |
| `SHOW FULL COLUMNS FROM <跨分片表>` | 找不到表 | 改用 `SHOW CREATE TABLE` 解析 DDL |
| `SHOW KEYS/INDEXES FROM <跨分片表>` | 找不到表 | 改用 `SHOW CREATE TABLE` 解析 DDL |
| `SHOW INDEX FROM <table>` | `Unknown command` | 改用 `SHOW CREATE TABLE` 解析 DDL |
| `SHOW TABLES LIKE '...'` | 语法错误 | 客户端正则过滤 |
| `SHOW TABLES FROM <db>` | 语法错误 | 不带 FROM，只查当前连接库 |
| `SHOW CREATE TABLE <db>.<table>`（点号语法） | 语法错误 | 只用表名，不带 schema 前缀 |
| `USE <database>` | `ERROR 10000` | 只更新本地字段，不发送命令 |
| `SAVEPOINT <name>` | `ERROR 10004` | 抛 `SQLFeatureNotSupportedException` |
| `SELECT DATABASE()` | 返回物理分片库名 | 从 `HostInfo` 读取 JDBC URL 中的逻辑库名 |
| `ResultSetMetaData.getCatalogName()` 返回空 | DDB 列定义包不含 database 字段 | fallback 到 `hostInfo.getDatabase()` |

### 不兼容（业务层注意，驱动无法代劳）

| 命令 | 错误 | 解决方案 |
|------|------|---------|
| `DESCRIBE <table>` | `ERROR 10004` | 业务代码改为 `SHOW COLUMNS FROM <table>` |
| `SAVEPOINT`（嵌套事务） | 不支持 | Spring 避免使用 `PROPAGATION_NESTED`，改用 `REQUIRED` 或 `REQUIRES_NEW` |
| 子查询派生表（`SELECT * FROM (子查询) alias WHERE ...`） | `Illegal identifier` | DDB 不支持此语法，业务 SQL 需改写 |

---

## 驱动代码修改清单

> 工程路径：`/Users/wbean/IdeaProjects/mysql-connector-j`
> 驱动版本：`8.4.0-SNAPSHOT`
> 构建命令：`ant compile && ant build`
> 输出 JAR：`build/mysql-connector-j-8.4.0-SNAPSHOT/mysql-connector-j-8.4.0-SNAPSHOT.jar`

### 修改 1：`DatabaseMetaData.java` — 强制使用 SHOW 命令实现，跳过 InfoSchema 路径

**文件**：`src/main/user-impl/java/com/mysql/cj/jdbc/DatabaseMetaData.java`

**改动**：`getInstance()` 方法直接返回基于 `SHOW` 命令的 `DatabaseMetaData`，不再检查 `useInformationSchema` 参数，不再返回 `DatabaseMetaDataUsingInfoSchema`。

```java
protected static DatabaseMetaData getInstance(...) throws SQLException {
    // [DDB] Always use SHOW-command-based implementation; DDB has no INFORMATION_SCHEMA.
    return new DatabaseMetaData(connToSet, databaseToSet, resultSetFactory);
}
```

---

### 修改 2：`DatabaseMetaData.java` — `getTables()` 改用 `SHOW TABLES` + 客户端过滤

**背景**：`SHOW FULL TABLES` 会穿透到物理分片只返回 6 张表；`SHOW TABLES LIKE '...'` 和 `SHOW TABLES FROM <db>` 在 DDB 中均语法错误。

**改动**：
- 执行 `SHOW TABLES`（无 FULL、无 LIKE、无 FROM）
- DDB 返回 11 列扩展格式：`SCHEMA_NAME | TYPE | POLICY | MODEL | BF | PKEY | BUCKETNO | WRITEABLE | NEED_CHECK_DUP_KEY | COMMENT | ID_ASSIGN_TYPE`
- 列名映射：第 1 列（表名）→ `TABLE_NAME`，第 2 列（`INNODB`）→ `TABLE_TYPE=TABLE`，第 10 列 → `REMARKS`
- `tableNamePattern` 过滤在 Java 层用正则完成（将 SQL `%`/`_` 通配符转为 Java 正则）

> **注意**：DDB 通过 JDBC 协议返回的 `SHOW TABLES` 第一列列名为 `SCHEMA_NAME`（而非 CLI 显示的 `NAME`），驱动代码以 `SCHEMA_NAME` 为准，同时兼容 `NAME`。

---

### 修改 3：`DatabaseMetaData.java` — `getColumns()` 改用 `SHOW CREATE TABLE` 解析 DDL

**背景**：
- `SHOW COLUMNS FROM` 返回非标准 7 列格式（无 `Null`、无 `Default`，类型无精度）
- `SHOW FULL COLUMNS FROM` 跨分片报错

**改动**：执行 `SHOW CREATE TABLE <table>`，解析 DDL 文本中每列的定义，提取以下字段：
- `Field`（列名）、`Type`（含精度）、`Null`（`NOT NULL` → `NO`，否则 `YES`）、`Key`（`PRIMARY KEY` → `PRI`，`UNIQUE KEY` → `UNI`，`KEY` → `MUL`）、`Default`、`Extra`（`AUTO_INCREMENT`、`on update CURRENT_TIMESTAMP` 等）、`Comment`

---

### 修改 4：`DatabaseMetaData.java` — `getIndexInfo()` / `getPrimaryKeys()` 改用 `SHOW CREATE TABLE` 解析 DDL

**背景**：`SHOW INDEX FROM` 语法不支持；`SHOW INDEXES FROM` / `SHOW KEYS FROM` 跨分片报错。

**改动**：同样执行 `SHOW CREATE TABLE <table>`，从 DDL 中解析 `PRIMARY KEY`、`UNIQUE KEY`、`KEY` 定义，构造符合 JDBC 规范的 `getIndexInfo` / `getPrimaryKeys` 结果集。

---

### 修改 5：`DatabaseMetaData.java` — `extractForeignKeyFromCreateTable()` 去掉 schema 前缀

**背景**：DDB 不支持 `SHOW CREATE TABLE `db`.`table`` 点号语法，报 `Syntax error, expect ';', but was '.'`。

**触发场景**：DBeaver 在查询结果集时触发 `getImportedKeys()` → `extractForeignKeyFromCreateTable()`。

**改动**：将
```java
StringUtils.getFullyQualifiedName(dbName, tableToExtract, quotedId, pedantic)
// 生成：`lofter_ddb_test_gz`.`C2C_ClearCommand`
```
改为：
```java
StringUtils.quoteIdentifier(tableToExtract, quotedId, pedantic)
// 生成：`C2C_ClearCommand`
```

---

### 修改 6：`DatabaseMetaData.java` — `getDatabaseIterator()` / `getSchemaPatternIterator()` 固定返回逻辑库名

**背景**：`SHOW DATABASES` 返回物理分片库名列表（非逻辑库名）；`SELECT DATABASE()` 返回物理分片名。

**改动**：`catalog/schema` 参数为 null 时，直接返回 `this.database`（JDBC URL 中指定的逻辑库名），不调用 `SHOW DATABASES`。

---

### 修改 7：`DatabaseMetaData.java` — `getDatabase(catalog, schema)` 兼容连字符 catalog 名

**背景**：DBeaver 内部把 catalog 名 `lofter_ddb_test_gz` 中的下划线转成了连字符 `lofter-ddb-test-gz`，导致元数据查询匹配不上。

**改动**：若传入的 catalog/schema 与 `this.database` 仅下划线/连字符差异（`catalog.replace('-','_').equalsIgnoreCase(this.database)`），则映射回正确的 `this.database`。

---

### 修改 8：`ConnectionImpl.java` — `setDatabase()` 不发送 `USE` 命令

**背景**：DDB 拒绝 `USE <db>` 命令，报 `ERROR 10000: database name can not be found on server`。

**改动**：`setDatabase()` 直接更新本地 `this.database` 字段并返回，不向服务端发送任何命令。

---

### 修改 9：`ConnectionImpl.java` — `setSavepoint()` 抛标准异常

**背景**：DDB 拒绝 `SAVEPOINT` 命令，报 `ERROR 10004`。Spring `PROPAGATION_NESTED` 等会触发。

**改动**：`setSavepoint()` 直接抛 `SQLFeatureNotSupportedException`，不发送命令，让上层框架能正确处理。

---

### 修改 10：`NativeCharsetSettings.java` — 跳过自定义字符集检测

**背景**：`detectCustomCollations` 默认为 true，会查询 `INFORMATION_SCHEMA.COLLATIONS`，DDB 没有 InfoSchema。

**改动**：直接跳过整个 custom collation 检测块（`if(false && ...)` 永远不执行）。

---

### 修改 11：`ResultSetMetaData.java` — `getCatalogName()` fallback 到逻辑库名

**背景**：DDB 的列定义协议包中 `databaseName` 字段为空，`getCatalogName()` 返回空字符串。DBeaver 用 `getCatalogName()` 构造行更新的 key（如 `` `lofter-ddb-test-gz`.`C2C_ClearCommand`.`PRIMARY` ``），得到空字符串后会 fallback 到自己的内部 catalog 显示名（可能含连字符），导致主键匹配失败，报 "attributes of key ... are missing in result set"。

**改动**：`getCatalogName()` 当 `Field.getDatabaseName()` 返回空/null 时，fallback 返回 `session.getHostInfo().getDatabase()`（即 JDBC URL 中指定的逻辑库名）。

---

## DBeaver 使用配置

### 驱动配置

1. DBeaver → **数据库** → **驱动管理器** → **新建驱动**
2. 驱动类：`com.mysql.cj.jdbc.Driver`
3. 添加 JAR：选择改造后的 `mysql-connector-j-8.4.0-SNAPSHOT.jar`
4. URL 模板：`jdbc:mysql://{host}:{port}/{database}`

### 连接配置

| 字段 | 值 |
|------|-----|
| Host | `10.59.187.166` |
| Port | `6000` |
| Database | `lofter_ddb_test_gz`（必须用**下划线**，不能用连字符） |
| Username | `public_test` |

### 已知 DBeaver 行为限制

| 场景 | 现象 | 说明 |
|------|------|------|
| 编辑行保存后刷新 | `Error refreshing rows`，SQL 报 `Illegal identifier` | DBeaver 用 `SELECT * FROM (原始SQL) alias WHERE id=?` 刷新，DDB 不支持派生表子查询语法。**数据已保存成功**，刷新失败不影响数据。手动重新执行查询即可看到最新数据。 |
| 查看外键（Foreign Keys） | 可能报错或返回空 | DDB 表通常不设置外键约束，DBeaver 查询外键时触发 `getImportedKeys()`，已修复 `SHOW CREATE TABLE` 的 schema 前缀问题，正常情况返回空列表（0 个外键）。 |

---

## 已修改文件汇总

| 文件 | 修改说明 |
|------|---------|
| `src/main/user-impl/java/com/mysql/cj/jdbc/DatabaseMetaData.java` | 11 处改动：getInstance 强制走 SHOW 路径；getTables/getColumns/getIndexInfo/getPrimaryKeys 全部改用 SHOW CREATE TABLE；getDatabaseIterator 固定逻辑库名；getDatabase 兼容连字符；extractForeignKeyFromCreateTable 去掉 schema 前缀 |
| `src/main/user-impl/java/com/mysql/cj/jdbc/ConnectionImpl.java` | setDatabase 不发 USE 命令；setSavepoint 抛标准异常 |
| `src/main/core-impl/java/com/mysql/cj/NativeCharsetSettings.java` | 跳过 custom collation 检测块 |
| `src/main/user-impl/java/com/mysql/cj/jdbc/result/ResultSetMetaData.java` | getCatalogName fallback 到 hostInfo.getDatabase() |

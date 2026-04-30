# 实战项目 3：中间件与数据库性能瓶颈诊断

> 目标：部署一个使用 MySQL、Redis、Kafka 的完整应用，模拟连接池耗尽、慢查询、大 key 等问题，并系统化排查修复。
> 这是平台工程师处理最多的问题类型：应用变慢，但不知道是哪个中间件导致的。

---

## 实验架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    完整中间件实验环境                             │
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│  │   App Pod    │────▶│   MySQL 8.0  │     │   Kafka      │   │
│  │  Spring Boot │     │  (StatefulSet)│    │  (3 brokers) │   │
│  │  REST API    │◀────│              │     │              │   │
│  │  /api/orders │     │  问题注入：   │     │  问题注入：   │   │
│  │              │     │  • 缺少索引   │     │  • batch=1   │   │
│  │  问题注入：   │     │  • 大表扫描   │     │  • 无压缩    │   │
│  │  • 连接池=5  │     │  • 死锁      │     │              │   │
│  └──────┬───────┘     └──────────────┘     └──────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────┐                                              │
│  │   Redis 7.0  │                                              │
│  │  (单实例)    │                                              │
│  │              │                                              │
│  │  问题注入：   │                                              │
│  │  • 大 key    │                                              │
│  │  • 慢命令    │                                              │
│  │  • 热点 key  │                                              │
│  └──────────────┘                                              │
│                                                                 │
│  监控栈：Prometheus + Grafana + JMX Exporter                    │
└─────────────────────────────────────────────────────────────────┘

API 端点：
  POST /api/orders      -> 创建订单（写 MySQL + 发 Kafka）
  GET  /api/orders/{id} -> 查询订单（读 MySQL + 读 Redis 缓存）
  GET  /api/cache/stats -> Redis 缓存统计
  GET  /api/health      -> 健康检查
```

---

## 前置要求

```bash
# 硬件
CPU: 6 核+
内存: 12GB+
磁盘: 30GB SSD

# 软件
docker --version  # 24.0+
kind --version    # 0.20+
kubectl version --client  # 1.28+
helm version      # 3.12+
java -version     # 17+
mvn -version      # 3.9+

# 可选工具
redis-cli --version
kafka-console-consumer.sh --version
mysql-client --version
```

---

## 实验步骤详解

### 步骤 1：部署实验环境

```bash
cd platform-engineering-lab/10-practice-projects/project-3-middleware-perf

# 一键部署（约 8-10 分钟）
bash deploy-middleware-lab.sh

# 脚本内部逻辑：
# 1. 创建 kind-middleware 集群
# 2. 部署 MySQL StatefulSet（带初始化数据）
# 3. 部署 Redis（带内存限制 512MB）
# 4. 部署 Kafka（3 broker，每节点 1GB）
# 5. 构建并部署 Spring Boot 应用
# 6. 部署 Prometheus + Grafana

# 验证部署
kubectl get pods -n middleware-lab
# NAME                     READY   STATUS    RESTARTS   AGE
# app-7d8f9b2c4-x1a2b      1/1     Running   0          3m
# mysql-0                  1/1     Running   0          5m
# redis-0                  1/1     Running   0          5m
# kafka-0                  1/1     Running   0          5m
# kafka-1                  1/1     Running   0          5m
# kafka-2                  1/1     Running   0          5m
# prometheus-0             1/1     Running   0          4m
# grafana-0                1/1     Running   0          4m

# 验证应用端口转发
kubectl port-forward svc/app -n middleware-lab 8080:8080 &
APP_PID=$!

# 测试 API
curl -s http://localhost:8080/api/health | jq .
# {"status":"UP","components":{"db":"UP","redis":"UP","kafka":"UP"}}
```

### 步骤 2：注入性能问题

```bash
# 问题 1：MySQL 慢查询（删除索引）
./inject-problems.sh mysql-slow-query

# 内部逻辑：
# mysql -h mysql.middleware-lab.svc.cluster.local -u root -padmin \
#   -e "ALTER TABLE orders DROP INDEX idx_created_at;"
# mysql -e "ALTER TABLE orders DROP INDEX idx_user_id;"
# 结果：orders 表 100 万条记录，无有效索引

# 问题 2：Redis 大 key
./inject-problems.sh redis-big-key

# 内部逻辑：
# redis-cli SET big:json:string $(python3 -c "print('x'*10485760)")  # 10MB
# redis-cli LPUSH big:list $(python3 -c "for i in range(100000): print('item'+str(i))")
# 结果：Redis 内存瞬间增长 50MB+

# 问题 3：连接池耗尽
./inject-problems.sh connection-pool-exhaust

# 内部逻辑：
# kubectl patch deployment app -n middleware-lab --type='json' -p='[
#   {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
#     {"name": "DB_MAX_POOL_SIZE", "value": "5"},
#     {"name": "DB_MIN_IDLE", "value": "1"}
#   ]}
# ]'
# 结果：连接池 max=5，50 并发压测时大量等待

# 问题 4：Kafka 低效配置
./inject-problems.sh kafka-inefficient

# 内部逻辑：
# 设置 batch.size=1, linger.ms=0, compression.type=none
# 结果：每条消息独立发送，网络 RTT 累积
```

### 步骤 3：压测观察问题

```bash
# 基线压测（注入问题前，可选）
siege -c 20 -t 30s --content-type "application/json" \
  "http://localhost:8080/api/orders POST {\"userId\":1,\"amount\":100}"
# 基线：Transactions: 4500, Response time: 0.08s, Availability: 100%

# 问题注入后压测
echo "=== 问题注入后压测 ==="
siege -c 20 -t 30s --content-type "application/json" \
  "http://localhost:8080/api/orders POST {\"userId\":1,\"amount\":100}"

# 预期输出（问题注入后）：
# Lifting the server siege...
# Transactions:                890 hits
# Availability:               72.50 %     <- 大量失败！
# Response time:                0.65 secs   <- 从 80ms 到 650ms
# Failed transactions:         245         <- 连接超时/获取失败
# Longest transaction:         5.00 secs   <- P99 5000ms

# 应用日志中出现异常
kubectl logs -f -n middleware-lab deploy/app | grep -E "ERROR|Exception|timeout" | head -20
# 预期输出：
# ERROR c.z.h.p.HikariPool - Thread starvation or clock leap detected
# ERROR o.h.e.j.s.SqlExceptionHelper - Connection is not available, request timed out after 30000ms
# ERROR o.a.k.c.p.i.Sender - [Producer clientId=producer-1] Connection to node -1 could not be established
```

### 步骤 4：MySQL 诊断

```bash
# 诊断脚本 1：慢查询日志
./diagnose-mysql.sh

# 内部执行：

# 1. 检查连接池状态
kubectl exec -it mysql-0 -n middleware-lab -- mysql -u root -padmin -e "
SHOW PROCESSLIST;
"
# 预期输出：
# +----+------+-------------------+------------+---------+------+----------+------------------+
# | Id | User | Host              | db         | Command | Time | State    | Info             |
# +----+------+-------------------+------------+---------+------+----------+------------------+
# |  5 | root | 10.244.0.x:xxxxx  | orders_db  | Query   |   12 | Sending  | SELECT * FROM orders WHERE user_id = 1 |
# |  6 | root | 10.244.0.x:xxxxx  | orders_db  | Query   |    8 | Sending  | SELECT * FROM orders WHERE user_id = 2 |
# |  7 | root | 10.244.0.x:xxxxx  | orders_db  | Sleep   |    0 |          | NULL             |
# |  8 | root | 10.244.0.x:xxxxx  | orders_db  | Query   |   15 | Sending  | SELECT COUNT(*) FROM orders WHERE created_at > '2024-01-01' |
# +----+------+-------------------+------------+---------+------+----------+------------------+
# 发现：多条慢查询正在执行，Time 列显示已执行 8-15 秒！

# 2. 检查慢查询日志
kubectl exec -it mysql-0 -n middleware-lab -- mysql -u root -padmin -e "
SELECT sql_text, ROUND(timer_wait/1000000000000, 3) AS duration_sec
FROM performance_schema.events_statements_history_long
WHERE timer_wait > 1000000000000
ORDER BY timer_wait DESC
LIMIT 10;
"
# 预期输出：
# +------------------------------------------+--------------+
# | sql_text                                 | duration_sec |
# +------------------------------------------+--------------+
# | SELECT * FROM orders WHERE user_id = ?   |       12.345 |
# | SELECT COUNT(*) FROM orders WHERE ...    |        8.234 |
# | SELECT * FROM orders WHERE status = ?    |        6.789 |
# +------------------------------------------+--------------+

# 3. EXPLAIN 分析执行计划
kubectl exec -it mysql-0 -n middleware-lab -- mysql -u root -padmin -e "
EXPLAIN SELECT * FROM orders WHERE user_id = 1;
"
# 预期输出：
# +----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
# | id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
# +----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
# |  1 | SIMPLE      | orders | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 1000000|   10.00  | Using where |
# +----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
# 关键指标：type=ALL（全表扫描），rows=1,000,000（扫描 100 万行）
# key=NULL（未使用索引）→ 根因确认：缺少索引！

# 4. 表索引状态
kubectl exec -it mysql-0 -n middleware-lab -- mysql -u root -padmin -e "
SHOW INDEX FROM orders;
"
# 预期输出：
# +--------+------------+----------+--------------+
# | Table  | Non_unique | Key_name | Seq_in_index |
# +--------+------------+----------+--------------+
# | orders |          0 | PRIMARY  |            1 |
# +--------+------------+----------+--------------+
# 确认：只有主键索引，user_id 和 created_at 的索引已被删除
```

### 步骤 5：Redis 诊断

```bash
# 诊断脚本 2：Redis 分析
./diagnose-redis.sh

# 内部执行：

# 1. 内存使用
kubectl exec -it redis-0 -n middleware-lab -- redis-cli INFO memory
# 预期输出：
# # Memory
# used_memory:536870912       <- 512MB 已用完！
# used_memory_human:512.00M
# used_memory_rss:629145600
# used_memory_peak:576716800
# maxmemory:536870912
# maxmemory_policy:noeviction  <- 达到上限不驱逐，直接报错！

# 2. 大 key 扫描
kubectl exec -it redis-0 -n middleware-lab -- redis-cli --bigkeys
# 预期输出：
# # Scanning the entire keyspace to find biggest keys as well as
# # average sizes per key type.
# 
# -------- summary -------
# Sampled 100 keys in the keyspace!
# Total key length in bytes is 2345 (avg len 23.45)
# 
# Biggest string found 'big:json:string' has 10485760 bytes  <- 10MB!
# Biggest list   found 'big:list' has 100000 items            <- 10 万元素！

# 3. 慢查询日志
kubectl exec -it redis-0 -n middleware-lab -- redis-cli SLOWLOG GET 10
# 预期输出：
# 1) 1) (integer) 12           # log id
#    2) (integer) 1704067200   # 时间戳
#    3) (integer) 5234000      # 执行时间 5234ms！
#    4) 1) "LRANGE"
#       2) "big:list"
#       3) "0"
#       4) "-1"
# 根因：LRANGE big:list 0 -1 读取 10 万元素，耗时 5.2 秒！

# 4. 热点 key 检测
kubectl exec -it redis-0 -n middleware-lab -- redis-cli INFO stats | grep keyspace
# keyspace_hits:12345
# keyspace_misses:67890       <- 命中率极低！
```

### 步骤 6：Kafka 诊断

```bash
# 诊断脚本 3：Kafka 分析
./diagnose-kafka.sh

# 内部执行：

# 1. 生产者指标
kubectl exec -it kafka-0 -n middleware-lab -- kafka-producer-perf-test \
  --topic orders \
  --num-records 1000 \
  --record-size 1000 \
  --throughput -1 \
  --producer-props bootstrap.servers=kafka.middleware-lab.svc.cluster.local:9092

# 预期输出（低效配置）：
# 1000 records sent, 123.456789 records/sec (0.12 MB/sec), 
# 4567.89 ms avg latency, 8901.23 ms max latency, 4321.0 ms 50th, 8765.4 ms 95th, 8890.1 ms 99th, 8900.5 ms 99.9th.
# 关键指标：吞吐量仅 123 records/sec，延迟 P99 = 8890ms！

# 2. 检查 topic 配置
kubectl exec -it kafka-0 -n middleware-lab -- kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --describe --entity-type topics --entity-name orders
# 预期输出：
# Dynamic configs for topic orders are:
#   compression.type=no compression  <- 无压缩！
#   min.insync.replicas=1
#   retention.ms=604800000

# 3. 检查生产者配置（应用内）
kubectl logs -n middleware-lab deploy/app | grep -E "batch.size|linger.ms|compression"
# 预期输出：
# batch.size = 1                   <- 每批只发 1 条！
# linger.ms = 0                    <- 不等待，立即发送
# compression.type = none          <- 不压缩
```

### 步骤 7：连接池诊断

```bash
# 诊断脚本 4：连接池分析
kubectl logs -n middleware-lab deploy/app | grep -i "HikariPool\|connection\|pool" | tail -30

# 预期输出：
# DEBUG c.z.h.p.HikariPool - HikariPool-1 - Pool stats (total=5, active=5, idle=0, waiting=45)
# 关键指标：
#   total=5    <- 最大连接数只有 5
#   active=5   <- 全部在用
#   idle=0     <- 没有空闲连接
#   waiting=45 <- 45 个请求在等待连接！

# 应用日志中的异常
kubectl logs -n middleware-lab deploy/app | grep -E "SQLException|Connection.*timeout" | head -10
# java.sql.SQLException: Connection is not available, request timed out after 30000ms
# 根因：连接池 max=5，并发请求 20+ 时大量超时
```

### 步骤 8：修复并验证

#### 修复 1：MySQL 索引

```bash
# 重建索引
kubectl exec -it mysql-0 -n middleware-lab -- mysql -u root -padmin -e "
USE orders_db;
CREATE INDEX idx_user_id ON orders(user_id);
CREATE INDEX idx_created_at ON orders(created_at);
CREATE INDEX idx_status ON orders(status);
ANALYZE TABLE orders;
"

# 验证执行计划
kubectl exec -it mysql-0 -n middleware-lab -- mysql -u root -padmin -e "
EXPLAIN SELECT * FROM orders WHERE user_id = 1;
"
# +----+-------------+--------+-------+---------------+-------------+---------+-------+------+-------------+
# | id | select_type | table  | type  | possible_keys | key         | key_len | ref   | rows | Extra       |
# +----+-------------+--------+-------+---------------+-------------+---------+-------+------+-------------+
# |  1 | SIMPLE      | orders | ref   | idx_user_id   | idx_user_id | 5       | const |    1 | Using index |
# +----+-------------+--------+-------+---------------+-------------+---------+-------+------+-------------+
# 改善：type=ref（索引查找），rows=1（只扫描 1 行）
```

#### 修复 2：Redis 大 key

```bash
# 删除大 key
kubectl exec -it redis-0 -n middleware-lab -- redis-cli DEL big:json:string
kubectl exec -it redis-0 -n middleware-lab -- redis-cli DEL big:list

# 优化：将大 JSON 拆分为 hash 字段
# 将大 list 改为分页读取

# 验证内存
kubectl exec -it redis-0 -n middleware-lab -- redis-cli INFO memory | grep used_memory_human
# used_memory_human:12.34M  <- 从 512M 降到 12M
```

#### 修复 3：连接池调大

```bash
kubectl patch deployment app -n middleware-lab --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "DB_MAX_POOL_SIZE", "value": "50"},
    {"name": "DB_MIN_IDLE", "value": "10"},
    {"name": "DB_CONNECTION_TIMEOUT", "value": "5000"},
    {"name": "DB_IDLE_TIMEOUT", "value": "600000"},
    {"name": "DB_MAX_LIFETIME", "value": "1800000"}
  ]}
]'
kubectl rollout status deployment app -n middleware-lab
```

#### 修复 4：Kafka 优化

```bash
kubectl patch deployment app -n middleware-lab --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value":
    {"name": "KAFKA_BATCH_SIZE", "value": "16384"}
  },
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value":
    {"name": "KAFKA_LINGER_MS", "value": "10"}
  },
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value":
    {"name": "KAFKA_COMPRESSION_TYPE", "value": "snappy"}
  }
]'
kubectl rollout status deployment app -n middleware-lab
```

### 步骤 9：修复后验证压测

```bash
# 重新压测
echo "=== 修复后压测 ==="
siege -c 20 -t 30s --content-type "application/json" \
  "http://localhost:8080/api/orders POST {\"userId\":1,\"amount\":100}"

# 预期输出：
# Lifting the server siege...
# Transactions:               5600 hits
# Availability:              100.00 %
# Response time:                0.07 secs   <- 从 650ms 降到 70ms
# Transaction rate:          186.67 trans/sec
# Failed transactions:           0
# Longest transaction:         0.15          <- P99 150ms

# 对比总结
echo "=== 修复前后对比 ==="
printf "%-25s %-15s %-15s\n" "指标" "修复前" "修复后"
printf "%-25s %-15s %-15s\n" "吞吐量(TPS)" "123" "187"
printf "%-25s %-15s %-15s\n" "平均延迟" "650ms" "70ms"
printf "%-25s %-15s %-15s\n" "成功率" "72.5%" "100%"
printf "%-25s %-15s %-15s\n" "MySQL 扫描行数" "100万" "1"
printf "%-25s %-15s %-15s\n" "Redis 内存" "512MB" "12MB"
printf "%-25s %-15s %-15s\n" "连接池等待" "45" "0"
printf "%-25s %-15s %-15s\n" "Kafka 吞吐" "123/s" "~5000/s"
```

---

## 排障决策树

```
应用变慢（P99 飙升）
    │
    ├── 应用日志有 SQL 超时？
    │       ├── 是 → MySQL 问题
    │       │       ├── EXPLAIN 查看执行计划
    │       │       ├── SHOW PROCESSLIST 查看慢查询
    │       │       └── 检查索引和连接池
    │       └── 否 → 继续
    │
    ├── 应用日志有 Redis 超时？
    │       ├── 是 → Redis 问题
    │       │       ├── INFO memory 查看内存使用
    │       │       ├── --bigkeys 扫描大 key
    │       │       ├── SLOWLOG 查看慢命令
    │       │       └── 检查热点 key 和缓存命中率
    │       └── 否 → 继续
    │
    ├── Kafka 生产者日志有发送失败？
    │       ├── 是 → Kafka 问题
    │       │       ├── 检查 batch.size / linger.ms
    │       │       ├── 检查 compression.type
    │       │       └── 检查 broker 网络和磁盘
    │       └── 否 → 继续
    │
    └── 以上都不是？
            ├── 检查 JVM GC 日志
            ├── 检查线程 Dump
            ├── 检查网络延迟
            └── 检查宿主机资源（CPU/内存/磁盘）
```

---

## 评分标准

```
基础要求（40 分）：
  □ 成功部署完整中间件环境（MySQL+Redis+Kafka）（15 分）
  □ 成功注入 4 类性能问题（10 分）
  □ 使用 siege 完成压测并记录基线（10 分）
  □ 成功运行所有诊断脚本（5 分）

进阶要求（40 分）：
  □ 定位 MySQL 慢查询根因（缺少索引）（10 分）
  □ 定位 Redis 大 key 和慢命令（10 分）
  □ 定位连接池耗尽问题（10 分）
  □ 定位 Kafka 配置低效问题（10 分）

挑战要求（20 分）：
  □ 修复后 P99 < 200ms（10 分）
  □ 编写综合监控 Dashboard（Grafana）（10 分）

优秀加分（额外）：
  □ 使用 JMX Exporter 监控 JVM 指标（+5 分）
  □ 编写自动化修复脚本（+5 分）
```

---

## 面试核心考点

```
Q: "应用突然变慢，如何快速定位是哪个中间件的问题？"

A:
   1. 先看应用日志：哪个组件抛出了超时异常？
      - SQLTimeoutException → MySQL
      - RedisCommandTimeoutException → Redis
      - KafkaTimeoutException → Kafka
   
   2. 再看监控：哪个组件的延迟/错误率飙升？
      - MySQL: slow_queries, threads_running
      - Redis: used_memory, slowlog, keyspace_hits/misses
      - Kafka: producer/consumer lag, request latency
   
   3. 分层诊断：
      - DB 层：EXPLAIN + SHOW PROCESSLIST + 索引分析
      - 缓存层：bigkeys + slowlog + 内存分析
      - 消息层：perf-test + 配置审计
      - 连接层：连接池监控 + 线程 Dump
   
   4. 修复优先级：
      - P0：连接池（影响所有请求）
      - P1：索引（影响特定查询）
      - P2：大 key（影响 Redis 性能）
      - P3：Kafka 配置（影响吞吐量，但通常不阻塞）
```

---

## 常见问题

```
Q: MySQL Pod 启动失败？
A: 检查 PVC 是否绑定，storage class 是否正确。
   kind 默认使用 standard StorageClass。

Q: Kafka broker 无法选举 leader？
A: 检查 Pod 间网络是否互通，DNS 解析是否正常。
   Kafka 依赖 headless service 进行 broker 发现。

Q: 压测时应用 OOM？
A: 检查应用的内存限制，默认可能只有 512MB。
   建议设置为 2Gi 以上。
```

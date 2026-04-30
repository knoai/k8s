# 生产排障：中间件与数据库时延深度排查

> 多集群部署中，80% 的时延差异来自下游中间件/数据库。本节提供 MySQL、Redis、Kafka 的专项排查方法，含真实日志和命令输出。

---

## 排查框架：中间件延迟分层

```
应用请求
    │
    ├─ 客户端层 [连接池/驱动版本/序列化/批量策略]
    │      典型延迟：0-5ms
    │
    ├─ 网络层 [TCP连接/DNS解析/跨AZ路由/防火墙]
    │      典型延迟：同AZ 0.5ms / 跨AZ 2-5ms / 跨地域 50-200ms
    │
    ├─ 服务端层 [负载均衡/代理层/分片路由]
    │      典型延迟：ProxySQL 0.5ms / PgBouncer 0.1ms
    │
    ├─ 处理层 [查询解析/执行计划/锁竞争/缓存]
    │      典型延迟：简单查询 1-10ms / 复杂查询 100ms-10s
    │
    └─ 存储层 [磁盘IO/WAL/Redo/刷盘策略]
           典型延迟：SSD 0.1-1ms / NVMe 0.01-0.1ms / 网络存储 5-50ms
```

---

## MySQL / PostgreSQL 排查

### 1. 连接池层面

#### 真实故障场景

```
应用日志：
[2024-01-15 14:23:45] [WARN] HikariPool-1 - Thread starvation or clock leap detected
[2024-01-15 14:23:46] [ERROR] HikariDataSource : HikariPool-1 - Connection is not available, 
  request timed out after 30000ms
[2024-01-15 14:23:46] [ERROR] OrderService : Failed to create order
  java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available
```

#### 诊断命令与输出

```bash
# 方法 1：通过 Actuator 查看连接池状态（Spring Boot）
curl -s http://<pod>:8080/actuator/metrics/hikaricp.connections.active | jq .

# 实际输出示例（健康）：
# {
#   "name": "hikaricp.connections.active",
#   "measurements": [{"statistic": "VALUE", "value": 12}],
#   "availableTags": [{"tag": "pool", "values": ["HikariPool-1"]}]
# }

# 实际输出示例（异常）：
# {
#   "name": "hikaricp.connections.active",
#   "measurements": [{"statistic": "VALUE", "value": 50}],
#   "availableTags": [{"tag": "pool", "values": ["HikariPool-1"]}]
# }
# ← value=50 且最大连接数也是 50，说明连接池已耗尽

# 查看完整连接池指标
curl -s http://<pod>:8080/actuator/metrics \
  | grep hikaricp \
  | jq -s 'sort_by(.name) | .[] | "\(.name): \(.measurements[0].value)"'

# 健康集群 A 输出：
# hikaricp.connections: 30
# hikaricp.connections.active: 12
# hikaricp.connections.idle: 18
# hikaricp.connections.max: 50
# hikaricp.connections.min: 10
# hikaricp.connections.pending: 0          ← 关键：没有等待连接的线程
# hikaricp.connections.timeout: 0
# hikaricp.connections.usage: 0.4          ← 使用率 40%

# 问题集群 B 输出：
# hikaricp.connections: 50
# hikaricp.connections.active: 50
# hikaricp.connections.idle: 0
# hikaricp.connections.max: 50
# hikaricp.connections.min: 10
# hikaricp.connections.pending: 23         ← 关键：23 个线程在等待连接！
# hikaricp.connections.timeout: 156        ← 已累计 156 次超时
# hikaricp.connections.usage: 1.0          ← 使用率 100%
```

#### 连接池配置对比

```yaml
# 集群 A（健康）
spring:
  datasource:
    hikari:
      maximum-pool-size: 50
      minimum-idle: 10
      connection-timeout: 5000        # 5秒
      idle-timeout: 300000            # 5分钟
      max-lifetime: 1200000           # 20分钟
      leak-detection-threshold: 60000 # 60秒泄漏检测
      
# 集群 B（问题）
spring:
  datasource:
    hikari:
      maximum-pool-size: 5            # ← 错误：只有 5 个连接
      minimum-idle: 1
      connection-timeout: 30000       # 30秒（太长，用户体验差）
      idle-timeout: 600000
      max-lifetime: 1800000
      # leak-detection-threshold 未设置！
```

#### 连接泄漏排查

```bash
# 1. 开启泄漏检测（需要重启应用）
# 在 application.yaml 中设置：
# spring.datasource.hikari.leak-detection-threshold=30000

# 2. 查看泄漏日志
kubectl logs <pod> | grep "Apparent connection leak detected"

# 实际输出：
# [2024-01-15 14:23:45] [WARN] com.zaxxer.hikari.pool.ProxyLeakTask : 
#   Apparent connection leak detected, owning stack trace follows for 
#   pool entry HikariPool-1, state ACTIVE, last acquired at 1705327412345
# java.lang.Exception: Apparent connection leak detected
#   at com.company.OrderService.createOrder(OrderService.java:45)
#   at com.company.OrderController.placeOrder(OrderController.java:23)
# ← 泄漏点在 OrderService.java:45

# 3. 代码审查：找到泄漏点
# 错误代码示例：
# public void createOrder(Order order) {
#     Connection conn = dataSource.getConnection();  // 获取连接
#     // ... 执行 SQL ...
#     // 缺少 conn.close() 或 try-with-resources！
#     // 如果中间抛出异常，连接永远不会被释放
# }

# 修复代码：
# public void createOrder(Order order) {
#     try (Connection conn = dataSource.getConnection()) {
#         // ... 执行 SQL ...
#     } // 自动关闭连接
# }
```

---

### 2. 查询执行层面

#### 开启并分析慢查询

```bash
# 步骤 1：开启慢查询日志（MySQL）
# 在 MySQL Pod 中执行：
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SET GLOBAL slow_query_log = 'ON';
  SET GLOBAL long_query_time = 0.1;
  SET GLOBAL log_output = 'TABLE';
"

# 验证：
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SHOW VARIABLES LIKE 'slow_query%';
"
# 预期输出：
# +---------------------+--------+
# | Variable_name       | Value  |
# +---------------------+--------+
# | slow_query_log      | ON     |
# | slow_query_log_file |        |
# | long_query_time     | 0.100  |
# +---------------------+--------+

# 步骤 2：运行一段时间后分析慢查询
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SELECT 
    db,
    COUNT(*) as cnt,
    ROUND(AVG(query_time), 3) as avg_time,
    ROUND(MAX(query_time), 3) as max_time,
    ROUND(SUM(query_time), 3) as total_time,
    LEFT(sql_text, 100) as query_sample
  FROM mysql.slow_log
  WHERE start_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)
  GROUP BY LEFT(sql_text, 50)
  ORDER BY total_time DESC
  LIMIT 10;
"

# 集群 A（健康）输出：
# +-------+-----+----------+----------+------------+--------------------------------------+
# | db    | cnt | avg_time | max_time | total_time | query_sample                         |
# +-------+-----+----------+----------+------------+--------------------------------------+
# | shop  |  15 |    0.234 |    0.456 |      3.510 | SELECT * FROM orders WHERE user_id = |
# | shop  |   8 |    0.123 |    0.234 |      0.984 | SELECT COUNT(*) FROM order_items WHE |
# | shop  |   5 |    0.089 |    0.123 |      0.445 | UPDATE inventory SET stock = stock - |
# +-------+-----+----------+----------+------------+--------------------------------------+

# 集群 B（问题）输出：
# +-------+------+----------+----------+------------+--------------------------------------+
# | db    | cnt  | avg_time | max_time | total_time | query_sample                         |
# +-------+------+----------+----------+------------+--------------------------------------+
# | shop  |  234 |    2.345 |    8.901 |    548.730 | SELECT * FROM orders WHERE user_id = | ← 大量慢查询！
# | shop  |   56 |    1.234 |    3.456 |     69.104 | SELECT o.*, u.name FROM orders o JOI |
# | shop  |   12 |    0.567 |    1.234 |      6.804 | INSERT INTO logs (action, details) V |
# +-------+------+----------+----------+------------+--------------------------------------+
```

#### 执行计划对比

```bash
# 查看有问题的查询的执行计划
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  EXPLAIN ANALYZE
  SELECT * FROM orders WHERE user_id = 'user_12345';
"

# 集群 A（健康，有索引）：
# +-------------------------------------------------------------------------+
# | EXPLAIN                                                                 |
# +-------------------------------------------------------------------------+
# | -> Index lookup on orders using idx_user_id (user_id='user_12345')  (cost=1.1 rows=5) (actual time=0.234..0.456 rows=3 loops=1)
# +-------------------------------------------------------------------------+
# ← 使用了 idx_user_id 索引，cost=1.1，实际时间 0.2-0.4ms

# 集群 B（问题，缺少索引）：
# +-------------------------------------------------------------------------+
# | EXPLAIN                                                                 |
# +-------------------------------------------------------------------------+
# | -> Filter: (orders.user_id = 'user_12345')  (cost=12345 rows=1) (actual time=2345.678..5678.901 rows=3 loops=1)
# |     -> Table scan on orders  (cost=12345 rows=5000000) (actual time=0.123..4567.890 rows=5000000 loops=1)
# +-------------------------------------------------------------------------+
# ← 全表扫描！cost=12345，实际时间 2.3-5.6 秒，扫描了 500万行！
```

#### 修复：添加索引

```bash
# 添加缺失的索引
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  ALTER TABLE orders ADD INDEX idx_user_id (user_id);
"

# 验证索引创建
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SHOW INDEX FROM orders;
"
# 预期输出：
# +--------+------------+--------------+--------------+-------------+
# | Table  | Key_name   | Seq_in_index | Column_name  | Cardinality |
# +--------+------------+--------------+--------------+-------------+
# | orders | PRIMARY    |            1 | id           |     5000000 |
# | orders | idx_user_id|            1 | user_id      |       50000 |
# +--------+------------+--------------+--------------+-------------+

# 再次测试查询时间
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SELECT BENCHMARK(100, (
    SELECT * FROM orders WHERE user_id = 'user_12345'
  ));
"
# 预期：从 2.3 秒降到 0.2 秒
```

---

### 3. 锁竞争排查

#### 查看当前锁等待

```bash
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SELECT 
    r.trx_id waiting_trx_id,
    r.trx_mysql_thread_id waiting_thread,
    LEFT(r.trx_query, 80) waiting_query,
    b.trx_id blocking_trx_id,
    b.trx_mysql_thread_id blocking_thread,
    LEFT(b.trx_query, 80) blocking_query,
    w.waiting_lock_id,
    w.blocking_lock_id,
    TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) wait_seconds
  FROM information_schema.innodb_lock_waits w
  INNER JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
  INNER JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id
  WHERE TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) > 5
  LIMIT 10;
"

# 典型输出（锁等待）：
# +----------------+------------------+-----------------------------------+----------------+------------------+-----------------------------------+------------------+------------------+-------------+
# | waiting_trx_id | waiting_thread   | waiting_query                     | blocking_trx_id| blocking_thread  | blocking_query                    | waiting_lock_id  | blocking_lock_id | wait_seconds|
# +----------------+------------------+-----------------------------------+----------------+------------------+-----------------------------------+------------------+------------------+-------------+
# | 1234567890     |              234 | UPDATE inventory SET stock=stock-1| 9876543210     |              567 | UPDATE inventory SET stock=stock-1| 1234:2345:5:123  | 9876:5432:5:123  |          15 |
# +----------------+------------------+-----------------------------------+----------------+------------------+-----------------------------------+------------------+------------------+-------------+
# ← 两个事务同时更新同一行库存，已等待 15 秒！
```

#### 锁等待时间统计

```bash
kubectl exec -it <mysql-pod> -- mysql -uroot -p -e "
  SELECT 
    EVENT_NAME,
    COUNT_STAR,
    ROUND(SUM_TIMER_WAIT/1000000000000, 3) as total_wait_sec,
    ROUND(AVG_TIMER_WAIT/1000000000000, 6) as avg_wait_sec,
    ROUND(MAX_TIMER_WAIT/1000000000000, 3) as max_wait_sec
  FROM performance_schema.events_waits_summary_global_by_event_name
  WHERE EVENT_NAME LIKE '%lock%'
    AND COUNT_STAR > 0
  ORDER BY SUM_TIMER_WAIT DESC
  LIMIT 10;
"

# 集群 A（健康）：
# +------------------------------------------+------------+----------------+--------------+--------------+
# | EVENT_NAME                               | COUNT_STAR | total_wait_sec | avg_wait_sec | max_wait_sec |
# +------------------------------------------+------------+----------------+--------------+--------------+
# | wait/synch/mutex/innodb/buf_pool_mutex   |   12345678 |          2.340 |   0.000000   |        0.001 |
# | wait/synch/rwlock/innodb/dict_operation_ |    5678901 |          1.230 |   0.000000   |        0.001 |
# +------------------------------------------+------------+----------------+--------------+--------------+

# 集群 B（问题）：
# +------------------------------------------+------------+----------------+--------------+--------------+
# | EVENT_NAME                               | COUNT_STAR | total_wait_sec | avg_wait_sec | max_wait_sec |
# +------------------------------------------+------------+----------------+--------------+--------------+
# | wait/synch/cond/innodb/row_lock_waits    |      12345 |        234.560 |   0.019000   |       15.678 |
# | wait/synch/mutex/innodb/trx_mutex        |    5678901 |         45.670 |   0.000008   |        0.234 |
# +------------------------------------------+------------+----------------+--------------+--------------+
# ← row_lock_waits 总等待 234 秒，最大等待 15.6 秒！
```

---

## Redis 排查

### 1. 延迟基准测试

```bash
# 在应用 Pod 中测试 Redis 延迟
kubectl exec -it <app-pod> -- /bin/sh -c '
  for i in $(seq 1 10); do
    START=$(date +%s%N)
    redis-cli -h redis -p 6379 PING >/dev/null 2>&1
    END=$(date +%s%N)
    echo "PING $i: $(( (END - START) / 1000000 ))ms"
  done
'

# 集群 A（健康，同 AZ）输出：
# PING 1: 0ms
# PING 2: 0ms
# PING 3: 1ms
# PING 4: 0ms
# PING 5: 0ms
# PING 6: 1ms
# PING 7: 0ms
# PING 8: 0ms
# PING 9: 0ms
# PING 10: 0ms
# 平均：0.2ms

# 集群 B（问题，跨 AZ）输出：
# PING 1: 12ms
# PING 2: 15ms
# PING 3: 8ms
# PING 4: 23ms
# PING 5: 11ms
# PING 6: 45ms  ← 抖动大
# PING 7: 14ms
# PING 8: 9ms
# PING 9: 18ms
# PING 10: 16ms
# 平均：17.1ms ← 比 A 慢 85 倍！
```

### 2. 慢命令排查

```bash
# 查看慢查询日志
kubectl exec -it <redis-pod> -- redis-cli SLOWLOG GET 10

# 集群 A（健康）输出：
# 1) 1) (integer) 123
#    2) (integer) 1705327412    # 时间戳
#    3) (integer) 15000          # 耗时 15ms
#    4) 1) "KEYS"                # 命令
#       2) "user:*"              # 参数
#    5) "10.244.0.5:54321"       # 客户端
# 只有 1 条慢查询，且是 KEYS（已知问题命令）

# 集群 B（问题）输出：
# 1) 1) (integer) 456
#    2) (integer) 1705327412
#    3) (integer) 234567        # 耗时 234ms！
#    4) 1) "HGETALL"
#       2) "big:hash:user:001"
# 2) 1) (integer) 455
#    2) (integer) 1705327410
#    3) (integer) 189234        # 耗时 189ms
#    4) 1) "LRANGE"
#       2) "big:list:events"
#       3) "0"
#       4) "-1"
# 大量慢查询，且都是大 key 操作！
```

### 3. 大 key 扫描

```bash
# 扫描大 key
kubectl exec -it <redis-pod> -- redis-cli --bigkeys

# 输出示例：
# # Scanning the entire keyspace to find biggest keys as well as
# # average sizes per key type.
# 
# -------- summary -------
# Sampled 100000 keys in the keyspace!
# Total key length in bytes is 1234567 (avg len 12.35)
# 
# Biggest string found 'session:abc123' has 1048576 bytes (1MB)
# Biggest   hash found 'big:hash:user:001' has 52428800 bytes (50MB) ← 大 key！
# Biggest    list found 'big:list:events' has 10000 items             ← 大 list！
# Biggest    zset found 'leaderboard:global' has 500000 items
# 
# 0 strings with 0 bytes (00.00% of keys, avg size 0 bytes)
# 50000 hashes with 5242880000 bytes (50.00% of keys, avg size 104857 bytes)
# 30000 lists with 123456789 bytes (30.00% of keys, avg size 4115 bytes)
```

### 4. 内存碎片与配置

```bash
kubectl exec -it <redis-pod> -- redis-cli INFO memory

# 集群 A（健康）：
# # Memory
# used_memory:8589934592
# used_memory_human:8.00G
# used_memory_rss:10737418240
# used_memory_rss_human:10.00G
# used_memory_peak:10737418240
# used_memory_peak_human:10.00G
# mem_fragmentation_ratio:1.25       ← 正常（1.0-1.5）
# mem_allocator:jemalloc-5.2.1

# 集群 B（碎片严重）：
# # Memory
# used_memory:4294967296
# used_memory_human:4.00G
# used_memory_rss:12884901888
# used_memory_rss_human:12.00G
# mem_fragmentation_ratio:3.00       ← 严重碎片（>2.0）
# ← 实际用了 4G，但 RSS 占用了 12G！
```

---

## Kafka 排查

### 生产者延迟测试

```bash
# 测试生产者延迟
kubectl exec -it <kafka-pod> -- kafka-producer-perf-test \
  --topic test-topic \
  --num-records 100000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props \
    bootstrap.servers=localhost:9092 \
    acks=all \
    linger.ms=5 \
    batch.size=32768

# 集群 A（健康）输出：
# 100000 records sent, 23456.789 records/sec (22.91 MB/sec), 
# 2.34 ms avg latency, 12.34 ms max latency, 
# 1 ms 50th, 3 ms 95th, 8 ms 99th, 11 ms 99.9th.

# 集群 B（问题）输出：
# 100000 records sent, 5678.123 records/sec (5.54 MB/sec), 
# 45.67 ms avg latency, 234.56 ms max latency,
# 12 ms 50th, 89 ms 95th, 156 ms 99th, 223 ms 99.9th.
# ← 吞吐量只有 A 的 24%，P99 延迟 156ms！
```

### 消费者 Lag 排查

```bash
kubectl exec -it <kafka-pod> -- kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group order-consumer-group

# 集群 A（健康）输出：
# TOPIC     PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG    CONSUMER-ID
# orders    0          1000000         1000010         10     consumer-1
# orders    1          2000000         2000005         5      consumer-2
# orders    2          3000000         3000003         3      consumer-3
# ← lag 很小，消费跟上生产

# 集群 B（问题）输出：
# TOPIC     PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG    CONSUMER-ID
# orders    0          1000000         1005000         5000   consumer-1
# orders    1          2000000         2012000         12000  consumer-2
# orders    2          3000000         3008000         8000   consumer-3
# ← lag 持续增大，消费跟不上生产！
```

---

## 自动化诊断脚本

```bash
#!/bin/bash
# middleware-health-check.sh
# 在应用 Pod 内执行

REDIS_HOST=${REDIS_HOST:-redis}
DB_HOST=${DB_HOST:-mysql}
DB_PORT=${DB_PORT:-3306}
DB_PASS=${DB_PASS:-root123}

echo "=========================================="
echo "  中间件健康检查"
echo "=========================================="

echo ""
echo "=== 1. Redis 延迟测试 ==="
for i in $(seq 1 5); do
  START=$(date +%s%N)
  redis-cli -h $REDIS_HOST PING >/dev/null 2>&1
  END=$(date +%s%N)
  echo "  PING $i: $(( (END - START) / 1000000 ))ms"
done

echo ""
echo "=== 2. Redis 慢查询数量 ==="
SLOWLOG_LEN=$(redis-cli -h $REDIS_HOST SLOWLOG LEN 2>/dev/null || echo 0)
echo "  慢查询数量: $SLOWLOG_LEN"
if [ "$SLOWLOG_LEN" -gt 10 ]; then
  echo "  ⚠️  警告：慢查询数量过多"
fi

echo ""
echo "=== 3. MySQL 连接时间 ==="
START=$(date +%s%N)
mysql -h $DB_HOST -P $DB_PORT -u root -p$DB_PASS -e "SELECT 1;" >/dev/null 2>&1
END=$(date +%s%N)
echo "  连接时间: $(( (END - START) / 1000000 ))ms"

echo ""
echo "=== 4. MySQL 活跃连接 ==="
mysql -h $DB_HOST -P $DB_PORT -u root -p$DB_PASS -e "
  SELECT 
    COUNT(*) as total,
    SUM(CASE WHEN Command = 'Sleep' THEN 1 ELSE 0 END) as sleeping,
    SUM(CASE WHEN Command != 'Sleep' THEN 1 ELSE 0 END) as active
  FROM information_schema.processlist;
" 2>/dev/null

echo ""
echo "=== 5. MySQL 锁等待 ==="
LOCK_WAIT=$(mysql -h $DB_HOST -P $DB_PORT -u root -p$DB_PASS -e "
  SELECT COUNT(*) FROM information_schema.innodb_lock_waits;
" 2>/dev/null | tail -1)
echo "  当前锁等待: $LOCK_WAIT"
if [ "$LOCK_WAIT" -gt 0 ]; then
  echo "  ⚠️  警告：存在锁等待"
fi

echo ""
echo "=== 6. DNS 解析时间 ==="
START=$(date +%s%N)
nslookup $DB_HOST >/dev/null 2>&1
END=$(date +%s%N)
echo "  DNS解析: $(( (END - START) / 1000000 ))ms"

echo ""
echo "=== 7. TCP 连接时间 ==="
START=$(date +%s%N)
timeout 5 bash -c "exec 3<>/dev/tcp/$DB_HOST/$DB_PORT" 2>/dev/null
END=$(date +%s%N)
if [ $? -eq 0 ]; then
  echo "  TCP连接: $(( (END - START) / 1000000 ))ms"
else
  echo "  TCP连接: 超时"
fi

echo ""
echo "=========================================="
```

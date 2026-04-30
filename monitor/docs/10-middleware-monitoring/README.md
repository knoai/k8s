# 中间件监控实战

> 生产环境中，中间件（Redis、Kafka、MySQL）是系统的核心依赖，其健康度直接影响业务可用性。本节提供主流中间件的监控方案。

---

## 1. Redis 监控

### 1.1 核心指标

| 类别 | 指标 | PromQL | 告警阈值 |
|------|------|--------|----------|
| **性能** | 内存使用率 | `redis_memory_used_bytes / redis_memory_max_bytes` | > 80% |
| **性能** | 连接数 | `redis_connected_clients` | > 10000 |
| **性能** | 命令速率 | `rate(redis_commands_processed_total[5m])` | 突增/骤降 |
| **性能** | 缓存命中率 | `redis_keyspace_hits_total / (redis_keyspace_hits_total + redis_keyspace_misses_total)` | < 90% |
| **性能** | 慢查询数 | `redis_slowlog_length` | > 100 |
| **可用性** | 主从延迟 | `redis_repl_backlog_first_byte_offset` | 持续增大 |
| **可用性** | 持久化状态 | `redis_rdb_last_bgsave_status` | != 0 |

### 1.2 部署 Redis Exporter

```yaml
# redis-exporter.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-exporter
  template:
    metadata:
      labels:
        app: redis-exporter
    spec:
      containers:
        - name: exporter
          image: oliver006/redis_exporter:v1.55.0
          env:
            - name: REDIS_ADDR
              value: "redis://redis:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-secret
                  key: password
          ports:
            - containerPort: 9121
              name: metrics
---
apiVersion: v1
kind: Service
metadata:
  name: redis-exporter
  namespace: monitoring
  labels:
    app: redis-exporter
spec:
  selector:
    app: redis-exporter
  ports:
    - port: 9121
      targetPort: 9121
      name: metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-metrics
  namespace: monitoring
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: redis-exporter
  endpoints:
    - port: metrics
      interval: 15s
```

### 1.3 Redis 告警规则

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: redis-alerts
  namespace: monitoring
spec:
  groups:
    - name: redis
      rules:
        - alert: RedisMemoryHigh
          expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.8
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Redis 内存使用率过高"
            description: "当前使用率: {{ $value | humanizePercentage }}"

        - alert: RedisConnectionsHigh
          expr: redis_connected_clients > 10000
          for: 5m
          labels:
            severity: warning

        - alert: RedisCacheHitRateLow
          expr: |
            rate(redis_keyspace_hits_total[5m]) 
            / 
            (rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m])) < 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Redis 缓存命中率过低"

        - alert: RedisMasterLinkDown
          expr: redis_master_link_up == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Redis 主从连接断开"
```

---

## 2. Kafka 监控

### 2.1 核心指标

| 类别 | 指标 | 说明 |
|------|------|------|
| **Broker** | `kafka_server_brokertopicmetrics_messagesin_total` | 消息写入速率 |
| **Broker** | `kafka_server_brokertopicmetrics_bytesin_total` | 写入字节速率 |
| **Broker** | `kafka_server_brokertopicmetrics_bytesout_total` | 读取字节速率 |
| **Consumer** | `kafka_consumer_lag` | 消费延迟（关键！）|
| **Consumer** | `kafka_consumer_records_consumed_rate` | 消费速率 |
| **Topic** | `kafka_topic_partition_current_offset` | 当前 offset |
| **Cluster** | `kafka_controller_activecontroller_count` | Active Controller 数（必须为 1）|
| **Cluster** | `kafka_server_replica_manager_underreplicated_partitions` | 未复制分区数 |

### 2.2 部署 Kafka Exporter

```yaml
# kafka-exporter.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka-exporter
  template:
    metadata:
      labels:
        app: kafka-exporter
    spec:
      containers:
        - name: exporter
          image: danielqsj/kafka-exporter:v1.7.0
          args:
            - --kafka.server=kafka:9092
            - --topic.filter=.*
            - --group.filter=.*
          ports:
            - containerPort: 9308
              name: metrics
---
# Service + ServiceMonitor 省略（同 Redis 模式）
```

### 2.3 Kafka 消费延迟告警

```yaml
- alert: KafkaConsumerLagHigh
  expr: kafka_consumer_group_lag > 10000
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Kafka 消费延迟过高: {{ $labels.topic }}"
    description: "Consumer Group: {{ $labels.group }}, Lag: {{ $value }}"

- alert: KafkaNoActiveController
  expr: kafka_controller_kafkacontroller_activecontrollercount != 1
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Kafka 集群无 Active Controller"

- alert: KafkaUnderReplicatedPartitions
  expr: kafka_server_replica_manager_under_replicated_partitions > 0
  for: 5m
  labels:
    severity: critical
```

---

## 3. MySQL 监控

### 3.1 核心指标

| 类别 | 指标 | PromQL |
|------|------|--------|
| **连接** | 活跃连接数 | `mysql_global_status_threads_connected` |
| **连接** | 最大连接使用率 | `mysql_global_status_threads_connected / mysql_global_variables_max_connections` |
| **查询** | 慢查询数 | `mysql_global_status_slow_queries` |
| **查询** | QPS | `rate(mysql_global_status_queries[5m])` |
| **复制** | 主从延迟 | `mysql_slave_lag_seconds` |
| **存储** | 表空间使用率 | 自定义查询 |
| **InnoDB** | Buffer Pool 命中率 | `mysql_global_status_innodb_buffer_pool_read_requests / (mysql_global_status_innodb_buffer_pool_read_requests + mysql_global_status_innodb_buffer_pool_reads)` |

### 3.2 部署 MySQL Exporter

```yaml
# mysql-exporter.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql-exporter
  template:
    metadata:
      labels:
        app: mysql-exporter
    spec:
      containers:
        - name: exporter
          image: prom/mysqld-exporter:v0.15.0
          env:
            - name: DATA_SOURCE_NAME
              valueFrom:
                secretKeyRef:
                  name: mysql-exporter-secret
                  key: dsn  # user:password@(mysql:3306)/
          ports:
            - containerPort: 9104
              name: metrics
```

### 3.3 MySQL 告警规则

```yaml
- alert: MySQLConnectionsHigh
  expr: |
    mysql_global_status_threads_connected 
    / 
    mysql_global_variables_max_connections > 0.8
  for: 5m
  labels:
    severity: warning

- alert: MySQLSlowQueriesHigh
  expr: rate(mysql_global_status_slow_queries[5m]) > 1
  for: 5m
  labels:
    severity: warning

- alert: MySQLReplicationLag
  expr: mysql_slave_lag_seconds > 10
  for: 5m
  labels:
    severity: critical

- alert: MySQLBufferPoolHitRateLow
  expr: |
    mysql_global_status_innodb_buffer_pool_read_requests 
    / 
    (mysql_global_status_innodb_buffer_pool_read_requests + mysql_global_status_innodb_buffer_pool_reads) < 0.95
  for: 10m
  labels:
    severity: warning
```

---

## 4. PostgreSQL 监控

### 4.1 核心指标

| 指标 | 说明 |
|------|------|
| `pg_stat_activity_count` | 活跃连接数 |
| `pg_stat_database_xact_commit` | 事务提交率 |
| `pg_stat_database_xact_rollback` | 事务回滚率 |
| `pg_stat_database_blks_hit` | Buffer 命中 |
| `pg_replication_lag` | 复制延迟 |
| `pg_stat_user_tables_seq_scan` | 全表扫描次数 |

### 4.2 部署 Postgres Exporter

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-exporter
  namespace: monitoring
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: exporter
          image: prometheuscommunity/postgres-exporter:v0.15.0
          env:
            - name: DATA_SOURCE_NAME
              value: "postgresql://user:password@postgres:5432/postgres?sslmode=disable"
          ports:
            - containerPort: 9187
```

---

## 5. Elasticsearch 监控

### 5.1 核心指标

| 指标 | 说明 | 告警阈值 |
|------|------|----------|
| `elasticsearch_cluster_health_status` | 集群状态 | != 1 (green) |
| `elasticsearch_jvm_memory_used_bytes` | JVM 内存 | > 85% |
| `elasticsearch_indices_store_size_bytes` | 索引大小 | 持续增长 |
| `elasticsearch_cluster_health_unassigned_shards` | 未分配分片 | > 0 |
| `elasticsearch_indices_indexing_rate` | 索引速率 | 骤降 |

### 5.2 部署

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elasticsearch-exporter
  namespace: monitoring
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: exporter
          image: quay.io/prometheuscommunity/elasticsearch-exporter:v1.6.0
          args:
            - --es.uri=http://elasticsearch:9200
          ports:
            - containerPort: 9114
```

---

## 6. MongoDB 监控

### 6.1 核心指标

| 指标 | 说明 |
|------|------|
| `mongodb_connections{state="current"}` | 当前连接数 |
| `mongodb_op_latencies_reads_avg` | 读延迟 |
| `mongodb_op_latencies_writes_avg` | 写延迟 |
| `mongodb_mongod_replset_member_replication_lag` | 复制延迟 |

### 6.2 部署

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb-exporter
  namespace: monitoring
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: exporter
          image: percona/mongodb_exporter:0.40
          args:
            - --mongodb.uri=mongodb://user:password@mongodb:27017
            - --discovering-mode
          ports:
            - containerPort: 9216
```

---

## 7. 中间件统一告警模板

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: middleware-alerts
  namespace: monitoring
spec:
  groups:
    - name: middleware-common
      rules:
        # 通用：Exporter 宕机
        - alert: MiddlewareExporterDown
          expr: up{job=~"redis-exporter|kafka-exporter|mysql-exporter|postgres-exporter"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "中间件 Exporter 宕机: {{ $labels.job }}"

        # 通用：连接数过高
        - alert: MiddlewareConnectionsHigh
          expr: |
            (
              redis_connected_clients > 10000
              or
              mysql_global_status_threads_connected > 1000
              or
              pg_stat_activity_count > 500
            )
          for: 5m
          labels:
            severity: warning
```

---

## 8. Dashboard ID 速查

| 中间件 | Dashboard ID | 名称 |
|--------|-------------|------|
| Redis | 763 | Redis Dashboard |
| Kafka | 7589 | Kafka Overview |
| MySQL | 7362 | MySQL Overview |
| PostgreSQL | 9628 | PostgreSQL Database |
| Elasticsearch | 266 | Elasticsearch |
| MongoDB | 2583 | MongoDB Overview |

---

## 参考

- [Redis Exporter](https://github.com/oliver006/redis_exporter)
- [Kafka Exporter](https://github.com/danielqsj/kafka_exporter)
- [MySQL Exporter](https://github.com/prometheus/mysqld_exporter)
- [PostgreSQL Exporter](https://github.com/prometheus-community/postgres_exporter)

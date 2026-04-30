# 可观测性治理规范

> 生产环境中，缺乏统一规范会导致监控数据混乱、Dashboard 难以维护、告警噪音大。本规范适用于团队级可观测性体系建设。

---

## 1. 指标命名规范

### 1.1 通用规则

```
<domain>_<entity>_<metric>_<unit>
```

| 部分 | 说明 | 示例 |
|------|------|------|
| `domain` | 业务域/系统名 | `order`、`payment`、`infra` |
| `entity` | 被测量对象 | `http`、`db`、`cache`、`jvm` |
| `metric` | 指标类型 | `requests`、`latency`、`errors` |
| `unit` | 单位/聚合方式 | `total`、`seconds`、`bytes` |

**正确示例**：
```
order_http_requests_total          # 订单服务 HTTP 请求总数
payment_db_query_duration_seconds  # 支付服务 DB 查询耗时
cache_redis_hits_total             # Redis 缓存命中数
infra_node_cpu_usage_ratio         # 节点 CPU 使用率
```

**错误示例**：
```
order-api-qps                       # ❌ 缩写，无后缀
cpu_percent                         # ❌ 无 domain，percent 不是单位
httpRequestCount                    # ❌ 驼峰命名
request_latency_ms                  # ❌ ms 不是标准单位（用 seconds）
```

### 1.2 单位规范

| 度量 | 标准单位 | 说明 |
|------|----------|------|
| 时间 | `seconds` | 浮点数，不要用 ms/us |
| 字节 | `bytes` | 整数 |
| 比率 | `ratio` | 0-1 浮点数 |
| 计数 | `total` | Counter 后缀 |
| 数量 | `count` | Gauge 数量 |
| 温度 | `celsius` | 摄氏度 |

### 1.3 指标类型后缀

| 类型 | 后缀 | 示例 |
|------|------|------|
| Counter | `_total` | `http_requests_total` |
| Gauge | 无后缀或 `_count` | `memory_used_bytes` |
| Histogram | `_seconds_bucket` | `http_duration_seconds_bucket` |
| Summary | `_seconds` | `http_duration_seconds` |

---

## 2. 标签（Label）规范

### 2.1 通用标签（所有指标必须携带）

```yaml
# K8s 通用标签
k8s_cluster: production-bj    # 集群名
k8s_namespace: order-service  # 命名空间
k8s_pod: order-svc-7d8f9-x1a2 # Pod 名
k8s_node: worker-01           # 节点名

# 应用通用标签
service_name: order-service   # 服务名
service_version: v1.2.0       # 版本号
deployment_environment: production  # 环境

# 团队/业务标签
team: backend                 # 负责团队
business_domain: ecommerce    # 业务域
cost_center: cc-12345         # 成本中心（FinOps）
```

### 2.2 禁止作为 Label 的字段

| 禁止字段 | 原因 | 替代方案 |
|----------|------|----------|
| `user_id` | 高基数 | 放到 Trace/Log 中 |
| `email` | 高基数 + PII | 脱敏后放 Log |
| `session_id` | 高基数 | 放到 Trace 中 |
| `client_ip` | 高基数 | 按段聚合：`10.0.x.x` |
| `request_path`（含ID） | 高基数 | 归一化：`/api/users/{id}` |
| `timestamp` | 无意义 | 指标自带时间戳 |

### 2.3 标签归一化

```go
// ❌ 原始路径
"/api/users/12345/orders/67890"

// ✅ 归一化后
"/api/users/{user_id}/orders/{order_id}"

// 实现方式
func normalizePath(path string) string {
    re := regexp.MustCompile(`/\d+`)
    return re.ReplaceAllString(path, "/{id}")
}
```

---

## 3. Dashboard 规范

### 3.1 命名规范

```
[<环境>] <系统/服务> - <用途>
```

| 示例 | 说明 |
|------|------|
| `[Prod] K8s Cluster Overview` | 生产环境 K8s 集群概览 |
| `[Prod] Order Service - RED Metrics` | 生产环境订单服务黄金指标 |
| `[Prod] JVM - Memory & GC` | 生产环境 JVM 内存与 GC |

### 3.2 Dashboard 分层设计

| 层级 | 受众 | 刷新间隔 | 内容 |
|------|------|----------|------|
| **L0 全局概览** | 管理层 | 5m | SLA、核心业务 KPI、成本 |
| **L1 系统概览** | SRE/运维 | 30s | 集群资源、K8s 状态 |
| **L2 服务监控** | 开发团队 | 30s | RED 指标、依赖拓扑 |
| **L3 组件监控** | 开发团队 | 15s | JVM、DB、Cache 详细指标 |
| **L4 业务监控** | 产品/运营 | 1m | 业务漏斗、转化率 |

### 3.3 面板规范

```
每行最多 4 个面板
每个面板必须有：标题、单位、描述
颜色规范：
  - 正常：绿色
  - 警告：黄色
  - 严重：红色
  - 信息：蓝色
```

### 3.4 变量规范

```
$cluster    # 集群选择
$namespace  # 命名空间
$service    # 服务名
$pod        # Pod 名（联动）
$interval   # 时间间隔
```

---

## 4. 告警规范

### 4.1 告警命名

```
[<系统>] <症状> [<阈值>]
```

| 示例 | 说明 |
|------|------|
| `[Order] High Error Rate [>5%]` | 订单服务错误率过高 |
| `[K8s] Node Disk Full [<10%]` | K8s 节点磁盘空间不足 |
| `[JVM] Heap Usage High [>85%]` | JVM 堆内存使用率过高 |

### 4.2 告警分级

| 级别 | 响应时间 | 通知方式 | 升级策略 |
|------|----------|----------|----------|
| **P0** | 5 分钟 | 电话+短信+IM | 15 分钟未处理升级 Manager |
| **P1** | 15 分钟 | 电话+IM | 30 分钟未处理升级 Director |
| **P2** | 30 分钟 | IM+邮件 | 1 小时未处理升级 VP |
| **P3** | 2 小时 | 邮件/IM | 次日处理 |
| **P4** | 次日 | 周报汇总 | 无 |

### 4.3 告警描述模板

```yaml
annotations:
  summary: "[{{ $labels.service }}] {{ $labels.alertname }}"
  description: |
    **影响服务**: {{ $labels.service }}
    **实例**: {{ $labels.instance }}
    **当前值**: {{ $value | humanize }}
    **阈值**: {{ $labels.threshold }}
    
    **排查步骤**:
    1. 查看 Grafana 面板: https://grafana/d/{{ $labels.service }}
    2. 查看 Trace: https://grafana/explore?traceId={{ $labels.trace_id }}
    3. 查看日志: https://grafana/explore?datasource=loki&query={{ $labels.pod }}
    
    **Runbook**: https://wiki/runbooks/{{ $labels.alertname }}
    **On-call**: @sre-oncall
```

### 4.4 告警治理 checklist

- [ ] 所有告警必须有 Runbook 链接
- [ ] 所有告警必须有明确的处理人/团队
- [ ] 告警触发后 24 小时内必须处理或调整阈值
- [ ] 每月回顾告警，关闭无效告警
- [ ] 告警数量人均不超过 5 条/天（P1 以上）

---

## 5. 日志规范

### 5.1 日志级别使用

| 级别 | 使用场景 | 处理方式 |
|------|----------|----------|
| **DEBUG** | 调试信息 | 开发环境开启，生产关闭 |
| **INFO** | 正常业务流程 | 保留 3-7 天 |
| **WARN** | 非预期但可恢复 | 保留 7-30 天，关注趋势 |
| **ERROR** | 业务错误 | 保留 30-90 天，必须处理 |
| **FATAL** | 系统级错误 | 保留 90 天，立即处理 |

### 5.2 结构化日志格式

```json
{
  "timestamp": "2024-01-15T08:30:00.123Z",
  "level": "ERROR",
  "service": "order-service",
  "version": "v1.2.0",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "thread": "http-worker-3",
  "logger": "c.e.order.service.PaymentService",
  "message": "Failed to process payment",
  "context": {
    "order_id": "ORD-12345",
    "user_id": "U67890",
    "amount": 199.99,
    "currency": "CNY",
    "payment_method": "alipay"
  },
  "error": {
    "type": "PaymentTimeoutException",
    "message": "Payment gateway timeout after 30s",
    "stack_trace": "..."
  }
}
```

### 5.3 日志字段规范

| 字段 | 类型 | 必传 | 说明 |
|------|------|------|------|
| `timestamp` | string | ✅ | ISO 8601 格式 |
| `level` | string | ✅ | DEBUG/INFO/WARN/ERROR/FATAL |
| `service` | string | ✅ | 服务名 |
| `trace_id` | string | ✅ | 链路追踪 ID |
| `message` | string | ✅ | 日志消息 |
| `error.type` | string | ❌ | 错误类型（ERROR 级别必传）|
| `error.message` | string | ❌ | 错误描述 |
| `context.*` | object | ❌ | 业务上下文 |

---

## 6. 链路追踪规范

### 6.1 Span 命名规范

```
<操作类型>: <目标>
```

| 示例 | 说明 |
|------|------|
| `GET /api/orders/{id}` | HTTP 接口 |
| `SELECT orders` | SQL 查询 |
| `GET orders:12345` | Redis 读取 |
| `publish payment.success` | Kafka 消息发送 |

### 6.2 必须携带的属性

```yaml
# 基础属性
service.name: order-service
service.version: v1.2.0
deployment.environment: production

# HTTP 属性
http.method: GET
http.route: /api/orders/{id}
http.status_code: 200
http.request_content_length: 1024

# 数据库属性
db.system: mysql
db.statement: SELECT * FROM orders WHERE id = ?
db.operation: SELECT

# 消息队列属性
messaging.system: kafka
messaging.destination: payment.success
messaging.operation: publish
```

---

## 7. 成本治理（FinOps）

### 7.1 成本标签

```yaml
# 所有监控资源必须携带
cost_center: cc-12345
environment: production
project: ecommerce-platform
owner: backend-team
```

### 7.2 成本控制策略

| 策略 | 实施方式 |
|------|----------|
| **采样控制** | Traces 10% 采样，Logs INFO 级别以下丢弃 |
| **保留周期** | Metrics 15天，Logs 7天，Traces 3天 |
| **数据降采样** | 历史数据 5m/1h 聚合后删除原始点 |
| **资源限制** | Collector CPU < 1核，内存 < 1Gi |
| **数据压缩** | 使用 VictoriaMetrics（7x 压缩）|

---

## 8. 安全合规

### 8.1 数据脱敏

```yaml
# OTel Collector Processor 配置
processors:
  attributes:
    actions:
      # 删除敏感字段
      - key: http.request.header.authorization
        action: delete
      - key: http.request.header.cookie
        action: delete
      - key: db.statement
        action: hash  # SQL 脱敏
      - key: email
        action: hash
      - key: phone_number
        action: hash
      - key: id_card
        action: delete
```

### 8.2 访问控制

```yaml
# Prometheus RBAC
# 只读访问，禁止 admin API
# Grafana OAuth2 + RBAC
# Loki 按 namespace 隔离
```

---

## 参考

- [Prometheus Naming Best Practices](https://prometheus.io/docs/practices/naming/)
- [OpenTelemetry Semantic Conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/)
- [Google SRE - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)

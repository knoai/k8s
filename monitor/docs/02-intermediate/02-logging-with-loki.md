# Loki 日志系统指南

## 1. Loki 概述

Loki 是由 Grafana Labs 开发的开源日志聚合系统，专为与 Grafana 配合使用而设计。与 Elasticsearch 不同，Loki 只索引日志的标签，而不索引完整的日志内容，因此更加轻量、成本更低。

### 1.1 Loki 架构

```
┌─────────────────────────────────────────────────────────────┐
│                        Grafana                              │
└─────────────────────────┬───────────────────────────────────┘
                          │ LogQL
┌─────────────────────────▼───────────────────────────────────┐
│                        Loki                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   Distributor │  │    Ingester  │  │   Querier    │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Object Storage (S3/GCS)                  │  │
│  │         chunks (日志内容) + index (标签索引)            │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Loki vs Elasticsearch

| 特性 | Loki | Elasticsearch |
|------|------|---------------|
| 索引方式 | 只索引标签 | 全文索引 |
| 存储成本 | 低（约为 ES 的 1/10） | 高 |
| 查询语言 | LogQL | Lucene |
| 与 Grafana 集成 | 原生深度集成 | 一般 |
| 适用场景 | 结构化日志、标签过滤 | 全文搜索、复杂分析 |

---

## 2. LogQL 查询语言

### 2.1 基础查询

```logql
# 选择所有带有 app="grafana" 标签的日志
{app="grafana"}

# 多标签过滤
{app="nginx", env="production"}

# 正则匹配
{app=~"nginx|apache"}
{env!~"dev|test"}
```

### 2.2 行过滤

```logql
# 包含字符串
{app="nginx"} |= "error"

# 不包含字符串
{app="nginx"} != "healthcheck"

# 正则匹配
{app="nginx"} |~ "error|ERROR|Error"
{app="nginx"} !~ "debug|DEBUG"

# 解析 JSON 后过滤
{app="api"} | json | level="error"
```

### 2.3 解析器

```logql
# JSON 解析
{app="api"} | json
{app="api"} | json message="msg", status_code="status"

# Logfmt 解析
{app="api"} | logfmt

# Pattern 解析
{app="nginx"} | pattern `<ip> - - <_> "<method> <uri> <_>" <status> <size>`

# Regex 解析
{app="api"} | regexp "(?P<time>\\S+) (?P<level>\\S+) (?P<msg>.*)"
```

### 2.4 聚合查询

```logql
# 计数
sum(rate({app="nginx"}[1m]))

# 按级别分组计数
sum by (level) (rate({app="api"} | json | level="error" [1m]))

# TopK
 topk(10, sum by (path) (rate({app="nginx"} | json [1m])))
```

---

## 3. Kubernetes 日志采集

### 3.1 Promtail（Loki 官方 Agent）

```yaml
# promtail-config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    pipeline_stages:
      - docker: {}
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: __host__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_container_name]
        target_label: container
```

### 3.2 OpenTelemetry Collector 采集日志

```yaml
receivers:
  filelog:
    include: [/var/log/pods/*/*/*.log]
    operators:
      - type: json_parser
        timestamp:
          parse_from: attributes.time
          layout: '%Y-%m-%dT%H:%M:%S.%LZ'
      - type: severity_parser
        parse_from: attributes.level

exporters:
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    labels:
      attributes:
        k8s.pod.name: "pod"
        k8s.namespace.name: "namespace"
```

---

## 4. 日志结构化最佳实践

### 4.1 推荐日志格式

**JSON 结构化日志（推荐）**：
```json
{
  "timestamp": "2024-01-15T08:30:00.123Z",
  "level": "ERROR",
  "service": "order-service",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "message": "Failed to process payment",
  "error": "connection timeout",
  "duration_ms": 5230,
  "user_id": "12345",
  "order_id": "ORD-789"
}
```

### 4.2 日志级别规范

| 级别 | 使用场景 |
|------|----------|
| **DEBUG** | 调试信息，生产环境通常关闭 |
| **INFO** | 正常业务流程记录 |
| **WARN** | 非预期但可恢复的情况 |
| **ERROR** | 业务错误，需要关注 |
| **FATAL** | 系统级错误，需要立即处理 |

### 4.3 日志规范建议

1. **统一时间格式**：ISO 8601（`2024-01-15T08:30:00Z`）
2. **包含 TraceID**：便于关联链路追踪
3. **避免敏感信息**：不输出密码、token、身份证号
4. **使用结构化格式**：JSON 便于机器解析
5. **控制日志量**：避免循环中高频输出

---

## 5. Grafana 中查询日志

### 5.1 Explore 界面

1. 进入 Grafana → Explore
2. 选择 Loki 数据源
3. 使用 LogQL 查询日志
4. 点击日志行查看详情

### 5.2 常用查询场景

```logql
# 查看特定 Pod 的错误日志
{namespace="production", pod=~"order-service-.*"} |= "error"

# 查看特定 Trace 的所有日志
{namespace="production"} |= "trace_id=\"abc123\""

# 统计每分钟的错误数
sum(rate({namespace="production"} |= "error" [1m]))

# 查看某个服务的慢请求日志
{app="api"} | json | duration_ms > 5000
```

---

## 参考资源

- [Loki 官方文档](https://grafana.com/docs/loki/latest/)
- [LogQL 查询语法](https://grafana.com/docs/loki/latest/query/)
- [Promtail 配置指南](https://grafana.com/docs/loki/latest/clients/promtail/)

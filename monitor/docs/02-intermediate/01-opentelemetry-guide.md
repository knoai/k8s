# OpenTelemetry 中间指南

## 1. OpenTelemetry 概述

OpenTelemetry (OTel) 是一个开源的可观测性框架，提供统一的标准来采集、处理和导出 **Metrics（指标）**、**Logs（日志）** 和 **Traces（链路追踪）**。

### 1.1 为什么使用 OpenTelemetry

| 优势 | 说明 |
|------|------|
| **统一标准** | 一套 SDK/Collector 覆盖三种信号 |
| **厂商无关** | 不锁定任何后端（Prometheus、Jaeger、Loki 等） |
| **自动埋点** | 支持 Java、Python、Node.js、.NET 等语言的自动埋点 |
| **社区活跃** | CNCF 孵化项目，生态丰富 |

### 1.2 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenTelemetry SDK                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                  │
│  │  Metrics │  │   Logs   │  │  Traces  │                  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                  │
└───────┼─────────────┼─────────────┼────────────────────────┘
        │             │             │
        └─────────────┴─────────────┘
                      │ OTLP
        ┌─────────────▼─────────────┐
        │  OpenTelemetry Collector  │
        │  ┌────────┐ ┌──────────┐  │
        │  │Receive │ │ Process  │  │
        │  │ OTLP   │ │ Batch    │  │
        │  │Prometheus││ Filter   │  │
        │  │  Logs  │ │ Transform│  │
        │  └────┬───┘ └────┬─────┘  │
        │       └──────────┘        │
        │  ┌─────────────────────┐  │
        │  │       Export        │  │
        │  │ Prometheus / Loki   │  │
        │  │ Tempo / Jaeger      │  │
        │  └─────────────────────┘  │
        └─────────────────────────────┘
```

---

## 2. OpenTelemetry Collector

### 2.1 核心概念

Collector 由三个核心组件构成：

| 组件 | 说明 | 示例 |
|------|------|------|
| **Receivers** | 接收数据 | OTLP、Prometheus、File Log |
| **Processors** | 处理数据 | Batch、Filter、Tail Sampling |
| **Exporters** | 导出数据 | Prometheus、Loki、Tempo |

### 2.2 部署模式

| 模式 | 适用场景 | 说明 |
|------|----------|------|
| **Agent** | 节点级采集 | DaemonSet 部署，采集节点和本地 Pod 数据 |
| **Gateway** | 中心汇聚 | Deployment 部署，汇聚多个 Agent 数据，统一处理 |
| **Sidecar** | 单应用采集 | 与特定 Pod 一起部署 |

### 2.3 完整配置示例

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector'
          scrape_interval: 15s
          static_configs:
            - targets: ['0.0.0.0:8888']

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  
  memory_limiter:
    limit_mib: 1500
    spike_limit_mib: 512
    check_interval: 5s
  
  resource:
    attributes:
      - key: k8s.cluster.name
        value: production
        action: upsert

exporters:
  prometheusremotewrite:
    endpoint: http://prometheus:9090/api/v1/write
  
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true
  
  loki:
    endpoint: http://loki:3100/loki/api/v1/push

service:
  pipelines:
    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
    
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo]
    
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [loki]
```

---

## 3. 链路追踪（Traces）

### 3.1 核心概念

| 概念 | 说明 |
|------|------|
| **Trace** | 一次完整请求的调用链 |
| **Span** | Trace 中的一个操作单元 |
| **Span Context** | 包含 TraceID 和 SpanID，用于跨服务传递 |
| **Baggage** | 跨服务传递的键值对数据 |

### 3.2 上下文传播

```
┌──────────┐    traceparent header    ┌──────────┐    traceparent header    ┌──────────┐
│ Service A│ ────────────────────────▶│ Service B│ ────────────────────────▶│ Service C│
│ (前端)    │  TraceID: abc123         │ (网关)   │  TraceID: abc123         │ (业务)   │
│          │  SpanID: span-a          │          │  SpanID: span-b          │          │
└──────────┘                          └──────────┘                          └──────────┘
```

**W3C Trace Context 格式**：
```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
# 版本-TraceID(32位)-SpanID(16位)-标志位
```

### 3.3 采样策略

| 策略 | 说明 | 适用场景 |
|------|------|----------|
| **AlwaysOn** | 全部采样 | 开发/测试环境 |
| **AlwaysOff** | 全部丢弃 | 关闭追踪 |
| **TraceIdRatioBased** | 按比例随机采样 | 生产环境基础采样 |
| **ParentBased** | 跟随父 Span 决策 | 保持调用链完整性 |
| **Tail Sampling** | 尾部采样（Collector 层） | 保留错误/慢请求 |

**推荐配置（生产环境）**：
```yaml
# SDK 层：10% 头部采样
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1

# Collector 层：尾部采样保留错误
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow_requests
        type: latency
        latency: {threshold_ms: 500}
      - name: probabilistic
        type: probabilistic
        probabilistic: {sampling_percentage: 10}
```

---

## 4. 多信号关联

### 4.1 Trace + Logs 关联

在日志中注入 TraceID，实现从链路下钻到日志：

```json
{
  "timestamp": "2024-01-15T08:30:00Z",
  "severity": "ERROR",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "service.name": "order-service",
  "message": "Failed to connect to database"
}
```

**Java (Logback)**：
```xml
<appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
  <encoder>
    <pattern>%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - trace_id=%X{trace_id} span_id=%X{span_id} - %msg%n</pattern>
  </encoder>
</appender>
```

### 4.2 Trace + Metrics 关联

通过 Exemplars 在 Metrics 中关联 Trace：

```promql
# 查看 P99 延迟，并关联到具体 Trace
histogram_quantile(0.99, 
  sum(rate(http_server_duration_bucket[5m])) by (le)
)
```

### 4.3 关联的价值

```
告警触发 (Metrics) 
    ↓
查看异常指标趋势
    ↓
点击 Exemplar → 跳转到 Trace
    ↓
Trace 中查看每个 Span 的耗时和标签
    ↓
点击 Span → 查看该时间点的相关日志
    ↓
定位根因
```

---

## 5. 应用接入实践

### 5.1 Java 自动埋点

```bash
# 下载 OTel Java Agent
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.0.0/opentelemetry-javaagent.jar

# JVM 参数
java -javaagent:opentelemetry-javaagent.jar \
  -Dotel.service.name=my-service \
  -Dotel.exporter.otlp.endpoint=http://otel-collector:4317 \
  -jar my-app.jar
```

### 5.2 Go 手动埋点

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("my-service")

func processOrder(ctx context.Context, orderID string) {
    ctx, span := tracer.Start(ctx, "process-order")
    defer span.End()
    
    span.SetAttributes(
        attribute.String("order.id", orderID),
        attribute.Float64("order.amount", 99.99),
    )
    
    // 业务逻辑...
}
```

---

## 6. 生产最佳实践

### 6.1 数据质量与成本控制

| 策略 | 说明 |
|------|------|
| **采样** | 头部采样减少数据量 + 尾部采样保留关键链路 |
| **基数控制** | 限制高基数属性（如 user_id），使用租户或分组替代 |
| **数据脱敏** | Collector Processor 过滤敏感字段（token、密码） |
| **分级存储** | 热数据短期保留 + 冷数据长期归档 |

### 6.2 Collector 性能优化

```yaml
processors:
  # 批处理减少网络请求
  batch:
    timeout: 1s
    send_batch_size: 1024
    send_batch_max_size: 2048
  
  # 内存限制防止 OOM
  memory_limiter:
    limit_mib: 4000
    spike_limit_mib: 500
    check_interval: 5s
  
  # 过滤不必要的数据
  filter:
    metrics:
      metric:
        - 'name == "unwanted_metric"'
```

### 6.3 常见陷阱

| 陷阱 | 解决方案 |
|------|----------|
| 日志中缺少 trace_id | 确保日志框架从 Span Context 获取并输出 |
| 上下文传播断裂 | 验证网关、代理、异步调用均保留传播头 |
| 自定义属性过多 | 遵循语义约定，避免无控制的高基数 |
| 采样无目的 | 文档化采样目标，验证故障链路能被捕获 |

---

## 参考资源

- [OpenTelemetry 官方文档](https://opentelemetry.io/docs/)
- [OTel Collector 配置](https://opentelemetry.io/docs/collector/configuration/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [OpenTelemetry 语义约定](https://opentelemetry.io/docs/concepts/semantic-conventions/)

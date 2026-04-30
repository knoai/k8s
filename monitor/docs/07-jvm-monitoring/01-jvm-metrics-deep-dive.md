# JVM 监控深度实战

> 市场 JD 高频要求："JVM 指标监测"、"定制化 APM 经验"。Java 应用是 K8s 上最常见的应用类型之一，深入掌握 JVM 监控是必备技能。

---

## 1. JVM 监控全景图

```
┌─────────────────────────────────────────────────────────────────┐
│                        JVM 运行时                                │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     堆内存 (Heap)                         │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │    Eden     │  │  Survivor 0 │  │  Survivor 1 │      │   │
│  │  │   (年轻代)   │  │   (幸存区)   │  │   (幸存区)   │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │                 Old Gen (老年代)                   │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐   │
│  │  非堆内存 (Non-Heap) │  │         线程 / GC               │   │
│  │  - Metaspace        │  │  - Thread Count                 │   │
│  │  - Code Cache       │  │  - GC Count / Time              │   │
│  │  - Direct Buffer    │  │  - JIT Compilation              │   │
│  └─────────────────────┘  └─────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    采集方式对比                            │   │
│  │  JMX Exporter  │  OTel Java Agent  │  Micrometer         │   │
│  │  (Sidecar模式)  │  (Auto-Instrument) │  (代码埋点)          │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. JVM 核心指标详解

### 2.1 内存指标

| 指标 | JMX MBean | PromQL | 告警阈值 |
|------|-----------|--------|----------|
| **堆内存使用率** | `java.lang:type=Memory` | `jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"}` | > 80% |
| **老年代使用率** | `java.lang:type=MemoryPool,name=G1 Old Gen` | `jvm_memory_pool_used_bytes{pool="G1 Old Gen"} / jvm_memory_pool_max_bytes{pool="G1 Old Gen"}` | > 85% |
| **Metaspace 使用率** | `java.lang:type=MemoryPool,name=Metaspace` | 同上 | > 90% |
| **GC 后老年代占比** | - | `jvm_memory_pool_used_bytes{pool="G1 Old Gen"} / jvm_memory_pool_max_bytes{pool="G1 Old Gen"} offset 5m` | 持续增长 |
| **直接内存使用** | `java.lang:type=BufferPool,name=direct` | `jvm_buffer_pool_used_bytes{pool="direct"}` | 接近 maxDirectMemory |

### 2.2 GC 指标

| 指标 | 说明 | 告警条件 |
|------|------|----------|
| `jvm_gc_pause_seconds_count` | GC 次数 | 持续 Full GC |
| `jvm_gc_pause_seconds_sum` | GC 总耗时 | GC 时间占比 > 10% |
| `jvm_gc_pause_seconds_max` | 单次 GC 最大耗时 | > 1s |
| `jvm_gc_memory_allocated_bytes_total` | 年轻代分配总量 | - |
| `jvm_gc_memory_promoted_bytes_total` | 晋升到老年代总量 | 突增预警 |

**GC 问题判断**：
```promql
# Full GC 频率
increase(jvm_gc_pause_seconds_count{gc="G1 Old Generation"}[1h])

# GC 时间占比（>10% 需关注）
(
  rate(jvm_gc_pause_seconds_sum[5m])
)
/
5 > 0.1

# 内存晋升速率（突增可能有大对象）
rate(jvm_gc_memory_promoted_bytes_total[5m])
```

### 2.3 线程指标

| 指标 | 说明 | 告警条件 |
|------|------|----------|
| `jvm_threads_live_threads` | 活跃线程数 | 突增/持续增长 |
| `jvm_threads_daemon_threads` | 守护线程数 | - |
| `jvm_threads_peak_threads` | 峰值线程数 | - |
| `jvm_threads_states_threads` | 按状态分组的线程数 | BLOCKED > 10 |

### 2.4 类加载指标

| 指标 | 说明 |
|------|------|
| `jvm_classes_loaded_classes` | 当前加载类数量 |
| `jvm_classes_unloaded_classes_total` | 卸载类总数 |
| `jvm_classes_loaded_classes_total` | 累计加载类数 |

---

## 3. 采集方式对比与实战

### 3.1 JMX Exporter（Sidecar 模式）

**原理**：JMX Exporter 作为 Java Agent 或独立进程暴露 JVM JMX 指标。

**Java Agent 方式（推荐）**：
```dockerfile
FROM openjdk:17-jdk-slim
COPY target/app.jar /app.jar
COPY jmx_prometheus_javaagent-0.20.0.jar /jmx_exporter.jar
COPY jmx-config.yml /jmx-config.yml
EXPOSE 8080 9090
ENTRYPOINT ["java", \
  "-javaagent:/jmx_exporter.jar=9090:/jmx-config.yml", \
  "-jar", "/app.jar"]
```

**独立进程方式**：
```yaml
# jmx-exporter.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jmx-exporter
spec:
  template:
    spec:
      containers:
        - name: app
          image: my-java-app:latest
          env:
            - name: JAVA_OPTS
              value: "-Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=9010 -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false"
        - name: jmx-exporter
          image: bitnami/jmx-exporter:0.20.0
          args:
            - "9090"
            - /etc/jmx/config.yml
          ports:
            - containerPort: 9090
              name: metrics
          env:
            - name: JMX_EXPORTER_JVM_OPTS
              value: "-Djava.rmi.server.hostname=127.0.0.1"
```

**JMX Exporter 配置（jmx-config.yml）**：
```yaml
---
lowercaseOutputLabelNames: true
lowercaseOutputName: true
whitelistObjectNames:
  - "java.lang:type=Memory"
  - "java.lang:type=MemoryPool,*"
  - "java.lang:type=GarbageCollector,*"
  - "java.lang:type=Threading"
  - "java.lang:type=ClassLoading"
  - "java.lang:type=OperatingSystem"
  - "java.nio:type=BufferPool,*"

rules:
  # JVM 内存
  - pattern: 'java.lang<type=Memory><(\w+)>(\w+):'
    name: jvm_memory_$2_bytes
    labels:
      area: "$1"
    type: GAUGE

  # 内存池
  - pattern: 'java.lang<type=MemoryPool, name=(\w+)><(\w+)>(\w+):'
    name: jvm_memory_pool_$3_bytes
    labels:
      pool: "$1"
    type: GAUGE

  # GC
  - pattern: 'java.lang<type=GarbageCollector, name=(\w+)><(\w+)>(\w+):'
    name: jvm_gc_$3_$2
    labels:
      gc: "$1"
    type: COUNTER

  # GC 暂停时间（关键！）
  - pattern: 'java.lang<type=GarbageCollector, name=(\w+)><LastGcInfo>duration:\s+(\d+)'
    name: jvm_gc_last_duration_seconds
    value: $2
    labels:
      gc: "$1"
    type: GAUGE

  # 线程
  - pattern: 'java.lang<type=Threading><(\w+)>(\w+):'
    name: jvm_threads_$2
    type: GAUGE

  # 类加载
  - pattern: 'java.lang<type=ClassLoading><(\w+)>(\w+):'
    name: jvm_classes_$2
    type: GAUGE

  # 操作系统
  - pattern: 'java.lang<type=OperatingSystem><(\w+)>(\w+):'
    name: jvm_os_$2
    type: GAUGE

  # 直接/映射 Buffer
  - pattern: 'java.nio<type=BufferPool, name=(\w+)><(\w+)>(\w+):'
    name: jvm_buffer_pool_$3
    labels:
      pool: "$1"
    type: GAUGE
```

### 3.2 OpenTelemetry Java Agent（推荐）

**优势**：
- 自动埋点 JVM + 框架（Spring Boot、JDBC、Redis、gRPC）
- 同时输出 Metrics + Traces + Logs
- 无需修改代码

**Deployment 配置**：
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: java-app
spec:
  template:
    spec:
      initContainers:
        - name: download-otel-agent
          image: curlimages/curl:latest
          command:
            - sh
            - -c
            - |
              curl -L -o /otel-agent/opentelemetry-javaagent.jar \
                https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.0.0/opentelemetry-javaagent.jar
          volumeMounts:
            - name: otel-agent
              mountPath: /otel-agent
      containers:
        - name: app
          image: my-java-app:latest
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel-agent/opentelemetry-javaagent.jar"
            - name: OTEL_SERVICE_NAME
              value: "order-service"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=production,deployment.environment=production"
            - name: OTEL_METRICS_EXPORTER
              value: "otlp,prometheus"
            - name: OTEL_TRACES_EXPORTER
              value: "otlp"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.monitoring:4317"
            # JVM 指标采集间隔
            - name: OTEL_METRIC_EXPORT_INTERVAL
              value: "60000"
            # 启用 JVM 指标
            - name: OTEL_INSTRUMENTATION_RUNTIME_TELEMETRY_ENABLED
              value: "true"
            # 启用 Micrometer 桥接（如果使用 Micrometer）
            - name: OTEL_INSTRUMENTATION_MICROMETER_ENABLED
              value: "true"
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 9464
              name: metrics  # OTel Prometheus exporter 端口
          volumeMounts:
            - name: otel-agent
              mountPath: /otel-agent
      volumes:
        - name: otel-agent
          emptyDir: {}
```

### 3.3 Micrometer + Prometheus（Spring Boot）

**pom.xml**：
```xml
<dependencies>
  <dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
  </dependency>
  <dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-otel</artifactId>
  </dependency>
  <dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-core</artifactId>
  </dependency>
</dependencies>
```

**application.yml**：
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  endpoint:
    prometheus:
      enabled: true
  metrics:
    tags:
      application: ${spring.application.name}
    distribution:
      percentiles-histogram:
        http.server.requests: true
      slo:
        http.server.requests: 50ms,100ms,200ms,500ms,1s,2s
    export:
      prometheus:
        enabled: true

  # JVM 指标增强
  metrics:
    enable:
      jvm: true
      process: true
      system: true
      logback: true
```

**自定义 Metrics（代码埋点）**：
```java
import io.micrometer.core.instrument.*;
import org.springframework.stereotype.Component;

@Component
public class OrderMetrics {
    private final Counter orderCounter;
    private final Timer orderTimer;
    private final Gauge inventoryGauge;

    public OrderMetrics(MeterRegistry registry) {
        // Counter: 订单总数
        this.orderCounter = Counter.builder("orders.created")
            .description("Total orders created")
            .tag("service", "order-service")
            .register(registry);

        // Timer: 订单处理耗时
        this.orderTimer = Timer.builder("orders.processing.duration")
            .description("Order processing time")
            .publishPercentiles(0.5, 0.95, 0.99)
            .register(registry);

        // Gauge: 当前库存（动态值）
        this.inventoryGauge = Gauge.builder("inventory.current")
            .description("Current inventory count")
            .register(registry, this, OrderMetrics::getInventoryCount);
    }

    public void recordOrder() {
        orderCounter.increment();
    }

    public void recordOrderDuration(long millis) {
        orderTimer.record(millis, java.util.concurrent.TimeUnit.MILLISECONDS);
    }

    private double getInventoryCount() {
        // 从缓存或数据库获取
        return 100.0;
    }
}
```

---

## 4. JVM 告警规则精编

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: jvm-alerts
  namespace: monitoring
  labels:
    role: alert-rules
    prometheus: prometheus
spec:
  groups:
    - name: jvm-memory
      rules:
        # 堆内存使用率过高
        - alert: JVMHeapUsageHigh
          expr: |
            jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"} > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "JVM 堆内存使用率过高: {{ $labels.service_name }}"
            description: "当前使用率: {{ $value | humanizePercentage }}"

        # 老年代使用率过高
        - alert: JVMOldGenUsageHigh
          expr: |
            jvm_memory_pool_used_bytes{pool="G1 Old Gen"} / 
            jvm_memory_pool_max_bytes{pool="G1 Old Gen"} > 0.9
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "JVM 老年代使用率过高: {{ $labels.service_name }}"
            description: "可能即将发生 Full GC 或 OOM"

        # Metaspace 使用率过高（类泄漏）
        - alert: JVMMetaspaceUsageHigh
          expr: |
            jvm_memory_pool_used_bytes{pool="Metaspace"} / 
            jvm_memory_pool_max_bytes{pool="Metaspace"} > 0.9
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "JVM Metaspace 使用率过高"
            description: "可能存在类加载泄漏"

        # GC 后老年代未释放（内存泄漏）
        - alert: JVMPossibleMemoryLeak
          expr: |
            jvm_memory_pool_used_bytes{pool="G1 Old Gen"} / 
            jvm_memory_pool_max_bytes{pool="G1 Old Gen"} > 0.8
            and
            jvm_memory_pool_used_bytes{pool="G1 Old Gen"} offset 1h > 0
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "JVM 可能存在内存泄漏"
            description: "GC 后老年代内存未下降，持续增长"

    - name: jvm-gc
      rules:
        # Full GC 频繁
        - alert: JVMFullGCFrequent
          expr: |
            increase(jvm_gc_pause_seconds_count{gc="G1 Old Generation"}[1h]) > 5
            or
            increase(jvm_gc_pause_seconds_count{gc="ConcurrentMarkSweep"}[1h]) > 5
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "JVM Full GC 频繁"
            description: "1 小时内 Full GC 超过 5 次"

        # GC 耗时过长
        - alert: JVMGCDurationHigh
          expr: |
            rate(jvm_gc_pause_seconds_sum[5m]) / 
            rate(jvm_gc_pause_seconds_count[5m]) > 0.5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "JVM GC 平均耗时过高"
            description: "单次 GC 平均耗时超过 500ms"

        # GC 时间占比过高
        - alert: JVMGCTimeRatioHigh
          expr: |
            rate(jvm_gc_pause_seconds_sum[5m]) / 5 > 0.1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "JVM GC 时间占比超过 10%"

    - name: jvm-threads
      rules:
        # 线程数突增
        - alert: JVMThreadCountSpike
          expr: |
            jvm_threads_live_threads > 
            avg_over_time(jvm_threads_live_threads[1d]) * 2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "JVM 线程数突增"
            description: "当前: {{ $value }}, 基线: {{ $value }} 的 2 倍"

        # 死锁线程
        - alert: JVMDeadlockedThreads
          expr: jvm_threads_deadlocked_threads > 0
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "JVM 检测到死锁线程"

    - name: jvm-application
      rules:
        # HTTP 接口 P99 延迟
        - alert: JVMHttpLatencyHigh
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_server_requests_seconds_bucket[5m])) by (le, uri)
            ) > 2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "HTTP 接口 {{ $labels.uri }} P99 延迟过高"

        # HTTP 错误率
        - alert: JVMHttpErrorRate
          expr: |
            sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
            /
            sum(rate(http_server_requests_seconds_count[5m])) > 0.05
          for: 2m
          labels:
            severity: critical
```

---

## 5. Grafana Dashboard 配置

### 5.1 JVM 核心 Dashboard JSON

```json
{
  "dashboard": {
    "title": "JVM 应用监控",
    "tags": ["jvm", "java"],
    "timezone": "browser",
    "schemaVersion": 36,
    "refresh": "30s",
    "panels": [
      {
        "id": 1,
        "title": "JVM 堆内存",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
        "targets": [
          {
            "expr": "jvm_memory_used_bytes{area=\"heap\",service_name=\"$service\"}",
            "legendFormat": "已使用"
          },
          {
            "expr": "jvm_memory_committed_bytes{area=\"heap\",service_name=\"$service\"}",
            "legendFormat": "Committed"
          },
          {
            "expr": "jvm_memory_max_bytes{area=\"heap\",service_name=\"$service\"}",
            "legendFormat": "最大"
          }
        ],
        "fieldConfig": {
          "defaults": {"unit": "bytes"}
        }
      },
      {
        "id": 2,
        "title": "GC 暂停时间",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
        "targets": [
          {
            "expr": "rate(jvm_gc_pause_seconds_sum{service_name=\"$service\"}[5m]) / rate(jvm_gc_pause_seconds_count{service_name=\"$service\"}[5m])",
            "legendFormat": "{{ gc }} 平均耗时"
          }
        ],
        "fieldConfig": {
          "defaults": {"unit": "s", "custom": {"fillOpacity": 20}}
        }
      },
      {
        "id": 3,
        "title": "线程数",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
        "targets": [
          {
            "expr": "jvm_threads_live_threads{service_name=\"$service\"}",
            "legendFormat": "活跃线程"
          },
          {
            "expr": "jvm_threads_daemon_threads{service_name=\"$service\"}",
            "legendFormat": "守护线程"
          },
          {
            "expr": "jvm_threads_peak_threads{service_name=\"$service\"}",
            "legendFormat": "峰值线程"
          }
        ]
      },
      {
        "id": 4,
        "title": "类加载",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
        "targets": [
          {
            "expr": "jvm_classes_loaded_classes{service_name=\"$service\"}",
            "legendFormat": "当前加载"
          },
          {
            "expr": "rate(jvm_classes_loaded_classes_total{service_name=\"$service\"}[5m])",
            "legendFormat": "加载速率"
          }
        ]
      },
      {
        "id": 5,
        "title": "HTTP 延迟分布",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 16},
        "targets": [
          {
            "expr": "histogram_quantile(0.50, sum(rate(http_server_requests_seconds_bucket{service_name=\"$service\"}[5m])) by (le))",
            "legendFormat": "P50"
          },
          {
            "expr": "histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket{service_name=\"$service\"}[5m])) by (le))",
            "legendFormat": "P95"
          },
          {
            "expr": "histogram_quantile(0.99, sum(rate(http_server_requests_seconds_bucket{service_name=\"$service\"}[5m])) by (le))",
            "legendFormat": "P99"
          }
        ],
        "fieldConfig": {
          "defaults": {"unit": "s"}
        }
      }
    ]
  }
}
```

---

## 6. JVM 调优与监控结合

### 6.1 GC 选型与监控要点

| GC 算法 | 适用场景 | 关键监控指标 |
|---------|----------|-------------|
| **G1GC** | 大内存（>4GB）、低延迟 | G1 Old Gen 使用率、Mixed GC 频率 |
| **ZGC** | 超大内存（>16GB）、极低延迟 | ZGC 周期、Mark/Relocate 耗时 |
| **Shenandoah** | 低延迟、OpenJDK | Pause 时长、Heap 使用率 |
| **Parallel GC** | 吞吐量优先、批处理 | Throughput、Full GC 频率 |

### 6.2 OOM 前兆监控

```promql
# OOM 前兆组合告警
(
  # 堆内存持续高位
  jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"} > 0.9
)
and
(
  # 且 GC 频繁
  rate(jvm_gc_pause_seconds_count[5m]) > 0.1
)
and
(
  # 且 GC 后内存未释放
  jvm_memory_used_bytes{area="heap"} offset 5m > jvm_memory_max_bytes{area="heap"} * 0.8
)
```

---

## 参考资源

- [JMX Exporter GitHub](https://github.com/prometheus/jmx_exporter)
- [OpenTelemetry Java Instrumentation](https://github.com/open-telemetry/opentelemetry-java-instrumentation)
- [Micrometer 文档](https://micrometer.io/docs)
- [Spring Boot Actuator](https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html)
- [JVM GC 调优指南](https://docs.oracle.com/en/java/javase/17/gctuning/)

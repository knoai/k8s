# 案例二：JVM 监控三种方式对比实践

## 目标

部署同一个 Spring Boot 应用，分别使用 **JMX Exporter**、**OTel Java Agent**、**Micrometer** 三种方式采集 JVM 指标，对比差异并理解各自适用场景。

完成后你将掌握：
- ✅ JMX Exporter Agent 模式和独立进程模式
- ✅ OTel Java Agent 自动埋点配置
- ✅ Micrometer 代码级埋点
- ✅ 三种方式的指标差异对比
- ✅ 生产环境选型能力

---

## 前置条件

```bash
# 确保 Prometheus Operator 已部署
helm list -n monitoring | grep prometheus

# 创建 namespace
kubectl create namespace jvm-demo --dry-run=client -o yaml | kubectl apply -f -
```

---

## 方式一：JMX Exporter（Agent 模式）

### 原理
JMX Exporter 作为 Java Agent 随 JVM 启动，直接读取 JMX MBean，在独立端口暴露 Prometheus 格式指标。

```
JVM → JMX MBean → JMX Exporter Agent → :9090/metrics → Prometheus
```

### 部署

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-jmx
  namespace: jvm-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-jmx
  template:
    metadata:
      labels:
        app: order-jmx
        monitoring: jmx
    spec:
      initContainers:
        # 下载 JMX Exporter Agent
        - name: download-jmx
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              wget -O /jmx/jmx_prometheus_javaagent.jar \
                https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/0.20.0/jmx_prometheus_javaagent-0.20.0.jar
              cat > /jmx/config.yaml <<'JMXCONFIG'
lowercaseOutputLabelNames: true
lowercaseOutputName: true
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
    name: jvm_gc_$3_total
    labels:
      gc: "$1"
    type: COUNTER
  # 线程
  - pattern: 'java.lang<type=Threading><(\w+)>(\w+):'
    name: jvm_threads_$2
    type: GAUGE
JMXCONFIG
          volumeMounts:
            - name: jmx
              mountPath: /jmx
      containers:
        - name: app
          image: ghcr.io/prometheus-community/spring-boot-demo:latest
          command:
            - java
            - -javaagent:/jmx/jmx_prometheus_javaagent.jar=9090:/jmx/config.yaml
            - -jar
            - /app.jar
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 9090
              name: metrics
          volumeMounts:
            - name: jmx
              mountPath: /jmx
      volumes:
        - name: jmx
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: order-jmx
  namespace: jvm-demo
  labels:
    app: order-jmx
spec:
  selector:
    app: order-jmx
  ports:
    - port: 8080
      name: http
    - port: 9090
      name: metrics
EOF

# ServiceMonitor
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-jmx-metrics
  namespace: jvm-demo
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: order-jmx
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
EOF

kubectl wait --for=condition=ready pod -l app=order-jmx -n jvm-demo --timeout=120s
```

### 验证指标

```bash
# 查看 JMX Exporter 暴露的指标
kubectl port-forward svc/order-jmx 9090:9090 -n jvm-demo &
curl -s http://localhost:9090/metrics | grep "^jvm_"

# 预期输出：
# jvm_memory_used_bytes{area="heap",} 67108864
# jvm_memory_pool_used_bytes{pool="G1 Eden Space",} 25165824
# jvm_gc_collection_seconds_count{gc="G1 Young Generation",} 12
# jvm_threads_live_threads 25
```

---

## 方式二：OpenTelemetry Java Agent

### 原理
OTel Java Agent 通过字节码注入自动采集 JVM 运行时指标 + 框架指标（HTTP、JDBC、Redis）+ 分布式链路追踪，统一通过 OTLP 协议上报。

```
JVM → OTel Agent(字节码注入) → OTLP → OTel Collector → Prometheus/Loki/Tempo
```

### 部署

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-otel
  namespace: jvm-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-otel
  template:
    metadata:
      labels:
        app: order-otel
        monitoring: otel
    spec:
      initContainers:
        - name: download-otel
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              wget -O /otel/opentelemetry-javaagent.jar \
                https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.0.0/opentelemetry-javaagent.jar
          volumeMounts:
            - name: otel
              mountPath: /otel
      containers:
        - name: app
          image: ghcr.io/prometheus-community/spring-boot-demo:latest
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/opentelemetry-javaagent.jar"
            - name: OTEL_SERVICE_NAME
              value: "order-otel"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "deployment.environment=demo,monitoring.type=otel-agent"
            # 同时输出到 Prometheus 端口和 OTLP
            - name: OTEL_METRICS_EXPORTER
              value: "prometheus,otlp"
            - name: OTEL_TRACES_EXPORTER
              value: "otlp"
            - name: OTEL_EXPORTER_PROMETHEUS_PORT
              value: "9464"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.monitoring:4317"
            - name: OTEL_METRIC_EXPORT_INTERVAL
              value: "60000"
            # 启用 JVM 指标
            - name: OTEL_INSTRUMENTATION_RUNTIME_TELEMETRY_ENABLED
              value: "true"
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 9464
              name: metrics
          volumeMounts:
            - name: otel
              mountPath: /otel
      volumes:
        - name: otel
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: order-otel
  namespace: jvm-demo
  labels:
    app: order-otel
spec:
  selector:
    app: order-otel
  ports:
    - port: 8080
      name: http
    - port: 9464
      name: metrics
EOF

# ServiceMonitor
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-otel-metrics
  namespace: jvm-demo
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: order-otel
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
EOF

kubectl wait --for=condition=ready pod -l app=order-otel -n jvm-demo --timeout=120s
```

### 验证指标

```bash
kubectl port-forward svc/order-otel 9464:9464 -n jvm-demo &

# OTel 格式的 JVM 指标
curl -s http://localhost:9464/metrics | grep "^jvm_"

# 预期输出（OTel 命名规范）：
# jvm_memory_used_bytes{jvm_memory_pool_name="G1 Eden Space",jvm_memory_type="heap"}
# jvm_gc_duration_seconds_count{gc="G1 Young Generation"}
# jvm_thread_count
# process_runtime_jvm_memory_usage{type="heap"}

# 同时有 HTTP 指标（自动埋点）
curl -s http://localhost:9464/metrics | grep "http_server"
# http_server_duration_seconds_bucket{http_method="GET",http_route="/",http_status_code="200",le="0.005"}
```

---

## 方式三：Micrometer（代码埋点）

### 原理
在 Spring Boot 代码中通过 Micrometer API 显式埋点，配合 `micrometer-registry-prometheus` 在 Actuator 端点暴露指标。

```
代码 → Micrometer Registry → /actuator/prometheus → Prometheus
```

### 部署（使用内置 Actuator）

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-micrometer
  namespace: jvm-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-micrometer
  template:
    metadata:
      labels:
        app: order-micrometer
        monitoring: micrometer
    spec:
      containers:
        - name: app
          image: ghcr.io/prometheus-community/spring-boot-demo:latest
          env:
            - name: MANAGEMENT_SERVER_PORT
              value: "8081"
            - name: MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE
              value: "prometheus,metrics,health"
            - name: MANAGEMENT_METRICS_TAGS_APPLICATION
              value: "order-micrometer"
            # 启用更多 JVM 指标
            - name: MANAGEMENT_METRICS_ENABLE_JVM
              value: "true"
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 8081
              name: management
EOF

# ServiceMonitor
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-micrometer-metrics
  namespace: jvm-demo
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: order-micrometer
  endpoints:
    - port: management
      path: /actuator/prometheus
      interval: 15s
EOF

kubectl wait --for=condition=ready pod -l app=order-micrometer -n jvm-demo --timeout=120s
```

### 验证指标

```bash
kubectl port-forward svc/order-micrometer 8081:8081 -n jvm-demo &

# Micrometer 格式的指标
curl -s http://localhost:8081/actuator/prometheus | grep "^jvm_"

# 预期输出（Micrometer 命名）：
# jvm_memory_used_bytes{area="heap",id="G1 Old Gen"}
# jvm_gc_pause_seconds_count{action="end of minor GC",cause="G1 Evacuation Pause"}
# jvm_threads_live_threads
# jvm_classes_loaded_classes

# 有应用自定义指标（如果代码中定义了）
curl -s http://localhost:8081/actuator/prometheus | grep "http_server"
# http_server_requests_seconds_count{exception="None",method="GET",outcome="SUCCESS",status="200",uri="/"}
```

---

## 三种方式对比

| 维度 | JMX Exporter | OTel Java Agent | Micrometer |
|------|-------------|-----------------|------------|
| **侵入性** | 低（JVM 参数） | 低（JVM 参数） | 中（代码修改） |
| **指标类型** | JVM 基础指标 | JVM + HTTP + DB + Cache + Trace | 自定义为主 |
| **命名规范** | JMX 原始名 | OTel 语义约定 | Micrometer 命名 |
| **链路追踪** | ❌ | ✅ 自动 | ❌（需额外集成） |
| **框架覆盖** | ❌ 仅 JVM | ✅ Spring/JDBC/Redis/gRPC 等 | ✅ Spring 生态 |
| **指标自定义** | 需改 YAML | 有限 | 完全灵活 |
| **性能开销** | 低 | 中 | 低 |
| **适用场景** | 遗留系统、快速接入 | 现代化全链路可观测 | 精细化业务监控 |

### 指标命名对比示例

| 指标含义 | JMX Exporter | OTel Agent | Micrometer |
|----------|-------------|-----------|-----------|
| 堆内存使用 | `jvm_memory_used_bytes{area="heap"}` | `jvm_memory_used_bytes{jvm_memory_type="heap"}` | `jvm_memory_used_bytes{area="heap"}` |
| GC 次数 | `jvm_gc_collection_seconds_count{gc="G1 Young"}` | `jvm_gc_duration_seconds_count{gc="G1 Young"}` | `jvm_gc_pause_seconds_count{action="end of minor GC"}` |
| 活跃线程 | `jvm_threads_live_threads` | `jvm_thread_count` | `jvm_threads_live_threads` |
| HTTP 请求 | ❌ 无 | `http_server_duration_seconds_count` | `http_server_requests_seconds_count` |

---

## 生产选型建议

| 场景 | 推荐方案 | 理由 |
|------|----------|------|
| 遗留 Java 系统，无源码 | JMX Exporter | 零代码，快速接入 |
| 新系统，需要全链路可观测 | OTel Java Agent | 一键获得 Metrics + Traces + Logs |
| 需要精细化业务指标 | Micrometer + OTel | 代码级灵活 + 统一上报 |
| 混合环境 | OTel Agent + Micrometer 桥接 | 自动埋点 + 自定义互补 |

---

## 验证清单

- [ ] 三个应用的 Pod 都 Ready
- [ ] Prometheus Targets 页面能看到三个 ServiceMonitor
- [ ] 能查询到各自的 JVM 指标（注意命名差异）
- [ ] OTel Agent 应用有 `http_server_duration_seconds` 指标
- [ ] JMX Exporter 只有 JVM 指标，无 HTTP 指标
- [ ] 理解三种指标命名差异的原因

---

## 清理

```bash
kubectl delete namespace jvm-demo
```

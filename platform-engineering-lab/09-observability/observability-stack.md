# K8s 可观测性体系深度实践

> 生产环境可观测性 = Metrics（指标）+ Logs（日志）+ Traces（链路）+ Profiles（剖析）。
> 本节提供基于 Prometheus + Grafana + Loki + Tempo/Jaeger 的完整生产实践。

---

## 一、可观测性三大支柱

```
┌─────────────────────────────────────────┐
│           Observability                 │
│                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
│  │ Metrics │  │  Logs   │  │ Traces  │ │
│  │         │  │         │  │         │ │
│  │ "什么"  │  │ "为什么" │  │ "哪里"  │ │
│  │ 发生了  │  │ 发生的  │  │ 发生的  │ │
│  └────┬────┘  └────┬────┘  └────┬────┘ │
│       │            │            │      │
│       └────────────┼────────────┘      │
│                    │                   │
│              ┌─────▼─────┐             │
│              │  Profiles │             │
│              │  "怎么"   │             │
│              │ 优化的   │             │
│              └───────────┘             │
└─────────────────────────────────────────┘

Metrics：量化系统状态
  - 延迟（Latency）：P50/P95/P99
  - 流量（Traffic）：QPS、RPS
  - 错误（Errors）：错误率、异常数
  - 饱和度（Saturation）：CPU、内存、连接数
  
Logs：记录详细事件
  - 结构化日志（JSON）
  - 日志级别：DEBUG/INFO/WARN/ERROR/FATAL
  - 日志聚合和搜索

Traces：请求全链路追踪
  - 分布式系统的请求路径
  - 每个 span 的耗时和依赖关系
  - 性能瓶颈定位

Profiles：运行时性能剖析
  - CPU 剖析：热点函数
  - 内存剖析：内存泄漏
  -  goroutine 剖析：死锁和泄漏
```

---

## 二、Metrics：Prometheus 深度实践

### 2.1 Prometheus 架构

```
Prometheus 架构：

  ┌─────────────────────────────────────────┐
  │  Prometheus Server                      │
  │   - 时序数据库（TSDB）                  │
  │   - PromQL 查询引擎                     │
  │   - 抓取调度器（Scraper）               │
  │   - 告警管理器（Alertmanager）          │
  └──────────────┬──────────────────────────┘
                 │ 抓取（Pull）
                 ▼
  ┌─────────────────────────────────────────┐
  │  Exporters / Service Discovery          │
  │   - Node Exporter（节点指标）           │
  │   - kube-state-metrics（K8s 资源）      │
  │   - cAdvisor（容器指标）                │
  │   - 应用埋点（client libraries）        │
  │   - K8s Service Discovery               │
  └─────────────────────────────────────────┘
                 │
                 ▼
  ┌─────────────────────────────────────────┐
  │  Alertmanager                           │
  │   - 告警分组                            │
  │   - 告警抑制                            │
  │   - 告警路由（PagerDuty/Slack/钉钉）    │
  └─────────────────────────────────────────┘
                 │
                 ▼
  ┌─────────────────────────────────────────┐
  │  Grafana                                │
  │   - 可视化面板                          │
  │   - 告警规则（替代 Prometheus 告警）    │
  └─────────────────────────────────────────┘
```

### 2.2 核心 Exporters

```yaml
# === Node Exporter ===
# 部署
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true
      hostPID: true
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.6.1
        args:
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        - --path.rootfs=/host/root
        - --collector.filesystem.ignored-mount-points=^/(sys|proc|dev|host|etc)($$|/)
        ports:
        - containerPort: 9100
          hostPort: 9100
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: root
          mountPath: /host/root
          readOnly: true
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      - name: root
        hostPath:
          path: /
EOF

# 关键指标：
# node_cpu_seconds_total{mode="idle"}          CPU 空闲时间
# node_cpu_seconds_total{mode="iowait"}        CPU IO 等待
# node_memory_MemTotal_bytes                   总内存
# node_memory_MemAvailable_bytes               可用内存
# node_memory_SwapTotal_bytes                  Swap 总量
# node_memory_SwapFree_bytes                   Swap 空闲
# node_disk_io_time_seconds_total              磁盘 IO 时间
# node_network_receive_bytes_total             网络接收字节
# node_network_transmit_bytes_total            网络发送字节
# node_load1                                   1 分钟负载
# node_filefd_allocated                        已分配文件描述符

# === kube-state-metrics ===
# K8s 资源状态指标
kubectl apply -f https://github.com/kubernetes/kube-state-metrics/releases/latest/download/kube-state-metrics-standard.yaml

# 关键指标：
# kube_pod_status_phase{phase="Running"}       Pod 状态分布
# kube_pod_container_status_restarts_total      容器重启次数
# kube_deployment_status_replicas_available     Deployment 可用副本
# kube_node_status_condition{condition="Ready"} 节点状态
# kube_resourcequota                            资源配额使用
# kube_persistentvolumeclaim_status_phase       PVC 状态

# === cAdvisor ===
# 容器资源指标（kubelet 内置）
# 访问：http://<node>:10255/metrics/cadvisor

# 关键指标：
# container_cpu_usage_seconds_total            容器 CPU 使用
# container_memory_working_set_bytes           容器内存使用（不含缓存）
# container_memory_usage_bytes                 容器内存使用（含缓存）
# container_network_receive_bytes_total        容器网络接收
# container_fs_usage_bytes                     容器磁盘使用
# container_spec_cpu_quota                     容器 CPU limit
# container_spec_cpu_period                    容器 CPU period
```

### 2.3 Prometheus 告警规则（生产级）

```yaml
groups:
- name: kubernetes
  rules:
  # === Pod 级别 ===
  - alert: PodCrashLooping
    expr: rate(kube_pod_container_status_restarts_total[5m]) > 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Pod {{ $labels.pod }} crash looping"
      description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} restarting {{ $value }} times/min"

  - alert: PodNotReady
    expr: |
      sum by (namespace, pod) (
        kube_pod_status_phase{phase=~"Pending|Unknown|Failed"}
      ) > 0
    for: 15m
    labels:
      severity: warning
    annotations:
      summary: "Pod {{ $labels.pod }} not ready"

  - alert: PodHighCpuUsage
    expr: |
      sum by (namespace, pod) (
        rate(container_cpu_usage_seconds_total{container!=""}[5m])
      ) / 
      sum by (namespace, pod) (
        container_spec_cpu_quota{container!=""} / container_spec_cpu_period{container!=""}
      ) > 0.85
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Pod {{ $labels.pod }} CPU usage > 85%"

  - alert: PodHighMemoryUsage
    expr: |
      sum by (namespace, pod) (
        container_memory_working_set_bytes{container!=""}
      ) / 
      sum by (namespace, pod) (
        container_spec_memory_limit_bytes{container!=""}
      ) > 0.85
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Pod {{ $labels.pod }} memory usage > 85%"

  # === 节点级别 ===
  - alert: NodeHighCpuUsage
    expr: 100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Node {{ $labels.instance }} CPU > 80%"

  - alert: NodeHighMemoryUsage
    expr: |
      (1 - (
        node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
      )) * 100 > 85
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Node {{ $labels.instance }} memory > 85%"

  - alert: NodeDiskPressure
    expr: |
      (1 - (
        node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}
      )) * 100 > 85
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Node {{ $labels.instance }} disk > 85%"

  - alert: NodeDiskIOHigh
    expr: rate(node_disk_io_time_seconds_total[5m]) > 0.8
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Node {{ $labels.instance }} disk IO > 80%"

  - alert: NodeNetworkErrors
    expr: rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m]) > 10
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Node {{ $labels.instance }} network errors"

  # === K8s 控制平面 ===
  - alert: APIServerHighLatency
    expr: |
      histogram_quantile(0.99, 
        sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le, verb)
      ) > 1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "API Server {{ $labels.verb }} P99 > 1s"

  - alert: ETCDHighCommitLatency
    expr: histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])) > 0.25
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "etcd commit latency P99 > 250ms"

  - alert: ETCDHighFsyncLatency
    expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "etcd WAL fsync latency P99 > 500ms"

  - alert: ControllerManagerDown
    expr: up{job="kube-controller-manager"} == 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Controller Manager is down"

  # === 应用级别 ===
  - alert: HighErrorRate
    expr: |
      sum(rate(http_requests_total{status=~"5.."}[5m])) 
      / 
      sum(rate(http_requests_total[5m])) > 0.01
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Error rate > 1%"

  - alert: HighLatency
    expr: |
      histogram_quantile(0.95, 
        sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
      ) > 0.5
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "P95 latency > 500ms"
```

---

## 三、Logs：Loki + Promtail 深度实践

### 3.1 Loki 架构

```
Loki 架构：

  Application → stdout/stderr
       │
       │ 容器日志文件（/var/log/pods/...）
       ▼
  Promtail（每节点 DaemonSet）
       - 读取日志文件
       - 添加标签（pod、namespace、container）
       - 推送到 Loki
       ▼
  Loki Server
       - 日志存储（对象存储：S3/OSS/GCS）
       - 索引（标签索引，不索引日志内容）
       - 查询（LogQL）
       ▼
  Grafana
       - 日志查询和可视化
       - 与 Metrics 关联

与 ELK 对比：
┌─────────────┬─────────────────┬─────────────────┐
│ 特性        │ Loki            │ ELK (EFK)       │
├─────────────┼─────────────────┼─────────────────┤
│ 索引        │ 只索引标签      │ 索引日志内容    │
│ 存储成本    │ 低（1/10）      │ 高              │
│ 查询速度    │ 简单查询快      │ 复杂查询快      │
│ 资源消耗    │ 低              │ 高              │
│ 与 PromQL   │ 集成（LogQL）   │ 独立查询语言    │
│ 部署复杂度  │ 低              │ 高              │
└─────────────┴─────────────────┴─────────────────┘
```

### 3.2 Promtail 配置

```yaml
# promtail-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: monitoring
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0

    positions:
      filename: /tmp/positions.yaml

    clients:
      - url: http://loki:3100/loki/api/v1/push
        batchwait: 1s
        batchsize: 1048576

    scrape_configs:
    # K8s Pod 日志
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
        - source_labels: [__meta_kubernetes_pod_container_name]
          target_label: container
        - replacement: /var/log/pods/*$1/*.log
          separator: /
          source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
          target_label: __path__

    # K8s 节点日志
    - job_name: kubernetes-node-logs
      static_configs:
      - targets:
        - localhost
        labels:
          job: node-logs
          __path__: /var/log/syslog
```

### 3.3 LogQL 查询示例

```bash
# 基础查询
# 查询所有日志
{job="kubernetes-pods"}

# 查询特定命名空间
{namespace="production"}

# 查询特定 Pod
{pod=~"order-service-.*"}

# 查询特定容器
{container="order-service"}

# 组合标签
{namespace="production", app="order-service"}

# 过滤日志内容
# 包含 "error" 的日志
{namespace="production"} |= "error"

# 不包含 "debug" 的日志
{namespace="production"} != "debug"

# 正则匹配
{namespace="production"} |~ "err.*|fail.*|exception.*"

# 解析 JSON 日志
{namespace="production"}
  | json
  | level="ERROR"
  | status_code="500"

# 统计错误数（与 Metrics 结合）
sum by (namespace) (
  rate(
    {namespace="production"} |= "error" [1m]
  )
)

# 查询特定时间范围
# Grafana 中直接选择时间范围

# 关联 Metrics 和 Logs
# 在 Grafana 中：从 Metrics 面板点击，自动跳转对应 Logs
```

---

## 四、Traces：Tempo/Jaeger 深度实践

### 4.1 分布式追踪原理

```
请求链路示例：

User → API Gateway → Auth Service → Order Service → DB
  │        │              │              │           │
  │     span-1        span-2        span-3      span-4
  │    0-5ms          5-15ms       15-45ms     45-50ms
  │
  └─ Trace ID: abc123-def456-789

Span 结构：
  - Trace ID：全局唯一，标识整个请求链路
  - Span ID：当前操作的唯一标识
  - Parent Span ID：父操作的标识
  - Operation Name：操作名称（如 "GET /api/orders"）
  - Start Time / Duration：开始时间和持续时间
  - Tags：键值对标签（如 http.method=GET, http.status_code=200）
  - Logs：时间戳事件（如 "error": "connection timeout"）

传播方式：
  - HTTP Header：traceparent（W3C 标准）
    traceparent: 00-<trace-id>-<span-id>-<flags>
  - gRPC Metadata
  - Message Queue Header
```

### 4.2 OpenTelemetry 自动埋点

```yaml
# OpenTelemetry Collector 部署
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: monitoring
data:
  otel-collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 1s
        send_batch_size: 1024

    exporters:
      otlp/tempo:
        endpoint: tempo:4317
        tls:
          insecure: true
      prometheusremotewrite:
        endpoint: http://prometheus:9090/api/v1/write
      loki:
        endpoint: http://loki:3100/loki/api/v1/push

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/tempo]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [prometheusremotewrite]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [loki]

---
# Java 应用自动埋点（OpenTelemetry Java Agent）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  template:
    spec:
      containers:
      - name: order-service
        image: order-service:v1.2.3
        env:
        - name: JAVA_TOOL_OPTIONS
          value: "-javaagent:/otel/opentelemetry-javaagent.jar"
        - name: OTEL_SERVICE_NAME
          value: "order-service"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector:4317"
        - name: OTEL_TRACES_EXPORTER
          value: "otlp"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
        volumeMounts:
        - name: otel-agent
          mountPath: /otel
      volumes:
      - name: otel-agent
        emptyDir: {}
      initContainers:
      - name: otel-agent-init
        image: busybox
        command:
        - wget
        - -O
        - /otel/opentelemetry-javaagent.jar
        - https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar
        volumeMounts:
        - name: otel-agent
          mountPath: /otel
```

### 4.3 追踪查询与分析

```bash
# Tempo 查询 API
# 按 Trace ID 查询
curl http://tempo:3200/api/traces/abc123-def456-789

# 按标签搜索
curl "http://tempo:3200/api/search?tags=service.name%3Dorder-service&limit=20"

# Grafana Tempo 查询：
# Trace ID：{traceId="abc123-def456-789"}
# 服务名：{service.name="order-service"}
# 持续时间：{duration>100ms}
# 错误：{status=error}

# 典型追踪分析：
# 1. 找到延迟高的 Trace
# 2. 查看每个 Span 的耗时
# 3. 定位瓶颈 Span（耗时占比最大）
# 4. 查看该 Span 的 Tags 和 Logs
# 5. 关联 Metrics 和 Logs
```

---

## 五、Profiles：持续性能剖析

```
Pyroscope / Parca 持续性能剖析：

  Application
    │
    ├─ CPU Profiling（采样）
    │   - 每秒 100 次采样
    │   - 记录当前执行的函数
    │   - 生成 Flame Graph
    │
    ├─ Memory Profiling
    │   - 记录内存分配
    │   - 定位内存泄漏
    │
    ├─ Goroutine Profiling（Go）
    │   - 记录所有 goroutine 栈
    │   - 发现死锁和泄漏
    │
    └─ Block Profiling
        - 记录阻塞事件
        - 发现锁竞争

Flame Graph 解读：
  - X 轴：样本数（不是时间）
  - Y 轴：调用栈深度
  - 宽度：函数在样本中出现的频率
  - 颜色：无意义，仅区分不同函数
  
  分析方法：
  1. 找到最宽的塔（最耗时的调用链）
  2. 从上到下分析调用链
  3. 找到"平顶"（自身耗时高的函数）
```

---

## 六、Grafana 统一面板

### 6.1 典型 Dashboard 结构

```
Grafana Dashboard 层级：

Level 1：全局概览（Global Overview）
  - 集群数量、节点数量、Pod 数量
  - 全局 CPU / 内存 / 磁盘使用率
  - 告警统计（当前告警数、最近 24h 告警）
  - 流量趋势（入/出站带宽）

Level 2：集群概览（Cluster Overview）
  - 节点状态（Ready / NotReady）
  - 工作负载状态（Deployment / StatefulSet / DaemonSet）
  - 资源使用 Top 10（CPU / 内存）
  - API Server / etcd 性能

Level 3：命名空间/应用（Namespace / Application）
  - Pod 列表（状态、重启次数、资源使用）
  - 服务指标（QPS、延迟、错误率）
  - 日志快速查看
  - 追踪快速查看

Level 4：Pod/容器（Pod / Container）
  - 容器资源使用（CPU / 内存 / 网络 / IO）
  - 容器日志
  - 容器事件
  - JVM / Go Runtime 指标
```

### 6.2 关键面板配置

```json
// 集群资源使用面板
{
  "title": "Cluster CPU Usage",
  "type": "timeseries",
  "targets": [
    {
      "expr": "100 - (avg by (instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
      "legendFormat": "{{instance}}"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "min": 0,
      "max": 100,
      "thresholds": {
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 70},
          {"color": "red", "value": 85}
        ]
      }
    }
  }
}

// Pod 内存使用面板
{
  "title": "Pod Memory Usage",
  "type": "table",
  "targets": [
    {
      "expr": "topk(20, container_memory_working_set_bytes{container!=\"\"} / container_spec_memory_limit_bytes{container!=\"\"})",
      "format": "table",
      "instant": true
    }
  ],
  "transformations": [
    {
      "id": "organize",
      "options": {
        "excludeByName": {
          "Time": true,
          "Value": false
        },
        "renameByName": {
          "Value": "Usage %"
        }
      }
    }
  ]
}
```

---

## 七、面试要点

```
Q: Prometheus 的 Pull 模式 vs Pull 模式有什么优缺点？

A: Pull 模式（Prometheus）：
   优点：
   1. 控制节奏：Prometheus 决定何时抓取，避免目标被压垮
   2. 易于调试：curl target/metrics 即可查看
   3. 服务发现：自动发现目标，无需目标配置推送地址
   4. 多副本支持：多个 Prometheus 可从同一目标抓取
   
   缺点：
   1. 短生命周期任务可能错过抓取窗口
   2. NAT/防火墙后目标不可达
   3. 需要目标暴露 /metrics 端点
   
   解决方案：Pushgateway（用于批处理任务）

Q: 如何处理高基数（High Cardinality）指标？

A: 高基数问题：
   - 标签值过多（如 user_id、request_id）
   - 导致时间序列爆炸
   - Prometheus 内存和查询性能下降
   
   解决方案：
   1. 避免高基数标签：user_id → user_type（普通/VIP）
   2. 使用 histogram 而不是为每个值创建 gauge
   3. 定期清理旧指标（ retention 策略）
   4. 使用 recording rules 预聚合
   5. 分片：多个 Prometheus 实例

Q: Loki 为什么不索引日志内容？

A: 设计哲学：
   - 标签索引：O(1) 查找，内存中完成
   - 内容不索引：降低存储成本（1/10 of ELK）
   - 查询时扫描：利用对象存储的高吞吐顺序读取
   
   权衡：
   - 简单查询（按标签过滤）很快
   - 复杂查询（全文搜索）较慢（需要扫描）
   - 适合：已知标签范围后的日志查询
   - 不适合：未知标签的全文搜索（用 ELK）

Q: 可观测性的三大支柱哪个最重要？

A: 都重要，但场景不同：
   - Metrics："什么"出了问题（快速发现）
   - Logs："为什么"出问题（详细调查）
   - Traces："哪里"出了问题（定位瓶颈）
   
   实际工作中：
   - 先通过 Metrics 发现异常（P99 延迟飙升）
   - 再通过 Traces 定位瓶颈（哪个服务慢）
   - 最后通过 Logs 找到根因（具体错误）
   
   所以三者需要联动，不能割裂
```

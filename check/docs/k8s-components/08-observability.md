# 08. 可观测性体系详解

## 可观测性三支柱

```
┌─────────────────────────────────────────┐
│           可观测性 (Observability)        │
│                                         │
│  ┌──────────┐  ┌──────────┐  ┌────────┐│
│  │ Metrics  │  │  Logs    │  │ Traces ││
│  │ (指标)   │  │ (日志)   │  │ (链路) ││
│  └──────────┘  └──────────┘  └────────┘│
│                                         │
│  回答"什么"   回答"为什么"   回答"哪里"  │
└─────────────────────────────────────────┘
```

| 支柱 | 回答的问题 | 时间维度 | 工具 |
|------|-----------|---------|------|
| **Metrics** | 系统当前状态？CPU/内存使用率？ | 聚合，时间序列 | Prometheus |
| **Logs** | 发生了什么？错误信息是什么？ | 离散事件 | Loki/EFK |
| **Traces** | 请求经过了哪些服务？哪一步慢？ | 请求链路 | Jaeger/Zipkin |

---

## Metrics — 指标监控

### Metrics Server

Metrics Server 是 K8s 的**资源使用指标聚合器**。

```
kubelet (cAdvisor)
    │ 收集容器 CPU/内存指标
    ▼
Metrics Server
    │ 聚合所有节点的指标
    ▼
apiserver (通过 Metrics API)
    │
    ├── kubectl top
    ├── HPA (Horizontal Pod Autoscaler)
    └── VPA (Vertical Pod Autoscaler)
```

```bash
# 查看 Pod 资源使用
kubectl top pod
kubectl top pod --sort-by=cpu

# 查看节点资源使用
kubectl top node
```

### cAdvisor

cAdvisor（Container Advisor）内嵌在 kubelet 中，负责：
- 收集容器资源使用统计
- 收集文件系统使用
- 收集网络统计

```bash
# 直接访问 cAdvisor（在节点上）
curl http://localhost:4194/api/v1.3/containers/
```

### Prometheus

Prometheus 是云原生监控的事实标准。

```
┌─────────────────────────────────────────┐
│              Prometheus                  │
│                                          │
│  ┌──────────┐  ┌──────────┐  ┌────────┐│
│  │ Scraping │  │ Storage  │  │ Alert  ││
│  │ (拉取)   │  │ (TSDB)   │  │ Manager││
│  └──────────┘  └──────────┘  └────────┘│
│       │                                  │
│       │ HTTP /metrics                    │
│       ▼                                  │
│  ┌─────────────────────────────────┐    │
│  │  Targets:                       │    │
│  │  - kubelet:10255/metrics        │    │
│  │  - kube-apiserver               │    │
│  │  - kube-controller-manager      │    │
│  │  - kube-scheduler               │    │
│  │  - etcd                         │    │
│  │  - node-exporter                │    │
│  │  - 业务应用 /metrics            │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

**Prometheus 核心概念**：

| 概念 | 说明 |
|------|------|
| **Target** | 被监控的目标（一个 endpoint） |
| **Metric** | 指标名称（如 `container_cpu_usage_seconds_total`） |
| **Label** | 标签（维度），如 `pod="web-xxx"`, `namespace="default"` |
| **Time Series** | 指标 + 标签 + 时间戳 + 值 |
| **PromQL** | 查询语言 |

**常用 PromQL**：

```promql
# Pod CPU 使用率
rate(container_cpu_usage_seconds_total{pod="my-pod"}[5m])

# 节点内存使用率
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

# 容器重启次数
increase(kube_pod_container_status_restarts_total[1h])

# API Server 请求延迟
histogram_quantile(0.99,
  rate(apiserver_request_duration_seconds_bucket[5m]))
```

### kube-state-metrics

kube-state-metrics 将 K8s 资源对象状态转换为 Prometheus 指标。

```
kube-state-metrics 暴露的指标：

kube_pod_status_phase{pod="xxx", namespace="default", phase="Running"}
kube_deployment_status_replicas{deployment="xxx"}
kube_node_status_condition{node="xxx", condition="Ready"}
kube_pod_container_status_waiting_reason{pod="xxx", reason="ImagePullBackOff"}
```

### HPA — 水平自动扩缩

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # 缩容前等待 5 分钟
```

**HPA 工作流程**：

```
1. Metrics Server 收集 CPU/内存指标
2. HPA Controller 计算目标副本数
   desiredReplicas = ceil[currentReplicas × (currentMetric / targetMetric)]
3. 更新 Deployment 的 replicas
4. Deployment Controller 调整 Pod 数量
```

---

## Logs — 日志

### 日志架构

```
Pod 容器输出 stdout/stderr
    │
    ├──► 节点上的容器运行时收集
    │
    ├──► 节点上的日志代理收集（DaemonSet）
    │       ├── Fluentd
    │       ├── Fluent Bit
    │       └── Filebeat
    │
    └──► 发送到日志存储
            ├── Elasticsearch (EFK)
            ├── Loki (Grafana 栈)
            └── 云厂商日志服务
```

### 日志收集方式

| 方式 | 说明 | 适用 |
|------|------|------|
| **节点级收集** | DaemonSet 在每个节点收集日志文件 | 最常用 |
| **Sidecar 收集** | 每个 Pod 运行一个日志收集容器 | 特殊需求 |
| **应用直写** | 应用直接发送到日志系统 | 需要应用改造 |

### 节点级收集（Fluent Bit）

```
节点 /var/log/containers/
    │
    ├── podA_default_app-xxx.log  → 符号链接到 containerd log
    ├── podB_default_app-yyy.log
    └── ...
    │
    ▼
Fluent Bit (DaemonSet)
    │
    ├── Input: Tail /var/log/containers/*.log
    │
    ├── Filter: Kubernetes 元数据丰富
    │       └── 添加 pod_name, namespace, labels
    │
    └── Output: 发送到 Elasticsearch / Loki / Kafka
```

### 日志规范

**结构化日志（推荐）**：

```json
{"timestamp":"2024-01-15T10:00:00Z","level":"INFO","service":"api","trace_id":"abc123","message":"Request processed","duration_ms":45}
```

**传统文本日志**：

```
2024-01-15 10:00:00 [INFO] [api] Request processed in 45ms
```

---

## Traces — 链路追踪

### 分布式追踪

微服务架构中，一个请求经过多个服务。链路追踪记录请求的完整路径。

```
用户请求
    │
    ▼
┌─────────┐    ┌─────────┐    ┌─────────┐
│  API    │───►│  Order  │───►│Payment  │
│ Gateway │    │ Service │    │ Service │
└─────────┘    └─────────┘    └─────────┘
    │
    ├── Trace ID: abc123
    │
    ├── Span 1: API Gateway (50ms)
    │   ├── Span 2: Order Service (30ms)
    │   │   └── Span 3: DB Query (5ms)
    │   └── Span 4: Payment Service (15ms)
    │
    └── 总耗时: 50ms
```

### OpenTelemetry

OpenTelemetry 是 CNCF 的观测标准，统一了 Metrics/Logs/Traces。

```
应用代码
    │
    ├── OpenTelemetry SDK
    │       ├── 自动埋点（HTTP、gRPC、DB）
    │       └── 手动埋点（业务逻辑）
    │
    └── OpenTelemetry Collector
            │
            ├── 接收 OTLP 数据
            │
            └── 导出到后端
                    ├── Jaeger (Traces)
                    ├── Prometheus (Metrics)
                    └── Loki (Logs)
```

### Jaeger 架构

```
┌─────────────────────────────────────────┐
│              Jaeger                      │
│                                          │
│  Agent (DaemonSet) ──► Collector ──► DB │
│       │                    │             │
│       │ UDP/gRPC           │             │
│       ▼                    ▼             │
│  应用发送 Trace 数据    处理和存储        │
│                                          │
│  Query Service ◄── UI (可视化)           │
└─────────────────────────────────────────┘
```

---

## 告警

### Prometheus Alertmanager

```yaml
# 告警规则
groups:
- name: k8s-alerts
  rules:
  - alert: HighCPUUsage
    expr: |
      100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High CPU usage on {{ $labels.instance }}"
      description: "CPU usage is above 80% for more than 5 minutes"

  - alert: PodCrashLooping
    expr: |
      rate(kube_pod_container_status_restarts_total[15m]) > 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "Pod {{ $labels.pod }} is crash looping"
```

### 常见告警规则

| 告警 | 表达式 | 级别 |
|------|--------|------|
| 节点 CPU 高 | `100 - avg(irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100 > 80` | warning |
| 节点内存高 | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.85` | warning |
| 节点磁盘满 | `(node_filesystem_avail_bytes / node_filesystem_size_bytes) < 0.1` | critical |
| Pod 崩溃 | `rate(kube_pod_container_status_restarts_total[15m]) > 0` | critical |
| Pod 未就绪 | `kube_pod_status_ready{condition="false"} == 1` | warning |
| API Server 延迟高 | `histogram_quantile(0.99, rate(apiserver_request_duration_seconds_bucket[5m])) > 1` | warning |
| etcd 不健康 | `etcd_server_has_leader != 1` | critical |

---

## 可观测性工具对比

### 开源方案

| 方案 | 组件 | 特点 |
|------|------|------|
| **Prometheus + Grafana** | Metrics | 云原生标准 |
| **EFK** | Elasticsearch + Fluentd + Kibana | 日志搜索强 |
| **PLG** | Promtail + Loki + Grafana | 轻量级日志 |
| **Jaeger** | Traces | CNCF 项目 |
| **SkyWalking** | Metrics/Logs/Traces | APM 一站式 |

### 云厂商方案

| 云厂商 | 方案 |
|--------|------|
| AWS | CloudWatch Container Insights |
| GCP | GKE Monitoring / Cloud Operations |
| Azure | Azure Monitor / Container Insights |
| 阿里云 | ARMS / SLS |

---

## 排查命令

```bash
# Metrics
kubectl top pod -A
kubectl top node
kubectl get hpa
kubectl describe hpa

# Logs
kubectl logs <pod>
kubectl logs <pod> --previous
kubectl logs -l app=my-app --tail=100
kubectl logs -l app=my-app --all-containers
kubectl logs <pod> -c <container>

# 多 Pod 日志
stern my-app

# Events
kubectl get events --sort-by='.lastTimestamp'
kubectl get events --field-selector type=Warning

# 节点日志
journalctl -u kubelet -f
journalctl -u containerd -f

# 链路追踪
kubectl port-forward svc/jaeger-query 16686:16686
# 打开浏览器 http://localhost:16686
```

# Kubernetes 全链路监控方案

## 1. 方案概述

本方案基于 **OpenTelemetry + Prometheus + Grafana + eBPF** 技术栈，构建覆盖基础设施、Kubernetes 编排层、应用服务、业务指标的全链路可观测体系。

### 核心目标
- **统一数据标准**：基于 OpenTelemetry 规范，统一 Metrics/Logs/Traces 采集格式
- **全栈覆盖**：从节点资源到业务指标，从网络流量到应用链路
- **无侵入采集**：通过 eBPF 和自动探针，降低业务改造成本
- **智能告警**：基于多维度数据关联，实现精准告警和快速定位

---

## 2. 整体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           可视化与告警层                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐ │
│  │   Grafana    │  │  Alertmanager│  │   Tempo UI   │  │  智能告警平台 │ │
│  │ (统一大盘)    │  │  (告警路由)   │  │ (链路查询)    │  │ (异常检测)   │ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
┌─────────────────────────────────────────────────────────────────────────┐
│                           数据处理与存储层                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐ │
│  │  Prometheus  │  │    Loki      │  │    Tempo     │  │ Pyroscope   │ │
│  │  (指标存储)   │  │  (日志存储)   │  │ (链路存储)    │  │ (性能剖析)   │ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
┌─────────────────────────────────────────────────────────────────────────┐
│                           数据采集与汇聚层                                │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │              OpenTelemetry Collector (Deployment)                   │ │
│  │         ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │ │
│  │         │  Batch      │  │  Filter     │  │  Transform  │          │ │
│  │         └─────────────┘  └─────────────┘  └─────────────┘          │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                    ▲                                    │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │          OpenTelemetry Collector (DaemonSet) + eBPF Agent           │ │
│  │              节点级采集：网络流、系统调用、容器指标                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
┌─────────────────────────────────────────────────────────────────────────┐
│                           数据采集层                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐ │
│  │ Pod Metrics  │  │  App Logs    │  │  App Traces  │  │  eBPF Agent │ │
│  │(Prometheus)  │  │ (OTel/Fluent)│  │ (OTel SDK)   │  │ (无侵入)     │ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 技术选型

### 3.1 核心组件

| 层级 | 组件 | 用途 | 部署方式 |
|------|------|------|----------|
| **指标** | Prometheus | 时序指标存储与查询 | StatefulSet |
| **日志** | Loki | 日志聚合与查询 | StatefulSet |
| **链路** | Tempo | 分布式追踪存储与查询 | StatefulSet |
| **剖析** | Pyroscope | 持续性能剖析 | StatefulSet |
| **采集** | OpenTelemetry Collector | 统一数据采集与处理 | DaemonSet + Deployment |
| **可视化** | Grafana | 统一可视化平台 | Deployment |
| **告警** | Alertmanager | 告警路由与管理 | Deployment |
| **网络** | eBPF Agent (Hubble/DeepFlow) | 无侵入网络可观测 | DaemonSet |

### 3.2 采集方式对比

| 采集方式 | 侵入性 | 适用场景 | 精度 | 成本 |
|----------|--------|----------|------|------|
| OTel SDK 手动埋点 | 高 | 核心业务指标 | 高 | 高 |
| OTel Auto-Instrumentation | 中 | 通用框架应用 | 中 | 中 |
| eBPF 无侵入采集 | 无 | 网络流量、系统调用 | 较高 | 低 |
| Sidecar 代理 (Istio) | 中 | Service Mesh 环境 | 高 | 中 |

---

## 4. 监控分层设计

### 4.1 基础设施层（IaaS）

监控对象：Node、Network、Storage

| 指标类型 | 采集组件 | 关键指标 |
|----------|----------|----------|
| 节点资源 | Node Exporter + kubelet | CPU/内存/磁盘/网络/负载 |
| 网络质量 | eBPF Agent | TCP 重传、丢包、延迟、DNS 解析 |
| 存储性能 | CSI Driver + Node Exporter | IOPS、吞吐量、延迟、容量 |
| GPU 资源 | DCGM Exporter | GPU 利用率、显存、温度 |

### 4.2 Kubernetes 编排层

监控对象：Cluster、Namespace、Pod、Container

| 指标类型 | 采集组件 | 关键指标 |
|----------|----------|----------|
| 集群状态 | kube-state-metrics | Pod 状态、Deployment 状态、资源配额 |
| 容器资源 | cAdvisor | CPU/内存/网络/磁盘使用量 |
| 调度事件 | Kubernetes Events | Pod 调度失败、驱逐、OOMKilled |
| API Server | API Server Metrics | 请求延迟、QPS、错误率 |
| ETCD | ETCD Metrics | 写入延迟、DB 大小、Leader 状态 |

### 4.3 应用服务层

监控对象：微服务、中间件、数据库

| 指标类型 | 采集组件 | 关键指标 |
|----------|----------|----------|
| HTTP/RPC | OTel SDK / eBPF | QPS、延迟、错误率、吞吐量 |
| JVM | JMX Exporter / OTel Java Agent | GC、堆内存、线程数、类加载 |
| Go Runtime | OTel Go SDK | Goroutine、GC、内存分配 |
| 数据库 | OTel / Exporter | 连接数、慢查询、QPS、锁等待 |
| 消息队列 | OTel / Exporter | 堆积量、消费速率、延迟 |
| 缓存 | Redis Exporter | 命中率、内存、连接数、命令耗时 |

### 4.4 业务指标层

监控对象：业务 KPI、用户体验

| 指标类型 | 采集方式 | 关键指标 |
|----------|----------|----------|
| 业务 KPI | OTel SDK 手动埋点 | 订单量、支付成功率、用户活跃 |
| 前端性能 | RUM (Real User Monitoring) | FCP、LCP、FID、CLS |
| 用户行为 | OTel Events | 页面 PV、点击热图、转化率 |

---

## 5. 分布式链路追踪

### 5.1 Trace 上下文传播

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Ingress  │───▶│ Gateway  │───▶│ Service A│───▶│ Service B│
│ (Nginx)   │    │ (Envoy)  │    │ (Java)   │    │ (Go)     │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
     │                │               │               │
     └────────────────┴───────────────┴───────────────┘
                        Trace Context Propagation
                     (W3C traceparent / B3 headers)
```

### 5.2 采样策略

```yaml
# OpenTelemetry Collector 采样配置
processors:
  # 头部采样：只采集 1% 的链路
  probabilistic_sampler:
    sampling_percentage: 1.0
  
  # 尾部采样：保留错误和慢请求
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 1000
    policies:
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow_requests
        type: latency
        latency: {threshold_ms: 500}
```

### 5.3 多维度关联

| 关联维度 | 关联方式 | 价值 |
|----------|----------|------|
| Trace + Logs | TraceID 注入日志 MDC | 从链路下钻到日志 |
| Trace + Metrics | Span 生成 RED 指标 | 从指标上卷到链路 |
| Trace + Network | eBPF 关联 Pod/Flow | 网络问题定位 |
| Logs + Metrics | 日志提取指标 + 标签关联 | 异常模式发现 |

---

## 6. 日志方案

### 6.1 日志采集架构

```
Pod Container
    │
    ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   stdout    │───▶│  OTel       │───▶│    Loki     │
│  (应用日志)  │    │ Collector   │    │  (日志存储)  │
└─────────────┘    │ (Parser/    │    └─────────────┘
                   │  Enrich)    │
                   └─────────────┘
```

### 6.2 日志结构化

```json
{
  "timestamp": "2024-01-15T08:30:00Z",
  "severity": "ERROR",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "service.name": "order-service",
  "k8s.pod.name": "order-service-7d8f9b2c-x1a2",
  "k8s.namespace.name": "production",
  "message": "Failed to connect to database",
  "error.type": "ConnectionTimeout",
  "http.route": "/api/orders",
  "user_id": "12345"
}
```

---

## 7. 告警体系

### 7.1 告警分级

| 级别 | 场景 | 响应时间 | 通知方式 |
|------|------|----------|----------|
| **P0** | 核心服务完全不可用、数据丢失 | 5分钟 | 电话 + 短信 + IM |
| **P1** | 核心服务性能严重下降、部分不可用 | 15分钟 | 电话 + IM |
| **P2** | 非核心服务异常、容量告警 | 30分钟 | IM + 邮件 |
| **P3** | 资源使用率偏高、预警信息 | 2小时 | IM/邮件 |

### 7.2 核心告警规则

```yaml
# PrometheusRule 示例
groups:
  - name: kubernetes-critical
    rules:
      # Pod 频繁重启
      - alert: PodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total[10m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Pod {{ $labels.pod }} 频繁重启"
          description: "Namespace: {{ $labels.namespace }}, Container: {{ $labels.container }}"

      # 节点资源不足
      - alert: NodeMemoryPressure
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "节点 {{ $labels.instance }} 内存不足"

      # 应用错误率升高
      - alert: HighErrorRate
        expr: |
          sum(rate(http_server_duration_count{status_code=~"5.."}[5m])) 
          / sum(rate(http_server_duration_count[5m])) > 0.05
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "服务 {{ $labels.service_name }} 错误率超过 5%"
```

### 7.3 告警降噪策略

1. **分组聚合**：同一服务/集群的告警合并发送
2. **告警抑制**：节点宕机时抑制该节点上所有 Pod 的不可达告警
3. **静默规则**：计划内维护窗口自动静默相关告警
4. **上下文增强**：告警消息附带 Trace 链接、相关日志、K8s Events

---

## 8. 可视化大盘

### 8.1 分层 Dashboard 设计

| Dashboard | 内容 | 受众 |
|-----------|------|------|
| **集群概览** | 节点资源、Pod 状态、事件 | SRE/运维 |
| **Namespace 视图** | 命名空间资源使用、配额 | 开发团队 |
| **应用服务** | RED 指标、依赖拓扑、健康度 | 开发团队 |
| **链路分析** | 延迟分布、错误链路、依赖图 | 开发/SRE |
| **业务大盘** | 业务 KPI、转化率、用户体验 | 产品/业务 |
| **网络可观测** | 流量拓扑、TCP 质量、DNS | 网络/SRE |

### 8.2 核心 Grafana 面板

```json
// 示例：服务 RED 指标面板
{
  "title": "服务黄金指标 (RED)",
  "panels": [
    {
      "title": "Request Rate",
      "targets": [{
        "expr": "sum(rate(http_server_duration_count{service=\"$service\"}[5m]))"
      }]
    },
    {
      "title": "Error Rate",
      "targets": [{
        "expr": "sum(rate(http_server_duration_count{service=\"$service\",status=~\"5..\"}[5m])) / sum(rate(http_server_duration_count{service=\"$service\"}[5m]))"
      }]
    },
    {
      "title": "Duration (P99)",
      "targets": [{
        "expr": "histogram_quantile(0.99, sum(rate(http_server_duration_bucket{service=\"$service\"}[5m])) by (le))"
      }]
    }
  ]
}
```

---

## 9. eBPF 无侵入监控

### 9.1 适用场景

| 场景 | eBPF 能力 | 优势 |
|------|-----------|------|
| 网络流量分析 | L3-L7 协议解析 | 无需 Sidecar，支持 mTLS |
| 服务拓扑发现 | 自动绘制调用关系 | 零配置，自动发现 |
| 性能剖析 | CPU 火焰图、Off-CPU | 低开销，精准定位 |
| 安全审计 | 系统调用追踪 | 实时检测异常行为 |

### 9.2 部署条件

- Linux 内核版本 >= 4.10（推荐 >= 5.4）
- 节点开启 BPF 特性：`CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y`
- 容器运行时支持：containerd / CRI-O / Docker

---

## 10. 生产最佳实践

### 10.1 性能优化

1. **采样策略**：头采样 1% + 尾部采样（错误/慢请求全采）
2. **数据聚合**：OTel Collector 层做 Batch 和聚合，减少存储压力
3. **资源限制**：
   ```yaml
   resources:
     limits:
       cpu: "2"
       memory: 4Gi
     requests:
       cpu: 500m
       memory: 1Gi
   ```
4. **存储 retention**：
   - Metrics: 15s 粒度 7天，1h 粒度 30天
   - Logs: 7天（热存储）+ 30天（冷存储）
   - Traces: 3天（按采样率动态调整）

### 10.2 高可用

1. Prometheus：联邦集群 + Thanos / Cortex 长期存储
2. Loki：多副本 + S3 后端存储
3. Tempo：多副本 + GCS/S3 对象存储
4. OTel Collector：DaemonSet 保障节点级高可用

### 10.3 安全

1. 敏感数据脱敏：OTel Collector Processor 过滤 PII
2. RBAC：最小权限原则，服务账号分离
3. 网络隔离：监控组件独立 Namespace，NetworkPolicy 限制访问
4. TLS：所有组件间通信启用 mTLS

---

## 11. 部署清单

```bash
# 1. 创建监控命名空间
kubectl create namespace monitoring

# 2. 部署 Prometheus + Alertmanager
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.retention=15d

# 3. 部署 Loki
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set loki.persistence.enabled=true

# 4. 部署 Tempo
helm install tempo grafana/tempo \
  --namespace monitoring \
  --set tempo.storage.trace.backend=local

# 5. 部署 OpenTelemetry Collector
helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --values otel-collector-values.yaml

# 6. 部署 Grafana（如未包含在 kube-prometheus-stack）
helm install grafana grafana/grafana \
  --namespace monitoring \
  --set datasources.default.yaml.datasources[0].url=http://prometheus:9090

# 7. 部署 eBPF Agent（可选）
helm install hubble cilium/hubble \
  --namespace kube-system
```

---

## 12. 总结

| 维度 | 方案亮点 |
|------|----------|
| **标准化** | OpenTelemetry 统一采集协议，避免供应商锁定 |
| **全链路** | Metrics + Logs + Traces + Profiles 全覆盖 |
| **无侵入** | eBPF + Auto-Instrumentation 降低接入成本 |
| **智能化** | 尾部采样 + 告警关联 + 上下文增强，快速定位 |
| **可扩展** | 云原生架构，水平扩展，支持多集群联邦 |

---

## 参考文档

- [OpenTelemetry 官方文档](https://opentelemetry.io/docs/)
- [Prometheus 最佳实践](https://prometheus.io/docs/practices/)
- [Grafana LGTM Stack](https://grafana.com/go/webinar/getting-started-with-lgtm/)
- [eBPF 云原生可观测性](https://ebpf.io/applications/)

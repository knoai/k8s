# Service Mesh 监控（Istio）

> Istio 作为最流行的 Service Mesh，提供了丰富的流量管理、安全和可观测能力。本节深入 Istio 监控体系。

---

## 1. Istio 可观测架构

```
┌─────────────────────────────────────────────────────────────────┐
│                          Workload                                │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐     │
│  │   App Pod   │◄────►│ Envoy Sidecar│◄────►│  Network    │     │
│  │             │      │  (Metrics)   │      │             │     │
│  └─────────────┘      └──────┬──────┘      └─────────────┘     │
│                              │                                   │
│                         ┌────┴────┐                             │
│                         │ istio-proxy │                          │
│                         └────┬────┘                             │
└──────────────────────────────┼──────────────────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ↓                ↓                ↓
         Prometheus        Grafana          Kiali
         (指标采集)        (可视化)         (拓扑图)
              ↓                ↓                ↓
         istio_requests_total  Service Map    Traffic Flow
```

---

## 2. Istio 标准指标

### 2.1 流量指标（四大黄金指标）

| 指标 | 类型 | 说明 |
|------|------|------|
| `istio_requests_total` | Counter | 请求总数（最重要） |
| `istio_request_duration_seconds` | Histogram | 请求延迟 |
| `istio_request_bytes` | Histogram | 请求大小 |
| `istio_response_bytes` | Histogram | 响应大小 |
| `istio_tcp_sent_bytes_total` | Counter | TCP 发送字节 |
| `istio_tcp_received_bytes_total` | Counter | TCP 接收字节 |

### 2.2 指标标签

```
istio_requests_total{
  reporter="destination",           # source/destination
  source_workload="frontend",
  source_workload_namespace="default",
  source_app="frontend",
  destination_workload="order-service",
  destination_workload_namespace="default",
  destination_app="order-service",
  destination_service="order-service.default.svc.cluster.local",
  request_protocol="http",
  response_code="200",
  response_flags="-",
  connection_security_policy="mutual_tls"
}
```

---

## 3. Istio 监控部署

### 3.1 启用 Telemetry

```yaml
# telemetry.yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: default-metrics
  namespace: istio-system
spec:
  metrics:
    - providers:
        - name: prometheus
      overrides:
        # 自定义标签
        - match:
            metric: REQUEST_COUNT
          tagOverrides:
            custom_destination:
              value: "unknown"
              operation: UPSERT
```

### 3.2 ServiceMonitor 采集 Envoy 指标

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: istio-envoy-stats
  namespace: istio-system
  labels:
    release: prometheus-stack
spec:
  namespaceSelector:
    any: true
  selector:
    matchExpressions:
      - key: security.istio.io/tlsMode
        operator: Exists
  podMetricsEndpoints:
    - port: envoy-prom
      path: /stats/prometheus
      interval: 15s
      relabelings:
        - action: keep
          sourceLabels: [__meta_kubernetes_pod_container_port_name]
          regex: '.*-envoy-prom'
        - action: labeldrop
          regex: "(pod|service|namespace)"
```

---

## 4. Istio 专属 PromQL

### 4.1 RED 指标

```promql
# Request Rate (QPS)
sum(rate(istio_requests_total{reporter="destination"}[5m])) by (destination_app)

# Error Rate
sum(rate(istio_requests_total{reporter="destination",response_code=~"5.."}[5m]))
/
sum(rate(istio_requests_total{reporter="destination"}[5m]))

# Duration P99
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination"}[5m])) by (le, destination_app)
)
```

### 4.2 服务拓扑查询

```promql
# 查看服务间调用关系
sum(istio_requests_total) by (source_app, destination_app)

# 查看 mTLS 使用率
sum(istio_requests_total{connection_security_policy="mutual_tls"})
/
sum(istio_requests_total)

# 查看重试次数
sum(rate(istio_requests_total{response_flags=~"UR|UF|UO"}[5m]))
```

### 4.3 故障注入监控

```promql
# 延迟注入后的 P99
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{destination_app="order-service"}[5m])) by (le)
)

# 故障注入后的错误率
sum(rate(istio_requests_total{destination_app="order-service",response_code=~"5.."}[5m]))
/
sum(rate(istio_requests_total{destination_app="order-service"}[5m]))
```

---

## 5. Kiali 服务拓扑

```bash
# 安装 Kiali
helm repo add kiali https://kiali.org/helm-charts
helm install kiali-server kiali/kiali-server \
  --namespace istio-system \
  --set auth.strategy="anonymous"

# 访问 Kiali
kubectl port-forward svc/kiali 20001:20001 -n istio-system &
open http://localhost:20001
```

**Kiali 核心功能**：
- 实时服务拓扑图
- 流量分布（金丝雀发布可视化）
- 流量健康度（错误率、延迟）
- 工作负载详情

---

## 6. Istio + eBPF（Ambient Mesh）

Istio 1.18+ 引入 Ambient Mesh，使用 eBPF 替代 Sidecar：

```bash
# 安装 Ambient Mesh
istioctl install --set profile=ambient

# 启用 ztunnel（eBPF 数据面）
kubectl label namespace default istio.io/dataplane-mode=ambient
```

**优势**：
- 无 Sidecar，资源消耗降低 40%
- eBPF 采集流量，性能更高
- 与 Hubble 集成，网络可观测性更强

---

## 7. Istio 告警规则

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: istio-alerts
  namespace: istio-system
spec:
  groups:
    - name: istio-traffic
      rules:
        - alert: IstioHighErrorRate
          expr: |
            sum(rate(istio_requests_total{reporter="destination",response_code=~"5.."}[5m])) by (destination_app)
            /
            sum(rate(istio_requests_total{reporter="destination"}[5m])) by (destination_app) > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Istio 服务 {{ $labels.destination_app }} 错误率过高"

        - alert: IstioHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(istio_request_duration_milliseconds_bucket{reporter="destination"}[5m])) by (le, destination_app)
            ) > 2000
          for: 5m
          labels:
            severity: warning

        - alert: IstioSidecarMissing
          expr: |
            (kube_pod_labels * on(pod) group_left() (1 - kube_pod_container_info{name="istio-proxy"}))
            > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} 缺少 Istio Sidecar"
```

---

## 8. Istio vs eBPF 方案对比

| 维度 | Istio Sidecar | Istio Ambient (eBPF) | Cilium + Hubble |
|------|---------------|---------------------|-----------------|
| **架构** | Sidecar Proxy | eBPF + Waypoint | eBPF |
| **性能** | 中（延迟增加 2-3ms） | 高（延迟增加 <1ms） | 高 |
| **资源** | 高（每个 Pod 一个 Envoy） | 低（节点级 ztunnel） | 低 |
| **mTLS** | ✅ | ✅ | ❌（需额外配置） |
| **L7 路由** | ✅ 完整 | ✅ Waypoint 补充 | ⚠️ 有限 |
| **拓扑图** | ✅ Kiali | ✅ Kiali | ✅ Hubble UI |
| **适用场景** | 需要完整 L7 控制 | 大规模、性能敏感 | 网络监控为主 |

---

## 参考

- [Istio Observability](https://istio.io/latest/docs/tasks/observability/)
- [Istio Metrics](https://istio.io/latest/docs/reference/config/metrics/)
- [Kiali Documentation](https://kiali.io/docs/)
- [Ambient Mesh](https://istio.io/latest/docs/ops/ambient/)

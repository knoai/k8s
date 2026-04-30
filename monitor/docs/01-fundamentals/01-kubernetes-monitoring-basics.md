# Kubernetes 监控基础

## 1. 为什么需要监控 Kubernetes

Kubernetes 已成为容器编排的事实标准，但管理复杂部署具有挑战性。全面的可观测性对于确保应用稳定性和高效资源利用至关重要。

### 监控的核心目标
- **性能监控**：检测高 CPU、内存或磁盘使用，在影响服务前发现问题
- **告警**：配置 Prometheus 告警，通过 Alertmanager 通知团队潜在故障
- **容量规划**：分析历史数据规划基础设施扩缩容
- **安全监控**：检测可疑模式和未授权访问尝试

---

## 2. 核心监控概念

### 2.1 Metrics（指标）
指标是随时间变化的数值数据，用于衡量系统状态和性能。

**四大黄金指标（Four Golden Signals）**：
| 指标 | 说明 | 示例 |
|------|------|------|
| **Latency（延迟）** | 请求处理时间 | HTTP 响应时间 P50/P99 |
| **Traffic（流量）** | 系统负载/请求量 | QPS、RPS |
| **Errors（错误）** | 失败请求比例 | 5xx 错误率 |
| **Saturation（饱和度）** | 资源使用接近上限程度 | CPU 使用率、内存使用率 |

**RED 方法（面向微服务）**：
- **R**ate：请求率
- **E**rrors：错误率
- **D**uration：请求持续时间

**USE 方法（面向资源）**：
- **U**tilization：资源使用率
- **S**aturation：资源饱和度
- **E**rrors：错误计数

### 2.2 Logs（日志）
日志是系统事件的文本记录，用于故障排查和审计。

### 2.3 Traces（链路追踪）
链路追踪记录请求在微服务间的完整调用路径，用于定位延迟和错误根因。

---

## 3. Prometheus 基础

### 3.1 Prometheus 架构

```
┌─────────────┐     scrape      ┌─────────────┐
│   Targets   │◄────────────────│  Prometheus │
│ (Exporters) │                 │   Server    │
└─────────────┘                 └──────┬──────┘
                                       │
                              ┌────────▼────────┐
                              │  Time Series DB │
                              └────────┬────────┘
                                       │
                              ┌────────▼────────┐
                              │  PromQL / API   │
                              └────────┬────────┘
                                       │
                              ┌────────▼────────┐
                              │  Alertmanager   │
                              └─────────────────┘
```

### 3.2 指标类型

| 类型 | 说明 | 使用场景 |
|------|------|----------|
| **Counter** | 单调递增计数器，重启归零 | 请求总数、错误总数 |
| **Gauge** | 可增可减的瞬时值 | 温度、内存使用量、当前连接数 |
| **Histogram** | 采样值分布，分桶计数 | 请求延迟分布、请求大小 |
| **Summary** | 类似 Histogram，但计算滑动分位 | 请求延迟分位数（客户端计算） |

### 3.3 核心 Exporters

| Exporter | 监控对象 |
|----------|----------|
| Node Exporter | Linux 节点资源（CPU/内存/磁盘/网络） |
| kube-state-metrics | K8s 资源状态（Pod/Deployment/Node 状态） |
| cAdvisor | 容器资源使用 |
| Blackbox Exporter | 外部探测（HTTP/TCP/ICMP） |

---

## 4. Grafana 可视化基础

### 4.1 核心功能
- 多数据源支持（Prometheus、Loki、Tempo、InfluxDB 等）
- 可交互的 Dashboard
- 告警和通知
- 变量和模板

### 4.2 Dashboard 设计原则
1. **KISS**：保持简单，面板数量适度
2. **一致性**：所有 Dashboard 统一设计风格
3. **标签化**：用标签组织 Dashboard，便于查找
4. **受众导向**：
   - 开发团队：详细诊断面板
   - 管理层：聚合 SLA/SLO 概览面板

### 4.3 常用 Dashboard ID（导入即用）

| Dashboard | ID | 说明 |
|-----------|-----|------|
| Kubernetes Cluster Monitoring | 6417 | 集群整体监控 |
| Node Exporter Full | 1860 | 节点详细监控 |
| Kubernetes Pods | 747 | Pod 监控 |
| Kubernetes Deployment | 8588 | Deployment 监控 |

---

## 5. 快速部署入门

### 5.1 使用 Helm 一键部署

```bash
# 添加仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 一键部署 Prometheus + Grafana + Alertmanager
helm install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace

# 查看密码
kubectl get secret --namespace monitoring prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode

# 端口转发访问
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80
kubectl port-forward -n monitoring svc/prometheus-stack-kube-p-prometheus 9090:9090
```

### 5.2 配置 Grafana 数据源

1. 登录 Grafana（默认 admin/prom-operator）
2. Configuration → Data Sources → Add data source
3. 选择 Prometheus，URL 填 `http://prometheus-stack-kube-p-prometheus:9090`
4. Save & Test

---

## 6. 常见错误与最佳实践

### 常见错误
- **不设告警**：只监控不告警等于没监控
- **忽略数据保留策略**：Prometheus 存储大量时序数据，需设置 retention
- **Dashboard 过于复杂**：信息过载反而降低效率

### 最佳实践
- **有效使用 Labels**：Labels 帮助高效分类指标
- **优化采集间隔**：过于频繁的采集会造成高开销
- **定期审查 Dashboard**：随基础设施演进更新

---

## 参考资源

- [Prometheus 官方文档](https://prometheus.io/docs/introduction/overview/)
- [Grafana 官方文档](https://grafana.com/docs/)
- [Kubernetes 监控指南](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/)
- [Google SRE Book - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)

# 实践案例总览

> 每个案例都是完整的、可落地的操作手册，复制粘贴即可执行。

## 案例列表

| 案例 | 难度 | 预计耗时 | 核心技能 |
|------|------|----------|----------|
| [案例一：Prometheus CRD 全栈实践](case1-prometheus-crd/) | ⭐⭐⭐ | 2-3 小时 | Prometheus Operator、ServiceMonitor、PrometheusRule、Alertmanager |
| [案例二：JVM 监控三种方式对比](case2-jvm-monitoring/) | ⭐⭐⭐ | 3-4 小时 | JMX Exporter、OTel Java Agent、Micrometer、Spring Boot |
| [案例三：Grafana 数据关联下钻](case3-grafana-integration/) | ⭐⭐⭐⭐ | 2-3 小时 | Grafana Provisioning、Exemplars、Metrics→Trace→Logs |
| [案例四：微服务全链路可观测](case4-fullstack-observability/) | ⭐⭐⭐⭐⭐ | 1-2 天 | 综合：OTel + Prometheus + Loki + Tempo + Grafana |

## 环境准备

所有案例基于以下环境：
- Kubernetes 集群（1.25+）
- kubectl + Helm 3
- 至少 4 核 8GB 内存的节点

```bash
# 前置检查
kubectl cluster-info
helm version

# 创建专用 namespace
kubectl create namespace observability-demo --dry-run=client -o yaml | kubectl apply -f -
```

## 快速清理

每个案例目录下都有 `cleanup.sh`，执行即可清理该案例资源：
```bash
cd cases/case1-prometheus-crd
./cleanup.sh
```

# K8s 监控排障速查表

## Prometheus 排障

```bash
# 查看 targets 状态
kubectl port-forward svc/prometheus 9090:9090
open http://localhost:9090/targets

# 查看告警规则
open http://localhost:9090/rules

# 查看告警状态
open http://localhost:9090/alerts

# TSDB 状态
curl http://localhost:9090/api/v1/status/tsdb

# 指标基数检查
open http://localhost:9090/api/v1/status/tsdb | jq .data.headStats

# 查看 Prometheus 日志
kubectl logs -n monitoring -l app=prometheus --tail=100

# 检查 WAL 目录大小
kubectl exec -it -n monitoring prometheus-0 -- du -sh /prometheus/wal
```

## Grafana 排障

```bash
# 查看 Grafana 日志
kubectl logs -n monitoring -l app=grafana --tail=100

# 获取 admin 密码
kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode

# 测试数据源连通性
curl -H "Authorization: Bearer $API_KEY" http://grafana/api/datasources
```

## Loki 排障

```bash
# 查看 Loki 状态
curl http://loki:3100/ready

# 查看 Loki 日志
kubectl logs -n monitoring -l app=loki --tail=100

# 测试推送日志
curl -X POST http://loki:3100/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(( $(date +%s) * 1000000000 ))'","test log"]]}]}'
```

## Tempo 排障

```bash
# 查看 Tempo 状态
curl http://tempo:3200/ready

# 通过 TraceID 查询
curl http://tempo:3200/api/traces/<trace-id>
```

## OTel Collector 排障

```bash
# 健康检查
curl http://otel-collector:13133/health

# zpages 调试
curl http://otel-collector:55679/debug/tracez
curl http://otel-collector:55679/debug/rpcz

# 查看自身指标
curl http://otel-collector:8888/metrics

# 内存使用
curl http://otel-collector:8888/metrics | grep otelcol_process_memory

# 查看日志
kubectl logs -n monitoring -l app=otel-collector --tail=100
```

## eBPF / Hubble 排障

```bash
# 检查 Hubble 是否启用
kubectl get configmap -n kube-system cilium-config -o yaml | grep hubble

# 查看 Hubble Relay 日志
kubectl logs -n kube-system -l app.kubernetes.io/name=hubble-relay --tail=50

# Hubble CLI 查看实时流量
hubble observe -f
hubble observe --namespace production -f
hubble observe --verdict DROPPED -f

# 检查 Cilium 状态
cilium status

# 检查 eBPF 程序加载
bpftool prog list
```

## 网络排障

```bash
# 进入 Pod 网络命名空间抓包
kubectl debug -it <pod> --image=nicolaka/netshoot -- tcpdump -i any -w /tmp/capture.pcap

# 测试 DNS 解析
kubectl run -it --rm debug --image=busybox:1.28 -- nslookup kubernetes.default

# 测试网络连通性
kubectl run -it --rm debug --image=busybox:1.28 -- wget -O- <service>:<port>
```

## 资源排障

```bash
# 查看节点资源
kubectl top nodes

# 查看 Pod 资源
kubectl top pods -n <namespace>

# 查看 Pod 事件
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# 查看 Pod 详细状态
kubectl describe pod <pod-name> -n <namespace>

# 查看 OOM 事件
kubectl get events -n <namespace> | grep -i oom
```

## 常用 Dashboard ID

| Dashboard | ID | 说明 |
|-----------|-----|------|
| Node Exporter Full | 1860 | 节点完整监控 |
| Kubernetes Cluster | 6417 | 集群概览 |
| Kubernetes Pods | 747 | Pod 监控 |
| Kubernetes Deployment | 8588 | Deployment |
| Kubernetes StatefulSet | 8589 | StatefulSet |
| Cilium Metrics | 16611 | Cilium 网络指标 |
| JVM Micrometer | 4701 | Java 应用监控 |
| Go Runtime | 10826 | Go 应用监控 |

## 常用端口速查

| 组件 | 端口 | 说明 |
|------|------|------|
| Prometheus | 9090 | Web UI / API |
| Grafana | 3000 | Web UI |
| Alertmanager | 9093 | Web UI |
| Loki | 3100 | HTTP API |
| Tempo | 3200 | HTTP API |
| OTel Collector OTLP gRPC | 4317 | 接收遥测数据 |
| OTel Collector OTLP HTTP | 4318 | 接收遥测数据 |
| OTel Collector Metrics | 8888 | 自身指标 |
| OTel Health Check | 13133 | 健康检查 |
| OTel zpages | 55679 | 调试页面 |
| Hubble Relay | 4245 | gRPC API |
| Hubble UI | 8081 | Web UI |

# 生产环境监控最佳实践

## 1. 架构设计原则

### 1.1 高可用架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        多集群联邦                                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │  Cluster A  │    │  Cluster B  │    │  Cluster C  │         │
│  │ (Region:BJ) │    │ (Region:SH) │    │ (Region:SZ) │         │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘         │
│         │                  │                  │                │
│         └──────────────────┼──────────────────┘                │
│                            ▼                                   │
│              ┌─────────────────────────┐                       │
│              │    Thanos / Cortex      │                       │
│              │    (全局查询 + 长期存储)   │                       │
│              └─────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

| 组件 | 高可用方案 |
|------|-----------|
| Prometheus | 联邦集群 + Thanos Sidecar |
| Grafana | 多实例 + 共享数据库 |
| Alertmanager | 集群模式（gossip 协议） |
| Loki | 多副本 + S3 后端 |
| Tempo | 多副本 + GCS/S3 对象存储 |

### 1.2 数据流设计

```
Pod → Node Agent → OTel Collector (DaemonSet)
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
    Prometheus    Loki        Tempo
    (短期热存储)  (中期存储)   (短期存储)
          │           │           │
          └───────────┴───────────┘
                      ▼
               Thanos/Cortex
               (长期冷存储 S3)
```

---

## 2. 性能优化

### 2.1 Prometheus 优化

```yaml
# prometheus.yaml
storage:
  tsdb:
    # 数据保留期
    retention.time: 15d
    retention.size: 50GB
    
    # 写入性能
    min-block-duration: 2h
    max-block-duration: 2h
    
    # 查询性能
    query.max-concurrency: 20
    query.timeout: 2m

# 采集配置
scrape_configs:
  - job_name: 'kubernetes-pods'
    scrape_interval: 15s      # 默认 15s
    scrape_timeout: 10s
    # 大规模集群可适当放宽到 30s
```

### 2.2 基数控制

```promql
# 检测高基数指标
topk(10, count by (__name__) ({__name__=~".+"}))

# 检测高基数标签
topk(10, count by (label_name) (metric_name))
```

**避免高基数标签**：
- ❌ user_id、email、session_id、IP 地址
- ❌ URL 路径中的动态 ID（如 `/api/users/12345`）
- ✅ 使用 pattern 归一化：`/api/users/{id}`
- ✅ 使用租户 ID、服务版本、环境标签

### 2.3 存储分层

| 数据类型 | 热存储 | 温存储 | 冷存储 |
|----------|--------|--------|--------|
| Metrics | 15s 粒度 7 天 | 5m 粒度 30 天 | 1h 粒度 1 年 |
| Logs | 原始 3 天 | 聚合 7 天 | 归档 90 天 |
| Traces | 采样后 3 天 | 错误链路 7 天 | - |

---

## 3. 安全与合规

### 3.1 数据安全

```yaml
# OTel Collector 敏感数据过滤
processors:
  attributes:
    actions:
      # 删除敏感字段
      - key: http.request.header.authorization
        action: delete
      - key: db.statement
        action: delete
      - key: email
        action: hash
      
      # 脱敏密码
      - key: password
        action: update
        value: "[REDACTED]"
```

### 3.2 访问控制

```yaml
# Grafana RBAC
[auth]
disable_login_form = false

[auth.generic_oauth]
enabled = true
name = SSO
allow_sign_up = true
client_id = grafana
client_secret = xxx
scopes = openid profile email groups
role_attribute_path = contains(groups[*], 'admin') && 'Admin' || contains(groups[*], 'editor') && 'Editor' || 'Viewer'
```

### 3.3 网络安全

```yaml
# NetworkPolicy 限制监控组件访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus-network-policy
  namespace: monitoring
spec:
  podSelector:
    matchLabels:
      app: prometheus
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
      ports:
        - protocol: TCP
          port: 9090
```

---

## 4. 成本优化

### 4.1 采样策略

```yaml
# 链路追踪采样
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      # 错误全采
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}
      # 慢请求全采
      - name: slow
        type: latency
        latency: {threshold_ms: 500}
      # 正常请求 1% 采样
      - name: normal
        type: probabilistic
        probabilistic: {sampling_percentage: 1}
```

### 4.2 数据降采样

```yaml
# Prometheus Recording Rules 预聚合
groups:
  - name: downsampling
    interval: 300s  # 5 分钟聚合
    rules:
      - record: :node_cpu_usage:avg_rate5m
        expr: avg(rate(node_cpu_seconds_total{mode!="idle"}[5m]))
      
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)
```

### 4.3 资源限制

```yaml
# Collector 资源限制
resources:
  limits:
    cpu: "2"
    memory: 4Gi
  requests:
    cpu: 500m
    memory: 1Gi

# Prometheus 资源限制
resources:
  limits:
    cpu: "4"
    memory: 16Gi
  requests:
    cpu: "1"
    memory: 8Gi
```

---

## 5. 运维 checklist

### 5.1 部署前检查

- [ ] 评估集群规模（节点数、Pod 数、QPS）
- [ ] 确定数据保留策略
- [ ] 规划存储容量（Metrics/Logs/Traces 分别估算）
- [ ] 配置资源限制（request/limit）
- [ ] 配置持久化存储（PV/PVC）
- [ ] 配置备份策略
- [ ] 设置告警规则
- [ ] 配置告警接收渠道

### 5.2 部署后验证

- [ ] 验证所有组件运行正常
- [ ] 验证数据采集完整
- [ ] 验证 Dashboard 显示正常
- [ ] 验证告警规则生效
- [ ] 验证告警通知可达
- [ ] 测试故障演练
- [ ] 文档化 Runbook

### 5.3 日常运维

- [ ] 监控监控系统的资源使用
- [ ] 定期检查磁盘空间
- [ ] 审查告警有效性（减少误报）
- [ ] 更新 Dashboard 和告警规则
- [ ] 定期备份配置
- [ ] 升级组件版本

---

## 6. 故障排查

### 6.1 Prometheus 常见问题

| 问题 | 排查 | 解决 |
|------|------|------|
| 内存 OOM | 检查 TSDB 块数量和查询复杂度 | 降低 retention、优化查询、增加内存 |
| 磁盘满 | 检查 WAL 和 checkpoint | 清理旧数据、扩容磁盘 |
| 采集失败 | 检查 target 状态和网络 | 调整 scrape_timeout、检查防火墙 |
| 查询慢 | 检查查询范围和基数 | 使用 Recording Rules、缩小查询范围 |

### 6.2 Collector 常见问题

```bash
# 查看 Collector 状态
curl http://otel-collector:13133/health

# 查看 zpages 调试信息
curl http://otel-collector:55679/debug/tracez

# 查看内存使用
curl http://otel-collector:8888/metrics | grep otelcol_process_memory
```

### 6.3 排查命令速查

```bash
# 查看 Prometheus targets
kubectl port-forward svc/prometheus 9090:9090
open http://localhost:9090/targets

# 查看告警状态
kubectl port-forward svc/alertmanager 9093:9093
open http://localhost:9093

# 查看 Loki 状态
curl http://loki:3100/ready

# 查看 Tempo 状态
curl http://tempo:3200/ready

# 查看 Pod 日志
kubectl logs -n monitoring -l app=prometheus --tail=100
kubectl logs -n monitoring -l app=otel-collector --tail=100
```

---

## 参考资源

- [Prometheus 操作指南](https://prometheus.io/docs/prometheus/latest/storage/)
- [Thanos 文档](https://thanos.io/)
- [Cortex 文档](https://cortexmetrics.io/)
- [Kubernetes 监控最佳实践](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/)

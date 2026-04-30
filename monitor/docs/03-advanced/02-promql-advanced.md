# PromQL 进阶与告警工程

## 1. 高级查询模式

### 1.1 环比与同比

```promql
# 环比：当前值 vs 1小时前
(
  sum(rate(http_requests_total[5m]))
  -
  sum(rate(http_requests_total[5m] offset 1h))
)
/
sum(rate(http_requests_total[5m] offset 1h))

# 同比：当前值 vs 1天前
sum(rate(http_requests_total[5m]))
/
sum(rate(http_requests_total[5m] offset 1d))
```

### 1.2 预测告警

```promql
# 预测磁盘将在 4 小时内填满
predict_linear(node_filesystem_free_bytes{fstype!="tmpfs"}[1h], 4 * 3600) < 0

# 预测内存将在 2 小时内耗尽
predict_linear(node_memory_MemAvailable_bytes[30m], 2 * 3600) < 0
```

### 1.3 多条件组合告警

```promql
# 错误率高 AND 有实际流量时才告警（避免低流量误报）
(
  sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
  /
  sum(rate(http_requests_total[5m])) by (service)
  > 0.05
)
and
(
  sum(rate(http_requests_total[5m])) by (service) > 10
)
```

### 1.4 基数爆炸检测

```promql
# 检测指标基数过高（可能导致 Prometheus 性能问题）
count by (__name__) ({__name__=~".+"}) > 10000
```

---

## 2. SLO 与 Error Budget

### 2.1 SLO 工程基础

| 概念 | 说明 | 示例 |
|------|------|------|
| **SLI** | 服务水平指标 | 请求延迟、可用性 |
| **SLO** | 服务水平目标 | P99 延迟 < 200ms，可用性 > 99.9% |
| **SLA** | 服务水平协议（对外承诺） | SLO + 违约赔偿 |
| **Error Budget** | 错误预算 = 1 - SLO | 99.9% SLO = 0.1% 错误预算 |

### 2.2 多窗口燃烧率告警

Google SRE 推荐的告警策略：快速消耗错误预算时立即告警，慢速消耗时延后告警。

```yaml
groups:
  - name: slo-alerts
    rules:
      # 快速消耗（1 小时窗口）：6% 错误预算在 1 小时内消耗完
      - alert: ErrorBudgetBurnFast
        expr: |
          (
            sum(rate(http_requests_total{status=~"5.."}[1h])) by (service)
            /
            sum(rate(http_requests_total[1h])) by (service)
          ) > (14.4 * (1 - 0.999))
        for: 2m
        labels:
          severity: critical
          window: "1h"
        annotations:
          summary: "{{ $labels.service }} 快速消耗错误预算"

      # 慢速消耗（6 小时窗口）：2% 错误预算在 6 小时内消耗完
      - alert: ErrorBudgetBurnSlow
        expr: |
          (
            sum(rate(http_requests_total{status=~"5.."}[6h])) by (service)
            /
            sum(rate(http_requests_total[6h])) by (service)
          ) > (6 * (1 - 0.999))
        for: 15m
        labels:
          severity: warning
          window: "6h"
        annotations:
          summary: "{{ $labels.service }} 慢速消耗错误预算"
```

### 2.3 OpenSLO 规范

```yaml
# openslo/checkout-slo.yaml
apiVersion: openslo/v1
kind: SLO
metadata:
  name: checkout-availability
  displayName: Checkout API Availability
spec:
  service: checkout-api
  description: Availability SLO for checkout endpoint
  budgetingMethod: Occurrences
  objectives:
    - displayName: 99.95% availability
      target: 0.9995
      ratioMetrics:
        good:
          source: prometheus
          queryType: promql
          query: sum(rate(http_requests_total{service="checkout",code=~"2.."}[5m]))
        total:
          source: prometheus
          queryType: promql
          query: sum(rate(http_requests_total{service="checkout"}[5m]))
  timeWindow:
    - duration: 30d
      isRolling: true
```

---

## 3. 告警工程最佳实践

### 3.1 告警设计原则

| 原则 | 说明 |
|------|------|
| **可行动** | 每个告警必须有明确的处理动作 |
| **症状导向** | 告警用户可见的症状，而非原因 |
| **分层分级** | P0（立即响应）→ P3（次日处理） |
| **避免噪音** | 使用 `for` 持续时间和阈值过滤 |

### 3.2 告警分级

```yaml
# P0 - 立即响应（电话 + 短信 + IM）
- alert: ServiceDown
  expr: up{job=~"critical-.*"} == 0
  for: 2m
  labels:
    severity: p0

# P1 - 15分钟内响应（电话 + IM）
- alert: HighErrorRate
  expr: error_rate > 0.1
  for: 5m
  labels:
    severity: p1

# P2 - 30分钟内响应（IM + 邮件）
- alert: HighLatency
  expr: latency_p99 > 1
  for: 10m
  labels:
    severity: p2

# P3 - 次日处理（邮件）
- alert: DiskWillFillIn72Hours
  expr: predict_linear(disk_free[6h], 72*3600) < 0
  for: 1h
  labels:
    severity: p3
```

### 3.3 告警降噪策略

```yaml
# Alertmanager 配置
route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'default'
  routes:
    # P0 立即通知
    - match:
        severity: p0
      receiver: 'pagerduty-critical'
      group_wait: 0s
      repeat_interval: 5m
    
    # P1 合并后通知
    - match:
        severity: p1
      receiver: 'slack-ops'
      group_wait: 2m

inhibit_rules:
  # 节点宕机时抑制该节点上所有 Pod 的不可达告警
  - source_match:
      alertname: 'NodeDown'
    target_match_re:
      alertname: 'PodNotReady|PodCrashLooping'
    equal: ['node']
```

### 3.4 告警模板最佳实践

```yaml
annotations:
  summary: "{{ $labels.service }} {{ $labels.alertname }}"
  description: |
    服务: {{ $labels.service }}
    实例: {{ $labels.instance }}
    当前值: {{ $value | humanizePercentage }}
    
    排查步骤:
    1. 查看 Grafana 面板: https://grafana/d/{{ $labels.service }}
    2. 查看相关 Trace: https://grafana/explore?traceId={{ $labels.trace_id }}
    3. 查看日志: https://grafana/explore?orgId=1&left=%7B%22datasource%22:%22Loki%22%7D
    
    Runbook: https://wiki.example.com/runbooks/{{ $labels.alertname }}
```

---

## 4. Recording Rules 工程化

### 4.1 分层 Recording Rules

```yaml
groups:
  # 第1层：原始指标预处理
  - name: raw-metrics
    interval: 15s
    rules:
      - record: instance:node_cpu:rate5m
        expr: rate(node_cpu_seconds_total[5m])
      
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)

  # 第2层：聚合指标
  - name: aggregated-metrics
    interval: 30s
    rules:
      - record: cluster:cpu_usage:avg
        expr: avg(instance:node_cpu:rate5m{mode!="idle"})
      
      - record: service:error_rate:ratio
        expr: |
          job:http_errors:rate5m / job:http_requests:rate5m

  # 第3层：SLO 指标
  - name: slo-metrics
    interval: 60s
    rules:
      - record: slo:availability:ratio_1h
        expr: |
          sum(rate(http_requests_total{code=~"2.."}[1h]))
          /
          sum(rate(http_requests_total[1h]))
      
      - record: slo:latency:p99_1h
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[1h])) by (le)
          )
```

---

## 5. Grafana Alerting（新版）

### 5.1 迁移到 Grafana Unified Alerting

```yaml
# values.yaml 中启用统一告警
grafana:
  alerting:
    enabled: true
  unified_alerting:
    enabled: true
```

### 5.2 Alert Rule Group

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: kubernetes-alerts
    folder: Infrastructure
    interval: 60s
    rules:
      - uid: node-cpu-alert
        title: Node CPU High
        condition: B
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: prometheus
            model:
              expr: 100 - avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100
          - refId: B
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [85]
        noDataState: NoData
        execErrState: Error
        for: 5m
        annotations:
          summary: "Node CPU high"
        labels:
          severity: warning
```

---

## 参考资源

- [Google SRE Book - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Google SRE Workbook - Alerting](https://sre.google/workbook/alerting/)
- [OpenSLO 规范](https://openslo.com/)
- [Sloth - SLO 生成器](https://sloth.dev/)
- [Prometheus Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
- [Alertmanager 配置](https://prometheus.io/docs/alerting/latest/configuration/)

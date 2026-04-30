# SLO 工程与 Google SRE 实践

> SLO（服务级别目标）是 SRE 的核心方法论。将可靠性量化、将告警与用户体验关联、用错误预算驱动发布决策，这是从"救火式运维"到"工程化运维"的关键转变。

---

## 1. 核心概念：SLI / SLO / SLA

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SLI / SLO / SLA 定义与关系                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   SLI (Service Level Indicator)                                             │
│   ─────────────────────────────                                             │
│   服务级别指标：可量化的可靠性测量                                           │
│                                                                             │
│   示例:                                                                      │
│   • 请求延迟: 95% 的请求在 200ms 内完成                                      │
│   • 错误率: 0.1% 的请求返回 5xx                                              │
│   • 可用性: 服务 99.9% 的时间可用                                            │
│   • 吞吐量: 每秒处理 10000 个请求                                            │
│                                                                             │
│   SLO (Service Level Objective)                                             │
│   ─────────────────────────────                                             │
│   服务级别目标：SLI 要达到的目标值                                           │
│                                                                             │
│   示例: "本季度，95% 的请求延迟 < 200ms"                                     │
│                                                                             │
│   SLA (Service Level Agreement)                                             │
│   ─────────────────────────────                                             │
│   服务级别协议：对外承诺，违约有经济赔偿                                       │
│                                                                             │
│   示例: "如果月度可用性 < 99.9%，赔偿月度费用的 10%"                          │
│                                                                             │
│   关系: SLI 是测量指标 → SLO 是目标 → SLA 是商业合同                          │
│          SLO 通常比 SLA 更严格（内部 buffer）                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 常见 SLI 类型

| 类别 | SLI | 测量方式 |
|------|-----|---------|
| **可用性** | 服务可响应请求的比例 | 成功请求数 / 总请求数 |
| **延迟** | 响应时间分布 | P50/P90/P95/P99 百分位 |
| **质量** | 返回正确结果的比例 | 正确响应 / 总响应 |
| **吞吐量** | 单位时间处理量 | QPS / TPS |
| **覆盖率** | 数据/功能完整度 | 缓存命中率、数据新鲜度 |

---

## 2. 错误预算（Error Budget）

### 2.1 什么是错误预算

```
错误预算 = 1 - SLO

示例:
  SLO = 99.9% 可用性
  错误预算 = 0.1% = 每月约 43 分钟不可用

┌─────────────────────────────────────────────────────────────┐
│                    错误预算可视化                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  100% │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│       │███████████████████████████████████████████████████│  │
│  99.9%│░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│  │
│       ↑                                                     │
│    SLO 线                                                    │
│                                                             │
│  ░░░░░ = 错误预算（允许的不可靠时间）                        │
│                                                             │
│  规则:                                                       │
│  • 错误预算充足 → 可以发布新功能、承担风险                   │
│  • 错误预算耗尽 → 停止发布，集中精力修复可靠性               │
│  • 错误预算为负 → 启动紧急响应，考虑降级/回滚                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 错误预算计算

```
可用性目标与错误预算对照表:

| 可用性  | 每月允许停机 | 每年允许停机 | 错误预算 |
|---------|-------------|-------------|---------|
| 99%     | 7.2 小时    | 3.65 天     | 1%      |
| 99.9%   | 43 分钟     | 8.76 小时   | 0.1%    |
| 99.95%  | 22 分钟     | 4.38 小时   | 0.05%   |
| 99.99%  | 4.3 分钟    | 52 分钟     | 0.01%   |
| 99.999% | 26 秒       | 5.2 分钟    | 0.001%  |

延迟 SLO 的错误预算:
  SLO: 95% 的请求延迟 < 200ms
  错误预算: 5% 的请求可以 >= 200ms

PromQL 计算错误预算消耗:
  # 可用性错误预算消耗率
  rate(http_requests_total{status=~"5.."}[1d])
  /
  rate(http_requests_total[1d])
  
  # 结果: 0.001 = 0.1%，在 99.9% SLO 的预算内
```

---

## 3. 多窗口燃烧率告警

### 3.1 燃烧率（Burn Rate）

```
燃烧率 = 当前错误率 / 错误预算率

示例:
  SLO: 99.9% (错误预算 0.1%)
  当前 1 小时错误率: 1%
  燃烧率 = 1% / 0.1% = 10x

含义: 按当前速度，错误预算将在 1/10 周期内耗尽

多窗口告警策略（Google SRE 推荐）:

┌─────────────────────────────────────────────────────────────┐
│                    燃烧率告警矩阵                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  快速燃尽（需要立即响应）                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 窗口    │ 燃烧率 │ 消耗预算 │ 响应时间               │   │
│  │ 2 小时  │  14.4x │   2%     │ 立即（ paging ）       │   │
│  │ 1 小时  │  14.4x │   1%     │ 立即（ paging ）       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  慢速燃尽（需要关注）                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 窗口    │ 燃烧率 │ 消耗预算 │ 响应时间               │   │
│  │ 3 天    │   2x   │   5%     │ 24h 内（ ticket ）     │   │
│  │ 6 小时  │   6x   │   5%     │ 下个工作日（ ticket ） │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  关键数字: 14.4 = (30 天 / 2 小时) × 1%                     │
│           即: 2 小时内消耗 2% 月度预算 = 14.4 倍燃烧率       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Prometheus 告警规则

```yaml
# slo-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-burn-rate-alerts
  namespace: monitoring
spec:
  groups:
    # ========== 定义 Recording Rules ==========
    - name: slo.recording
      rules:
        # 总请求数 (1m rate)
        - record: slo:api_requests_total:rate1m
          expr: sum(rate(http_requests_total{job="api-gateway"}[1m]))
        
        # 错误请求数 (1m rate)
        - record: slo:api_errors_total:rate1m
          expr: sum(rate(http_requests_total{job="api-gateway",status=~"5.."}[1m]))
        
        # 错误率 (1h)
        - record: slo:api_error_rate:ratio_rate1h
          expr: |
            sum(rate(http_requests_total{job="api-gateway",status=~"5.."}[1h]))
            /
            sum(rate(http_requests_total{job="api-gateway"}[1h]))
        
        # 错误率 (5m)
        - record: slo:api_error_rate:ratio_rate5m
          expr: |
            sum(rate(http_requests_total{job="api-gateway",status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{job="api-gateway"}[5m]))
        
        # 错误率 (6h)
        - record: slo:api_error_rate:ratio_rate6h
          expr: |
            sum(rate(http_requests_total{job="api-gateway",status=~"5.."}[6h]))
            /
            sum(rate(http_requests_total{job="api-gateway"}[6h]))
        
        # 错误率 (3d)
        - record: slo:api_error_rate:ratio_rate3d
          expr: |
            sum(rate(http_requests_total{job="api-gateway",status=~"5.."}[3d]))
            /
            sum(rate(http_requests_total{job="api-gateway"}[3d]))

    # ========== 燃烧率告警 ==========
    - name: slo.burn_rate
      rules:
        # 快速燃尽 - 1小时窗口 (14.4x 燃烧率)
        # 意味着 1 小时消耗 1% 月度预算
        - alert: APIErrorBudgetBurn1h
          expr: |
            (
              slo:api_error_rate:ratio_rate1h > (14.4 * 0.001)  # 14.4 * 0.1%
            and
              slo:api_error_rate:ratio_rate5m > (14.4 * 0.001)
            )
            or
            (
              slo:api_error_rate:ratio_rate6h > (6 * 0.001)     # 6x 燃烧率
            and
              slo:api_error_rate:ratio_rate30m > (6 * 0.001)
            )
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "API error budget is burning fast"
            description: "Error rate is {{ $value | humanizePercentage }}. Budget will be exhausted soon."
        
        # 慢速燃尽 - 3天窗口 (2x 燃烧率)
        - alert: APIErrorBudgetBurn3d
          expr: |
            (
              slo:api_error_rate:ratio_rate3d > (2 * 0.001)
            and
              slo:api_error_rate:ratio_rate6h > (2 * 0.001)
            )
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "API error budget is burning slowly"
            description: "Error rate over 3 days is {{ $value | humanizePercentage }}."

    # ========== SLO 状态 Dashboard 用 ==========
    - name: slo.status
      rules:
        - record: slo:api_availability:ratio
          expr: |
            1 - (
              sum(rate(http_requests_total{job="api-gateway",status=~"5.."}[30d]))
              /
              sum(rate(http_requests_total{job="api-gateway"}[30d]))
            )
        
        - record: slo:api_latency:p95_30d
          expr: |
            histogram_quantile(0.95,
              sum(rate(http_request_duration_seconds_bucket{job="api-gateway"}[30d])) by (le)
            )
```

---

## 4. SLO 设计实践

### 4.1 设计原则

```
1. 用户导向
   • 从用户可感知的行为定义 SLO
   • 不要从系统内部指标定义（如 CPU 使用率）
   ✓ "99% 的请求在 200ms 内完成"
   ✗ "CPU 使用率 < 80%"

2. 可测量
   • SLI 必须能通过现有监控数据计算
   • 避免无法自动化的手工测量

3. 可执行
   • SLO 达成/未达成时，团队知道该做什么
   • 错误预算耗尽 → 停止发布

4. 分层 SLO
   • 基础设施层: 节点可用性 99.9%
   • 平台层: K8s API 可用性 99.95%
   • 应用层: 业务 API 可用性 99.9%
   • 用户层: 页面加载时间 P95 < 2s

5. 不要过度追求
   • 99.999% 的成本可能是 99.9% 的 10 倍
   • 评估业务真实需求
```

### 4.2 SLO 文档模板

```markdown
# API Gateway SLO

## 服务信息
- 服务名称: api-gateway
- 团队: Platform
- 负责人: xxx
- 最后更新: 2024-01-15

## SLO 定义

### 可用性
- 目标: 99.9%
- SLI: 非 5xx 响应的比例
- 测量: sum(rate(http_requests_total{status!~"5.."}[30d])) / sum(rate(http_requests_total[30d]))
- 错误预算: 0.1% = 每月 43 分钟

### 延迟
- 目标: P95 < 200ms
- SLI: 95% 的请求延迟
- 测量: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[30d])) by (le))
- 错误预算: 5% 的请求可以 >= 200ms

### 错误率
- 目标: < 0.1%
- SLI: 5xx 响应比例
- 测量: sum(rate(http_requests_total{status=~"5.."}[30d])) / sum(rate(http_requests_total[30d]))

## 告警
- 快速燃尽: 1h/5m 窗口, 14.4x 燃烧率 → Paging
- 慢速燃尽: 3d/6h 窗口, 2x 燃烧率 → Ticket

## 应急响应
1. 错误预算 > 50% 耗尽: 召集团队复盘
2. 错误预算 100% 耗尽: 停止非紧急发布
3. 连续两个周期预算耗尽: 启动专项改进
```

---

## 5. Grafana SLO Dashboard

```json
// SLO Dashboard 关键面板

{
  "title": "SLO Status - API Gateway",
  "panels": [
    {
      "title": "Availability SLO",
      "type": "stat",
      "targets": [
        {
          "expr": "slo:api_availability:ratio",
          "legendFormat": "Current"
        },
        {
          "expr": "0.999",
          "legendFormat": "Target (99.9%)"
        }
      ],
      "fieldConfig": {
        "thresholds": {
          "steps": [
            {"color": "red", "value": 0},
            {"color": "yellow", "value": 0.999},
            {"color": "green", "value": 0.9995}
          ]
        }
      }
    },
    {
      "title": "Error Budget Remaining",
      "type": "gauge",
      "targets": [
        {
          "expr": "1 - (slo:api_error_rate:ratio_rate30d / 0.001)"
        }
      ],
      "fieldConfig": {
        "max": 1,
        "min": -1,
        "thresholds": {
          "steps": [
            {"color": "red", "value": -1},
            {"color": "yellow", "value": 0},
            {"color": "green", "value": 0.5}
          ]
        }
      }
    },
    {
      "title": "Burn Rate (1h)",
      "type": "graph",
      "targets": [
        {
          "expr": "slo:api_error_rate:ratio_rate1h / 0.001",
          "legendFormat": "1h burn rate"
        },
        {
          "expr": "14.4",
          "legendFormat": "Critical (14.4x)"
        }
      ]
    }
  ]
}
```

---

## 6. 面试高频题

**Q: SLO 和 SLA 的区别？**

<details>
<summary>答案</summary>

- **SLI**: 服务级别指标，可量化的测量值（如错误率 0.1%）
- **SLO**: 服务级别目标，SLI 要达到的目标值（如错误率 < 0.1%），内部使用
- **SLA**: 服务级别协议，对外承诺，违约有经济赔偿（如可用性 99.9%，否则赔偿 10%）

SLO 通常比 SLA 更严格，留出内部 buffer。

</details>

**Q: 为什么推荐多窗口燃烧率告警而不是简单阈值？**

<details>
<summary>答案</summary>

简单阈值告警的问题：
1. 静态阈值无法适应流量波动
2. 高流量时 1% 错误可能是大量请求，低流量时 50% 错误可能很少请求
3. 频繁误报或漏报

多窗口燃烧率的优势：
1. 同时考虑短窗口（灵敏度）和长窗口（验证）
2. 与错误预算直接关联，反映真实风险
3. 不同燃烧率对应不同响应级别（ paging vs ticket ）

</details>

---

## 参考资源

- [Google SRE Book - SLO 章节](https://sre.google/sre-book/table-of-contents/)
- [Google SRE Workbook - Alerting](https://sre.google/workbook/alerting/)
- [Prometheus SLO 告警最佳实践](https://prometheus.io/docs/practices/alerting/)
- [SLO 模板](https://github.com/google/sre-room-101/blob/main/workbook/slo-document-template.md)

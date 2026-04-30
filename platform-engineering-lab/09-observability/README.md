# 09 - 可观测性体系建设

可观测性（Observability）不是监控的同义词。监控告诉你系统是否正常工作，
可观测性让你理解系统为什么这样工作。在平台工程中，可观测性体系是
平台的核心能力之一，需要为所有应用提供统一的日志、指标、追踪和告警。

## 学习目标

1. 理解可观测性三大支柱（Metrics/Logs/Traces）的关系和差异
2. 掌握 Prometheus + Grafana 的指标采集和可视化
3. 掌握分布式追踪（Jaeger/Tempo）的实现和查询
4. 学会设计有效的告警规则（减少告警疲劳）
5. 建立 SLO/SLI 体系，从监控转向可靠性工程
6. 掌握 OpenTelemetry 统一采集标准

## 核心概念

### 可观测性三大支柱

**指标（Metrics）**: 可聚合的数值数据，回答"系统现在的状态是什么？"
- 示例: CPU 使用率 45%、请求 QPS 1200、错误率 0.1%
- 特点: 低基数、高频率、适合趋势分析
- 工具: Prometheus、VictoriaMetrics、Thanos
- 采集方式: Pull（Prometheus 主动拉取）或 Push（应用主动推送）
- 数据模型: 时间序列（timestamp + value + labels）

**日志（Logs）**: 离散的事件记录，回答"系统发生了什么？"
- 示例: "2024-01-15 10:23:45 ERROR 连接数据库超时"
- 特点: 高基数、低频率、适合故障排查
- 工具: Loki、ELK（Elasticsearch + Logstash + Kibana）、Fluentd
- 结构化日志: JSON 格式，便于查询和分析
- 日志级别: DEBUG / INFO / WARN / ERROR / FATAL

**追踪（Traces）**: 请求的完整链路，回答"请求经过了哪些服务？"
- 示例: 用户请求 → API Gateway → Order Service → DB（每步耗时）
- 特点: 展示因果关系、适合延迟分析
- 工具: Jaeger、Tempo、SkyWalking、Zipkin
- Span: 追踪的基本单位，记录一个操作的详细信息
- Trace ID: 全局唯一标识，贯穿整个调用链

**关系**: 指标发现问题，日志定位问题，追踪理解问题。
三者不是替代关系，而是互补关系。

**统一关联**: 通过 Correlation ID（Trace ID）将三者关联:
- 指标中记录 Trace ID 的采样率
- 日志中嵌入 Trace ID 和 Span ID
- 追踪中包含业务上下文（用户 ID、订单 ID）

### 告警设计原则

**避免告警疲劳**:
- 告警数量应 < 人均 5 条/天
- P0 告警（立即响应）应 < 1 条/周
- 每个告警必须有明确的处理手册（Runbook）
- 告警关闭后应有后续跟踪（是否根治）

**告警分级**:

| 级别 | 名称 | 响应时间 | 通知方式 | 示例 |
|------|------|---------|---------|------|
| P0 | 紧急 | 5 分钟 | 电话 + 短信 + PagerDuty | 核心服务完全不可用 |
| P1 | 严重 | 30 分钟 | 短信 + 邮件 + Slack | 部分功能不可用，有降级方案 |
| P2 | 警告 | 4 小时 | 邮件 + Slack | 性能下降，用户体验受损 |
| P3 | 信息 | 24 小时 | Slack | 非紧急问题，需要关注 |

**告警设计检查清单**:
- [ ] 告警是否可行动？（收到后知道该做什么）
- [ ] 是否有明确的阈值依据？（不是拍脑袋）
- [ ] 是否避免了重复告警？（同一问题只发一次）
- [ ] 是否有自动恢复？（问题消失后自动关闭）
- [ ] 是否考虑了告警抑制？（维护期间不告警）

**Prometheus 告警规则示例**:
```yaml
groups:
- name: api-alerts
  rules:
  - alert: HighErrorRate
    expr: |
      rate(http_requests_total{status=~"5.."}[5m])
      /
      rate(http_requests_total[5m]) > 0.01
    for: 2m
    labels:
      severity: p1
    annotations:
      summary: "High error rate detected"
      description: "Error rate is {{ $value | humanizePercentage }}"
      runbook_url: "https://wiki/runbooks/high-error-rate"
```

### SLO/SLI/SLA 体系

**SLI（Service Level Indicator）**: 可量化的指标
- 示例: HTTP 请求延迟、错误率、可用性百分比
- 选择原则: 用户可感知、可量化、可控制
- 常见 SLI:
  - 可用性: 成功请求数 / 总请求数
  - 延迟: P50/P95/P99 响应时间
  - 吞吐量: QPS / TPS
  - 错误率: 4xx/5xx 错误占比

**SLO（Service Level Objective）**: SLI 的目标值
- 示例: P99 延迟 < 200ms，错误率 < 0.1%，可用性 > 99.9%
- 设置原则: 基于历史数据，留出错误预算
- SLO 不是越高越好，需要权衡成本和收益

**SLA（Service Level Agreement）**: 对外承诺，违反有惩罚
- 示例: 可用性 99.95%，月度不可用时间 < 21.6 分钟
- 与 SLO 的区别: SLA 更严格（通常 SLO > SLA）
- 内部使用 SLO，对外承诺使用 SLA

**错误预算（Error Budget）**: 允许的不达标时间
- 计算: 错误预算 = 1 - SLO
- 示例: 99.9% 可用性 = 每月 43.2 分钟错误预算
- 使用: 错误预算耗尽时，暂停发布，优先稳定性
- 政策: 错误预算低于 50% 时预警，低于 20% 时禁止发布

## 模块内容

### Prometheus 监控体系

文件: `prometheus-setup.md`

Prometheus 架构:
```
    Service Discovery → Target → Exporter → Prometheus → AlertManager → Notification
                                          ↓
                                        Grafana
```

核心概念:
- **Metric Types**: Counter（累计值）、Gauge（瞬时值）、Histogram（分布）、Summary（分位数）
- **PromQL**: 查询语言，支持聚合、过滤、计算
- **Recording Rules**: 预计算复杂查询，提高查询性能
- **Alerting Rules**: 定义告警条件
- **Service Discovery**: 自动发现监控目标（K8s、Consul、EC2）

常用 Exporter:
- node-exporter: 节点级指标（CPU、内存、磁盘、网络）
- kube-state-metrics: K8s 资源状态指标
- cadvisor: 容器级指标
- mysqld-exporter: MySQL 指标
- redis-exporter: Redis 指标

### Grafana 可视化

文件: `grafana-dashboards.md`

Dashboard 设计原则:
- 一个 Dashboard 回答一个核心问题
- 从上到下: 概览 → 详情 → 原始数据
- 使用颜色编码: 绿色（正常）、黄色（警告）、红色（严重）
- 添加面板描述，说明指标含义和阈值依据
- 使用变量（Variables）实现动态过滤
- 使用模板（Templating）实现复用

### 分布式追踪

文件: `distributed-tracing.md`

追踪实现:
- **OpenTelemetry**: 统一的采集标准，支持自动插桩
- **Jaeger**: 存储和查询追踪数据
- **Trace 分析**: 识别慢调用、错误传播、服务依赖
- **采样策略**: 头部采样、尾部采样、概率采样

OpenTelemetry 自动插桩:
```python
# Python 示例
from opentelemetry import trace
from opentelemetry.exporter.jaeger.thrift import JaegerExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

trace.set_tracer_provider(TracerProvider())
tracer = trace.get_tracer(__name__)

jaeger_exporter = JaegerExporter(
    agent_host_name="jaeger-agent",
    agent_port=6831,
)
span_processor = BatchSpanProcessor(jaeger_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)
```

### 日志聚合

文件: `log-aggregation.md`

Loki 架构:
```
App → Promtail → Loki → Grafana
```

优势:
- 与 Prometheus 标签模型一致
- 存储成本低（只索引标签，不索引日志内容）
- 与 Grafana 深度集成
- 支持 LogQL 查询语言

Loki 部署模式:
- Monolithic: 单实例，适合小规模
- Simple Scalable: 读写分离，适合中等规模
- Distributed: 微服务架构，适合大规模

## 面试常见问题

**Q: Metrics vs Logs vs Traces 如何选择？**

A: 不是选择，而是组合使用:
- **Metrics**: 用于监控趋势、设置告警、容量规划
- **Logs**: 用于故障排查、审计、安全分析
- **Traces**: 用于延迟分析、依赖梳理、性能优化

最佳实践: 所有服务同时输出三种数据，通过 Correlation ID 关联。
在 Grafana 中可以将三者联动: 从 Metrics 告警跳转到 Logs 查询，
从 Logs 跳转到 Traces。

**Q: 如何设计有效的告警？**

A: 五个原则:
1. **可行动**: 收到告警后知道该做什么
2. **有依据**: 阈值基于历史数据和业务需求
3. **避免噪音**: 同一问题只发一次，自动恢复后关闭
4. **分层**: P0/P1/P2/P3，不同级别不同响应时间
5. **有手册**: 每个告警对应一个 Runbook

反例: "CPU 使用率 > 80%" → 不知道该怎么办
正例: "订单服务 P99 延迟 > 500ms，Runbook: https://wiki/runbooks/latency"

**Q: SLO 设置的常见错误？**

A: 三大错误:
1. **SLO 过高**: 99.999% 需要极高投入，可能不值得
2. **SLO 无错误预算**: 没有缓冲空间，小故障就触发紧急响应
3. **SLO 与业务无关**: 监控了 CPU 使用率，但用户关心的是页面加载时间

**Q: 如何处理告警疲劳？**

A: 四步法:
1. **统计**: 统计每个人每天收到的告警数量
2. **分类**: 区分有效告警和噪音告警
3. **优化**: 调整阈值、合并相似告警、添加抑制规则
4. **文化**: 建立"告警即债务"文化，定期清理无效告警

目标: 人均每天 < 5 条告警，P0 每周 < 1 条。

**Q: OpenTelemetry 的优势？**

A:
- 统一标准: 一个 SDK 同时采集 Metrics/Logs/Traces
- vendor-neutral: 不绑定特定厂商
- 自动插桩: 支持多种语言和框架的自动采集
- 社区活跃: CNCF 孵化项目，生态丰富
- 向后兼容: 兼容 OpenCensus 和 OpenTracing

**Q: Prometheus 的 Pull 模式 vs Push 模式？**

A:
- **Pull 模式**: Prometheus 主动拉取指标
  优点: 易于发现目标故障（拉取失败即知道目标异常）
  缺点: 短生命周期 Pod 可能错过采集

- **Push 模式**: 应用主动推送指标（如 Prometheus Pushgateway）
  优点: 适合批处理和短生命周期任务
  缺点: 需要额外组件，故障检测复杂

Prometheus 默认使用 Pull 模式，这是其设计哲学。

**Q: 如何选择追踪采样策略？**

A:
- **头部采样**: 在请求入口处决定是否采样
  优点: 简单，无存储浪费
  缺点: 可能错过异常请求

- **尾部采样**: 在请求完成后决定是否采样
  优点: 可以基于结果采样（如只采样错误请求）
  缺点: 需要缓冲所有追踪，内存开销大

- **概率采样**: 按固定概率采样
  优点: 简单，可预测
  缺点: 可能采样不到稀有事件

生产推荐: 概率采样（1-10%）+ 尾部采样（错误请求 100% 采样）。

**Q: 日志结构化 vs 非结构化？**

A:
- **非结构化**: "2024-01-15 ERROR 连接超时"
  缺点: 难以查询和分析，需要正则解析

- **结构化（JSON）**: {"timestamp": "2024-01-15", "level": "ERROR", "message": "连接超时", "service": "order-service"}
  优点: 易于查询、分析、关联

推荐: 所有日志使用 JSON 格式，包含标准字段（timestamp、level、service、trace_id）。

## 参考资源

- [Prometheus 文档](https://prometheus.io/docs/)
- [Grafana 最佳实践](https://grafana.com/docs/grafana/latest/best-practices/)
- [OpenTelemetry](https://opentelemetry.io/)
- [Google SRE Book - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Loki 文档](https://grafana.com/docs/loki/)
- [Jaeger 文档](https://www.jaegertracing.io/docs/)
- [Distributed Systems Observability](https://www.oreilly.com/library/view/distributed-systems-observability/9781492033431/)

## 可观测性体系构建实践

### 数据采集架构

典型的可观测性数据采集架构:

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│   Metrics   │   │    Logs     │   │   Traces    │
│  Prometheus │   │    Loki     │   │   Jaeger    │
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │                 │
       └─────────────────┼─────────────────┘
                         │
                    ┌────┴────┐
                    │ Grafana │
                    │ (统一视图)│
                    └─────────┘
```

### 指标采集最佳实践

**应用指标（自定义）**:
```python
from prometheus_client import Counter, Histogram, Gauge

# 请求计数器
request_count = Counter('http_requests_total', 'Total requests', ['method', 'endpoint', 'status'])

# 请求延迟直方图
request_duration = Histogram('http_request_duration_seconds', 'Request duration', ['endpoint'])

# 当前连接数
current_connections = Gauge('http_connections_current', 'Current connections')
```

**基础设施指标（标准）**:
- node-exporter: CPU、内存、磁盘、网络、文件描述符
- kube-state-metrics: Deployment、Pod、Node、PVC 状态
- cadvisor: 容器级 CPU、内存、网络、磁盘 I/O

**指标命名规范**:
- 使用蛇形命名: `http_requests_total`
- 包含单位: `_seconds`, `_bytes`, `_total`
- 避免高基数标签: 不要使用 user_id、email 作为标签

### 日志采集最佳实践

**结构化日志格式**:
```json
{
  "timestamp": "2024-01-15T10:23:45.123Z",
  "level": "ERROR",
  "service": "order-service",
  "trace_id": "abc123",
  "span_id": "def456",
  "message": "数据库连接超时",
  "context": {
    "user_id": "12345",
    "order_id": "67890",
    "db_host": "db.internal"
  }
}
```

**日志级别使用指南**:
- DEBUG: 开发调试信息，生产环境不输出
- INFO: 正常业务流程（请求开始/结束、状态变更）
- WARN: 异常情况但已处理（重试、降级）
- ERROR: 业务错误（需要人工介入）
- FATAL: 系统级错误（进程退出）

### 追踪采集最佳实践

**Span 命名规范**:
- 使用 "{操作} {资源}" 格式: `GET /api/orders`, `SELECT orders`
- 避免动态值: 不要 `GET /api/orders/12345`

**Span 属性（Attributes）**:
- http.method: HTTP 方法
- http.url: 请求 URL
- http.status_code: 响应状态码
- db.system: 数据库类型（mysql, redis）
- db.statement: SQL 语句（注意脱敏）

**Baggage（跨服务传递的上下文）**:
- user.id: 用户 ID
- tenant.id: 租户 ID
- request.id: 请求 ID

### 统一告警体系

**告警规则分层**:

| 层级 | 范围 | 示例 |
|------|------|------|
| 基础设施 | 集群/节点 | 节点 CPU > 80%，节点内存 > 90% |
| 平台服务 | K8s 组件 | API Server 延迟 > 1s，etcd  Leader 变更 |
| 应用指标 | 业务服务 | 错误率 > 1%，P99 延迟 > 500ms |
| 业务指标 | 业务 KPI | 订单成功率 < 99%，支付失败率 > 0.1% |

**告警通知渠道**:
- P0: PagerDuty / 电话
- P1: Slack + 邮件
- P2: 邮件
- P3: Slack 频道

### 可观测性成熟度模型

| 级别 | 特征 | 工具 |
|------|------|------|
| L1 | 基础监控 | 主机监控、简单告警 |
| L2 | 应用监控 | APM、分布式追踪 |
| L3 | 统一可观测性 | Metrics/Logs/Traces 关联 |
| L4 | 智能可观测性 | AI 异常检测、自动根因分析 |

## 面试常见问题补充

**Q: Prometheus 的 Histogram 和 Summary 有什么区别？**

A:
- **Histogram**: 客户端分桶，服务端计算分位数
  - 优点: 可以聚合（多个实例的 histogram 可以相加）
  - 缺点: 分桶需要预先定义，精度受限

- **Summary**: 客户端计算分位数，服务端直接暴露
  - 优点: 精度高
  - 缺点: 不可聚合

推荐: 大多数场景使用 Histogram，需要精确分位数时使用 Summary。

**Q: 日志采集中的性能考虑？**

A:
1. **异步写入**: 日志写入使用异步队列，避免阻塞业务
2. **批量发送**: 聚合多条日志后一次性发送
3. **压缩传输**: 使用 gzip 压缩日志数据
4. **采样**: 高频日志进行采样（如只记录 1%）
5. **本地缓冲**: 网络故障时本地缓存，恢复后重传

**Q: 如何处理追踪数据量过大的问题？**

A:
1. **采样**: 只采样 1-10% 的追踪数据
2. **尾部采样**: 只保留异常/慢请求的追踪
3. **保留策略**: 自动删除 7 天前的追踪数据
4. **聚合**: 将相似追踪聚合为模式（pattern）


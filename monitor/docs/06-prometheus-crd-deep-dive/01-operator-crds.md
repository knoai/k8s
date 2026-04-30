# Prometheus Operator CRD 深入

> prometheus-operator 通过 CRD 将 Prometheus 配置声明式化，是 K8s 上部署 Prometheus 的事实标准。深入理解 CRD 是面试和生产的必备技能。

---

## 1. CRD 全景图

```
┌─────────────────────────────────────────────────────────────────┐
│                     Prometheus Operator                           │
│                                                                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │  Prometheus  │    │ServiceMonitor│    │    Rules     │      │
│  │    CRD       │    │    CRD       │    │   CRD        │      │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘      │
│         │                   │                   │               │
│         └───────────────────┴───────────────────┘               │
│                             │                                   │
│                    ┌────────▼────────┐                         │
│                    │  Operator 控制器 │                         │
│                    │  (watch → reconcile)│                      │
│                    └────────┬────────┘                         │
│                             │                                   │
│         ┌───────────────────┼───────────────────┐              │
│         ▼                   ▼                   ▼              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐       │
│  │  StatefulSet│    │  ConfigMap  │    │   Secret    │       │
│  │  Prometheus │    │ prometheus.yml│   │   TLS/Certs │       │
│  └─────────────┘    └─────────────┘    └─────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Prometheus CRD

### 2.1 核心配置详解

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
  namespace: monitoring
spec:
  # 副本数（高可用）
  replicas: 2

  # 数据保留策略
  retention: 15d
  retentionSize: "50GB"

  # ServiceMonitor 选择器（自动发现）
  serviceMonitorSelector:
    matchLabels:
      release: prometheus
  serviceMonitorNamespaceSelector:
    any: true  # 扫描所有 namespace

  # PodMonitor 选择器
  podMonitorSelector:
    matchLabels:
      release: prometheus

  # Alertmanager 关联
  alerting:
    alertmanagers:
      - namespace: monitoring
        name: alertmanager
        port: web

  # 规则选择器
  ruleSelector:
    matchLabels:
      role: alert-rules
      prometheus: prometheus

  # 远程存储（Thanos/VM）
  remoteWrite:
    - url: http://thanos-receive:19291/api/v1/receive
      queueConfig:
        maxSamplesPerSend: 10000
        maxShards: 200
      writeRelabelConfigs:
        - sourceLabels: [__name__]
          regex: 'up|prometheus_.*'
          action: drop  # 不转发系统指标

  remoteRead:
    - url: http://thanos-store:9090/api/v1/read
      readRecent: true

  # 资源限制
  resources:
    requests:
      memory: 4Gi
      cpu: "1"
    limits:
      memory: 16Gi
      cpu: "4"

  # 持久化存储
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: standard
        resources:
          requests:
            storage: 100Gi

  # 安全：禁用 admin API
  enableAdminAPI: false

  # 禁用远端执行（防止未授权查询）
  enableRemoteWriteReceiver: false

  # 查询配置
  query:
    maxConcurrency: 20  # 最大并发查询数
    timeout: 2m         # 查询超时

  # TSDB 配置
  tsdb:
    outOfOrderTimeWindow: 0s  # 乱序数据时间窗口

  # 抓取配置（全局）
  scrapeInterval: 15s
  scrapeTimeout: 10s
  evaluationInterval: 15s

  # 外部标签（多集群标识）
  externalLabels:
    cluster: production-bj
    replica: $(POD_NAME)

  # Pod 级别配置
  podMetadata:
    labels:
      app: prometheus
    annotations:
      prometheus.io/scrape: "false"

  # 亲和性/反亲和性（多副本时分散节点）
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
          topologyKey: kubernetes.io/hostname

  # 安全上下文
  securityContext:
    fsGroup: 2000
    runAsUser: 1000
    runAsNonRoot: true

  # 附加参数
  additionalArgs:
    - name: log.level
      value: debug
```

### 2.2 多 Prometheus 分片（Sharding）

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus-shard-0
spec:
  shards: 3  # 自动创建 3 个分片
  shardIdentity: 0
  # 每个分片只抓取部分 target
```

分片原理：
```
Shard 0: hash(target) % 3 == 0  → 抓取 1/3 targets
Shard 1: hash(target) % 3 == 1  → 抓取 1/3 targets
Shard 2: hash(target) % 3 == 2  → 抓取 1/3 targets
                ↓
         Thanos Querier 聚合全局视图
```

### 2.3 Thanos Sidecar 集成

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
spec:
  thanos:
    image: thanosio/thanos:v0.34.0
    objectStorageConfig:
      name: thanos-objstore
      key: thanos.yaml
    # 其他 Thanos 参数
    additionalArgs:
      - --min-time=-2h
      - --max-time=-1h
```

---

## 3. ServiceMonitor CRD

### 3.1 完整配置

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app-metrics
  namespace: production
  labels:
    release: prometheus  # 与 Prometheus CRD 的 serviceMonitorSelector 匹配
spec:
  # 选择目标 Service
  selector:
    matchLabels:
      app: my-app
    matchExpressions:
      - key: tier
        operator: In
        values: [frontend, backend]

  # 扫描的 namespace（为空则只扫描当前 namespace）
  namespaceSelector:
    any: true            # 扫描所有 namespace
    # matchNames:        # 或指定 namespace 列表
    #   - production
    #   - staging

  # 端点配置
  endpoints:
    # 端点 1：应用指标
    - port: metrics      # Service 中定义的 port name
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      honorLabels: true   # 保留目标原始 labels（解决外部标签冲突）
      honorTimestamps: true

      # 协议（http/https）
      scheme: http

      # TLS 配置（用于 https endpoint）
      tlsConfig:
        insecureSkipVerify: false
        caFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        certFile: /etc/prometheus/secrets/cert.pem
        keyFile: /etc/prometheus/secrets/key.pem

      # Bearer Token
      bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token

      # 自定义抓取参数
      params:
        format: [prometheus]

      # 指标过滤（relabel 配置）
      metricRelabelings:
        # 丢弃高基数指标
        - sourceLabels: [__name__]
          regex: '.*_bucket'  # 示例：丢弃所有 bucket
          action: drop
        # 标签重写
        - sourceLabels: [__name__]
          regex: 'jvm_memory_.*'
          targetLabel: category
          replacement: memory
          action: replace

      # 目标 relabel（抓取前）
      relabelings:
        # 将 Pod IP 作为 instance 标签
        - sourceLabels: [__meta_kubernetes_pod_ip]
          targetLabel: instance
          action: replace
        # 添加 namespace 标签
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: k8s_namespace
          action: replace

    # 端点 2：健康检查指标（不同 path）
    - port: metrics
      path: /actuator/prometheus
      interval: 30s
```

### 3.2 relabel 详解

```
Prometheus 抓取流程中的 relabel 阶段：

1. Service Discovery → 原始 labels（__meta_*）
      ↓
2. relabelings（ServiceMonitor endpoints 中配置）
      → 修改 target 标签（如 instance、job）
      → 删除/保留 target（action: keep/drop）
      ↓
3. 抓取目标 → 获取指标数据
      ↓
4. metricRelabelings
      → 修改/删除指标名和标签
      → 丢弃整行指标（action: drop）
      ↓
5. 写入 TSDB
```

**常用 action**：

| action | 作用 |
|--------|------|
| `replace` | 替换标签值（默认） |
| `keep` | 只保留匹配的目标 |
| `drop` | 删除匹配的目标/指标 |
| `hashmod` | 计算 hash 取模（分片用） |
| `labelmap` | 正则匹配后创建新标签 |
| `labeldrop` | 删除匹配的标签 |
| `lowercase` / `uppercase` | 大小写转换 |

### 3.3 PodMonitor（无 Service 场景）

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: envoy-sidecar-metrics
  namespace: istio-system
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      security.istio.io/tlsMode: istio
  namespaceSelector:
    any: true
  podMetricsEndpoints:
    - port: envoy-prom
      path: /stats/prometheus
      interval: 15s
      # Envoy 需要这个 relabel
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_container_port_name]
          regex: envoy-prom
          action: keep
```

---

## 4. PrometheusRule CRD

### 4.1 告警规则高级配置

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: application-alerts
  namespace: monitoring
  labels:
    role: alert-rules        # 必须与 Prometheus CRD 的 ruleSelector 匹配
    prometheus: prometheus
spec:
  groups:
    # 记录规则：预聚合
    - name: recording-rules
      interval: 30s          # 评估间隔（默认与 Prometheus 一致）
      partial_response_strategy: warn
      rules:
        # 预计算服务 QPS
        - record: service:http_requests:rate5m
          expr: |
            sum by (service, namespace) (
              rate(http_requests_total[5m])
            )

        # 预计算服务错误率
        - record: service:http_errors:rate5m
          expr: |
            sum by (service, namespace) (
              rate(http_requests_total{status=~"5.."}[5m])
            )

        # 预计算资源使用率（方便告警和 Dashboard）
        - record: pod:memory_usage:ratio
          expr: |
            container_memory_working_set_bytes{container!=""}
            /
            kube_pod_container_resource_limits{resource="memory"}

    # 告警规则
    - name: service-alerts
      interval: 15s
      rules:
        # 服务不可用
        - alert: ServiceDown
          expr: up{job=~".*-service"} == 0
          for: 2m
          labels:
            severity: critical
            team: sre
            channel: pagerduty
          annotations:
            summary: "服务 {{ $labels.job }} 不可用"
            description: |
              实例 {{ $labels.instance }} 已宕机超过 2 分钟。
              
              排查步骤：
              1. 查看 Pod 状态: `kubectl get pod -l app={{ $labels.job }}`
              2. 查看事件: `kubectl describe pod {{ $labels.pod }}`
              3. 查看日志: `kubectl logs {{ $labels.pod }} --previous`
              
              Dashboard: https://grafana/d/{{ $labels.job }}
              Runbook: https://wiki/runbooks/service-down

        # 错误率升高（多条件组合）
        - alert: HighErrorRate
          expr: |
            (
              sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
              /
              sum by (service) (rate(http_requests_total[5m]))
            ) > 0.05
            and
            sum by (service) (rate(http_requests_total[5m])) > 10
          for: 5m
          labels:
            severity: warning
            team: backend
          annotations:
            summary: "服务 {{ $labels.service }} 错误率过高"
            description: "5xx 错误率: {{ $value | humanizePercentage }}"

        # 使用记录规则的告警（性能优化）
        - alert: HighErrorRateOptimized
          expr: |
            service:http_errors:rate5m
            /
            service:http_requests:rate5m > 0.1
          for: 2m
          labels:
            severity: critical

        # 预测性告警
        - alert: DiskWillFillIn4Hours
          expr: |
            predict_linear(
              node_filesystem_avail_bytes{mountpoint="/"}[1h],
              4 * 3600
            ) < 0
          for: 30m
          labels:
            severity: warning

        # 异常检测：环比波动
        - alert: TrafficAnomaly
          expr: |
            abs(
              sum(rate(http_requests_total[5m]))
              -
              sum(rate(http_requests_total[5m] offset 1d))
            )
            /
            sum(rate(http_requests_total[5m] offset 1d))
            > 0.5
          for: 10m
          labels:
            severity: warning
```

### 4.2 规则文件组织策略

```yaml
# 按层级组织
rules/
├── 00-recording/           # 记录规则（先评估）
│   ├── node-metrics.yaml
│   ├── service-metrics.yaml
│   └── slo-metrics.yaml
├── 10-infrastructure/      # 基础设施告警
│   ├── node-alerts.yaml
│   ├── pod-alerts.yaml
│   └── k8s-control-plane.yaml
├── 20-application/         # 应用层告警
│   ├── http-alerts.yaml
│   ├── database-alerts.yaml
│   └── cache-alerts.yaml
└── 30-business/            # 业务告警
    └── business-kpi.yaml
```

---

## 5. Alertmanager CRD

### 5.1 AlertmanagerConfig（全局）

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Alertmanager
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  replicas: 3              # 集群模式（gossip 协议）
  logLevel: info

  # 外部访问地址（用于生成告警链接）
  externalUrl: https://alertmanager.example.com

  # 自定义配置文件 Secret
  configSecret: alertmanager-config

  # 资源限制
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m

  # 亲和性
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values: [alertmanager]
            topologyKey: kubernetes.io/hostname

  # 存储（保存告警状态，避免重启后告警风暴）
  storage:
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 5Gi
```

### 5.2 路由配置详解

```yaml
# alertmanager-config Secret 中的 alertmanager.yml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.example.com:587'
  smtp_from: 'alert@example.com'
  pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'
  slack_api_url: '<slack-webhook-url>'

# 模板
templates:
  - '/etc/alertmanager/templates/*.tmpl'

# 路由树
route:
  # 根路由
  receiver: 'default'
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  # 子路由
  routes:
    # P0：关键服务 → 立即电话通知
    - match:
        severity: p0
      receiver: pagerduty-critical
      group_wait: 0s
      repeat_interval: 5m
      continue: true  # 继续匹配下级路由

    # P1：重要服务 → Slack + 邮件
    - match:
        severity: p1
      receiver: slack-ops
      group_wait: 1m
      routes:
        - match:
            team: database
          receiver: dba-slack

    # 按 namespace 路由
    - match_re:
        namespace: production|staging
      receiver: team-slack
      routes:
        - match:
            namespace: production
          receiver: production-slack
        - match:
            namespace: staging
          receiver: staging-slack
          # staging 不重复通知
          repeat_interval: 12h

    # 告警抑制后的降级通知
    - match:
        severity: info
      receiver: slack-info
      group_wait: 5m
      repeat_interval: 24h

# 抑制规则
inhibit_rules:
  # 节点宕机时，抑制该节点上所有 Pod 的不可达告警
  - source_match:
      alertname: 'NodeDown'
      severity: 'critical'
    target_match_re:
      alertname: 'PodNotReady|PodCrashLooping|ServiceDown'
    equal: ['node']

  # 集群级别故障时，抑制所有相关服务告警
  - source_match:
      alertname: 'ClusterUnavailable'
    target_match_re:
      alertname: '.*'
    equal: ['cluster']

# 接收器
receivers:
  - name: 'default'
    email_configs:
      - to: 'oncall@example.com'
        headers:
          Subject: 'Prometheus Alert: {{ .GroupLabels.alertname }}'

  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: '<pagerduty-integration-key>'
        severity: critical
        description: '{{ .GroupLabels.alertname }}'
        details:
          summary: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}'

  - name: 'slack-ops'
    slack_configs:
      - channel: '#ops-alerts'
        send_resolved: true
        title: '{{ .GroupLabels.alertname }}'
        text: |
          {{ range .Alerts }}
          *Alert:* {{ .Annotations.summary }}
          *Severity:* {{ .Labels.severity }}
          *Description:* {{ .Annotations.description }}
          {{ end }}
        actions:
          - type: button
            text: 'View Dashboard'
            url: '{{ .CommonAnnotations.dashboard_url }}'
          - type: button
            text: 'Runbook'
            url: '{{ .CommonAnnotations.runbook_url }}'

  - name: 'slack-info'
    slack_configs:
      - channel: '#info-alerts'
        send_resolved: false
```

### 5.3 AlertmanagerConfig CRD（按 namespace 隔离）

```yaml
# 允许特定 namespace 配置自己的告警路由
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: team-a-config
  namespace: team-a
  labels:
    alertmanagerConfig: team-configs  # 与 Alertmanager 的 alertmanagerConfigSelector 匹配
spec:
  route:
    receiver: team-a-slack
    groupBy: ['alertname']
    matchers:
      - name: namespace
        value: team-a
        matchType: '='
  receivers:
    - name: team-a-slack
      slackConfigs:
        - apiURL:
            name: slack-webhook
            key: url
          channel: '#team-a-alerts'
```

Alertmanager 需要配置：
```yaml
spec:
  alertmanagerConfigSelector:
    matchLabels:
      alertmanagerConfig: team-configs
  alertmanagerConfiguration:
    name: global-config  # 全局基础配置
```

---

## 6. Probe CRD（Blackbox 探测）

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: external-endpoints
  namespace: monitoring
  labels:
    release: prometheus
spec:
  jobName: external-http-check
  interval: 30s
  # 探测目标
  targets:
    staticConfig:
      static:
        - https://api.example.com/health
        - https://www.example.com
      labels:
        env: production
  # 使用 Blackbox Exporter
  prober:
    url: blackbox-exporter.monitoring:9115
    path: /probe
  # 模块配置
  module: http_2xx
  # 超时
  scrapeTimeout: 10s
```

Blackbox Exporter ConfigMap：
```yaml
modules:
  http_2xx:
    prober: http
    http:
      method: GET
      valid_status_codes: [200, 301, 302]
      fail_if_ssl: false
      tls_config:
        insecure_skip_verify: true

  http_post_2xx:
    prober: http
    http:
      method: POST
      body: '{"check":"health"}'
      headers:
        Content-Type: application/json
      valid_status_codes: [200]

  tcp_connect:
    prober: tcp
    tcp:
      preferred_ip_protocol: ip4

  dns_example:
    prober: dns
    dns:
      query_name: "example.com"
      query_type: "A"
      valid_rcodes: [NOERROR]
```

---

## 7. 面试高频题

**Q: Prometheus Operator 中 ServiceMonitor 和 PodMonitor 的区别？**

<details>
<summary>答案</summary>

| 特性 | ServiceMonitor | PodMonitor |
|------|----------------|------------|
| 目标发现 | 基于 Service | 直接基于 Pod |
| 使用场景 | 有 Service 的标准应用 | Sidecar 指标（Envoy、Istio） |
| Endpoint 配置 | endpoints | podMetricsEndpoints |
| 端口来源 | Service port name | Container port name |

PodMonitor 适用于：
- Istio Envoy sidecar metrics
- DaemonSet 无 Service 场景
- 需要直接访问 Pod IP 的特殊指标

</details>

**Q: relabelings 和 metricRelabelings 的区别？**

<details>
<summary>答案</summary>

- **relabelings**：在抓取之前执行，操作 target 的元数据标签（如 instance、job、__address__）
- **metricRelabelings**：在抓取之后执行，操作指标名和指标标签，可以删除整行指标

执行顺序：Service Discovery → relabelings → Scrape → metricRelabelings → TSDB

</details>

**Q: 如何实现 Prometheus 高可用？**

<details>
<summary>答案</summary>

1. **Prometheus 层面**：replicas: 2 + Thanos Sidecar + Thanos Querier（去重）
2. **Alertmanager 层面**：replicas: 3（gossip 协议自动同步状态）
3. **存储层面**：对象存储（S3）长期备份
4. **查询层面**：Thanos Query Frontend 缓存

</details>

---

## 参考资源

- [Prometheus Operator 文档](https://prometheus-operator.dev/)
- [API 参考](https://prometheus-operator.dev/docs/api-reference/api/)
- [Prometheus Relabeling](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config)

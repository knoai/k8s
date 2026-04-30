# Grafana 深度集成实战

> 市场 JD 高频要求："Grafana 可视化"、"监控即代码"。深入掌握 Grafana Operator、Provisioning、高级变量和插件开发是进阶必备。

---

## 1. Grafana Operator CRD

### 1.1 Grafana CRD

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: monitoring
  labels:
    dashboards: "grafana"
spec:
  config:
    # 安全配置
    security:
      admin_user: admin
      admin_password: "${GRAFANA_ADMIN_PASSWORD}"  # 从 Secret 引用
      disable_gravatar: true
      cookie_secure: true
      cookie_samesite: strict

    # 会话配置
    session:
      provider: redis
      provider_config: "addr=redis:6379,pool_size=100,db=0"

    # 匿名访问
    auth.anonymous:
      enabled: false

    # OAuth 集成
    auth.generic_oauth:
      enabled: true
      name: SSO
      allow_sign_up: true
      client_id: "${OAUTH_CLIENT_ID}"
      client_secret: "${OAUTH_CLIENT_SECRET}"
      scopes: openid profile email groups
      auth_url: https://sso.example.com/auth
      token_url: https://sso.example.com/token
      api_url: https://sso.example.com/userinfo
      role_attribute_path: contains(groups[*], 'admin') && 'Admin' || contains(groups[*], 'editor') && 'Editor' || 'Viewer'

    # 日志
    log:
      mode: console
      level: warn

    # 数据库（高可用）
    database:
      type: postgres
      host: grafana-postgres:5432
      name: grafana
      user: "${DB_USER}"
      password: "${DB_PASSWORD}"
      ssl_mode: require
      max_open_conn: 100
      max_idle_conn: 10

    # 渲染（PDF/PNG 导出）
    rendering:
      server_url: http://grafana-image-renderer.monitoring:8081/render
      callback_url: http://grafana.monitoring:3000/

  deployment:
    spec:
      replicas: 2
      template:
        spec:
          containers:
            - name: grafana
              image: grafana/grafana:10.4.0
              env:
                - name: GF_PATHS_PROVISIONING
                  value: /etc/grafana/provisioning
                - name: GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS
                  value: "true"
              resources:
                requests:
                  memory: 256Mi
                  cpu: 250m
                limits:
                  memory: 1Gi
                  cpu: 1000m
              volumeMounts:
                - name: provisioning
                  mountPath: /etc/grafana/provisioning
          volumes:
            - name: provisioning
              configMap:
                name: grafana-provisioning
```

### 1.2 GrafanaDatasource CRD

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-kube-p-prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
      manageAlerts: true
      alertmanagerUid: "alertmanager"
      prometheusType: Prometheus
      cacheLevel: "High"
      incrementalQuerying: true
      # Exemplars 配置
      exemplarTraceIdDestinations:
        - name: trace_id
          url: http://tempo:3200/trace/$${__value.raw}
          datasourceUid: tempo

    secureJsonData:
      # 如需认证
      httpHeaderValue1: "Bearer ${PROMETHEUS_TOKEN}"
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: loki
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: '"trace_id":"(\w+)"'
          url: http://tempo:3200/trace/$${__value.raw}
          datasourceUid: tempo
        - name: Pod
          matcherRegex: '"k8s.pod.name":"(\w+)"'
          url: http://prometheus:9090/graph?g0.expr={pod="$${__value.raw}"}
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: tempo
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      tracesToLogs:
        datasourceUid: loki
        tags: ['pod', 'namespace', 'service.name']
        mappedTags: [{key: 'service.name', value: 'service'}]
        mapTagNamesEnabled: false
        spanStartTimeShift: '1h'
        spanEndTimeShift: '1h'
        filterByTraceID: true
        filterBySpanID: false
      tracesToMetrics:
        datasourceUid: prometheus
        tags: [{key: 'service.name', value: 'service'}]
        queries:
          - name: 'Request Rate'
            query: 'sum(rate(http_requests_total{"service.name"="$service"}[5m]))'
      serviceMap:
        datasourceUid: prometheus
```

### 1.3 GrafanaDashboard CRD

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: k8s-cluster-overview
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  # 方式 1：直接内嵌 JSON
  json: >
    {
      "title": "K8s Cluster Overview",
      "uid": "k8s-cluster",
      ...
    }

  # 方式 2：引用 ConfigMap
  configMapRef:
    name: grafana-dashboards
    key: k8s-cluster.json

  # 方式 3：引用 URL
  url: https://raw.githubusercontent.com/.../dashboard.json

  # 方式 4：引用 Grafana.com
  grafanaCom:
    id: 6417
    revision: 1

  datasources:
    - inputName: DS_PROMETHEUS
      datasourceName: Prometheus
```

---

## 2. Provisioning（监控即代码）

### 2.1 目录结构

```
/etc/grafana/provisioning/
├── dashboards/           # Dashboard 自动加载
│   ├── dashboards.yml    # Dashboard provider 配置
│   └── *.json            # Dashboard JSON 文件
├── datasources/          # 数据源自动配置
│   └── datasources.yml
├── alerting/             # 告警规则（Grafana 8+）
│   └── alert_rules.yml
├── plugins/              # 插件配置
│   └── plugins.yml
└── notifiers/            # 通知渠道（旧版）
    └── notifiers.yml
```

### 2.2 数据源 Provisioning

```yaml
# /etc/grafana/provisioning/datasources/datasources.yml
apiVersion: 1

deleteDatasources:
  - name: old-prometheus
    orgId: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
      manageAlerts: true
      cacheLevel: "High"
      incrementalQuerying: true
      # Exemplars 关联 Trace
      exemplarTraceIdDestinations:
        - name: trace_id
          url: http://tempo:3200/trace/${__value.raw}
          datasourceUid: tempo
          urlDisplayLabel: "View Trace"
    secureJsonData:
      httpHeaderValue1: "Bearer token"

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: "TraceID"
          matcherRegex: '"trace_id":"(\w+)"'
          url: http://tempo:3200/trace/${__value.raw}
          datasourceUid: tempo

  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      tracesToLogs:
        datasourceUid: loki
        tags: ['pod', 'namespace']
        spanStartTimeShift: '1h'
        filterByTraceID: true
      tracesToMetrics:
        datasourceUid: prometheus
        tags: [{key: 'service.name', value: 'service'}]
      serviceMap:
        datasourceUid: prometheus
```

### 2.3 Dashboard Provisioning

```yaml
# /etc/grafana/provisioning/dashboards/dashboards.yml
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true  # 从目录结构创建文件夹

  - name: 'infrastructure'
    orgId: 1
    folder: '基础设施'
    type: file
    disableDeletion: false
    editable: false
    options:
      path: /var/lib/grafana/dashboards/infrastructure

  - name: 'applications'
    orgId: 1
    folder: '应用服务'
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards/applications
```

### 2.4 告警规则 Provisioning

```yaml
# /etc/grafana/provisioning/alerting/alert_rules.yml
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
              expr: |
                100 - avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100
              refId: A
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
          __dashboardUid__: "node-overview"
          __panelId__: "2"
        labels:
          severity: warning
```

---

## 3. 变量高级用法

### 3.1 查询变量

```promql
# 动态获取所有 namespace
label_values(kube_namespace_labels, namespace)

# 联动变量：根据 namespace 获取 pod
label_values(kube_pod_info{namespace=~"$namespace"}, pod)

# 多选 + All 选项
label_values(node_uname_info, nodename)
```

### 3.2 变量类型速查

| 类型 | 用途 | 示例 |
|------|------|------|
| **Query** | 从数据源查询 | `label_values(namespace)` |
| **Custom** | 手动定义 | `production, staging, dev` |
| **Text box** | 自由输入 | Pod 名搜索 |
| **Constant** | 隐藏常量 | 集群名 |
| **Data source** | 数据源切换 | Prometheus-BJ, Prometheus-SH |
| **Interval** | 时间间隔 | 1m, 5m, 1h |
| **Ad hoc filters** | 临时过滤 | Key-Value 过滤器 |

### 3.3 变量语法

```promql
# 多选变量（自动展开为正则）
{namespace=~"$namespace"}

# 使用 include All
{namespace=~"$namespace"}  # 选择 All 时自动变为 .*

# 排除变量
{namespace!~"kube-system|monitoring"}

# 变量嵌套
{pod=~"$pod", namespace=~"$namespace"}

# 使用变量做数学运算
rate(http_requests_total[ $__rate_interval ])  # 内置间隔变量
```

### 3.4 全局变量

| 变量 | 说明 |
|------|------|
| `$__from` / `$__to` | 时间范围 Unix 时间戳 |
| `$__interval` | 根据面板宽度计算的间隔 |
| `$__rate_interval` | 推荐的 rate() 间隔（至少 4x scrape interval） |
| `$__timezone` | 当前时区 |
| `$__dashboard` | Dashboard UID |
| `$__user` | 当前用户名 |

---

## 4. 数据关联与下钻

### 4.1 Metrics → Trace 关联（Exemplars）

```yaml
# Prometheus 数据源配置中启用 Exemplars
jsonData:
  exemplarTraceIdDestinations:
    - name: trace_id
      url: http://tempo:3200/trace/${__value.raw}
      datasourceUid: tempo
      urlDisplayLabel: "View Trace"
```

**在 Dashboard 中使用**：
1. 创建 Heatmap 或 Timeseries 面板
2. 使用支持 Exemplar 的指标（Histogram）
3. 在面板设置中启用 "Show exemplars"
4. 悬停在数据点上，点击 "View Trace" 跳转

### 4.2 Trace → Logs 关联

```yaml
# Tempo 数据源配置
tracesToLogs:
  datasourceUid: loki
  tags: ['pod', 'namespace', 'service.name']
  mappedTags:
    - key: 'service.name'
      value: 'service'
  spanStartTimeShift: '1h'
  spanEndTimeShift: '1h'
  filterByTraceID: true
```

### 4.3 Logs → Trace 关联

```yaml
# Loki 数据源配置
derivedFields:
  - name: TraceID
    matcherRegex: '"trace_id":"(\w+)"'
    url: http://tempo:3200/trace/${__value.raw}
    datasourceUid: tempo
```

### 4.4 数据链路图

```
[Metrics Panel] 
  → 点击 Exemplar (trace_id)
    → [Trace View] (Tempo)
      → 点击 "Logs for this span"
        → [Log Context] (Loki)
      → 点击 "Metrics for this span"
        → [Service Metrics] (Prometheus)
```

---

## 5. 插件开发入门

### 5.1 环境准备

```bash
# 安装 Grafana 插件工具
npx @grafana/create-plugin@latest my-plugin

cd my-plugin
npm install
npm run dev
```

### 5.2 简单数据源插件

```typescript
// src/datasource.ts
import { DataSourceInstanceSettings, CoreApp } from '@grafana/data';
import { DataSourceWithBackend } from '@grafana/runtime';
import { MyQuery, MyDataSourceOptions } from './types';

export class DataSource extends DataSourceWithBackend<MyQuery, MyDataSourceOptions> {
  constructor(instanceSettings: DataSourceInstanceSettings<MyDataSourceOptions>) {
    super(instanceSettings);
  }

  getDefaultQuery(_: CoreApp): Partial<MyQuery> {
    return {
      queryText: 'SELECT * FROM metrics',
    };
  }
}

// src/types.ts
export interface MyQuery extends DataQuery {
  queryText: string;
}

export interface MyDataSourceOptions extends DataSourceJsonData {
  apiUrl: string;
}
```

### 5.3 自定义面板插件

```typescript
// src/SimplePanel.tsx
import React from 'react';
import { PanelProps } from '@grafana/data';
import { SimpleOptions } from 'types';

interface Props extends PanelProps<SimpleOptions> {}

export const SimplePanel: React.FC<Props> = ({ options, data, width, height }) => {
  const value = data.series[0]?.fields[1]?.values.get(0) || 0;

  return (
    <div style={{ width, height, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ fontSize: options.fontSize, color: options.color }}>
        {value}
      </div>
    </div>
  );
};
```

---

## 6. 性能优化

### 6.1 查询优化

```promql
# ❌ 避免大范围查询
rate(http_requests_total[1h])

# ✅ 缩小范围，使用 $__rate_interval
rate(http_requests_total[$__rate_interval])

# ❌ 避免高基数聚合
sum(rate(http_requests_total[5m])) by (user_id)

# ✅ 按服务聚合
sum(rate(http_requests_total[5m])) by (service)
```

### 6.2 面板优化

| 优化项 | 建议 |
|--------|------|
| 刷新频率 | 不自动刷新或设置 30s+ |
| 数据点数量 | Max data points 设为面板宽度像素数 |
| 查询缓存 | 启用 Query caching |
| 变量查询 | 减少变量查询频率 |
| 使用 Recording Rules | 复杂查询预聚合 |

### 6.3 Grafana 服务器优化

```ini
# grafana.ini
[server]
protocol = http
http_port = 3000

[database]
type = postgres
host = postgres:5432
max_open_conn = 100

[remote_cache]
type = redis
connstr = addr=redis:6379,pool_size=100,db=0

[dataproxy]
timeout = 30
dialTimeout = 10
keep_alive_seconds = 30
```

---

## 7. 面试高频题

**Q: Grafana Provisioning 的作用？与手动配置的区别？**

<details>
<summary>答案</summary>

Provisioning 实现 "监控即代码"：
- Dashboard/数据源/告警配置通过 YAML/JSON 文件管理
- 支持版本控制（Git）
- 环境一致性（开发/测试/生产）
- 重启后自动恢复
- 与手动配置互斥：provisioning 的 dashboard 标记为不可编辑

</details>

**Q: 如何实现跨集群统一监控视图？**

<details>
<summary>答案</summary>

1. **数据源层面**：Grafana 配置多个 Prometheus 数据源（Prometheus-BJ, Prometheus-SH）
2. **Thanos 层面**：Thanos Querier 聚合多个 Prometheus 分片
3. **Dashboard 层面**：使用 Data source 变量切换，或混合查询（Mixed datasource）
4. **组织层面**：使用 Grafana Organization 隔离不同团队的集群

</details>

**Q: Exemplars 是什么？如何实现 Metrics 到 Trace 的关联？**

<details>
<summary>答案</summary>

Exemplars 是在 Histogram bucket 中附加的原始样本（包含 trace_id），用于将聚合指标关联到具体 Trace。

实现方式：
1. 应用埋点时，将 trace_id 附加到 Histogram 的 Exemplar
2. Prometheus 采集时保留 Exemplar 数据
3. Grafana 中配置 Exemplar 关联（datasource config）
4. 在 Dashboard 点击数据点跳转到 Trace

</details>

---

## 参考资源

- [Grafana Operator 文档](https://grafana.github.io/grafana-operator/)
- [Grafana Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Grafana 插件开发](https://grafana.com/developers/plugin-tools/)
- [Dashboard 变量](https://grafana.com/docs/grafana/latest/dashboards/variables/)

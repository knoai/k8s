# 案例三：Grafana 数据关联与下钻实践

## 目标

使用 Grafana Operator + Provisioning 实现完整的 **Metrics → Trace → Logs** 数据关联下钻链路，体验现代可观测性的核心能力。

完成后你将掌握：
- ✅ Grafana Operator CRD 部署
- ✅ Provisioning 管理 Dashboard 和数据源
- ✅ Exemplars（Metrics 关联 Trace）
- ✅ Trace to Logs（Trace 关联日志）
- ✅ Logs to Trace（日志关联 Trace）

---

## 前置条件

```bash
# 确保以下组件已部署
helm list -n monitoring

# 需要：Prometheus + Tempo + Loki + Grafana
# 如果缺少，一键安装：
helm install observability grafana/lgtm-distributed \
  --namespace monitoring --create-namespace \
  --set loki.enabled=true \
  --set tempo.enabled=true \
  --set prometheus.enabled=true \
  --set grafana.enabled=true
```

---

## 步骤 1：部署 Grafana Operator

```bash
# 安装 Grafana Operator
helm repo add grafana-operator https://grafana.github.io/helm-charts
helm repo update
helm install grafana-operator grafana-operator/grafana-operator \
  --namespace monitoring

# 等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana-operator -n monitoring --timeout=120s
```

---

## 步骤 2：用 CRD 创建 Grafana 实例

```bash
kubectl apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: demo-grafana
  namespace: monitoring
  labels:
    dashboards: "grafana"
spec:
  config:
    security:
      admin_user: admin
      admin_password: admin123
    log:
      mode: console
      level: info
  deployment:
    spec:
      template:
        spec:
          containers:
            - name: grafana
              image: grafana/grafana:10.4.0
              env:
                - name: GF_PATHS_PROVISIONING
                  value: /etc/grafana/provisioning
                - name: GF_FEATURE_TOGGLES_ENABLE
                  value: "traceqlSearch"
              resources:
                requests:
                  memory: 256Mi
                  cpu: 250m
                limits:
                  memory: 512Mi
                  cpu: 500m
EOF

# 获取访问地址
kubectl port-forward svc/demo-grafana-service 3000:3000 -n monitoring &
echo "Grafana: http://localhost:3000 (admin/admin123)"
```

---

## 步骤 3：用 CRD 创建数据源（含关联配置）

```bash
kubectl apply -f - <<'EOF'
# Prometheus 数据源（启用 Exemplars 关联 Trace）
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: demo-prometheus
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-stack-kube-p-prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
      manageAlerts: true
      # ★★★ Exemplars 配置：点击 Metrics 数据点跳转到 Trace ★★★
      exemplarTraceIdDestinations:
        - name: trace_id
          url: 'http://localhost:3000/explore?left=%7B"datasource":"Tempo","queries":%5B%7B"refId":"A","queryType":"traceId","query":"${__value.raw}"%7D%5D%7D'
          datasourceUid: tempo
          urlDisplayLabel: "查看 Trace"
    secureJsonData: {}
---
# Tempo 数据源（Trace to Logs + Trace to Metrics）
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: demo-tempo
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
      # ★★★ Trace to Logs：从 Trace 跳转到相关日志 ★★★
      tracesToLogs:
        datasourceUid: loki
        tags: ['pod', 'namespace', 'service.name']
        mappedTags:
          - key: 'service.name'
            value: 'service'
        spanStartTimeShift: '1h'
        spanEndTimeShift: '1h'
        filterByTraceID: true
        filterBySpanID: false
      # ★★★ Trace to Metrics：从 Trace 跳转到 Metrics ★★★
      tracesToMetrics:
        datasourceUid: prometheus
        tags:
          - key: 'service.name'
            value: 'service'
        queries:
          - name: '请求速率'
            query: 'sum(rate(http_server_requests_seconds_count{service="$service"}[5m]))'
      # Service Map
      serviceMap:
        datasourceUid: prometheus
---
# Loki 数据源（Logs to Trace）
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: demo-loki
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
      # ★★★ Derived Fields：从日志中提取 trace_id 并链接到 Trace ★★★
      derivedFields:
        - name: "TraceID"
          matcherRegex: '"trace_id":"(\w+)"'
          url: 'http://localhost:3000/explore?left=%7B"datasource":"Tempo","queries":%5B%7B"refId":"A","queryType":"traceId","query":"${__value.raw}"%7D%5D%7D'
          datasourceUid: tempo
        - name: "Pod"
          matcherRegex: '"pod":"([\w-]+)"'
          url: ''
EOF

# 验证数据源
open http://localhost:3000/datasources
```

---

## 步骤 4：Provisioning 管理 Dashboard

```bash
# 创建 Dashboard JSON ConfigMap
kubectl create configmap grafana-dashboards \
  --from-file=demo-dashboard.json=/dev/stdin \
  -n monitoring --dry-run=client -o yaml <<'EOF' | kubectl apply -f -
{
  "dashboard": {
    "id": null,
    "uid": "demo-correlation",
    "title": "数据关联演示",
    "tags": ["demo"],
    "timezone": "browser",
    "schemaVersion": 36,
    "refresh": "30s",
    "panels": [
      {
        "id": 1,
        "title": "HTTP 请求延迟分布（含 Exemplars）",
        "type": "heatmap",
        "gridPos": {"h": 10, "w": 24, "x": 0, "y": 0},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [
          {
            "expr": "sum(increase(http_server_requests_seconds_bucket[1m])) by (le)",
            "format": "heatmap",
            "legendFormat": "{{le}}"
          }
        ],
        "options": {
          "calculate": false,
          "cellGap": 1,
          "color": {"mode": "scheme", "scheme": "YlOrRd"}
        },
        "heatmap": {},
        "exemplar": {
          "color": "rgba(255,0,255,0.7)"
        }
      },
      {
        "id": 2,
        "title": "请求速率",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 10},
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "targets": [
          {
            "expr": "sum(rate(http_server_requests_seconds_count[5m])) by (status)",
            "legendFormat": "{{status}}"
          }
        ]
      },
      {
        "id": 3,
        "title": "Trace 查询",
        "type": "traces",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 10},
        "datasource": {"type": "tempo", "uid": "tempo"}
      }
    ]
  }
}
EOF

# 用 GrafanaDashboard CRD 加载
kubectl apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: demo-correlation
  namespace: monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  configMapRef:
    name: grafana-dashboards
    key: demo-dashboard.json
EOF

# 验证 Dashboard
open http://localhost:3000/d/demo-correlation
```

---

## 步骤 5：部署带 TraceID 的 Demo 应用

```bash
kubectl create namespace correlation-demo --dry-run=client -o yaml | kubectl apply -f -

# 部署一个同时输出 Metrics + Logs + Traces 的应用
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: correlation-app
  namespace: correlation-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: correlation-app
  template:
    metadata:
      labels:
        app: correlation-app
    spec:
      containers:
        - name: app
          image: ghcr.io/open-telemetry/opentelemetry-demo/productcatalogservice:latest
          env:
            - name: OTEL_SERVICE_NAME
              value: "product-catalog"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.monitoring:4317"
            - name: OTEL_METRICS_EXPORTER
              value: "otlp"
            - name: OTEL_TRACES_EXPORTER
              value: "otlp"
            - name: OTEL_LOGS_EXPORTER
              value: "otlp"
          ports:
            - containerPort: 8080
EOF

# 为该应用创建 ServiceMonitor
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: correlation-app-metrics
  namespace: correlation-demo
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: correlation-app
  endpoints:
    - port: metrics
      interval: 15s
EOF

kubectl wait --for=condition=ready pod -l app=correlation-app -n correlation-demo --timeout=120s
```

---

## 步骤 6：验证数据关联链路

### 6.1 Metrics → Trace（Exemplars）

```bash
# 1. 生成一些请求
kubectl port-forward svc/correlation-app 8080:8080 -n correlation-demo &
for i in {1..50}; do
  curl -s http://localhost:8080/products >/dev/null
done

# 2. 打开 Grafana Dashboard
open http://localhost:3000/d/demo-correlation

# 3. 在 Heatmap 面板中，悬停在数据点上
#    应该能看到 Exemplar 标记（粉色圆点）
# 4. 点击 Exemplar → 跳转到 Trace 详情
```

### 6.2 Trace → Logs

```bash
# 1. 打开 Explore → 选择 Tempo 数据源
open http://localhost:3000/explore?orgId=1&left=%7B"datasource":"Tempo"%7D

# 2. 查询一个 trace_id（从 Metrics Exemplar 获取，或随机搜索）
# 3. 在 Trace 详情中，点击任意 Span
# 4. 点击 "Logs for this span" → 跳转到 Loki，自动过滤相关日志
```

### 6.3 Trace → Metrics

```bash
# 1. 在 Trace 详情中
# 2. 点击 "Metrics for this span"
# 3. 自动跳转到 Prometheus，显示该服务的请求速率
```

### 6.4 Logs → Trace

```bash
# 1. 打开 Explore → 选择 Loki 数据源
open http://localhost:3000/explore?orgId=1&left=%7B"datasource":"Loki"%7D

# 2. 查询日志：{service_name="product-catalog"}
# 3. 展开日志行，找到 trace_id 字段（高亮为蓝色链接）
# 4. 点击 trace_id → 跳转到 Tempo Trace 详情
```

---

## 完整数据链路图

```
用户请求 → correlation-app
                ↓
        ┌───────┼───────┐
        ↓       ↓       ↓
    Metrics   Trace     Log
   (Prometheus) (Tempo)  (Loki)
        ↓       ↓       ↓
        └───────┴───────┘
                ↓
           Grafana
                ↓
    ┌───────────┼───────────┐
    ↓           ↓           ↓
Metrics Panel  Trace View  Log Panel
    ↓           ↓           ↓
点击 Exemplar  Logs for     点击
    ↓           span        trace_id
    ↓           ↓           ↓
  Trace ←──── Trace ←──── Trace
   View         View        View
    ↓           ↓
Metrics for   Logs Panel
  span
    ↓
Metrics Panel
```

---

## 验证清单

- [ ] Grafana Operator 正常运行
- [ ] Grafana 能通过 CRD 自动加载数据源
- [ ] Prometheus 数据源配置了 Exemplars
- [ ] Tempo 数据源配置了 tracesToLogs 和 tracesToMetrics
- [ ] Loki 数据源配置了 derivedFields（trace_id 链接）
- [ ] Dashboard 通过 GrafanaDashboard CRD 自动加载
- [ ] 在 Heatmap 中点击 Exemplar 能跳转到 Trace
- [ ] 在 Trace 详情中点击 "Logs for this span" 能查看相关日志
- [ ] 在日志中点击 trace_id 能跳转到 Trace 详情

---

## 关键配置总结

| 关联方向 | 配置位置 | 关键字段 |
|----------|----------|----------|
| Metrics → Trace | Prometheus Datasource | `exemplarTraceIdDestinations` |
| Trace → Logs | Tempo Datasource | `tracesToLogs.datasourceUid` |
| Trace → Metrics | Tempo Datasource | `tracesToMetrics.datasourceUid` |
| Logs → Trace | Loki Datasource | `derivedFields`（regex + url） |

---

## 清理

```bash
kubectl delete namespace correlation-demo
kubectl delete grafana demo-grafana -n monitoring
kubectl delete grafanadatasource demo-prometheus demo-tempo demo-loki -n monitoring
kubectl delete grafanadashboard demo-correlation -n monitoring
kubectl delete configmap grafana-dashboards -n monitoring
helm uninstall grafana-operator -n monitoring
```

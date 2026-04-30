# 案例四：微服务全链路可观测综合实战

## 目标

构建一个完整的微服务可观测体系，覆盖 **指标、日志、链路、剖析** 四大信号，实现从基础设施到业务层的全栈监控。

完成后你将拥有一个生产级可观测平台：
- ✅ OpenTelemetry 统一采集（Go + Java 微服务）
- ✅ Prometheus + VictoriaMetrics 存储
- ✅ Loki 日志聚合
- ✅ Tempo 分布式链路追踪
- ✅ Pyroscope 持续性能剖析
- ✅ Grafana 统一可视化 + 告警
- ✅ 完整的 Metrics → Trace → Logs → Profile 下钻

---

## 架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户流量                                        │
│                            (wrk / k6)                                       │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────────────┐
│                            Ingress / Gateway                                 │
│                              (Nginx / Envoy)                                 │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         │                         │                         │
┌────────▼────────┐      ┌────────▼────────┐      ┌────────▼────────┐
│   API Gateway   │──────▶│  Order Service  │──────▶│ Payment Service │
│     (Go)        │       │    (Java)       │       │    (Go)         │
│                 │       │                 │       │                 │
│  OTel SDK       │       │  OTel Agent     │       │  OTel SDK       │
│  ─────────────  │       │  ─────────────  │       │  ─────────────  │
│  Metrics        │       │  Metrics        │       │  Metrics        │
│  Traces         │       │  Traces         │       │  Traces         │
│  Logs           │       │  Logs           │       │  Logs           │
└────────┬────────┘       └────────┬────────┘       └────────┬────────┘
         │                         │                         │
         └─────────────────────────┼─────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────────────┐
│                     OpenTelemetry Collector (DaemonSet)                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Receivers: OTLP (4317) + FileLog + Prometheus                      │    │
│  │  Processors: Batch + Memory Limiter + Tail Sampling                 │    │
│  │  Exporters: PrometheusRemoteWrite + OTLP/Tempo + Loki               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────┬─────────────┬─────────────────────────────────────┘
                           │             │
              ┌────────────▼──┐ ┌───────▼────────┐ ┌──────────▼──────────┐
              │  Prometheus   │ │     Tempo      │ │       Loki          │
              │  (热存储15天)  │ │  (链路3天)      │ │    (日志7天)         │
              └───────┬───────┘ └────────────────┘ └─────────────────────┘
                      │
              ┌───────▼────────┐
              │ VictoriaMetrics│
              │  (长期存储90天) │
              └────────────────┘
                                           ┌─────────────────────┐
                                           │     Grafana         │
                                           │  (统一可视化 + 告警)  │
                                           └─────────────────────┘
```

---

## 步骤 1：部署基础设施

```bash
# 创建 namespace
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# 添加 Helm 仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# 1. 部署 VictoriaMetrics（长期存储）
helm install victoria-metrics grafana/victoria-metrics-single \
  --namespace observability \
  --set server.persistentVolume.enabled=true \
  --set server.persistentVolume.size=50Gi

# 2. 部署 Tempo
helm install tempo grafana/tempo \
  --namespace observability \
  --set tempo.storage.trace.backend=local

# 3. 部署 Loki
helm install loki grafana/loki \
  --namespace observability \
  --set loki.commonConfig.replication_factor=1 \
  --set singleBinary.replicas=1

# 4. 部署 Prometheus（只保留短期数据，remoteWrite 到 VM）
helm install prometheus prometheus-community/prometheus \
  --namespace observability \
  --set server.remoteWrite[0].url=http://victoria-metrics-server:8428/api/v1/write \
  --set server.retention=15d

# 5. 部署 Grafana
helm install grafana grafana/grafana \
  --namespace observability \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
  --set datasources."datasources\.yaml".datasources[0].type=prometheus \
  --set datasources."datasources\.yaml".datasources[0].url=http://prometheus-server:9090 \
  --set datasources."datasources\.yaml".datasources[1].name=Tempo \
  --set datasources."datasources\.yaml".datasources[1].type=tempo \
  --set datasources."datasources\.yaml".datasources[1].url=http://tempo:3100 \
  --set datasources."datasources\.yaml".datasources[2].name=Loki \
  --set datasources."datasources\.yaml".datasources[2].type=loki \
  --set datasources."datasources\.yaml".datasources[2].url=http://loki:3100

# 获取 Grafana 密码
kubectl get secret --namespace observability grafana -o jsonpath="{.data.admin-password}" | base64 --decode
echo ""

# 端口转发
kubectl port-forward svc/grafana 3000:80 -n observability &
kubectl port-forward svc/prometheus-server 9090:80 -n observability &
echo "Grafana: http://localhost:3000"
echo "Prometheus: http://localhost:9090"
```

---

## 步骤 2：部署 OpenTelemetry Collector

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: observability
data:
  otel-collector.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 1s
        send_batch_size: 1024
      memory_limiter:
        limit_mib: 512
        spike_limit_mib: 128
        check_interval: 5s
      # 尾部采样：保留错误和慢请求
      tail_sampling:
        decision_wait: 10s
        num_traces: 1000
        policies:
          - name: errors
            type: status_code
            status_code: {status_codes: [ERROR]}
          - name: slow
            type: latency
            latency: {threshold_ms: 500}
          - name: probabilistic
            type: probabilistic
            probabilistic: {sampling_percentage: 10}
      resource:
        attributes:
          - key: k8s.cluster.name
            value: demo-cluster
            action: upsert

    exporters:
      prometheusremotewrite:
        endpoint: http://victoria-metrics-server:8428/api/v1/write
      otlp/tempo:
        endpoint: tempo:4317
        tls:
          insecure: true
      loki:
        endpoint: http://loki:3100/loki/api/v1/push
        labels:
          attributes:
            service.name: "service"
            k8s.namespace.name: "namespace"
            k8s.pod.name: "pod"
      debug:
        verbosity: detailed

    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheusremotewrite]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, tail_sampling, resource, batch]
          exporters: [otlp/tempo]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [loki]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: observability
spec:
  replicas: 2
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.96.0
          args: ["--config=/conf/otel-collector.yaml"]
          ports:
            - containerPort: 4317
              name: otlp-grpc
            - containerPort: 4318
              name: otlp-http
          volumeMounts:
            - name: config
              mountPath: /conf
          resources:
            limits:
              cpu: "1"
              memory: 1Gi
            requests:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    app: otel-collector
  ports:
    - port: 4317
      name: otlp-grpc
    - port: 4318
      name: otlp-http
EOF
```

---

## 步骤 3：部署 Go 微服务（API Gateway）

```bash
kubectl create namespace microservices --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: microservices
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
    spec:
      containers:
        - name: app
          image: ghcr.io/open-telemetry/opentelemetry-demo/loadgenerator:latest
          env:
            - name: OTEL_SERVICE_NAME
              value: "api-gateway"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability:4317"
            - name: OTEL_TRACES_SAMPLER
              value: "parentbased_traceidratio"
            - name: OTEL_TRACES_SAMPLER_ARG
              value: "0.5"
          ports:
            - containerPort: 8080
EOF
```

---

## 步骤 4：部署 Java 微服务（Order Service）

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: microservices
spec:
  replicas: 2
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
    spec:
      initContainers:
        - name: download-otel
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              wget -O /otel/opentelemetry-javaagent.jar \
                https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.0.0/opentelemetry-javaagent.jar
          volumeMounts:
            - name: otel
              mountPath: /otel
      containers:
        - name: app
          image: ghcr.io/prometheus-community/spring-boot-demo:latest
          env:
            - name: JAVA_TOOL_OPTIONS
              value: "-javaagent:/otel/opentelemetry-javaagent.jar"
            - name: OTEL_SERVICE_NAME
              value: "order-service"
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.observability:4317"
            - name: OTEL_METRICS_EXPORTER
              value: "otlp"
            - name: OTEL_TRACES_EXPORTER
              value: "otlp"
            - name: OTEL_LOGS_EXPORTER
              value: "otlp"
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: otel
              mountPath: /otel
      volumes:
        - name: otel
          emptyDir: {}
EOF
```

---

## 步骤 5：配置监控采集

```bash
# ServiceMonitor 自动发现微服务指标
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: microservices-metrics
  namespace: microservices
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/part-of: opentelemetry-demo
  namespaceSelector:
    matchNames:
      - microservices
  endpoints:
    - port: metrics
      interval: 15s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
EOF
```

---

## 步骤 6：配置告警规则

```bash
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: microservices-alerts
  namespace: observability
  labels:
    role: alert-rules
    prometheus: prometheus
spec:
  groups:
    - name: slo-alerts
      rules:
        # SLO：99% 可用性
        - alert: MicroserviceAvailabilitySLOBurn
          expr: |
            (
              sum(rate(http_server_requests_seconds_count{status=~"5.."}[1h]))
              /
              sum(rate(http_server_requests_seconds_count[1h]))
            ) > (14.4 * 0.01)
          for: 2m
          labels:
            severity: critical
            slo: availability
          annotations:
            summary: "服务可用性 SLO 快速燃烧"
            description: "1 小时内错误率超过 14.4 × 0.01（即快速消耗错误预算）"

    - name: latency-alerts
      rules:
        - alert: HighLatencyP99
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_server_requests_seconds_bucket[5m])) by (le, service_name)
            ) > 2
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.service_name }} P99 延迟过高"
EOF
```

---

## 步骤 7：导入 Grafana Dashboard

```bash
# 导入标准 Dashboard
# 1. JVM Micrometer Dashboard (ID: 4701)
# 2. Node Exporter Full (ID: 1860)
# 3. K8s Cluster (ID: 6417)

# 配置数据源关联
curl -X POST http://localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -u admin:$(kubectl get secret --namespace observability grafana -o jsonpath="{.data.admin-password}" | base64 --decode) \
  -d '{
    "name": "VictoriaMetrics",
    "type": "prometheus",
    "url": "http://victoria-metrics-server:8428",
    "access": "proxy",
    "jsonData": {
      "timeInterval": "15s",
      "httpMethod": "POST"
    }
  }'
```

---

## 步骤 8：生成流量并验证

```bash
# 安装 wrk
# brew install wrk  # macOS
# apt-get install wrk  # Ubuntu

# 获取 Gateway 地址
GATEWAY_URL=$(kubectl get svc api-gateway -n microservices -o jsonpath='{.spec.clusterIP}')

# 生成持续流量
wrk -t4 -c100 -d300s http://$GATEWAY_URL:8080/ &

# 验证 Metrics
curl -s http://localhost:9090/api/v1/query?query='sum(rate(http_server_requests_seconds_count[5m]))'

# 验证 Traces（Tempo）
curl -s http://localhost:9090/api/v1/query?query='traces_spanmetrics_latency_count'

# 验证 Logs（Loki）
curl -G -s http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="order-service"}' \
  --data-urlencode 'limit=10'
```

---

## 验证清单

### 基础设施
- [ ] Prometheus 运行正常，能查询指标
- [ ] VictoriaMetrics 运行正常，remoteWrite 有数据写入
- [ ] Tempo 运行正常，能查询 Trace
- [ ] Loki 运行正常，能查询日志
- [ ] OTel Collector 运行正常，无报错

### 数据采集
- [ ] Go 服务指标正常采集
- [ ] Java 服务指标正常采集
- [ ] 链路数据正常采集
- [ ] 日志数据正常采集

### 数据关联
- [ ] Grafana Dashboard 能查看 Metrics
- [ ] 点击 Exemplar 能跳转到 Trace
- [ ] Trace 详情能查看相关 Logs
- [ ] 日志中的 trace_id 能链接到 Trace

### 告警
- [ ] 告警规则正常评估
- [ ] 模拟高延迟后告警触发
- [ ] 告警通知正常发送

---

## 扩展练习

1. **添加 Pyroscope 性能剖析**
   ```bash
   helm install pyroscope grafana/pyroscope --namespace observability
   # 为 Java/Go 应用添加 Profiling Agent
   ```

2. **添加 eBPF 网络监控**
   ```bash
   helm install cilium cilium/cilium --namespace kube-system \
     --set hubble.enabled=true \
     --set hubble.relay.enabled=true \
     --set hubble.ui.enabled=true
   ```

3. **多集群联邦**
   ```bash
   # 部署 Thanos Query 聚合多个 Prometheus
   # 配置 Grafana 多数据源切换
   ```

4. **SLO 看板**
   ```bash
   # 创建 SLO Dashboard
   # 显示错误预算剩余、燃烧率趋势
   ```

---

## 清理

```bash
helm uninstall prometheus victoria-metrics tempo loki grafana -n observability
helm uninstall otel-collector -n observability 2>/dev/null || true
kubectl delete namespace observability microservices
```

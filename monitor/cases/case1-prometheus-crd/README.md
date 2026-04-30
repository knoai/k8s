# 案例一：Prometheus Operator CRD 全栈实践

## 目标

部署一个完整的 Java 应用监控体系，从零开始手写所有 CRD，理解 Prometheus Operator 的核心工作原理。

完成后你将掌握：
- ✅ Prometheus CRD 的所有核心字段
- ✅ ServiceMonitor 自动发现机制
- ✅ relabelings vs metricRelabelings 的区别
- ✅ PrometheusRule 的 Recording Rules 和 Alert Rules
- ✅ Alertmanager 的多级路由和抑制规则

---

## 前置条件

```bash
# 1. 确保 kube-prometheus-stack 已部署
helm list -n monitoring | grep prometheus

# 2. 如果没有，先部署
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=false  # 我们后续自己部署 Grafana
```

---

## 步骤 1：部署 Java Demo 应用

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: observability-demo
  labels:
    app: order-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
        tier: backend
    spec:
      containers:
        - name: app
          image: ghcr.io/prometheus-community/spring-boot-demo:latest
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 8081
              name: management
          env:
            - name: MANAGEMENT_SERVER_PORT
              value: "8081"
            - name: MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE
              value: "prometheus,health,info,metrics"
            - name: SERVER_PORT
              value: "8080"
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
              cpu: 500m
---
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: observability-demo
  labels:
    app: order-service
    tier: backend
spec:
  selector:
    app: order-service
  ports:
    - port: 80
      targetPort: 8080
      name: http
    - port: 8081
      targetPort: 8081
      name: management  # Actuator 端口
EOF

# 验证
kubectl wait --for=condition=ready pod -l app=order-service -n observability-demo --timeout=120s
kubectl get pod,svc -n observability-demo
```

---

## 步骤 2：创建 ServiceMonitor

```bash
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: order-service-metrics
  namespace: observability-demo
  labels:
    release: prometheus-stack  # 必须匹配 Prometheus CRD 的 serviceMonitorSelector
spec:
  # 选择目标 Service
  selector:
    matchLabels:
      app: order-service
  
  # 扫描当前 namespace
  namespaceSelector:
    matchNames:
      - observability-demo
  
  endpoints:
    # 端点 1：Spring Boot Actuator 指标
    - port: management
      path: /actuator/prometheus
      interval: 15s
      scrapeTimeout: 10s
      honorLabels: true
      
      # 目标级 relabel（抓取前执行）
      relabelings:
        # 将 Pod 名添加到 instance 标签
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
          action: replace
        # 添加 namespace 标签
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: k8s_namespace
          action: replace
        # 添加节点标签
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
          action: replace
      
      # 指标级 relabel（抓取后执行）
      metricRelabelings:
        # 只保留我们关心的指标，减少存储压力
        - sourceLabels: [__name__]
          regex: '(jvm_.*|http_server_requests_.*|process_.*|system_cpu_.*)'
          action: keep
        # 丢弃 jvm_buffer_pool_used_bytes 指标（降低基数）
        - sourceLabels: [__name__]
          regex: 'jvm_buffer_pool_used_bytes'
          action: drop
EOF

# 验证：查看 Prometheus 是否发现了 target
kubectl port-forward svc/prometheus-stack-kube-p-prometheus 9090:9090 -n monitoring &
open http://localhost:9090/targets
# 应该能看到 observability-demo/order-service-metrics
```

---

## 步骤 3：创建 PrometheusRule（告警规则）

```bash
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: order-service-alerts
  namespace: observability-demo
  labels:
    role: alert-rules
    prometheus: prometheus-stack-kube-p-prometheus  # 匹配 Prometheus CRD 的 ruleSelector
spec:
  groups:
    # Recording Rules：预聚合，提升查询性能
    - name: order-service-recording
      interval: 30s
      rules:
        # 预计算 QPS
        - record: service:order:qps
          expr: |
            sum(rate(http_server_requests_seconds_count{service="order-service"}[5m]))
        
        # 预计算错误率
        - record: service:order:error_rate
          expr: |
            sum(rate(http_server_requests_seconds_count{service="order-service",status=~"5.."}[5m]))
            /
            sum(rate(http_server_requests_seconds_count{service="order-service"}[5m]))
    
    # Alert Rules：告警
    - name: order-service-alerts
      interval: 15s
      rules:
        # 服务不可用
        - alert: OrderServiceDown
          expr: up{job="observability-demo/order-service-metrics"} == 0
          for: 2m
          labels:
            severity: critical
            service: order-service
            team: backend
          annotations:
            summary: "订单服务不可用"
            description: "Pod {{ $labels.pod }} 已宕机超过 2 分钟"
            runbook_url: "https://wiki.example.com/runbooks/order-service-down"
        
        # 错误率过高（使用 Recording Rule）
        - alert: OrderServiceHighErrorRate
          expr: service:order:error_rate > 0.05
          for: 5m
          labels:
            severity: warning
            service: order-service
            team: backend
          annotations:
            summary: "订单服务错误率过高"
            description: "5xx 错误率: {{ $value | humanizePercentage }}"
        
        # HTTP P99 延迟过高
        - alert: OrderServiceHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(http_server_requests_seconds_bucket{service="order-service"}[5m])) by (le)
            ) > 2
          for: 5m
          labels:
            severity: warning
            service: order-service
            team: backend
          annotations:
            summary: "订单服务 P99 延迟过高"
            description: "P99 延迟: {{ $value }}s"
        
        # JVM 堆内存使用率过高
        - alert: OrderServiceJVMHeapHigh
          expr: |
            jvm_memory_used_bytes{area="heap",service="order-service"} 
            / 
            jvm_memory_max_bytes{area="heap",service="order-service"} > 0.8
          for: 5m
          labels:
            severity: warning
            service: order-service
            team: backend
          annotations:
            summary: "订单服务 JVM 堆内存使用率过高"
            description: "当前使用率: {{ $value | humanizePercentage }}"
EOF

# 验证规则是否生效
open http://localhost:9090/rules
open http://localhost:9090/alerts
```

---

## 步骤 4：配置 Alertmanager 路由

```bash
# 先获取当前 Alertmanager 配置 Secret
kubectl get secret alertmanager-prometheus-stack-kube-p-alertmanager -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d > /tmp/current-alertmanager.yaml

# 创建新的 Alertmanager 配置（含我们的路由）
cat > /tmp/alertmanager-config.yaml <<'EOF'
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.example.com:587'
  smtp_from: 'alert@example.com'

# 抑制规则
inhibit_rules:
  # 节点宕机时抑制该节点上所有 Pod 的不可达告警
  - source_match:
      alertname: 'KubeNodeNotReady'
      severity: 'critical'
    target_match_re:
      alertname: 'OrderServiceDown|KubePodCrashLooping'
    equal: ['node']

# 路由树
route:
  receiver: 'default'
  group_by: ['alertname', 'namespace', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # 订单服务路由
    - match:
        service: order-service
      receiver: backend-team
      routes:
        - match:
            severity: critical
          receiver: backend-team-pager
          group_wait: 0s
          repeat_interval: 5m
        - match:
            severity: warning
          receiver: backend-team-slack
          group_wait: 2m
    
    # 基础设施路由
    - match_re:
        alertname: 'Kube.*|Node.*'
      receiver: sre-team
      group_wait: 1m

# 接收器
receivers:
  - name: 'default'
    email_configs:
      - to: 'oncall@example.com'

  - name: 'backend-team'
    slack_configs:
      - channel: '#backend-alerts'
        send_resolved: true
        title: '{{ .GroupLabels.alertname }}'
        text: |
          {{ range .Alerts }}
          *Service:* {{ .Labels.service }}
          *Severity:* {{ .Labels.severity }}
          *Summary:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          {{ end }}

  - name: 'backend-team-pager'
    pagerduty_configs:
      - service_key: '<your-pagerduty-key>'
        severity: critical
        description: '{{ .GroupLabels.alertname }} - {{ .GroupLabels.service }}'

  - name: 'backend-team-slack'
    slack_configs:
      - channel: '#backend-warnings'
        send_resolved: true

  - name: 'sre-team'
    slack_configs:
      - channel: '#sre-alerts'
        send_resolved: true
EOF

# 更新 Secret
kubectl create secret generic alertmanager-prometheus-stack-kube-p-alertmanager \
  --from-file=alertmanager.yaml=/tmp/alertmanager-config.yaml \
  -n monitoring --dry-run=client -o yaml | kubectl apply -f -

# 重启 Alertmanager 生效
kubectl rollout restart statefulset alertmanager-prometheus-stack-kube-p-alertmanager -n monitoring
```

---

## 步骤 5：模拟告警验证

```bash
# 1. 触发 HTTP 错误（让错误率升高）
for i in {1..100}; do
  curl -s http://$(kubectl get svc order-service -n observability-demo -o jsonpath='{.spec.clusterIP}')/error || true
  sleep 0.1
done

# 2. 查看告警状态
open http://localhost:9090/alerts

# 3. 查看 Alertmanager
kubectl port-forward svc/prometheus-stack-kube-p-alertmanager 9093:9093 -n monitoring &
open http://localhost:9093

# 4. 模拟 Pod 宕机（测试抑制规则）
kubectl scale deployment order-service --replicas=0 -n observability-demo
# 等待 2 分钟后查看告警
# 然后恢复
kubectl scale deployment order-service --replicas=2 -n observability-demo
```

---

## 验证清单

- [ ] Prometheus Targets 页面能看到 `observability-demo/order-service-metrics`
- [ ] 能查询到 `jvm_memory_used_bytes`、`http_server_requests_seconds_count` 等指标
- [ ] Rules 页面能看到 Recording Rules 和 Alert Rules
- [ ] Alerts 页面能看到告警状态（绿色/黄色/红色）
- [ ] Alertmanager 页面能看到告警分组和路由
- [ ] 模拟错误后，`OrderServiceHighErrorRate` 告警变为 Firing
- [ ] 缩容 Pod 后，`OrderServiceDown` 告警变为 Firing
- [ ] 恢复 Pod 后，告警变为 Resolved

---

## 关键概念总结

```
ServiceMonitor → Prometheus 通过 label selector 自动发现
     ↓
endpoints → relabelings（目标级，操作 instance/job 等）
     ↓
Scrape → metricRelabelings（指标级，操作指标名和标签）
     ↓
TSDB ← PrometheusRule（Recording Rules 预聚合）
     ↓
Alert Rules → Alertmanager（路由 → 抑制 → 通知）
```

---

## 清理

```bash
kubectl delete namespace observability-demo
# 恢复 Alertmanager 配置（可选）
# kubectl delete secret alertmanager-prometheus-stack-kube-p-alertmanager -n monitoring
```

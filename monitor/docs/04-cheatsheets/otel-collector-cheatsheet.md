# OpenTelemetry Collector 配置速查表

## 常用 Receivers

```yaml
receivers:
  # OTLP（最常用）
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  
  # Prometheus 抓取
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector'
          scrape_interval: 15s
          static_configs:
            - targets: ['0.0.0.0:8888']
  
  # 文件日志
  filelog:
    include: [/var/log/*.log]
    operators:
      - type: json_parser
  
  # Kubernetes 事件
  k8s_events:
    auth_type: serviceAccount
  
  # 主机指标
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
      memory:
      disk:
      network:
```

## 常用 Processors

```yaml
processors:
  # 批处理（性能优化）
  batch:
    timeout: 1s
    send_batch_size: 1024
    send_batch_max_size: 2048
  
  # 内存限制（防 OOM）
  memory_limiter:
    limit_mib: 1500
    spike_limit_mib: 512
    check_interval: 5s
  
  # 资源属性增强
  resource:
    attributes:
      - key: k8s.cluster.name
        value: production
        action: upsert
      - key: environment
        from_attribute: env
        action: insert
  
  # 属性处理
  attributes:
    actions:
      - key: password
        action: delete
      - key: email
        action: hash
      - key: environment
        value: production
        action: upsert
  
  # 尾部采样
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
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
  
  # 过滤
  filter:
    metrics:
      metric:
        - 'name == "unwanted_metric"'
    traces:
      span:
        - 'attributes["http.route"] == "/health"'
```

## 常用 Exporters

```yaml
exporters:
  # Prometheus Remote Write
  prometheusremotewrite:
    endpoint: http://prometheus:9090/api/v1/write
  
  # OTLP（Tempo/Jaeger）
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true
  
  # Loki
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    labels:
      attributes:
        k8s.pod.name: "pod"
        k8s.namespace.name: "namespace"
  
  # Jaeger
  jaeger:
    endpoint: jaeger:14250
    tls:
      insecure: true
  
  # Zipkin
  zipkin:
    endpoint: http://zipkin:9411/api/v2/spans
  
  # 调试输出
  debug:
    verbosity: detailed
```

## Pipeline 配置

```yaml
service:
  pipelines:
    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite]
    
    traces:
      receivers: [otlp]
      processors: [memory_limiter, tail_sampling, resource, batch]
      exporters: [otlp/tempo]
    
    logs:
      receivers: [otlp, filelog]
      processors: [memory_limiter, resource, batch]
      exporters: [loki]
  
  extensions: [health_check, zpages, pprof]
  telemetry:
    logs:
      level: info
```

## 扩展 Extensions

```yaml
extensions:
  # 健康检查
  health_check:
    endpoint: :13133
  
  # 调试页面
  zpages:
    endpoint: :55679
  
  # 性能剖析
  pprof:
    endpoint: :1777
```

## 环境变量配置

```bash
# Java 应用
export OTEL_SERVICE_NAME=my-service
export OTEL_RESOURCE_ATTRIBUTES=service.namespace=production,deployment.environment=prod
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
export OTEL_TRACES_SAMPLER=parentbased_traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1

# Go 应用
export OTEL_SERVICE_NAME=payment-service
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
export OTEL_TRACES_SAMPLER=traceidratio
export OTEL_TRACES_SAMPLER_ARG=0.1
```

## Kubernetes 部署要点

```yaml
# DaemonSet 模式（节点级 Agent）
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-collector-agent
spec:
  template:
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.96.0
          resources:
            limits:
              cpu: "2"
              memory: 4Gi
            requests:
              cpu: 500m
              memory: 1Gi

# Deployment 模式（中心 Gateway）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector-gateway
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.96.0
          resources:
            limits:
              cpu: "4"
              memory: 8Gi
```

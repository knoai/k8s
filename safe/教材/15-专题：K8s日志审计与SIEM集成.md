# 第15章 专题：K8s 日志审计与 SIEM 集成

> **本章目标**：建立完整的 K8s 安全日志体系。从日志采集、API 审计配置到 SIEM 集成，帮助读者构建"看得见"的安全运营能力。
>
> 读完本章后，你应该能够：设计多层日志架构；配置 API Server 审计策略；部署日志采集管道；在 SIEM 中构建 K8s 安全检测规则；进行威胁狩猎。

---

## 15.1 K8s 日志体系全景

### 15.1.1 日志来源分类与价值

```
┌─────────────────────────────────────────────────────────────────┐
│                    K8s 日志来源全景                             │
├─────────────────────────────────────────────────────────────────┤
│  控制平面日志（Control Plane）                                  │
│  ├─ API Server 审计日志       ← 最重要：所有 API 操作记录       │
│  ├─ kube-scheduler 日志       ← 调度决策、资源分配              │
│  ├─ kube-controller-manager 日志 ← 控制器操作、副本管理         │
│  ├─ etcd 日志                 ← 数据变更、Raft 协议             │
│  └─ cloud-controller-manager 日志 ← 云资源生命周期              │
├─────────────────────────────────────────────────────────────────┤
│  节点日志（Node）                                               │
│  ├─ kubelet 日志              ← Pod 生命周期、挂载操作          │
│  ├─ 容器运行时日志（containerd/CRI-O）← 镜像拉取、容器创建      │
│  ├─ 系统日志（/var/log/syslog, journald）← 内核消息、服务日志   │
│  └─ 审计日志（auditd）         ← 系统调用审计                   │
├─────────────────────────────────────────────────────────────────┤
│  工作负载日志（Workload）                                        │
│  ├─ 应用标准输出（stdout/stderr）← 业务日志、错误堆栈            │
│  ├─ 应用文件日志               ← 结构化日志、访问日志            │
│  ├─ Sidecar 代理日志（Envoy/Istio）← 服务网格流量日志            │
│  └─ 初始化容器日志             ← 启动脚本、配置生成              │
├─────────────────────────────────────────────────────────────────┤
│  安全工具日志（Security）                                        │
│  ├─ Falco 告警                ← 运行时威胁检测                  │
│  ├─ Tetragon 事件             ← eBPF 进程/网络跟踪              │
│  ├─ Trivy/Grype 扫描结果      ← 漏洞扫描结果                    │
│  ├─ kube-bench 合规报告       ← CIS 基线检查结果                │
│  ├─ Kubescape 扫描结果        ← NSA/MITRE 框架扫描              │
│  └─ 网络流量日志（Cilium Hubble）← L3-L7 流量可见性             │
├─────────────────────────────────────────────────────────────────┤
│  云平台日志（Cloud）                                             │
│  ├─ CloudTrail / Activity Log  ← 云 API 操作审计                │
│  ├─ VPC Flow Logs             ← 网络流量元数据                  │
│  ├─ Load Balancer 访问日志     ← 入口流量日志                   │
│  └─ GuardDuty / SCC / Defender ← 威胁检测结果                   │
└─────────────────────────────────────────────────────────────────┘
```

### 15.1.2 日志输出方式对比

| 方式 | 优点 | 缺点 | 适用场景 | 推荐度 |
|------|------|------|---------|--------|
| **标准输出** | 原生支持，自动轮转 | 无结构化，丢失上下文 | 简单应用、开发环境 | ⭐⭐⭐ |
| **文件日志** | 持久化，可结构化 | 需要额外采集 | 复杂应用、遗留系统 | ⭐⭐⭐⭐ |
| **Sidecar** | 灵活，不改应用 | 额外资源消耗 | 无法修改的应用 | ⭐⭐⭐ |
| **节点文件** | 系统级日志 | 需要 DaemonSet | kubelet、运行时 | ⭐⭐⭐⭐ |
| **直接推送** | 低延迟 | 耦合度高 | 高价值安全事件 | ⭐⭐⭐ |

### 15.1.3 结构化日志的重要性

```
非结构化日志：
2024-01-15 10:30:45 ERROR connection failed from 10.0.1.5 to db.internal:5432

结构化日志（JSON）：
{
  "timestamp": "2024-01-15T10:30:45Z",
  "level": "ERROR",
  "event": "connection_failed",
  "source_ip": "10.0.1.5",
  "target_host": "db.internal",
  "target_port": 5432,
  "pod_name": "api-service-7d8f9",
  "namespace": "production",
  "trace_id": "abc123",
  "error_code": "ECONNREFUSED"
}

结构化日志的优势：
- 可精确查询（trace_id = "abc123"）
- 可聚合统计（count by namespace）
- 可关联分析（join with audit logs）
- 可自动告警（level = "ERROR" AND count > 100）
```

---

## 15.2 API Server 审计日志深度配置

### 15.2.1 审计策略设计原则

```
审计策略设计原则：

1. 分层记录（Tiered Logging）
   ├─ 高风险操作 → RequestResponse（完整记录）
   ├─ 中等风险 → Request（元数据 + 请求体）
   ├─ 低风险 → Metadata（仅元数据）
   └─ 噪音 → None（不记录）

2. 关键操作必须全记录：
   ├─ Secret 的 create/update/delete
   ├─ RBAC 变更（Role/RoleBinding/ClusterRole/ClusterRoleBinding）
   ├─ Pod 的 exec/attach/portforward
   ├─ 特权 Pod 创建
   ├─ ServiceAccount Token 创建
   └─ Node 的 cordon/drain/delete

3. 性能考虑：
   ├─ RequestResponse 会产生大量数据
   ├─ 对 Secrets 使用 RequestResponse 需权衡
   └─ 使用 batch webhook 减少开销
```

### 15.2.2 生产级审计策略

```yaml
# /etc/kubernetes/audit/production-audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy

# 排除高频低危操作
rules:
  # Level 0: 完全排除（减少噪音）
  - level: None
    resources:
    - group: ""
      resources: ["events", "endpoints", "endpointslices"]
    users: ["system:kube-scheduler", "system:kube-proxy", "system:node:*"]
    verbs: ["get", "list", "watch"]
    omitStages:
    - RequestReceived

  # Level 1: Metadata（只记录元数据）
  - level: Metadata
    resources:
    - group: ""
      resources: ["pods", "deployments", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
    omitStages:
    - RequestReceived

  # Level 2: Request（元数据 + 请求体）
  - level: Request
    resources:
    - group: ""
      resources: ["configmaps", "serviceaccounts"]
    verbs: ["create", "update", "patch"]
    omitStages:
    - RequestReceived

  # Level 3: RequestResponse（完整记录）
  # 3.1 Secret 操作（注意：Response 包含 Secret 数据）
  - level: RequestResponse
    resources:
    - group: ""
      resources: ["secrets"]
    verbs: ["create", "update", "patch", "delete"]
    omitStages:
    - RequestReceived

  # 3.2 RBAC 变更
  - level: RequestResponse
    resources:
    - group: rbac.authorization.k8s.io
      resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]
    omitStages:
    - RequestReceived

  # 3.3 特权操作（exec/attach/portforward/proxy）
  - level: RequestResponse
    resources:
    - group: ""
      resources: ["pods"]
    verbs: ["create"]
    subresources: ["exec", "attach", "portforward", "proxy", "binding", "eviction"]
    omitStages:
    - RequestReceived

  # 3.4 Pod/Deployment 创建（用于检测特权容器）
  - level: RequestResponse
    resources:
    - group: ""
      resources: ["pods", "deployments", "replicasets", "daemonsets", "statefulsets", "jobs"]
    verbs: ["create", "update"]
    omitStages:
    - RequestReceived

  # 3.5 ServiceAccount Token 创建
  - level: RequestResponse
    resources:
    - group: ""
      resources: ["serviceaccounts/token"]
    verbs: ["create"]
    omitStages:
    - RequestReceived

  # 3.6 Node 变更
  - level: RequestResponse
    resources:
    - group: ""
      resources: ["nodes"]
    verbs: ["create", "update", "patch", "delete", "cordon", "drain"]
    omitStages:
    - RequestReceived

  # 3.7 网络策略变更
  - level: RequestResponse
    resources:
    - group: networking.k8s.io
      resources: ["networkpolicies", "ingresses"]
    verbs: ["create", "update", "patch", "delete"]
    omitStages:
    - RequestReceived

  # 默认级别
  - level: Metadata
    omitStages:
    - RequestReceived
```

### 15.2.3 API Server 审计配置

```bash
# kube-apiserver 启动参数
# /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
  - command:
    - kube-apiserver
    # 本地日志文件（备用）
    - --audit-log-path=/var/log/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --audit-log-format=json
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    # Webhook（推荐用于生产）
    - --audit-webhook-config-file=/etc/kubernetes/audit/webhook.yaml
    - --audit-webhook-mode=batch
    - --audit-webhook-batch-max-size=400
    - --audit-webhook-batch-max-wait=1s
    - --audit-webhook-truncate-enabled=true
    - --audit-webhook-truncate-max-batch-size=10485760
    volumeMounts:
    - mountPath: /etc/kubernetes/audit
      name: audit-config
      readOnly: true
    - mountPath: /var/log/audit
      name: audit-logs
  volumes:
  - hostPath:
      path: /etc/kubernetes/audit
      type: DirectoryOrCreate
    name: audit-config
  - hostPath:
      path: /var/log/audit
      type: DirectoryOrCreate
    name: audit-logs
```

**Webhook 配置文件**：

```yaml
# /etc/kubernetes/audit/webhook.yaml
apiVersion: v1
kind: Config
clusters:
- name: audit-cluster
  cluster:
    server: https://audit-collector.monitoring.svc.cluster.local/webhook
    certificate-authority: /etc/kubernetes/pki/audit-ca.crt
    # 或使用 insecure-skip-tls-verify: true（不推荐）
users:
- name: audit-user
  user:
    token: ${AUDIT_WEBHOOK_TOKEN}
contexts:
- name: audit-context
  context:
    cluster: audit-cluster
    user: audit-user
current-context: audit-context
```

### 15.2.4 审计日志分析

```bash
# 审计日志字段解析
# 每条审计日志包含以下关键字段：

# {
#   "kind": "Event",
#   "apiVersion": "audit.k8s.io/v1",
#   "level": "RequestResponse",
#   "auditID": "12345-abc",
#   "stage": "ResponseComplete",
#   "requestURI": "/api/v1/namespaces/default/pods",
#   "verb": "create",
#   "user": {
#     "username": "admin@company.com",
#     "groups": ["system:authenticated"]
#   },
#   "sourceIPs": ["10.0.1.100"],
#   "userAgent": "kubectl/v1.28.0",
#   "objectRef": {
#     "resource": "pods",
#     "namespace": "default",
#     "name": "nginx"
#   },
#   "responseStatus": {
#     "code": 201
#   },
#   "requestObject": { ... },  # 请求体（Level=Request/RequestResponse）
#   "responseObject": { ... }  # 响应体（Level=RequestResponse）
# }

# 分析脚本：检测异常操作
cat << 'EOF' > analyze_audit.sh
#!/bin/bash
AUDIT_LOG="/var/log/audit/audit.log"

echo "=== 审计日志分析 ==="

echo "\n[1] 最近失败的认证"
jq -r 'select(.responseStatus.code | tostring | startswith("4")) | 
  [.requestReceivedTimestamp, .user.username, .verb, .requestURI, .responseStatus.code] | @tsv' \
  $AUDIT_LOG | tail -20

echo "\n[2] 特权 Pod 创建"
jq -r 'select(.requestObject.spec.containers[].securityContext.privileged == true) |
  [.requestReceivedTimestamp, .user.username, .objectRef.namespace, .objectRef.name] | @tsv' \
  $AUDIT_LOG | tail -10

echo "\n[3] RBAC 变更"
jq -r 'select(.objectRef.resource | test("roles|rolebindings")) |
  [.requestReceivedTimestamp, .user.username, .verb, .objectRef.resource, .objectRef.name] | @tsv' \
  $AUDIT_LOG | tail -10

echo "\n[4] exec/attach 操作"
jq -r 'select(.objectRef.subresource | test("exec|attach|portforward")) |
  [.requestReceivedTimestamp, .user.username, .objectRef.namespace, .objectRef.name, .objectRef.subresource] | @tsv' \
  $AUDIT_LOG | tail -20

echo "\n[5] Secret 访问"
jq -r 'select(.objectRef.resource == "secrets" and .verb == "get") |
  [.requestReceivedTimestamp, .user.username, .objectRef.namespace, .objectRef.name] | @tsv' \
  $AUDIT_LOG | tail -20
EOF
chmod +x analyze_audit.sh
```

---

## 15.3 日志采集架构

### 15.3.1 Fluent Bit + Loki 轻量级方案

```
┌─────────────────────────────────────────────────────────────┐
│                  Fluent Bit + Loki 架构                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐               │
│   │ App Pod │    │ App Pod │    │ App Pod │               │
│   │ stdout  │    │ stdout  │    │ stdout  │               │
│   └────┬────┘    └────┬────┘    └────┬────┘               │
│        │              │              │                      │
│        └──────────────┼──────────────┘                      │
│                       │                                      │
│              ┌────────▼────────┐                            │
│              │  /var/log/pods  │                            │
│              │ /var/log/containers                          │
│              └────────┬────────┘                            │
│                       │                                      │
│              ┌────────▼────────┐                            │
│              │  Fluent Bit     │  ◄── DaemonSet              │
│              │  (采集+解析)     │                            │
│              │                 │                            │
│              │  [INPUT] tail   │  ← 容器日志                 │
│              │  [INPUT] tail   │  ← 审计日志                 │
│              │  [FILTER] k8s   │  ← 元数据丰富               │
│              │  [OUTPUT] loki  │  → 发送                     │
│              └────────┬────────┘                            │
│                       │                                      │
│              ┌────────▼────────┐                            │
│              │     Loki        │  ◄── 日志存储               │
│              │  (水平可扩展)    │                            │
│              └────────┬────────┘                            │
│                       │                                      │
│              ┌────────▼────────┐                            │
│              │    Grafana      │  ◄── 查询展示               │
│              │   (LogQL)       │                            │
│              └─────────────────┘                            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Fluent Bit 完整配置**：

```yaml
# fluent-bit-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Daemon        off
        Parsers_File  parsers.conf
        HTTP_Server   On
        HTTP_Listen   0.0.0.0
        HTTP_Port     2020
        Health_Check  On

    # 容器日志输入
    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/*.log
        Parser            docker
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On
        Refresh_Interval  10

    # 审计日志输入
    [INPUT]
        Name              tail
        Tag               audit.*
        Path              /var/log/audit/audit.log
        Parser            json
        DB                /var/log/flb_audit.db
        Mem_Buf_Limit     5MB

    # kubelet 日志
    [INPUT]
        Name              systemd
        Tag               kubelet
        Systemd_Filter    _SYSTEMD_UNIT=kubelet.service
        DB                /var/log/flb_systemd.db

    # Kubernetes 元数据丰富
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off

    # 添加集群标签
    [FILTER]
        Name          record_modifier
        Match         *
        Record        cluster_name production
        Record        environment prod

    # Loki 输出
    [OUTPUT]
        Name            loki
        Match           kube.*
        Host            loki.logging.svc.cluster.local
        Port            3100
        Labels          job=fluentbit, cluster=$cluster_name, namespace=$kubernetes['namespace_name'], pod=$kubernetes['pod_name'], container=$kubernetes['container_name']
        Line_Format     json
        Drop_Records    No

    # 审计日志单独输出
    [OUTPUT]
        Name            loki
        Match           audit.*
        Host            loki.logging.svc.cluster.local
        Port            3100
        Labels          job=audit, cluster=$cluster_name
        Line_Format     json

  parsers.conf: |
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On

    [PARSER]
        Name        json
        Format      json
        Time_Key    requestReceivedTimestamp
        Time_Format %Y-%m-%dT%H:%M:%S.%NZ
```

### 15.3.2 ELK/EFK 企业级方案

```
┌──────────────────────────────────────────────────────────────┐
│                    ELK/EFK 企业级架构                         │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐                │
│   │ App Pod │    │ App Pod │    │ App Pod │                │
│   │ stdout  │    │ stdout  │    │ stdout  │                │
│   └────┬────┘    └────┬────┘    └────┬────┘                │
│        │              │              │                       │
│        └──────────────┼──────────────┘                       │
│                       │                                       │
│              ┌────────▼────────┐                             │
│              │  Fluentd/Bit    │  ◄── DaemonSet               │
│              │  (采集+缓冲)     │                             │
│              └────────┬────────┘                             │
│                       │                                       │
│              ┌────────▼────────┐                             │
│              │     Kafka       │  ◄── 消息队列（缓冲）        │
│              │  (高吞吐缓冲)    │                             │
│              └────────┬────────┘                             │
│                       │                                       │
│              ┌────────▼────────┐                             │
│              │    Logstash     │  ◄── 解析处理                │
│              │  (过滤+解析+增强)│                             │
│              └────────┬────────┘                             │
│                       │                                       │
│              ┌────────▼────────┐                             │
│              │ Elasticsearch   │  ◄── 存储+索引               │
│              │  (集群+分片)     │                             │
│              └────────┬────────┘                             │
│                       │                                       │
│              ┌────────▼────────┐                             │
│              │     Kibana      │  ◄── 查询可视化              │
│              │  (Discover+Lens)│                             │
│              └─────────────────┘                             │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### 15.3.3 OpenTelemetry 现代化方案

```yaml
# OpenTelemetry Collector 配置
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: monitoring
spec:
  mode: daemonset
  config: |
    receivers:
      filelog:
        include:
          - /var/log/pods/*/*/*.log
        operators:
          - type: json_parser
            timestamp:
              parse_from: attributes.time
              layout: '%Y-%m-%dT%H:%M:%S.%LZ'
          - type: metadata
            id: add-k8s-metadata
            resource:
              k8s.pod.name: EXPR(env("K8S_POD_NAME"))
              k8s.namespace.name: EXPR(env("K8S_NAMESPACE"))

    processors:
      batch:
        timeout: 1s
        send_batch_size: 1024
      resource:
        attributes:
          - key: cluster.name
            value: production
            action: upsert

    exporters:
      loki:
        endpoint: http://loki.monitoring.svc:3100/loki/api/v1/push
      prometheusremotewrite:
        endpoint: http://prometheus:9090/api/v1/write

    service:
      pipelines:
        logs:
          receivers: [filelog]
          processors: [batch, resource]
          exporters: [loki]
```

---

## 15.4 安全告警规则

### 15.4.1 Loki LogQL 安全查询

```bash
# ========== 威胁检测查询 ==========

# 1. 特权容器创建
{job="fluentbit"} 
  | json
  | requestObject_spec_containers_securityContext_privileged = "true"
  | line_format "{{.user_username}} created privileged pod {{.objectRef_name}} in {{.objectRef_namespace}}"

# 2. exec/attach/portforward 操作（实时告警）
{job="audit"}
  | json
  | objectRef_subresource =~ "exec|attach|portforward"
  | user_username != "system:.*"
  | line_format "{{.user_username}} executed {{.objectRef_subresource}} on {{.objectRef_namespace}}/{{.objectRef_name}}"

# 3. RBAC 权限提升
{job="audit"}
  | json
  | objectRef_resource =~ "clusterroles|clusterrolebindings"
  | verb = "create"
  | line_format "{{.user_username}} created {{.objectRef_resource}}/{{.objectRef_name}}"

# 4. Secret 被非系统用户访问
{job="audit"}
  | json
  | objectRef_resource = "secrets"
  | verb = "get"
  | user_username !=~ "system:.*|.*controller|.*scheduler"
  | line_format "{{.user_username}} accessed secret {{.objectRef_namespace}}/{{.objectRef_name}}"

# 5. 失败的认证尝试（可能的暴力破解）
{job="audit"}
  | json
  | responseStatus_code = "401"
  | user_username != "system:anonymous"
  | line_format "Failed auth from {{.sourceIPs}} as {{.user_username}}"

# 6. 异常时间操作（凌晨操作）
{job="audit"}
  | json
  | verb =~ "create|update|delete"
  | user_username !=~ "system:.*"
  | line_format "{{.user_username}} {{.verb}} {{.objectRef_resource}} at {{.requestReceivedTimestamp}}"

# 7. Node 变更（可能的节点劫持）
{job="audit"}
  | json
  | objectRef_resource = "nodes"
  | verb =~ "delete|cordon|drain"
  | line_format "{{.user_username}} performed {{.verb}} on node {{.objectRef_name}}"

# 8. ServiceAccount Token 创建（横向移动）
{job="audit"}
  | json
  | objectRef_resource = "serviceaccounts"
  | objectRef_subresource = "token"
  | line_format "{{.user_username}} created token for {{.objectRef_namespace}}/{{.objectRef_name}}"
```

### 15.4.2 Falco 告警结构化输出

```yaml
# /etc/falco/falco.yaml
json_output: true
json_include_output_property: true
json_include_tags_property: true

file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco/events.log

http_output:
  enabled: true
  url: http://alertmanager.monitoring.svc:9093/v1/alerts

# 输出格式示例：
# {
#   "priority": "Critical",
#   "rule": "Launch Privileged Container",
#   "time": "2026-01-15T10:30:00.000000000Z",
#   "output_fields": {
#     "container.id": "12345abc",
#     "container.image.repository": "ubuntu",
#     "container.name": "bad-pod",
#     "k8s.ns.name": "default",
#     "k8s.pod.name": "privileged-test",
#     "proc.cmdline": "docker-entrypoint.sh nginx",
#     "user.name": "root"
#   },
#   "hostname": "node-1",
#   "tags": ["mitre_privilege_escalation", "container"]
# }
```

### 15.4.3 Prometheus Alertmanager 安全告警

```yaml
# prometheus-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: k8s-security-alerts
  namespace: monitoring
spec:
  groups:
  - name: k8s-security
    interval: 30s
    rules:
    # 特权容器启动
    - alert: PrivilegedContainerCreated
      expr: |
        increase(falco_events{priority="Critical"}[5m]) > 0
      for: 0m
      labels:
        severity: critical
        team: security
      annotations:
        summary: "Privileged container detected"
        description: "Container {{ $labels.container_name }} in namespace {{ $labels.k8s_ns_name }} started with privileged mode"
        runbook_url: "https://wiki.company.com/runbooks/privileged-container"

    # 高频率 API 失败
    - alert: K8sAuditHighFailureRate
      expr: |
        (
          sum(rate(kube_audit_event_total{response_code=~"401|403|500"}[5m]))
          /
          sum(rate(kube_audit_event_total[5m]))
        ) > 0.05
      for: 5m
      labels:
        severity: warning
        team: security
      annotations:
        summary: "High rate of failed K8s API requests"
        description: "{{ $value | humanizePercentage }} of API requests are failing"

    # 异常 exec 操作
    - alert: UnexpectedExecActivity
      expr: |
        sum by (user_username) (
          rate(kube_audit_event_total{subresource="exec"}[1h])
        ) > 0
      for: 10m
      labels:
        severity: info
        team: security
      annotations:
        summary: "Unexpected exec activity"

    # Falco 告警风暴
    - alert: FalcoAlertStorm
      expr: |
        sum(rate(falco_events[5m])) > 10
      for: 5m
      labels:
        severity: warning
        team: security
      annotations:
        summary: "Falco alert storm detected"
        description: "{{ $value }} alerts per second"
```

---

## 15.5 SIEM 集成实战

### 15.5.1 Splunk 集成

```bash
# 方式1：Splunk Connect for Kubernetes
helm repo add splunk https://splunk.github.io/splunk-connect-for-kubernetes/
helm install splunk-connect splunk/splunk-connect-for-kubernetes \
  --set splunk.hec.host=splunk-hec.company.com \
  --set splunk.hec.token=<hec-token> \
  --set splunk.hec.index=kubernetes \
  --set splunk.hec.port=8088 \
  --set splunk.hec.protocol=https \
  --set logs.enabled=true \
  --set logs.containers.path=/var/log/containers \
  --set metrics.enabled=true \
  --set objects.enabled=true \
  --set rbac.create=true

# 方式2：Fluent Bit 直接输出到 Splunk HEC
# 在 fluent-bit-config.yaml 中添加：
[OUTPUT]
    Name            splunk
    Match           *
    Host            splunk-hec.company.com
    Port            8088
    Splunk_Token    <hec-token>
    TLS             On
    TLS.Verify      Off
    Splunk_Send_Raw On
```

### 15.5.2 Azure Sentinel 集成

```bash
# 1. 创建 Log Analytics Workspace
az monitor log-analytics workspace create \
  --resource-group my-rg \
  --name k8s-security-workspace \
  --location eastus

# 2. 启用 Container Insights
az aks enable-addons \
  --resource-group my-rg \
  --name production \
  --addons monitoring \
  --workspace-resource-id /subscriptions/<sub>/resourcegroups/my-rg/providers/microsoft.operationalinsights/workspaces/k8s-security-workspace

# 3. 启用 Sentinel
az sentinel create \
  --resource-group my-rg \
  --workspace-name k8s-security-workspace

# 4. 在 Sentinel 中创建 K8s 检测规则（KQL）
# - 异常 Pod 创建
# - 特权容器
# - RBAC 变更
```

**Sentinel KQL 检测规则示例**：

```kusto
// 特权容器创建
KubeAuditAdmin
| where ObjectRefResource == "pods"
| extend PodSpec = parse_json(RequestObject)
| where PodSpec.spec.containers.securityContext.privileged == true
| project TimeGenerated, UserUsername, ObjectRefNamespace, ObjectRefName

// RBAC 权限提升
KubeAuditAdmin
| where ObjectRefResource in ("clusterroles", "clusterrolebindings")
| where Verb in ("create", "update")
| project TimeGenerated, UserUsername, Verb, ObjectRefResource, ObjectRefName
```

### 15.5.3 Elastic Security 集成

```yaml
# Filebeat 配置采集 K8s 日志
apiVersion: v1
kind: ConfigMap
metadata:
  name: filebeat-config
  namespace: monitoring
data:
  filebeat.yml: |
    filebeat.inputs:
    - type: container
      paths:
        - /var/log/containers/*.log
      processors:
        - add_kubernetes_metadata:
            host: ${NODE_NAME}
            matchers:
            - logs_path:
                logs_path: "/var/log/containers/"

    - type: log
      paths:
        - /var/log/audit/audit.log
      fields:
        log_type: k8s_audit
      fields_under_root: true

    output.elasticsearch:
      hosts: ["https://elasticsearch.monitoring.svc:9200"]
      username: "${ES_USERNAME}"
      password: "${ES_PASSWORD}"
      ssl.certificate_authorities: ["/etc/ssl/certs/ca.crt"]

    setup.kibana:
      host: "https://kibana.monitoring.svc:5601"
```

---

## 15.6 日志安全与合规

### 15.6.1 日志传输安全

```yaml
# Fluent Bit TLS 配置
[OUTPUT]
    Name            loki
    Match           *
    Host            loki.logging.svc.cluster.local
    Port            3100
    TLS             On
    TLS.Verify      On
    TLS.CA_File     /etc/ssl/certs/ca.crt
    TLS.Cert_File   /etc/ssl/certs/client.crt
    TLS.Key_File    /etc/ssl/certs/client.key
    TLS.Key_Password ${TLS_KEY_PASSWORD}
```

### 15.6.2 日志存储加密

```yaml
# Loki 存储加密（使用 S3 + KMS）
auth_enabled: false

server:
  http_listen_port: 3100

common:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
  replication_factor: 1
  path_prefix: /tmp/loki

schema_config:
  configs:
  - from: 2020-05-15
    store: boltdb-shipper
    object_store: s3
    schema: v11
    index:
      prefix: index_
      period: 24h

storage_config:
  aws:
    s3: s3://us-west-2/my-loki-bucket
    sse_encryption: true
    sse:
      type: SSE-KMS
      kms_key_id: arn:aws:kms:us-west-2:123456789012:key/12345
```

### 15.6.3 日志保留策略

| 日志类型 | 建议保留期 | 合规要求 | 存储位置 |
|---------|-----------|---------|---------|
| API 审计日志 | 1年+ | SOC2/ISO27001 | 热存储 30 天 + 冷存储 |
| 安全告警（Falco） | 3年+ | 法律证据 | 对象存储 |
| 应用日志 | 30-90天 | 排障需要 | 热存储 |
| 容器运行时日志 | 30天 | 运行时分析 | 热存储 |
| 云平台审计日志 | 1年+ | 合规 | 云存储 |

### 15.6.4 日志脱敏

```yaml
# Fluent Bit 脱敏过滤器
[FILTER]
    Name          modify
    Match         kube.*
    # 删除敏感字段
    Remove        password
    Remove        token
    Remove        secret
    Remove        api_key
    Remove        private_key

[FILTER]
    Name          lua
    Match         kube.*
    Script        /fluent-bit/scripts/mask.lua
    Call          mask_sensitive_data
```

```lua
-- mask.lua
function mask_sensitive_data(tag, timestamp, record)
    local sensitive_patterns = {
        ["password"] = "***REDACTED***",
        ["token"] = "***REDACTED***",
        ["secret"] = "***REDACTED***",
        ["api_key"] = "***REDACTED***"
    }
    
    for key, mask in pairs(sensitive_patterns) do
        if record[key] then
            record[key] = mask
        end
    end
    
    return 1, timestamp, record
end
```

---

## 15.7 威胁狩猎

### 15.7.1 基于审计日志的威胁狩猎

```bash
# ========== 威胁狩猎查询集 ==========

# 1. 横向移动检测
# 查找同一用户短时间内访问多个命名空间的 Secret
jq -r '
  select(.objectRef.resource == "secrets" and .verb == "get") |
  [.user.username, .objectRef.namespace, .requestReceivedTimestamp] | @tsv
' /var/log/audit/audit.log | \
  awk '{print $1, $2}' | sort | uniq -c | sort -rn | head -20
# 如果同一用户访问了 >5 个命名空间的 Secret，可疑！

# 2. 权限提升时间线
# 查找 RBAC 变更后紧跟的特权操作
jq -r '
  select(
    (.objectRef.resource | test("roles|rolebindings")) or
    (.requestObject.spec.containers[].securityContext.privileged == true)
  ) |
  [.requestReceivedTimestamp, .user.username, .verb, .objectRef.resource, .objectRef.name] | @tsv
' /var/log/audit/audit.log | sort

# 3. 异常时间操作
# 查找非工作时间（22:00-06:00）的高风险操作
jq -r '
  select(.verb =~ "create|update|delete" and .user.username !=~ "system:.*") |
  select(.requestReceivedTimestamp | match("T(0[0-5]|2[2-9])")) |
  [.requestReceivedTimestamp, .user.username, .verb, .objectRef.resource] | @tsv
' /var/log/audit/audit.log

# 4. 来自异常 IP 的访问
# 查找来自非公司 IP 段的 API 访问
jq -r '
  select(.sourceIPs[0] | test("^(?!10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)")) |
  [.requestReceivedTimestamp, .user.username, .sourceIPs[0], .requestURI] | @tsv
' /var/log/audit/audit.log
```

### 15.7.2 基于日志的异常检测

```yaml
# Prometheus 异常检测规则
- alert: UnusualAPIActivity
  expr: |
    (
      sum by (user_username) (
        rate(kube_audit_event_total[1h])
      )
      >
      3 * avg by (user_username) (
        rate(kube_audit_event_total[1h] offset 7d)
      )
    )
  for: 15m
  labels:
    severity: warning
  annotations:
    summary: "Unusual API activity detected"
    description: "User {{ $labels.user_username }} has 3x normal API call rate"
```

---

## 15.8 本章实验

### 实验 15.1：配置 API Server 审计日志（20 分钟）

```bash
# 步骤 1：创建审计策略
sudo mkdir -p /etc/kubernetes/audit
sudo tee /etc/kubernetes/audit/policy.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets", "pods"]
  verbs: ["create", "update", "delete"]
- level: RequestResponse
  resources:
  - group: rbac.authorization.k8s.io
    resources: ["roles", "rolebindings"]
  verbs: ["create", "update", "delete"]
- level: Metadata
  omitStages:
  - RequestReceived
EOF

# 步骤 2：修改 kube-apiserver
sudo vim /etc/kubernetes/manifests/kube-apiserver.yaml
# 添加：
# --audit-policy-file=/etc/kubernetes/audit/policy.yaml
# --audit-log-path=/var/log/audit/audit.log
# --audit-log-maxage=30
# --audit-log-maxbackup=10
# --audit-log-maxsize=100

# 步骤 3：验证审计日志
sudo tail -f /var/log/audit/audit.log | jq .

# 步骤 4：触发审计事件
kubectl create secret generic test-secret --from-literal=key=value
kubectl delete secret test-secret

# 步骤 5：分析日志
sudo cat /var/log/audit/audit.log | jq -r '
  select(.objectRef.resource == "secrets") |
  [.requestReceivedTimestamp, .user.username, .verb, .objectRef.name] | @tsv'
```

### 实验 15.2：部署 Fluent Bit + Loki + Grafana（30 分钟）

```bash
# 步骤 1：添加 Helm 仓库
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# 步骤 2：部署 Loki（单节点模式）
helm install loki grafana/loki-stack \
  --namespace monitoring --create-namespace \
  --set promtail.enabled=false \
  --set grafana.enabled=false

# 步骤 3：部署 Fluent Bit
helm install fluent-bit fluent/fluent-bit \
  --namespace monitoring \
  --set config.outputs='[OUTPUT]
    Name loki
    Match *
    Host loki.monitoring.svc.cluster.local
    Port 3100'

# 步骤 4：部署 Grafana
helm install grafana grafana/grafana \
  --namespace monitoring \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Loki \
  --set datasources."datasources\.yaml".datasources[0].type=loki \
  --set datasources."datasources\.yaml".datasources[0].url=http://loki:3100

# 步骤 5：获取 Grafana 密码
kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 -d

# 步骤 6：端口转发访问 Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000

# 步骤 7：在 Grafana 中查询日志
# http://localhost:3000/explore
# 查询：{job="fluentbit"} |= "error"
```

### 实验 15.3：创建安全告警 Dashboard（25 分钟）

```bash
# 在 Grafana 中创建 Dashboard，包含以下 Panel：

# Panel 1: 特权容器启动趋势
# LogQL: sum(rate({job="fluentbit"} |= "privileged" [5m]))

# Panel 2: RBAC 变更时间线
# LogQL: {job="audit"} | json | objectRef_resource=~"roles|rolebindings"

# Panel 3: API 请求失败率
# LogQL: {job="audit"} | json | responseStatus_code=~"4xx|5xx"

# Panel 4: Top 10 活跃用户
# LogQL: topk(10, sum by (user_username) (rate({job="audit"}[1h])))

# Panel 5: exec/attach 操作统计
# LogQL: sum by (objectRef_subresource) (rate({job="audit"} | json | objectRef_subresource=~"exec|attach|portforward" [5m]))

# Panel 6: Secret 访问热力图
# LogQL: sum by (objectRef_namespace) (rate({job="audit"} | json | objectRef_resource="secrets" [1h]))
```

---

## 15.9 本章练习题

### 选择题

1. **API Server 审计日志的四个级别是什么？**
   - A. Debug, Info, Warning, Error
   - B. None, Metadata, Request, RequestResponse
   - C. Low, Medium, High, Critical
   - D. Silent, Quiet, Normal, Verbose

2. **为什么审计日志中 Secret 的 RequestResponse 级别需要谨慎使用？**
   - A. 性能开销大
   - B. Secret 数据会记录在日志中
   - C. 日志文件太大
   - D. 不支持 JSON 格式

3. **Fluent Bit 相比 Fluentd 的主要优势是什么？**
   - A. 功能更丰富
   - B. 更轻量、性能更高
   - C. 支持更多输出插件
   - D. 配置更简单

4. **日志脱敏的最佳实践是什么？**
   - A. 在应用层脱敏
   - B. 在采集层脱敏
   - C. 在存储层脱敏
   - D. 在查询时脱敏

### 简答题

1. 设计一个生产级 K8s 审计策略。需要考虑哪些关键因素？如何平衡安全可见性和性能开销？

2. 描述 Fluent Bit + Loki 日志采集架构的完整数据流。为什么推荐使用 DaemonSet 部署 Fluent Bit？

3. 如何在 SIEM 中构建 K8s 安全检测规则？列举至少 5 种应该监控的异常行为。

4. 日志保留策略应该如何设计？不同类型日志的保留期应如何确定？

### 实践题

1. **审计日志配置**（30 分钟）：
   - 配置 API Server 审计策略
   - 记录 Secret 操作、RBAC 变更、exec/attach
   - 分析审计日志，识别异常行为

2. **日志采集管道**（45 分钟）：
   - 部署 Fluent Bit + Loki + Grafana
   - 配置采集容器日志和审计日志
   - 创建安全告警 Dashboard
   - 测试告警规则

3. **威胁狩猎**（30 分钟）：
   - 在审计日志中执行以下搜索：
     - 查找失败的认证尝试
     - 查找非工作时间的操作
     - 查找特权容器创建
   - 编写自动化脚本定期执行这些搜索

---

## 15.10 本章小结

| 主题 | 关键要点 |
|------|---------|
| **日志来源** | 控制平面、节点、工作负载、安全工具、云平台 |
| **审计策略** | None/Metadata/Request/RequestResponse 四级分层 |
| **采集架构** | Fluent Bit + Loki（轻量）/ EFK（企业）/ OpenTelemetry（现代） |
| **安全查询** | LogQL/KQL 用于威胁检测和狩猎 |
| **SIEM 集成** | Splunk、Sentinel、Elastic Security |
| **告警规则** | Falco → Prometheus → Alertmanager |
| **日志安全** | TLS 传输、存储加密、访问控制、日志脱敏 |
| **保留策略** | 审计 1年+，告警 3年+，应用 30-90天 |

**核心原则**：
1. **先采集再分析**：没有日志就无法检测
2. **分层策略**：不同日志不同级别，平衡性能和可见性
3. **结构化优先**：JSON 格式便于查询和关联
4. **实时告警**：关键安全事件需要实时通知
5. **保留合规**：满足法律和业务需求

**推荐阅读**：
- Kubernetes 审计文档：https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Loki 文档：https://grafana.com/docs/loki/
- Falco 输出配置：https://falco.org/docs/outputs/

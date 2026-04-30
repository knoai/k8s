# 生产排障：API Server 502/504 错误

> API Server 返回 502 Bad Gateway 或 504 Gateway Timeout 时，
> 故障点可能在 API Server 本身、etcd、网络层或上游组件。

---

## 502 vs 504 的区别

| 状态码 | 含义 | 典型场景 |
|--------|------|---------|
| **502** | Bad Gateway | API Server 作为网关，上游服务返回无效响应 |
| **504** | Gateway Timeout | API Server 或上游服务处理超时 |

```
请求链路中的 502/504：

Client → LoadBalancer → API Server → etcd
    │          │             │          │
    │          │             │          └─ 502: etcd 返回错误
    │          │             │          └─ 504: etcd 响应超时
    │          │             │
    │          │             └─ 504: API Server 处理超时
    │          │             └─ 502: admission webhook 返回错误
    │          │
    │          └─ 504: LoadBalancer 超时（AWS ALB 默认 60s）
    │          └─ 502: LoadBalancer 健康检查失败
    │
    └─ 504: Client 侧超时
```

---

## 诊断流程

### 步骤 1：确认错误来源

```bash
# 方法 1：查看 API Server 日志
kubectl logs -n kube-system -l component=kube-apiserver --tail=100 | grep -E "502|504|timeout|error"

# 典型 502 日志（admission webhook 失败）：
# E0115 08:30:00.123456       1 dispatcher.go:181] failed calling webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc": 
#   failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/validate?timeout=10s": 
#   context deadline exceeded
# I0115 08:30:00.234567       1 trace.go:219] Trace[1234567890]: "Create" url:/api/v1/namespaces/default/pods,user-agent:kubectl/v1.28.0 (linux/amd64) kubernetes/12345a 
#   (15-Jan-2024 08:29:50.123) (total time: 10013ms):
# Trace[1234567890]: --"Object stored in database" 10013ms (08:30:00.234)
# Trace[1234567890]: [10.013982s] [10.013982s] END

# 典型 504 日志（etcd 超时）：
# E0115 08:30:00.345678       1 status.go:71] apiserver received an error that is not an metav1.Status: 
#   rpc error: code = DeadlineExceeded desc = context deadline exceeded
# E0115 08:30:00.456789       1 watcher.go:123] failed to create watcher for *v1.Pod: 
#   etcdserver: request timed out
# I0115 08:30:00.567890       1 trace.go:219] Trace[9876543210]: "Get" url:/api/v1/namespaces/default/pods/nginx 
#   (total time: 5002ms):
# Trace[9876543210]: --"About to write a response" 5002ms (08:30:00.567)
# Trace[9876543210]: [5.002134s] [5.002134s] END

# 方法 2：查看审计日志
grep -E '"responseStatus".*"code".*50[24]' /var/log/audit/audit.log | tail -20

# 审计日志输出：
# {"kind":"Event","apiVersion":"audit.k8s.io/v1","level":"RequestResponse",
#  "auditID":"abc12345-6789-0123-4567-890abcdef012",
#  "stage":"ResponseComplete",
#  "requestURI":"/api/v1/namespaces/default/pods",
#  "verb":"create",
#  "user":{"username":"admin"},
#  "objectRef":{"resource":"pods","namespace":"default"},
#  "responseStatus":{"metadata":{},"code":504,"status":"Failure",
#    "message":"Timeout: request did not complete within requested timeout 34s",
#    "reason":"Timeout","details":{},"code":504},
#  "requestReceivedTimestamp":"2024-01-15T08:29:50.123456Z",
#  "stageTimestamp":"2024-01-15T08:30:24.567890Z"}
# ← 请求耗时 34 秒，最终 504

# 方法 3：API Server 指标
kubectl get --raw /metrics 2>/dev/null | grep -E "apiserver_request_duration_seconds|apiserver_request_total"

# 输出：
# apiserver_request_duration_seconds_bucket{verb="POST",resource="pods",le="0.005"} 12345
# apiserver_request_duration_seconds_bucket{verb="POST",resource="pods",le="0.01"} 23456
# apiserver_request_duration_seconds_bucket{verb="POST",resource="pods",le="+Inf"} 123456
# apiserver_request_duration_seconds_sum{verb="POST",resource="pods"} 456.789
# apiserver_request_duration_seconds_count{verb="POST",resource="pods"} 123456
# → 平均 POST Pod 时间 = 456.789/123456 = 3.7ms

# apiserver_request_total{code="504",verb="POST",resource="pods"} 234
# apiserver_request_total{code="502",verb="POST",resource="pods"} 56
# ← 234 次 504，56 次 502！
```

---

## 根因 1：Admission Webhook 超时

### 现象

```bash
# API Server 日志
# E0115 08:30:00.123456 1 dispatcher.go:181] failed calling webhook "kyverno-resource-validating-webhook-cfg.kyverno.svc": 
#   Post "https://kyverno-svc.kyverno.svc:443/validate?timeout=10s": context deadline exceeded

# 请求被 webhook 阻塞 10 秒后超时

# 检查 webhook 配置
kubectl get validatingwebhookconfiguration -o yaml | grep -A 5 timeoutSeconds

# 输出：
# timeoutSeconds: 10
# ← 只有 10 秒超时

# webhook 服务状态
kubectl get svc kyverno-svc -n kyverno
# NAME          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
# kyverno-svc   ClusterIP   10.96.123.45    <none>        443/TCP   10d

kubectl get pod -n kyverno -l app=kyverno
# NAME                       READY   STATUS    RESTARTS   AGE
# kyverno-7d4c7b5f9d-abc12   1/1     Running   0          10d
# kyverno-7d4c7b5f9d-def34   0/1     Pending   0          10d
# ← 1 个 Pod Pending！只有 1/2 副本可用，负载翻倍！

# 检查 kyverno Pod 资源
kubectl top pod -n kyverno
# NAME                       CPU(cores)   MEMORY(bytes)
# kyverno-7d4c7b5f9d-abc12   950m         1024Mi
# ← CPU 接近 limit（假设 limit=1000m），处理延迟增加！
```

### 诊断 Webhook 延迟

```bash
# 从 API Server Pod 测试 webhook 连通性
kubectl exec -it <apiserver-pod> -n kube-system -- /bin/sh -c '
  # 测试 DNS 解析
  time nslookup kyverno-svc.kyverno.svc.cluster.local
  
  # 测试 TCP 连接
  time nc -zv kyverno-svc.kyverno.svc.cluster.local 443
'

# 预期输出（健康）：
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
# Name:      kyverno-svc.kyverno.svc.cluster.local
# Address 1: 10.96.123.45 kyverno-svc.kyverno.svc.cluster.local
# real    0m0.005s
# Connection to kyverno-svc.kyverno.svc.cluster.local 443 port [tcp/https] succeeded!
# real    0m0.023s

# 危险信号：
# ;; connection timed out; no servers could be reached
# real    0m15.001s
# nc: connect to kyverno-svc.kyverno.svc.cluster.local port 443 (tcp) failed: Connection timed out
# real    0m2.101s
```

### 修复

```bash
# 方案 1：增大 webhook 超时
kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  --type='json' -p='[{"op": "replace", "path": "/webhooks/0/timeoutSeconds", "value": 30}]'

# 方案 2：临时移除有问题的 webhook（紧急恢复）
kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg

# 方案 3：扩容 webhook 服务
kubectl scale deployment kyverno -n kyverno --replicas=5
kubectl wait --for=condition=ready pod -n kyverno -l app=kyverno --timeout=120s

# 方案 4：增加 webhook 资源
kubectl patch deployment kyverno -n kyverno --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "2000m"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"}
]'
```

---

## 根因 2：etcd 响应超时

### 现象

```bash
# API Server 日志
# E0115 08:30:00.345678 1 status.go:71] apiserver received an error that is not an metav1.Status: 
#   rpc error: code = DeadlineExceeded desc = context deadline exceeded
# W0115 08:30:00.456789 1 etcd.go:123] etcd: watch channel closed

# etcd 日志
kubectl logs -n kube-system etcd-<node> | grep -E "took too long|request timed out|database space"

# 输出：
# 2024-01-15 08:29:50.123456 W | etcdserver: read-only range request 
#   "key:\"/registry/pods/default/nginx-xxx\" " took too long (2.345s) to execute
# 2024-01-15 08:29:55.234567 W | etcdserver: read-only range request 
#   "key:\"/registry/deployments/\" range_end:\"/registry/deployments0\" " took too long (5.678s) to execute
# ← etcd 读请求耗时 2-5 秒！

# etcd 性能测试
kubectl exec etcd-<node> -n kube-system -- etcdctl check perf --load="l"

# 输出：
#  FAIL: Throughput is 45 writes/s (expected minimum 100 writes/s)
#  FAIL: Slowest request took 5.678s (expected maximum 0.5s)
#  FAIL: Stddev is 2.345s (expected maximum 0.1s)
#  FAIL
# ← etcd 性能严重不达标！
```

### etcd 延迟诊断

```bash
# 1. 磁盘延迟测试
kubectl exec etcd-<node> -n kube-system -- /bin/sh -c '
  echo "=== WAL 目录磁盘测试 ==="
  dd if=/dev/zero of=/var/lib/etcd/member/wal/test-write bs=4k count=1000 oflag=dsync 2>&1 | tail -1
  rm -f /var/lib/etcd/member/wal/test-write
  
  echo ""
  echo "=== 数据目录磁盘测试 ==="
  dd if=/dev/zero of=/var/lib/etcd/member/snap/test-write bs=4k count=1000 oflag=dsync 2>&1 | tail -1
  rm -f /var/lib/etcd/member/snap/test-write
'

# 预期输出（SSD）：
# 1000+0 records in
# 1000+0 records out
# 4096000 bytes (4.1 MB, 3.9 MiB) copied, 0.234567 s, 17.5 MB/s

# 危险信号（慢磁盘）：
# 4096000 bytes (4.1 MB, 3.9 MiB) copied, 12.345678 s, 332 kB/s
# ← 4MB 写入 12 秒！etcd WAL 同步会严重超时！

# 2. etcd 指标
curl -s http://<etcd-ip>:2381/metrics | grep -E "etcd_disk_wal_fsync_duration_seconds|etcd_disk_backend_commit_duration_seconds|etcd_server_slow_apply_total"

# 健康指标：
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.001"} 56789
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.01"} 123456
# etcd_disk_backend_commit_duration_seconds_bucket{le="0.001"} 67890
# etcd_disk_backend_commit_duration_seconds_bucket{le="0.01"} 123456
# etcd_server_slow_apply_total 0
# ← 99% 的操作 < 10ms，无慢操作

# 危险信号：
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.1"} 123
# etcd_disk_wal_fsync_duration_seconds_bucket{le="1.0"} 45678
# etcd_server_slow_apply_total 12345
# ← 大量 WAL fsync > 100ms，12,345 次慢 apply！
```

### 修复

```bash
# 方案 1：检查 etcd 磁盘类型
# etcd 必须使用 SSD 或 NVMe！
# 检查当前磁盘类型
lsblk -d -o NAME,ROTA,TYPE,SIZE,MODEL
# NAME ROTA TYPE   SIZE MODEL
# sda     1 disk   200G VMware Virtual S
# ← ROTA=1 表示旋转磁盘（HDD），不可用于 etcd！

# 方案 2：迁移 etcd 到 SSD
# 1. 备份 etcd
kubectl exec etcd-<node> -n kube-system -- etcdctl snapshot save /tmp/etcd-backup.db
# 2. 挂载 SSD 到 /var/lib/etcd
# 3. 恢复数据
kubectl exec etcd-<node> -n kube-system -- etcdctl snapshot restore /tmp/etcd-backup.db --data-dir /var/lib/etcd

# 方案 3：检查 etcd 数据大小
ectl endpoint status --cluster -w table
# DB SIZE > 4GB 时需要 compaction 和 defragment

# 执行 compaction
kubectl exec etcd-<leader> -n kube-system -- etcdctl compaction $(etcdctl endpoint status --write-out="json" | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)

# 执行 defragment（逐节点）
for NODE in 10.0.1.10 10.0.1.11 10.0.1.12; do
  kubectl exec etcd-$NODE -n kube-system -- etcdctl defrag --cluster
  sleep 30
done

# 方案 4：增加 API Server 到 etcd 的超时
# 在 API Server 启动参数中添加：
# --etcd-request-timeout=30  # 默认 20s
```

---

## 根因 3：API Server 自身过载

### 现象

```bash
# API Server CPU/内存使用率高
kubectl top pod -n kube-system -l component=kube-apiserver

# 输出：
# NAME                  CPU(cores)   MEMORY(bytes)
# kube-apiserver-node1  7800m        8192Mi
# ← CPU 7.8 核（如果 limit=8，接近满载）
# ← 内存 8GB（如果 limit=8GB，接近 OOM）

# API Server 指标
kubectl get --raw /metrics 2>/dev/null | grep -E "apiserver_request_duration_seconds|apiserver_current_inflight_requests"

# 输出：
# apiserver_current_inflight_requests{request_kind="mutating"} 200
# apiserver_current_inflight_requests{request_kind="readOnly"} 400
# ← 当前 200 个 mutating + 400 个 readOnly 请求正在处理

# apiserver_request_duration_seconds_bucket{verb="LIST",resource="pods",le="0.1"} 123
# apiserver_request_duration_seconds_bucket{verb="LIST",resource="pods",le="0.5"} 456
# apiserver_request_duration_seconds_bucket{verb="LIST",resource="pods",le="1.0"} 789
# apiserver_request_duration_seconds_bucket{verb="LIST",resource="pods",le="+Inf"} 12345
# → 大量 LIST Pod 请求 > 1 秒！
```

### 修复

```bash
# 方案 1：水平扩容 API Server（静态 Pod 需添加节点）
# 如果是托管 K8s（EKS/GKE/ACK），自动扩容

# 方案 2：增大并发限制
# 修改 API Server 参数：
# --max-requests-inflight=800        # 默认 400
# --max-mutating-requests-inflight=400 # 默认 200

# 方案 3：启用 API Priority and Fairness (APF)
kubectl apply -f - <<'EOF'
apiVersion: flowcontrol.apiserver.k8s.io/v1beta3
kind: PriorityLevelConfiguration
metadata:
  name: exempt-clients
spec:
  type: Exempt
---
apiVersion: flowcontrol.apiserver.k8s.io/v1beta3
kind: FlowSchema
metadata:
  name: kube-controller-manager
spec:
  priorityLevelConfiguration:
    name: exempt-clients
  rules:
  - subjects:
    - kind: User
      user:
        name: system:kube-controller-manager
EOF

# 方案 4：限制 LIST 请求（使用分页）
# 客户端侧：
# kubectl get pods --chunk-size=500  # 分页获取
# API 调用：limit=500&continue=<token>
```

---

## 根因 4：LoadBalancer 超时

### 现象

```bash
# AWS ALB 默认超时 60 秒
# 如果请求处理 > 60 秒，ALB 返回 504

# 检查 LoadBalancer 超时
# AWS ALB:
aws elbv2 describe-target-group-attributes --target-group-arn <arn>
# {
#     "Attributes": [
#         {"Key": "deregistration_delay.timeout_seconds", "Value": "300"},
#         {"Key": "stickiness.enabled", "Value": "false"},
#         {"Key": "idle_timeout.timeout_seconds", "Value": "60"},   ← 60 秒空闲超时
#         {"Key": "connection_logs.s3.enabled", "Value": "false"}
#     ]
# }
```

### 修复

```bash
# 方案 1：增大 LoadBalancer 超时
# AWS ALB:
aws elbv2 modify-target-group-attributes \
  --target-group-arn <arn> \
  --attributes Key=idle_timeout.timeout_seconds,Value=300

# 方案 2：减少 API Server 处理时间
# --request-timeout=1m0s  # 默认 1 分钟

# 方案 3：使用长连接 + 流式响应（watch）替代轮询
```

---

## 根因 5：Client 侧超时

### 现象

```bash
# kubectl 命令超时
kubectl get pods --all-namespaces
# Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)
# ← Client 端 32 秒超时

# 检查 kubeconfig
cat ~/.kube/config | grep -A 5 "server"
# server: https://<lb-address>:6443

# 测试连接
export KUBECONFIG=~/.kube/config
time curl -k --cert <cert> --key <key> https://<lb-address>:6443/healthz
# real    0m0.234s
# ← 直接连接 API Server 很快，问题不在 API Server

time curl -k --cert <cert> --key <key> https://<lb-address>:6443/api/v1/pods
# real    0m45.678s
# ← LIST 所有 Pod 需要 45 秒，超过 kubectl 默认 32 秒超时！
```

### 修复

```bash
# 方案 1：增加 kubectl 超时
kubectl get pods --all-namespaces --request-timeout=120s

# 方案 2：使用分页
kubectl get pods --all-namespaces --chunk-size=500

# 方案 3：增加 Client 超时配置
export KUBECONFIG=~/.kube/config
kubectl config set-cluster <cluster> --insecure-skip-tls-verify=true
# 或者在 kubeconfig 中设置:
# clusters:
# - cluster:
#     server: https://...
#     certificate-authority-data: ...
#   name: my-cluster
```

---

## 一键诊断脚本

```bash
#!/bin/bash
# diagnose-apiserver-502-504.sh

echo "=========================================="
echo "  API Server 502/504 诊断"
echo "  时间: $(date)"
echo "=========================================="

echo ""
echo "=== 1. API Server 状态 ==="
kubectl get pods -n kube-system -l component=kube-apiserver -o wide
kubectl top pod -n kube-system -l component=kube-apiserver 2>/dev/null || echo "metrics-server 不可用"

echo ""
echo "=== 2. API Server 日志（最近错误）==="
kubectl logs -n kube-system -l component=kube-apiserver --tail=30 2>/dev/null | grep -E "502|504|timeout|error|webhook" | tail -10

echo ""
echo "=== 3. etcd 状态 ==="
kubectl get pods -n kube-system -l component=etcd -o wide
kubectl top pod -n kube-system -l component=etcd 2>/dev/null || echo "metrics-server 不可用"

echo ""
echo "=== 4. etcd 性能指标 ==="
for pod in $(kubectl get pods -n kube-system -l component=etcd -o name); do
  echo "--- $pod ---"
  kubectl exec $pod -n kube-system -- sh -c '
    echo "DB Size: $(du -sh /var/lib/etcd/member/snap/db 2>/dev/null | cut -f1)"
    echo "WAL Size: $(du -sh /var/lib/etcd/member/wal 2>/dev/null | cut -f1)"
  ' 2>/dev/null
done

echo ""
echo "=== 5. Webhook 配置 ==="
kubectl get validatingwebhookconfiguration --no-headers 2>/dev/null | while read name rest; do
  echo "--- ValidatingWebhook: $name ---"
  kubectl get validatingwebhookconfiguration $name -o jsonpath='{range .webhooks[0]}{.name}{"\n"}timeout: {.timeoutSeconds}{"\n"}failurePolicy: {.failurePolicy}{"\n"}{end}' 2>/dev/null
done

kubectl get mutatingwebhookconfiguration --no-headers 2>/dev/null | while read name rest; do
  echo "--- MutatingWebhook: $name ---"
  kubectl get mutatingwebhookconfiguration $name -o jsonpath='{range .webhooks[0]}{.name}{"\n"}timeout: {.timeoutSeconds}{"\n"}failurePolicy: {.failurePolicy}{"\n"}{end}' 2>/dev/null
done

echo ""
echo "=== 6. API Server 请求延迟 ==="
kubectl get --raw /metrics 2>/dev/null | grep -E "apiserver_request_duration_seconds_sum|apiserver_request_duration_seconds_count" | grep -E "pods|nodes" | head -6

echo ""
echo "=== 7. 错误统计 ==="
kubectl get --raw /metrics 2>/dev/null | grep -E "apiserver_request_total.*code=\"50[24]\"" | head -10

echo ""
echo "=== 8. 连接测试 ==="
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "API Server: $API_SERVER"
time curl -sk -o /dev/null -w "%{http_code}" "$API_SERVER/healthz" 2>/dev/null | xargs echo "Healthz:"
time curl -sk -o /dev/null -w "%{http_code}" "$API_SERVER/readyz" 2>/dev/null | xargs echo "Readyz:"
time curl -sk -o /dev/null -w "%{http_code}" "$API_SERVER/livez" 2>/dev/null | xargs echo "Livez:"

echo ""
echo "=========================================="
echo "  诊断完成"
echo "=========================================="
```

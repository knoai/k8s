# 生产排障：Service Mesh 延迟排查

> Service Mesh（Istio/Linkerd）引入 Sidecar 后，延迟增加 1-5ms 属正常。
> 但当延迟增加 50ms+ 时，需要系统排查 Envoy 配置、连接池、mTLS、过滤器链等。

---

## Service Mesh 延迟来源

```
请求链路（含 Sidecar）：

Client App
    │
    ├─ [本地] iptables/nftables REDIRECT/TPROXY (0.01-0.1ms)
    │
    ▼
Envoy Sidecar (Outbound Listener)
    │
    ├─ [过滤器] TcpProxy / HTTP Connection Manager (0.01ms)
    ├─ [路由] VirtualHost 匹配 → Cluster 选择 (0.01ms)
    ├─ [负载均衡] EDS endpoint 选择 (0.01ms)
    ├─ [连接池] 获取/创建连接 (0.1-5ms)
    │
    ├─ [mTLS] TLS 握手（新连接时）
    │   - 无 mTLS: 0ms
    │   - mTLS (SDS): 0.5-2ms
    │   - mTLS (文件挂载): 1-3ms
    │
    ├─ [过滤器] HTTP 路由、限流、认证 (0.1-1ms)
    │
    ▼
目标 Pod
    │
    ├─ [网络] 跨节点网络 (同 AZ 0.5ms / 跨 AZ 2-5ms)
    │
    ▼
目标 Envoy Sidecar (Inbound Listener)
    │
    ├─ [TLS] mTLS 终止 (0.1ms)
    ├─ [鉴权] RBAC / JWT 验证 (0.1-2ms)
    ├─ [指标] 请求统计 (0.01ms)
    │
    ▼
Server App

正常延迟增加：1-3ms（已建立连接，无 mTLS）
异常延迟增加：50ms+（连接池耗尽、TLS 握手频繁、过滤器阻塞）
```

---

## 诊断工具链

### istioctl 诊断

```bash
# ==================== 代理配置检查 ====================

# 1. 查看 Sidecar 配置摘要
istioctl proxy-config cluster <pod> -n <namespace>

# 预期输出（健康）：
# SERVICE FQDN                                    PORT     SUBSET     DIRECTION     TYPE           DESTINATION RULE
# BlackHoleCluster                                -        -          -             STATIC
# InboundPassthroughClusterIpv4                   -        -          -             ORIGINAL_DST
# PassthroughCluster                              -        -          -             ORIGINAL_DST
# agent                                           -        -          -             STATIC
# my-service.production.svc.cluster.local         8080     -          outbound      EDS
# my-service.production.svc.cluster.local         8080     v1         outbound      EDS            my-service-dr
# my-service.production.svc.cluster.local         8080     v2         outbound      EDS            my-service-dr
# prometheus_stats                                -        -          -             STATIC
# xds-grpc                                        -        -          -             STATIC
# zipkin                                          -        -          -             STRICT_DNS

# 危险信号：
# - BlackHoleCluster 有大量流量 → 路由匹配失败，请求被黑洞
# - 出现 PassthroughCluster 流量 → mTLS 严格模式下的明文请求

# 2. 查看 Listener 配置
istioctl proxy-config listener <pod> -n <namespace> --port 8080

# 预期输出：
# ADDRESS PORT  MATCH                                DESTINATION
# 0.0.0.0 8080  Route: my-service_8080               Route: my-service_8080

# 3. 查看路由配置
istioctl proxy-config route <pod> -n <namespace> --name 8080 -o json | jq '.[0].virtualHosts[0].routes[0]'

# 预期输出：
# {
#   "name": "default",
#   "match": { "prefix": "/" },
#   "route": {
#     "cluster": "outbound|8080||my-service.production.svc.cluster.local",
#     "timeout": "10s",
#     "retryPolicy": {
#       "retryOn": "gateway-error,connect-failure,refused-stream",
#       "numRetries": 2,
#       "perTryTimeout": "10s"
#     }
#   }
# }

# 危险信号：
# "timeout": "0s" → 无超时，可能导致连接悬挂
# "numRetries": 10 → 重试过多，级联故障放大

# 4. 查看 Endpoint 状态
istioctl proxy-config endpoint <pod> -n <namespace> --cluster "outbound|8080||my-service.production.svc.cluster.local"

# 预期输出（健康）：
# ENDPOINT             STATUS      OUTLIER CHECK     CLUSTER
# 10.244.1.5:8080      HEALTHY     OK                outbound|8080||my-service.production.svc.cluster.local
# 10.244.1.6:8080      HEALTHY     OK                outbound|8080||my-service.production.svc.cluster.local
# 10.244.1.7:8080      HEALTHY     OK                outbound|8080||my-service.production.svc.cluster.local

# 危险信号：
# 10.244.1.5:8080      UNHEALTHY   FAILED            ...
# ← 健康检查失败，但仍有流量发送（Ejection 未生效）

# ==================== 连接池状态 ====================

# 5. 查看连接池统计
istioctl proxy-config cluster <pod> -n <namespace> --fqdn my-service.production.svc.cluster.local -o json | jq '.[0].circuitBreakers'

# 输出：
# {
#   "thresholds": [
#     {
#       "maxConnections": 1024,         # 最大连接数
#       "maxPendingRequests": 1024,     # 最大挂起请求
#       "maxRequests": 1024,            # 最大并发请求
#       "maxRetries": 3                 # 最大重试数
#     }
#   ]
# }

# 6. 查看统计信息（最关键！）
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15090/stats/prometheus | grep -E "cluster|upstream|downstream" | head -50

# 关键指标：
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_rq_total: 1234567
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_rq_time: P0(nan,0) P25(nan,1.234) P50(nan,2.345) P75(nan,4.567) P90(nan,8.901) P95(nan,12.345) P99(nan,23.456) P99.5(nan,34.567) P99.9(nan,56.789) P100(nan,123.456)
# ← P99 延迟 23.456ms（健康）

# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_cx_active: 45
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_cx_total: 12345
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_cx_connect_ms: P0(nan,0.5) P50(nan,1.2) P99(nan,5.6)
# ← 连接建立时间 P99 5.6ms（正常）

# 危险信号：
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_rq_pending_overflow: 12345
# ← 连接池溢出！请求被丢弃！
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_cx_connect_timeout: 567
# ← 567 次连接超时！
# cluster.outbound|8080||my-service.production.svc.cluster.local.upstream_rq_time: ... P99(nan,567.890)
# ← P99 延迟 567ms！严重异常！
```

### Envoy 日志分析

```bash
# 开启 Envoy 访问日志
# 在 Pod 级别：
kubectl annotate pod <pod> -n <namespace> sidecar.istio.io/logLevel=debug

# 或者全局开启访问日志
cat > access-log.yaml <<EOF
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  accessLogging:
  - providers:
    - name: envoy
    filter:
      expression: "response.code >= 500"
EOF

# 查看 Envoy 访问日志
kubectl logs <pod> -c istio-proxy | grep "my-service"

# 预期输出（健康）：
# [2024-01-15T08:30:00.123Z] "GET /api/data HTTP/1.1" 200 - via_upstream 
#   - "-" 0 1234 2 1 "-" "curl/7.68.0" 
#   "abc123-def456" "my-service.production.svc.cluster.local:8080" 
#   "10.244.1.5:8080" outbound|8080||my-service.production.svc.cluster.local 
#   10.244.0.5:54321 10.96.0.10:8080 10.244.0.5 - default
# 
# 字段解读：
# [timestamp] "method path protocol" status - response_flags 
#   "-" bytes_received bytes_sent duration_ms upstream_duration_ms 
#   "-" "user-agent" "request_id" "authority" "upstream_host" 
#   cluster source_ip destination_ip source_port - route_name
# 
# 关键延迟字段：
# - duration_ms = 2: 总延迟 2ms
# - upstream_duration_ms = 1: 后端处理 1ms
# - Sidecar 开销 = 2 - 1 = 1ms（正常）

# 危险信号：
# [2024-01-15T08:30:00.123Z] "GET /api/data HTTP/1.1" 503 UH 
#   - "-" 0 19 0 0 "-" "curl/7.68.0" 
#   "abc123" "my-service.production.svc.cluster.local:8080" 
#   "-" outbound|8080||my-service.production.svc.cluster.local 
#   10.244.0.5:54321 10.96.0.10:8080 10.244.0.5 - default
# 
# response_flags = UH (Upstream connection failure)
# upstream_duration_ms = 0
# duration_ms = 0
# → 连接池耗尽，无法建立上游连接！
```

---

## 根因 1：mTLS TLS 握手延迟

### 现象

```bash
# 症状：
# - 新连接延迟高（50-200ms）
# - 已建立连接的请求延迟正常
# - 高并发时延迟飙升

# 诊断
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15090/stats/prometheus | grep -E "ssl|tls"

# 输出：
# listener.0.0.0.0_8080.ssl.handshake: 12345
# listener.0.0.0.0_8080.ssl.handshake_ms: P0(nan,50) P50(nan,80) P99(nan,200)
# ← TLS 握手 P99 200ms！

# cluster.outbound|8080||my-service...upstream_cx_total: 50000
# cluster.outbound|8080||my-service...upstream_cx_active: 10
# ← 创建了 50000 个连接，但只有 10 个活跃 → 连接频繁创建销毁！
```

### 根因分析

```
mTLS 握手延迟来源：
  1. 证书验证：
     - 验证对端证书链
     - 检查 CRL/OCSP（如果有）
     - 默认耗时：1-5ms
  
  2. SDS (Secret Discovery Service)：
     - Envoy 动态获取证书
     - 首次连接时需要从 istiod 获取
     - 缓存命中时：0ms
     - 缓存未命中时：50-200ms
  
  3. 证书格式：
     - RSA 2048：较快
     - RSA 4096：慢 4-8 倍
     - ECDSA P-256：推荐（更快）
```

### 修复

```yaml
# 方案 1：启用连接保持（HTTP Keep-Alive）
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-service-dr
spec:
  host: my-service.production.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 30ms
        tcpKeepalive:
          time: 300s          # 5 分钟发送一次 keepalive
          interval: 75s
      http:
        h2UpgradePolicy: UPGRADE       # HTTP/2 复用连接
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000         # HTTP/2 每连接最大请求

# 方案 2：使用 ECDSA 证书（替代 RSA）
# 在 PeerAuthentication 中：
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
# 证书生成时使用 ECDSA：
# istioctl proxy-config secret <pod> -o json | jq '.dynamicActiveSecrets[] | select(.name=="default")'

# 方案 3：开启 Connection Pool 预热
trafficPolicy:
  connectionPool:
    tcp:
      maxConnections: 100
    http:
      http1MaxPendingRequests: 100
      http2MaxRequests: 1000
  loadBalancer:
    simple: LEAST_CONN
    warmupDurationSecs: 300    # 新 endpoint 5 分钟预热期
```

---

## 根因 2：连接池耗尽

### 现象

```bash
# Envoy 统计
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15090/stats/prometheus | grep -E "overflow|cx_active|cx_total"

# 输出：
# cluster.outbound|8080||my-service...upstream_rq_pending_overflow: 23456
# cluster.outbound|8080||my-service...upstream_rq_pending_active: 1024
# cluster.outbound|8080||my-service...upstream_cx_active: 1024
# cluster.outbound|8080||my-service...upstream_cx_total: 150000
# 
# 解读：
# - upstream_cx_active = 1024 = maxConnections（连接池满）
# - upstream_rq_pending_overflow = 23456（23456 个请求被丢弃！）
# - 总连接数 15 万（说明连接未复用）
```

### 根因

```
连接池耗尽原因：
  1. HTTP/1.1 无 Keep-Alive：
     - 每个请求新建 TCP 连接
     - 连接数 = QPS × 平均响应时间
     - QPS 1000，RT 1s → 需要 1000 连接
  
  2. 连接超时过短：
     - idleTimeout = 1s
     - 连接刚建立就被关闭
     - 下次请求需要重新建立
  
  3. Sidecar 连接池配置过小：
     - maxConnections = 10（默认值可能不足）
     - 后端实际可以处理更多
```

### 修复

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-service-dr
spec:
  host: my-service.production.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1000          # 增大连接池
        connectTimeout: 100ms
      http:
        http1MaxPendingRequests: 1000
        http2MaxRequests: 10000        # HTTP/2 大幅复用连接
        maxRequestsPerConnection: 1000 # 每连接最大请求数
        maxRetries: 3
    loadBalancer:
      simple: LEAST_CONN
      localityLbSetting:
        enabled: true
        failover:
        - from: us-east-1a
          to: us-east-1b
```

---

## 根因 3：Envoy 过滤器阻塞

### 现象

```bash
# 症状：所有请求延迟均匀增加 50ms+

# 查看过滤器统计
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15090/stats/prometheus | grep -E "ext_authz|jwt_authn|rbac"

# 输出：
# http.ext_authz.denied: 0
# http.ext_authz.disabled: 0
# http.ext_authz.error: 0
# http.ext_authz.failure_mode_allowed: 0
# http.ext_authz.ok: 123456
# http.ext_authz.duration: P0(nan,45) P50(nan,52) P99(nan,156)
# ← ext_authz（外部鉴权）P99 156ms！
```

### 修复

```yaml
# 方案 1：JWT 验证缓存
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: jwt-auth
spec:
  jwtRules:
  - issuer: "https://auth.mycompany.com"
    jwksUri: "https://auth.mycompany.com/.well-known/jwks.json"
    # 启用 JWT 缓存
    outputPayloadToHeader: x-jwt-payload
    # 或降低验证频率

# 方案 2：移除不必要的过滤器
# 检查 EnvoyFilter 配置
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: unnecessary-filter
# 删除或禁用增加延迟的自定义过滤器

# 方案 3：异步鉴权
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: async-authz
spec:
  action: ALLOW
  rules:
  - when:
    - key: request.auth.claims[scope]
      values: ["read"]
    # 简单规则避免复杂判断
```

---

## 根因 4：Sidecar CPU Throttling

### 现象

```bash
# Sidecar CPU 使用率高
kubectl top pod <pod> --containers

# 输出：
# NAME         CPU(cores)   MEMORY(bytes)
# my-app       100m         256Mi
# istio-proxy  500m         128Mi
# ← Sidecar CPU 500m，但 limit 可能就是 500m！

# 检查 throttling
kubectl exec <pod> -c istio-proxy -- cat /sys/fs/cgroup/cpu.stat | grep nr_throttled
# nr_throttled 1234567
# throttled_usec 9876543210
# ← 被 throttle 了 9876 秒！

# Envoy 延迟统计
kubectl exec <pod> -c istio-proxy -- curl -s localhost:15090/stats/prometheus | grep "server.worker"
# server.worker_0.dispatch_duration: P0(nan,0.001) P99(nan,0.050)
# server.worker_1.dispatch_duration: P0(nan,0.001) P99(nan,0.500)
# ← worker_1 调度延迟 500ms（被 throttle 影响）
```

### 修复

```yaml
# 方案 1：增加 Sidecar 资源
apiVersion: v1
kind: Pod
metadata:
  annotations:
    # Istio 1.19+ 支持
    sidecar.istio.io/proxyCPU: "1000m"
    sidecar.istio.io/proxyMemory: "256Mi"
    sidecar.istio.io/proxyLimitCPU: "2000m"
    sidecar.istio.io/proxyLimitMemory: "512Mi"

# 方案 2：全局配置（IstioOperator）
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: default
  values:
    global:
      proxy:
        resources:
          requests:
            cpu: 500m
            memory: 128Mi
          limits:
            cpu: 2000m
            memory: 256Mi

# 方案 3：使用 eBPF 替代 iptables（Istio Ambient Mesh）
# Ambient Mesh 不需要 Sidecar，延迟更低
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
```

---

## 一键诊断脚本

```bash
#!/bin/bash
# diagnose-mesh-latency.sh <pod> <namespace>

POD=${1:-}
NS=${2:-default}

if [ -z "$POD" ]; then
  echo "Usage: $0 <pod> <namespace>"
  exit 1
fi

echo "=========================================="
echo "  Service Mesh 延迟诊断"
echo "  Pod: $NS/$POD"
echo "=========================================="

echo ""
echo "=== 1. Sidecar 状态 ==="
kubectl get pod $POD -n $NS -o jsonpath='{.status.containerStatuses[?(@.name=="istio-proxy")].ready}'
echo ""

kubectl top pod $POD -n $NS --containers 2>/dev/null || echo "metrics-server 不可用"

echo ""
echo "=== 2. Envoy Cluster 状态 ==="
istioctl proxy-config cluster $POD -n $NS | head -20

echo ""
echo "=== 3. 关键延迟指标 ==="
kubectl exec $POD -n $NS -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "upstream_rq_time|upstream_cx_connect_ms" | head -10

echo ""
echo "=== 4. 连接池状态 ==="
kubectl exec $POD -n $NS -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "upstream_cx_active|upstream_cx_total|upstream_rq_pending_overflow" | head -10

echo ""
echo "=== 5. TLS 握手统计 ==="
kubectl exec $POD -n $NS -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "ssl.handshake" | head -5

echo ""
echo "=== 6. 过滤器延迟 ==="
kubectl exec $POD -n $NS -c istio-proxy -- curl -s localhost:15090/stats/prometheus 2>/dev/null | grep -E "ext_authz.duration|jwt_authn|rbac.allowed" | head -10

echo ""
echo "=== 7. CPU Throttling ==="
kubectl exec $POD -n $NS -c istio-proxy -- cat /sys/fs/cgroup/cpu.stat 2>/dev/null | grep throttled || echo "无法读取 cgroup"

echo ""
echo "=== 8. 最近 Envoy 日志 ==="
kubectl logs $POD -n $NS -c istio-proxy --tail=20 2>/dev/null | grep -E "duration|response_flags" | tail -5

echo ""
echo "=========================================="
echo "  诊断完成"
echo "=========================================="
```

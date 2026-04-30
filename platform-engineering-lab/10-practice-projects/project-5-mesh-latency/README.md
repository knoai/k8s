# 实战项目 5：Service Mesh 延迟排查

> 目标：在 Istio 环境下部署应用，模拟 mTLS 握手延迟、Sidecar 资源不足、Filter 链过长等问题并排查。
> Service Mesh 带来了强大的流量管理能力，但也引入了额外的网络跳点和计算开销。

---

## 实验架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    Istio Service Mesh 实验环境                   │
│                    (kind-mesh-lab 集群)                          │
│                                                                 │
│  ┌──────────────┐                                              │
│  │   Ingress    │                                              │
│  │   Gateway    │                                              │
│  └──────┬───────┘                                              │
│         │                                                       │
│    ┌────┴────┬────────┬────────┐                               │
│    ▼         ▼        ▼        ▼                               │
│  ┌────┐   ┌────┐  ┌────┐  ┌────┐                             │
│  │App │   │App │  │App │  │App │                             │
│  │ A  │   │ B  │  │ C  │  │ D  │                             │
│  │    │   │    │  │    │  │    │                             │
│  │无  │   │+   │  │+   │  │+   │                             │
│  │Side│   │mTLS│  │mTLS│  │mTLS│                             │
│  │car │   │STRICT│ │PERMISSIVE│ │WASM│                        │
│  └────┘   └────┘  └────┘  └────┘  +RateLimit                 │
│                                                                 │
│  监控：Prometheus + Grafana + Kiali + Jaeger                    │
│                                                                 │
│  应用调用链：App A → App B → App C → App D                       │
│  （模拟典型微服务调用链）                                         │
└─────────────────────────────────────────────────────────────────┘

基线预期延迟（无 Sidecar）：
  P50: 5ms, P99: 15ms

预期问题延迟（有 Sidecar + 问题配置）：
  P50: 50ms, P99: 500ms
  修复后应恢复至：P50: 10ms, P99: 30ms
```

---

## 前置要求

```bash
# 硬件
CPU: 8 核+
内存: 16GB+
磁盘: 40GB SSD

# 软件
docker --version     # 24.0+
kind --version       # 0.20+
kubectl version --client  # 1.28+
helm version         # 3.12+
istioctl version     # 1.20+

# 压测工具
siege --version      # 4.1+
# 或
wrk --version        # 4.2+
```

---

## 实验步骤详解

### 步骤 1：部署 Istio + 实验环境

```bash
cd platform-engineering-lab/10-practice-projects/project-5-mesh-latency

# 一键部署（约 10-15 分钟，Istio 组件较多）
bash deploy-mesh-lab.sh

# 脚本内部逻辑：
# 1. 创建 kind-mesh-lab 集群
# 2. 安装 Istio（demo profile，包含所有组件）
# 3. 启用 sidecar 自动注入
# 4. 部署 4 个应用（App A/B/C/D）
# 5. 部署 Ingress Gateway
# 6. 部署监控栈（Prometheus + Grafana + Kiali + Jaeger）

# 验证 Istio 安装
kubectl get pods -n istio-system
# NAME                                    READY   STATUS
# istiod-xxxxxxxxxx-xxxxx                 1/1     Running
# istio-ingressgateway-xxxxxxxxxx-xxxxx   1/1     Running
# istio-egressgateway-xxxxxxxxxx-xxxxx    1/1     Running
# prometheus-xxxxxxxxxx-xxxxx             1/1     Running
# grafana-xxxxxxxxxx-xxxxx                1/1     Running
# kiali-xxxxxxxxxx-xxxxx                  1/1     Running
# jaeger-xxxxxxxxxx-xxxxx                 1/1     Running

# 验证应用（带 Sidecar 的 Pod 会显示 2/2）
kubectl get pods -n mesh-lab
# NAME                   READY   STATUS
# app-a-xxxxxxxx-xxxxx   1/1     Running     <- 无 Sidecar
# app-b-xxxxxxxx-xxxxx   2/2     Running     <- 有 Sidecar
# app-c-xxxxxxxx-xxxxx   2/2     Running     <- 有 Sidecar
# app-d-xxxxxxxx-xxxxx   2/2     Running     <- 有 Sidecar
```

### 步骤 2：配置差异说明

```bash
# App A：无 Sidecar（基线）
kubectl get deployment app-a -n mesh-lab -o yaml | grep -A 2 "sidecar.istio.io/inject"
# sidecar.istio.io/inject: "false"

# App B：STRICT mTLS（问题 1 - 握手延迟）
kubectl get peerauthentication app-b -n mesh-lab -o yaml
# spec:
#   mtls:
#     mode: STRICT
# 所有入站流量必须经过 mTLS 握手

# App C：PERMISSIVE mTLS（对照组）
kubectl get peerauthentication app-c -n mesh-lab -o yaml
# spec:
#   mtls:
#     mode: PERMISSIVE
# 允许明文和 mTLS 同时存在

# App D：WASM 插件 + 限流（问题 2 - Filter 链过长）
kubectl get envoyfilter app-d-filter -n mesh-lab -o yaml
# 包含 5 个 WASM filter + rate limit filter
```

### 步骤 3：压测对比

```bash
# 获取 Ingress Gateway NodePort
INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
INGRESS_HOST=$(kubectl get po -l istio=ingressgateway -n istio-system -o jsonpath='{.items[0].status.hostIP}')

echo "Ingress: http://$INGRESS_HOST:$INGRESS_PORT"

# 压测 App A（无 Sidecar 基线）
echo "=== App A（无 Sidecar）==="
siege -c 50 -t 30s "http://$INGRESS_HOST:$INGRESS_PORT/api/a"
# 预期输出：
# Response time: 0.005 secs
# Longest transaction: 0.015 secs    <- P99 = 15ms

# 压测 App B（STRICT mTLS）
echo "=== App B（STRICT mTLS）==="
siege -c 50 -t 30s "http://$INGRESS_HOST:$INGRESS_PORT/api/b"
# 预期输出：
# Response time: 0.050 secs          <- 比 A 慢 10 倍！
# Longest transaction: 0.500 secs    <- P99 = 500ms！

# 压测 App C（PERMISSIVE mTLS）
echo "=== App C（PERMISSIVE mTLS）==="
siege -c 50 -t 30s "http://$INGRESS_HOST:$INGRESS_PORT/api/c"
# 预期输出：
# Response time: 0.020 secs
# Longest transaction: 0.080 secs    <- 比 STRICT 好很多

# 压测 App D（WASM + RateLimit）
echo "=== App D（WASM + RateLimit）==="
siege -c 50 -t 30s "http://$INGRESS_HOST:$INGRESS_PORT/api/d"
# 预期输出：
# Response time: 0.120 secs          <- 最慢！
# Longest transaction: 1.200 secs    <- P99 = 1200ms！
```

### 步骤 4：Envoy Sidecar 诊断

```bash
# 诊断脚本
./diagnose-mesh.sh app-b

# 脚本内部执行：

# 1. 进入 Sidecar（Envoy）admin 接口
ENVOY_ADMIN_PORT=15000
kubectl exec -it deploy/app-b -n mesh-lab -c istio-proxy -- curl -s localhost:$ENVOY_ADMIN_PORT/server_info | jq .
# {
#   "version": "1.20.0",
#   "state": "LIVE",
#   "hot_restart_version": "11.104",
#   "command_line_options": {
#     "concurrency": 2,     <- 工作线程数
#     ...
#   }
# }

# 2. 查看集群配置
kubectl exec -it deploy/app-b -n mesh-lab -c istio-proxy -- curl -s localhost:$ENVOY_ADMIN_PORT/clusters | grep "app-c"
# outbound|80||app-c.mesh-lab.svc.cluster.local::10.96.123.45:8080::cx_active::50
# outbound|80||app-c.mesh-lab.svc.cluster.local::10.96.123.45:8080::cx_connect_fail::0
# outbound|80||app-c.mesh-lab.svc.cluster.local::10.96.123.45:8080::rq_active::10
# outbound|80||app-c.mesh-lab.svc.cluster.local::10.96.123.45:8080::rq_error::0
# outbound|80||app-c.mesh-lab.svc.cluster.local::10.96.123.45:8080::rq_success::12345
# outbound|80||app-c.mesh-lab.svc.cluster.local::10.96.123.45:8080::rq_time_ms::P50=5,P90=15,P99=45

# 3. 查看 Listener 配置
kubectl exec -it deploy/app-b -n mesh-lab -c istio-proxy -- curl -s localhost:$ENVOY_ADMIN_PORT/listeners | jq .
# [
#   {
#     "name": "0.0.0.0_8080",
#     "address": {"socket_address": {"address": "0.0.0.0", "port_value": 8080}},
#     "filter_chains": [
#       {
#         "tls_context": {"...": "mTLS 配置"},
#         "filters": [
#           {"name": "envoy.filters.network.http_connection_manager", ...}
#         ]
#       }
#     ]
#   }
# ]

# 4. 查看 mTLS 握手统计
kubectl exec -it deploy/app-b -n mesh-lab -c istio-proxy -- curl -s localhost:$ENVOY_ADMIN_PORT/stats/prometheus | grep tls
# istio_requests_total{reporter="source",source_workload="app-b",destination_workload="app-c",connection_security_policy="mutual_tls"} 12345
# 确认使用了 mTLS

# 5. 查看 WASM filter 统计（App D）
kubectl exec -it deploy/app-d -n mesh-lab -c istio-proxy -- curl -s localhost:$ENVOY_ADMIN_PORT/stats/prometheus | grep wasm
# wasm_vm_null_created: 5
# wasm_vm_null_active: 5
# wasm_filter_chains: 5
# 每个请求经过 5 个 WASM filter！
```

### 步骤 5：mTLS 握手延迟分析

```bash
# 方法 1：使用 istioctl authn 检查认证策略
istioctl authn tls-check deploy/app-b -n mesh-lab
# HOST:PORT                                         STATUS     SERVER     CLIENT     AUTHN POLICY
# app-b.mesh-lab.svc.cluster.local:8080             OK         STRICT     mTLS       app-b/mesh-lab
# app-c.mesh-lab.svc.cluster.local:8080             OK         PERMISSIVE mTLS       default/
# 确认 App B 使用 STRICT mTLS

# 方法 2：使用 openssl 测试握手时间
kubectl exec -it deploy/app-a -n mesh-lab -- \
  openssl s_client -connect app-b.mesh-lab.svc.cluster.local:8080 \
  -CAfile /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -cert /var/run/secrets/istio.io/app-a-cert-chain.pem \
  -key /var/run/secrets/istio.io/app-a-key.pem

# 观察握手耗时（实际通过 Envoy 的 stats）
kubectl exec -it deploy/app-b -n mesh-lab -c istio-proxy -- curl -s localhost:15090/stats/prometheus | grep ssl
# ssl.handshake: 2345          <- 累计握手次数
# ssl.handshake_time_ms: P50=5,P90=15,P99=45  <- 握手耗时！

# mTLS 握手延迟分解：
# 1. TCP 三次握手: ~1ms
# 2. TLS 1.3 握手: ~5-10ms (1-RTT)
# 3. 证书验证: ~1-2ms
# 总计: ~8-15ms/次
# 在长连接复用场景下，握手只发生在连接建立时
# 但如果连接池频繁重建，累积延迟很大
```

### 步骤 6：Filter 链性能分析

```bash
# 查看 App D 的 Envoy filter 链
kubectl exec -it deploy/app-d -n mesh-lab -c istio-proxy -- curl -s localhost:15000/config_dump | jq '.configs[] | select(.["@type"]=="type.googleapis.com/envoy.admin.v3.ListenersConfigDump") | .dynamic_listeners[0].active_state.listener.filter_chains[0].filters'

# 预期输出（简化）：
# [
#   {"name": "envoy.filters.network.http_connection_manager", ...},
#   {"name": "envoy.filters.http.wasm", config: {plugin: "auth-check"}},
#   {"name": "envoy.filters.http.wasm", config: {plugin: "rate-limit"}},
#   {"name": "envoy.filters.http.wasm", config: {plugin: "transform"}},
#   {"name": "envoy.filters.http.wasm", config: {plugin: "audit-log"}},
#   {"name": "envoy.filters.http.wasm", config: {plugin: "metrics"}},
#   {"name": "envoy.filters.http.router", ...}
# ]
# 共 6 个 filter（5 个 WASM + 1 个 router）

# 每个 WASM filter 的开销：
# - 上下文切换：~0.1ms
# - 内存拷贝：~0.05ms
# - WASM 执行时间：取决于逻辑（通常 0.1-1ms）
# 总计：5 个 filter × ~0.5ms = ~2.5ms/请求
# 但如果 filter 逻辑复杂（如访问外部服务），可能 10ms+
```

### 步骤 7：使用 Kiali 和 Jaeger 可视化

```bash
# 暴露 Kiali 端口
kubectl port-forward svc/kiali -n istio-system 20001:20001 &
# 浏览器访问 http://localhost:20001/kiali

# 在 Kiali 中可以观察到：
# 1. 服务拓扑图：显示 App A → B → C → D 的调用链
# 2. 流量指标：每个边的延迟、错误率、吞吐量
# 3. 安全状态：哪些连接使用了 mTLS

# 暴露 Jaeger 端口
kubectl port-forward svc/tracing -n istio-system 16686:16686 &
# 浏览器访问 http://localhost:16686

# 在 Jaeger 中可以观察到：
# 1. 端到端调用链延迟
# 2. 每个 span 的耗时
# 3. Sidecar 引入的额外延迟

# 典型 Trace（App B STRICT mTLS）：
# ─── ingressgateway (5ms)
#     └── app-b.sidecar (15ms)       <- Sidecar 处理
#         └── app-b.app (10ms)        <- 实际业务处理
#             └── app-c.sidecar (12ms) <- 出站 mTLS
#                 └── app-c.app (8ms)
# 总计：50ms（Sidecar 开销占 60%）
```

### 步骤 8：修复与优化

#### 修复 1：调整 mTLS 模式

```bash
# 将 App B 从 STRICT 改为 PERMISSIVE（如果安全要求允许）
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: app-b
  namespace: mesh-lab
spec:
  selector:
    matchLabels:
      app: app-b
  mtls:
    mode: PERMISSIVE
EOF

# 或者：在内部服务间使用 PERMISSIVE，仅在 Ingress 使用 STRICT
# 最佳实践：东西向流量使用 PERMISSIVE，南北向使用 STRICT
```

#### 修复 2：优化连接池

```bash
# 配置 Envoy 连接池参数
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: app-b-connection-pool
  namespace: mesh-lab
spec:
  host: app-b.mesh-lab.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 30ms
      http:
        h2UpgradePolicy: DO_NOT_UPGRADE
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000
        maxRequestsPerConnection: 1000
        maxRetries: 3
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
EOF
```

#### 修复 3：移除不必要的 WASM Filter

```bash
# 删除多余的 EnvoyFilter
kubectl delete envoyfilter app-d-filter -n mesh-lab

# 或只保留必要的 filter
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: app-d-minimal
  namespace: mesh-lab
spec:
  workloadSelector:
    labels:
      app: app-d
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.wasm
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
          config:
            name: rate-limit
            root_id: rate-limit
            vm_config:
              runtime: envoy.wasm.runtime.v8
              code:
                remote:
                  http_uri:
                    uri: http://wasm-repo/rate-limit.wasm
EOF
```

#### 修复 4：Sidecar 资源调优

```bash
# 给 Sidecar 分配更多资源
kubectl patch deployment app-b -n mesh-lab --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/1/resources", "value": {
    "limits": {"cpu": "500m", "memory": "256Mi"},
    "requests": {"cpu": "100m", "memory": "128Mi"}
  }}
]'
# 注意：istio-proxy 是第二个容器（index 1）
```

### 步骤 9：验证修复

```bash
# 重新压测
echo "=== App B 修复后（PERMISSIVE mTLS）==="
siege -c 50 -t 30s "http://$INGRESS_HOST:$INGRESS_PORT/api/b"
# Response time: 0.010 secs       <- 从 50ms 降到 10ms
# Longest transaction: 0.040 secs  <- P99 从 500ms 降到 40ms

echo "=== App D 修复后（移除 WASM）==="
siege -c 50 -t 30s "http://$INGRESS_HOST:$INGRESS_PORT/api/d"
# Response time: 0.015 secs       <- 从 120ms 降到 15ms
# Longest transaction: 0.050 secs  <- P99 从 1200ms 降到 50ms

# 对比总结
echo "=== 修复前后对比 ==="
printf "%-25s %-15s %-15s %-15s\n" "应用" "修复前 P99" "修复后 P99" "改善"
printf "%-25s %-15s %-15s %-15s\n" "App B (STRICT mTLS)" "500ms" "40ms" "12.5x"
printf "%-25s %-15s %-15s %-15s\n" "App D (WASM)" "1200ms" "50ms" "24x"
```

---

## 排障决策树

```
Service Mesh 延迟问题
    │
    ├── 无 Sidecar 的基线是否正常？
    │       ├── 否 → 应用本身有问题，先排查应用
    │       └── 是 → Sidecar 引入的延迟
    │
    ├── 延迟是单次高还是持续高？
    │       ├── 单次高 → 可能是 mTLS 握手（连接重建）
    │       │       ├── 检查连接池配置（maxRequestsPerConnection）
    │       │       ├── 检查连接超时时间
    │       │       └── 优化：增大连接复用
    │       └── 持续高 → 每个请求都有额外开销
    │               ├── 检查 filter 链长度
    │               ├── 检查 WASM filter 执行时间
    │               └── 检查 Sidecar CPU/内存是否充足
    │
    ├── 使用 Jaeger 查看 trace 分解
    │       ├── Sidecar inbound 延迟高？
    │       │       ├── 检查 mTLS 模式
    │       │       ├── 检查鉴权 filter
    │       │       └── 检查限流配置
    │       ├── Sidecar outbound 延迟高？
    │       │       ├── 检查 upstream 连接池
    │       │       ├── 检查负载均衡策略
    │       │       └── 检查重试/超时配置
    │       └── 应用本身延迟高？
    │               → 排查应用性能
    │
    └── 使用 Envoy stats 定位
            ├── ssl.handshake_time_ms 高？ → mTLS 优化
            ├── wasm 相关指标高？ → 减少/优化 WASM filter
            └── upstream_rq_time 高？ → 后端服务问题
```

---

## 评分标准

```
基础要求（40 分）：
  □ 成功部署 Istio + 实验环境（15 分）
  □ 成功部署 4 个应用并验证 Sidecar 注入（10 分）
  □ 完成 4 组压测并记录基线（10 分）
  □ 运行诊断脚本收集数据（5 分）

进阶要求（40 分）：
  □ 定位 STRICT mTLS 握手延迟（10 分）
  □ 定位 WASM filter 链开销（10 分）
  □ 使用 Kiali 分析服务拓扑（10 分）
  □ 使用 Jaeger 分析调用链延迟（10 分）

挑战要求（20 分）：
  □ 修复后 App B P99 < 50ms（10 分）
  □ 修复后 App D P99 < 100ms（10 分）

优秀加分（额外）：
  □ 编写 Istio 性能基线检查脚本（+5 分）
  □ 配置自定义 EnvoyFilter 并测试性能影响（+5 分）
```

---

## 面试核心考点

```
Q: "Service Mesh 的 Sidecar 模式有什么性能开销？"

A:
   1. 网络跳点：每个请求多 2 次网络跳转（inbound + outbound）
   2. mTLS 握手：首次连接增加 5-15ms（TLS 1.3）
   3. Filter 链执行：每个请求经过多个 L7 filter
   4. 资源消耗：Sidecar 占用额外 CPU（~0.1 vCPU/1000 RPS）和内存（~50MB）
   5. 延迟数据（实测）：
      - 无 Sidecar: P99 = 15ms
      - 有 Sidecar + mTLS: P99 = 30-50ms
      - 有 Sidecar + WASM: P99 = 50-200ms（取决于 filter）
   6. 优化方案：
      - 使用 eBPF 加速（Cilium Service Mesh）
      - 使用 Ambient Mesh（Sidecar-less）
      - 连接池优化，减少握手频率
      - 精简 filter 链

Q: "Istio 的 STRICT mTLS 和 PERMISSIVE 模式有什么区别？"

A:
   STRICT：
   - 所有入站流量必须使用 mTLS
   - 明文请求会被拒绝
   - 安全性最高，但兼容性差（老旧客户端可能不支持）
   
   PERMISSIVE：
   - 同时接受 mTLS 和明文流量
   - 兼容性好，适合渐进式迁移
   - 安全性较低，明文流量存在风险
   
   推荐策略：
   - 东西向流量：PERMISSIVE（内部服务可控）
   - 南北向流量：STRICT（外部不可信）
   - 逐步迁移：先 PERMISSIVE，验证后再 STRICT
```

---

## 常见问题

```
Q: Istio 安装失败？
A: 确保有足够资源（Istio 需要 2GB+ 内存）。
   kind 集群需要足够的节点资源，可以调整 kind 配置。

Q: Sidecar 未自动注入？
A: 检查命名空间是否有 istio-injection=enabled 标签：
   kubectl get namespace mesh-lab -o yaml | grep istio-injection

Q: Kiali 看不到服务图？
A: 检查 Prometheus 是否正确采集了 Envoy 指标。
   查看 istio-proxy 的 15090 端口是否正常暴露。
```

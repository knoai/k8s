# 性能基准：API Server 调优参数完全手册

> Kubernetes API Server 是整个集群的控制平面入口。
> 在 1000-10000 节点的大规模集群中，一个参数配置不当就可能导致全集群级别的延迟飙升或请求拒绝。
> 本章基于生产环境 5000 节点集群的实测数据和故障案例，提供每个参数的完整调优指南。

---

## 第一章：API Server 架构与性能瓶颈

### 1.1 请求处理流程

```
用户请求 → API Server → Authentication → Authorization → Admission Control → 
  ├─ 读请求（GET/LIST/WATCH）→ 优先队列 → 缓存查询 / etcd 查询 → 响应
  └─ 写请求（CREATE/UPDATE/DELETE）→ 变更队列 → etcd 事务 → 响应

关键瓶颈点：
  1. Authentication：每个请求都要验证 Token，高并发时 JWT 验证成为瓶颈
  2. Admission Webhook：Kyverno/OPA 等 Webhook 增加 50-500ms 延迟
  3. etcd 写：所有写操作都要经过 Raft 共识，是天然瓶颈
  4. Watch 连接：每个控制器维持一个 Watch 连接，大集群连接数 > 10000
  5. 序列化/反序列化：大 List 请求（如 --all-namespaces）消耗大量 CPU
```

### 1.2 生产故障案例：max-requests-inflight 过低导致全集群雪崩

```
故障时间线：
  2024-03-15 14:00 - 业务高峰，Pod 数量从 5000 增长到 8000
  14:05 - 多个控制器（Deployment、ReplicaSet、HPA）同时 List Pod
  14:10 - API Server 开始返回 429 Too Many Requests
  14:15 - Kubelet 探针失败，Pod 被标记为 NotReady
  14:20 - Service 移除 NotReady Pod 端点，业务流量下降
  14:25 - HPA 检测到流量下降，开始缩容
  14:30 - 缩容释放资源，控制器再次创建 Pod
  14:35 - 循环重复，全集群振荡

根因：
  max-requests-inflight = 400（默认值）
  1000 节点集群的典型并发：
    - Kubelet 探针：1000 节点 × 30 Pod/节点 × 每 10 秒 1 次 = 3000 QPS
    - 控制器 List：10 控制器 × 每 30 秒全量 List = ~500 QPS
    - 开发者 kubectl：100 人 × 10 并发 = 1000 QPS
    总计：~4500 QPS，远超 400 限制

解决方案：
  max-requests-inflight = 800（1000 节点）
  max-mutating-requests-inflight = 400
```

---

## 第二章：核心参数详解

### 2.1 并发控制参数

#### `--max-requests-inflight`（并发读上限）

```
作用：限制同时处理的非变更请求（GET/LIST/WATCH）数量。

原理：
  API Server 内部维护一个计数器：
  - 新请求到达 → 计数器 +1
  - 请求完成 → 计数器 -1
  - 计数器 >= max-requests-inflight → 返回 429

默认值：400

推荐值计算：
  max-requests-inflight = (节点数 × 0.5) + (控制器数量 × 50) + (开发者并发 × 10) + 余量(30%)
  
  # 1000 节点示例
  = 1000 × 0.5 + 20 × 50 + 50 × 10
  = 500 + 1000 + 500
  = 2000
  # 加 30% 余量 → 2600，但受内存限制，通常设 800-1600
  
  # 5000 节点示例
  = 5000 × 0.5 + 50 × 50 + 100 × 10
  = 2500 + 2500 + 1000
  = 6000
  # 加 30% 余量 → 7800，实际设 3200-4000

实际推荐配置：
  ┌─────────────┬────────────────┬────────────────┬────────────────┐
  │ 集群规模     │ 读并发上限      │ 写并发上限      │ 内存需求       │
  ├─────────────┼────────────────┼────────────────┼────────────────┤
  │ 100 节点    │ 400            │ 200            │ 4GB            │
  │ 500 节点    │ 600            │ 300            │ 8GB            │
  │ 1000 节点   │ 800-1200       │ 400-600        │ 8-16GB         │
  │ 3000 节点   │ 1600-2400      │ 800-1200       │ 16-32GB        │
  │ 5000 节点   │ 2400-3200      │ 1200-1600      │ 32-64GB        │
  │ 10000 节点  │ 3200-5000      │ 1600-2400      │ 64-128GB       │
  └─────────────┴────────────────┴────────────────┴────────────────┘

风险：
  设置过高 → API Server OOM（每个请求消耗 10KB-1MB 内存，取决于响应大小）
  设置过低 → 正常请求被 429，引发级联故障

配置方法：
  # kube-apiserver 启动参数
  --max-requests-inflight=1600
  
  # 或使用 kubeadm 配置
  apiVersion: kubeadm.k8s.io/v1beta3
  kind: ClusterConfiguration
  apiServer:
    extraArgs:
      max-requests-inflight: "1600"
      max-mutating-requests-inflight: "800"
```

#### `--max-mutating-requests-inflight`（并发写上限）

```
作用：限制同时处理的变更请求（CREATE/UPDATE/DELETE/PATCH）数量。

推荐值：读限制的 25-50%

原因：
  1. 写操作触发 etcd 事务，比读更昂贵
  2. etcd 写吞吐量有限（通常 < 1000 TPS，取决于磁盘）
  3. 写过多会导致 etcd fsync 队列堆积，延迟飙升
  
实测数据：
  - etcd 使用 NVMe 磁盘：~3000 TPS
  - etcd 使用 SSD 云盘：~1000 TPS
  - etcd 使用普通云盘：~200 TPS
  
  如果 max-mutating-requests-inflight > etcd TPS，
  请求会在 API Server 队列中堆积，最终超时。
```

### 2.2 缓存参数

#### `--default-watch-cache-size` 和 `--watch-cache-sizes`

```
作用：API Server 在内存中缓存资源对象，减少 etcd 查询。

默认值问题：
  - Pod 默认缓存 100 个对象
  - 5000 节点集群，Pod 数量 5万+ → 缓存命中率 < 5%
  - 每次 List Pod 都要查询 etcd，延迟 500ms-2s

推荐配置：
  # 1000 节点集群（Pod 数 ~3万）
  --watch-cache-sizes=node#5000,pod#50000,service#5000,endpoints#10000,configmap#10000,secret#10000
  
  # 5000 节点集群（Pod 数 ~15万）
  --watch-cache-sizes=node#10000,pod#200000,service#20000,endpoints#50000,configmap#50000,secret#50000
  
  # 10000 节点集群（Pod 数 ~30万）
  --watch-cache-sizes=node#20000,pod#500000,service#50000,endpoints#100000,configmap#100000,secret#100000

内存估算：
  每个 Pod 对象在内存中约 2-5KB（含缓存开销）
  50万 Pod × 3KB = 1.5GB
  
  每个 Node 对象约 10KB
  2万 Node × 10KB = 200MB
  
  每个 Endpoints 对象约 1-10KB（取决于后端数量）
  10万 Endpoints × 5KB = 500MB
  
  总计：~2-3GB 仅 watch cache

验证缓存命中率：
  # Prometheus 查询
  rate(apiserver_cache_list_total[5m]) / rate(apiserver_list_total[5m])
  # 目标：> 90%
```

### 2.3 超时参数

#### `--request-timeout`

```
作用：API Server 处理请求的最大时间。

默认值：1m0s（60 秒）

问题场景：
  - kubectl get pods --all-namespaces
    5000 节点集群，15万 Pod
    全量 List 需要 30-60 秒
    如果 timeout=60s，刚好在边缘，稍有波动就超时
  
  - 大规模删除：kubectl delete namespace <ns>
    Namespace 内有 1000+ Pod
    级联删除可能需要数分钟

推荐值：
  ┌─────────────┬────────────────┐
  │ 集群规模     │ request-timeout │
  ├─────────────┼────────────────┤
  │ < 500 节点  │ 1m0s           │
  │ 500-2000    │ 2m0s           │
  │ 2000-5000   │ 3m0s           │
  │ > 5000      │ 5m0s           │
  └─────────────┴────────────────┘

注意：
  超时太长 → 慢请求占用连接，影响其他请求
  超时太短 → 大 List 频繁失败，客户端重试加剧负载
  
  客户端也需要配合调整：
  export KUBE_CLIENT_TIMEOUT=300s
  export KUBE_CONFIG_TIMEOUT=300s
```

### 2.4 垃圾回收参数

#### `--concurrent-gc-syncs`

```
作用：控制垃圾回收器的并发 worker 数。

背景：
  K8s 使用 OwnerReference 实现级联删除：
  Deployment 删除 → ReplicaSet 删除 → Pod 删除
  
  大规模删除时（如删除一个包含 1000 个 Pod 的 Namespace），
  GC 队列可能堆积，导致资源残留。

默认值：20

推荐值：
  - 1000 节点：50
  - 5000 节点：100
  - 10000 节点：200

验证：
  # 删除 Namespace 后检查残留
  kubectl delete namespace test-ns
  sleep 60
  kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n test-ns
  # 应该无输出（所有资源已清理）
```

#### `--delete-collection-workers`

```
作用：并行处理 DeleteCollection 请求的 worker 数。

场景：
  kubectl delete pods --all -n <ns>
  Namespace 删除时的级联清理

默认值：1（单线程）

问题：
  删除 10000 个 Pod，单线程逐个删除 → 需要 10-30 分钟
  期间 Namespace 处于 Terminating 状态

推荐值：
  --delete-collection-workers=100

风险：
  设置过高 → etcd 写压力突增
  建议配合 etcd 的写性能逐步调大
```

### 2.5 聚合层路由参数

#### `--enable-aggregator-routing`

```
作用：允许 API Server 将扩展 API 请求直接路由到后端服务，
      不经过 API Server 本身代理。

影响：
  关闭（默认 false）：
  - 所有 Metrics Server / Custom Metrics / Aggregated API 请求
  - 都经过 API Server 代理
  - API Server CPU 和带宽双倍消耗
  
  开启（true）：
  - 客户端直接与后端 Service 通信
  - API Server 负载降低 30-50%

风险：
  - 需要客户端能直接访问后端 Service
  - 某些网络隔离场景（如 API Server 在专用子网）不适用

推荐：
  大部分生产环境应开启
  --enable-aggregator-routing=true
```

---

## 第三章：内存与 CPU 基线

### 3.1 资源需求估算

```
5000 节点集群 API Server 资源需求：

┌────────┬────────┬────────┬─────────────────────────────────────┐
│ 资源   │ 最低   │ 推荐   │ 峰值场景                            │
├────────┼────────┼────────┼─────────────────────────────────────┤
│ CPU    │ 4 core │ 8 core │ 16 core（全量 List + GC + 审计）    │
│ 内存   │ 8GB    │ 16GB   │ 32GB（watch cache 满载 + 大 List）  │
│ 磁盘   │ 100GB  │ 500GB  │ -（审计日志）                       │
│ 网络   │ 10Gbps │ 25Gbps │ 25Gbps（大规模事件流）              │
└────────┴────────┴────────┴─────────────────────────────────────┘

内存分配建议：
  - Watch Cache：40-50%
  - 请求处理：20-30%
  - 审计日志缓冲：10-20%
  - Go Runtime + GC：10-20%
```

### 3.2 Go GC 调优

```bash
# API Server 是 Go 程序，GC 频率影响延迟

# 方式 1：环境变量
export GOGC=100  # 默认值，堆增长 100% 触发 GC
export GOGC=200  # 大内存场景，降低 GC 频率（延迟降低，但内存增加）

# 方式 2：GOMEMLIMIT（Go 1.19+，推荐）
export GOMEMLIMIT=12GiB  # 软内存限制，超过后激进 GC
# 优势：避免 OOM，同时允许内存使用到接近限制

# 方式 3：API Server 启动参数
--target-ram-mb=16384  # 目标内存 16GB，自动调整 GC

# 监控 GC 影响
# Prometheus 查询：
# rate(go_gc_duration_seconds_sum[5m])
# 目标：< 5% 的总 CPU 时间
```

---

## 第四章：压测与验证

### 4.1 使用 vegeta 压测

```bash
# 安装 vegeta
brew install vegeta

# 测试 1：List Pod（最常见操作）
echo "GET https://kubernetes.default.svc/api/v1/pods?limit=500" | \
  vegeta attack -rate=100 -duration=60s | \
  vegeta report

# 预期输出（健康集群）：
# Requests      [total, rate, throughput]  6000, 100.02, 99.98
# Latencies     [min, mean, 50, 90, 95, 99, max]
#   10ms, 45ms, 40ms, 80ms, 100ms, 200ms, 2s
# Bytes In      [total, mean]              123456789, 20576.13
# Bytes Out     [total, mean]              0, 0.00
# Success       [ratio]                    99.95%
# Status Codes  [code:count]               200:5997  429:3
#
# 关键指标：
# - P99 < 500ms：健康
# - P99 > 1s：需要调优（增大 cache、增大 inflight）
# - 429 数量 > 1%：inflight 设置过低

# 测试 2：大规模 List（--all-namespaces）
echo "GET https://kubernetes.default.svc/api/v1/pods" | \
  vegeta attack -rate=10 -duration=60s | \
  vegeta report

# 测试 3：并发写（创建 Pod）
cat > create-pod.json <<'EOF'
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": { "name": "test-{{_uuid}}", "namespace": "default" },
  "spec": {
    "containers": [{ "name": "test", "image": "nginx:alpine" }]
  }
}
EOF
vegeta attack -rate=50 -duration=60s -targets=<(echo "POST https://kubernetes.default.svc/api/v1/namespaces/default/pods") \
  -body create-pod.json | vegeta report
```

### 4.2 关键监控指标

```yaml
# Prometheus 监控规则
apiVersion: v1
kind: ConfigMap
metadata:
  name: apiserver-alerts
  namespace: monitoring
data:
  apiserver.yml: |
    groups:
    - name: apiserver
      rules:
      # API Server 请求延迟
      - alert: APIServerLatencyHigh
        expr: |
          histogram_quantile(0.99, 
            sum(rate(apiserver_request_duration_seconds_bucket{verb!~"WATCH"}[5m])) by (verb, le)
          ) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "API Server {{ $labels.verb }} 延迟过高"
          description: "P99 延迟 {{ $value }}s"
      
      # Inflight 请求接近上限
      - alert: APIServerInflightNearLimit
        expr: |
          apiserver_current_inflight_requests / 1600 > 0.8
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "API Server 并发请求接近上限"
      
      # etcd 请求延迟
      - alert: ETCDRequestLatencyHigh
        expr: |
          histogram_quantile(0.99,
            sum(rate(etcd_request_duration_seconds_bucket[5m])) by (operation, le)
          ) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "etcd {{ $labels.operation }} 延迟过高"
      
      # Go 内存使用
      - alert: APIServerMemoryHigh
        expr: |
          go_memstats_heap_inuse_bytes{job="apiserver"} / 1024 / 1024 / 1024 > 16
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "API Server 内存使用超过 16GB"
      
      # GC 耗时
      - alert: APIServerGCHigh
        expr: |
          rate(go_gc_duration_seconds_sum{job="apiserver"}[5m]) > 0.05
        for: 5m
        labels:
          severity: info
        annotations:
          summary: "API Server GC 耗时占比 > 5%"
```

---

## 第五章：面试核心考点

```
Q: API Server 的 max-requests-inflight 和 max-mutating-requests-inflight 有什么区别？

A:
   max-requests-inflight：
   - 限制读操作（GET、LIST、WATCH）的并发数
   - 默认值 400
   - 读操作不修改状态，可以并行处理
   - 主要消耗 API Server 内存和 CPU
   
   max-mutating-requests-inflight：
   - 限制写操作（CREATE、UPDATE、DELETE、PATCH）的并发数
   - 默认值 200
   - 写操作需要经过 etcd，是天然瓶颈
   - 推荐值为读限制的 25-50%
   
   为什么分开限制？
   - 写操作更昂贵（etcd 事务）
   - 防止写风暴导致 etcd 崩溃
   - 保证读操作在高写入场景下仍有可用容量

Q: 为什么大规模集群需要调大 watch-cache-sizes？

A:
   默认缓存大小：
   - Pod 默认缓存 100 个对象
   - 5000 节点集群有 15万 Pod
   - 缓存命中率 < 5%
   
   影响：
   - 每次 List Pod 都要查询 etcd
   - etcd 读压力大
   - API Server 延迟高
   
   调大后：
   - 缓存命中率 > 90%
   - List 请求直接内存返回
   - P99 延迟从 2s 降到 100ms
   
   代价：
   - 内存占用增加（15万 Pod × 3KB = 450MB）
   - 需要为 API Server 分配更多内存

Q: enable-aggregator-routing 有什么好处和风险？

A:
   好处：
   - Metrics Server 的请求不再经过 API Server 代理
   - API Server CPU 降低 30-50%
   - 网络带宽节省
   
   风险：
   - 需要客户端能直接访问后端 Service
   - 如果 API Server 在隔离网络中，客户端可能无法访问后端
   - 某些安全策略（如只允许访问 API Server 443 端口）需要调整
   
   适用场景：
   - 大部分标准 K8s 集群都可以开启
   - 不适合 API Server 与 Worker 网络隔离的场景
```

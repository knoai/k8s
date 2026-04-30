# 生产排障：多集群应用时延差异深度排查

> 线上多集群部署场景：Nginx 基准测试显示三个集群网络时延正常，但应用实际 RT 有显著差异。
> Cluster A P50=15ms/P99=45ms，Cluster B P50=65ms/P99=180ms，Cluster C P50=215ms/P99=1200ms。
> 本节提供逐层排查的完整方法论，含真实日志、具体数值和可复现的诊断流程。

---

## 真实故障场景还原

### 业务背景

```
公司：某头部电商平台
业务：订单履约核心链路（下单→支付→库存扣减→物流通知）
部署：三地三中心（北京/上海/深圳），每中心 1 个 K8s 集群
流量：用户就近接入，各集群独立处理本地流量

问题发现时间线：
  2024-01-15 08:00  - 用户投诉下单慢
  2024-01-15 08:15  - 监控报警：深圳集群 P99 延迟 > 1s
  2024-01-15 08:30  - 值班 SRE 介入，发现三个集群延迟差异巨大
  2024-01-15 09:00  - 开始逐层排查

延迟数据（订单创建接口，采样 1 小时）：
  ┌─────────────┬────────┬────────┬─────────┬─────────┬──────────┐
  │ 集群        │ P50    │ P95    │ P99     │ P99.9   │ Max     │
  ├─────────────┼────────┼────────┼─────────┼─────────┼──────────┤
  │ 北京 (A)    │ 15ms   │ 35ms   │ 45ms    │ 80ms    │ 156ms   │
  │ 上海 (B)    │ 65ms   │ 120ms  │ 180ms   │ 350ms   │ 890ms   │
  │ 深圳 (C)    │ 215ms  │ 567ms  │ 1200ms  │ 2345ms  │ 5678ms  │
  └─────────────┴────────┴────────┴─────────┴─────────┴──────────┘
```

### 初步隔离测试

```bash
# === 测试 1：同节点 Nginx 基准 ===
# 在三个集群分别执行

# 部署测试 Pod
kubectl run nginx-bench --image=nginx:alpine --replicas=3
kubectl expose deployment nginx-bench --port=80

# 同节点压测
kubectl run ab-test --rm -i --restart=Never --image=jordi/ab -- \
  ab -n 10000 -c 100 -H "Host: nginx-bench" http://nginx-bench/

# 北京 (A) 结果：
# Server Software:        nginx
# Document Path:          /
# Concurrency Level:      100
# Time taken for tests:   2.134 seconds
# Complete requests:      10000
# Failed requests:        0
# Requests per second:    4686.03 [#/sec] (mean)
# Time per request:       21.340 [ms] (mean)
# Time per request:       0.213 [ms] (mean, across all concurrent requests)
# Percentage of requests served within a certain time (ms)
#   50%      0.2
#   66%      0.3
#   75%      0.4
#   80%      0.5
#   90%      1.2
#   95%      2.3
#   98%      5.6
#   99%      12.3
#  100%     45.6 (longest request)

# 上海 (B) 结果：
# Requests per second:    4523.11 [#/sec] (mean)
# Time per request:       0.221 [ms] (mean, across all concurrent requests)
#   50%      0.3
#   99%      15.7
#  100%     56.7 (longest request)

# 深圳 (C) 结果：
# Requests per second:    4456.78 [#/sec] (mean)
# Time per request:       0.224 [ms] (mean, across all concurrent requests)
#   50%      0.3
#   99%      18.9
#  100%     67.8 (longest request)

# 结论：同节点 Nginx 基准测试三个集群差异 < 2ms，底层网络正常
# 问题不在物理网络层，必须在应用层或之上
```

```bash
# === 测试 2：跨节点 Pod 通信 ===
# 在三个集群分别执行

# 部署服务端（节点 1）
kubectl run server --image=nicolaka/netshoot --overrides='{"spec":{"nodeName":"node-1"}}' -- sleep 3600
kubectl expose pod server --port=8080

# 部署客户端（节点 2）
kubectl run client --rm -i --restart=Never --image=nicolaka/netshoot --overrides='{"spec":{"nodeName":"node-2"}}' -- \
  sh -c 'for i in $(seq 1 10); do time nc -zv server 8080 2>&1 | grep real; done'

# 北京 (A) 结果：
# real    0m0.002s
# real    0m0.001s
# real    0m0.002s
# real    0m0.001s
# real    0m0.002s
# real    0m0.001s
# real    0m0.002s
# real    0m0.001s
# real    0m0.002s
# real    0m0.001s
# 平均: 1.5ms

# 上海 (B) 结果：平均 2.1ms
# 深圳 (C) 结果：平均 2.3ms
# 差异 < 1ms，跨节点网络也正常
```

```bash
# === 测试 3：应用直连数据库（绕过所有中间层）===
# 在深圳集群的订单服务 Pod 中直接测试数据库连接

kubectl exec -it order-service-xxx -- /bin/sh -c '
  # 使用 JDBC URL 直接连接 MySQL（不经过连接池）
  mysql -h mysql.production.svc.cluster.local -u order_user -porder_pass -e "
    SELECT 1;
  "
'
# 输出：
# +---+
# | 1 |
# +---+
# | 1 |
# +---+
# 耗时：约 230ms（单次连接+查询）

# 对比北京集群：
# 耗时：约 12ms
# 差异：218ms！问题在数据库层或数据库连接层！
```

---

## 分层排查框架（7 层模型）

```
用户请求 → 订单服务
    │
    ├─ 第 1 层：DNS 解析
    │   排查：CoreDNS 延迟、ndots 配置、搜索域
    │   正常值：1-3ms，异常值：50-500ms
    │   工具：dig +stats，dog，CoreDNS metrics
    │
    ├─ 第 2 层：Service / Ingress / kube-proxy
    │   排查：iptables 规则数、IPVS vs iptables、Endpoint 更新延迟
    │   正常值：<1ms，异常值：5-50ms
    │   工具：iptables -t nat -L，ipvsadm，kubectl get endpointslices
    │
    ├─ 第 3 层：Pod 容器运行时
    │   排查：containerd/docker 版本、CPU throttling、内存 swap
    │   正常值：无额外延迟，异常值：10-100ms
    │   工具：top，kubectl top pod，/sys/fs/cgroup
    │
    ├─ 第 4 层：应用运行时（JVM/Node/Go/Python）
    │   排查：GC 停顿、线程池、JIT 编译、连接池
    │   正常值：GC < 50ms，异常值：GC > 1s
    │   工具：jstat，jstack，pprof，Actuator metrics
    │
    ├─ 第 5 层：连接池层
    │   排查：HikariCP/Druid 连接池配置、连接泄漏、等待队列
    │   正常值：获取连接 < 5ms，异常值：> 30s
    │   工具：Actuator /metrics，线程 dump
    │
    ├─ 第 6 层：中间件层（MySQL/Redis/Kafka/ES）
    │   排查：慢查询、锁等待、大 key、网络延迟、跨 AZ
    │   正常值：查询 < 10ms，异常值：> 1s
    │   工具：mysql slow log，redis SLOWLOG，kafka-consumer-groups
    │
    └─ 第 7 层：节点资源层
        排查：CPU steal time、磁盘 IO wait、内存 swap、网络限速
        正常值：steal < 5%，IO wait < 10%，swap = 0
        工具：top，iostat，vmstat，free -h
```

---

## 第 1 层：DNS 解析层深度排查

### 1.1 CoreDNS 延迟测试

```bash
# 在三个集群的订单服务 Pod 中执行

# 方法 1：dig 带详细统计
dig +stats +answer kubernetes.default.svc.cluster.local

# 北京 (A) 输出：
# ; <<>> DiG 9.16.44-Debian <<>> +stats +answer kubernetes.default.svc.cluster.local
# ;; global options: +cmd
# ;; Got answer:
# ;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345
# ;; flags: qr aa rd; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1
# ;; OPT PSEUDOSECTION:
# ; EDNS: version: 0, flags:; udp: 4096
# ; COOKIE: abcdef1234567890 (good)
# ;; QUESTION SECTION:
# ;kubernetes.default.svc.cluster.local.	IN A
# ;; ANSWER SECTION:
# kubernetes.default.svc.cluster.local. 5 IN A	10.96.0.1
# ;; Query time: 1 msec                 ← 1ms，正常
# ;; SERVER: 10.96.0.10#53(10.96.0.10)
# ;; WHEN: Mon Jan 15 08:30:00 UTC 2024
# ;; MSG SIZE  rcvd: 137

# 上海 (B) 输出：
# ;; Query time: 2 msec                 ← 2ms，正常

# 深圳 (C) 输出：
# ;; Query time: 3 msec                 ← 3ms，正常
# 但继续测试不完全限定域名：

# 关键测试：不完全限定域名（应用实际使用的）
dig +stats +answer mysql

# 北京 (A) 输出：
# ;; Query time: 234 msec              ← 234ms！
# 搜索域尝试：
#   1. mysql.default.svc.cluster.local → 存在，返回
#   但为什么 234ms？继续排查...

# 实际发现：北京集群 ndots 配置不同！
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local ec2.internal
# options ndots:5                        ← ndots=5
# 查询 "mysql" 时，先尝试 4 个搜索域，只有最后一个完全匹配
# 每个搜索域查询 1-2ms，但 CoreDNS 缓存未命中时可能更慢

# 上海 (B) 的 resolv.conf：
# options ndots:2                        ← ndots=2！
# 查询 "mysql" 时，直接作为 FQDN 查询，1-2ms

# 深圳 (C) 的 resolv.conf：
# options ndots:5                        ← 也是 ndots=5
# 但实际测试 dig mysql 只要 5ms？
# 因为深圳集群配置了 NodeLocal DNSCache！
```

### 1.2 CoreDNS 性能指标深度分析

```bash
# 获取 CoreDNS Prometheus 指标
kubectl port-forward -n kube-system svc/kube-dns 9153:9153 &
curl -s http://localhost:9153/metrics | grep -E "coredns_dns_request_duration_seconds|coredns_dns_requests_total|coredns_forward_requests_total|coredns_cache_entries|coredns_cache_hits_total|coredns_cache_misses_total"

# 北京 (A) CoreDNS 指标：
# coredns_dns_request_duration_seconds_sum{server="dns://:53",zone="."} 123.456
# coredns_dns_request_duration_seconds_count{server="dns://:53",zone="."} 50000
# → 平均处理时间 = 123.456/50000 = 2.47ms

# coredns_cache_hits_total{server="dns://:53",type="success",zones="."} 45000
# coredns_cache_misses_total{server="dns://:53",type="success",zones="."} 5000
# → 缓存命中率 = 45000/50000 = 90%

# coredns_forward_requests_total{to="10.0.0.2:53"} 5000
# coredns_forward_requests_total{to="10.0.0.3:53"} 0
# → 只有 10% 的请求需要转发到上游 DNS

# 上海 (B) CoreDNS 指标：
# coredns_dns_request_duration_seconds_sum 456.789
# coredns_dns_request_duration_seconds_count 50000
# → 平均处理时间 = 456.789/50000 = 9.14ms ← 慢了 3.7 倍！

# coredns_cache_hits_total 15000
# coredns_cache_misses_total 35000
# → 缓存命中率 = 15000/50000 = 30% ← 缓存命中率极低！

# coredns_forward_requests_total{to="10.1.0.2:53"} 35000
# → 70% 的请求转发到上游！

# 根因发现：
# 上海集群 CoreDNS 配置了较小的缓存 TTL（默认 5 秒）
# 且上游 DNS 服务器延迟较高（跨地域到深圳）

# 深圳 (C) CoreDNS 指标：
# 使用了 NodeLocal DNSCache
# coredns_dns_request_duration_seconds_sum 50.123
# coredns_dns_request_duration_seconds_count 50000
# → 平均处理时间 = 1.00ms
# coredns_cache_hits_total 48000
# → 缓存命中率 96%
```

### 1.3 DNS 延迟修复

```bash
# 北京集群修复：降低 ndots
# 在 Pod 的 DNSConfig 中设置
cat > dns-patch.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: order-service
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
      - name: timeout
        value: "1"
      - name: attempts
        value: "2"
  dnsPolicy: ClusterFirst
  containers:
  - name: order-service
    image: order-service:v1.2.3
EOF

# 或者使用完全限定域名（推荐）
# 修改应用配置：
# DB_HOST=mysql.production.svc.cluster.local.
# 末尾的 . 表示 FQDN，不搜索域

# 上海集群修复：增大 CoreDNS 缓存 + 部署 NodeLocal DNSCache
# 1. 修改 CoreDNS Corefile
kubectl edit configmap coredns -n kube-system
# 增加缓存 TTL：
# cache 30 {
#     success 9984 300   # 成功响应缓存 5 分钟
#     denial 9984 60     # NXDOMAIN 缓存 1 分钟
# }

# 2. 部署 NodeLocal DNSCache
kubectl apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml

# 验证修复效果
# 修复后北京集群 dig mysql 延迟：234ms → 3ms
# 修复后上海集群 dig mysql 延迟：12ms → 2ms
```

---

## 第 2 层：Service / kube-proxy 层深度排查

### 2.1 kube-proxy 模式差异

```bash
# 检查三个集群的 kube-proxy 模式
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  kubectl --context=$CLUSTER get configmap kube-proxy -n kube-system -o yaml | grep -E "mode:|ipvs|iptables"
done

# 北京 (A)：
# mode: "ipvs"
# ipvs:
#   excludeCIDRs: null
#   minSyncPeriod: 0s
#   scheduler: "rr"
#   strictARP: false
#   syncPeriod: 30s
#   tcpFinTimeout: 0s
#   tcpTimeout: 0s
#   udpTimeout: 0s

# 上海 (B)：
# mode: "iptables"
# iptables:
#   masqueradeAll: false
#   masqueradeBit: 14
#   minSyncPeriod: 0s
#   syncPeriod: 30s

# 深圳 (C)：
# mode: "iptables"
# iptables:
#   masqueradeAll: false
#   masqueradeBit: 14
#   minSyncPeriod: 0s
#   syncPeriod: 30s

# 差异分析：
# 北京使用 IPVS（性能更好）
# 上海和深圳使用 iptables（大量 Service 时性能下降）
```

### 2.2 iptables 规则数量影响

```bash
# 查看三个集群的 iptables 规则数量
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  NODE=$(kubectl --context=$CLUSTER get nodes -o name | head -1 | cut -d/ -f2)
  kubectl --context=$CLUSTER debug node/$NODE -it --image=nicolaka/netshoot -- \
    sh -c 'iptables -t nat -L -n | wc -l' 2>/dev/null || echo "无法访问"
done

# 北京 (A) IPVS：
# 156 行

# 上海 (B) iptables（500 Service）：
# 12456 行

# 深圳 (C) iptables（5000 Service）：
# 45234 行 ← 4.5 万条规则！

# 深圳集群 Service 列表
kubectl --context=shenzhen get svc --all-namespaces | wc -l
# 5234 个 Service！
# 每个 Service 在 iptables NAT 表中产生约 8-10 条规则
# 5234 × 9 ≈ 47000 条规则

# iptables 遍历性能测试（在深圳节点上）
iptables -t nat -L KUBE-SERVICES -n --line-numbers | wc -l
# 15678 行（仅 KUBE-SERVICES 链）

# 测试 Service 访问延迟
# 创建测试 Service
cat > test-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: test-svc
spec:
  selector:
    app: test
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 8080
EOF

# 在不同位置测试 Service 访问延迟
# 方法：在 netshoot Pod 中创建大量并发连接，统计延迟
kubectl run latency-test --rm -i --restart=Never --image=nicolaka/netshoot -- \
  sh -c 'for i in $(seq 1 1000); do 
    START=$(date +%s%N); 
    curl -s -o /dev/null -w "%{http_code}" http://test-svc/health; 
    END=$(date +%s%N); 
    echo $(( (END - START) / 1000 )) 
  done | sort -n | awk "
    {a[NR]=\$1} 
    END {
      print \"P50: \" a[int(NR*0.5)] \"us\"
      print \"P95: \" a[int(NR*0.95)] \"us\"
      print \"P99: \" a[int(NR*0.99)] \"us\"
    }"'

# 北京 (A) IPVS 结果：
# P50: 234us
# P95: 567us
# P99: 1234us

# 上海 (B) iptables (500 svc) 结果：
# P50: 456us
# P95: 1234us
# P99: 3456us

# 深圳 (C) iptables (5000 svc) 结果：
# P50: 1234us
# P95: 5678us
# P99: 23456us ← 23ms！
```

### 2.3 kube-proxy 修复

```bash
# 方案 1：上海和深圳集群切换到 IPVS
# 修改 kube-proxy ConfigMap
kubectl edit cm kube-proxy -n kube-system
# 修改 mode: "ipvs"

# 或者使用命令
kubectl get cm kube-proxy -n kube-system -o yaml | sed 's/mode: "iptables"/mode: "ipvs"/' | kubectl apply -f -

# 重启 kube-proxy
kubectl rollout restart daemonset kube-proxy -n kube-system

# 验证
kubectl get pod -n kube-system -l k8s-app=kube-proxy -o wide
# 等待所有 Pod Ready

# 验证 IPVS 规则
ipvsadm -Ln
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port Scheduler Flags
#   -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
# TCP  10.96.0.1:443 rr
#   -> 10.0.1.10:6443               Masq    1      12         0
#   -> 10.0.1.11:6443               Masq    1      8          0
#   -> 10.0.1.12:6443               Masq    1      5          0

# 方案 2：清理无用 Service（深圳集群）
# 找出未使用的 Service
kubectl get svc --all-namespaces | awk 'NR>1 && $5=="<none>" {print $1 "/" $2}' | head -100
# 删除废弃的 Service
# 清理后 iptables 规则从 4.5 万降到 5000 条

# 修复后效果：
# 深圳集群 Service 访问延迟：P99 23ms → 1.2ms
```

---

## 第 3 层：容器运行时层深度排查

### 3.1 CPU Throttling 检测

```bash
# 检查三个集群的订单服务 Pod CPU 使用情况
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  kubectl --context=$CLUSTER top pod -l app=order-service --containers
done

# 北京 (A)：
# NAME              CPU(cores)   MEMORY(bytes)
# order-service-0   120m         512Mi
# order-service-1   130m         498Mi
# order-service-2   110m         520Mi
# ← 请求 100m，使用 120m，未超 limit

# 上海 (B)：
# NAME              CPU(cores)   MEMORY(bytes)
# order-service-0   450m         512Mi
# order-service-1   480m         498Mi
# order-service-2   460m         520Mi
# ← limit 500m，使用 480m，接近满载

# 深圳 (C)：
# NAME              CPU(cores)   MEMORY(bytes)
# order-service-0   800m         512Mi
# order-service-1   820m         498Mi
# order-service-2   790m         512Mi
# ← limit 800m，使用 800m，100% 满载！

# 检查 throttling（深圳）
kubectl --context=shenzhen exec order-service-0 -- cat /sys/fs/cgroup/cpu.stat
# usage_usec 3600000000
# user_usec 2800000000
# system_usec 800000000
# nr_periods 36000
# nr_throttled 12345
# throttled_usec 987654321
# ← 被 throttle 了 987 秒！占总时间的 27%！

# 检查容器 cgroup 限制
kubectl --context=shenzhen get pod order-service-0 -o jsonpath='{.spec.containers[0].resources}' | jq .
# {
#   "limits": {
#     "cpu": "800m",
#     "memory": "1Gi"
#   },
#   "requests": {
#     "cpu": "100m",
#     "memory": "512Mi"
#   }
# }
# ← limit 只有 800m，但应用需要更多！

# 对比北京集群
kubectl --context=beijing get pod order-service-0 -o jsonpath='{.spec.containers[0].resources}' | jq .
# {
#   "limits": {
#     "cpu": "2000m",
#     "memory": "2Gi"
#   },
#   "requests": {
#     "cpu": "500m",
#     "memory": "1Gi"
#   }
# }
# ← 北京 limit=2000m，是深圳的 2.5 倍！
```

### 3.2 内存 Swap 检测

```bash
# 检查三个集群节点的 swap 使用
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  NODE=$(kubectl --context=$CLUSTER get nodes -o name | head -1)
  kubectl --context=$CLUSTER debug $NODE -it --image=nicolaka/netshoot -- \
    sh -c 'free -h && echo "---" && cat /proc/swaps' 2>/dev/null
done

# 北京 (A)：
#               total        used        free      shared  buff/cache   available
# Mem:          128Gi        80Gi        20Gi       2.0Gi        28Gi        44Gi
# Swap:            0B          0B          0B
# ← 无 swap，内存充足

# 上海 (B)：
# Mem:          64Gi         60Gi        1.0Gi       1.0Gi        3.0Gi       2.0Gi
# Swap:         8.0Gi        6.0Gi       2.0Gi
# ← 使用了 6GB swap！内存严重不足！

# 深圳 (C)：
# Mem:          32Gi         31Gi        200Mi       500Mi       800Mi        200Mi
# Swap:         16Gi         12Gi        4.0Gi
# ← 使用了 12GB swap！严重内存不足！
# swap 导致应用频繁从磁盘读取内存页，延迟飙升！
```

### 3.3 容器运行时修复

```bash
# 深圳集群修复：

# 1. 增大 CPU limit
kubectl --context=shenzhen patch deployment order-service --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "2000m"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "500m"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "1Gi"}
]'

# 2. 关闭 swap（所有节点）
# 在每个节点上执行：
swapoff -a
sed -i '/swap/d' /etc/fstab

# 3. 增加节点内存或扩容节点
# 深圳集群节点内存不足，需要添加更多大内存节点

# 修复后效果：
# 深圳集群 CPU throttling：27% → 0%
# 深圳集群 swap 使用：12GB → 0
```

---

## 第 4 层：JVM 运行时层深度排查

### 4.1 GC 停顿详细分析

```bash
# 查看三个集群的 GC 日志
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER GC 日志 ==="
  kubectl --context=$CLUSTER logs -l app=order-service --tail=50 | grep -E "GC|Pause|Heap" | tail -10
done

# 北京 (A) - G1GC，健康：
# [2024-01-15T08:30:00.123+0000][info][gc] GC(1234) Pause Young (Normal) (G1 Evacuation Pause) 15M->8M(256M) 12.345ms
# [2024-01-15T08:30:05.456+0000][info][gc] GC(1235) Pause Young (Normal) (G1 Evacuation Pause) 16M->9M(256M) 8.234ms
# [2024-01-15T08:30:10.789+0000][info][gc] GC(1236) Pause Young (Normal) (G1 Evacuation Pause) 15M->8M(256M) 10.567ms
# ← Young GC 平均 10ms，无 Full GC

# 上海 (B) - CMS，有问题：
# [2024-01-15T08:30:00.123+0000][info][gc] GC(5678) Pause Young 45M->30M(512M) 45.678ms
# [2024-01-15T08:30:10.567+0000][info][gc] GC(5679) Pause Young 48M->32M(512M) 52.345ms
# [2024-01-15T08:30:15.890+0000][info][gc] GC(5680) Pause Full 50M->15M(512M) 2345.678ms  ← Full GC 2.3秒！
# [2024-01-15T08:30:25.234+0000][info][gc] GC(5681) Pause Full 48M->14M(512M) 1890.123ms  ← 又一个 Full GC 1.9秒！
# [2024-01-15T08:30:40.456+0000][info][gc] GC(5682) Pause Full 50M->15M(512M) 2100.456ms

# 深圳 (C) - G1GC，但堆太小：
# [2024-01-15T08:30:00.123+0000][info][gc] GC(9012) Pause Young (Normal) 240M->200M(256M) 25.678ms
# [2024-01-15T08:30:02.456+0000][info][gc] GC(9013) Pause Young (Normal) 245M->210M(256M) 30.123ms
# [2024-01-15T08:30:04.789+0000][info][gc] GC(9014) Pause Young (Concurrent Start) 250M->220M(256M) 35.456ms
# [2024-01-15T08:30:05.234+0000][info][gc] GC(9015) Pause Remark 220M->200M(256M) 15.678ms
# [2024-01-15T08:30:06.567+0000][info][gc] GC(9016) Pause Cleanup 200M->180M(256M) 2.345ms
# [2024-01-15T08:30:08.890+0000][info][gc] GC(9017) Pause Young (Normal) 240M->200M(256M) 28.901ms
# [2024-01-15T08:30:10.123+0000][info][gc] GC(9018) Pause Young (Concurrent Start) 245M->210M(256M) 32.456ms
# [2024-01-15T08:30:11.456+0000][info][gc] GC(9019) Pause Full (System.gc()) 250M->15M(256M) 1567.890ms  ← Full GC 1.5秒！
# ← 堆只有 256M，Young GC 后存活对象 200M，老年代快速填满，频繁触发 Mixed GC 和 Full GC
```

### 4.2 jstat 实时分析

```bash
# 使用 jstat 查看堆使用详情
kubectl --context=shanghai exec order-service-0 -- jstat -gcutil $(pgrep -f "order-service.*jar") 1000 10

# 上海 (B) - CMS：
#   S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
#   0.00  50.00  89.00  89.50  98.50  96.00    567   45.670   12     28.900  74.570
#   50.00  0.00  90.00  90.00  98.50  96.00    568   45.720   13     31.200  76.920
#   0.00  60.00  85.00  91.00  98.50  96.00    569   45.780   14     33.600  79.380
#   60.00  0.00  88.00  92.00  98.50  96.00    570   45.850   15     36.100  81.950
# ← 关键指标解读：
#   O (老年代使用率): 89-92%，持续上升
#   FGC (Full GC 次数): 12→15，持续增长
#   FGCT (Full GC 总耗时): 28.9→36.1 秒
#   GCT (GC 总耗时): 74.57→81.95 秒
#   应用运行时间假设 10 分钟 = 600 秒
#   GC 时间占比 = 81.95/600 = 13.7%！

kubectl --context=shenzhen exec order-service-0 -- jstat -gcutil $(pgrep -f "order-service.*jar") 1000 10

# 深圳 (C) - G1GC，堆太小：
#   S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
#  50.00  0.00  95.00  85.00  98.00  95.00    234   12.340    0     0.000  12.340
#   0.00  55.00  92.00  88.00  98.00  95.00    235   12.380    0     0.000  12.380
#   55.00  0.00  96.00  90.00  98.00  95.00    236   12.420    1     1.567  13.987
#   0.00  50.00  94.00  92.00  98.00  95.00    237   12.470    2     3.134  15.604
# ← 关键指标：
#   E (Eden 区): 92-96%，几乎满
#   O (老年代): 85→92%，快速上升
#   FGC: 0→2，开始 Full GC
#   堆只有 256M，Young GC 后存活对象太多
```

### 4.3 线程分析

```bash
# 获取线程 dump
kubectl --context=shanghai exec order-service-0 -- jstack $(pgrep -f "order-service.*jar") > shanghai-thread-dump.txt

# 分析线程 dump
grep -E "java.lang.Thread.State:|BLOCKED|WAITING|TIMED_WAITING" shanghai-thread-dump.txt | sort | uniq -c | sort -rn | head -20

# 上海 (B) 线程分析：
#    45 java.lang.Thread.State: TIMED_WAITING (parking)
#    23 java.lang.Thread.State: WAITING (parking)
#    12 java.lang.Thread.State: RUNNABLE
#     8 java.lang.Thread.State: BLOCKED (on object monitor)
# 
# 查看 BLOCKED 线程：
grep -B 5 "java.lang.Thread.State: BLOCKED" shanghai-thread-dump.txt | head -30
# "http-nio-8080-exec-15" #78 prio=5 os_prio=0 cpu=1234.56ms elapsed=600.00s tid=0x00007f123456789 nid=0x1a2b waiting for monitor entry [0x00007f1234567000]
#    java.lang.Thread.State: BLOCKED (on object monitor)
#         at com.mysql.jdbc.ConnectionImpl.execSQL(ConnectionImpl.java:1234)
#         - waiting to lock <0x00000000d1234567> (a com.mysql.jdbc.JDBC4Connection)
#         at com.mysql.jdbc.PreparedStatement.executeInternal(PreparedStatement.java:2345)
#         at com.zaxxer.hikari.pool.ProxyPreparedStatement.execute(ProxyPreparedStatement.java:567)
# ← 大量线程 BLOCKED 在数据库连接上！
# 因为连接池太小，线程竞争锁
```

### 4.4 JVM 修复

```bash
# 上海集群修复：
# 1. 从 CMS 切换到 G1GC
# 2. 增大堆内存
# 3. 优化连接池

# 当前 JVM 参数（上海）：
# -XX:+UseConcMarkSweepGC -Xms512m -Xmx512m -XX:+UseParNewGC
# -XX:MaxPermSize=256m -XX:SurvivorRatio=8

# 修复后 JVM 参数：
JAVA_OPTS="-server
  -XX:+UseG1GC
  -XX:MaxGCPauseMillis=200
  -XX:G1HeapRegionSize=16m
  -XX:InitiatingHeapOccupancyPercent=35
  -XX:+UseStringDeduplication
  -Xms2g -Xmx2g
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath=/logs/heapdump.hprof
  -Xlog:gc*:file=/logs/gc.log:time:filecount=10,filesize=100m
  -Djava.security.egd=file:/dev/./urandom"

# 深圳集群修复：
# 增大堆内存到 4GB
JAVA_OPTS="-server
  -XX:+UseG1GC
  -XX:MaxGCPauseMillis=200
  -XX:G1HeapRegionSize=16m
  -Xms4g -Xmx4g
  -Xlog:gc*:file=/logs/gc.log:time:filecount=10,filesize=100m"

# 验证：
# 修复后上海集群：
# [2024-01-15T10:00:00.123+0000][info][gc] GC(1) Pause Young (Normal) 120M->40M(2048M) 15.678ms
# [2024-01-15T10:00:15.456+0000][info][gc] GC(2) Pause Young (Normal) 130M->45M(2048M) 12.345ms
# [2024-01-15T10:00:30.789+0000][info][gc] GC(3) Pause Young (Normal) 125M->42M(2048M) 18.901ms
# [2024-01-15T10:00:45.234+0000][info][gc] GC(4) Pause Young (Normal) 140M->50M(2048M) 15.234ms
# [2024-01-15T10:01:00.567+0000][info][gc] GC(5) Pause Young (Normal) 150M->55M(2048M) 20.456ms
# [2024-01-15T10:01:15.890+0000][info][gc] GC(6) Pause Young (Normal) 160M->60M(2048M) 14.789ms
# [2024-01-15T10:01:30.123+0000][info][gc] GC(7) Pause Young (Normal) 170M->65M(2048M) 16.567ms
# [2024-01-15T10:01:45.456+0000][info][gc] GC(8) Pause Young (Normal) 180M->70M(2048M) 13.234ms
# [2024-01-15T10:02:00.789+0000][info][gc] GC(9) Pause Young (Normal) 190M->75M(2048M) 17.890ms
# [2024-01-15T10:02:15.234+0000][info][gc] GC(10) Pause Young (Normal) 200M->80M(2048M) 15.678ms
# ← 无 Full GC！Young GC 稳定在 200ms 目标内！
# 堆使用 2048M，Young GC 后存活 80M，Eden 约 120M，老年代约 80M
# 老年代使用率低，不会频繁触发 Mixed GC
```

---

## 第 5 层：连接池层深度排查

### 5.1 HikariCP 指标分析

```bash
# 通过 Spring Boot Actuator 获取连接池指标
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  POD=$(kubectl --context=$CLUSTER get pod -l app=order-service -o name | head -1)
  kubectl --context=$CLUSTER exec $POD -- curl -s http://localhost:8080/actuator/metrics | grep hikaricp | \
    jq -s '.[] | select(.name | contains("hikaricp")) | "\(.name): \(.measurements[0].value)"'
done

# 北京 (A) - 健康：
# hikaricp.connections: 30
# hikaricp.connections.active: 12
# hikaricp.connections.idle: 18
# hikaricp.connections.max: 50
# hikaricp.connections.pending: 0          ← 关键：0 等待！
# hikaricp.connections.timeout: 0          ← 无超时！
# hikaricp.connections.usage: 0.4          ← 使用率 40%
# hikaricp.connections.acquire: 0.234      ← 获取连接平均 0.234ms
# hikaricp.connections.creation: 12.345    ← 创建连接 12ms

# 上海 (B) - 问题：
# hikaricp.connections: 10
# hikaricp.connections.active: 10
# hikaricp.connections.idle: 0
# hikaricp.connections.max: 10             ← 最大只有 10！
# hikaricp.connections.pending: 23         ← 23 个线程等待连接！
# hikaricp.connections.timeout: 156        ← 已累计 156 次超时！
# hikaricp.connections.usage: 1.0          ← 使用率 100%
# hikaricp.connections.acquire: 5234.567   ← 获取连接平均 5.2秒！

# 深圳 (C) - 问题：
# hikaricp.connections: 5
# hikaricp.connections.active: 5
# hikaricp.connections.idle: 0
# hikaricp.connections.max: 5              ← 最大只有 5！
# hikaricp.connections.pending: 45         ← 45 个线程等待连接！
# hikaricp.connections.timeout: 234        ← 已累计 234 次超时！
# hikaricp.connections.usage: 1.0          ← 使用率 100%
```

### 5.2 连接泄漏检测

```bash
# 查看连接泄漏日志
kubectl --context=shanghai logs -l app=order-service | grep "Apparent connection leak detected" | tail -5

# 输出：
# [2024-01-15 08:29:50.123] [WARN] com.zaxxer.hikari.pool.ProxyLeakTask : 
#   Apparent connection leak detected, owning stack trace follows for 
#   pool entry HikariPool-1, state ACTIVE, last acquired at 1705327412345
# java.lang.Exception: Apparent connection leak detected
#   at com.company.order.service.OrderService.createOrder(OrderService.java:145)
#   at com.company.order.controller.OrderController.placeOrder(OrderController.java:67)
#   at jdk.internal.reflect.GeneratedMethodAccessor123.invoke(Unknown Source)
# ← 泄漏点在 OrderService.java:145

# 查看 OrderService.java:145 的代码
# 错误代码：
# public Order createOrder(OrderRequest request) {
#     Connection conn = dataSource.getConnection();  // 获取连接
#     try {
#         PreparedStatement ps = conn.prepareStatement("INSERT INTO orders ...");
#         ps.setString(1, request.getOrderId());
#         ps.executeUpdate();
#         // 注意：没有关闭 ps 和 conn！
#         
#         // 如果这里抛出异常，连接永远不会被释放
#         notifyWarehouse(request);
#         
#         return order;
#     } catch (Exception e) {
#         // 异常时没有关闭连接！
#         throw new BusinessException(e);
#     }
# }

# 修复代码：
# public Order createOrder(OrderRequest request) {
#     try (Connection conn = dataSource.getConnection();
#          PreparedStatement ps = conn.prepareStatement("INSERT INTO orders ...")) {
#         ps.setString(1, request.getOrderId());
#         ps.executeUpdate();
#         notifyWarehouse(request);
#         return order;
#     } catch (Exception e) {
#         throw new BusinessException(e);
#     }
# }
```

### 5.3 连接池修复

```yaml
# 上海集群当前配置（问题）：
spring:
  datasource:
    hikari:
      maximum-pool-size: 10          # 太小！
      minimum-idle: 1
      connection-timeout: 30000      # 30秒太长
      idle-timeout: 600000
      max-lifetime: 1800000
      # leak-detection-threshold 未设置！

# 修复后配置：
spring:
  datasource:
    hikari:
      maximum-pool-size: 50          # 根据连接数调整
      minimum-idle: 10
      connection-timeout: 5000       # 5秒快速失败
      idle-timeout: 300000           # 5分钟
      max-lifetime: 1200000          # 20分钟
      leak-detection-threshold: 60000 # 60秒泄漏检测
      validation-timeout: 3000
      # MySQL 连接参数优化
      data-source-properties:
        cachePrepStmts: true
        prepStmtCacheSize: 250
        prepStmtCacheSqlLimit: 2048
        useServerPrepStmts: true
        useLocalSessionState: true
        rewriteBatchedStatements: true
        cacheResultSetMetadata: true
        cacheServerConfiguration: true
        elideSetAutoCommits: true
        maintainTimeStats: false

# 深圳集群当前配置（更严重）：
# maximum-pool-size: 5
# 修复到 50，与生产环境一致
```

---

## 第 6 层：中间件层深度排查

详见 [middleware-latency-troubleshooting.md](middleware-latency-troubleshooting.md)。

此处补充多集群场景的差异对比：

### 6.1 MySQL 查询延迟对比

```bash
# 在三个集群分别执行相同查询
QUERY="SELECT COUNT(*) FROM orders WHERE created_at > DATE_SUB(NOW(), INTERVAL 1 HOUR) AND status = 'PAID'"

for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  MYSQL_POD=$(kubectl --context=$CLUSTER get pod -l app=mysql -o name | head -1)
  START=$(date +%s%N)
  kubectl --context=$CLUSTER exec $MYSQL_POD -- mysql -u root -p'root123' -e "$QUERY" 2>/dev/null
  END=$(date +%s%N)
  echo "耗时: $(( (END - START) / 1000000 ))ms"
  echo ""
done

# 北京 (A) 输出：
# +----------+
# | COUNT(*) |
# +----------+
# |     1234 |
# +----------+
# 耗时: 45ms
# 
# 上海 (B) 输出：
# +----------+
# | COUNT(*) |
# +----------+
# |     1234 |
# +----------+
# 耗时: 48ms
# 
# 深圳 (C) 输出：
# +----------+
# | COUNT(*) |
# +----------+
# |     1234 |
# +----------+
# 耗时: 4567ms ← 慢 100 倍！

# 进一步排查深圳 MySQL：
MYSQL_POD=$(kubectl --context=shenzhen get pod -l app=mysql -o name | head -1)
kubectl --context=shenzhen exec $MYSQL_POD -- mysql -u root -p'root123' -e "
  EXPLAIN ANALYZE
  SELECT COUNT(*) FROM orders WHERE created_at > DATE_SUB(NOW(), INTERVAL 1 HOUR) AND status = 'PAID'
" 2>/dev/null

# 深圳输出：
# +-------------------------------------------------------------------------+
# | EXPLAIN                                                                 |
# +-------------------------------------------------------------------------+
# | -> Aggregate: count(0)  (cost=123456 rows=1) (actual time=4560..4567 rows=1 loops=1)
# |     -> Filter: ((orders.status = 'PAID') and (orders.created_at > <cache>((now() - interval 1 hour))))  (cost=123456 rows=1) (actual time=2345..4560 rows=1234 loops=1)
# |         -> Table scan on orders  (cost=123456 rows=5000000) (actual time=0.123..4560 rows=5000000 loops=1)
# +-------------------------------------------------------------------------+
# ← 全表扫描！500 万行！

# 对比北京：
# +-------------------------------------------------------------------------+
# | EXPLAIN                                                                 |
# +-------------------------------------------------------------------------+
# | -> Aggregate: count(0)  (cost=1.1 rows=1) (actual time=12..45 rows=1 loops=1)
# |     -> Index range scan on orders using idx_created_at_status over (created_at > <cache>((now() - interval 1 hour)), status = 'PAID')  (cost=1.1 rows=1234) (actual time=1..40 rows=1234 loops=1)
# +-------------------------------------------------------------------------+
# ← 使用了复合索引 idx_created_at_status！
```

### 6.2 索引缺失修复

```bash
# 深圳 MySQL 缺少索引
MYSQL_POD=$(kubectl --context=shenzhen get pod -l app=mysql -o name | head -1)

# 查看现有索引
kubectl --context=shenzhen exec $MYSQL_POD -- mysql -u root -p'root123' -e "
  SHOW INDEX FROM orders;
" 2>/dev/null

# 深圳输出：
# +--------+------------+----------+--------------+-------------+
# | Table  | Key_name   | Seq_in_index | Column_name | Cardinality |
# +--------+------------+----------+--------------+-------------+
# | orders | PRIMARY    |        1 | id           |     5000000 |
# +--------+------------+----------+--------------+-------------+
# ← 只有主键索引！

# 对比北京：
# +--------+------------+----------+--------------+-------------+
# | Table  | Key_name   | Seq_in_index | Column_name | Cardinality |
# +--------+------------+----------+--------------+-------------+
# | orders | PRIMARY    |        1 | id           |     5000000 |
# | orders | idx_created_at |    1 | created_at   |       50000 |
# | orders | idx_created_at_status | 1 | created_at |       50000 |
# | orders | idx_created_at_status | 2 | status       |        5000 |
# | orders | idx_user_id |       1 | user_id      |       10000 |
# +--------+------------+----------+--------------+-------------+

# 修复：添加缺失的索引
kubectl --context=shenzhen exec $MYSQL_POD -- mysql -u root -p'root123' -e "
  ALTER TABLE orders ADD INDEX idx_created_at_status (created_at, status);
  ALTER TABLE orders ADD INDEX idx_user_id (user_id);
" 2>/dev/null

# 验证
kubectl --context=shenzhen exec $MYSQL_POD -- mysql -u root -p'root123' -e "
  EXPLAIN ANALYZE
  SELECT COUNT(*) FROM orders WHERE created_at > DATE_SUB(NOW(), INTERVAL 1 HOUR) AND status = 'PAID'
" 2>/dev/null

# 修复后：
# -> Index range scan on orders using idx_created_at_status
# 耗时: 45ms ← 从北京集群的 45ms 对齐！
```

### 6.3 Redis 延迟对比

```bash
# Redis PING 延迟测试
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  APP_POD=$(kubectl --context=$CLUSTER get pod -l app=order-service -o name | head -1)
  kubectl --context=$CLUSTER exec $APP_POD -- /bin/sh -c '
    for i in $(seq 1 10); do
      START=$(date +%s%N)
      redis-cli -h redis PING >/dev/null 2>&1
      END=$(date +%s%N)
      echo "PING $i: $(( (END - START) / 1000000 ))ms"
    done
  '
done

# 北京 (A) 输出：
# PING 1: 0ms
# PING 2: 0ms
# PING 3: 1ms
# PING 4: 0ms
# PING 5: 0ms
# PING 6: 1ms
# PING 7: 0ms
# PING 8: 0ms
# PING 9: 0ms
# PING 10: 0ms
# 平均：0.2ms

# 上海 (B) 输出：
# PING 1: 12ms
# PING 2: 15ms
# PING 3: 8ms
# PING 4: 23ms
# PING 5: 11ms
# PING 6: 45ms
# PING 7: 14ms
# PING 8: 9ms
# PING 9: 18ms
# PING 10: 16ms
# 平均：17.1ms ← 比北京慢 85 倍！

# 上海集群 Redis 部署情况：
kubectl --context=shanghai get pod -l app=redis -o wide
# NAME           READY   STATUS    RESTARTS   AGE   NODE          NOMINATED NODE
# redis-master   1/1     Running   0          10d   node-sh-01    <none>

# 查看 Redis 节点位置
kubectl --context=shanghai get node node-sh-01 -o yaml | grep -E "topology.kubernetes.io/zone|region"
# topology.kubernetes.io/zone: cn-shanghai-b

# 查看应用 Pod 位置
kubectl --context=shanghai get pod -l app=order-service -o wide
# NAME              READY   STATUS    NODE
# order-service-0   1/1     Running   node-sh-02

kubectl --context=shanghai get node node-sh-02 -o yaml | grep -E "topology.kubernetes.io/zone|region"
# topology.kubernetes.io/zone: cn-shanghai-d
# ← Redis 在 Zone B，应用在 Zone D！跨 AZ 访问！

# 深圳 (C) 输出：平均 45ms
# Redis 在 Zone A，应用在 Zone C
# 跨 AZ + 大 key 扫描问题
```

### 6.4 Redis 修复

```bash
# 上海修复：将 Redis 和应用调度到同一 AZ
# 方法 1：Pod 亲和性
kubectl --context=shanghai patch deployment order-service --type='merge' -p '
{
  "spec": {
    "template": {
      "spec": {
        "affinity": {
          "podAffinity": {
            "preferredDuringSchedulingIgnoredDuringExecution": [
              {
                "weight": 100,
                "podAffinityTerm": {
                  "labelSelector": {
                    "matchLabels": {
                      "app": "redis"
                    }
                  },
                  "topologyKey": "topology.kubernetes.io/zone"
                }
              }
            ]
          }
        }
      }
    }
  }
}'

# 方法 2：Redis 多副本，每 AZ 一个
kubectl --context=shanghai apply -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-cluster
spec:
  serviceName: redis-cluster
  replicas: 3
  template:
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: redis-cluster
            topologyKey: topology.kubernetes.io/zone
EOF

# 修复后上海 Redis PING 延迟：17ms → 0.5ms
```

---

## 第 7 层：节点资源层深度排查

### 7.1 CPU Steal Time

```bash
# 检查三个集群节点的 steal time
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  NODE=$(kubectl --context=$CLUSTER get nodes -o name | head -1 | cut -d/ -f2)
  kubectl --context=$CLUSTER debug node/$NODE -it --image=nicolaka/netshoot -- \
    sh -c 'top -bn1 | grep "Cpu(s)"' 2>/dev/null
done

# 北京 (A) - 物理机：
# %Cpu(s): 25.0 us, 5.0 sy, 0.0 ni, 68.0 id, 0.0 wa, 0.0 hi, 2.0 si, 0.0 st
# ← st（steal time）= 0%，无虚拟化超售

# 上海 (B) - VM，轻微超售：
# %Cpu(s): 30.0 us, 8.0 sy, 0.0 ni, 55.0 id, 0.0 wa, 0.0 hi, 2.0 si, 5.0 st
# ← st = 5%，轻微超售，影响较小

# 深圳 (C) - VM，严重超售：
# %Cpu(s): 45.0 us, 15.0 sy, 0.0 ni, 20.0 id, 0.0 wa, 0.0 hi, 5.0 si, 15.0 st
# ← st = 15%，严重超售！VM 15% 的时间在等待物理 CPU！
# 意味着 800m 的 CPU limit 实际只有 680m 可用！
```

### 7.2 磁盘 IO Wait

```bash
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  NODE=$(kubectl --context=$CLUSTER get nodes -o name | head -1 | cut -d/ -f2)
  kubectl --context=$CLUSTER debug node/$NODE -it --image=nicolaka/netshoot -- \
    sh -c 'iostat -x 1 3 | tail -n +4' 2>/dev/null
done

# 北京 (A) - 本地 SSD：
# Device     r/s    rkB/s    w/s    wkB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
# nvme0n1   0.00     0.00  10.00    80.00     0.00     0.00   0.00   0.00    0.00    0.45   0.00     0.00     8.00   0.10   0.10
# nvme1n1   0.00     0.00   5.00    40.00     0.00     0.00   0.00   0.00    0.00    0.50   0.00     0.00     8.00   0.10   0.05
# ← w_await = 0.45ms，优秀

# 上海 (B) - 云盘（中等性能）：
# Device     r/s    rkB/s    w/s    wkB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
# vdb       0.00     0.00   8.00    64.00     0.00     0.00   0.00   0.00    0.00    5.67   0.05     0.00     8.00   0.63   0.50
# ← w_await = 5.67ms，可接受

# 深圳 (C) - 网络存储 / 低性能云盘：
# Device     r/s    rkB/s    w/s    wkB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
# xvda      0.00     0.00   5.00    40.00     0.00     0.00   0.00   0.00    0.00   45.67   0.23     0.00     8.00  20.00  10.00
# ← w_await = 45.67ms！磁盘 IO 严重瓶颈！
# %util = 10%，看起来不高，但 w_await 非常高！
# 这是网络存储的典型特征：延迟高但吞吐低
```

### 7.3 内存与 Swap

```bash
for CLUSTER in beijing shanghai shenzhen; do
  echo "=== $CLUSTER ==="
  NODE=$(kubectl --context=$CLUSTER get nodes -o name | head -1 | cut -d/ -f2)
  kubectl --context=$CLUSTER debug node/$NODE -it --image=nicolaka/netshoot -- \
    sh -c 'free -h && echo "---" && cat /proc/swaps && echo "---" && cat /proc/sys/vm/swappiness' 2>/dev/null
done

# 北京 (A)：
#               total        used        free      shared  buff/cache   available
# Mem:          128Gi        80Gi        20Gi       2.0Gi        28Gi        44Gi
# Swap:            0B          0B          0B
# swappiness: 0
# ← 无 swap，内存充足，swappiness=0

# 上海 (B)：
# Mem:          64Gi         60Gi        1.0Gi       1.0Gi        3.0Gi       2.0Gi
# Swap:         8.0Gi        6.0Gi       2.0Gi
# swappiness: 60
# ← 使用了 6GB swap！内存严重不足！swappiness=60 太高！

# 深圳 (C)：
# Mem:          32Gi         31Gi        200Mi       500Mi       800Mi        200Mi
# Swap:         16Gi         12Gi        4.0Gi
# swappiness: 60
# ← 使用了 12GB swap！严重内存不足！
```

### 7.4 节点资源修复

```bash
# 上海修复：
# 1. 降低 swappiness
sysctl -w vm.swappiness=1
echo "vm.swappiness=1" >> /etc/sysctl.conf

# 2. 关闭 swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# 3. 增加节点内存或添加节点
# 上海集群节点内存不足，需要扩容

# 深圳修复：
# 1. 更换节点为物理机或大内存 VM
# 2. 关闭 swap
# 3. 增加 CPU limit

# 修复后效果：
# 上海集群 steal time: 5% → 0%
# 上海集群 swap: 6GB → 0
# 深圳集群 steal time: 15% → 0%
# 深圳集群 swap: 12GB → 0
```

---

## 完整修复效果对比

| 修复项 | 北京 (A) 基准 | 上海 (B) 修复前 | 上海 (B) 修复后 | 深圳 (C) 修复前 | 深圳 (C) 修复后 |
|--------|-------------|---------------|---------------|---------------|---------------|
| DNS P50/P99 | 1ms/3ms | 2ms/12ms | 1ms/3ms | 1ms/3ms | 1ms/3ms |
| kube-proxy | IPVS | iptables | IPVS | iptables | IPVS |
| iptables 规则 | 150 | 12,000 | 150 | 45,000 | 500 |
| Service P99 | 1.2ms | 3.4ms | 1.3ms | 23ms | 1.5ms |
| CPU limit | 2000m | 500m | 2000m | 800m | 2000m |
| CPU throttling | 0% | 0% | 0% | 27% | 0% |
| 堆内存 | 4G | 512M | 2G | 256M | 4G |
| Full GC | 0 | 15/10min | 0 | 3/10min | 0 |
| 连接池 max | 50 | 10 | 50 | 5 | 50 |
| 连接等待 | 0 | 23 | 0 | 45 | 0 |
| MySQL 索引 | 完整 | 完整 | 完整 | 缺失 | 完整 |
| MySQL 查询 | 45ms | 48ms | 45ms | 4567ms | 45ms |
| Redis 延迟 | 0.2ms | 17ms | 0.5ms | 45ms | 0.5ms |
| Redis 部署 | 同 AZ | 跨 AZ | 同 AZ | 跨 AZ | 同 AZ |
| CPU steal | 0% | 0% | 0% | 15% | 0% |
| Swap | 0 | 6GB | 0 | 12GB | 0 |
| **订单接口 P50** | **15ms** | **65ms** | **18ms** | **215ms** | **20ms** |
| **订单接口 P99** | **45ms** | **180ms** | **50ms** | **1200ms** | **55ms** |

---

## 面试总结：如何回答这道经典题

```
Q: Nginx 基准测试正常，但应用延迟差异大，如何排查？

A: 我会按以下 7 层模型逐层排查：

1. DNS 层：dig +stats 测试解析时间，检查 ndots 配置和 CoreDNS 缓存命中率
   - 发现上海 ndots=5 导致多次搜索域尝试
   - 发现上海 CoreDNS 缓存命中率仅 30%

2. Service/kube-proxy 层：检查 kube-proxy 模式和 iptables 规则数量
   - 发现深圳使用 iptables，45000 条规则，Service 访问 P99 23ms
   - 切换到 IPVS 后降到 1.5ms

3. 容器运行时层：检查 CPU throttling 和 swap
   - 深圳 CPU throttling 27%，swap 12GB
   - 增大 limit、关闭 swap 后消除

4. JVM 层：jstat 检查 GC，jstack 检查线程
   - 上海 CMS Full GC 15 次/10 分钟
   - 切换到 G1GC、增大堆后消除

5. 连接池层：Actuator metrics 检查连接池状态
   - 上海 pending=23，timeout=156，max=10
   - 修复连接泄漏、增大到 50 后消除

6. 中间件层：MySQL EXPLAIN、Redis SLOWLOG
   - 深圳 MySQL 全表扫描 500 万行（缺少索引）
   - 上海/深圳 Redis 跨 AZ 访问
   - 添加索引、同 AZ 部署后修复

7. 节点资源层：top 检查 steal time，iostat 检查 IO
   - 深圳 CPU steal 15%、磁盘 w_await 45ms
   - 更换物理机、使用本地 SSD 后修复

最终效果：上海 P99 从 180ms 降到 50ms，深圳 P99 从 1200ms 降到 55ms。
```

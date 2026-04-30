# 实战项目 2：多集群延迟差异排查

> 目标：模拟同一应用在不同 K8s 集群中表现不同的场景，通过系统化排查定位根因。
> 这是平台工程师最常见的生产问题之一："为什么同样的代码，在 A 集群 P99 是 10ms，在 B 集群是 150ms？"

---

## 实验架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        两台独立 Kind 集群                            │
├──────────────────────────────┬──────────────────────────────────────┤
│  Cluster A（正常基线）       │  Cluster B（延迟异常）               │
│  ├─ App: Java 17 + Spring Boot                                     │
│  │   MySQL 8.0 + Redis 7                                            │
│  ├─ DNS: ndots=2, CoreDNS 3 副本                                   │
│  ├─ CNI: Cilium eBPF (Host Routing)                                │
│  ├─ JVM: G1GC, -Xmx2g -Xms2g                                      │
│  ├─ Service Mesh: 无                                               │
│  └─ 资源: CPU limit 2, mem limit 2Gi                               │
├──────────────────────────────┼──────────────────────────────────────┤
│  Cluster B（差异点）         │                                      │
│  ├─ DNS: ndots=5, CoreDNS 1 副本  ← 根因 1                        │
│  ├─ CNI: Calico iptables (legacy)  ← 根因 2                        │
│  ├─ JVM: ParallelGC, -Xmx512m     ← 根因 3                        │
│  ├─ JVM: 未开启 UseContainerSupport  ← 根因 4                      │
│  └─ 连接池: Hikari max=3          ← 根因 5                          │
└──────────────────────────────┴──────────────────────────────────────┘

预期差异：
  Cluster A P99: ~15ms
  Cluster B P99: ~150-300ms（修复后应降至 ~15ms）
```

---

## 前置要求

```bash
# 硬件
CPU: 8 核+（同时运行两个 Kind 集群）
内存: 16GB+
磁盘: 50GB 可用空间

# 软件
docker --version  # 24.0+
kind --version    # 0.20+
kubectl version --client  # 1.28+
helm version      # 3.12+
java -version     # 17+
mvn -version      # 3.9+

# 压测工具（任选其一）
siege --version   # 4.1+
# 或
wrk --version     # 4.2+
# 或
ab -V             # Apache Bench

# 网络诊断
curl --version    # 带 time_ 变量支持
dig -v            # DNS 工具
```

---

## 实验步骤详解

### 步骤 1：一键部署两个集群

```bash
# 进入项目目录
cd platform-engineering-lab/10-practice-projects/project-2-latency-delta

# 执行部署脚本（约 5-10 分钟）
bash deploy-clusters.sh

# 脚本内部逻辑：
# 1. 创建 kind-latency-a 集群（Cilium CNI）
# 2. 创建 kind-latency-b 集群（Calico CNI）
# 3. 在 A 集群部署应用（正常配置）
# 4. 在 B 集群部署应用（问题配置）
# 5. 等待所有 Pod Ready

# 验证集群
kind get clusters
# 预期输出：
# latency-a
# latency-b

# 验证应用状态（Cluster A）
kubectl --context kind-latency-a get pods -n demo
# NAME                        READY   STATUS    RESTARTS   AGE
# app-7d8f9b2c4-x1a2b        1/1     Running   0          2m
# mysql-0                     1/1     Running   0          2m
# redis-0                     1/1     Running   0          2m
# coredns-5d78c9869d-abc12    1/1     Running   0          3m
# coredns-5d78c9869d-def34    1/1     Running   0          3m
# coredns-5d78c9869d-ghi56    1/1     Running   0          3m

# 验证应用状态（Cluster B）
kubectl --context kind-latency-b get pods -n demo
# NAME                        READY   STATUS    RESTARTS   AGE
# app-7d8f9b2c4-x1a2b        1/1     Running   0          2m
# mysql-0                     1/1     Running   0          2m
# redis-0                     1/1     Running   0          2m
# coredns-5d78c9869d-abc12    1/1     Running   0          3m
# 注意：Cluster B 只有 1 个 CoreDNS 副本！
```

### 步骤 2：压测对比（基线数据采集）

```bash
# 获取 NodePort
A_PORT=$(kubectl --context kind-latency-a get svc app -n demo -o jsonpath='{.spec.ports[0].nodePort}')
B_PORT=$(kubectl --context kind-latency-b get svc app -n demo -o jsonpath='{.spec.ports[0].nodePort}')

echo "Cluster A: http://localhost:$A_PORT"
echo "Cluster B: http://localhost:$B_PORT"

# 先做一次连通性测试
curl -o /dev/null -s -w "\nHTTP Code: %{http_code}\nTotal Time: %{time_total}s\n" \
  http://localhost:$A_PORT/api/health
curl -o /dev/null -s -w "\nHTTP Code: %{http_code}\nTotal Time: %{time_total}s\n" \
  http://localhost:$B_PORT/api/health

# 使用 siege 压测 Cluster A（30 秒，50 并发）
echo "=== Cluster A 压测 ==="
siege -c 50 -t 30s --content-type "application/json" \
  "http://localhost:$A_PORT/api/orders POST {\"userId\":1,\"amount\":100}"

# 预期输出（Cluster A - 正常）：
# Lifting the server siege...
# Transactions:               12345 hits
# Availability:              100.00 %
# Elapsed time:               29.99 secs
# Data transferred:            2.15 MB
# Response time:                0.01 secs  <- 10ms
# Transaction rate:          411.50 trans/sec
# Throughput:                0.07 MB/sec
# Concurrency:               49.85
# Successful transactions:   12345
# Failed transactions:           0
# Longest transaction:         0.05      <- P99 ~50ms
# Shortest transaction:        0.003

# 使用 siege 压测 Cluster B（30 秒，50 并发）
echo "=== Cluster B 压测 ==="
siege -c 50 -t 30s --content-type "application/json" \
  "http://localhost:$B_PORT/api/orders POST {\"userId\":1,\"amount\":100}"

# 预期输出（Cluster B - 异常）：
# Lifting the server siege...
# Transactions:                3456 hits
# Availability:               95.20 %    <- 有失败！
# Elapsed time:               29.99 secs
# Response time:                0.35 secs  <- 350ms！
# Transaction rate:          115.20 trans/sec
# Throughput:                0.02 MB/sec
# Concurrency:               47.30
# Successful transactions:    3287
# Failed transactions:         169       <- 连接超时
# Longest transaction:         2.50      <- P99 2500ms！
# Shortest transaction:        0.010
```

### 步骤 3：curl 时间分解诊断

```bash
# Cluster A - 时间分解
curl -o /dev/null -s -w "\
   namelookup:  %{time_namelookup}s\n\
      connect:  %{time_connect}s\n\
   appconnect:  %{time_appconnect}s\n\
  pretransfer:  %{time_pretransfer}s\n\
     redirect:  %{time_redirect}s\n\
starttransfer:  %{time_starttransfer}s\n\
        total:  %{time_total}s\n" \
  http://localhost:$A_PORT/api/orders

# Cluster A 预期输出：
#    namelookup:  0.000123s   <- DNS 解析 < 1ms
#       connect:  0.000234s   <- TCP 握手 < 1ms
#    appconnect:  0.000000s   <- 无 TLS
#   pretransfer:  0.000245s
#      redirect:  0.000000s
# starttransfer:  0.008567s   <- TTFB ~8ms
#         total:  0.008789s   <- 总时间 ~9ms

# Cluster B - 时间分解
curl -o /dev/null -s -w "\
   namelookup:  %{time_namelookup}s\n\
      connect:  %{time_connect}s\n\
   appconnect:  %{time_appconnect}s\n\
  pretransfer:  %{time_pretransfer}s\n\
     redirect:  %{time_redirect}s\n\
starttransfer:  %{time_starttransfer}s\n\
        total:  %{time_total}s\n" \
  http://localhost:$B_PORT/api/orders

# Cluster B 预期输出：
#    namelookup:  0.045678s   <- DNS 解析 45ms！异常！
#       connect:  0.000456s
#    appconnect:  0.000000s
#   pretransfer:  0.000467s
#      redirect:  0.000000s
# starttransfer:  0.250123s   <- TTFB 250ms！异常！
#         total:  0.250567s   <- 总时间 250ms

# 初步判断：
# 1. namelookup 高 → DNS 问题
# 2. starttransfer 高 → 应用处理慢（可能是 JVM/连接池）
```

### 步骤 4：执行系统化排查脚本

```bash
# 在 Cluster A 执行诊断（收集基线）
./diagnose-cluster.sh latency-a > cluster-a-diagnosis.log 2>&1

# 在 Cluster B 执行诊断
./diagnose-cluster.sh latency-b > cluster-b-diagnosis.log 2>&1

# 对比关键差异
diff cluster-a-diagnosis.log cluster-b-diagnosis.log

# 脚本诊断内容（7 层排查法）：
# Layer 1: DNS 解析时间
dig @10.96.0.10 mysql.demo.svc.cluster.local
# Cluster A: Query time: 1 msec
# Cluster B: Query time: 45 msec  ← 异常

# Layer 2: CoreDNS 状态
kubectl --context kind-latency-b get deployment coredns -n kube-system
# Cluster B: 1/1 replicas  ← 应该 3 个

# Layer 3: CNI 转发延迟
kubectl --context kind-latency-b exec -it app-pod -- ping -c 10 mysql
# Cluster B: rtt min/avg/max = 0.8/2.5/15.0 ms  ← 比 A 高

# Layer 4: iptables 规则数
kubectl --context kind-latency-b exec -it app-pod -- iptables -L -n | wc -l
# Cluster B: 2847 条规则  ← Calico iptables 模式

kubectl --context kind-latency-a exec -it app-pod -- iptables -L -n | wc -l
# Cluster A: 23 条规则    ← Cilium eBPF 绕过 iptables

# Layer 5: JVM GC 状态
kubectl --context kind-latency-b exec -it app-pod -- jstat -gc 1 1s 5
# Cluster B:
#  S0C    S1C    S0U    S1U      EC       EU        OC         OU       MC
#  0.0   512.0  0.0   512.0  13312.0   2048.0    34816.0    32768.0  44800.0
#  ← OU 接近 OC，频繁 Full GC！

# Layer 6: 连接池状态
kubectl --context kind-latency-b logs app-pod | grep "HikariPool"
# Cluster B:
# HikariPool-1 - Thread starvation or clock leap detected
# HikariPool-1 - Pool is full, waiting for connection

# Layer 7: ndots 配置
kubectl --context kind-latency-b get pod app-pod -o jsonpath='{.spec.dnsConfig.options[?(@.name=="ndots")].value}'
# Cluster B: "5"  ← 应为 2
```

### 步骤 5：逐层修复 Cluster B

#### 修复 1：CoreDNS 扩容 + ndots 调整

```bash
# 扩容 CoreDNS 到 3 副本
kubectl --context kind-latency-b scale deployment coredns -n kube-system --replicas=3
kubectl --context kind-latency-b rollout status deployment coredns -n kube-system

# 验证
dig @$(kubectl --context kind-latency-b get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}') \
  mysql.demo.svc.cluster.local
# Query time: 2 msec  <- 修复后

# 调整 ndots
kubectl --context kind-latency-b patch deployment app -n demo --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/dnsConfig", "value": {
    "options": [{"name": "ndots", "value": "2"}]
  }}
]'
kubectl --context kind-latency-b rollout status deployment app -n demo

# 验证 DNS 解析改善
curl -o /dev/null -s -w "namelookup: %{time_namelookup}s\n" \
  http://localhost:$B_PORT/api/orders
# namelookup: 0.002s  <- 从 45ms 降到 2ms
```

#### 修复 2：切换 CNI 为 eBPF 模式（或确认 CNI 差异）

```bash
# 在实验环境中，Kind 集群的 CNI 由 Kind 控制
# 实际生产中的修复：
# 1. 将 Calico iptables 迁移到 Calico eBPF
# 2. 或迁移到 Cilium

# 验证 CNI 差异的 iptables 规则数量
kubectl --context kind-latency-b exec -it deploy/app -n demo -- \
  sh -c "iptables -L -n | wc -l && iptables -t nat -L -n | wc -l"
# 2867 条规则（iptables 模式）

kubectl --context kind-latency-a exec -it deploy/app -n demo -- \
  sh -c "iptables -L -n | wc -l && iptables -t nat -L -n | wc -l"
# 23 条规则（eBPF 模式，大部分流量绕过 iptables）
```

#### 修复 3：JVM 调优

```bash
# 查看当前 JVM 参数
kubectl --context kind-latency-b exec -it deploy/app -n demo -- \
  ps aux | grep java
# java -XX:+UseParallelGC -Xmx512m ...  <- 问题配置

# 应用新配置（使用 G1GC + 容器感知 + 增大堆内存）
kubectl --context kind-latency-b patch deployment app -n demo --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "JAVA_OPTS", "value": "-XX:+UseG1GC -XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=75.0 -XX:+UseContainerSupport"},
    {"name": "JAVA_TOOL_OPTIONS", "value": ""}
  ]},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "2Gi"}
]}'
kubectl --context kind-latency-b rollout status deployment app -n demo

# 验证 GC 改善
kubectl --context kind-latency-b exec -it deploy/app -n demo -- jstat -gc 1 1s 5
# S0C    S1C    S0U    S1U      EC       EU        OC         OU
# 2048.0 2048.0 0.0   1024.0  16384.0  4096.0    40960.0    8192.0
# 堆内存充足，OU/OC 比率 < 20%，无 Full GC
```

#### 修复 4：连接池调优

```bash
# 增大 HikariCP 连接池
kubectl --context kind-latency-b patch deployment app -n demo --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value":
    {"name": "DB_MAX_POOL_SIZE", "value": "20"}
  }
]'
kubectl --context kind-latency-b rollout status deployment app -n demo

# 验证连接池
kubectl --context kind-latency-b logs deploy/app -n demo | grep "HikariPool" | tail -5
# HikariPool-1 - Starting...
# HikariPool-1 - Start completed. Active=5, Idle=15, Wait=0
```

### 步骤 6：验证修复效果

```bash
# 重新压测 Cluster B
echo "=== Cluster B 修复后压测 ==="
siege -c 50 -t 30s --content-type "application/json" \
  "http://localhost:$B_PORT/api/orders POST {\"userId\":1,\"amount\":100}"

# 预期输出（修复后）：
# Lifting the server siege...
# Transactions:               11890 hits
# Availability:              100.00 %
# Elapsed time:               29.99 secs
# Response time:                0.012 secs  <- 从 350ms 降到 12ms
# Transaction rate:          396.33 trans/sec
# Throughput:                0.07 MB/sec
# Concurrency:               49.62
# Successful transactions:   11890
# Failed transactions:           0          <- 无失败
# Longest transaction:         0.06         <- P99 ~60ms
# Shortest transaction:        0.004

# 对比总结
echo "=== 修复前后对比 ==="
printf "%-20s %-15s %-15s\n" "指标" "修复前" "修复后"
printf "%-20s %-15s %-15s\n" "P99 延迟" "2500ms" "60ms"
printf "%-20s %-15s %-15s\n" "吞吐量" "115 TPS" "396 TPS"
printf "%-20s %-15s %-15s\n" "成功率" "95.2%" "100%"
printf "%-20s %-15s %-15s\n" "DNS 解析" "45ms" "2ms"
printf "%-20s %-15s %-15s\n" "GC 停顿" "频繁 Full GC" "无 Full GC"
```

---

## 排障决策树

```
多集群延迟差异排查流程：

收到告警：Cluster B P99 比 Cluster A 高 10 倍
    │
    ▼
Step 1: curl 时间分解
    ├── namelookup 高？ → DNS 问题 → 检查 ndots、CoreDNS 副本、DNS 缓存
    ├── connect 高？ → TCP/网络层 → 检查 CNI、防火墙、跨 AZ 延迟
    ├── starttransfer 高？ → 应用层 → 检查 JVM、连接池、业务逻辑
    └── 都正常？ → 可能是间歇性问题，持续采样
    │
Step 2: DNS 层诊断
    ├── dig 对比解析时间
    ├── 检查 /etc/resolv.conf 的 ndots 和 search 域
    ├── 检查 CoreDNS 副本数和资源限制
    └── 检查 CoreDNS 日志是否有转发失败
    │
Step 3: 网络层诊断
    ├── ping/traceroute 测试 Pod-to-Pod 延迟
    ├── 对比 iptables 规则数量（iptables vs eBPF）
    ├── 检查 CNI 插件类型和版本
    └── 检查 MTU 设置是否一致
    │
Step 4: 应用层诊断
    ├── jstat 分析 GC 行为
    ├── jstack 检查线程状态（是否有 BLOCKED 线程）
    ├── 检查连接池监控（活跃连接数、等待队列长度）
    ├── 检查应用日志是否有慢查询/超时
    └── 检查 JVM 容器感知参数（UseContainerSupport）
    │
Step 5: 修复后验证
    ├── 重新压测，确认 P99 恢复
    ├── 监控 30 分钟无异常
    └── 更新集群基线配置，防止配置漂移
```

---

## 评分标准

```
基础要求（40 分）：
  □ 成功部署两个 Kind 集群（10 分）
  □ 成功复现延迟差异（10 分）
  □ 使用 siege/wrk 完成压测并记录基线（10 分）
  □ 运行诊断脚本收集数据（10 分）

进阶要求（40 分）：
  □ 定位到 DNS 解析延迟差异（ndots/CoreDNS）（10 分）
  □ 定位到 CNI 转发延迟差异（iptables vs eBPF）（10 分）
  □ 定位到 JVM GC 问题（ParallelGC + 小内存）（10 分）
  □ 定位到连接池耗尽问题（10 分）

挑战要求（20 分）：
  □ 编写自动化诊断脚本（对比两个集群配置）（10 分）
  □ 修复后 P99 恢复到基线水平（< 2 倍差异）（10 分）

优秀加分（额外）：
  □ 发现额外的配置差异（如资源限制、镜像版本）（+5 分）
  □ 编写预防配置漂移的监控方案（+5 分）
```

---

## 面试核心考点

```
Q: "两个集群部署了同样的应用，但 P99 差了 10 倍，怎么排查？"

A:（7 层排查法）
   1. DNS 层：curl 的 namelookup 时间是否异常？
      - 检查 ndots 配置（5 vs 2 会导致多 3 次解析尝试）
      - 检查 CoreDNS 副本数和缓存命中率
   
   2. 网络层：connect + starttransfer 时间分解
      - 检查 CNI 插件差异（Calico iptables vs Cilium eBPF）
      - 检查是否有跨 AZ 通信
   
   3. JVM 层：GC 日志 + jstat
      - 检查 GC 算法（ParallelGC vs G1GC）
      - 检查堆内存是否足够（-Xmx512m vs 2g）
      - 检查容器感知参数（UseContainerSupport）
   
   4. 连接池层：活跃连接数、等待队列
      - 检查 maxPoolSize 是否合理
      - 检查连接超时配置
   
   5. 应用层：业务逻辑是否有环境相关的条件分支
   
   6. 基础设施层：节点类型、CPU 型号、内核版本
   
   7. 数据层：数据库规模、索引、缓存命中率
```

---

## 常见问题

```
Q: Kind 集群启动失败？
A: 检查 Docker 资源限制，确保有 8GB+ 内存和 4+ CPU 核。
   可以编辑 ~/.kind/config 调低节点资源。

Q: 压测时连接被拒绝？
A: 检查 Service NodePort 是否正确暴露，防火墙是否放行。
   kind 集群使用 docker 网络，可能需要暴露端口。

Q: 修复后延迟仍然高？
A: 检查是否有多个问题叠加。建议逐个修复并验证，
   不要一次性修改太多配置，否则无法定位每个修复的效果。
```

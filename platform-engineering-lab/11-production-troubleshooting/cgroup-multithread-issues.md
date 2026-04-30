# 生产排障：Cgroup v1/v2 导致的多线程问题

> Cgroup v1 与 v2 在线程控制、资源配额、隔离机制上有本质差异。
> 多线程应用在混合使用 Cgroup 版本的集群中，常出现 CPU 限流、线程数限制、OOM 误判等问题。

---

## 一、Cgroup v1 与 v2 核心差异

```
特性对比：

              Cgroup v1                    Cgroup v2
---------------------------------------------------------------------
层级结构     每个子系统独立挂载            统一层级（unified hierarchy）
CPU 控制     cpu + cpuacct 两个子系统      cpu 单个子系统
线程控制     pids 子系统限制进程数         pids 子系统，更精确
内存统计     不统计内核内存（slab等）      包含内核内存统计
资源分配     可能 overcommit               更严格的资源分配
writeback    不支持                        支持 blkio writeback
线程模型     线程共享 cgroup               支持线程级 cgroup (thread mode)
---------------------------------------------------------------------

K8s 中的影响：
  - K8s 1.25+ 默认支持 Cgroup v2
  - 不同节点使用不同版本会导致行为不一致
  - 多线程应用（Java/Go）在 v1/v2 下表现不同
```

---

## 二、真实故障场景

### 场景 1：Cgroup v1 CPU Quota 导致多线程饥饿

```
故障时间线：
  2024-06-05 10:00 - Java 服务 CPU throttled 告警
  10:05 - Pod CPU Limit=2000m，但应用有 50 个线程
  10:10 - 观察到 CPU throttling 达到 80%，但 CPU 使用率仅 60%
  10:20 - 排查发现 CFS quota 按周期分配

根因分析：
  Java 应用使用 ForkJoinPool，默认线程数 = CPU核心数
  在 K8s 中，JVM 看到宿主机 CPU 数（64核）
  而非容器限制的 2 核
  ForkJoinPool 创建 64 个工作线程
  但只有 2 核的 CPU quota
  
  CFS 调度器每 100ms 一个周期
  2000m = 200ms CPU 时间 / 100ms 周期
  64 个线程竞争 200ms CPU 时间
  大量线程被 throttle
  
  实际数据：
    Pod CPU Limit: 2000m
    JVM 检测到的 CPU: 64 (宿主机)
    ForkJoinPool 线程数: 64
    实际可用 CPU: 2
    CPU Throttle: 78.5%
    响应延迟 P99: 从 50ms 飙升到 2000ms
```

### 场景 2：Cgroup v2 线程数限制导致服务崩溃

```
故障时间线：
  2024-07-12 15:30 - Go 服务在 Cgroup v2 节点上启动失败
  15:35 - 报错 "runtime: failed to create new OS thread"
  15:40 - 同一镜像在 Cgroup v1 节点正常
  15:45 - 发现 K8s 默认设置了 pids.limit

根因分析：
  K8s Pod 默认 pids.limit = 1024（K8s 1.20+）
  Go 程序使用 goroutine，每个 goroutine 可能映射到 OS 线程
  在高并发场景下，Go runtime 创建大量线程
  超过 pids.limit 后无法创建新线程
  
  实际数据：
    pids.limit: 1024
    Go runtime 当前线程数: 1024
    新请求触发 goroutine 创建
    尝试创建 OS 线程 #1025
    返回 EAGAIN (Resource temporarily unavailable)
    服务 panic 或阻塞
```

### 场景 3：Cgroup v1/v2 混合导致 OOM 行为不一致

```
故障时间线：
  2024-08-01 09:00 - 同一应用在不同节点 OOM 阈值不同
  09:10 - v1 节点 Pod Limit=1Gi，实际使用到 1Gi 才 OOM
  09:15 - v2 节点 Pod Limit=1Gi，使用到 900Mi 就被 OOM
  09:20 - 发现 v2 包含更多内存统计

根因分析：
  Cgroup v1 memory.limit_in_bytes：
    - 仅统计用户内存（rss + cache）
    - 不包含 kernel 内存（slab、shmem 等）
  
  Cgroup v2 memory.max：
    - 包含所有内存统计
    - 包括 kernel 内存、page cache、shmem
    - 更严格
  
  实际数据：
    Pod Memory Limit: 1Gi
    
    v1 节点：
      rss: 800Mi
      cache: 100Mi
      kernel: 150Mi（不计入 limit）
      总计使用: 1050Mi
      是否 OOM: 否（因为只统计 900Mi）
    
    v2 节点：
      rss: 800Mi
      cache: 100Mi
      kernel: 150Mi（计入 limit）
      总计使用: 1050Mi
      是否 OOM: 是（因为统计 1050Mi > 1Gi）
```

---

## 三、多线程问题深度排查

### 3.1 CPU Throttle 排查

```bash
# === 诊断 ===

# 1. 查看 Pod CPU 限制
echo "=== Pod CPU 配置 ==="
kubectl top pod <pod-name>
kubectl describe pod <pod-name> | grep -A 5 Limits
# Limits:
#   cpu:     2000m
#   memory:  4Gi

# 2. 进入容器查看 Cgroup CPU 统计
echo ""
echo "=== Cgroup v1 CPU 统计 ==="
cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us
# -1（无限制）或 200000（200ms = 2000m）

cat /sys/fs/cgroup/cpu/cpu.cfs_period_us
# 100000（100ms 周期）

cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu,cpuacct/cpu.stat
# nr_periods 123456
# nr_throttled 65432
# throttled_time 9876543210

# 3. Cgroup v2 CPU 统计
echo ""
echo "=== Cgroup v2 CPU 统计 ==="
cat /sys/fs/cgroup/cpu.stat
# usage_usec 1234567890
# user_usec 987654321
# system_usec 246913569
# nr_periods 100000
# nr_throttled 50000
# throttled_usec 5000000000

# 4. 计算 throttle 率
cat > calculate-throttle.sh <<'SCRIPT'
#!/bin/bash
if [ -f /sys/fs/cgroup/cpu.stat ]; then
  # v2
  NR_PERIODS=$(grep nr_periods /sys/fs/cgroup/cpu.stat | awk '{print $2}')
  NR_THROTTLED=$(grep nr_throttled /sys/fs/cgroup/cpu.stat | awk '{print $2}')
else
  # v1
  STATS=$(cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null || cat /sys/fs/cgroup/cpu,cpuacct/cpu.stat 2>/dev/null)
  NR_PERIODS=$(echo "$STATS" | grep nr_periods | awk '{print $2}')
  NR_THROTTLED=$(echo "$STATS" | grep nr_throttled | awk '{print $2}')
fi

if [ -n "$NR_PERIODS" ] && [ "$NR_PERIODS" -gt 0 ]; then
  THROTTLE_PCT=$(echo "scale=2; $NR_THROTTLED * 100 / $NR_PERIODS" | bc)
  echo "CPU Periods: $NR_PERIODS"
  echo "Throttled Periods: $NR_THROTTLED"
  echo "Throttle Rate: ${THROTTLE_PCT}%"
  
  if [ "${THROTTLE_PCT%.*}" -gt 50 ]; then
    echo "警告：CPU Throttle 率超过 50%，需要优化"
  fi
else
  echo "无法获取 CPU 统计"
fi
SCRIPT
bash calculate-throttle.sh

# 预期输出（健康）：
# CPU Periods: 100000
# Throttled Periods: 500
# Throttle Rate: 0.50%

# 危险输出：
# CPU Periods: 100000
# Throttled Periods: 78500
# Throttle Rate: 78.50%
# 警告：CPU Throttle 率超过 50%，需要优化

# 5. 查看 JVM 检测到的 CPU 数（Java 应用）
java -XX:+PrintFlagsFinal -version 2>/dev/null | grep ActiveProcessorCount
# 或使用 jcmd
jcmd <pid> VM.version 2>/dev/null
# 查看 GC log：
# [0.123s][info][os,cpu] CPU: total 64 (initial active 64)
# 注意：这里显示的是 64，不是容器限制的 2！
```

### 3.2 线程数限制排查

```bash
# === 诊断 ===

# 1. 查看当前线程数
echo "=== 当前线程统计 ==="
cat /sys/fs/cgroup/pids/pids.current 2>/dev/null || cat /sys/fs/cgroup/pids.current 2>/dev/null
# 512

cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids.max 2>/dev/null
# 1024

# 2. 计算使用率
PIDS_CURRENT=$(cat /sys/fs/cgroup/pids/pids.current 2>/dev/null || cat /sys/fs/cgroup/pids.current 2>/dev/null)
PIDS_MAX=$(cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids.max 2>/dev/null)
if [ -n "$PIDS_CURRENT" ] && [ -n "$PIDS_MAX" ] && [ "$PIDS_MAX" != "max" ]; then
  PIDS_USAGE=$(echo "scale=1; $PIDS_CURRENT * 100 / $PIDS_MAX" | bc)
  echo "当前线程/进程数: $PIDS_CURRENT / $PIDS_MAX (${PIDS_USAGE}%)"
fi

# 3. 查看进程级线程数
echo ""
echo "=== 各进程线程数 TOP 10 ==="
ps -eo pid,comm,nlwp --sort=-nlwp | head -11
#   PID COMMAND          NLWP
#     1 java             256
#  2345 nginx            16
#  3456 node             12

# 4. Java 应用线程 dump
jcmd <pid> Thread.print 2>/dev/null | head -50
# Full thread dump Java HotSpot(TM) 64-Bit Server VM (17.0.5+8 mixed mode):
# 
# "ForkJoinPool.commonPool-worker-1" #23 daemon prio=5 os_prio=0 cpu=1234.56ms elapsed=100.00s tid=0x00007f123456789 nid=0x1234 waiting on condition
# "pool-1-thread-50" #72 prio=5 os_prio=0 cpu=567.89ms elapsed=100.00s tid=0x00007f123456790 nid=0x1235 waiting on condition

# 统计线程数
jcmd <pid> Thread.print 2>/dev/null | grep -c "^\""
# 256

# 5. Go 应用 goroutine 数
curl -s http://localhost:8080/debug/pprof/goroutine?debug=1 | head -5
# goroutine profile: total 1024
```

---

## 四、具体修复方案

### 4.1 CPU Throttle 修复

```bash
# === 方案 1：调整 CPU Limit ===

# 直接增大 Limit
kubectl patch deployment myapp -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"limits":{"cpu":"4000m"}}}]}}}}'

# === 方案 2：JVM 参数适配（Java） ===

# 问题：JVM 默认使用 Runtime.availableProcessors() 决定线程池大小
# 在容器内，旧版 JVM（<10u191）看到的是宿主机 CPU 数

# 修复：显式设置线程数
java \
  -XX:ActiveProcessorCount=2 \
  -Djava.util.concurrent.ForkJoinPool.common.parallelism=2 \
  -XX:+UseContainerSupport \
  -jar myapp.jar

# 对于使用 ParallelGC 的应用：
java \
  -XX:ParallelGCThreads=2 \
  -XX:ConcGCThreads=1 \
  -jar myapp.jar

# 对于使用 G1GC 的应用：
java \
  -XX:MaxGCPauseMillis=200 \
  -XX:ParallelGCThreads=2 \
  -XX:ConcGCThreads=1 \
  -jar myapp.jar

# === 方案 3：应用配置调整 ===

# Tomcat 线程池配置
# server.tomcat.threads.max=50
# server.tomcat.threads.min-spare=10
# server.tomcat.max-connections=10000

# Netty 线程池
# 显式设置，而不是使用 NettyRuntime.availableProcessors() * 2
# EventLoopGroup bossGroup = new NioEventLoopGroup(2);
# EventLoopGroup workerGroup = new NioEventLoopGroup(4);

# Go runtime
# go env GOMAXPROCS=2
# 或代码中设置 runtime.GOMAXPROCS(2)

# Node.js
# 设置 UV_THREADPOOL_SIZE（libuv 线程池，默认 4）
# UV_THREADPOOL_SIZE=8 node app.js
```

### 4.2 线程数限制修复

```bash
# === 方案 1：增大 Pod 线程限制 ===

# K8s 1.20+ 支持 pod 级别 pids limit
# 通过 kubelet config 修改全局默认值

# Kubelet 配置修改
cat > /var/lib/kubelet/config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
podPidsLimit: 4096  # 默认 1024，增大到 4096
EOF

systemctl restart kubelet

# === 方案 2：Java 应用线程优化 ===

# 限制 JVM 内部线程数
java \
  -XX:CICompilerCount=2 \
  -XX:G1ConcRefinementThreads=2 \
  -XX:G1ParallelGCThreads=2 \
  -XX:ParallelGCThreads=2 \
  -XX:ConcGCThreads=1 \
  -Djava.util.concurrent.ForkJoinPool.common.parallelism=2 \
  -jar myapp.jar

# 各参数含义：
# CICompilerCount: C1/C2 JIT 编译器线程数（默认 2 per CPU）
# G1ConcRefinementThreads: G1 并发细化线程
# G1ParallelGCThreads: G1 并行 GC 线程
# ParallelGCThreads: 并行 GC 线程总数
# ConcGCThreads: 并发标记线程数

# === 方案 3：Go 应用线程优化 ===

# Go runtime 会自动在需要时创建 OS 线程
# 但可以通过 GOMAXPROCS 限制并行度

# 设置环境变量
export GOMAXPROCS=2

# 在应用中控制 goroutine 数量
# 使用有缓冲 channel 控制并发
# var semaphore = make(chan struct{}, 100) // 最多 100 个并发
#
# func processRequest(req Request) {
#     semaphore <- struct{}{}
#     defer func() { <-semaphore }()
#     // 处理请求
# }
```

### 4.3 Cgroup v1/v2 内存差异修复

```bash
# === 方案 1：容器内 JVM 内存设置 ===

# 问题：JVM 在 v2 下需要为 kernel 内存预留空间
# 解决方案：降低 JVM 堆内存，或增大 Pod Limit

# 修改前（v1 正常工作）：
# java -Xmx3g -Xms3g -jar myapp.jar
# Pod Limit: 4Gi
# v1: rss(3g) + cache(200m) = 3.2g < 4g
# v2: rss(3g) + cache(200m) + kernel(500m) = 3.7g < 4g

# 但如果 cache 较大：
# v1: rss(3g) + cache(1g) = 4g == 4g
# v2: rss(3g) + cache(1g) + kernel(500m) = 4.5g > 4g -> OOM

# 修复：预留 20% 给系统
java \
  -XX:+UseContainerSupport \
  -XX:MaxRAMPercentage=75.0 \
  -XX:InitialRAMPercentage=75.0 \
  -jar myapp.jar

# 或显式设置（推荐）
java \
  -XX:+UseContainerSupport \
  -Xmx3g -Xms3g \
  -XX:MaxDirectMemorySize=512m \
  -XX:MaxMetaspaceSize=256m \
  -jar myapp.jar
# 总内存使用约 3g + 512m + 256m + 预留 = ~4g
# 对应 Pod Limit 应设为 5-6Gi

# === 方案 2：统一集群 Cgroup 版本 ===

# 检查节点 Cgroup 版本
cat /proc/filesystems | grep cgroup
# node1: cgroup2
# node2: cgroup

# 统一为 Cgroup v2：
# 1. 确保内核 >= 4.15（推荐 >= 5.x）
uname -r
# 5.15.0

# 2. 修改 GRUB
cat > /etc/default/grub.d/cgroup.cfg <<'EOF'
GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1"
EOF
update-grub

# 3. 重启节点
reboot

# 4. 验证
stat -fc %T /sys/fs/cgroup
# cgroup2fs

# 注意：
# - 混合集群会导致行为不一致
# - 建议在集群初始化时统一版本
# - K8s 1.25+ 推荐 v2
```

---

## 五、面试要点

```
Q: Java 应用在 K8s 中为什么经常 CPU throttled？

A: 根本原因：
   1. JVM 默认使用 Runtime.availableProcessors() 设置线程池大小
   2. 旧版 JVM（<10u191）看到的是宿主机 CPU 数
   3. 容器限制 2 核，但 JVM 创建 64 个线程
   4. CFS 每 100ms 周期分配 quota
   5. 64 个线程竞争 200ms CPU 时间
   6. 大量线程被 throttle
   
   解决：
   1. 升级 JDK 到 10u191+ 或 17+（支持容器感知）
   2. 显式设置 -XX:ActiveProcessorCount=2
   3. 调整各线程池大小（ForkJoinPool、GC 线程）
   4. 增大 CPU Limit 或去掉 Limit（只设 Request）

Q: Cgroup v2 相比 v1 在内存统计上有什么变化？

A: 
   v1 memory.limit_in_bytes：
   - 只统计 rss + cache（page cache）
   - 不包含 kernel 内存（slab、shmem）
   - 实际限制比看起来宽松
   
   v2 memory.max：
   - 包含所有内存类型
   - 包括 kernel 内存、page cache、shmem、sock
   - 更严格，可能导致 v1 正常但 v2 OOM
   
   实践建议：
   - 统一集群 Cgroup 版本
   - v2 环境下预留 10-20% 内存给系统
   - 监控 memory.stat 中各分项

Q: 为什么 Go 应用在 Cgroup v2 下会出现 "failed to create new OS thread"？

A:
   1. K8s 默认设置 pod pids limit = 1024
   2. Go runtime 在 goroutine 阻塞时创建新 OS 线程
   3. 高并发时线程数达到 1024 上限
   4. 无法再创建新线程
   5. 返回 EAGAIN 错误
   
   解决：
   1. 增大 kubelet podPidsLimit（如 4096）
   2. 限制 goroutine 并发数（使用 channel 信号量）
   3. 设置 GOMAXPROCS 限制并行度
   4. 检查是否有 goroutine 泄露

Q: 如何诊断容器内的 Cgroup 配置？

A:
   1. 确认 Cgroup 版本：stat -fc %T /sys/fs/cgroup
   2. v1: 查看 /sys/fs/cgroup/cpu/, /memory/, /pids/ 下的文件
   3. v2: 查看 /sys/fs/cgroup/ 下的 cgroup.controllers, cpu.max, memory.max 等
   4. 检查 CPU throttle: cat cpu.stat | grep throttled
   5. 检查线程限制: cat pids.current vs pids.max
   6. 检查内存限制: cat memory.limit_in_bytes (v1) 或 memory.max (v2)
```

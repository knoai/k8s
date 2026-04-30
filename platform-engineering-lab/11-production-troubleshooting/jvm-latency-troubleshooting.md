# 生产排障：JVM 延迟深度排查

> Java 应用在生产环境中的延迟问题，80% 与 JVM 运行时行为相关。
> 本节从 GC、JIT、线程池、容器化四个维度，提供系统化的诊断和调优方法。

---

## 一、JVM 延迟来源分层

```
请求延迟 = 业务逻辑 + JVM 运行时 + 容器运行时 + 系统层

┌─────────────────────────────────────────┐
│  业务逻辑层（0-100ms）                   │
│   - 算法复杂度                          │
│   - 数据库查询                          │
│   - 外部服务调用                        │
│   ← 优化：代码层面                      │
├─────────────────────────────────────────┤
│  JVM 运行时层（0-50ms，异常时 >1s）     │
│   - GC 停顿（Young/Full）               │
│   - JIT 编译（C1/C2）                   │
│   - 线程安全（锁竞争）                  │
│   - 类加载                              │
│   ← 优化：JVM 参数 + 代码优化            │
├─────────────────────────────────────────┤
│  容器运行时层（0-5ms，异常时 >50ms）    │
│   - CPU Throttling                      │
│   - 内存限制导致 OOM/_swap              │
│   - 容器内资源感知（cgroup v1/v2）      │
│   ← 优化：资源限制 + 容器感知 JVM        │
├─────────────────────────────────────────┤
│  系统层（0-1ms，异常时 >10ms）          │
│   - CPU steal time                      │
│   - 磁盘 IO                             │
│   - 网络延迟                            │
│   ← 优化：基础设施层面                   │
└─────────────────────────────────────────┘
```

---

## 二、GC 停顿诊断与调优

### 2.1 GC 类型对比

```
┌──────────┬─────────────┬─────────────┬─────────────┬─────────────┐
│ GC 类型  │ 适用场景    │ 延迟特点    │ 吞吐量    │ 内存开销   │
├──────────┼─────────────┼─────────────┼─────────────┼─────────────┤
│ Serial   │ 单核/客户端 │ STW 长      │ 低         │ 低         │
│ Parallel │ 批处理      │ STW 长      │ 高         │ 中         │
│ CMS      │ 低延迟(旧)  │ 并发收集    │ 中         │ 高         │
│ G1GC     │ 大堆(默认)  │ 可预测暂停  │ 高         │ 中         │
│ ZGC      │ 超大堆(<16T)│ <1ms 暂停   │ 高         │ 中高       │
│ Shenandoah│ 超大堆     │ <10ms 暂停  │ 高         │ 中         │
└──────────┴─────────────┴─────────────┴─────────────┴─────────────┘

JDK 版本默认 GC：
  - JDK 8：Parallel GC（-XX:+UseParallelGC）
  - JDK 9-16：G1GC（-XX:+UseG1GC）
  - JDK 17+：G1GC（默认）
  
生产推荐：
  - 堆 < 4G：G1GC
  - 堆 4G-32G：G1GC（调优 MaxGCPauseMillis）
  - 堆 > 32G：ZGC（JDK 15+）或 Shenandoah
```

### 2.2 GC 日志分析

```bash
# === 开启 GC 日志 ===
# JDK 8:
# -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:/logs/gc.log
# -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=100M

# JDK 11+:
# -Xlog:gc*:file=/logs/gc.log:time:filecount=10,filesize=100m

# === 分析 GC 日志 ===
# 使用 GCViewer 或 gceasy.io 在线分析

# 典型 GC 日志（G1GC）：
# [2024-01-15T08:30:00.123+0000][info][gc] GC(1234) Pause Young (Normal) (G1 Evacuation Pause) 12M->8M(256M) 12.345ms
# [2024-01-15T08:30:05.456+0000][info][gc] GC(1235) Pause Young (Normal) (G1 Evacuation Pause) 15M->9M(256M) 8.234ms
# [2024-01-15T08:30:10.789+0000][info][gc] GC(1236) Pause Young (Concurrent Start) (G1 Humongous Allocation) 200M->180M(256M) 25.678ms
# [2024-01-15T08:30:11.123+0000][info][gc] GC(1237) Concurrent Cycle
# [2024-01-15T08:30:12.456+0000][info][gc] GC(1237) Pause Remark 180M->170M(256M) 5.678ms
# [2024-01-15T08:30:13.789+0000][info][gc] GC(1237) Pause Cleanup 170M->160M(256M) 1.234ms
# [2024-01-15T08:30:14.123+0000][info][gc] GC(1237) Concurrent Cycle 2345.678ms

# 日志字段解读：
# GC(1234)              - GC 编号
# Pause Young           - Young GC（年轻代回收）
# Pause Full            - Full GC（全堆回收）
# Pause Remark          - 并发标记后的重新标记（STW）
# Pause Cleanup         - 清理阶段（STW）
# 12M->8M(256M)         - GC 前堆使用 -> GC 后堆使用（总堆大小）
# 12.345ms              - STW 暂停时间

# === 使用 jstat 实时监控 ===
jstat -gcutil <pid> 1000 10

# 输出：
#   S0     S1     E      O      M     CCS    YGC     YGCT    FGC    FGCT     GCT
#   0.00  12.34  45.67  34.56  98.12  95.67    234    2.345    0     0.000   2.345
#   12.34  0.00  23.45  35.67  98.12  95.67    235    2.360    0     0.000   2.360
#   0.00  15.67  56.78  36.89  98.12  95.67    236    2.380    0     0.000   2.380

# 字段解读：
# S0/S1：Survivor 0/1 区使用率
# E：Eden 区使用率
# O：Old 区（老年代）使用率
# M：Metaspace 使用率
# CCS：Compressed Class Space 使用率
# YGC：Young GC 次数
# YGCT：Young GC 总耗时（秒）
# FGC：Full GC 次数
# FGCT：Full GC 总耗时（秒）
# GCT：GC 总耗时（秒）

# === 危险信号 ===
# 1. FGC 频繁增长
#    FGC 从 0 → 10（10 分钟内）
#    原因：老年代空间不足，或内存泄漏

# 2. O（老年代）使用率持续上升
#    O: 30% → 50% → 70% → 85% → 90%
#    原因：对象生命周期过长，或内存泄漏

# 3. Eden 区经常 90%+
#    E: 90%+ 持续出现
#    原因：年轻代太小，或对象创建过快

# 4. YGCT 增长过快
#    YGCT: 2.3s → 45.6s（10 分钟内）
#    原因：Young GC 过于频繁
```

### 2.3 GC 调优实战

```bash
# === 场景 1：Young GC 频繁 ===
# 症状：每秒 1-2 次 Young GC，每次 20-50ms
# 原因：年轻代太小

# 优化前参数：
# -Xms2g -Xmx2g -XX:+UseG1GC
# G1 默认年轻代 = 总堆的 5-60%（动态调整）
# 如果应用创建大量短生命周期对象，可能年轻代不够

# 优化后参数：
JAVA_OPTS="-XX:+UseG1GC
  -XX:G1NewSizePercent=30        # 年轻代最小 30%
  -XX:G1MaxNewSizePercent=60      # 年轻代最大 60%
  -XX:MaxGCPauseMillis=100        # 目标 GC 暂停 100ms
  -Xms4g -Xmx4g                   # 增大堆内存
  -XX:+ParallelRefProcEnabled     # 并行处理引用
  -XX:+AlwaysPreTouch             # 启动时预分配内存"

# === 场景 2：Full GC 频繁 ===
# 症状：每 5-10 分钟一次 Full GC，每次 1-3 秒
# 原因：老年代空间不足，或内存泄漏

# 诊断：
# 1. 查看堆 dump
jmap -dump:format=b,file=/tmp/heapdump.hprof <pid>

# 2. 使用 MAT（Eclipse Memory Analyzer）分析
# 查找 Dominator Tree，找到最大的对象

# 3. 常见内存泄漏：
#    - 静态 Map/Collection 无限增长
#    - 未关闭的资源（连接、流、监听器）
#    - 缓存未设置 TTL
#    - ThreadLocal 未清理

# 优化：
# 1. 增大堆内存
# 2. 修复内存泄漏
# 3. 启用 GC 日志分析
JAVA_OPTS="-XX:+UseG1GC
  -XX:InitiatingHeapOccupancyPercent=35  # 提前触发并发标记
  -XX:G1HeapRegionSize=16m               # 增大 Region 大小
  -Xms8g -Xmx8g
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath=/logs/heapdump.hprof
  -Xlog:gc*:file=/logs/gc.log:time:filecount=10,filesize=100m"

# === 场景 3：超大堆（>32G）低延迟 ===
# 症状：堆 64G，GC 停顿 500ms-2s
# 解决方案：使用 ZGC

JAVA_OPTS="-XX:+UseZGC
  -XX:+ZGenerational                    # 分代 ZGC（JDK 21+）
  -Xms64g -Xmx64g
  -XX:SoftMaxHeapSize=50g               # 软最大堆
  -XX:+AlwaysPreTouch
  -XX:+DisableExplicitGC                # 禁止 System.gc()
  -Xlog:gc*:file=/logs/gc.log:time:filecount=10,filesize=100m"

# ZGC 特点：
# - 暂停时间 < 1ms（与堆大小无关）
# - 支持 16TB 堆
# - JDK 15+ 可用，JDK 21+ 分代 ZGC
# - 吞吐量略低于 G1（约 95%）
```

---

## 三、JIT 编译诊断

### 3.1 JIT 编译过程

```
JIT 编译层级：

Level 0：解释执行
  - 代码首次执行
  - 收集调用次数、循环次数
  
Level 1：C1 编译（客户端编译器）
  - 调用次数 > 1500
  - 简单优化（方法内联、常量传播）
  - 编译速度快，代码质量一般
  
Level 2：C1 编译 + 更多优化
  - 调用次数 > 10000
  - 增加 profiling
  
Level 3：C1 编译 + 完整 profiling
  - 为 C2 编译收集数据
  
Level 4：C2 编译（服务端编译器）
  - 调用次数 > 10000 + 足够 profiling 数据
  - 激进优化（逃逸分析、锁消除、向量化）
  - 编译速度慢，代码质量最高

编译阈值参数：
  -XX:Tier3InvocationThreshold=200     # C1 编译阈值
  -XX:Tier4InvocationThreshold=10000   # C2 编译阈值
  -XX:CompileThreshold=10000            # 旧版参数
```

### 3.2 JIT 相关延迟

```bash
# 症状：应用启动后前几分钟延迟高，之后稳定
# 原因：JIT 编译期间 CPU 占用高，且方法在解释执行

# 诊断：
# 1. 查看 JIT 编译日志
-XX:+PrintCompilation
#    123   45%     3       java.lang.String::hashCode @ 13 (55 bytes)
#    124   46       3       java.util.ArrayList::get (11 bytes)
#    125   47       4       java.util.HashMap::getNode (148 bytes)
#    126   48%     4       java.util.HashMap::get @ 2 (23 bytes)

# 2. 查看 CodeCache 使用
jstat -compiler <pid>
# Compiled  Compiled  Failed  Invalid   Time   FailedType FailedMethod
#    12345     12345       0        0   45.67          0

# CodeCache 满时：
# Compiled  Compiled  Failed  Invalid   Time   FailedType FailedMethod
#    12345     12000     345        0  123.45          1    java/lang/String.hashCode
# ← 345 个方法编译失败！

# 3. 查看哪些方法在编译
-XX:+LogCompilation
# 输出到 hotspot_pid.log，需要 hsdis 工具分析

# 优化方案：
# 1. 增大 CodeCache
-XX:ReservedCodeCacheSize=512m  # 默认 240m

# 2. 使用 AOT 编译（JDK 9+）
# jaotc --output libHelloWorld.so HelloWorld.class
# -XX:AOTLibrary=./libHelloWorld.so

# 3. 预热（Warmup）
# 应用启动后，发送预热请求，触发 JIT 编译
# 预热脚本：
for i in $(seq 1 10000); do
  curl -s http://localhost:8080/api/health > /dev/null
done

# 4. 使用 CDS（Class Data Sharing）
# -XX:+UseSharedSpaces
# 减少类加载时间
```

---

## 四、线程池与锁竞争

### 4.1 线程池诊断

```bash
# 查看线程状态
jstack <pid> | grep "java.lang.Thread.State" | sort | uniq -c | sort -rn

# 健康状态：
#    30 java.lang.Thread.State: RUNNABLE
#    10 java.lang.Thread.State: WAITING (parking)
#     5 java.lang.Thread.State: TIMED_WAITING (sleeping)
#     2 java.lang.Thread.State: BLOCKED (on object monitor)
# ← BLOCKED 线程很少，健康

# 问题状态：
#    45 java.lang.Thread.State: BLOCKED (on object monitor)
#    20 java.lang.Thread.State: WAITING (parking)
#    10 java.lang.Thread.State: RUNNABLE
# ← 大量 BLOCKED 线程！锁竞争严重！

# 查看 BLOCKED 线程详情
jstack <pid> | grep -A 5 "BLOCKED"
# "http-nio-8080-exec-15" #78 prio=5 os_prio=0 cpu=1234.56ms elapsed=600.00s tid=0x00007f123456789 nid=0x1a2b waiting for monitor entry [0x00007f1234567000]
#    java.lang.Thread.State: BLOCKED (on object monitor)
#         at com.company.cache.LocalCache.get(LocalCache.java:123)
#         - waiting to lock <0x00000000d1234567> (a java.util.HashMap)
#         at com.company.service.OrderService.getOrder(OrderService.java:45)
# ← LocalCache.java:123 的 HashMap 是瓶颈！

# 优化：
# 1. HashMap → ConcurrentHashMap
# 2. 缩小锁粒度
# 3. 使用读写锁（ReentrantReadWriteLock）
# 4. 无锁数据结构（AtomicLong, LongAdder）
```

### 4.2 线程池配置

```java
// 生产环境线程池配置

// Tomcat 线程池
server.tomcat.threads.max=200              // 最大线程数
server.tomcat.threads.min-spare=20         // 最小空闲线程
server.tomcat.accept-count=100             // 连接队列长度
server.tomcat.max-connections=10000        // 最大连接数
server.tomcat.connection-timeout=20000     // 连接超时 20s

// HikariCP 连接池
spring.datasource.hikari.maximum-pool-size=50
spring.datasource.hikari.minimum-idle=10
spring.datasource.hikari.connection-timeout=5000       // 5s
spring.datasource.hikari.idle-timeout=300000           // 5min
spring.datasource.hikari.max-lifetime=1200000          // 20min
spring.datasource.hikari.leak-detection-threshold=60000 // 60s

// 业务线程池
@Bean
public ThreadPoolExecutor businessExecutor() {
    return new ThreadPoolExecutor(
        10,                          // 核心线程数
        50,                          // 最大线程数
        60L, TimeUnit.SECONDS,       // 空闲线程存活时间
        new LinkedBlockingQueue<>(1000), // 队列容量
        new ThreadFactoryBuilder().setNameFormat("business-%d").build(),
        new ThreadPoolExecutor.CallerRunsPolicy() // 拒绝策略
    );
}

// 拒绝策略选择：
// AbortPolicy：直接抛出异常（默认）
// CallerRunsPolicy：由调用线程执行任务
// DiscardPolicy：静默丢弃任务
// DiscardOldestPolicy：丢弃队列最老的任务
```

---

## 五、容器化 JVM 陷阱

### 5.1 容器资源感知

```
JVM 容器化问题：

JDK 8u131 之前：
  - JVM 无法感知容器资源限制
  - 读取的是宿主机 CPU/内存
  - 结果：
    * 宿主机 64 核，容器 limit=2 核
    * JVM 认为有 64 核，启动 64 个 GC 线程
    * 严重 CPU throttling

JDK 8u131+ / JDK 9+：
  - 添加 -XX:+UseContainerSupport
  - JVM 读取 cgroup 限制
  - 默认启用（JDK 10+）

JDK 8u191+ / JDK 10+：
  - 自动感知容器资源
  - 无需额外参数

验证：
  Runtime.getRuntime().availableProcessors()
  // JDK 8u131 之前：返回宿主机 CPU 数
  // JDK 8u191+：返回容器 CPU limit
```

### 5.2 容器 JVM 参数最佳实践

```bash
# 生产环境容器 JVM 参数模板

# === 基础参数 ===
JAVA_OPTS="-server
  # GC 选择
  -XX:+UseG1GC
  -XX:MaxGCPauseMillis=200
  
  # 堆内存（根据容器 limit 设置）
  # 容器 limit=4G，JVM 堆占 70-75%
  -XX:MaxRAMPercentage=75.0
  -XX:InitialRAMPercentage=75.0
  
  # 容器感知（JDK 8u131+ 需要显式开启）
  -XX:+UseContainerSupport
  
  # 线程数（根据容器 CPU limit）
  -XX:ActiveProcessorCount=2
  
  # GC 线程数（避免过多）
  -XX:ParallelGCThreads=2
  -XX:ConcGCThreads=1
  
  # OOM 时生成堆 dump
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath=/logs/heapdump.hprof
  
  # GC 日志（JDK 11+）
  -Xlog:gc*:file=/logs/gc.log:time:filecount=10,filesize=100m
  
  # 编码优化
  -Dfile.encoding=UTF-8
  -Dsun.jnu.encoding=UTF-8
  
  # 随机数生成器（避免启动阻塞）
  -Djava.security.egd=file:/dev/./urandom
  
  # 时区
  -Duser.timezone=Asia/Shanghai
"

# === 示例：容器 limit=4G CPU=2 ===
# 堆内存 = 4G * 75% = 3G
# GC 线程 = 2（与 CPU limit 一致）
# 并行线程 = 2

# === 诊断容器 JVM 问题 ===
# 1. 查看 JVM 感知的资源
kubectl exec <pod> -- java -XX:+PrintFlagsFinal -version | grep -E "MaxHeapSize|MaxRAM|ParallelGCThreads|ConcGCThreads"

# 2. 查看实际堆使用
kubectl exec <pod> -- jmap -heap 1

# 3. 查看 GC 线程数
kubectl exec <pod> -- jstack 1 | grep -c "GC Thread"
```

---

## 六、一键诊断脚本

```bash
#!/bin/bash
# jvm-health-check.sh <pod-name> <namespace>

POD=${1:-}
NS=${2:-default}

if [ -z "$POD" ]; then
  echo "Usage: $0 <pod-name> [namespace]"
  exit 1
fi

echo "=========================================="
echo "  JVM 健康检查: $NS/$POD"
echo "=========================================="

# 获取进程 ID
PID=$(kubectl exec $POD -n $NS -- sh -c 'ps -ef | grep java | grep -v grep | awk "{print \$2}"' 2>/dev/null)
if [ -z "$PID" ]; then
  echo "未找到 Java 进程"
  exit 1
fi
echo "Java PID: $PID"

echo ""
echo "=== 1. JVM 版本和参数 ==="
kubectl exec $POD -n $NS -- java -version 2>&1
kubectl exec $POD -n $NS -- sh -c "ps -ef | grep java | grep -v grep" | awk '{for(i=9;i<=NF;i++) print $i}'

echo ""
echo "=== 2. 堆内存使用 ==="
kubectl exec $POD -n $NS -- jstat -gcutil $PID 2>/dev/null | head -2

echo ""
echo "=== 3. GC 统计 ==="
kubectl exec $POD -n $NS -- jstat -gc $PID 2>/dev/null | tail -1 | awk '
{
  print "S0: " $1 "%"
  print "S1: " $2 "%"
  print "E: " $3 "%"
  print "O: " $4 "%"
  print "M: " $5 "%"
  print "YGC: " $8
  print "YGCT: " $9 "s"
  print "FGC: " $10
  print "FGCT: " $11 "s"
  print "GCT: " $12 "s"
}'

echo ""
echo "=== 4. 线程状态 ==="
kubectl exec $POD -n $NS -- jstack $PID 2>/dev/null | grep "java.lang.Thread.State" | sort | uniq -c | sort -rn

echo ""
echo "=== 5. BLOCKED 线程 ==="
BLOCKED=$(kubectl exec $POD -n $NS -- jstack $PID 2>/dev/null | grep -c "BLOCKED")
echo "BLOCKED 线程数: $BLOCKED"
if [ "$BLOCKED" -gt 5 ]; then
  echo "⚠️  警告：存在大量 BLOCKED 线程"
  kubectl exec $POD -n $NS -- jstack $PID 2>/dev/null | grep -B 2 "BLOCKED" | head -20
fi

echo ""
echo "=== 6. 死锁检测 ==="
kubectl exec $POD -n $NS -- jstack -l $PID 2>/dev/null | grep -A 5 "Found one Java-level deadlock"

echo ""
echo "=== 7. CodeCache ==="
kubectl exec $POD -n $NS -- jstat -compiler $PID 2>/dev/null

echo ""
echo "=== 8. 类加载 ==="
kubectl exec $POD -n $NS -- jstat -class $PID 2>/dev/null

echo ""
echo "=========================================="
echo "  检查完成"
echo "=========================================="
```

---

## 七、面试要点

```
Q: G1GC 和 ZGC 的区别？如何选择？

A: 
   G1GC：
   - 目标：可预测的暂停时间（默认 200ms）
   - 适用：堆 4G-32G
   - 特点：
     * 分代收集（年轻代 + 老年代）
     * Region 化内存管理
     * 并发标记
   - JDK 8+ 可用
   
   ZGC：
   - 目标：< 1ms 暂停（与堆大小无关）
   - 适用：堆 > 32G，或极致低延迟
   - 特点：
     * 并发压缩
     * 染色指针
     * 读屏障
   - JDK 15+ 可用，JDK 21+ 分代 ZGC
   
   选择：
   - 一般应用：G1GC
   - 超大堆 + 低延迟：ZGC
   - JDK 8：只能 G1GC（ZGC 不可用）

Q: 如何排查 Java 内存泄漏？

A: 五步排查法：

   1. 确认泄漏：
      - jstat -gcutil 观察 O（老年代）持续增长
      - Full GC 后内存不下降
   
   2. 生成堆 dump：
      - jmap -dump:format=b,file=... <pid>
      - 或 -XX:+HeapDumpOnOutOfMemoryError
   
   3. 分析 dump：
      - 使用 MAT（Eclipse Memory Analyzer）
      - 查找 Dominator Tree
      - 查看 Histogram，找最大的对象
   
   4. 定位泄漏源：
      - 查找 GC Roots
      - 确定谁持有引用
   
   5. 修复：
      - 清理静态集合
      - 关闭资源（try-with-resources）
      - 设置缓存 TTL
      - 使用 WeakReference

Q: JVM 在容器中为什么需要特殊配置？

A: 核心问题：JVM 默认读取宿主机资源，而非容器限制

   CPU 问题：
   - JDK 8u131 之前：availableProcessors() 返回宿主机 CPU
   - 容器 limit=2 核，JVM 启动 32 个 GC 线程
   - 结果：严重 CPU throttling
   - 修复：-XX:+UseContainerSupport（JDK 8u191+ 自动）
   
   内存问题：
   - JVM 默认使用物理内存的 1/4 作为堆
   - 容器 limit=4G，宿主机 64G
   - JVM 申请 16G 堆，触发 OOMKilled
   - 修复：-XX:MaxRAMPercentage=75.0
   
   最佳实践：
   - 使用 JDK 11+（容器感知完善）
   - 显式设置堆内存百分比
   - 限制 GC 线程数
   - 监控容器实际资源使用
```

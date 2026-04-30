# 实战项目 4：JVM 应用性能诊断

> 目标：部署不同 JVM 配置的 Java 应用，模拟 GC 停顿、内存泄漏、线程死锁等问题，通过工具链系统化诊断。
> Java 应用在 K8s 中的性能问题通常与 JVM 对容器环境的"认知不足"有关。

---

## 实验架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    JVM 诊断实验环境                               │
│                                                                 │
│  ┌──────────────────────────┐  ┌──────────────────────────┐   │
│  │      App A（健康基线）    │  │      App B（问题注入）    │   │
│  │  ├─ JDK 17               │  │  ├─ JDK 8                │   │
│  │  ├─ G1GC                 │  │  ├─ ParallelGC           │   │
│  │  ├─ -XX:+UseContainerSupport│ │  ├─ 无容器感知参数     │   │
│  │  ├─ -Xmx1536m (75% of 2Gi)│ │  ├─ -Xmx512m (未感知容器)│   │
│  │  ├─ CPU limit: 2         │  │  ├─ CPU limit: 0.5      │   │
│  │  ├─ 连接池: Hikari max=20│  │  ├─ 连接池: Hikari max=3│   │
│  │  └─ 无内存泄漏           │  │  ├─ 内存泄漏: 静态 Map  │   │
│  │                          │  │  └─ 死锁: 两线程互等     │   │
│  └──────────────────────────┘  └──────────────────────────┘   │
│                                                                 │
│  诊断工具：                                                     │
│  • jstat / jmap / jstack（JDK 自带）                           │
│  • async-profiler（火焰图）                                    │
│  • Arthas（生产环境诊断）                                       │
│  • JMX Exporter + Prometheus                                   │
│  • Grafana JVM Dashboard                                       │
│                                                                 │
│  暴露端点：                                                     │
│  • /actuator/prometheus  -> JVM 指标                           │
│  • /actuator/health      -> 健康检查                           │
│  • /api/memory-leak      -> 触发内存泄漏                       │
│  • /api/deadlock         -> 触发死锁                           │
│  • /api/gc-pressure      -> 触发 GC 压力                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 前置要求

```bash
# 硬件
CPU: 6 核+
内存: 12GB+
磁盘: 20GB

# 软件
docker --version     # 24.0+
kind --version       # 0.20+
kubectl version --client  # 1.28+
java -version        # 17（构建用）
mvn -version         # 3.9+

# 可选诊断工具
# async-profiler: https://github.com/jvm-profiling-tools/async-profiler
# arthas: https://arthas.aliyun.com/
```

---

## 实验步骤详解

### 步骤 1：构建测试应用

```bash
cd platform-engineering-lab/10-practice-projects/project-4-jvm-diagnose/java-perf-app

# 构建应用
mvn clean package -DskipTests

# 构建 Docker 镜像
docker build -t java-perf-app:latest .

# 加载到 Kind
kind load docker-image java-perf-app:latest --name jvm-lab

# 镜像内部 Dockerfile 关键配置（供参考）：
# FROM eclipse-temurin:17-jre-alpine
# COPY target/*.jar app.jar
# ENTRYPOINT ["java", "-jar", "/app.jar"]
```

### 步骤 2：部署实验环境

```bash
cd ..  # 回到 project-4-jvm-diagnose 目录

# 一键部署
bash deploy-jvm-lab.sh

# 验证部署
kubectl get pods -n jvm-lab
# NAME                     READY   STATUS    RESTARTS   AGE
# app-a-7d8f9b2c4-x1a2b    1/1     Running   0          2m
# app-b-7d8f9b2c4-y3c4d    1/1     Running   0          2m
# prometheus-0             1/1     Running   0          3m
# grafana-0                1/1     Running   0          3m

# 暴露端口
kubectl port-forward svc/app-a -n jvm-lab 8080:8080 &
kubectl port-forward svc/app-b -n jvm-lab 8081:8080 &

# 验证 API
curl -s http://localhost:8080/actuator/health | jq .
# {"status":"UP"}

curl -s http://localhost:8081/actuator/health | jq .
# {"status":"UP"}
```

### 步骤 3：基线采集（App A 健康状态）

```bash
# 运行基线诊断
./diagnose-jvm.sh app-a

# 脚本内部执行及预期输出：

# 1. JVM 版本和参数
kubectl exec -it deploy/app-a -n jvm-lab -- ps aux | grep java
# java -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0
#      -XX:+UseG1GC -Xlog:gc*:file=/tmp/gc.log
#      -Djava.security.egd=file:/dev/./urandom -jar /app.jar
# 关键：UseContainerSupport=true, G1GC, MaxRAMPercentage=75

# 2. GC 状态（jstat）
kubectl exec -it deploy/app-a -n jvm-lab -- jstat -gc 1 1s 5
#  S0C    S1C    S0U    S1U      EC       EU        OC         OU       MC
#  0.0   2048.0  0.0   2048.0  13312.0   4096.0    34816.0    8192.0   44800.0
#  0.0   2048.0  0.0   2048.0  13312.0   5120.0    34816.0    8192.0   44800.0
#  0.0   2048.0  0.0   2048.0  13312.0   6144.0    34816.0    8192.0   44800.0
# 指标解读：
#   S0C/S1C: Survivor 区容量 2048KB
#   EC/EU: Eden 区容量/已用
#   OC/OU: Old 区容量/已用
#   OU/OC = 8192/34816 = 23.5%（健康）

# 3. 堆内存详情（jmap -heap）
kubectl exec -it deploy/app-a -n jvm-lab -- jmap -heap 1
# Heap Configuration:
#    MinHeapFreeRatio         = 40
#    MaxHeapFreeRatio         = 70
#    MaxHeapSize              = 1610612736 (1536.0MB)  <- 75% of 2Gi limit
#    NewSize                  = 35651584 (34.0MB)
#    MaxNewSize               = 536870912 (512.0MB)

# 4. 线程状态（jstack）
kubectl exec -it deploy/app-a -n jvm-lab -- jstack 1 | grep -E "java.lang.Thread.State" | sort | uniq -c
#   1 java.lang.Thread.State: RUNNABLE
#  15 java.lang.Thread.State: TIMED_WAITING
#   5 java.lang.Thread.State: WAITING
# 无 BLOCKED 线程（健康）

# 5. GC 日志分析
kubectl exec -it deploy/app-a -n jvm-lab -- cat /tmp/gc.log | tail -10
# [2024-01-01T12:00:01.234+0000] GC(12) Pause Young (Normal) (G1 Evacuation Pause)
# [2024-01-01T12:00:01.235+0000] GC(12) Using 2 workers of 2 for evacuation
# [2024-01-01T12:00:01.238+0000] GC(12) Pause Young (Normal) (G1 Evacuation Pause) 45M->12M(1536M) 3.456ms
# 关键指标：Young GC 耗时 3.456ms（< 10ms 优秀）

# 6. 压测基线
curl -s http://localhost:8080/actuator/prometheus | grep jvm_memory_used_bytes
# jvm_memory_used_bytes{area="heap",id="G1 Old Gen"} 8388608.0
# jvm_memory_used_bytes{area="heap",id="G1 Eden Space"} 4194304.0
# jvm_memory_used_bytes{area="nonheap",id="Metaspace"} 47185920.0
```

### 步骤 4：App B 问题诊断

```bash
# 运行问题诊断
./diagnose-jvm.sh app-b

# 脚本内部执行及预期输出：

# 1. JVM 版本和参数
kubectl exec -it deploy/app-b -n jvm-lab -- ps aux | grep java
# java -Xmx512m -jar /app.jar
# 问题：
#   - JDK 8（无 UseContainerSupport 默认支持）
#   - 手动指定 -Xmx512m（未感知容器限制）
#   - 无 GC 日志配置
#   - ParallelGC（JDK 8 默认，不是 G1GC）

# 2. GC 状态（jstat）
kubectl exec -it deploy/app-b -n jvm-lab -- jstat -gc 1 1s 10
#  S0C    S1C    S0U    S1U      EC       EU        OC         OU       MC
#  64.0   64.0   0.0    64.0    512.0    512.0     448.0      448.0    32000.0
#  64.0   64.0   0.0    64.0    512.0    512.0     448.0      448.0    32000.0
#  ...
# 关键指标：
#   OC=448KB, OU=448KB → Old 区已满！
#   EC=512KB, EU=512KB → Eden 区已满！
#   频繁触发 Full GC！

# 3. GC 日志（应用日志中）
kubectl logs -n jvm-lab deploy/app-b | grep -E "Full GC|GC pause" | tail -10
# [Full GC (Ergonomics) [PSYoungGen: 512K->0K(576K)] [ParOldGen: 448K->384K(448K)] 960K->384K(1024K), [Metaspace: 32000K->32000K(32000K)], 0.2345678 secs] [Times: user=0.45 sys=0.01, real=0.23 secs]
# [Full GC (Ergonomics) [PSYoungGen: 512K->0K(576K)] [ParOldGen: 448K->416K(448K)] 960K->416K(1024K), [Metaspace: 32000K->32000K(32000K)], 0.1987654 secs] [Times: user=0.42 sys=0.01, real=0.20 secs]
# 关键指标：
#   Full GC 耗时 200-230ms！
#   频率：每 5-10 秒一次！
#   ParallelGC 使用多线程，但 STW 时间长

# 4. 线程状态（jstack）
kubectl exec -it deploy/app-b -n jvm-lab -- jstack 1 | grep -E "java.lang.Thread.State" | sort | uniq -c
#   1 java.lang.Thread.State: BLOCKED
#   1 java.lang.Thread.State: RUNNABLE
#  12 java.lang.Thread.State: TIMED_WAITING
#   2 java.lang.Thread.State: WAITING
# 发现：1 个 BLOCKED 线程！

# 查看 BLOCKED 线程详情
kubectl exec -it deploy/app-b -n jvm-lab -- jstack 1 | grep -A 20 "BLOCKED"
# "http-nio-8080-exec-5" #25 prio=5 os_prio=0 cpu=1234.56ms elapsed=120.45s tid=0x00007f123456789 nid=0x1f waiting for monitor entry [0x00007f123abcdef]
#    java.lang.Thread.State: BLOCKED (on object monitor)
#         at com.example.service.OrderService.processOrder(OrderService.java:45)
#         - waiting to lock <0x00000000d5f01234> (a java.lang.Object)
#         at com.example.controller.OrderController.createOrder(OrderController.java:23)
# 根因：线程在等待锁，可能存在死锁！

# 5. 检查死锁
kubectl exec -it deploy/app-b -n jvm-lab -- jstack 1 | grep -A 50 "Found one Java-level deadlock"
# Found one Java-level deadlock:
# =============================
# "Thread-1":
#   waiting to lock monitor 0x00007f1234560000 (object 0x00000000d5f01234, a java.lang.Object),
#   which is held by "Thread-2"
# "Thread-2":
#   waiting to lock monitor 0x00007f1234560001 (object 0x00000000d5f05678, a java.lang.Object),
#   which is held by "Thread-1"
# 确认：存在死锁！

# 6. 内存泄漏检查（jmap -histo）
kubectl exec -it deploy/app-b -n jvm-lab -- jmap -histo 1 | head -20
#  num     #instances         #bytes  class name
# ----------------------------------------------
#    1:       1234567      987653600  [B
#    2:        234567      234567000  java.lang.String
#    3:        100000      160000000  com.example.cache.LeakEntry  <- 泄漏类！
#    4:         87654      123456789  java.util.HashMap$Node
# 根因：LeakEntry 实例 10 万个，占用 160MB！

# 7. 连接池状态
kubectl logs -n jvm-lab deploy/app-b | grep -i "HikariPool" | tail -5
# DEBUG c.z.h.p.HikariPool - HikariPool-1 - Pool stats (total=3, active=3, idle=0, waiting=12)
# 连接池 max=3，全部在用，12 个请求等待！
```

### 步骤 5：使用 Arthas 实时诊断

```bash
# 进入 App B Pod
kubectl exec -it deploy/app-b -n jvm-lab -- /bin/sh

# 下载 Arthas（如果镜像中未包含）
wget https://arthas.aliyun.com/arthas-boot.jar
java -jar arthas-boot.jar 1

# Arthas 命令示例：

# 1. 查看线程状态
[arthas@1]$ thread -n 5
# "http-nio-8080-exec-1" Id=21 RUNNABLE
# "http-nio-8080-exec-2" Id=22 BLOCKED
# "http-nio-8080-exec-3" Id=23 WAITING
# ...

# 2. 查看 GC 情况
[arthas@1]$ jvm
# HEAP-MEMORY-USAGE             96000000/536870912 (17.86%)
# NO-HEAP-MEMORY-USAGE          32500000/... (...)
# GARBAGE-COLLECTORS:
#   PS Scavenge            count: 234, time: 3456ms
#   PS MarkSweep           count: 56, time: 12345ms  <- Full GC 频繁！

# 3. 火焰图（CPU）
[arthas@1]$ profiler start
# Started [cpu] profiling
[arthas@1]$ profiler stop --file /tmp/flamegraph.html
# profiler output file: /tmp/flamegraph.html

# 4. 查看方法执行时间
[arthas@1]$ trace com.example.service.OrderService processOrder '#cost>100' -n 5
# ---ts=2024-01-01 12:00:00;thread_name=http-nio-8080-exec-1;id=21;
# `---[234.567ms] com.example.service.OrderService:processOrder()
#     `---[234.000ms] com.example.service.OrderService:getFromCache() # 缓存慢！

# 退出
[arthas@1]$ quit
exit  # 退出 Pod shell
```

### 步骤 6：修复 App B

#### 修复 1：JVM 参数优化

```bash
# 更新 Deployment，使用正确的 JVM 参数
kubectl patch deployment app-b -n jvm-lab --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "JAVA_OPTS", "value": "-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=75.0 -XX:+UseG1GC -XX:+PrintGCDetails -Xlog:gc*:file=/tmp/gc.log"},
    {"name": "JAVA_TOOL_OPTIONS", "value": ""}
  ]},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "2Gi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "2"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/cpu", "value": "500m"}
]}'
kubectl rollout status deployment app-b -n jvm-lab

# 验证新参数
kubectl exec -it deploy/app-b -n jvm-lab -- ps aux | grep java
# java -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=75.0
#      -XX:+UseG1GC -XX:+PrintGCDetails -Xlog:gc*:file=/tmp/gc.log -jar /app.jar
```

#### 修复 2：内存泄漏修复

```bash
# 应用修复后的镜像（假设已修复 LeakEntry 的无限增长）
# 在生产环境中，需要修改代码并重新构建

# 模拟修复：清理泄漏的缓存
curl -s http://localhost:8081/api/clear-cache
# {"status":"CACHE_CLEARED","entriesRemoved":100000}

# 验证内存下降
kubectl exec -it deploy/app-b -n jvm-lab -- jmap -histo 1 | grep LeakEntry
# 无输出（已清理）
```

#### 修复 3：连接池调大

```bash
kubectl patch deployment app-b -n jvm-lab --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value":
    {"name": "DB_MAX_POOL_SIZE", "value": "20"}
  }
]'
kubectl rollout status deployment app-b -n jvm-lab
```

#### 修复 4：死锁修复

```bash
# 死锁需要代码修复。在生产环境中：
# 1. 使用 jstack 获取死锁信息
# 2. 修改代码，确保锁的顺序一致
# 3. 或使用 tryLock + timeout 避免无限等待

# 模拟重启恢复（临时方案）
kubectl rollout restart deployment app-b -n jvm-lab
kubectl rollout status deployment app-b -n jvm-lab
```

### 步骤 7：验证修复

```bash
# 重新诊断
./diagnose-jvm.sh app-b

# 验证 GC
kubectl exec -it deploy/app-b -n jvm-lab -- jstat -gc 1 1s 5
# S0C    S1C    S0U    S1U      EC       EU        OC         OU       MC
# 2048.0 2048.0 0.0   1024.0  13312.0  4096.0    34816.0    8192.0   44800.0
# OU/OC = 8192/34816 = 23.5%（健康，无 Full GC）

# 验证线程
kubectl exec -it deploy/app-b -n jvm-lab -- jstack 1 | grep "BLOCKED"
# 无 BLOCKED 线程

# 压测对比
echo "=== App A 压测 ==="
siege -c 20 -t 30s http://localhost:8080/api/orders
# Response time: 0.012s, Availability: 100%

echo "=== App B 修复后压测 ==="
siege -c 20 -t 30s http://localhost:8081/api/orders
# Response time: 0.015s, Availability: 100%  <- 接近 App A！
```

---

## 排障决策树

```
Java 应用性能问题
    │
    ├── P99 延迟周期性飙升？
    │       ├── 是 → GC 问题
    │       │       ├── jstat -gc 查看 GC 频率
    │       │       ├── 查看 GC 日志确认 Full GC
    │       │       ├── 检查堆内存设置（UseContainerSupport）
    │       │       └── 优化：G1GC + 容器感知 + 合理堆大小
    │       └── 否 → 继续
    │
    ├── 应用无响应，CPU 不高？
    │       ├── 是 → 线程问题
    │       │       ├── jstack 查看 BLOCKED 线程
    │       │       ├── 查找死锁
    │       │       └── 优化：统一锁顺序、使用 tryLock
    │       └── 否 → 继续
    │
    ├── 内存持续增长，最终 OOM？
    │       ├── 是 → 内存泄漏
    │       │       ├── jmap -histo 查看对象增长
    │       │       ├── jmap -dump 生成 heap dump
    │       │       ├── MAT/VisualVM 分析泄漏源
    │       │       └── 优化：修复引用未释放问题
    │       └── 否 → 继续
    │
    └── 连接超时，但服务端正常？
            ├── 是 → 连接池问题
            │       ├── 检查连接池配置（max/min/timeout）
            │       ├── 检查连接泄漏（未 close）
            │       └── 优化：调大连接池、设置合理超时
            └── 否 → 检查网络/数据库/外部依赖
```

---

## 评分标准

```
基础要求（40 分）：
  □ 成功构建 Java 应用镜像（10 分）
  □ 成功部署 App A 和 App B（10 分）
  □ 成功运行诊断脚本收集数据（10 分）
  □ 使用 jstat/jmap/jstack 完成基础诊断（10 分）

进阶要求（40 分）：
  □ 定位 GC 问题（ParallelGC + 小内存 + 无容器感知）（10 分）
  □ 定位线程死锁（jstack 发现死锁）（10 分）
  □ 定位内存泄漏（LeakEntry 无限增长）（10 分）
  □ 定位连接池耗尽问题（10 分）

挑战要求（20 分）：
  □ 使用 Arthas 实时诊断（火焰图/方法追踪）（10 分）
  □ 修复后 P99 < 2 倍 App A 基线（10 分）

优秀加分（额外）：
  □ 使用 async-profiler 生成火焰图（+5 分）
  □ 配置 JMX Exporter + Grafana JVM Dashboard（+5 分）
```

---

## 面试核心考点

```
Q: "Java 应用在 K8s 中常见的性能问题有哪些？"

A:
   1. 堆内存设置不当：
      - JDK 8 默认不感知容器限制，-Xmx 可能超过容器内存限制导致 OOMKilled
      - 解决：使用 JDK 11+ 或开启 -XX:+UnlockExperimentalVMOptions -XX:+UseCGroupMemoryLimitForHeap
      - 或显式设置 -XX:MaxRAMPercentage=75.0
   
   2. GC 算法选择：
      - ParallelGC：吞吐量高，但 STW 时间长（200ms+）
      - G1GC：平衡吞吐量和延迟，STW < 50ms
      - ZGC/Shenandoah：超低延迟，STW < 10ms
   
   3. CPU 限制影响：
      - CPU limit 低会导致 GC 线程数少，GC 时间变长
      - 解决：设置合理的 CPU request/limit
   
   4. 容器感知参数：
      - -XX:+UseContainerSupport（JDK 10+）
      - -XX:MaxRAMPercentage（替代 -Xmx）
      - -XX:ActiveProcessorCount（替代自动检测）

Q: "JDK 8 在 K8s 中有什么已知问题？"

A:
   1. 不感知容器内存限制：
      - 默认读取 /proc/meminfo 获取物理机内存
      - 容器 limit 2GB，但 JVM 看到 64GB，堆可能设置过大
   
   2. 不感知容器 CPU 限制：
      - 默认读取 /proc/cpuinfo 获取物理机 CPU 数
      - GC 线程数 = CPU 数，在 2C 容器中 GC 线程可能过多
   
   3. 解决方案：
      - 升级 JDK 11+（推荐）
      - 或手动设置 -Xmx、-XX:ParallelGCThreads
      - 使用 Fabric8 的 Java 镜像或自定义 entrypoint
```

---

## 常见问题

```
Q: jmap/jstack 执行失败？
A: 确保 JVM 以相同用户运行，且目标进程有权限。
   如果使用非 root 容器，可能需要添加 CAP_SYS_PTRACE。

Q: Arthas 无法 attach？
A: 检查 /tmp/.java_pid* 文件权限，或尝试使用 -l 参数。
   某些安全加固的容器可能禁止 attach。

Q: 压测时应用重启？
A: 检查 livenessProbe 阈值是否过严。
   GC 暂停可能导致探针超时，触发重启。
```

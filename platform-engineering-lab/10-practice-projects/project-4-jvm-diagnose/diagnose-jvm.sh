#!/bin/bash
# JVM 性能诊断脚本
# 检查 GC 状态、堆内存、线程状态、类加载、内存泄漏、死锁、CPU 使用
# 用于 platform-engineering-lab 项目 4
# 输出包含自动建议和面试级分析

set -euo pipefail

APP_NAME=${1:-""}
if [ -z "$APP_NAME" ]; then
  echo "用法: $0 <app-name>"
  echo ""
  echo "示例:"
  echo "  $0 app-a    # 诊断健康基线（G1GC，容器感知）"
  echo "  $0 app-b    # 诊断问题应用（ParallelGC，无容器感知）"
  echo ""
  echo "对比分析:"
  echo "  先运行 $0 app-a 获取健康基线"
  echo "  再运行 $0 app-b 获取问题数据"
  echo "  对比差异找出根因"
  exit 1
fi

NAMESPACE="jvm-lab"
APP_POD=$(kubectl get pod -n "$NAMESPACE" -l app="$APP_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$APP_POD" ]; then
  echo "错误: 未找到应用 Pod (app=$APP_NAME)"
  echo "可用的应用:"
  kubectl get pods -n "$NAMESPACE" -l app -o jsonpath='{range .items[*]}{.metadata.labels.app}{"\n"}{end}' 2>/dev/null || echo "  无"
  exit 1
fi

echo "=============================================="
echo "  JVM 性能诊断报告"
echo "  应用: $APP_NAME"
echo "  Pod: $APP_POD"
echo "  命名空间: $NAMESPACE"
echo "  时间: $(date -Iseconds)"
echo "=============================================="
echo ""

# 获取 Java PID
JAVA_PID=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- sh -c 'ps aux | grep java | grep -v grep | awk "{print \$2}"' 2>/dev/null | tr -d '\r' || echo "")

if [ -z "$JAVA_PID" ]; then
  echo "错误: 无法获取 Java 进程 PID"
  exit 1
fi

echo "Java PID: $JAVA_PID"
echo ""

# 1. JVM 版本和启动参数
echo "========================================"
echo "1. JVM 版本和启动参数"
echo "========================================"
echo "Java 进程详情:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- ps aux 2>/dev/null | grep java | grep -v grep || echo "  未找到 Java 进程"

echo ""
echo "JVM 版本信息:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- java -version 2>/dev/null || echo "  无法获取"
echo ""

# 2. GC 统计
echo "========================================"
echo "2. GC 统计 (jstat -gc)"
echo "========================================"
echo "列说明:"
echo "  S0C/S1C = Survivor 0/1 容量 (KB)"
echo "  S0U/S1U = Survivor 0/1 使用 (KB)"
echo "  EC/EU   = Eden 容量/使用 (KB)"
echo "  OC/OU   = Old 区 容量/使用 (KB)"
echo "  MC/MU   = Metaspace 容量/使用 (KB)"
echo "  YGC/YGCT= Young GC 次数/时间(秒)"
echo "  FGC/FGCT= Full GC 次数/时间(秒)"
echo "  GCT     = 总 GC 时间(秒)"
echo ""
echo "采样 3 次（间隔 1 秒）:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstat -gc "$JAVA_PID" 1s 3 2>/dev/null || echo "  jstat 不可用（可能是 JRE 而非 JDK）"
echo ""

echo "GC 原因统计 (jstat -gccause):"
echo "LGCC = Last GC Cause, GCC = Current GC Cause"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstat -gccause "$JAVA_PID" 1s 2 2>/dev/null || echo "  jstat 不可用"
echo ""

# 3. 堆内存详情
echo "========================================"
echo "3. 堆内存详情 (jmap -heap)"
echo "========================================"
echo "堆配置和摘要:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jmap -heap "$JAVA_PID" 2>/dev/null || echo "  jmap 不可用（JRE 环境）"
echo ""

# 4. 内存直方图（检查泄漏）
echo "========================================"
echo "4. 内存直方图 Top 25 (jmap -histo)"
echo "========================================"
echo "列: 排名 | 实例数 | 字节数 | 类名"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jmap -histo "$JAVA_PID" 2>/dev/null | head -25 || echo "  jmap 不可用"

echo ""

# 检查是否有可疑的大对象
LEAK_CLASS=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jmap -histo "$JAVA_PID" 2>/dev/null | grep -iE "Leak|HashMap|ArrayList|ConcurrentHashMap|byte\[\]|Object\[\]|String\[\]" | head -10 || echo "")
if [ -n "$LEAK_CLASS" ]; then
  echo "可疑的集合/数组对象（实例数或字节数异常高可能表示泄漏）:"
  echo "$LEAK_CLASS"
fi
echo ""

# 5. 线程状态
echo "========================================"
echo "5. 线程状态统计"
echo "========================================"
echo "各状态线程数:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep "java.lang.Thread.State" | sort | uniq -c || echo "  jstack 不可用"

echo ""
echo "线程总数:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep -c "java.lang.Thread.State" || echo "  无法统计"
echo ""

# 6. 死锁检测
echo "========================================"
echo "6. 死锁检测"
echo "========================================"
DEADLOCK=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep "Found one Java-level deadlock" || echo "")
if [ -n "$DEADLOCK" ]; then
  echo "⚠️ 发现死锁！详情如下:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep -A 50 "Found one Java-level deadlock" || echo ""
else
  echo "✓ 未发现死锁"
fi
echo ""

# 7. BLOCKED 线程详情
echo "========================================"
echo "7. BLOCKED / WAITING 线程详情"
echo "========================================"
echo "BLOCKED 线程（可能 contention）:"
BLOCKED_THREADS=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep -B 1 "java.lang.Thread.State: BLOCKED" | grep '"' | head -5 || echo "")
if [ -n "$BLOCKED_THREADS" ]; then
  echo "$BLOCKED_THREADS"
  echo ""
  echo "BLOCKED 线程堆栈详情:"
  kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep -A 5 "java.lang.Thread.State: BLOCKED" | head -20 || echo ""
else
  echo "✓ 无 BLOCKED 线程"
fi

echo ""
echo "WAITING / TIMED_WAITING 线程（检查是否有连接池等待）:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep -B 1 "java.lang.Thread.State: WAITING\|java.lang.Thread.State: TIMED_WAITING" | grep '"' | head -5 || echo "  无 WAITING 线程"
echo ""

# 8. GC 日志
echo "========================================"
echo "8. GC 日志（最近 20 行）"
echo "========================================"
echo "路径: /tmp/gc.log（需要 -Xlog:gc* 参数才会生成）"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- cat /tmp/gc.log 2>/dev/null | tail -20 || echo "  GC 日志不存在"
echo ""

# 9. 应用日志异常
echo "========================================"
echo "9. 应用日志异常扫描"
echo "========================================"
echo "最近 30 条 ERROR / Exception / OOM / timeout / deadlock:"
kubectl logs "$APP_POD" -n "$NAMESPACE" --tail=150 2>/dev/null | grep -iE "ERROR|Exception|OutOfMemory|timeout|deadlock|GC overhead limit exceeded" | tail -20 || echo "  未找到异常日志"
echo ""

# 10. 资源使用
echo "========================================"
echo "10. 容器资源使用"
echo "========================================"
echo "Pod 资源使用:"
kubectl top pod "$APP_POD" -n "$NAMESPACE" 2>/dev/null || echo "  metrics-server 不可用"

echo ""
echo "JVM 内存限制 vs 容器限制:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null | awk '{print "  容器内存限制: " $1/1024/1024 " MB"}' || echo "  cgroup v2 路径不同，尝试替代路径..."
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- cat /sys/fs/cgroup/memory.current 2>/dev/null | awk '{print "  当前内存使用: " $1/1024/1024 " MB"}' || echo "  无法获取"

echo ""
echo "容器 CPU 限制:"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null | awk '{if($1==-1) print "  CPU 限制: 无限制"; else print "  CPU quota: " $1}' || echo "  无法获取"
kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null | awk '{print "  CPU period: " $1}' || echo "  无法获取"
echo ""

# 11. 自动诊断建议
echo "========================================"
echo "11. 自动诊断建议"
echo "========================================"

WARNINGS=0

# 检查 GC 类型
GC_TYPE=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- ps aux 2>/dev/null | grep java | grep -oE "UseG1GC|UseParallelGC|UseConcMarkSweepGC|UseZGC|UseShenandoahGC" | head -1 | tr -d '\r' || echo "")
if [ -n "$GC_TYPE" ]; then
  echo "GC 算法: $GC_TYPE"
  case "$GC_TYPE" in
    *ParallelGC*)
      echo "  ⚠️ 警告: ParallelGC 吞吐量高但 STW 时间长"
      echo "  影响: 不适合低延迟场景，P99 可能达到数百毫秒"
      echo "  生产建议: 切换为 G1GC (-XX:+UseG1GC) 或 ZGC (-XX:+UseZGC)"
      echo "  适用场景: 批处理、大数据（吞吐优先）"
      WARNINGS=$((WARNINGS + 1))
      ;;
    *G1GC*)
      echo "  ✓ G1GC 适合大多数场景，平衡吞吐和延迟"
      echo "  默认目标: MaxGCPauseMillis=200ms"
      echo "  适用场景: Web 服务、微服务（延迟敏感但非极端）"
      ;;
    *ZGC*|*ShenandoahGC*)
      echo "  ✓ 低延迟 GC，STW < 10ms，适合大堆内存"
      echo "  适用场景: 高频交易、实时游戏（极端延迟敏感）"
      echo "  注意: JDK 15+ 生产可用，需要更多 CPU 资源"
      ;;
  esac
else
  echo "GC 算法: 未知（使用 JVM 默认）"
  echo "  JDK 8 默认 ParallelGC，JDK 11+ 默认 G1GC"
fi

# 检查容器感知
CONTAINER_SUPPORT=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- ps aux 2>/dev/null | grep java | grep -o "UseContainerSupport" | head -1 || echo "")
if [ -z "$CONTAINER_SUPPORT" ]; then
  echo ""
  echo "⚠️ 警告: 未检测到 -XX:+UseContainerSupport"
  echo "  影响: JVM 按宿主机内存分配堆，可能远超容器 limit"
  echo "  症状: 容器内存 limit 4GB，JVM 分配 8GB+，导致 OOMKilled"
  echo "  建议: 添加 -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
  echo "  版本要求: JDK 8u191+ / JDK 11+"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查堆内存设置
HEAP_SIZE=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- ps aux 2>/dev/null | grep java | grep -oE "Xmx[0-9]+[mgMG]" | head -1 | tr -d '\r' || echo "")
if [ -n "$HEAP_SIZE" ]; then
  echo ""
  echo "堆内存手动设置: $HEAP_SIZE"
  echo "  提示: 手动 -Xmx 时，确保不超过容器内存限制"
  echo "  建议: 使用 -XX:MaxRAMPercentage=75.0 替代 -Xmx"
  echo "  原因: MaxRAMPercentage 自动感知容器内存限制"
fi

# 检查 Full GC
FULL_GC=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstat -gc "$JAVA_PID" 1s 1 2>/dev/null | tail -1 | awk '{print $14}')
if [ -n "$FULL_GC" ] && [ "$FULL_GC" != "0" ] && [ "$FULL_GC" != "FGC" ] && [ "$FULL_GC" != "" ]; then
  echo ""
  echo "⚠️ 检测到 $FULL_GC 次 Full GC"
  echo "  影响: Full GC STW 时间长（数秒级别）"
  echo "  排查:"
  echo "    1. 检查堆内存是否足够（OU/OC 比率）"
  echo "    2. 检查是否存在内存泄漏（jmap -histo 查看增长最快的类）"
  echo "    3. 优化对象生命周期，减少进入老年代的对象"
  echo "    4. 调整新生代比例（-XX:NewRatio）"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查 OOM
OOM=$(kubectl logs "$APP_POD" -n "$NAMESPACE" --tail=50 2>/dev/null | grep -i "OutOfMemoryError" | head -1 || echo "")
if [ -n "$OOM" ]; then
  echo ""
  echo "⚠️ 警告: 应用日志中发现 OutOfMemoryError"
  echo "  建议: 分析 heap dump，检查内存泄漏或大对象"
  echo "  生成 heap dump: -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查线程数
THREAD_COUNT=$(kubectl exec -it "$APP_POD" -n "$NAMESPACE" -- jstack "$JAVA_PID" 2>/dev/null | grep -c "java.lang.Thread.State" || echo "0")
if [ -n "$THREAD_COUNT" ] && [ "$THREAD_COUNT" -gt 500 ] 2>/dev/null; then
  echo ""
  echo "⚠️ 警告: 线程数 $THREAD_COUNT（过多）"
  echo "  影响: 每个线程占用 ~1MB 栈内存，线程过多导致内存压力"
  echo "  建议: 检查线程池配置，使用有界队列"
  WARNINGS=$((WARNINGS + 1))
fi

if [ "$WARNINGS" -eq 0 ]; then
  echo "✓ 未发现明显问题"
fi

echo ""
echo "========================================"
echo "面试知识点"
echo "========================================"
echo "Q: G1GC 和 ZGC 的核心区别？"
echo "A:"
echo "  G1GC:"
echo "    - 区域化分代收集（Region-based）"
echo "    - 目标停顿: 200ms（默认）"
echo "    - 适用: 通用场景，JDK 9+ 默认"
echo "    - 堆范围: 数 GB 到数百 GB"
echo ""
echo "  ZGC:"
echo "    - 低延迟，STW < 10ms"
echo "    - 并发整理（Concurrent compaction）"
echo "    - 适用: 极端延迟敏感场景"
echo "    - 堆范围: 8MB - 16TB"
echo "    - JDK 15+ 生产可用"
echo ""
echo "  选择: 延迟敏感选 ZGC，通用场景选 G1GC"
echo ""
echo "Q: 容器中的 JVM 内存配置最佳实践？"
echo "A:"
echo "  1. -XX:+UseContainerSupport（JDK 8u191+/JDK 11+）"
echo "     让 JVM 读取 cgroup 内存限制而非宿主机内存"
echo ""
echo "  2. -XX:MaxRAMPercentage=75.0（替代 -Xmx）"
echo "     按容器内存限制的百分比设置堆上限"
echo ""
echo "  3. 预留 25% 给堆外内存:"
echo "     - Metaspace（类元数据）"
echo "     - DirectBuffer（NIO 直接内存）"
echo "     - 线程栈（每个线程 ~1MB）"
echo "     - JNI 代码"
echo ""
echo "  4. 公式: 容器 limit = JVM 堆 × 1.33（即 75% 给堆）"
echo ""
echo "Q: 如何排查内存泄漏？"
echo "A:"
echo "  1. jmap -histo 查看增长最快的类"
echo "     对比泄漏前后的 histogram，找出增量对象"
echo ""
echo "  2. jmap -dump:format=b,file=/tmp/heap.hprof <pid>"
echo "     生成 heap dump 文件"
echo ""
echo "  3. 使用 MAT（Eclipse Memory Analyzer）分析:"
echo "     - Dominator Tree: 找出占用内存最大的对象"
echo "     - Leak Suspects: 自动分析潜在的泄漏点"
echo "     - Path to GC Roots: 追踪对象引用链"
echo ""
echo "  4. 常见泄漏场景:"
echo "     - ThreadLocal 未清理"
echo "     - 静态集合类无限增长"
echo "     - 监听器/回调未注销"
echo "     - 连接池泄漏"
echo ""
echo "Q: 为什么 JVM 在容器中会被 OOMKilled？"
echo "A:"
echo "  原因 1: 未启用 UseContainerSupport"
echo "    JVM 按宿主机内存分配堆，远超容器 limit"
echo ""
echo "  原因 2: 只设置了 -Xmx，未考虑堆外内存"
echo "    总内存 = 堆 + Metaspace + DirectBuffer + 线程栈 + 其他"
echo "    即使 -Xmx < limit，堆外内存也可能导致 OOM"
echo ""
echo "  原因 3: 容器 limit 设置过小"
echo "    建议至少给 JVM 堆留 2-4GB 余量"
echo ""
echo "  解决: -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
echo ""

echo "=============================================="
echo "  JVM 诊断完成"
echo "  建议对照 App A（健康基线）进行对比分析"
echo "=============================================="

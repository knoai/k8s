#!/bin/bash
# Redis 性能诊断脚本
# 检查内存使用、慢日志、大 Key、连接数、持久化状态、复制状态、集群状态
# 用于 platform-engineering-lab 项目 3
# 输出包含自动诊断建议和面试级分析指导

set -euo pipefail

echo "=============================================="
echo "  Redis 性能诊断报告"
echo "  时间: $(date -Iseconds)"
echo "=============================================="
echo ""

NAMESPACE="middleware-lab"
REDIS_POD=$(kubectl get pod -n "$NAMESPACE" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$REDIS_POD" ]; then
  echo "错误: 未找到 Redis Pod"
  echo "请先运行 ./deploy-middleware-lab.sh"
  exit 1
fi

echo "Redis Pod: $REDIS_POD"
echo "Namespace: $NAMESPACE"
echo ""

# 1. 基础信息
echo "========================================"
echo "1. Redis 基础信息"
echo "========================================"
echo "服务器信息:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO server 2>/dev/null | grep -E "redis_version|redis_mode|uptime_in_seconds|process_id|tcp_port|hz|lru_clock|executable|config_file" || echo "  无法获取"
echo ""

# 2. 内存使用
echo "========================================"
echo "2. 内存使用详情"
echo "========================================"
echo "内存统计:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO memory 2>/dev/null | grep -E "used_memory|used_memory_human|used_memory_rss|used_memory_peak|used_memory_peak_human|maxmemory|maxmemory_human|mem_fragmentation_ratio|mem_fragmentation_bytes|mem_allocator" || echo "  无法获取"

echo ""
echo "Key 空间统计:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO keyspace 2>/dev/null || echo "  无法获取"

echo ""
echo "总 Key 数量:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli DBSIZE 2>/dev/null || echo "  无法获取"
echo ""

# 3. 大 Key 扫描
echo "========================================"
echo "3. 大 Key 扫描"
echo "========================================"
echo "使用 redis-cli --bigkeys 扫描（采样统计）:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli --bigkeys 2>/dev/null || echo "  扫描失败"

echo ""
echo "手动扫描 string 类型最大 Key（sample 100 个）:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- bash -c "
  redis-cli --scan --pattern '*' | head -100 | while read key; do
    size=\$(redis-cli STRLEN \"\$key\" 2>/dev/null || echo 0)
    echo \"\$size \$key\"
  done | sort -nr | head -10
" 2>/dev/null || echo "  扫描失败"
echo ""

# 4. 慢日志
echo "========================================"
echo "4. 慢日志分析"
echo "========================================"
echo "慢日志条目数:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli SLOWLOG LEN 2>/dev/null || echo "  无法获取"

echo ""
echo "最近 10 条慢日志（格式: id | 时间戳 | 耗时(us) | 命令）:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli SLOWLOG GET 10 2>/dev/null || echo "  无慢日志"
echo ""

# 5. 客户端连接
echo "========================================"
echo "5. 客户端连接分析"
echo "========================================"
echo "连接统计:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO clients 2>/dev/null || echo "  无法获取"

echo ""
echo "连接列表（前 20 条）:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CLIENT LIST 2>/dev/null | head -20 || echo "  无法获取"

echo ""
echo "阻塞客户端（执行阻塞命令如 BLPOP）:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CLIENT LIST 2>/dev/null | grep -i "blocked" | head -5 || echo "  无阻塞客户端"
echo ""

# 6. 统计信息
echo "========================================"
echo "6. 命令统计"
echo "========================================"
echo "总体统计:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO stats 2>/dev/null | grep -E "total_commands_processed|instantaneous_ops_per_sec|total_connections_received|rejected_connections|sync_full|sync_partial_ok|expired_keys|evicted_keys|keyspace_hits|keyspace_misses|pubsub_channels|pubsub_patterns|latest_fork_usec|total_forks|migrate_cached_sockets|slave_expires_tracked_keys|active_defrag_hits|active_defrag_misses|active_defrag_key_hits|active_defrag_key_misses" || echo "  无法获取"

echo ""
echo "命令分布（按命令类型统计调用次数和耗时）:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO commandstats 2>/dev/null | head -20 || echo "  无法获取"
echo ""

# 7. 持久化状态
echo "========================================"
echo "7. 持久化状态"
echo "========================================"
echo "RDB 持久化:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO persistence 2>/dev/null | grep -E "rdb_last_save_time|rdb_changes_since_last_save|rdb_bgsave_in_progress|rdb_last_bgsave_status|rdb_last_bgsave_time_sec" || echo "  无法获取"

echo ""
echo "AOF 持久化:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO persistence 2>/dev/null | grep -E "aof_enabled|aof_rewrite_in_progress|aof_rewrite_scheduled|aof_last_rewrite_time_sec|aof_current_size|aof_base_size|aof_pending_rewrite|aof_buffer_length|aof_rewrite_buffer_length|aof_last_bgrewrite_status|aof_last_write_status" || echo "  无法获取"
echo ""

# 8. 复制状态
echo "========================================"
echo "8. 复制状态"
echo "========================================"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO replication 2>/dev/null | head -20 || echo "  无法获取（单实例无主从）"
echo ""

# 9. 配置检查
echo "========================================"
echo "9. 关键配置检查"
echo "========================================"
echo "内存和驱逐策略:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET maxmemory 2>/dev/null || echo "  无法获取"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET maxmemory-policy 2>/dev/null || echo "  无法获取"

echo ""
echo "慢日志配置:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET slowlog* 2>/dev/null || echo "  无法获取"

echo ""
echo "持久化配置:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET save 2>/dev/null || echo "  无法获取"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET appendonly 2>/dev/null || echo "  无法获取"

echo ""
echo "超时配置:"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET timeout 2>/dev/null || echo "  无法获取"
kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET tcp-keepalive 2>/dev/null || echo "  无法获取"
echo ""

# 10. 自动诊断建议
echo "========================================"
echo "10. 自动诊断建议"
echo "========================================"

WARNINGS=0

# 检查内存使用
MEM_USED=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO memory 2>/dev/null | grep "^used_memory:" | cut -d: -f2 | tr -d '\r' || echo "0")
MEM_MAX=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO memory 2>/dev/null | grep "^maxmemory:" | cut -d: -f2 | tr -d '\r' || echo "0")

if [ "$MEM_MAX" != "0" ] && [ -n "$MEM_MAX" ] && [ "$MEM_MAX" != "" ]; then
  if command -v bc &> /dev/null; then
    MEM_RATIO=$(echo "scale=2; $MEM_USED / $MEM_MAX * 100" | bc 2>/dev/null || echo "0")
    if (( $(echo "$MEM_RATIO > 80" | bc -l 2>/dev/null || echo "0") )); then
      echo "⚠️ 警告: 内存使用率达到 ${MEM_RATIO}%"
      echo "  影响: 即将触发 Key 驱逐，影响缓存命中率"
      echo "  建议: 增加 maxmemory 或优化数据结构（使用 Hash 代替 String）"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# 检查内存碎片
FRAG_RATIO=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO memory 2>/dev/null | grep "^mem_fragmentation_ratio:" | cut -d: -f2 | tr -d '\r' || echo "0")
if [ -n "$FRAG_RATIO" ] && [ "$FRAG_RATIO" != "" ]; then
  if command -v bc &> /dev/null; then
    if (( $(echo "$FRAG_RATIO > 1.5" | bc -l 2>/dev/null || echo "0") )); then
      echo ""
      echo "⚠️ 警告: 内存碎片率 $FRAG_RATIO"
      echo "  影响: 实际 RSS 内存远大于数据内存，浪费容器内存"
      echo "  建议: 考虑重启 Redis 或启用主动碎片整理（activedefrag yes，Redis 4.0+）"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# 检查驱逐
EVICTED=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO stats 2>/dev/null | grep "^evicted_keys:" | cut -d: -f2 | tr -d '\r' || echo "0")
if [ -n "$EVICTED" ] && [ "$EVICTED" != "0" ] && [ "$EVICTED" != "" ]; then
  echo ""
  echo "⚠️ 警告: 已驱逐 $EVICTED 个 Key"
  echo "  影响: 缓存命中率下降，请求穿透到后端数据库"
  echo "  建议:"
  echo "    1. 评估内存扩容需求"
  echo "    2. 检查是否存在大 Key 浪费内存"
  echo "    3. 优化数据结构（String → Hash，减少 Key 数量）"
  echo "    4. 设置合理的 Key 过期时间"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查慢日志
SLOW_COUNT=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli SLOWLOG LEN 2>/dev/null | tr -d '\r' || echo "0")
if [ -n "$SLOW_COUNT" ] && [ "$SLOW_COUNT" != "0" ] && [ "$SLOW_COUNT" != "" ]; then
  echo ""
  echo "⚠️ 警告: 有 $SLOW_COUNT 条慢日志"
  echo "  影响: 阻塞 Redis 单线程，影响所有客户端响应"
  echo "  建议:"
  echo "    1. 避免 KEYS *、SMEMBERS、HGETALL 等 O(N) 命令"
  echo "    2. 大 Key 删除使用 UNLINK 替代 DEL（异步删除）"
  echo "    3. 集合类操作确保数据量可控"
  echo "    4. 使用 SCAN 替代 KEYS"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查缓存命中率
KEYSPACE_HITS=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO stats 2>/dev/null | grep "^keyspace_hits:" | cut -d: -f2 | tr -d '\r' || echo "0")
KEYSPACE_MISSES=$(kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO stats 2>/dev/null | grep "^keyspace_misses:" | cut -d: -f2 | tr -d '\r' || echo "0")
if [ -n "$KEYSPACE_HITS" ] && [ -n "$KEYSPACE_MISSES" ] && [ "$KEYSPACE_MISSES" != "0" ]; then
  if command -v bc &> /dev/null; then
    HIT_RATE=$(echo "scale=2; $KEYSPACE_HITS / ($KEYSPACE_HITS + $KEYSPACE_MISSES) * 100" | bc 2>/dev/null || echo "0")
    if (( $(echo "$HIT_RATE < 80" | bc -l 2>/dev/null || echo "0") )); then
      echo ""
      echo "⚠️ 警告: 缓存命中率 ${HIT_RATE}%"
      echo "  影响: 大量请求穿透到后端存储，增加 DB 压力"
      echo "  建议:"
      echo "    1. 检查 Key 过期策略是否过于激进"
      echo "    2. 检查内存驱逐是否导致热点 Key 被清理"
      echo "    3. 增加缓存预热机制"
      echo "    4. 评估是否需要增大 maxmemory"
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

if [ "$WARNINGS" -eq 0 ]; then
  echo "✓ 未发现明显问题"
fi

echo ""
echo "========================================"
echo "面试知识点"
echo "========================================"
echo "Q: Redis 为什么单线程还这么快？"
echo "A:"
echo "  1) 纯内存操作（无磁盘 I/O）"
echo "  2) I/O 多路复用（epoll/kqueue）单线程处理多个连接"
echo "  3) 避免线程切换和锁竞争开销"
echo "  4) 高效的数据结构（SDS、跳跃表、压缩列表）"
echo ""
echo "  注意: Redis 6.0+ 引入多线程 I/O，但命令执行仍是单线程"
echo "        多线程用于网络读写，不处理命令逻辑"
echo ""
echo "Q: 大 Key 的危害和处理？"
echo "A:"
echo "  危害:"
echo "    1) 阻塞单线程（DEL 1MB Key 可能需要 1ms+）"
echo "    2) 内存碎片（删除后内存不返回给 OS）"
echo "    3) RDB/AOF 持久化慢（大 Key 序列化耗时）"
echo "    4) 主从同步慢（全量同步时阻塞）"
echo "    5) 迁移困难（Redis Cluster 槽迁移时阻塞）"
echo ""
echo "  处理:"
echo "    1) 拆分: 将大 Hash/Set 拆分为多个小 Key"
echo "    2) 渐进式删除: 使用 UNLINK 替代 DEL（异步删除）"
echo "    3) 监控: 定期运行 --bigkeys 和 redis-cli --memkeys"
echo "    4) 预防: 代码审查中检查 Value 大小"
echo ""
echo "Q: maxmemory-policy 如何选择？"
echo "A:"
echo "  缓存场景（数据可丢失）:"
echo "    allkeys-lru: 所有 Key 按最近最少使用驱逐"
echo "    allkeys-lfu: 所有 Key 按访问频率驱逐（Redis 4.0+）"
echo "    allkeys-random: 随机驱逐"
echo ""
echo "  持久化场景（部分数据不可丢失）:"
echo "    volatile-lru: 仅带过期时间的 Key 按 LRU 驱逐"
echo "    volatile-lfu: 仅带过期时间的 Key 按 LFU 驱逐"
echo "    volatile-ttl: 驱逐即将过期的 Key"
echo ""
echo "  严格场景:"
echo "    noeviction: 不驱逐，写操作直接报错"
echo "    适用: 必须确保数据不丢失，需配合内存监控告警"
echo ""
echo "Q: Redis 持久化选择 RDB 还是 AOF？"
echo "A:"
echo "  RDB:"
echo "    优点: 文件紧凑，恢复速度快，适合备份"
echo "    缺点: 可能丢失最后一次快照后的数据"
echo "    配置: save 900 1 / save 300 10 / save 60 10000"
echo ""
echo "  AOF:"
echo "    优点: 数据更安全，最多丢失 1 秒数据"
echo "    缺点: 文件大，恢复速度慢"
echo "    配置: appendonly yes，appendfsync everysec"
echo ""
echo "  生产推荐: 两者同时启用"
echo "    - RDB 用于快速恢复和备份"
echo "    - AOF 用于数据安全"
echo "    - 恢复时优先使用 AOF（数据更完整）"
echo ""

echo "=============================================="
echo "  Redis 诊断完成"
echo "=============================================="

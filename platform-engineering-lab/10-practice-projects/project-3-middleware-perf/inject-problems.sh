#!/bin/bash
# 中间件性能实验 - 问题注入脚本
# 向 MySQL/Redis 注入性能问题，用于实验对比和诊断训练
# 用于 platform-engineering-lab 项目 3
#
# 注入的问题对应真实生产环境中的常见性能瓶颈:
#   MySQL: 缺失索引、数据膨胀、连接池瓶颈、慢查询
#   Redis: 大 Key、内存不足、Key 膨胀、慢操作

set -euo pipefail

NAMESPACE="middleware-lab"
MYSQL_POD=""
REDIS_POD=""

echo "=============================================="
echo "  中间件性能实验 - 问题注入"
echo "  时间: $(date -Iseconds)"
echo "=============================================="
echo ""
echo "本脚本将注入以下问题（对应生产环境真实场景）:"
echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │  MySQL 问题注入                          │"
echo "  │    1. 删除所有非主键索引                 │"
echo "  │       → 所有 WHERE 查询全表扫描          │"
echo "  │                                          │"
echo "  │    2. 插入 10,000 条测试数据             │"
echo "  │       → 放大全表扫描的代价               │"
echo "  │                                          │"
echo "  │    3. 限制 max_connections=50            │"
echo "  │       → 模拟连接池配置不当               │"
echo "  │                                          │"
echo "  │    4. 启用慢查询日志（阈值 0.1s）        │"
echo "  │       → 记录所有慢查询用于分析           │"
echo "  │                                          │"
echo "  │    5. 降低临时表内存阈值                 │"
echo "  │       → 增加磁盘临时表概率               │"
echo "  └──────────────────────────────────────────┘"
echo ""
echo "  ┌──────────────────────────────────────────┐"
echo "  │  Redis 问题注入                          │"
echo "  │    1. 写入 100 个大 Key（每个 ~1MB）     │"
echo "  │       → 阻塞单线程、内存碎片             │"
echo "  │                                          │"
echo "  │    2. 限制 maxmemory=128MB               │"
echo "  │       → 触发 Key 驱逐，缓存命中率下降    │"
echo "  │                                          │"
echo "  │    3. 创建 50,000 个小 Key               │"
echo "  │       → Key 膨胀，Dbsize 过大            │"
echo "  │                                          │"
echo "  │    4. 启用慢日志（阈值 1ms）             │"
echo "  │       → 记录所有慢操作                   │"
echo "  └──────────────────────────────────────────┘"
echo ""

# 获取 Pod 名称
find_pods() {
  echo "=== 查找中间件 Pod ==="
  
  MYSQL_POD=$(kubectl get pod -n "$NAMESPACE" -l app=mysql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  REDIS_POD=$(kubectl get pod -n "$NAMESPACE" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [ -z "$MYSQL_POD" ]; then
    echo "错误: 未找到 MySQL Pod"
    echo "请先运行: ./deploy-middleware-lab.sh"
    exit 1
  fi
  
  if [ -z "$REDIS_POD" ]; then
    echo "错误: 未找到 Redis Pod"
    echo "请先运行: ./deploy-middleware-lab.sh"
    exit 1
  fi
  
  echo "  MySQL Pod: $MYSQL_POD"
  echo "  Redis Pod: $REDIS_POD"
  echo ""
}

# MySQL 问题注入
inject_mysql() {
  echo "========================================"
  echo "MySQL 问题注入"
  echo "========================================"
  echo ""
  
  # 1. 删除索引
  echo "[1/5] 删除 orders 表所有非主键索引..."
  echo "  生产场景: DBA 误操作删除索引 / 新环境忘记创建索引"
  echo "  影响: 所有带 WHERE 条件的查询从 <10ms 恶化到数秒"
  echo ""
  
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    USE orders_db;
    SELECT index_name, column_name, cardinality 
    FROM information_schema.statistics 
    WHERE table_name='orders' AND index_name != 'PRIMARY';
  " 2>/dev/null | while read idx col card; do
    if [ -n "$idx" ] && [ "$idx" != "index_name" ]; then
      echo "    删除索引: $idx (列: $col, 基数: $card)"
      kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
        USE orders_db;
        DROP INDEX $idx ON orders;
      " 2>/dev/null || echo "    删除失败: $idx"
    fi
  done
  echo "  ✓ 非主键索引已删除"
  echo ""
  
  # 2. 填充慢查询数据
  echo "[2/5] 填充数据（生成大量无索引查询场景）..."
  echo "  插入 10,000 条订单记录，覆盖不同 user_id、status、created_at"
  echo "  这样 WHERE user_id=xxx / status='pending' 等查询都会全表扫描"
  echo ""
  
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    USE orders_db;
    DELIMITER //
    DROP PROCEDURE IF EXISTS fill_orders//
    CREATE PROCEDURE fill_orders()
    BEGIN
      DECLARE i INT DEFAULT 0;
      WHILE i < 10000 DO
        INSERT INTO orders (user_id, amount, status, created_at)
        VALUES (
          FLOOR(1 + RAND() * 1000),
          ROUND(RAND() * 1000, 2),
          ELT(1 + FLOOR(RAND() * 3), 'pending', 'paid', 'shipped'),
          DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY)
        );
        SET i = i + 1;
      END WHILE;
    END//
    DELIMITER ;
    CALL fill_orders();
    SELECT COUNT(*) as total_orders FROM orders;
  " 2>/dev/null || echo "  数据填充完成（可能部分成功）"
  echo ""
  
  # 3. 修改连接数限制
  echo "[3/5] 修改 max_connections 为 50（模拟连接池瓶颈）..."
  echo "  生产场景: 应用连接池配置 200，但 MySQL max_connections=100"
  echo "  症状: 'Too many connections' 错误，部分请求无法建立连接"
  echo "  排查: SHOW STATUS LIKE 'Threads_connected'; 观察是否接近 max_connections"
  echo ""
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    SET GLOBAL max_connections = 50;
    SHOW VARIABLES LIKE 'max_connections';
    SHOW VARIABLES LIKE 'max_user_connections';
  " 2>/dev/null || echo "  修改失败"
  echo ""
  
  # 4. 启用慢查询日志
  echo "[4/5] 启用慢查询日志..."
  echo "  slow_query_log=ON, long_query_time=0.1s"
  echo "  任何超过 100ms 的查询都会被记录到慢查询日志"
  echo "  查看: SHOW VARIABLES LIKE 'slow_query%';"
  echo ""
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    SET GLOBAL slow_query_log = 'ON';
    SET GLOBAL long_query_time = 0.1;
    SHOW VARIABLES LIKE 'slow_query%';
    SHOW VARIABLES LIKE 'long_query_time';
  " 2>/dev/null || echo "  配置失败"
  echo ""
  
  # 5. 临时表配置
  echo "[5/5] 降低临时表内存阈值..."
  echo "  tmp_table_size 和 max_heap_table_size 控制内存临时表上限"
  echo "  超过后使用 MyISAM 磁盘临时表，性能急剧下降"
  echo "  生产建议: tmp_table_size ≥ 16MB"
  echo ""
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    SET GLOBAL tmp_table_size = 1024 * 1024;
    SET GLOBAL max_heap_table_size = 1024 * 1024;
    SHOW VARIABLES LIKE 'tmp_table_size';
    SHOW VARIABLES LIKE 'max_heap_table_size';
  " 2>/dev/null || echo "  配置失败"
  
  echo ""
  echo "✓ MySQL 问题注入完成"
  echo ""
}

# Redis 问题注入
inject_redis() {
  echo "========================================"
  echo "Redis 问题注入"
  echo "========================================"
  echo ""
  
  # 1. 写入大量大 Key
  echo "[1/4] 写入大量大 Key（每个 1MB）..."
  echo "  大 Key 定义: String > 10KB, Hash/Set/ZSet/List 元素 > 5000"
  echo "  危害:"
  echo "    - 阻塞单线程（Redis 是单线程处理命令）"
  echo "    - 内存碎片（删除后内存不释放）"
  echo "    - 序列化/反序列化慢"
  echo "    - 主从同步慢（RDB 生成和传输耗时）"
  echo ""
  
  for i in $(seq 1 100); do
    kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- \
      redis-cli SET "bigkey:$i" "$(openssl rand -base64 1048576 | tr -d '\n')" 2>/dev/null || true
  done
  echo "  ✓ 已写入 100 个大 Key（约 100MB）"
  echo ""
  
  # 2. 设置不合理的 maxmemory
  echo "[2/4] 设置 maxmemory 为 128MB（模拟内存不足）..."
  echo "  生产场景: Redis 数据增长但运维未及时调整 maxmemory"
  echo "  症状: 触发驱逐策略，缓存命中率下降，请求穿透到数据库"
  echo "  策略选择:"
  echo "    allkeys-lru: 所有 Key 按 LRU 驱逐"
  echo "    volatile-lru: 仅带过期时间的 Key 按 LRU 驱逐"
  echo "    allkeys-lfu: 按访问频率驱逐（Redis 4.0+）"
  echo "    noeviction: 不驱逐，写操作直接报错"
  echo ""
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- \
    redis-cli CONFIG SET maxmemory 134217728 2>/dev/null || echo "  设置失败"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- \
    redis-cli CONFIG SET maxmemory-policy allkeys-lru 2>/dev/null || echo "  策略设置失败"
  
  echo "  当前配置:"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET maxmemory 2>/dev/null || echo "  无法获取"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET maxmemory-policy 2>/dev/null || echo "  无法获取"
  echo ""
  
  # 3. 创建大量 Key
  echo "[3/4] 创建 50,000 个小 Key..."
  echo "  场景: 缓存 Key 设计不合理，每个用户一个 Key"
  echo "  例如: session:user:12345, session:user:12346, ..."
  echo "  症状: DBSIZE 膨胀，INFO keyspace 统计变慢，RDB 持久化时间增加"
  echo "  优化: 使用 Hash 聚合，如 session:user → field=12345, value=session_data"
  echo ""
  
  for i in $(seq 1 50); do
    kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- \
      redis-cli MSET $(seq $((i*1000+1)) $((i*1000+1000)) | xargs -I{} echo "key:{}" "val:{}") 2>/dev/null || true
  done
  echo "  ✓ 已创建 50,000 个 Key"
  echo ""
  
  # 4. 启用慢日志
  echo "[4/4] 启用慢日志..."
  echo "  阈值设为 1ms（即 1000 微秒）"
  echo "  生产建议: 通常设为 10000（10ms），这里 1ms 是为了实验效果"
  echo "  查看: SLOWLOG GET 10"
  echo ""
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- \
    redis-cli CONFIG SET slowlog-log-slower-than 1000 2>/dev/null || echo "  设置失败"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- \
    redis-cli CONFIG SET slowlog-max-len 128 2>/dev/null || echo "  设置失败"
  
  echo "  当前慢日志配置:"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli CONFIG GET slowlog* 2>/dev/null || echo "  无法获取"
  echo ""
  
  echo "✓ Redis 问题注入完成"
  echo ""
}

# 验证注入
verify() {
  echo "========================================"
  echo "验证注入结果"
  echo "========================================"
  echo ""
  
  echo "--- MySQL 验证 ---"
  echo "索引数量:"
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    USE orders_db;
    SELECT COUNT(*) as index_count FROM information_schema.statistics WHERE table_name='orders';
  " 2>/dev/null || echo "  查询失败"
  
  echo ""
  echo "数据量:"
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    USE orders_db;
    SELECT COUNT(*) as total_rows FROM orders;
    SELECT status, COUNT(*) as cnt FROM orders GROUP BY status;
  " 2>/dev/null || echo "  查询失败"
  
  echo ""
  echo "连接限制:"
  kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
    SHOW VARIABLES LIKE 'max_connections';
    SHOW VARIABLES LIKE 'long_query_time';
  " 2>/dev/null || echo "  查询失败"
  
  echo ""
  echo "--- Redis 验证 ---"
  echo "内存使用:"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli INFO memory 2>/dev/null | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio" || echo "  查询失败"
  
  echo ""
  echo "Key 数量:"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli DBSIZE 2>/dev/null || echo "  查询失败"
  
  echo ""
  echo "大 Key 统计:"
  kubectl exec -it "$REDIS_POD" -n "$NAMESPACE" -- redis-cli --bigkeys 2>/dev/null | grep -E "Biggest|Keyspace|count" | head -10 || echo "  扫描失败"
  
  echo ""
  echo "=============================================="
  echo "  问题注入完成"
  echo ""
  echo "  下一步诊断:"
  echo "    ./diagnose-mysql.sh  # MySQL 全面诊断"
  echo "    ./diagnose-redis.sh  # Redis 全面诊断"
  echo ""
  echo "  压测验证:"
  echo "    MySQL:"
  echo "      sysbench oltp_read_only \\"
  echo "        --mysql-host=<mysql-svc-ip> \\"
  echo "        --mysql-user=root \\"
  echo "        --mysql-password=admin \\"
  echo "        --mysql-db=orders_db \\"
  echo "        --tables=1 --table-size=10000 \\"
  echo "        --threads=10 --time=60 run"
  echo ""
  echo "    Redis:"
  echo "      redis-benchmark -h <redis-svc-ip> -p 6379 \\"
  echo "        -n 100000 -c 50 \\"
  echo "        --csv > redis-benchmark.csv"
  echo ""
  echo "  面试知识点:"
  echo "    Q: 为什么删除索引会导致性能问题？"
  echo "    A: 无索引时 MySQL 需要全表扫描，时间复杂度 O(n)"
  echo "       有索引时 B+ 树查找，时间复杂度 O(log n)"
  echo "       10,000 行数据: 全表扫描 ~50-100ms，索引查找 ~0.5ms"
  echo "       100 万行数据: 全表扫描 ~5-10s，索引查找 ~1ms"
  echo ""
  echo "    Q: Redis 大 Key 的危害？"
  echo "    A: 1) 阻塞单线程（DEL 1MB Key 可能需要 1ms+）"
  echo "       2) 内存碎片（删除后内存不返回给 OS）"
  echo "       3) RDB/AOF 持久化慢（大 Key 序列化耗时）"
  echo "       4) 主从同步慢（全量同步时阻塞）"
  echo "       5) 迁移困难（Redis Cluster 槽迁移时阻塞）"
  echo "       处理: 拆分大 Key、渐进式删除（UNLINK）、监控 bigkeys"
  echo ""
  echo "    Q: maxmemory-policy 如何选择？"
  echo "    A: 缓存场景（可丢失）: allkeys-lru / allkeys-lfu"
  echo "       持久化场景（不可丢失）: volatile-lru + 过期时间"
  echo "       严格场景（不可驱逐）: noeviction（需确保内存充足）"
  echo "=============================================="
}

# 主流程
main() {
  find_pods
  inject_mysql
  inject_redis
  verify
}

main "$@"

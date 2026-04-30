#!/bin/bash
# MySQL 性能诊断脚本
# 检查慢查询、执行计划、连接池状态、索引情况、表大小、InnoDB 状态、锁等待
# 用于 platform-engineering-lab 项目 3
# 输出格式化为易于阅读的表格，包含自动诊断建议和面试级分析

set -euo pipefail

echo "=============================================="
echo "  MySQL 性能诊断报告"
echo "  时间: $(date -Iseconds)"
echo "=============================================="
echo ""

NAMESPACE="middleware-lab"
MYSQL_POD=$(kubectl get pod -n "$NAMESPACE" -l app=mysql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$MYSQL_POD" ]; then
  echo "错误: 未找到 MySQL Pod"
  echo "请先运行 ./deploy-middleware-lab.sh"
  exit 1
fi

echo "MySQL Pod: $MYSQL_POD"
echo "Namespace: $NAMESPACE"
echo ""

# 1. 检查进程列表
echo "========================================"
echo "1. 当前进程列表 (SHOW PROCESSLIST)"
echo "========================================"
echo "列: Id | User | Host | db | Command | Time | State | Info"
echo "注意: 关注 Command='Query' 且 Time>1 的进程，可能是慢查询"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "SHOW PROCESSLIST;" 2>/dev/null || echo "  无法获取进程列表"
echo ""

# 2. 全局状态
echo "========================================"
echo "2. 全局状态摘要"
echo "========================================"
echo "连接和线程统计:"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SHOW STATUS WHERE Variable_name IN 
  ('Threads_connected','Threads_running','Threads_cached','Connections',
   'Max_used_connections','Aborted_connects','Aborted_clients');
" 2>/dev/null || echo "  无法获取"

echo ""
echo "查询统计:"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SHOW STATUS WHERE Variable_name IN 
  ('Queries','Slow_queries','Questions','Com_select','Com_insert',
   'Com_update','Com_delete','Select_scan','Select_full_join',
   'Created_tmp_tables','Created_tmp_disk_tables','Table_locks_waited',
   'Innodb_row_lock_waits','Innodb_deadlocks');
" 2>/dev/null || echo "  无法获取"
echo ""

# 3. 慢查询统计
echo "========================================"
echo "3. 慢查询统计 (performance_schema)"
echo "========================================"
echo "Top 10 最慢的 SQL（按平均执行时间排序）:"
echo "列: sql_text | exec_count | avg_latency_sec | max_latency_sec | rows_sent | rows_examined | avg_rows_examined"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SELECT 
  LEFT(DIGEST_TEXT, 80) as sql_text,
  COUNT_STAR as exec_count,
  ROUND(AVG_TIMER_WAIT/1000000000000, 3) as avg_latency_sec,
  ROUND(MAX_TIMER_WAIT/1000000000000, 3) as max_latency_sec,
  SUM_ROWS_SENT as total_rows_sent,
  SUM_ROWS_EXAMINED as total_rows_examined,
  ROUND(SUM_ROWS_EXAMINED/NULLIF(COUNT_STAR,0), 0) as avg_rows_examined
FROM performance_schema.events_statements_summary_by_digest
WHERE AVG_TIMER_WAIT > 1000000000000
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 10;
" 2>/dev/null || echo "  性能模式未启用或无法获取"
echo ""

# 4. 检查 orders 表索引
echo "========================================"
echo "4. orders 表索引详情"
echo "========================================"
echo "列: Table | Non_unique | Key_name | Seq_in_index | Column_name | Cardinality"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
USE orders_db;
SHOW INDEX FROM orders;
" 2>/dev/null || echo "  无法获取索引信息"
echo ""

# 5. EXPLAIN 分析
echo "========================================"
echo "5. 典型查询执行计划 (EXPLAIN)"
echo "========================================"
echo ""
echo "--- 查询 1: SELECT * FROM orders WHERE user_id = 1 ---"
echo "预期: 如果 user_id 有索引，type=ref；无索引则 type=ALL（全表扫描）"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
USE orders_db;
EXPLAIN SELECT * FROM orders WHERE user_id = 1;
" 2>/dev/null || echo "  无法获取执行计划"

echo ""
echo "--- 查询 2: SELECT * FROM orders WHERE created_at > '2024-01-01' ---"
echo "预期: 如果 created_at 有索引，type=range；无索引则 type=ALL"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
USE orders_db;
EXPLAIN SELECT * FROM orders WHERE created_at > '2024-01-01';
" 2>/dev/null || echo "  无法获取执行计划"

echo ""
echo "--- 查询 3: SELECT COUNT(*) FROM orders WHERE status = 'pending' ---"
echo "预期: 如果 status 有索引，type=ref；无索引则 type=ALL"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
USE orders_db;
EXPLAIN SELECT COUNT(*) FROM orders WHERE status = 'pending';
" 2>/dev/null || echo "  无法获取执行计划"

echo ""
echo "--- 查询 4: SELECT * FROM orders ORDER BY created_at DESC LIMIT 10 ---"
echo "预期: 如果有 created_at 索引，Extra 出现 Using index；无索引则 filesort"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
USE orders_db;
EXPLAIN SELECT * FROM orders ORDER BY created_at DESC LIMIT 10;
" 2>/dev/null || echo "  无法获取执行计划"
echo ""

# 6. 表大小统计
echo "========================================"
echo "6. 表大小统计"
echo "========================================"
echo "列: table_name | data_mb | index_mb | total_mb | table_rows | index_data_ratio"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SELECT 
  table_name,
  ROUND(data_length/1024/1024, 2) as data_mb,
  ROUND(index_length/1024/1024, 2) as index_mb,
  ROUND((data_length+index_length)/1024/1024, 2) as total_mb,
  table_rows,
  ROUND(index_length/NULLIF(data_length,0), 2) as index_data_ratio
FROM information_schema.tables
WHERE table_schema = 'orders_db'
ORDER BY (data_length+index_length) DESC;
" 2>/dev/null || echo "  无法获取表统计"
echo ""

# 7. InnoDB 状态摘要
echo "========================================"
echo "7. InnoDB 引擎状态摘要"
echo "========================================"
echo "关键指标:"
echo "  History list length: Undo 日志长度（长表示有长事务）"
echo "  Buffer pool hit rate: 缓冲池命中率（应 >95%）"
echo "  Pending reads/writes: 挂起的 I/O 操作"
echo "  Modified db pages: 脏页数量"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SHOW ENGINE INNODB STATUS\G
" 2>/dev/null | grep -E "Trx id counter|History list length|Log sequence number|Log flushed up to|Last checkpoint at|Pending flushes|Pending reads|Pending writes|Buffer pool size|Free buffers|Database pages|Old database pages|Modified db pages|Pages read|Pages created|Pages written|Row operations" | head -30 || echo "  无法获取引擎状态"
echo ""

# 8. 连接统计
echo "========================================"
echo "8. 连接和线程统计"
echo "========================================"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SHOW STATUS LIKE 'Threads_%';
" 2>/dev/null || echo "  无法获取线程统计"

echo ""
echo "最大连接数配置:"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'wait_timeout';
SHOW VARIABLES LIKE 'interactive_timeout';
" 2>/dev/null || echo "  无法获取配置"
echo ""

# 9. 锁等待
echo "========================================"
echo "9. 锁等待检测"
echo "========================================"
echo "如果有锁等待，会显示 waiting_query 和 blocking_query"
kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SELECT 
  r.trx_id waiting_trx_id,
  r.trx_mysql_thread_id waiting_thread,
  LEFT(r.trx_query, 50) waiting_query,
  b.trx_id blocking_trx_id,
  b.trx_mysql_thread_id blocking_thread,
  LEFT(b.trx_query, 50) blocking_query
FROM information_schema.innodb_lock_waits w
INNER JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
INNER JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id;
" 2>/dev/null || echo "  无锁等待或无法获取"
echo ""

# 10. 自动诊断建议
echo "========================================"
echo "10. 自动诊断建议"
echo "========================================"

WARNINGS=0

INDEX_COUNT=$(kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
USE orders_db;
SELECT COUNT(*) FROM information_schema.statistics WHERE table_name='orders' AND index_name != 'PRIMARY';
" 2>/dev/null | tail -1 | tr -d '\r' || echo "0")

if [ "$INDEX_COUNT" = "0" ] || [ -z "$INDEX_COUNT" ] || [ "$INDEX_COUNT" = "" ]; then
  echo "⚠️ 警告: orders 表缺少非主键索引！"
  echo "  影响: 所有 WHERE 条件查询都会全表扫描"
  echo "  症状: SELECT 行数 ~ rows_examined = rows_sent × table_rows"
  echo "  建议: 执行以下 SQL 重建索引:"
  echo "    CREATE INDEX idx_user_id ON orders(user_id);"
  echo "    CREATE INDEX idx_created_at ON orders(created_at);"
  echo "    CREATE INDEX idx_status ON orders(status);"
  echo "    ANALYZE TABLE orders;"
  WARNINGS=$((WARNINGS + 1))
else
  echo "✓ orders 表有 $INDEX_COUNT 个非主键索引"
fi

# 检查是否有慢查询
SLOW_EXISTS=$(kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest WHERE AVG_TIMER_WAIT > 1000000000000;
" 2>/dev/null | tail -1 | tr -d '\r' || echo "0")

if [ "$SLOW_EXISTS" != "0" ] && [ -n "$SLOW_EXISTS" ] && [ "$SLOW_EXISTS" != "" ]; then
  echo ""
  echo "⚠️ 发现 $SLOW_EXISTS 条慢查询（平均执行时间 > 1秒）"
  echo "  排查步骤:"
  echo "    1. 使用 EXPLAIN 分析执行计划"
  echo "    2. 检查 type 列: ALL=全表扫描, range=索引范围扫描, ref=索引等值查询"
  echo "    3. 检查 rows 列: 是否远大于预期返回行数"
  echo "    4. 检查 Extra 列: Using filesort/Using temporary 表示需要优化"
  echo "    5. 优化: 添加索引、重写查询、避免 SELECT *"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查临时表
TMP_DISK=$(kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "
SHOW STATUS LIKE 'Created_tmp_disk_tables';
" 2>/dev/null | tail -1 | tr -d '\r' || echo "0")
if [ -n "$TMP_DISK" ] && [ "$TMP_DISK" != "" ] && [ "$TMP_DISK" != "0" ]; then
  echo ""
  echo "⚠️ 警告: 存在磁盘临时表（Created_tmp_disk_tables=$TMP_DISK）"
  echo "  影响: 磁盘 I/O 开销远大于内存临时表"
  echo "  建议: 增大 tmp_table_size / max_heap_table_size（建议 ≥ 16MB）"
  WARNINGS=$((WARNINGS + 1))
fi

# 检查连接使用率
CONN_USED=$(kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | tail -1 | tr -d '\r' || echo "0")
MAX_CONN=$(kubectl exec -it "$MYSQL_POD" -n "$NAMESPACE" -- mysql -u root -padmin -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | tail -1 | tr -d '\r' || echo "0")
if [ -n "$CONN_USED" ] && [ -n "$MAX_CONN" ] && [ "$MAX_CONN" != "0" ] && [ "$MAX_CONN" != "" ]; then
  CONN_PCT=$((CONN_USED * 100 / MAX_CONN))
  if [ "$CONN_PCT" -gt 80 ]; then
    echo ""
    echo "⚠️ 警告: 连接使用率 ${CONN_PCT}%（$CONN_USED / $MAX_CONN）"
    echo "  影响: 接近 max_connections 限制，新连接可能被拒绝"
    echo "  建议: 增大 max_connections 或优化连接池配置"
    WARNINGS=$((WARNINGS + 1))
  fi
fi

if [ "$WARNINGS" -eq 0 ]; then
  echo "✓ 未发现明显问题"
fi

echo ""
echo "========================================"
echo "面试知识点"
echo "========================================"
echo "Q: EXPLAIN 输出各列的含义？"
echo "A:"
echo "  id:     查询标识符（复杂查询有多个 id）"
echo "  select_type: SIMPLE/PRIMARY/SUBQUERY/DERIVED"
echo "  table:  访问的表"
echo "  type:   访问类型（重要！）"
echo "          system > const > eq_ref > ref > range > index > ALL"
echo "          ALL = 全表扫描（最慢），range = 索引范围扫描"
echo "  possible_keys: 可能使用的索引"
echo "  key:    实际使用的索引"
echo "  rows:   扫描的行数估计（越小越好）"
echo "  Extra:  额外信息"
echo "          Using index（覆盖索引，好）"
echo "          Using where（需要回表过滤）"
echo "          Using filesort（需要排序，差）"
echo "          Using temporary（需要临时表，差）"
echo ""
echo "Q: InnoDB vs MyISAM 核心区别？"
echo "A:"
echo "  事务:    InnoDB 支持 ACID，MyISAM 不支持"
echo "  锁:      InnoDB 行锁，MyISAM 表锁"
echo "  崩溃恢复: InnoDB 有 redo log，MyISAM 无（崩溃后需修复）"
echo "  外键:    InnoDB 支持，MyISAM 不支持"
echo "  全文索引: MyISAM 原生支持，InnoDB 5.6+ 支持"
echo "  适用:    生产环境几乎都用 InnoDB"
echo ""
echo "Q: 索引失效的常见场景？"
echo "A:"
echo "  1. 对列做函数运算: WHERE YEAR(created_at)=2024"
echo "  2. 隐式类型转换: WHERE user_id='1'（user_id 是 int）"
echo "  3. LIKE 前导通配符: WHERE name LIKE '%xxx'"
echo "  4. OR 条件部分无索引: WHERE a=1 OR b=2（b 无索引）"
echo "  5. 不等于/NOT IN: WHERE status != 'active'"
echo "  6. IS NULL / IS NOT NULL（某些情况下）"
echo "  7. 联合索引未使用最左前缀"
echo ""
echo "Q: 如何优化慢查询？"
echo "A:"
echo "  1. 确认慢查询: slow_query_log + pt-query-digest"
echo "  2. EXPLAIN 分析执行计划"
echo "  3. 添加合适的索引（覆盖索引最佳）"
echo "  4. 重写查询（避免 SELECT *，减少 JOIN）"
echo "  5. 优化表结构（垂直拆分、分区）"
echo "  6. 升级硬件（SSD、更大内存）"
echo "  7. 读写分离（主写从读）"
echo "  8. 缓存（Redis 缓存热点数据）"
echo ""

echo "=============================================="
echo "  MySQL 诊断完成"
echo "=============================================="

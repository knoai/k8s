# 性能基准：etcd 压测与调优完全手册

> etcd 是 Kubernetes 控制平面的唯一有状态组件，也是整个集群的性能瓶颈所在。
> 一个 fsync 延迟 50ms 的磁盘，会让 5000 节点集群的 API Server 写延迟飙升到不可用的程度。
> 本章从硬件选型到参数调优，提供经过生产验证的完整基准数据和调优方案。

---

## 第一章：etcd 为什么是瓶颈？

### 1.1 etcd 在 K8s 中的角色

```
K8s 控制平面的写路径：

kubectl apply → API Server → Authentication → Authorization → Admission →
  Validation → etcd (Raft 共识) → 返回响应

读路径：

kubectl get → API Server → Watch Cache / etcd → 返回响应

关键事实：
  - 所有 K8s 状态变更（Pod 创建、ConfigMap 更新、Node 状态上报）都写入 etcd
  - etcd 使用 Raft 共识算法，写操作需要 Leader 同步到多数 Follower
  - 每次写都要 fsync 到磁盘
  - etcd 的性能决定了整个 K8s 控制平面的吞吐量上限
```

### 1.2 生产故障：磁盘 fsync 延迟导致全集群瘫痪

```
故障时间线：
  2024-02-20 09:00 - 业务高峰，HPA 频繁扩缩容
  09:05 - 多个 etcd 节点 fsync P99 从 2ms 飙升到 50ms
  09:10 - etcd Leader 选举超时，发生 Leader 切换
  09:12 - API Server 写请求大量超时（> 10s）
  09:15 - Kubelet 心跳更新失败，节点被标记为 NotReady
  09:20 - Pod 被驱逐，业务中断

根因分析：
  环境：AWS EC2，使用 gp2 云盘
  gp2 特性：
    - 基准 IOPS：3 IOPS/GB
    - 100GB 卷 = 300 IOPS
    - 突发积分耗尽后，IOPS 被限制到基准值
  
   etcd 负载：
    - 5000 节点集群
    - 每秒 500+ 写操作
    - 每次写需要 fsync
    - 需要 500+ IOPS
  
  结果：
    - gp2 突发积分耗尽
    - IOPS 被限制到 300
    - fsync 延迟从 2ms → 50ms
    - heartbeat-interval=100ms，election-timeout=1000ms
    - fsync 50ms > heartbeat 100ms 的 50%
    - Follower 认为 Leader 失效，触发选举

解决方案：
  1. 磁盘升级到 gp3（3000 IOPS 基准）
  2. heartbeat-interval 从 100ms 调到 200ms
  3. 监控 etcd_disk_wal_fsync_duration_seconds，P99 > 10ms 告警
```

---

## 第二章：硬件选型基准

### 2.1 磁盘性能要求

```
etcd 的磁盘负载特征：
  - 99% 的操作是 4KB 随机写
  - 每个写操作都需要 fsync（同步刷盘）
  - 顺序读（启动时加载快照）
  
关键指标：
  ┌─────────────────┬────────┬────────┬───────────┬────────────────────┐
  │ 指标            │ 最低   │ 推荐   │ 生产级    │ 验证方法           │
  ├─────────────────┼────────┼────────┼───────────┼────────────────────┤
  │ 顺序写吞吐      │ 100MB/s│ 500MB/s│ 1000MB/s+ │ fio --rw=write     │
  │ 随机写 IOPS     │ 1000   │ 5000   │ 10000+    │ fio --rw=randwrite │
  │ fsync 延迟 P99  │ <10ms  │ <5ms   │ <2ms      │ fio --fsync=1      │
  │ 磁盘类型        │ SSD    │ NVMe   │ 企业NVMe  │ -                  │
  │ 容量            │ 50GB   │ 100GB  │ 500GB+    │ df -h /var/lib/etcd│
  └─────────────────┴────────┴────────┴───────────┴────────────────────┘

实测对比（AWS 云盘）：
  ┌─────────────────┬────────────┬─────────────┬────────────────┐
  │ 磁盘类型        │ fsync P99  │ etcd 写 TPS │ 适用规模       │
  ├─────────────────┼────────────┼─────────────┼────────────────┤
  │ gp2 (100GB)     │ 50ms       │ 200         │ < 100 节点     │
  │ gp3 (3000 IOPS) │ 10ms       │ 1000        │ < 1000 节点    │
  │ io2 (16000 IOPS)│ 5ms        │ 3000        │ < 3000 节点    │
  │ NVMe 本地盘     │ 2ms        │ 5000        │ < 5000 节点    │
  │ Intel Optane    │ 0.5ms      │ 10000+      │ 10000+ 节点    │
  └─────────────────┴────────────┴─────────────┴────────────────┘
```

### 2.2 fio 测试命令与输出解读

```bash
# 模拟 etcd 负载：4KB 随机写，每次 fsync
sudo fio --name=etcd-fsync \
  --directory=/var/lib/etcd \
  --ioengine=sync \
  --rw=randwrite \
  --bs=4k \
  --size=4g \
  --numjobs=1 \
  --fsync=1 \
  --direct=1 \
  --group_reporting \
  --runtime=60

# 关键输出解读：
# fsync/fdatasync/sync_file_range:
#   sync (usec): min=200, max=15000, avg=500, stdev=1200
# 
# 判断标准：
# - avg < 1000 us (1ms)：优秀，适合大规模集群
# - avg 1000-5000 us：可用，但大规模集群需要监控
# - avg > 10000 us (10ms)：不合格，必须升级磁盘
# - max > 100000 us (100ms)：极度危险，etcd 将频繁选举

# 如果测试结果显示不合格：
# 1. 检查是否有其他进程占用磁盘 IO
#   iostat -x 1
# 2. 检查磁盘是否达到 IOPS 上限
#   aws ec2 describe-volumes --volume-ids vol-xxxxxx
# 3. 检查是否使用正确的磁盘类型
#   lsblk -d -o NAME,TYPE,ROTA,SIZE
```

---

## 第三章：etcd 压测工具

### 3.1 etcd benchmark（官方工具）

```bash
# 安装
go install go.etcd.io/etcd/tests/v3@latest

# 写压测（模拟 K8s 写负载）
benchmark --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --target-leader \
  --conns=100 \
  --clients=1000 \
  put --key-size=256 --val-size=1024 --total=100000

# 输出解读：
# Summary:
#   Total:        100000
#   Slowest:      0.050 sec     <- 最大延迟
#   Fastest:      0.001 sec     <- 最小延迟
#   Average:      0.005 sec     <- 平均延迟
#   Rate:         20000 req/sec <- 吞吐量
#   Throughput:   20 MB/sec

# 读压测（模拟控制器 List-Watch）
benchmark --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  --conns=100 \
  --clients=1000 \
  range your-key --consistency=s --total=100000

# 一致性级别：
# - s (serializable)：从本地读取，可能读到旧数据，性能最好
# - l (linearizable)：线性一致，需要 Leader 确认，性能较差
# K8s 默认使用 serializable 读取
```

### 3.2 压测结果分级

```
┌─────────────┬──────────┬────────────┬─────────────────────────────────────┐
│ 指标        │ 健康值   │ 警告值     │ 危险值                              │
├─────────────┼──────────┼────────────┼─────────────────────────────────────┤
│ 写 TPS      │ > 5000   │ 2000-5000  │ < 2000                              │
│ 写延迟 P99  │ < 10ms   │ 10-50ms    │ > 50ms（Leader 选举风险）            │
│ 读 TPS      │ > 10000  │ 5000-10000 │ < 5000                              │
│ 读延迟 P99  │ < 5ms    │ 5-20ms     │ > 20ms                              │
│ fsync P99   │ < 2ms    │ 2-10ms     │ > 10ms                              │
└─────────────┴──────────┴────────────┴─────────────────────────────────────┘

生产环境基线测试建议：
  - 新集群上线前：必须跑 benchmark，确认 TPS > 3000
  - 季度例行测试：对比历史数据，发现性能退化
  - 扩容前测试：确认 etcd 能支撑新增负载
```

---

## 第四章：关键参数调优

### 4.1 心跳与选举超时

```bash
# 默认参数（适合同机房低延迟）
--heartbeat-interval=100    # 100ms，Leader 向 Follower 发送心跳
--election-timeout=1000     # 1000ms，Follower 多久没收到心跳就触发选举

# 跨可用区（延迟 2-5ms）
--heartbeat-interval=200
--election-timeout=2000

# 跨地域（延迟 10-50ms，不推荐用于 etcd）
--heartbeat-interval=500
--election-timeout=5000

# 调优公式：
# election-timeout >= 10 × heartbeat-interval
# election-timeout >= 网络 RTT × 5

# 为什么 heartbeat 不能太长？
# - 太长：Leader 故障检测慢，故障恢复时间增加
# - 太短：网络抖动导致不必要的选举

# 为什么 election-timeout 不能太长？
# - 太长：Leader 故障后，集群无 Leader 时间长（不可写）
# - 默认 1000ms：Leader 故障后，最多 1 秒恢复
```

### 4.2 快照与压缩

```bash
# 自动压缩（删除历史版本，减小数据库大小）
--auto-compaction-retention=1h     # 保留 1 小时历史
--auto-compaction-mode=periodic    # 周期模式（每小时压缩一次）
# 或
--auto-compaction-mode=revision    # 按 revision 压缩
--auto-compaction-retention=1000   # 保留最近 1000 个 revision

# K8s 推荐：
# - 使用 periodic 模式（每小时压缩）
# - retention = 1h（与 API Server 默认 compaction 配合）

# 快照设置
--snapshot-count=100000            # 每 10 万事务触发快照
# 调大减少快照频率，但故障恢复时间增加
# 调小增加快照频率，影响性能

# 生产建议：
# 1000 节点：snapshot-count=100000
# 5000 节点：snapshot-count=500000
# 10000 节点：snapshot-count=1000000
```

### 4.3 配额与存储

```bash
# 后端存储配额（默认 2GB 太小，大集群会频繁告警）
--quota-backend-bytes=8589934592    # 8GB
--quota-backend-bytes=17179869184   # 16GB（大规模集群）

# 最大请求大小
--max-request-bytes=33554432        # 32MB
# 处理大对象（如包含大 ConfigMap 的请求）

# 单次事务最大操作数
--max-txn-ops=128                   # 默认 128
# K8s 默认使用事务批量操作
# 如果看到 "too many operations in txn" 错误，需要调大
```

### 4.4 网络参数

```bash
# gRPC keepalive 设置
--grpc-keepalive-min-time=5s        # 客户端 keepalive 最小间隔
--grpc-keepalive-interval=2h        # 服务端发送 keepalive 间隔
--grpc-keepalive-timeout=20s        # keepalive 超时

# 为什么需要 keepalive？
# - 检测半开连接（如防火墙静默断开）
# - 保持 NAT 映射
# - 在负载均衡器后维持连接
```

---

## 第五章：内存使用估算

### 5.1 内存计算公式

```
etcd 内存 ≈ DB 大小 × 2 + Watch 连接数 × 平均键大小 × 2

示例：
- DB 大小：4GB
- Watch 连接：1000 个（100 个控制器 × 10 种资源）
- 平均键大小：1KB

内存 = 4GB × 2 + 1000 × 1KB × 2
     = 8GB + 2MB
     ≈ 8GB

推荐容器内存限制：12-16GB（留 50% 余量）

各规模集群参考：
  ┌─────────────┬────────────┬────────────┬────────────┐
  │ 集群规模    │ Pod 数量   │ etcd DB    │ 内存需求   │
  ├─────────────┼────────────┼────────────┼────────────┤
  │ 100 节点    │ 3000       │ 500MB      │ 2-4GB      │
  │ 500 节点    │ 15000      │ 2GB        │ 4-8GB      │
  │ 1000 节点   │ 30000      │ 4GB        │ 8-16GB     │
  │ 5000 节点   │ 150000     │ 16GB       │ 32-64GB    │
  │ 10000 节点  │ 300000     │ 32GB       │ 64-128GB   │
  └─────────────┴────────────┴────────────┴────────────┘
```

---

## 第六章：defrag 最佳实践

### 6.1 碎片率检查

```bash
# 检查碎片率
etcdctl endpoint status --write-out=json | jq '
  .[].Status.dbSize / .[].Status.dbSizeInUse
'
# 如果比值 > 1.5，说明碎片严重，需要 defrag

# 示例：
# dbSize = 8GB
# dbSizeInUse = 2GB
# 碎片率 = 8/2 = 4.0（极度碎片化，75% 空间浪费）
```

### 6.2 在线 defrag 脚本（不停机）

```bash
#!/bin/bash
# etcd-online-defrag.sh
# 生产环境在线 defrag，不影响可用性

ENDPOINTS="https://etcd-0:2379,https://etcd-1:2379,https://etcd-2:2379"
CERTS="--cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"

defrag_node() {
  local endpoint=$1
  
  echo "=== 检查 $endpoint ==="
  STATUS=$(etcdctl --endpoints=$endpoint $CERTS endpoint status --write-out=json)
  DB_SIZE=$(echo $STATUS | jq '.[0].Status.dbSize')
  DB_SIZE_IN_USE=$(echo $STATUS | jq '.[0].Status.dbSizeInUse')
  IS_LEADER=$(echo $STATUS | jq '.[0].Status.leader == .[0].Status.header.member_id')
  
  FRAGMENTATION=$(echo "scale=2; $DB_SIZE / $DB_SIZE_IN_USE" | bc)
  echo "  DB Size: $(($DB_SIZE / 1024 / 1024))MB"
  echo "  DB Size In Use: $(($DB_SIZE_IN_USE / 1024 / 1024))MB"
  echo "  Fragmentation: ${FRAGMENTATION}x"
  
  if [ "$IS_LEADER" = "true" ]; then
    echo "  跳过 Leader 节点（避免选举）"
    return
  fi
  
  if [ "$(echo "$FRAGMENTATION > 1.5" | bc)" -eq 1 ]; then
    echo "  开始 defrag..."
    etcdctl --endpoints=$endpoint $CERTS defrag
    
    echo "  验证..."
    etcdctl --endpoints=$endpoint $CERTS endpoint status --write-out=table
  else
    echo "  碎片率正常，跳过"
  fi
}

# 先处理 Follower
for ep in https://etcd-1:2379 https://etcd-2:2379; do
  defrag_node $ep
  sleep 10
done

# 迁移 Leader
echo "=== 迁移 Leader ==="
CURRENT_LEADER=$(etcdctl --endpoints=https://etcd-0:2379 $CERTS endpoint status --write-out=json | jq '.[0].Status.leader')
echo "当前 Leader: $CURRENT_LEADER"

# 迁移到 etcd-1
etcdctl --endpoints=https://etcd-0:2379 $CERTS move-leader <etcd-1-member-id>
sleep 5

# 对原 Leader（现在是 Follower）执行 defrag
defrag_node https://etcd-0:2379

echo "=== defrag 完成 ==="

# 建议：
# - 每月执行一次
# - 在低峰期执行（凌晨 2-4 点）
# - 每次 defrag 前创建快照备份
```

---

## 第七章：灾难恢复演练

### 7.1 季度演练检查表

```bash
#!/bin/bash
# etcd-disaster-recovery-drill.sh

set -e

BACKUP_DIR="/backup/etcd"
TEST_DIR="/tmp/etcd-test"
DATE=$(date +%Y%m%d-%H%M%S)

echo "=== etcd 灾难恢复演练 (${DATE}) ==="

# 1. 创建快照
echo "[1/5] 创建快照..."
etcdctl snapshot save ${BACKUP_DIR}/quarterly-${DATE}.db \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 2. 验证快照完整性
echo "[2/5] 验证快照..."
etcdctl snapshot status ${BACKUP_DIR}/quarterly-${DATE}.db --write-out=table
# 输出示例：
# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
# +----------+----------+------------+------------+
# | 12345678 |   523456 |     156789 |    2.5 GB  |
# +----------+----------+------------+------------+

# 3. 恢复测试（隔离环境）
echo "[3/5] 恢复测试..."
rm -rf ${TEST_DIR}
etcdctl snapshot restore ${BACKUP_DIR}/quarterly-${DATE}.db \
  --data-dir=${TEST_DIR} \
  --name=test-etcd \
  --initial-cluster=test-etcd=https://127.0.0.1:2380 \
  --initial-cluster-token=test-${DATE} \
  --initial-advertise-peer-urls=https://127.0.0.1:2380

# 4. 启动测试 etcd
echo "[4/5] 启动测试 etcd..."
etcd --data-dir=${TEST_DIR} \
  --listen-client-urls=http://127.0.0.1:22379 \
  --advertise-client-urls=http://127.0.0.1:22379 \
  --listen-peer-urls=http://127.0.0.1:22380 &
ETCD_PID=$!
sleep 5

# 5. 验证数据完整性
echo "[5/5] 验证数据..."
TEST_KEYS=$(ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:22379 get "" --prefix --keys-only | wc -l)
PROD_KEYS=$(etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get "" --prefix --keys-only | wc -l)

echo "  生产环境键数量: $PROD_KEYS"
echo "  恢复后键数量: $TEST_KEYS"

if [ "$TEST_KEYS" -eq "$PROD_KEYS" ]; then
  echo "  验证通过"
else
  echo "  警告：键数量不一致！"
fi

# 清理
kill $ETCD_PID 2>/dev/null || true
rm -rf ${TEST_DIR}

echo "=== 演练完成 ==="
```

---

## 第八章：面试核心考点

```
Q: 为什么 etcd 是 K8s 的性能瓶颈？

A:
   1. 单点写入：所有状态变更都要经过 etcd，没有分片
   2. Raft 共识：写操作需要 Leader + 多数 Follower 确认
   3. fsync 限制：每次写都要刷盘，磁盘 IOPS 是硬上限
   4. 读放大：List 所有 Pod 需要遍历整个键空间
   
   优化方向：
   - 磁盘：使用 NVMe/Optane，fsync < 2ms
   - 网络：同机房部署，RTT < 1ms
   - API Server：增大 watch cache，减少 etcd 查询
   - 应用：减少无意义的 Label Selector 变更

Q: etcd heartbeat-interval 和 election-timeout 如何调优？

A:
   基本原则：
   - election-timeout >= 10 × heartbeat-interval
   - election-timeout >= 网络 RTT × 5
   
   同机房：
   - heartbeat=100ms, election=1000ms
   - Leader 故障检测时间：1 秒
   
   跨可用区：
   - RTT = 2-5ms
   - heartbeat=200ms, election=2000ms
   - 容忍短暂的网络抖动
   
   跨地域（不推荐）：
   - RTT = 10-50ms
   - heartbeat=500ms, election=5000ms
   - Leader 故障检测时间：5 秒（太长）
   
   为什么跨地域不适合 etcd？
   - 写延迟 = RTT × 2（Leader → Follower → Ack）
   - RTT 50ms → 写延迟 100ms → TPS 只有 10
   - K8s 集群无法正常工作

Q: etcd 的 DB 为什么会增长？如何管理？

A:
   增长原因：
   1. K8s 所有资源变更都产生新的 revision
   2. 每个 revision 都保留历史（用于 Watch 和回滚）
   3. 默认不会自动清理历史 revision
   
   管理方法：
   1. 自动压缩（auto-compaction）：
      - periodic 模式：每小时删除 1 小时前的历史
      - revision 模式：保留最近 N 个 revision
   2. 手动压缩：
      etcdctl compact $(etcdctl endpoint status --write-out=json | jq '.[0].Status.header.revision')
   3. defrag：
      - 压缩后 DB 文件不会缩小，需要 defrag 释放空间
      - 在线 defrag：逐个节点执行，先处理 Follower
   
   监控指标：
   - etcd_mvcc_db_total_size_in_bytes
   - etcd_mvcc_db_total_size_in_use_in_bytes
   - 两者比值 > 1.5 → 需要 defrag
```

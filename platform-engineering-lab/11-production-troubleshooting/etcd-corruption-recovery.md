# 生产排障：etcd 数据损坏与恢复

> etcd 是 Kubernetes 的单一数据源（Single Source of Truth）。etcd 故障会导致整个集群不可用。
> 本节提供从预防到恢复的完整流程，含真实命令输出和数值。

---

## etcd 在 K8s 中的关键作用

```
API Server ←─gRPC──→ etcd (3 节点 Raft 集群)
                        │
                        ├─ 存储所有 K8s 资源（Pod/Service/Secret/ConfigMap/...）
                        ├─ 存储集群状态（Node 信息、Lease）
                        ├─ 存储事件（Events）
                        └─ 实现乐观锁（resourceVersion）
```

### 资源占用参考

| 集群规模 | etcd 数据大小 | 内存使用 | 存储 IOPS 要求 | 网络延迟要求 |
|---------|-------------|---------|--------------|-----------|
| 小型 (<100 Node) | 100MB-500MB | 512MB-2GB | 3000+ (顺序写) | <10ms |
| 中型 (100-500 Node) | 500MB-2GB | 2GB-4GB | 5000+ | <5ms |
| 大型 (500-2000 Node) | 2GB-8GB | 4GB-8GB | 10000+ NVMe | <2ms |
| 超大型 (2000+ Node) | 8GB-50GB | 8GB-16GB | 20000+ NVMe Optane | <1ms |

---

## 场景 1：etcd 磁盘空间满

### 现象

```bash
# API Server 日志
kubectl logs <apiserver-pod> -n kube-system | grep -i etcd | tail -20

# 输出：
# E0115 08:30:00.123456       1 status.go:71] apiserver received an error that is not an metav1.Status: 
#   rpc error: code = ResourceExhausted desc = etcdserver: mvcc: database space exceeded
# E0115 08:30:00.234567       1 watcher.go:123] failed to create watcher for 
#   *v1.Pod: etcdserver: mvcc: database space exceeded

# kubectl 命令表现
kubectl get pods
# Error from server: etcdserver: mvcc: database space exceeded

# etcd 日志
kubectl logs -n kube-system etcd-<node> | tail -20

# 输出：
# 2024-01-15 08:30:00.123456 W | etcdserver: read-only range request 
#   "key:\"/registry/pods/\" " took too long (2.345s) to execute
# 2024-01-15 08:30:00.234567 E | etcdserver: cannot fetch v2 version (context deadline exceeded)
```

### 诊断

```bash
# 1. 检查 etcd 数据目录大小
kubectl exec -it etcd-<node> -n kube-system -- /bin/sh -c '
  du -sh /var/lib/etcd/member/snap/db
  du -sh /var/lib/etcd/member/wal
'

# 输出：
# 8.0G    /var/lib/etcd/member/snap/db   ← 数据库 8GB！
# 2.0G    /var/lib/etcd/member/wal       ← WAL 2GB

# 2. 检查 etcd 配额
ectl endpoint status --cluster -w table

# 输出：
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
# | 10.0.1.10:2379 | 1234567890abcdef |  3.5.4  |  8.0 GB |      true |      false |        12 |    1234567 |            1234567 |        |
# | 10.0.1.11:2379 | fedcba0987654321 |  3.5.4  |  8.0 GB |     false |      false |        12 |    1234567 |            1234567 |        |
# | 10.0.1.12:2379 | aabbccdd11223344 |  3.5.4  |  8.0 GB |     false |      false |        12 |    1234567 |            1234567 |        |
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+

# 3. 检查默认配额（默认 8GB）
ectl get / --prefix --keys-only | wc -l
# 1234567  ← 120 万+ key！

# 4. 按资源类型统计 key 数量
kubectl exec etcd-<node> -n kube-system -- etcdctl get / --prefix --keys-only | grep -oE '^/registry/[^/]+' | sort | uniq -c | sort -rn | head -20

# 输出：
#   500000 /registry/events           ← 50 万事件！
#   200000 /registry/pods
#   150000 /registry/replicasets
#   100000 /registry/secrets
#    50000 /registry/configmaps
#    30000 /registry/endpointslices
#    20000 /registry/services
#    10000 /registry/namespaces
#     5000 /registry/nodes
# ← 事件数量占 40%！
```

### 根因分析

| 根因 | 场景 | 数值 |
|------|------|------|
| 事件未清理 | 默认事件保留 1 小时，但大量 Pod 创建/删除产生海量事件 | events key 占 40-80% |
| 大量 Lease | 大量 Node 的 kubelet 心跳 Lease | 1 个 Node = 1 个 Lease |
| CRD 对象膨胀 | 大量 CRD 实例（如 Argo Workflow） | 每个 Workflow = 多个 CRD 对象 |
| 缺少 compaction | etcd compaction 未执行或间隔过长 | 默认 auto-compaction 每 5 分钟 |
| 缺少 defragment | 碎片率高但未整理 | 碎片率 > 50% 时应该 defrag |

### 修复

```bash
# === 紧急修复 ===

# 1. 手动 compaction（压缩历史版本）
# ⚠️ 需要集群可用，如不可用则跳过此步
kubectl exec etcd-<leader> -n kube-system -- etcdctl compaction $(etcdctl endpoint status --write-out="json" | grep revision | sed 's/.*revision":\([0-9]*\).*/\1/')

# 2. 手动 defragment
# ⚠️ 逐节点执行，每节点 defrag 时集群仍有 2/3 节点可用
for NODE in 10.0.1.10 10.0.1.11 10.0.1.12; do
  echo "Defragmenting $NODE..."
  kubectl exec etcd-$NODE -n kube-system -- etcdctl defrag --cluster
  sleep 30
done

# 验证
etcdctl endpoint status --cluster -w table
# DB SIZE 应从 8GB 降到 1-2GB

# === 长期修复 ===

# 3. 设置 etcd 配额警告和自动清理
# 在 etcd 启动参数中添加：
# --quota-backend-bytes=8589934592  # 8GB（默认也是 8GB，可增大到 16GB）
# --auto-compaction-retention=1h    # 每小时自动 compaction

# 4. 配置事件 TTL
cat > event-ttl-patch.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - name: kube-apiserver
    command:
    - kube-apiserver
    - --event-ttl=5m          # 事件只保留 5 分钟（默认 1 小时）
    - --audit-log-maxage=30   # 审计日志保留 30 天
EOF
# 注意：需要修改 kube-apiserver 静态 Pod 配置

# 5. 定期清理历史事件（CronJob）
cat > cleanup-events.yaml <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cleanup-events
  namespace: kube-system
spec:
  schedule: "0 */6 * * *"  # 每 6 小时执行一次
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: event-cleanup
          containers:
          - name: cleanup
            image: bitnami/kubectl
            command:
            - /bin/sh
            - -c
            - |
              # 删除 1 小时前的事件
              kubectl delete events --all-namespaces \
                --field-selector=lastTimestamp<$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
          restartPolicy: OnFailure
EOF
```

---

## 场景 2：etcd 节点分裂（Split Brain）

### 现象

```bash
# 集群状态不一致
kubectl get nodes
# Error from server: etcdserver: request timed out

# 检查 etcd 成员状态
etcdctl member list

# 输出：
# 1234567890abcdef, started, etcd-1, http://10.0.1.10:2380, http://10.0.1.10:2379, false
# fedcba0987654321, started, etcd-2, http://10.0.1.11:2380, http://10.0.1.11:2379, false
# aabbccdd11223344, started, etcd-3, http://10.0.1.12:2380, http://10.0.1.12:2379, false
# ← 所有节点都显示 started，但无法写入

# 检查各节点的 endpoint status
for NODE in 10.0.1.10 10.0.1.11 10.0.1.12; do
  echo "=== $NODE ==="
  etcdctl --endpoints=$NODE:2379 endpoint status
done

# 输出：
# === 10.0.1.10 ===
# 1234567890abcdef, 3.5.4, 1.0 GB, false, false, 10, 1234567, 1234567
# 
# === 10.0.1.11 ===
# fedcba0987654321, 3.5.4, 1.0 GB, false, false, 8, 1234000, 1234000
# ← Raft Term 不同！10 vs 8
# ← Raft Index 不同！1234567 vs 1234000
# 
# === 10.0.1.12 ===
# aabbccdd11223344, 3.5.4, 1.0 GB, false, false, 8, 1234000, 1234000
# ← 节点 2 和 3 的 term/index 一致，但节点 1 不同
```

### 根因

```
典型场景：
1. 网络分区导致 Leader（节点 1）与其他节点失联
2. 节点 1 作为旧 Leader 继续接受写请求（但无法提交）
3. 节点 2 和 3 选举出新 Leader（term 增加）
4. 网络恢复后，节点 1 的数据与新 Leader 不一致
5. 由于节点 1 的数据更新但 term 更旧，Raft 不会自动同步
```

### 修复

```bash
# === 修复：让数据最新的节点成为 Leader ===

# 1. 停止有问题的节点（节点 1）
kubectl exec etcd-<node1> -n kube-system -- pkill etcd

# 2. 从成员列表中移除（必须在多数派节点上执行）
ectl member remove 1234567890abcdef

# 验证
etcdctl member list
# 只剩 2 个节点

# 3. 在节点 1 上删除数据目录（⚠️ 数据丢失风险！先备份！）
kubectl exec etcd-<node1> -n kube-system -- /bin/sh -c '
  mv /var/lib/etcd/member /var/lib/etcd/member.bak.$(date +%Y%m%d_%H%M%S)
'

# 4. 重新加入节点（作为全新成员）
# 获取加入 token
TOKEN=$(etcdctl member add etcd-1 --peer-urls=http://10.0.1.10:2380 | grep ETCD_INITIAL_CLUSTER | cut -d'"' -f2)

# 在节点 1 上以新成员模式启动
kubectl exec etcd-<node1> -n kube-system -- etcd \
  --name etcd-1 \
  --initial-advertise-peer-urls http://10.0.1.10:2380 \
  --listen-peer-urls http://0.0.0.0:2380 \
  --listen-client-urls http://0.0.0.0:2379 \
  --advertise-client-urls http://10.0.1.10:2379 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-cluster $TOKEN \
  --initial-cluster-state existing

# 5. 验证集群恢复
etcdctl endpoint status --cluster -w table
# 3 个节点状态一致

# 6. 验证 K8s 恢复
kubectl get nodes
kubectl get pods --all-namespaces
```

---

## 场景 3：etcd 数据损坏（WAL/Snap 损坏）

### 现象

```bash
# etcd 无法启动
kubectl logs etcd-<node> -n kube-system

# 输出：
# 2024-01-15 08:30:00.123456 C | etcdmain: database file (/var/lib/etcd/member/snap/db) 
#   is corrupted or invalid: file index [1230000] does not match expected index [1234567]
# 2024-01-15 08:30:00.234567 C | etcdmain: cannot fetch cluster info from peer urls:
#   could not open database (open /var/lib/etcd/member/snap/db: file is not a valid database)
```

### 修复

```bash
# === 方法 1：从快照恢复（推荐） ===

# 1. 停止损坏的节点
kubectl exec etcd-<bad-node> -n kube-system -- pkill etcd

# 2. 从健康节点获取最新快照
kubectl exec etcd-<good-node> -n kube-system -- etcdctl snapshot save /tmp/snapshot.db
kubectl cp kube-system/etcd-<good-node>:/tmp/snapshot.db ./snapshot.db

# 验证快照
etcdctl snapshot status snapshot.db -w table
# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
# +----------+----------+------------+------------+
# | abc123de |  1234567 |     500000 |     1.0 GB |
# +----------+----------+------------+------------+

# 3. 在损坏节点上恢复
kubectl cp ./snapshot.db kube-system/etcd-<bad-node>:/tmp/snapshot.db

kubectl exec etcd-<bad-node> -n kube-system -- etcdctl snapshot restore /tmp/snapshot.db \
  --name etcd-bad \
  --initial-cluster etcd-bad=http://10.0.1.10:2380,etcd-2=http://10.0.1.11:2380,etcd-3=http://10.0.1.12:2380 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-advertise-peer-urls http://10.0.1.10:2380 \
  --data-dir /var/lib/etcd

# 4. 重新启动 etcd
# 如果 etcd 是静态 Pod，删除 Pod 会自动重建
kubectl delete pod etcd-<bad-node> -n kube-system

# === 方法 2：从其他节点同步（如果 WAL 只损坏部分） ===

# 1. 停止损坏节点
kubectl exec etcd-<bad-node> -n kube-system -- pkill etcd

# 2. 备份并删除数据
kubectl exec etcd-<bad-node> -n kube-system -- /bin/sh -c '
  mkdir -p /var/lib/etcd-backup
  cp -r /var/lib/etcd/member /var/lib/etcd-backup/
  rm -rf /var/lib/etcd/member
'

# 3. 重新启动（etcd 会自动从 Leader 同步）
kubectl delete pod etcd-<bad-node> -n kube-system

# ⚠️ 注意：如果 snap/db 也损坏，此方法无效，必须使用快照恢复
```

---

## 场景 4：etcd 性能下降

### 现象

```bash
# API Server 响应慢
kubectl get pods --all-namespaces
# 耗时 5-10 秒（正常 <1 秒）

# etcd 延迟指标
etcdctl check perf --load="s"

# 正常输出：
#  PASS: Throughput is 150 writes/s
#  PASS: Slowest request took 0.234s
#  PASS: Stddev is 0.045s
#  PASS

# 异常输出：
#  FAIL: Throughput is 45 writes/s (expected minimum 100 writes/s)
#  FAIL: Slowest request took 5.678s (expected maximum 0.5s)
#  FAIL: Stddev is 2.345s (expected maximum 0.1s)
#  FAIL
```

### 诊断

```bash
# 1. 检查 etcd 磁盘延迟
kubectl exec etcd-<node> -n kube-system -- /bin/sh -c '
  dd if=/dev/zero of=/var/lib/etcd/test-write bs=4k count=1000 oflag=dsync
'

# 正常（SSD/NVMe）：
# 1000+0 records in
# 1000+0 records out
# 4096000 bytes (4.1 MB, 3.9 MiB) copied, 0.234567 s, 17.5 MB/s
# ← 4MB 写入 0.23 秒，足够快

# 异常（HDD/网络存储）：
# 1000+0 records in
# 1000+0 records out
# 4096000 bytes (4.1 MB, 3.9 MiB) copied, 12.345678 s, 332 kB/s
# ← 4MB 写入 12 秒！太慢了

# 2. 检查 etcd 内存使用
kubectl top pod etcd-<node> -n kube-system

# 正常：
# NAME          CPU(cores)   MEMORY(bytes)
# etcd-node1    100m         1024Mi

# 异常：
# NAME          CPU(cores)   MEMORY(bytes)
# etcd-node1    800m         4096Mi          ← CPU 和内存都很高

# 3. 检查 gRPC 指标
curl http://<etcd-metrics>:2381/metrics 2>/dev/null | grep -E "etcd_disk_wal_fsync_duration_seconds|etcd_disk_backend_commit_duration_seconds"

# 正常：
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.001"} 12345
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.01"} 67890
# etcd_disk_backend_commit_duration_seconds_bucket{le="0.001"} 23456
# etcd_disk_backend_commit_duration_seconds_bucket{le="0.01"} 78901
# ← 大部分操作 <10ms

# 异常：
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.001"} 123
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.01"} 456
# etcd_disk_wal_fsync_duration_seconds_bucket{le="0.1"} 7890
# etcd_disk_wal_fsync_duration_seconds_bucket{le="1.0"} 12345
# ← 大量操作 >100ms！
```

### 修复

```bash
# 修复 1：提升磁盘性能
# etcd 必须使用 SSD 或 NVMe，HDD 不可接受
# 如果使用云盘：
# - AWS：gp3 3000 IOPS 以上，或 io2
# - 阿里云：ESSD PL1/PL2
# - GCP：pd-ssd

# 修复 2：分离 etcd 磁盘
# etcd 数据目录使用独立磁盘
# /var/lib/etcd 挂载到专用 NVMe

# 修复 3：调整 etcd 参数
cat > /etc/kubernetes/manifests/etcd.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: etcd
  namespace: kube-system
spec:
  containers:
  - name: etcd
    command:
    - etcd
    - --name=$(NODE_NAME)
    - --quota-backend-bytes=17179869184  # 增大到 16GB
    - --heartbeat-interval=100            # 降低心跳间隔（网络好时）
    - --election-timeout=500              # 降低选举超时
    - --snapshot-count=50000              # 更频繁做快照
    - --max-snapshots=5
    - --max-wals=5
    - --auto-compaction-retention=1h
EOF

# 修复 4：限制事件数量
# 设置 kube-apiserver 事件 TTL
# --event-ttl=5m

# 修复 5：如果内存不足，升级 etcd 节点内存
# 或者减少 etcd 存储的数据量
```

---

## 预防性监控

### Prometheus 告警规则

```yaml
groups:
- name: etcd
  rules:
  - alert: etcdDBSizeHigh
    expr: etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes > 0.8
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "etcd DB size is over 80%"
      description: "etcd DB size is {{ $value | humanizePercentage }} of quota"

  - alert: etcdFsyncSlow
    expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "etcd WAL fsync is too slow"
      description: "P99 WAL fsync is {{ $value }}s (should be <0.1s)"

  - alert: etcdNoLeader
    expr: etcd_server_has_leader{job="etcd"} == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "etcd has no leader"

  - alert: etcdHighNumberOfFailedGRPCRequests
    expr: sum(rate(etcd_grpc_requests_failed_total[5m])) / sum(rate(etcd_grpc_total[5m])) > 0.01
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "etcd gRPC request failure rate is high"
      description: "Failure rate is {{ $value | humanizePercentage }}"

  - alert: etcdHighMemoryUsage
    expr: process_resident_memory_bytes{job="etcd"} / 1024 / 1024 / 1024 > 8
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "etcd memory usage is high"
      description: "Memory usage is {{ $value }}GB"
```

---

## 一键 etcd 健康检查脚本

```bash
#!/bin/bash
# etcd-health-check.sh
# 在 etcd 节点上执行

ETCDCTL="etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

echo "=========================================="
echo "  etcd 健康检查"
echo "=========================================="

echo ""
echo "=== 1. 集群状态 ==="
$ETCDCTL endpoint status --cluster -w table

echo ""
echo "=== 2. 成员列表 ==="
$ETCDCTL member list -w table

echo ""
echo "=== 3. 集群健康 ==="
$ETCDCTL endpoint health --cluster

echo ""
echo "=== 4. DB 大小 ==="
DB_SIZE=$($ETCDCTL endpoint status --cluster -w json | grep -o '"dbSize":[0-9]*' | head -1 | cut -d: -f2)
echo "DB Size: $(echo "scale=2; $DB_SIZE / 1024 / 1024 / 1024" | bc) GB"

echo ""
echo "=== 5. 键值数量 ==="
KEY_COUNT=$($ETCDCTL get / --prefix --keys-only | wc -l)
echo "Key count: $KEY_COUNT"

echo ""
echo "=== 6. 事件数量 ==="
EVENT_COUNT=$($ETCDCTL get /registry/events --prefix --keys-only | wc -l)
echo "Event count: $EVENT_COUNT"

echo ""
echo "=== 7. 磁盘延迟测试 ==="
dd if=/dev/zero of=/var/lib/etcd/test-write bs=4k count=1000 oflag=dsync 2>&1 | tail -1
rm -f /var/lib/etcd/test-write

echo ""
echo "=== 8. 性能测试 ==="
$ETCDCTL check perf --load="s" 2>&1 | tail -5

echo ""
echo "=== 9. 碎片化检查 ==="
$ETCDCTL endpoint status --cluster -w json | grep -o '"dbSizeInUse":[0-9]*' | head -1
echo ""
echo "=== 10. 告警检查 ==="
# 检查常见告警
$ETCDCTL alarm list 2>/dev/null || echo "无告警"

echo ""
echo "=========================================="
echo "  检查完成"
echo "=========================================="
```

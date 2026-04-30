# Thanos 深度解析

> Thanos 是 Prometheus 生态中最成熟的长期存储与全局查询方案。理解其架构组件、部署模式和性能优化，是构建大规模可观测性平台的核心能力。

---

## 1. 为什么需要 Thanos

```
Prometheus 单机局限:

┌─────────────────────────────────────────────────────────────┐
│                    单机 Prometheus                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  问题 1: 存储限制                                            │
│    - 本地 TSDB 默认 15 天保留                                │
│    - 单机磁盘有限（通常几百 GB）                             │
│    - 无法查询历史数据（如 3 个月前的指标）                    │
│                                                             │
│  问题 2: 高可用                                              │
│    - 单节点故障 = 监控中断                                   │
│    - 无法实现真正的多副本                                   │
│                                                             │
│  问题 3: 全局视图                                            │
│    - 多集群/多区域各自部署 Prometheus                        │
│    - 无法统一查询所有集群数据                                │
│    - 跨集群告警难以实现                                     │
│                                                             │
│  问题 4: 数据持久化                                          │
│    - 节点重建后历史数据丢失                                  │
│    - 无法进行容量规划分析                                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘

Thanos 解决之道:
  ✓ 对象存储集成 (S3/GCS/Azure Blob/MinIO) — 无限存储
  ✓ Sidecar / Receiver 模式 — 灵活的数据上传
  ✓ Store Gateway + Querier — 全局统一查询
  ✓ Compactor — 数据降采样与压缩
  ✓ Ruler — 全局告警与 Recording Rules
```

---

## 2. Thanos 架构全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Thanos 架构全景                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                    │
│   │ Prometheus  │    │ Prometheus  │    │ Prometheus  │  ← 多个 Prometheus │
│   │  Cluster A  │    │  Cluster B  │    │  Cluster C  │                    │
│   │             │    │             │    │             │                    │
│   │ + Sidecar   │    │ + Sidecar   │    │ + Sidecar   │  ← Sidecar 上传数据│
│   │   (或       │    │   (或       │    │   (或       │                    │
│   │   Receiver) │    │   Receiver) │    │   Receiver) │                    │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                    │
│          │                  │                  │                            │
│          │  Upload blocks   │  Upload blocks   │  Upload blocks             │
│          │  (每 2h)         │  (每 2h)         │  (每 2h)                   │
│          ▼                  ▼                  ▼                            │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                    对象存储 (Object Storage)                         │  │
│   │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐      │  │
│   │  │Block 001│ │Block 002│ │Block 003│ │Block... │ │Block N  │      │  │
│   │  │(2h数据) │ │(2h数据) │ │(2h数据) │ │         │ │(降采样) │      │  │
│   │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘      │  │
│   │                                                                     │  │
│   │  存储格式: Prometheus TSDB block (immutable)                       │  │
│   │  云厂商: AWS S3 / GCP GCS / Azure Blob / MinIO / Ceph / COS        │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│          ▲                                                                  │
│          │  Serve blocks                                                    │
│          │                                                                  │
│   ┌──────┴──────┐  ┌─────────────┐  ┌─────────────┐                        │
│   │Store Gateway│  │  Compactor  │  │    Ruler    │                        │
│   │             │  │             │  │             │                        │
│   │ - 发现对象  │  │ - 数据压缩  │  │ - 全局告警  │                        │
│   │   存储中的  │  │ - 降采样    │  │ - Recording │                        │
│   │   blocks    │  │   (5m/1h)   │  │   Rules     │                        │
│   │ - 提供查询  │  │ - 保留策略  │  │ - 写入结果  │                        │
│   │   接口      │  │   (如 1年)  │  │   到对象存储│                        │
│   └──────┬──────┘  └─────────────┘  └──────┬──────┘                        │
│          │                                  │                               │
│          │  StoreAPI gRPC                   │ StoreAPI gRPC                  │
│          └────────────────┬─────────────────┘                               │
│                           │                                                 │
│                    ┌──────▼──────┐                                          │
│                    │   Querier   │  ← 统一查询入口                           │
│                    │             │                                          │
│                    │ - 聚合所有  │  HTTP: /api/v1/query                     │
│                    │   StoreAPI  │  HTTP: /api/v1/query_range               │
│                    │ - 去重      │  兼容 Prometheus API                     │
│                    │ - 查询分发  │                                          │
│                    └──────┬──────┘                                          │
│                           │                                                 │
│                    ┌──────▼──────┐                                          │
│                    │   Grafana   │  ← 数据源配置为 Querier                  │
│                    │  / Alertm.  │                                          │
│                    └─────────────┘                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心组件详解

### 3.1 Sidecar 模式

```
Sidecar 模式（推荐，最常用）:

┌─────────────────────────────────────────────────────────────┐
│                    Prometheus Pod                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐      ┌─────────────────┐              │
│  │   Prometheus    │◄────►│  Thanos Sidecar │              │
│  │                 │      │                 │              │
│  │ - 本地采集      │      │ - 读取 TSDB     │              │
│  │ - 本地查询      │      │ - 上传 block    │              │
│  │ - 2h 生成 block │      │   到对象存储    │              │
│  │                 │      │ - 提供 StoreAPI │              │
│  └─────────────────┘      └────────┬────────┘              │
│                                    │                        │
│                                    │ Upload (每 2h)         │
│                                    ▼                        │
│                              ┌──────────┐                   │
│                              │  S3/GCS  │                   │
│                              └──────────┘                   │
│                                                             │
│  部署方式:                                                   │
│    - Sidecar 作为同一 Pod 的容器与 Prometheus 一起运行        │
│    - 共享 Prometheus 数据目录                                │
│                                                             │
│  优点:                                                       │
│    ✓ 简单，与现有 Prometheus 部署兼容                        │
│    ✓ 利用 Prometheus 的高可用（多副本各自上传）               │
│    ✓ 实时数据在 Prometheus，历史在对象存储                    │
│                                                             │
│  缺点:                                                       │
│    ✗ 每个 Prometheus 需要配一个 Sidecar                     │
│    ✗ 依赖 Prometheus 本地存储（不能缩小）                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘

Sidecar 上传配置:

# thanos-objstore.yaml
type: S3
config:
  bucket: "thanos-metrics"
  endpoint: "s3.amazonaws.com"
  region: "us-east-1"
  access_key: "..."
  secret_key: "..."
  insecure: false
  signature_version2: false
  put_user_metadata:
    X-Storage-Class: "STANDARD_IA"
  http_config:
    idle_conn_timeout: 0s
    response_header_timeout: 0s
    insecure_skip_verify: false

# Prometheus 启动参数
prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=15d \
  --storage.tsdb.min-block-duration=2h \
  --storage.tsdb.max-block-duration=2h  # 固定 2h，与 Thanos 对齐

# Sidecar 启动参数
thanos sidecar \
  --tsdb.path=/prometheus \
  --prometheus.url=http://localhost:9090 \
  --grpc.address=0.0.0.0:10901 \
  --http.address=0.0.0.0:10902 \
  --objstore.config-file=/etc/thanos/objstore.yml
```

### 3.2 Receiver 模式

```
Receiver 模式（Push 模式，适合短期数据/无本地存储）:

┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  Prometheus ──remote_write──► Thanos Receiver               │
│  (无本地存储)                  (StatefulSet)                  │
│                                 │                            │
│                                 │ 攒够 2h 数据                │
│                                 ▼                            │
│                              对象存储                        │
│                                                             │
│  部署方式:                                                   │
│    - Receiver 作为独立 StatefulSet 运行                     │
│    - Prometheus 配置 remote_write 指向 Receiver             │
│    - Receiver 本地暂存，满 2h 后上传对象存储                  │
│                                                             │
│  优点:                                                       │
│    ✓ Prometheus 不需要本地大存储                            │
│    ✓ 适合边缘/轻量 Prometheus 场景                          │
│    ✓ 可以聚合多个 Prometheus 写入                           │
│                                                             │
│  缺点:                                                       │
│    ✗ Receiver 本身需要高可用（有状态）                      │
│    ✗ 额外一跳，增加延迟                                     │
│    ✗ 容量规划复杂（Receiver 本地磁盘）                      │
│                                                             │
│  适用场景:                                                   │
│    • 边缘集群 Prometheus 轻量部署                           │
│    • 无状态/无本地盘的 Prometheus                           │
│    • 多租户写入隔离                                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘

Receiver 配置:

# Prometheus remote_write
remote_write:
  - url: http://thanos-receiver:19291/api/v1/receive
    queue_config:
      capacity: 10000
      max_samples_per_send: 1000
      max_shards: 200
    write_relabel_configs:
      - source_labels: [__name__]
        regex: 'go_.*'
        action: drop  # 可选过滤

# Receiver 启动
thanos receive \
  --objstore.config-file=/etc/thanos/objstore.yml \
  --tsdb.path=/var/thanos/receive \
  --grpc.address=0.0.0.0:10901 \
  --http.address=0.0.0.0:10902 \
  --receive.local-endpoint=$(POD_NAME).thanos-receiver:10901 \
  --receive.hashrings-file=/etc/thanos/hashrings.json
```

### 3.3 Store Gateway

```
Store Gateway:

职责:
  1. 从对象存储发现 blocks
  2. 将 block index 加载到本地内存/磁盘
  3. 通过 StoreAPI 提供查询服务

启动参数:
thanos store \
  --objstore.config-file=/etc/thanos/objstore.yml \
  --data-dir=/var/thanos/store \
  --grpc.address=0.0.0.0:10901 \
  --http.address=0.0.0.0:10902 \
  --index-cache-size=250MB \
  --bucket-cache-size=250MB \
  --chunk-pool-size=2GB \
  --store.grpc.series-sample-limit=0 \
  --store.grpc.series-max-concurrency=20

关键调优参数:
  --index-cache-size    # 索引缓存，越大查询越快
  --bucket-cache-size   # bucket 元数据缓存
  --chunk-pool-size     # chunk 数据池

内存计算公式:
  Store Gateway 内存 ≈ index-cache-size + bucket-cache-size + chunk-pool-size + 开销
  建议至少 4-8GB
```

### 3.4 Compactor

```
Compactor:

职责:
  1. 压缩 (Compaction): 合并小的 blocks，优化查询性能
  2. 降采样 (Downsampling): 生成 5m 和 1h 分辨率的数据
  3. 保留 (Retention): 按策略删除过期数据

┌─────────────────────────────────────────────────────────────┐
│                    降采样原理                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  原始数据 (raw): 15s 采集间隔                                │
│    ──●──●──●──●──●──●──●──●──●──●──●──●──●──●──●──        │
│                                                             │
│  5m 降采样: 每 5 分钟取一个样本                              │
│    ──●──────────●──────────●──────────●──────────●──        │
│                                                             │
│  1h 降采样: 每小时取一个样本                                 │
│    ──●────────────────────●────────────────────●──          │
│                                                             │
│  查询策略:                                                   │
│    - 最近 1 天: 查 raw 数据                                  │
│    - 1 天 ~ 1 周: 查 5m 降采样                              │
│    - 1 周前: 查 1h 降采样                                   │
│                                                             │
│  存储节省:                                                   │
│    - 原始数据 100GB                                          │
│    - + 5m 降采样 ≈ +20GB                                    │
│    - + 1h 降采样 ≈ +5GB                                     │
│    - 总计 ≈ 125GB (可查询 1 年)                             │
│    - 不压缩 1 年需要 ≈ 2.4TB                                │
│                                                             │
└─────────────────────────────────────────────────────────────┘

Compactor 配置:
thanos compact \
  --objstore.config-file=/etc/thanos/objstore.yml \
  --data-dir=/var/thanos/compact \
  --retention.resolution-raw=30d \
  --retention.resolution-5m=120d \
  --retention.resolution-1h=1y \
  --downsample.concurrency=4 \
  --compact.concurrency=4 \

# 注意: Compactor 必须是单实例运行！
# 使用 pod 反亲和性确保只有一个实例在运行
```

### 3.5 Querier

```
Querier:

职责:
  - 聚合多个 StoreAPI 源（Sidecar/Store/Ruler/Receiver）
  - 提供与 Prometheus 兼容的 HTTP API
  - 对查询结果去重（多副本 Prometheus 场景）

启动参数:
thanos query \
  --http.address=0.0.0.0:9090 \
  --grpc.address=0.0.0.0:10901 \
  --store=thanos-sidecar-1:10901 \
  --store=thanos-sidecar-2:10901 \
  --store=thanos-store:10901 \
  --store=thanos-rule:10901 \
  --query.replica-label=replica \
  --query.auto-downsampling \
  --query.partial-response \
  --query.max-concurrent=20 \
  --query.timeout=2m

关键参数:
  --store                    # 指定 StoreAPI 端点
  --query.replica-label      # 去重标签（如 replica=prometheus-0）
  --query.auto-downsampling  # 自动选择降采样级别
  --query.partial-response   # 部分 Store 失败时仍返回结果

高可用部署:
  - 部署多个 Querier 实例
  - 前面放负载均衡（Nginx/HAProxy/Service）
  - Grafana 配置多个 Querier 数据源（可配 Alert）
```

### 3.6 Ruler

```
Ruler:

职责:
  - 评估全局 Recording Rules 和 Alerting Rules
  - 将结果写入对象存储（Recording 结果）
  - 发送告警到 Alertmanager

启动参数:
thanos rule \
  --data-dir=/var/thanos/rule \
  --rule-file=/etc/thanos/rules/*.yml \
  --alertmanagers.url=http://alertmanager:9093 \
  --query=http://thanos-query:9090 \
  --objstore.config-file=/etc/thanos/objstore.yml \
  --label=ruler_cluster=prod \
  --alert.query-url=http://thanos-query:9090

Recording Rules 示例:
groups:
  - name: thanos_global
    interval: 30s
    rules:
      - record: cluster:node_cpu_usage:rate5m
        expr: |
          sum by (cluster) (
            rate(node_cpu_seconds_total{mode!="idle"}[5m])
          )

告警规则与本地 Prometheus 的区别:
  - Ruler 可以跨多个 Prometheus 评估规则
  - 结果写入对象存储，可长期保留
  - 适合全局视角的告警（如多集群聚合）
```

---

## 4. Thanos 部署模式

### 4.1 简单模式（单集群）

```
┌─────────────────────────────────────────────────────────────┐
│                    单集群部署                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────┐                               │
│  │  Prometheus x2 (HA)     │                               │
│  │  + Sidecar x2           │                               │
│  └────────────┬────────────┘                               │
│               │  Upload blocks                             │
│               ▼                                            │
│  ┌─────────────────────────┐                               │
│  │  MinIO (对象存储)        │                               │
│  └────────────┬────────────┘                               │
│               │                                            │
│  ┌────────────▼────────────┐                               │
│  │  Store + Compactor      │                               │
│  └────────────┬────────────┘                               │
│               │                                            │
│  ┌────────────▼────────────┐                               │
│  │  Querier ──► Grafana    │                               │
│  └─────────────────────────┘                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘

适用: 单 K8s 集群，需要长期存储
```

### 4.2 多集群联邦模式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         多集群联邦部署                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐            │
│   │  Cluster A   │      │  Cluster B   │      │  Cluster C   │            │
│   │              │      │              │      │              │            │
│   │ Prometheus   │      │ Prometheus   │      │ Prometheus   │            │
│   │ + Sidecar    │      │ + Sidecar    │      │ + Sidecar    │            │
│   └──────┬───────┘      └──────┬───────┘      └──────┬───────┘            │
│          │                     │                     │                      │
│          │ Upload              │ Upload              │ Upload               │
│          ▼                     ▼                     ▼                      │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │                    中央对象存储 (S3/GCS)                             │  │
│   │                                                                     │  │
│   │  • 所有集群的 blocks 存储在一个 bucket                               │  │
│   │  • 或每个集群独立的 bucket（推荐）                                   │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│          ▲                                                                  │
│          │                                                                  │
│   ┌──────┴──────┐  ┌─────────────┐  ┌─────────────┐                        │
│   │Store Gateway│  │  Compactor  │  │    Ruler    │  ← 中央查询集群        │
│   └──────┬──────┘  └─────────────┘  └──────┬──────┘                        │
│          │                                  │                               │
│          └────────────────┬─────────────────┘                               │
│                           │                                                 │
│                    ┌──────▼──────┐                                          │
│                    │   Querier   │                                          │
│                    └──────┬──────┘                                          │
│                           │                                                 │
│                    ┌──────▼──────┐                                          │
│                    │   Grafana   │  ← 全局视图                               │
│                    │  (所有集群)  │                                          │
│                    └─────────────┘                                          │
│                                                                             │
│  优势:                                                                       │
│    • 一个 Grafana 查看所有集群                                              │
│    • 全局 Recording Rules                                                   │
│    • 跨集群告警                                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 对象存储选择与配置

```
对象存储选项对比:

| 存储 | 适用场景 | 成本 | 可靠性 |
|------|---------|------|--------|
| AWS S3 | 生产环境 | 中 | 极高 |
| GCP GCS | GKE 环境 | 中 | 极高 |
| Azure Blob | AKS 环境 | 中 | 极高 |
| MinIO | 私有云/测试 | 低 | 中 |
| Ceph RGW | 大规模私有云 | 低 | 高 |
| 腾讯云 COS | 国内环境 | 低 | 高 |
| 阿里云 OSS | 国内环境 | 低 | 高 |

MinIO 部署 (K8s 内):
helm install minio bitnami/minio \
  --set persistence.size=500Gi \
  --set accessKey.password=thanos \
  --set secretKey.password=thanos123

Thanos 连接 MinIO:
type: S3
config:
  bucket: "thanos"
  endpoint: "minio.monitoring.svc.cluster.local:9000"
  access_key: "thanos"
  secret_key: "thanos123"
  insecure: true
  signature_version2: false
```

---

## 6. Thanos 与 VictoriaMetrics 对比

| 维度 | Thanos | VictoriaMetrics |
|------|--------|-----------------|
| **架构** | 多组件分离 | 相对集中 |
| **存储** | 对象存储 (S3) | 本地磁盘/块存储 |
| **查询** | Querier 聚合 | vmselect 聚合 |
| **写入** | Sidecar/Receiver | vminsert |
| **压缩** | Compactor | 内置 |
| **降采样** | 显式配置 | 内置 (无显式降采样) |
| **资源占用** | 较高（多组件） | 较低 |
| **成熟度** | 高（CNCF 孵化） | 中 |
| **PromQL 兼容** | 完全 | 几乎完全 |
| **高可用** | 需自行配置 | 集群版原生支持 |
| **适合** | 多云/已有 S3 | 纯 K8s/追求简单 |

---

## 7. 面试高频题

**Q: Thanos Sidecar 和 Receiver 模式的区别？**

<details>
<summary>答案</summary>

- **Sidecar**: 读取 Prometheus 本地 TSDB，每 2h 上传 block。Prometheus 保留完整本地存储。适合已有 Prometheus 场景。
- **Receiver**: Prometheus remote_write 推送数据到 Receiver，Receiver 暂存后上传。Prometheus 可不保留本地数据。适合边缘/轻量场景。

</details>

**Q: Thanos Compactor 为什么必须单实例运行？**

<details>
<summary>答案</summary>

Compactor 需要独占式修改对象存储中的 blocks（合并、删除、重写）。多个实例同时操作会导致数据损坏。通过 K8s pod 反亲和性或选举机制确保单实例。

</details>

---

## 参考资源

- [Thanos 官方文档](https://thanos.io/tip/thanos/getting-started.md/)
- [Thanos GitHub](https://github.com/thanos-io/thanos)
- [Prometheus Operator + Thanos 集成](https://prometheus-operator.dev/docs/kube/thanos/)

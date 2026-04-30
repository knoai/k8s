# VictoriaMetrics 深度解析

> VictoriaMetrics 是高性能、低资源占用的 Prometheus 兼容时序数据库。在 K8s 监控场景中，它以简单架构和优异性能成为 Thanos 的有力替代方案。

---

## 1. 为什么选 VictoriaMetrics

```
Prometheus 长期存储痛点:

┌─────────────────────────────────────────────────────────────┐
│  1. 单节点存储有限                                           │
│     - 本地磁盘几百 GB                                        │
│     - 高基数场景（Pod 多、label 多）存储爆炸                  │
│                                                             │
│  2. 查询性能瓶颈                                             │
│     - 大量历史数据查询慢                                     │
│     - 复杂 PromQL 计算量大                                   │
│                                                             │
│  3. 高可用复杂                                               │
│     - Thanos 组件多、配置复杂                                │
│     - Cortex 学习曲线陡峭                                    │
│                                                             │
│  4. 资源占用高                                               │
│     - Thanos Store 内存需求大                                │
│     - 多个组件叠加资源开销                                   │
└─────────────────────────────────────────────────────────────┘

VictoriaMetrics 的优势:
  ✓ 单二进制文件即可运行（也可集群模式）
  ✓ 比 Prometheus 占用更少 RAM（~7x 少）
  ✓ 比 Prometheus 更快的查询速度
  ✓ 比 Thanos/Cortex 更简单的架构
  ✓ 原生支持多租户
  ✓ 更好的高基数处理能力
  ✓ 内置数据保留和压缩
```

---

## 2. 架构设计

### 2.1 单节点模式

```
┌─────────────────────────────────────────────────────────────┐
│                    单节点 VictoriaMetrics                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              VictoriaMetrics Single                   │   │
│  │                                                     │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │   │
│  │  │ Ingestion│  │ Storage  │  │ Query    │          │   │
│  │  │ 接收数据  │  │ 压缩存储  │  │ PromQL   │          │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘          │   │
│  │       │             │             │                │   │
│  │       └─────────────┴─────────────┘                │   │
│  │                     │                              │   │
│  │              ┌──────▼──────┐                       │   │
│  │              │ 本地磁盘    │                       │   │
│  │              │ (/storage)  │                       │   │
│  │              └─────────────┘                       │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  部署: 一个二进制文件 + 数据目录                              │
│  适用: 中小规模、测试环境、简单场景                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 集群模式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       VictoriaMetrics 集群架构                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────┐                                                             │
│   │  vmauth  │  ← 可选认证代理 (多租户/负载均衡)                            │
│   │  (可选)   │                                                             │
│   └────┬─────┘                                                             │
│        │                                                                   │
│   ┌────┴────┐  ┌──────────┐  ┌──────────┐                                  │
│   │vminsert │  │vminsert  │  │vminsert  │  ← 数据写入层（无状态）           │
│   │  x N    │  │  x N     │  │  x N     │                                  │
│   └────┬────┘  └────┬─────┘  └────┬─────┘                                  │
│        │            │             │                                         │
│        └────────────┼─────────────┘                                         │
│                     │ 一致性哈希分片                                         │
│        ┌────────────┼─────────────┐                                         │
│        ▼            ▼             ▼                                         │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐                                   │
│   │vmstorage │ │vmstorage │ │vmstorage │  ← 存储层（有状态）                │
│   │   x N    │ │   x N    │ │   x N    │                                   │
│   │          │ │          │ │          │                                   │
│   │ 本地磁盘  │ │ 本地磁盘  │ │ 本地磁盘  │                                   │
│   └────┬─────┘ └────┬─────┘ └────┬─────┘                                   │
│        │            │             │                                         │
│        └────────────┼─────────────┘                                         │
│                     │ 查询聚合                                               │
│        ┌────────────┼─────────────┐                                         │
│        ▼            ▼             ▼                                         │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐                                   │
│   │vmselect  │ │vmselect  │ │vmselect  │  ← 查询层（无状态）                │
│   │  x N     │ │  x N     │ │  x N     │                                   │
│   └────┬─────┘ └────┬─────┘ └────┬─────┘                                   │
│        └────────────┴─────────────┘                                         │
│                     │                                                       │
│              ┌──────▼──────┐                                               │
│              │  Grafana /  │                                               │
│              │  Alertmanager│                                               │
│              └─────────────┘                                               │
│                                                                             │
│  组件职责:                                                                   │
│  • vminsert: 接收 remote_write 数据，一致性哈希分发到 vmstorage              │
│  • vmstorage: 实际存储数据，处理查询请求                                     │
│  • vmselect: 聚合多个 vmstorage 的查询结果                                   │
│  • vmauth: 可选的认证和路由代理                                              │
│                                                                             │
│  注意: vmstorage 之间的数据不冗余！需要自行确保高可用（如副本集）              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 核心组件详解

### 3.1 vmstorage

```
vmstorage 是 VictoriaMetrics 的核心存储引擎:

存储结构:
  /storage
  ├── data/
  │   ├── big/          # 大 blocks (历史数据)
  │   │   ├── 20240101/
  │   │   └── ...
  │   └── small/        # 小 blocks (近期数据)
  │       ├── 20240115/
  │       └── ...
  └── indexdb/
      └── ...           # 倒排索引

关键参数:
  -retentionPeriod=3    # 保留 3 个月
  -storageDataPath=/storage
  -search.maxUniqueTimeseries=300000  # 最大时间序列数
  -search.maxQueryDuration=30s
  -memory.allowedPercent=60  # 允许使用 60% 内存

数据压缩:
  • 使用 zstd 压缩算法
  • 典型压缩率: 10:1 (相比原始数据)
  • 高基数场景下比 Prometheus 更高效

高可用方案:
  # 方案 1: 双写 (推荐)
  Prometheus remote_write 同时写入两组 vmstorage
  
  # 方案 2: vmbackup + vmrestore
  定期备份到对象存储，故障时恢复
```

### 3.2 vminsert

```
vminsert 是数据入口:

启动参数:
vminsert \
  -storageNode=vmstorage-1:8400 \
  -storageNode=vmstorage-2:8400 \
  -storageNode=vmstorage-3:8400 \
  -replicationFactor=2  # 写入 2 个副本（实验性）

数据分发:
  • 一致性哈希（基于 metric name + label）
  • 自动处理 vmstorage 扩缩容
  • 失败节点自动跳过

Prometheus 配置:
remote_write:
  - url: http://vminsert:8480/insert/0/prometheus/api/v1/write
    # /insert/<accountID>/prometheus/...  accountID 用于多租户
    queue_config:
      capacity: 20000
      max_samples_per_send: 10000
      max_shards: 30
```

### 3.3 vmselect

```
vmselect 是查询入口:

启动参数:
vmselect \
  -storageNode=vmstorage-1:8401 \
  -storageNode=vmstorage-2:8401 \
  -storageNode=vmstorage-3:8401 \
  -search.cacheTimestampOffset=5m \
  -search.maxQueryDuration=30s \
  -search.maxPointsPerTimeseries=30000

缓存策略:
  • 查询结果缓存（内存）
  • 近期数据查询优先从 cache 返回
  • 支持部分响应（部分 vmstorage 失败时仍返回）

Grafana 数据源配置:
  URL: http://vmselect:8481/select/0/prometheus
  # /select/<accountID>/prometheus
```

### 3.4 vmagent

```
vmagent 是轻量级数据采集代理:

┌─────────────────────────────────────────────────────────────┐
│                      vmagent 架构                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  采集端                                                       │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐                    │
│  │ Target 1 │ │ Target 2 │ │ Target 3 │  ...               │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘                    │
│       │            │            │                           │
│       └────────────┼────────────┘                           │
│                    │ scrape                                  │
│              ┌─────▼─────┐                                  │
│              │  vmagent   │  ← 替代 Prometheus 采集功能      │
│              │            │                                  │
│              │ - 服务发现  │                                  │
│              │ - relabel   │                                  │
│              │ - 内存缓存  │                                  │
│              └─────┬─────┘                                  │
│                    │ remote_write                            │
│                    ▼                                         │
│              ┌──────────┐                                   │
│              │ Victoria │                                   │
│              │ Metrics  │                                   │
│              └──────────┘                                   │
│                                                             │
│  优势:                                                       │
│    ✓ 比 Prometheus 更少的内存占用（~10x 少）                 │
│    ✓ 支持多个 remote_write 目标（多副本/多集群）             │
│    ✓ 支持从 Kafka 读取数据                                   │
│    ✓ 支持流式聚合                                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘

启动参数:
vmagent \
  -promscrape.config=/etc/prometheus/prometheus.yml \
  -remoteWrite.url=http://vminsert:8480/insert/0/prometheus/api/v1/write \
  -remoteWrite.tmpDataPath=/tmp/vmagent \
  -promscrape.maxScrapeSize=16MB
```

---

## 4. K8s 部署实战

### 4.1 Helm 部署集群版

```bash
# 添加 Helm 仓库
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

# 安装 VictoriaMetrics 集群
helm install victoria-metrics vm/victoria-metrics-cluster \
  --namespace monitoring \
  --create-namespace \
  --set vminsert.replicaCount=2 \
  --set vmselect.replicaCount=2 \
  --set vmselect.suppressStorageFQDNsRender=true \
  --set vmstorage.replicaCount=3 \
  --set vmstorage.persistentVolume.size=100Gi \
  --set vmstorage.retentionPeriod=3

# 查看组件
kubectl get pods -n monitoring -l app.kubernetes.io/instance=victoria-metrics
```

### 4.2 Prometheus Remote Write 配置

```yaml
# prometheus-values.yaml
prometheus:
  prometheusSpec:
    remoteWrite:
      - url: http://victoria-metrics-vminsert.monitoring.svc.cluster.local:8480/insert/0/prometheus/api/v1/write
        queueConfig:
          capacity: 20000
          maxSamplesPerSend: 10000
          maxShards: 30
        writeRelabelConfigs:
          - sourceLabels: [__name__]
            regex: 'go_.*'
            action: drop  # 可选：过滤不需要的指标
```

### 4.3 Grafana 数据源配置

```yaml
# grafana-datasource.yaml
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    type: prometheus
    url: http://victoria-metrics-vmselect.monitoring.svc.cluster.local:8481/select/0/prometheus
    access: proxy
    isDefault: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
      manageAlerts: true
      alertmanagerUid: alertmanager
```

---

## 5. 性能优化

### 5.1 高基数问题处理

```bash
# 查看当前时间序列数量
curl -s 'http://vmselect:8481/select/0/prometheus/api/v1/series/count' | jq

# 查看最占用资源的指标
curl -s 'http://vmselect:8481/select/0/prometheus/api/v1/status/tsdb' | jq '.data.top10[0]'

# vmstorage 内存调优
# 高基数场景增加内存
vmstorage \
  -memory.allowedPercent=60 \
  -search.maxUniqueTimeseries=1000000

# 限制单个查询的样本数
vmselect \
  -search.maxSamplesPerQuery=100000000 \
  -search.maxPointsPerTimeseries=30000

# relabel 过滤高基数 label
writeRelabelConfigs:
  - regex: "instance_id|container_id|uid"
    action: labeldrop
```

### 5.2 与 Thanos 性能对比

| 场景 | VictoriaMetrics | Thanos |
|------|-----------------|--------|
| 单节点内存 (100K series) | ~1GB | ~3GB (Prometheus) |
|  ingestion 速率 | 1M+ samples/s | 依赖 Prometheus |
| 查询 1h 数据 | <100ms | <100ms |
| 查询 30d 数据 | <1s | 2-5s |
| 部署复杂度 | 低（3个组件） | 高（6+ 组件） |
| 资源占用 | 低 | 高 |

---

## 6. 多租户配置

```
VictoriaMetrics 原生支持多租户:

URL 格式:
  /insert/<accountID>/prometheus/api/v1/write
  /select/<accountID>/prometheus/api/v1/query

accountID: 0 ~ 2^32-1 的数字

示例:
  团队 A: accountID=1
  团队 B: accountID=2

配合 vmauth 做路由:
vmauth \
  -auth.config=/etc/vmauth/config.yml

# vmauth 配置
users:
  - username: team-a
    password: pass-a
    url_prefix: http://vminsert:8480/insert/1/
  - username: team-b
    password: pass-b
    url_prefix: http://vminsert:8480/insert/2/
```

---

## 7. 从 Thanos 迁移到 VictoriaMetrics

```bash
# 方案: 双写迁移

# 1. 部署 VictoriaMetrics
helm install vm vm/victoria-metrics-cluster -n monitoring

# 2. Prometheus 配置双写
remote_write:
  - url: http://thanos-receiver:19291/api/v1/receive  # 原有 Thanos
  - url: http://vminsert:8480/insert/0/prometheus/api/v1/write  # 新增 VM

# 3. 并行运行一段时间（至少一个 retention 周期）

# 4. Grafana 切数据源到 VictoriaMetrics

# 5. 验证数据完整性后停 Thanos

# 6. 清理 Thanos 资源
```

---

## 参考资源

- [VictoriaMetrics 官方文档](https://docs.victoriametrics.com/)
- [VictoriaMetrics GitHub](https://github.com/VictoriaMetrics/VictoriaMetrics)
- [vmagent 文档](https://docs.victoriametrics.com/vmagent.html)
- [VictoriaMetrics vs Thanos 对比](https://docs.victoriametrics.com/FAQ.html#what-is-the-difference-between-victoriametrics-and-thanos)

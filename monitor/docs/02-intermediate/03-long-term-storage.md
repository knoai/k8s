# Prometheus 长期存储方案

> 市场 JD 高频要求："熟悉 Thanos/Mimir/VictoriaMetrics 等长期存储方案，能独立设计大规模指标监控体系"

---

## 1. 为什么需要长期存储

Prometheus 本地存储存在以下限制：

| 限制 | 说明 |
|------|------|
| 单机容量 | 受限于单节点磁盘 |
| 数据保留 | 通常保留 15 天，无法查询历史趋势 |
| 高可用 | 单点故障风险 |
| 查询性能 | 大规模查询容易 OOM |
| 多集群 | 无法聚合多个集群数据 |

**长期存储目标**：
- 低成本保存数月到数年的历史数据
- 跨集群全局查询视图
- 高可用与水平扩展

---

## 2. 方案对比

| 方案 | 存储后端 | 查询接口 | 架构复杂度 | 适用场景 |
|------|----------|----------|------------|----------|
| **Thanos** | S3/GCS/MinIO | PromQL | 中 | 多集群联邦、对象存储 |
| **VictoriaMetrics** | 本地/云盘 | PromQL | 低 | 高性能、简单部署 |
| **Mimir** | S3/GCS | PromQL | 中 | Grafana Labs 生态 |
| **Cortex** | S3/GCS | PromQL | 高 | 已逐步被 Mimir 取代 |
| **Remote Write** | InfluxDB/TimescaleDB | 各数据库接口 | 低 | 已有数据库基础设施 |

---

## 3. Thanos 详解

### 3.1 Thanos 架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Query Layer                               │
│                    Thanos Query (Querier)                        │
│                         │   │   │                                │
│                         ▼   ▼   ▼                                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │Sidecar+Prom │  │Sidecar+Prom │  │    Thanos Store         │  │
│  │  Cluster A  │  │  Cluster B  │  │   (历史数据来自 S3)      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│         │                │                      │                │
│         └────────────────┼──────────────────────┘                │
│                          ▼                                       │
│              ┌─────────────────────┐                             │
│              │    Object Storage   │                             │
│              │   (S3/GCS/MinIO)    │                             │
│              └─────────────────────┘                             │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Compactor │  Ruler │  Receiver │  Query Frontend       │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 核心组件

| 组件 | 功能 | 部署方式 |
|------|------|----------|
| **Sidecar** | 与 Prometheus 同节点，上传数据到对象存储 | Sidecar |
| **Querier** | 聚合查询多个 Store/Sidecar 数据 | Deployment |
| **Store** | 从对象存储读取历史数据 | StatefulSet |
| **Compactor** | 压缩和降采样历史数据 | StatefulSet |
| **Ruler** | 评估 Recording Rules 和告警 | StatefulSet |
| **Query Frontend** | 查询缓存和拆分 | Deployment |
| **Receiver** | 接收 Remote Write 数据（可选） | StatefulSet |

### 3.3 Thanos 部署配置

```yaml
# thanos-sidecar 与 Prometheus 一起部署
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
spec:
  template:
    spec:
      containers:
        # Prometheus 容器
        - name: prometheus
          image: prom/prometheus:v2.50.0
          args:
            - --config.file=/etc/prometheus/prometheus.yml
            - --storage.tsdb.retention.time=15d
            - --storage.tsdb.min-block-duration=2h
            - --storage.tsdb.max-block-duration=2h
        
        # Thanos Sidecar
        - name: thanos-sidecar
          image: thanosio/thanos:v0.34.0
          args:
            - sidecar
            - --tsdb.path=/prometheus
            - --prometheus.url=http://localhost:9090
            - --objstore.config-file=/etc/thanos/bucket.yml
          volumeMounts:
            - name: thanos-config
              mountPath: /etc/thanos
---
# thanos-querier.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thanos-querier
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: querier
          image: thanosio/thanos:v0.34.0
          args:
            - query
            - --http-address=0.0.0.0:9090
            - --grpc-address=0.0.0.0:10901
            - --store=thanos-store:10901
            - --store=prometheus-0:10901
            - --store=prometheus-1:10901
            - --query.auto-downsampling
            - --query.partial-response
          ports:
            - containerPort: 9090
              name: http
            - containerPort: 10901
              name: grpc
---
# thanos-store.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: thanos-store
spec:
  replicas: 2
  template:
    spec:
      containers:
        - name: store
          image: thanosio/thanos:v0.34.0
          args:
            - store
            - --data-dir=/var/thanos/store
            - --objstore.config-file=/etc/thanos/bucket.yml
            - --index-cache-size=250MB
            - --chunk-pool-size=2GB
            - --store.grpc.series-sample-limit=0
            - --store.grpc.series-max-concurrency=20
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: 2000m
              memory: 8Gi
---
# thanos-compactor.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: thanos-compactor
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: compactor
          image: thanosio/thanos:v0.34.0
          args:
            - compact
            - --data-dir=/var/thanos/compact
            - --objstore.config-file=/etc/thanos/bucket.yml
            - --retention.resolution-raw=15d
            - --retention.resolution-5m=30d
            - --retention.resolution-1h=1y
            - --consistency-delay=30m
            - --downsampling.disable=false
---
# thanos-bucket.yaml (对象存储配置)
type: S3
config:
  bucket: "thanos-metrics"
  endpoint: "s3.amazonaws.com"
  region: "us-east-1"
  access_key: "${AWS_ACCESS_KEY}"
  secret_key: "${AWS_SECRET_KEY}"
```

### 3.4 Thanos 查询示例

```bash
# 通过 Thanos Querier 查询全局数据
curl http://thanos-querier:9090/api/v1/query \
  -d 'query=sum(rate(http_requests_total[5m]))'

# 查询 30 天前的数据（通过 Store 从 S3 读取）
curl http://thanos-querier:9090/api/v1/query \
  -d 'query=node_cpu_seconds_total{mode="idle"}' \
  -d 'time=1710000000'
```

---

## 4. VictoriaMetrics 详解

### 4.1 为什么选 VictoriaMetrics

| 优势 | 说明 |
|------|------|
| **高性能** | 比 Prometheus 高 10-20 倍查询性能 |
| **低资源** | 存储空间仅为 Prometheus 的 7 倍少 |
| **兼容 PromQL** | 完全兼容 Prometheus 查询语法 |
| **简单部署** | 单二进制文件即可运行 |
| **水平扩展** | 集群模式支持水平扩展 |

### 4.2 部署模式

| 模式 | 适用场景 | 组件 |
|------|----------|------|
| **单节点** | 中小规模 | vmstorage + vminsert + vmselect |
| **集群** | 大规模生产 | 分离部署 |

### 4.3 VictoriaMetrics 集群部署

```yaml
# vmstorage.yaml - 数据存储
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vmstorage
spec:
  replicas: 3
  serviceName: vmstorage
  template:
    spec:
      containers:
        - name: vmstorage
          image: victoriametrics/vmstorage:v1.97.0-cluster
          args:
            - --storageDataPath=/storage
            - --retentionPeriod=3
          ports:
            - containerPort: 8482
              name: http
            - containerPort: 8400
              name: insert
            - containerPort: 8401
              name: select
          resources:
            requests:
              cpu: 1000m
              memory: 8Gi
            limits:
              cpu: 4000m
              memory: 32Gi
          volumeMounts:
            - name: storage
              mountPath: /storage
  volumeClaimTemplates:
    - metadata:
        name: storage
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 500Gi
---
# vminsert.yaml - 数据写入
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vminsert
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: vminsert
          image: victoriametrics/vminsert:v1.97.0-cluster
          args:
            - --storageNode=vmstorage-0.vmstorage:8400
            - --storageNode=vmstorage-1.vmstorage:8400
            - --storageNode=vmstorage-2.vmstorage:8400
          ports:
            - containerPort: 8480
              name: http
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
---
# vmselect.yaml - 数据查询
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vmselect
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: vmselect
          image: victoriametrics/vmselect:v1.97.0-cluster
          args:
            - --storageNode=vmstorage-0.vmstorage:8401
            - --storageNode=vmstorage-1.vmstorage:8401
            - --storageNode=vmstorage-2.vmstorage:8401
          ports:
            - containerPort: 8481
              name: http
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
---
# Prometheus Remote Write 到 VictoriaMetrics
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
data:
  prometheus.yml: |
    remote_write:
      - url: http://vminsert:8480/insert/0/prometheus/api/v1/write
        queue_config:
          max_samples_per_send: 10000
          max_shards: 200
```

### 4.4 Prometheus 与 VictoriaMetrics 对比

| 维度 | Prometheus | VictoriaMetrics |
|------|------------|-----------------|
| 单机容量 | TB 级 | 百 TB 级 |
| 查询并发 | 中等 | 高（支持并发查询） |
| 数据压缩 | 一般 | 高（7-10 倍压缩） |
| 降采样 | 需 Thanos | 内置 |
| 高可用 | 需联邦 | 内置集群模式 |
| 学习曲线 | 低 | 低 |

---

## 5. Mimir 详解

### 5.1 Mimir 定位

Grafana Labs 推出的 Prometheus 长期存储方案，Cortex 的演进版本。

```
┌─────────────────────────────────────────────────────────────┐
│                      Mimir 架构                               │
│                                                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Distributor│───▶│   Ingester  │───▶│    Store    │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│         │                  │                  │              │
│         └──────────────────┼──────────────────┘              │
│                            ▼                                 │
│                 ┌─────────────────────┐                      │
│                 │   Object Storage    │                      │
│                 └─────────────────────┘                      │
│                                                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Querier   │    │  Compactor  │    │   Ruler     │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Mimir 部署

```bash
# 使用 Helm 部署
helm repo add grafana https://grafana.github.io/helm-charts
helm install mimir grafana/mimir-distributed \
  --namespace monitoring \
  --set mimir.structuredConfig.common.storage.backend=s3 \
  --set mimir.structuredConfig.common.storage.s3.endpoint=s3.amazonaws.com
```

---

## 6. 方案选型建议

| 场景 | 推荐方案 | 理由 |
|------|----------|------|
| 多集群统一视图 | Thanos | Sidecar 模式天然适配多集群 |
| 追求极致性能 | VictoriaMetrics | 查询快、资源省 |
| Grafana 生态深度用户 | Mimir | 与 Grafana Cloud 一致 |
| 已有对象存储基础设施 | Thanos/Mimir | 利用现有 S3 |
| 快速部署、运维简单 | VictoriaMetrics | 单二进制、配置少 |

---

## 7. 高基数问题实战

> 市场高频考点："解决 Active Series 爆炸与高基数指标压缩优化"

### 7.1 什么是高基数

```
http_requests_total{path="/api/users/1"}   # ❌ 路径包含动态 ID
http_requests_total{path="/api/users/{id}"} # ✅ 路径归一化
```

**高基数标签**：user_id、email、session_id、IP 地址、URL 含动态参数

### 7.2 检测高基数

```promql
# 查看指标基数
topk(10, count by (__name__) ({__name__=~".+"}))

# 查看标签基数
count by (label_name) (metric_name)
```

### 7.3 解决方案

| 方案 | 说明 |
|------|------|
| **标签归一化** | `/api/users/123` → `/api/users/{id}` |
| **删除高基数标签** | relabel_config `action: labeldrop` |
| **降采样** | 降低采集频率 |
| **分片存储** | VictoriaMetrics 集群分片 |
| **丢弃指标** | 非关键指标直接丢弃 |

```yaml
# Prometheus relabel 删除高基数标签
metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'http_requests_total'
    action: keep
  - regex: 'user_id|session_id|client_ip'
    action: labeldrop
```

---

## 参考资源

- [Thanos 官方文档](https://thanos.io/)
- [VictoriaMetrics 文档](https://docs.victoriametrics.com/)
- [Grafana Mimir 文档](https://grafana.com/docs/mimir/latest/)
- [Prometheus Remote Write](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write)

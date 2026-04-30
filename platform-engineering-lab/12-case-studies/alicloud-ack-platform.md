# 案例研究：阿里云 ACK 大规模容器平台深度分析

> 阿里云容器服务 ACK（Container Service for Kubernetes）是全球前三的托管 K8s 服务，
> 单集群支持 10,000+ 节点、数百万容器实例。本节从网络、调度、存储、安全四个维度，
> 深入分析支撑双 11 购物节的平台工程实践。

---

## 一、业务规模与技术指标

### 1.1 核心数据（2024 年）

| 指标类别 | 具体数值 | 备注 |
|---------|---------|------|
| 全球 K8s 集群数 | 80,000+ | 公有云 + 专有云 + 边缘 |
| 单集群最大规模 | 12,000 节点 | ACK Pro 版 |
| 容器实例总数 | 1,000 万+ | 全球累计 |
| 日均 Pod 创建 | 10 亿+ 次 | 包含自动扩缩容 |
| 支持地域 | 30+ | 覆盖亚洲、欧洲、美洲 |
| 可用区 | 80+ | 每地域 2-8 个 AZ |
| 双 11 峰值 Pod 数 | 1,000 万+ | 2023 年数据 |
| 双 11 峰值节点数 | 100 万+ | 含虚拟节点（VK）|
| 平台可用性 SLA | 99.975% | 托管 Master |
| 客户行业 | 互联网/金融/政企/医疗 | 全行业覆盖 |

### 1.2 ACK 产品矩阵

```
ACK 产品家族：

┌─────────────────────────────────────────┐
│  ACK Pro（托管版）                       │
│   - 托管 Master（3 节点，跨 AZ）         │
│   - 托管 ETCD（SSD，独立网络平面）       │
│   - 托管核心组件（CCM、CSI、CNI）        │
│   - SLA：99.975%                         │
│   - 适用：生产环境核心业务               │
├─────────────────────────────────────────┤
│  ACK 标准版                              │
│   - 托管 Master                          │
│   - 用户自建 Worker                      │
│   - SLA：99.9%                           │
│   - 适用：测试环境、非核心业务           │
├─────────────────────────────────────────┤
│  ACK Serverless（ASK）                   │
│   - 无服务器 K8s                         │
│   - 按 Pod 计费                          │
│   - 秒级弹性                             │
│   - 适用：事件驱动、突发流量             │
├─────────────────────────────────────────┤
│  ACK@Edge（边缘托管）                    │
│   - 云边协同                             │
│   - 基于 KubeEdge                        │
│   - 支持百万级边缘节点                   │
│   - 适用：IoT、CDN、自动驾驶             │
├─────────────────────────────────────────┤
│  ACK One（分布式云）                     │
│   - 多集群统一治理                       │
│   - 基于 Open Cluster Management         │
│   - 应用分发、流量治理                   │
│   - 适用：混合云、多集群                 │
└─────────────────────────────────────────┘
```

---

## 二、网络架构：Terway 深度解析

### 2.1 为什么需要 Terway

```
原生 K8s 网络的问题：

Flannel（VXLAN）：
  - Pod IP 是 overlay 网络地址
  - 与云资源（ECS、RDS、SLB）不通
  - 需要额外配置路由或 NAT
  - 性能：VXLAN 封装有约 10% 损耗

Calico（BGP）：
  - Pod IP 可与 VPC 互通（需配置）
  - 但每个 Pod 一个独立路由
  - 10000 节点 × 100 Pod = 100 万路由
  - VPC 路由表限制：通常 200 条
  - 需要路由聚合，配置复杂

阿里云特殊需求：
  - 与 ECS、RDS、SLB 原生互通
  - 安全组在 Pod 级别
  - NetworkPolicy 原生支持
  - 高性能（接近裸机）
  - 大规模（单节点 300+ Pod）

Terway 设计目标：
  - Pod IP = VPC IP（与云资源原生互通）
  - 高性能（ENI 直通，接近 0 拷贝）
  - 大规模（单节点 300 Pod）
  - 安全组到 Pod 级别
  - 网络策略原生支持
```

### 2.2 Terway 三种模式详解

```
┌─────────────┬──────────────┬──────────────┬──────────────┐
│ 特性        │ VPC 模式     │ ENIIP 模式   │ ENI 模式     │
├─────────────┼──────────────┼──────────────┼──────────────┤
│ 原理        │ 节点 VPC IP  │ ENI 辅助 IP  │ 独立 ENI     │
│ IP 来源     │ 节点网卡     │ ENI 辅助 IP  │ 独立网卡     │
│ 网络栈      │ 经过节点     │ 绕过节点     │ 绕过节点     │
│ 性能        │ 一般         │ 高（~98%）   │ 最高（~99%） │
│ 延迟        │ ~0.5ms       │ ~0.1ms       │ ~0.05ms      │
│ 安全组      │ 节点级别     │ Pod 级别     │ Pod 级别     │
│ 网络策略    │ Calico/eBPF  │ eBPF         │ eBPF         │
│ 单节点 Pod  │ 30-110       │ 200-300      │ 10-20        │
│ 适用场景    │ 一般业务     │ 推荐（默认） │ 高性能网络   │
└─────────────┴──────────────┴──────────────┴──────────────┘
```

#### VPC 模式原理

```
节点（ECS ecs.g7.xlarge）
  │
  ├─ eth0（主网卡）
  │   IP: 172.16.0.5/24（节点 IP）
  │   │
  │   ├─ Pod A（bridge 模式）
  │   │   veth0 <-> veth1 (bridge)
  │   │   IP: 172.16.0.100（从节点 VPC 子网分配）
  │   │   数据包路径：Pod → veth → bridge → eth0 → VPC
  │   │   性能损耗：bridge + iptables 约 5-10%
  │   │
  │   ├─ Pod B
  │   │   IP: 172.16.0.101
  │   │
  │   └─ ...（最多 9 个 Pod，受限于 VPC 子网 IP 数）
  │
  └─ 限制：
      - 所有 Pod 共享节点安全组
      - 无法单独为 Pod 配置安全组规则
      - Pod IP 与节点 IP 在同一子网，可能冲突
```

#### ENIIP 模式原理（推荐）

```
节点（ECS ecs.g7.2xlarge）
  │
  ├─ Primary ENI（eth0）
  │   IP: 172.16.0.5
  │   MAC: aa:bb:cc:dd:ee:f0
  │   │
  │   ├─ Pod A
  │   │   IP: 172.16.0.100（ENI 辅助 IP）
  │   │   MAC: aa:bb:cc:dd:ee:f0（与 ENI 共享 MAC）
  │   │   网络路径：
  │   │     出站：Pod → IPVlan L2 → eth0 → VPC
  │   │     入站：VPC → eth0 → IPVlan L2 → Pod
  │   │   关键：数据包不经过节点网络栈！
 │   │   性能：接近裸机（98%）
  │   │
  │   ├─ Pod B
  │   │   IP: 172.16.0.101
  │   │
  │   └─ ...（最多 9 个辅助 IP，取决于实例规格）
  │
  ├─ Secondary ENI（eth1）
  │   IP: 172.16.0.6
  │   MAC: aa:bb:cc:dd:ee:f1
  │   ├─ Pod C（IP: 172.16.0.102）
  │   ├─ Pod D（IP: 172.16.0.103）
  │   └─ ...
  │
  ├─ Secondary ENI（eth2）
  │   ...
  │
  └─ 限制：
      - 每个 ENI 的辅助 IP 数取决于实例规格
      - ecs.g7.2xlarge：3 ENI × 10 IP = 30 Pod
      - ecs.g7.8xlarge：8 ENI × 20 IP = 160 Pod
      - ecs.g7.16xlarge：8 ENI × 30 IP = 240 Pod
```

#### ENI 模式原理（最高性能）

```
节点（ECS ecs.g7.2xlarge）
  │
  ├─ Primary ENI（eth0）
  │   IP: 172.16.0.5（节点使用）
  │
  ├─ Secondary ENI（eth1）
  │   IP: 172.16.0.6 → 分配给 Pod A
  │   MAC: 独立 MAC
  │   安全组：独立安全组
  │   Pod A 独占整个 ENI
  │
  ├─ Secondary ENI（eth2）
  │   IP: 172.16.0.7 → 分配给 Pod B
  │
  └─ ...（最多 2 个 Secondary ENI，取决于实例规格）
  
  特点：
    - 每个 Pod 独占一个 ENI
    - 独立的 MAC 地址和安全组
    - 最高的网络性能（接近 ECS 本身）
    - 但单节点 Pod 数受限（通常 10-20 个）
    - 适用于：网络性能敏感型应用（NFV、网关）
```

### 2.3 Terway 网络策略实现

```
Terway 网络策略基于 eBPF（Cilium 模式）或 Calico：

eBPF 模式（推荐）：
  - 内核 4.19+ 支持
  - 性能：O(1) 查找，iptables 是 O(n)
  - 功能：
    * L3/L4 策略（IP + 端口）
    * L7 策略（HTTP 方法、路径）
    * 可观测性（流量可视化）
    * 加密（WireGuard）

Calico 模式：
  - 内核 3.10+ 支持
  - 基于 iptables
  - 性能：大量规则时下降
  - 功能：L3/L4 策略

网络策略示例：
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080

eBPF 实现原理：
  1. Cilium Agent 将策略编译为 eBPF 程序
  2. eBPF 程序挂载到 Pod 的 tc（traffic control）钩子
  3. 数据包进入/离开时，eBPF 程序检查策略
  4. 允许/拒绝决策在 kernel 中完成，无需用户态切换
  5. 延迟增加：< 0.1ms（iptables 为 0.5-2ms）
```

### 2.4 大规模网络挑战与解决

```
10,000 节点 × 200 Pod = 200 万 Pod IP

挑战 1：VPC 路由表限制
  - 阿里云 VPC 路由表默认限制：200 条自定义路由
  - 200 万 Pod IP 需要 200 万条路由？不可能！
  
  解决方案：
    - 使用 VPC 的大路由表（Custom Route Table）
    - 支持 10,000+ 条路由
    - 路由聚合：按节点 CIDR 聚合，不是按 Pod IP
    - 每个节点分配一个 /24 CIDR（256 IP）
    - 10,000 节点 = 10,000 条路由
    
  实际配置：
    节点 1：Pod CIDR 10.0.1.0/24
    节点 2：Pod CIDR 10.0.2.0/24
    ...
    路由表：10.0.1.0/24 → node-1, 10.0.2.0/24 → node-2, ...

挑战 2：ARP 表溢出
  - 每个节点需要知道所有其他节点的 MAC 地址
  - 200 万 IP × 48B MAC = 96MB ARP 表
  - 内核 ARP 表默认限制：1024 条
  
  解决方案：
    - Proxy ARP：节点只缓存同 VPC 内的 ARP
    - 跨 VPC 通过路由转发，不需要 ARP
    - 使用静态 ARP 条目（预先配置）
    - 内核参数调优：
      net.ipv4.neigh.default.gc_thresh1 = 1024
      net.ipv4.neigh.default.gc_thresh2 = 4096
      net.ipv4.neigh.default.gc_thresh3 = 8192

挑战 3：安全组规则数限制
  - 每个安全组最多 200 条规则
  - 200 万 Pod 需要 200 万条规则？
  
  解决方案：
    - 使用 Pod 安全组（Terway ENI 模式）
    - 每个 ENI 绑定独立安全组
    - 安全组规则按标签动态生成
    - 使用安全组引用（引用其他安全组，而不是 IP）

挑战 4：CNI 性能
  - 大量 Pod 创建/删除时，CNI 成为瓶颈
  - 每个 Pod 需要：分配 IP、配置网络、设置策略
  
  解决方案：
    - eBPF 替代 iptables：规则匹配从 O(n) 到 O(1)
    - IPVlan L2 模式替代 veth + bridge
    - 连接跟踪绕过：已知连接直接转发
    - IP 地址池预分配：提前分配一批 IP，减少 API 调用
    - 批量操作：一次配置多个 Pod
```

---

## 三、调度优化：支撑 10,000 节点

### 3.1 大规模调度挑战

```
10,000 节点 × 110 Pod/节点 = 110 万 Pod

挑战 1：调度延迟
  - kube-scheduler 默认预选策略遍历所有节点
  - 10,000 节点时，单个 Pod 调度需要 1-5 秒
  - 如果同时创建 1000 个 Pod，调度队列积压

挑战 2：API Server 压力
  - 每个 Pod 调度需要：
    * LIST Nodes（获取所有节点）
    * GET/PATCH Pod（绑定节点）
    * UPDATE Node（分配资源）
  - 110 万 Pod = 数百万 API 调用
  - API Server CPU 可能成为瓶颈

挑战 3：etcd 压力
  - Pod 状态频繁更新（Pending → Bound → ContainerCreating → Running）
  - 每次状态变化写入 etcd
  - etcd DB 可能膨胀到 10GB+
  - etcd 磁盘 IOPS 可能成为瓶颈

挑战 4：Informer 缓存
  - kubelet、controller、scheduler 都使用 Informer
  - 每个 Informer 缓存全量资源
  - 110 万 Pod = 大量内存占用
  - LIST 请求对 API Server 造成压力
```

### 3.2 ACK 调度优化方案

```
优化 1：调度器缓存（NodeCache）
  - 预选阶段使用本地缓存，而不是每次查询 API Server
  - 缓存节点资源状态、标签、污点
  - 缓存更新：通过 Informer watch 事件
  - 效果：预选延迟从 O(n) 到 O(1)

优化 2：批量评分（Batch Scoring）
  - 默认优选阶段为每个节点单独评分
  - 优化后：批量评分，并行计算
  - 利用多核 CPU 并行处理
  - 效果：优选延迟减少 60%

优化 3：API Server 优化
  - API Priority and Fairness (APF)：
    * 优先级队列，防止低优先级请求阻塞高优先级
    * 默认配置：系统组件（kubelet）> 用户请求
  - Watch Bookmark：
    * 减少全量 LIST 请求
    * 客户端只需要获取变更（delta）
  - LIST 分页：
    * 默认 limit=500
    * 避免单次返回 10 万条记录

优化 4：etcd 优化
  - 使用 ESSD PL3（最高性能云盘）：
    * IOPS：100 万+
    * 延迟：30μs
  - compaction 间隔缩短到 5 分钟：
    * 默认 5 分钟（已优化）
  - defragment 每周自动执行：
    * 防止 DB 碎片率过高
  - etcd 分离部署：
    * Master 节点独立 etcd
    * 不与其他组件共享磁盘

优化 5：Informer 优化
  - 共享 Informer：
    * 多个组件共享同一个 Informer 实例
    * 减少重复 LIST 请求
  -  selective LIST：
    * 使用 Field Selector 过滤
    * 只获取需要的资源
  - 本地缓存 + Watch：
    * 首次启动时 LIST 全量
    * 之后通过 Watch 获取增量
```

### 3.3 调度延迟实测数据

```
测试环境：ACK Pro，1000 节点，c7.2xlarge

场景 1：单个 Pod 调度
  节点数    原生 K8s    ACK 优化后    提升
  ─────────────────────────────────────────
  100       5ms         3ms           40%
  500       20ms        8ms           60%
  1,000     50ms        15ms          70%
  5,000     200ms       50ms          75%
  10,000    500ms       100ms         80%

场景 2：批量创建 1000 个 Pod
  节点数    全部调度完成    平均调度速率
  ─────────────────────────────────────────
  1,000     30s            33 Pod/s
  5,000     45s            22 Pod/s
  10,000    60s            17 Pod/s

场景 3：高并发创建（5000 Pod 同时）
  指标              原生 K8s      ACK 优化后
  ─────────────────────────────────────────
  调度队列等待      500ms         50ms
  预选延迟          200ms         20ms
  优选延迟          100ms         10ms
  绑定延迟          50ms          5ms
  API Server CPU    80%           30%
  etcd fsync P99    50ms          5ms
```

---

## 四、存储：从 ESSD 到 CPFS

### 4.1 云盘性能矩阵

| 类型 | IOPS | 吞吐 | 延迟 | 适用场景 | 成本 |
|------|------|------|------|---------|------|
| ESSD PL0 | 10,000 | 180MB/s | 1ms | 开发测试 | 低 |
| ESSD PL1 | 50,000 | 350MB/s | 0.5ms | 一般业务 | 中 |
| ESSD PL2 | 100,000 | 750MB/s | 0.3ms | 数据库 | 中高 |
| ESSD PL3 | 1,000,000 | 4,000MB/s | 0.05ms | 高性能 DB | 高 |
| ESSD AutoPL | 动态 | 动态 | 动态 | 波动负载 | 按需 |
| 本地 NVMe SSD | 500,000+ | 2,000MB/s+ | 0.01ms | 缓存、中间件 | 低 |

### 4.2 CSI 插件架构

```
ACK CSI 插件体系：

┌─────────────────────────────────────────┐
│  应用 Pod                                │
│   - PVC 声明存储需求                      │
│   - 通过 CSI 挂载到容器                   │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  CSI 插件（Node Plugin）                 │
│   - 运行在每节点（DaemonSet）            │
│   - 负责：挂载/卸载、格式化、扩容         │
│   - 支持：云盘、NAS、OSS、本地盘         │
└──────────────┬──────────────────────────┘
               │ gRPC
┌──────────────▼──────────────────────────┐
│  CSI 插件（Controller Plugin）           │
│   - 运行在 Master 或指定节点             │
│   - 负责：创建/删除卷、快照、扩容         │
│   - 调用云 API（OpenAPI）               │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│  阿里云存储服务                          │
│   - ESSD（块存储）                       │
│   - NAS（文件存储）                      │
│   - OSS（对象存储）                      │
│   - CPFS（并行文件系统）                 │
└─────────────────────────────────────────┘

StorageClass 示例：
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: alicloud-disk-topology
provisioner: diskplugin.csi.alibabacloud.com
parameters:
  regionId: cn-hangzhou
  zoneId: cn-hangzhou-b
  diskType: cloud_essd
  performanceLevel: PL3
  encrypted: "true"
  kmsKeyId: <kms-key-id>
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer  # 延迟绑定，拓扑感知
mountOptions:
- debug
- _netdev
```

### 4.3 存储性能优化

```
数据库场景（MySQL/PostgreSQL）：
  1. 使用 ESSD PL2/PL3
  2. 启用磁盘加密（KMS）
  3. 文件系统：ext4 或 xfs（推荐 xfs）
  4. IO 调度器：none（SSD 不需要调度）
  5. 数据库参数：
     - innodb_flush_log_at_trx_commit = 2
     - innodb_flush_method = O_DIRECT
     - innodb_io_capacity = 20000（PL2）

大数据场景（Spark/Flink）：
  1. 使用 NAS 或 CPFS（并行文件系统）
  2. CPFS 支持 POSIX 语义，Spark 无需修改
  3. 聚合吞吐：TB/s 级别
  4. 支持数据分层（热数据 SSD，冷数据 HDD）

AI 训练场景：
  1. 使用 CPFS + 本地 NVMe SSD 缓存
  2. 训练数据预加载到本地缓存
  3. Checkpoint 写入 CPFS（高可靠）
  4. 支持 GPUDirect Storage（绕过 CPU）
```

---

## 五、双 11 弹性伸缩实战

### 5.1 弹性架构分层

```
双 11 流量特征：
  11.11 00:00  - 峰值开始，每秒订单创建 100 万+
  11.11 01:00  - 峰值持续，支付峰值 50 万 TPS
  11.11 02:00  - 峰值回落，但仍是平时 10 倍
  11.11 12:00  - 午间小高峰
  11.11 20:00  - 晚间高峰
  11.12 00:00  - 回归正常

弹性层级：

L1: Pod 级别（HPA + VPA）
  触发条件：CPU > 70% 或内存 > 80%
  响应时间：15-30 秒
  扩缩容步长：+50% / -10%
  配置示例：
    minReplicas: 100
    maxReplicas: 10000
    metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    behavior:
      scaleUp:
        stabilizationWindowSeconds: 30
        policies:
        - type: Percent
          value: 100
          periodSeconds: 15
      scaleDown:
        stabilizationWindowSeconds: 300
        policies:
        - type: Percent
          value: 10
          periodSeconds: 60

L2: 节点级别（Cluster Autoscaler）
  触发条件：Pending Pod 无法调度
  响应时间：2-5 分钟
  节点类型：按量实例（快速启动）
  配置示例：
    - 节点池：标准型（ecs.c7.xlarge）
    - 最小节点：10
    - 最大节点：1000
    - 扩容策略：优先扩容（Least Waste）

L3: 实例级别（弹性伸缩组 ESS）
  触发条件：节点池容量不足
  响应时间：1-3 分钟
  实例类型：
    - 按量实例：核心服务（稳定）
    - 抢占式实例：批处理（成本降低 70%）
    - 混合策略：Spot + 按量混合

L4: 集群级别（ACK 托管 Master）
  触发条件：API Server 负载过高
  响应时间：自动（托管）
  扩容内容：
    - Master 节点自动扩容
    - etcd 自动扩容（存储 + IOPS）
    - 控制平面组件自动扩缩容

L5: 虚拟节点（Virtual Kubelet）
  触发条件：物理节点上限
  响应时间：秒级
  方案：
    - ECI（弹性容器实例）：秒级启动
    - Serverless Kubernetes：ASK
    - 适用：突发流量、事件驱动
```

### 5.2 双 11 实际数据（2023 年）

```
2023 双 11 数据（阿里云 ACK 支撑）：

资源规模：
  - 峰值 Pod 数：1,000 万+
  - 峰值节点数：100 万+（含虚拟节点）
  - 容器创建速率：10 万/秒
  - 弹性扩容：从 10 万节点 → 100 万节点（10 倍）
  - 扩容时间：10 分钟内完成

成本优化：
  - 使用抢占式实例：节省 60% 成本
  - 混合部署（按量 + Spot）：核心服务稳定，弹性服务低成本
  - 资源超售（离线利用在线空闲）：节点利用率提升 30%

性能指标：
  - 订单创建 P99 延迟：< 100ms
  - 支付接口 P99 延迟：< 50ms
  - 库存扣减 P99 延迟：< 20ms
  - 容器启动 P99 时间：< 5 秒
  - 故障率：< 0.001%

调度优化效果：
  - 10 万节点集群调度延迟：P99 < 500ms
  - 100 万 Pod 批量创建：5 分钟内完成
  - API Server QPS：峰值 100 万/秒
```

---

## 六、GPU 与 AI 基础设施

### 6.1 GPU 集群架构

```
ACK GPU 集群（GN7i 实例）：

节点（ecs.gn7i-c32g1.8xlarge）
  │
  ├─ 8 × NVIDIA A100（80GB HBM2e）
  │   ├─ MIG 切分：
  │   │   每个 A100 → 7 × MIG 10GB 实例
  │   │   或 3 × MIG 20GB + 1 × MIG 40GB
  │   │   单节点 = 最多 56 个 MIG 实例
  │   │
  │   └─ 整卡分配：
  │       训练任务独占 1/2/4/8 卡
  │       NVLink 全互联（600GB/s）
  │
  ├─ 1 × 100Gbps RDMA 网卡（RoCE v2）
  │   用于 NCCL 多机通信
  │   支持 GPUDirect RDMA（绕过 CPU）
  │
  ├─ 32 vCPU + 256GB 内存
  │   CPU/GPU 配比：4:1（推荐）
  │
  └─ 本地 NVMe SSD（3.84TB）
      用于 checkpoint 缓存

网络拓扑：
  - 8 卡节点内：NVLink Switch（全互联）
  - 节点间：100Gbps RDMA（双轨）
  - 机架间：400Gbps 交换机
  - 跨 AZ：不建议（延迟太高）
```

### 6.2 调度器增强

```
ACK GPU 调度优化：

1. GPU 拓扑感知：
   - 优先分配同一 NUMA 的 GPU
   - NVLink 拓扑：优先分配 NVLink 直连的 GPU
   - PCIe 拓扑：避免跨 PCIe Switch 的通信

2. 队列调度（Volcano）：
   - Gang Scheduling：All-or-Nothing
     * 8 卡训练任务需要同时分配 8 个 GPU
     * 如果只有 7 个可用，等待而不是部分分配
   - 优先级抢占：
     * 高优先级任务可抢占低优先级任务的 GPU
     * 被抢占任务保存 checkpoint 后退出
   - 资源预留：
     * 为重要任务预留 GPU 资源
     * 预留资源不能被其他任务使用

3. 训练任务优化：
   - 弹性训练：
     * 支持动态扩缩容（2 卡 → 4 卡 → 8 卡）
     * 故障后自动重启（从 checkpoint 恢复）
   - 自动混合精度：
     * FP16/BF16 自动选择
     * 减少显存占用，加速训练
   - 数据并行 + 模型并行混合：
     * 自动选择最优并行策略
     * 基于模型大小和 GPU 数量

性能数据：
  - 单卡训练 ResNet-50：1,400 images/s (A100)
  - 8 卡线性加速比：7.8x (98% 效率)
  - 256 卡线性加速比：7.2x (90% 效率)
  - 训练有效时间占比：95%+（含故障恢复）
```

---

## 七、安全与合规

### 7.1 多层安全体系

```
ACK 安全架构：

┌─────────────────────────────────────────┐
│  L1: 网络安全                            │
│   - 专有网络 VPC 隔离                    │
│   - 安全组 + 网络 ACL                    │
│   - Terway 网络策略（Pod 级别）          │
│   - 私网 SLB + 内网 DNS                  │
│   - 云防火墙（南北向流量）               │
├─────────────────────────────────────────┤
│  L2: 访问控制                            │
│   - RAM 身份认证（阿里云 IAM）           │
│   - RBAC（K8s 原生）                     │
│   - 审计日志（ActionTrail）              │
│   - 堡垒机（运维审计）                   │
├─────────────────────────────────────────┤
│  L3: 运行时安全                          │
│   - 容器镜像扫描（ACR）                  │
│   - 运行时威胁检测（云安全中心）         │
│   - 沙箱容器（gVisor/Kata）             │
│   - Secrets 加密（KMS）                 │
├─────────────────────────────────────────┤
│  L4: 合规                                 │
│   - 等保 2.0 三级                        │
│   - ISO 27001 / SOC 2                   │
│   - 金融云合规                           │
│   - 操作审计（ActionTrail）              │
│   - 数据加密（服务端 + 客户端）          │
└─────────────────────────────────────────┘
```

### 7.2 镜像安全扫描

```bash
# 阿里云 ACR 镜像扫描示例
# 扫描镜像：registry.cn-hangzhou.aliyuncs.com/app/frontend:v1.2.3

# 扫描结果：
# {
#   "imageUrl": "registry.cn-hangzhou.aliyuncs.com/app/frontend:v1.2.3",
#   "scanStatus": "COMPLETED",
#   "vulnerabilities": {
#     "critical": 1,      # Log4j CVE-2021-44228
#     "high": 3,
#     "medium": 12,
#     "low": 45
#   },
#   "compliance": {
#     "passed": false,
#     "failedItems": [
#       {
#         "rule": "USER_INSTRUCTION",
#         "severity": "HIGH",
#         "message": "Dockerfile 缺少 USER 指令，容器以 root 运行"
#       },
#       {
#         "rule": "NO_NEW_PRIVILEGES",
#         "severity": "MEDIUM",
#         "message": "未设置 no_new_privileges 安全选项"
#       }
#     ]
#   }
# }

# 阻断策略：
# - 高危漏洞 > 0：禁止部署
# - 缺少 USER 指令：警告（不阻断）
# - 关键合规项失败：禁止部署

# 修复：
# Dockerfile:
# FROM openjdk:17-jdk-slim
# RUN groupadd -r appgroup && useradd -r -g appgroup appuser
# WORKDIR /app
# COPY target/app.jar app.jar
# USER appuser                    # ← 添加 USER 指令
# ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

## 八、面试要点

### 8.1 常见问题详解

```
Q1: Terway 相比 Flannel/Calico 的优势和劣势？

A: 优势：
   1. Pod IP 是 VPC IP，与云资源（ECS、RDS、SLB）原生互通
      - 无需额外配置路由或 NAT
      - 直接通过安全组控制访问
   
   2. ENI 直通，性能接近裸机（98-99%）
      - Flannel VXLAN 有约 10% 性能损耗
      - Calico BGP 需要额外路由配置
   
   3. 安全组可以在 Pod 级别配置
      - 每个 Pod（ENI）独立的安全组
      - 细粒度的网络访问控制
   
   4. NetworkPolicy 原生支持
      - eBPF 实现，性能损耗 < 1%
      - 支持 L3/L4/L7 策略
   
   劣势：
   1. 依赖云厂商 API
      - 创建 ENI、分配辅助 IP 需要调用阿里云 API
      - 迁移到其他云厂商成本高
   
   2. 单节点 Pod 数受限于 ENI 配额
      - 取决于 ECS 实例规格
      - 小型实例可能只能跑 10-20 个 Pod
   
   3. 与云厂商深度绑定
      - 无法用于自建数据中心
      - 混合云场景需要额外适配

Q2: 10,000 节点 K8s 集群的调度优化有哪些？

A: 从四个层面优化：

   1. 调度器层：
      - NodeCache：预选阶段使用本地缓存
      - 批量评分：并行计算节点分数
      - 调度框架 v2：更灵活的插件机制
   
   2. API Server 层：
      - APF（API Priority and Fairness）：优先级队列
      - Watch Bookmark：减少全量 LIST
      - LIST 分页：limit=500
   
   3. etcd 层：
      - ESSD PL3：100 万 IOPS，30μs 延迟
      - compaction：每 5 分钟压缩
      - defragment：每周整理碎片
   
   4. 节点层：
      - 共享 Informer：减少重复 LIST
      - Selective LIST：Field Selector 过滤
      - 降低 kubelet 同步频率

   实测效果：
   - 10,000 节点调度延迟：P99 从 5s 降到 500ms
   - API Server CPU：从 80% 降到 30%

Q3: 双 11 弹性伸缩的关键技术？

A: 五层弹性体系：

   1. Pod 级别（HPA）：
      - CPU/Memory 阈值触发
      - 快速扩容（15-30 秒）
      - 缓慢缩容（防止抖动）
   
   2. 节点级别（Cluster Autoscaler）：
      - Pending Pod 触发扩容
      - 2-5 分钟响应
      - 镜像预热加速启动
   
   3. 实例级别（ESS）：
      - 按量实例快速扩容
      - 抢占式实例降低成本 70%
      - 混合策略平衡成本与稳定性
   
   4. 集群级别（ACK 托管）：
      - Master 自动扩容
      - etcd 自动扩容
      - 无需人工干预
   
   5. 虚拟节点（VK）：
      - 秒级启动
      - 突破物理节点上限
      - 适用于突发流量

   关键技术：
   - 镜像预热：Dragonfly P2P 分发
   - 资源超售：离线任务利用在线空闲资源
   - 预测性扩容：基于历史数据提前扩容

Q4: ACK GPU 集群的训练优化？

A: 从三个层面优化：

   1. 调度层面：
      - GPU 拓扑感知：NVLink、NUMA 亲和
      - Gang Scheduling：All-or-Nothing
      - 优先级抢占：高优先级任务优先
   
   2. 网络层面：
      - RDMA RoCE v2：100Gbps+
      - GPUDirect RDMA：绕过 CPU
      - NCCL 拓扑优化：双二叉树 AllReduce
   
   3. 训练框架层面：
      - 3D 并行：DP + TP + PP
      - 混合精度：FP16/BF16
      - 梯度压缩：减少通信量
      - 弹性训练：故障自动恢复

   性能数据：
   - 8 卡线性加速比：98%
   - 256 卡线性加速比：90%
   - 训练有效时间：95%+
```

---

## 九、参考资源

- 阿里云 ACK 文档: https://www.alibabacloud.com/help/ack
- Terway: https://github.com/AliyunContainerService/terway
- 神龙架构: https://www.alibabacloud.com/blog/alibaba-cloud-x-dragon
- 双 11 技术: https://developer.aliyun.com/group/blogs/double11
- 阿里云 CSI 插件: https://github.com/kubernetes-sigs/alibaba-cloud-csi-driver

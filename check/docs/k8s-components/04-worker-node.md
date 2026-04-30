# 04. 工作节点组件详解

## kubelet — 节点代理

### 职责

kubelet 是运行在每个工作节点上的**代理程序**，负责：
1. 向 apiserver **注册节点**
2. 接收 apiserver 分配给本节点的 Pod
3. 通过 CRI 调用容器运行时**创建/管理容器**
4. **监控容器状态**，上报给 apiserver
5. 执行**健康检查**（liveness/readiness/startup probe）
6. **管理节点资源**（挂载卷、配置网络）

### 架构图

```
┌──────────────────────────────────────────────┐
│                   Worker Node                 │
│                                               │
│  ┌──────────────────────────────────────┐    │
│  │              kubelet                  │    │
│  │                                       │    │
│  │  ┌──────────┐    ┌──────────────┐    │    │
│  │  │ Pod Sync │───►│ CRI (gRPC)   │────┼────┼──► containerd
│  │  │  Loop    │    │              │    │    │
│  │  └──────────┘    └──────────────┘    │    │
│  │       │                               │    │
│  │       ▼                               │    │
│  │  ┌──────────┐    ┌──────────────┐    │    │
│  │  │  Volume  │───►│ CSI (gRPC)   │────┼────┼──► CSI Driver
│  │  │ Manager  │    │              │    │    │
│  │  └──────────┘    └──────────────┘    │    │
│  │       │                               │    │
│  │       ▼                               │    │
│  │  ┌──────────┐    ┌──────────────┐    │    │
│  │  │ Network  │───►│ CNI (exec)   │────┼────┼──► Calico/Flannel
│  │  │ Plugin   │    │              │    │    │
│  │  └──────────┘    └──────────────┘    │    │
│  │       │                               │    │
│  │       ▼                               │    │
│  │  ┌──────────┐                         │    │
│  │  │  cAdvisor│───► 收集容器指标        │    │
│  │  └──────────┘                         │    │
│  └──────────────────────────────────────┘    │
│                                               │
│  ←──── 上报节点/Pod 状态到 apiserver ────►    │
└──────────────────────────────────────────────┘
```

### Pod Sync Loop

kubelet 的核心是一个**同步循环**：

```
while true:
    1. 从 apiserver 获取分配到此节点的 Pod 列表
    2. 与本地实际运行的容器对比
    3. 对于缺失的 Pod：调用 CRI 创建
    4. 对于多余的 Pod：调用 CRI 删除
    5. 对于已存在的 Pod：检查状态，执行探针
    6. 上报节点和 Pod 状态到 apiserver
    7. sleep(sync interval，默认 10s)
```

### Pod 生命周期管理

```
apiserver 下发 Pod spec
        │
        ▼
   kubelet 接收
        │
        ├── 创建 Sandbox（pause 容器）
        │   └── 创建网络命名空间
        │   └── 调用 CNI 配置网络
        │
        ├── 创建 Init 容器（按序执行）
        │
        ├── 创建业务容器
        │   └── 调用 CRI PullImage
        │   └── 调用 CRI CreateContainer
        │   └── 调用 CRI StartContainer
        │
        ├── 配置存储
        │   └── 调用 CSI/内置插件 挂载卷
        │
        ├── 执行探针
        │   ├── startupProbe
        │   ├── livenessProbe
        │   └── readinessProbe
        │
        └── 持续监控并上报状态
```

### 节点注册与心跳

```
1. 节点启动时
   kubelet → apiserver POST /nodes
   └── 注册节点信息（IP、容量、标签等）

2. 节点运行中
   kubelet → apiserver PATCH /nodes/{name}/status
   └── 每 10 秒更新一次节点状态

3. 节点失联
   Node Controller 检测到超过 40 秒（默认）未收到心跳
   └── 标记节点为 NotReady
   └── 驱逐节点上的 Pod（设置 tolerationSeconds）
```

**节点状态字段**：
```yaml
status:
  conditions:
    - type: Ready           # 节点是否健康
      status: "True"
    - type: DiskPressure    # 磁盘压力
      status: "False"
    - type: MemoryPressure  # 内存压力
      status: "False"
    - type: PIDPressure     # 进程压力
      status: "False"
    - type: NetworkUnavailable  # 网络是否可用
      status: "False"
  capacity:
    cpu: "8"
    memory: 32850180Ki
    pods: "110"
  allocatable:
    cpu: "7900m"
    memory: 31746180Ki
    pods: "110"
```

### 驱逐机制（Eviction）

当节点资源不足时，kubelet 会**主动驱逐 Pod**。

**驱逐信号**：

| 信号 | 描述 | 软驱逐阈值 | 硬驱逐阈值 |
|------|------|-----------|-----------|
| `memory.available` | 节点可用内存 | 100Mi | 100Mi |
| `nodefs.available` | 节点文件系统可用空间 | 10% | 5% |
| `nodefs.inodesFree` | 节点 inode 数量 | 5% | 4% |
| `imagefs.available` | 镜像文件系统可用空间 | 15% | 10% |

**软驱逐 vs 硬驱逐**：
- **软驱逐**：超过阈值后，先等 `eviction-soft-grace-period`（如 1m30s），如果仍超阈值才驱逐
- **硬驱逐**：超过阈值**立即**驱逐

**驱逐优先级**（QOS 等级）：
1. `BestEffort`（未设置 requests/limits）— 最先被驱逐
2. `Burstable`（设置了 requests ≠ limits）
3. `Guaranteed`（requests == limits）— 最后被驱逐

---

## kube-proxy — 网络代理

### 职责

kube-proxy 运行在每个节点上，负责实现 **Kubernetes Service** 的网络功能：
- 将 Service 的虚拟 IP 映射到后端 Pod 的 IP
- 实现负载均衡
- 维护网络规则（iptables 或 IPVS）

### 三种模式

#### 1. iptables 模式（默认）

```
Service: my-svc, ClusterIP: 10.96.0.1
后端 Pods: 10.244.1.2, 10.244.1.3, 10.244.1.4

iptables 规则（由 kube-proxy 维护）：
-A KUBE-SERVICES -d 10.96.0.1/32 -p tcp -m tcp --dport 80
  -j KUBE-SVC-XXXXX

-A KUBE-SVC-XXXXX -m statistic --mode random --probability 0.333
  -j KUBE-SEP-AAAAA   # → 10.244.1.2
-A KUBE-SVC-XXXXX -m statistic --mode random --probability 0.500
  -j KUBE-SEP-BBBBB   # → 10.244.1.3
-A KUBE-SVC-XXXXX
  -j KUBE-SEP-CCCCC   # → 10.244.1.4
```

**特点**：
- 使用 Linux iptables 实现 NAT 和负载均衡
- 随机分发（probability 链）
- 规则数量随 Service × Endpoint 线性增长
- 大规模集群（> 1000 Service）性能下降

#### 2. IPVS 模式（推荐）

```
IPVS 规则（由 kube-proxy 维护）：

ipvsadm -Ln
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn
TCP  10.96.0.1:80 rr
  -> 10.244.1.2:80                Masq    1      0
  -> 10.244.1.3:80                Masq    1      0
  -> 10.244.1.4:80                Masq    1      0
```

**特点**：
- 使用 Linux IPVS（内核级负载均衡）
- 支持多种调度算法：rr（轮询）、lc（最少连接）、dh、sh、sed、nq
- 规则存储在内核哈希表，查询 O(1)
- 适合大规模集群

**启用 IPVS**：
```yaml
# kube-proxy ConfigMap
mode: "ipvs"
ipvs:
  scheduler: "rr"
```

#### 3. eBPF 模式（实验性）

一些 CNI 插件（如 Cilium）实现了 kube-proxy 的功能，可以完全替代 kube-proxy。

```
Pod A ──► Service IP ──► Cilium eBPF ──► Pod B
                 （无 iptables，直接 eBPF 转发）
```

### kube-proxy 工作流

```
apiserver 中 Service/Endpoint 变化
         │
         ▼
   kube-proxy Watch
         │
         ▼
   更新 iptables/IPVS 规则
         │
         ▼
   节点上生效
```

### Service 到 Pod 的流量路径

```
Pod (src: 10.244.1.5) 访问 my-svc:80 (10.96.0.1)
         │
         ├── 数据包到达节点网桥/路由
         │
         ├── kube-proxy 的 iptables/IPVS 规则捕获
         │       │
         │       ├── DNAT：目标 IP 从 10.96.0.1 改为后端 Pod IP
         │       │
         │       └── 负载均衡：选择其中一个后端 Pod
         │
         ├── 数据包发送到目标 Pod 所在节点
         │       （如果同节点则直接转发）
         │
         └── 目标 Pod 收到请求
                 src: 10.244.1.5, dst: 10.244.1.3
```

---

## 容器运行时（Container Runtime）

### CRI — 容器运行时接口

CRI（Container Runtime Interface）是 kubelet 与容器运行时之间的**标准 gRPC 接口**。

```
┌─────────┐     gRPC (CRI)     ┌─────────────────┐
│ kubelet │◄──────────────────►│ Container       │
│         │  RunPodSandbox     │ Runtime         │
│         │  CreateContainer   │ (containerd/    │
│         │  StartContainer    │  CRI-O)         │
│         │  StopContainer     │                 │
│         │  RemovePodSandbox  │                 │
└─────────┘                    └────────┬────────┘
                                        │
                              ┌─────────┴─────────┐
                              ▼                   ▼
                        ┌──────────┐        ┌──────────┐
                        │ runc     │        │ runc     │
                        │ (OCI)    │        │ (OCI)    │
                        └──────────┘        └──────────┘
```

**CRI 定义的服务**：
- `RuntimeService`：容器生命周期管理（创建、启动、停止、删除）
- `ImageService`：镜像管理（拉取、查看、删除）

### containerd

containerd 是目前最常用的容器运行时。

```
containerd 架构：

┌──────────────────────────────────────────────┐
│              containerd                        │
│                                                │
│  ┌────────────┐  ┌────────────┐              │
│  │ CRI Plugin │  │  Image     │              │
│  │            │  │  Service   │              │
│  └─────┬──────┘  └─────┬──────┘              │
│        │               │                      │
│  ┌─────┴──────┐  ┌─────┴──────┐              │
│  │ Container  │  │  Snapshot  │              │
│  │  Service   │  │   Service  │              │
│  └─────┬──────┘  └─────┬──────┘              │
│        │               │                      │
│  ┌─────┴──────┐  ┌─────┴──────┐              │
│  │  Runtime   │  │  Content   │              │
│  │  (runc)    │  │  Store     │              │
│  └────────────┘  └────────────┘              │
└──────────────────────────────────────────────┘
```

### 镜像拉取流程

```
1. kubelet 从 Pod spec 获取 image
2. kubelet 调用 CRI ImageService.PullImage()
3. containerd 解析镜像引用（registry + namespace + repo + tag）
4. containerd 从镜像仓库拉取镜像层
5. containerd 使用 snapshotter 解压镜像层
6. containerd 返回镜像 ID 给 kubelet
```

### 容器创建流程

```
1. kubelet 调用 CRI RuntimeService.RunPodSandbox()
   └── containerd 创建 pause 容器
   └── containerd 调用 CNI 配置网络
   └── 返回 sandbox ID

2. kubelet 调用 CRI RuntimeService.PullImage()（如果需要）

3. kubelet 调用 CRI RuntimeService.CreateContainer()
   └── containerd 准备容器 rootfs（overlayfs）
   └── containerd 生成 OCI runtime spec
   └── 返回 container ID

4. kubelet 调用 CRI RuntimeService.StartContainer()
   └── containerd 调用 runc create + runc start
   └── 容器进程启动
```

### OCI 标准

OCI（Open Container Initiative）定义了容器的标准：
- **runtime-spec**：容器运行时规范（runc 实现）
- **image-spec**：容器镜像规范

```
OCI Image:
├── manifest.json       # 镜像清单（层列表、配置）
├── config.json         # 容器配置（环境变量、命令、用户）
├── layer1.tar.gz       # 只读层
├── layer2.tar.gz
└── ...

运行时通过 overlayfs 合并所有层：
  lowerdir = layer1:layer2:...
  upperdir = 可写层
  merged = 合并后的视图
```

---

## 工作节点组件总结

| 组件 | 核心职责 | 运行位置 | 与 apiserver 关系 |
|------|---------|---------|------------------|
| kubelet | 管理节点上的容器生命周期 | 每个节点 | 主动连接 apiserver |
| kube-proxy | 维护 Service 网络规则 | 每个节点 | Watch apiserver |
| containerd | 创建和管理容器 | 每个节点 | 通过 CRI 与 kubelet 交互 |
| CNI Plugin | 配置 Pod 网络 | 每个节点 | 被 kubelet/containerd 调用 |
| CSI Driver | 挂载/卸载存储卷 | 每个节点 | 被 kubelet 调用 |

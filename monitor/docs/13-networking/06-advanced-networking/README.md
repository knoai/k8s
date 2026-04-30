# 高级网络技术

> 专家级网络知识：BGP、VXLAN、DPDK、RDMA、SR-IOV、智能网卡。这些技术在高性能计算、AI/ML 基础设施、金融交易系统中至关重要。

---

## 1. BGP（边界网关协议）

### 1.1 BGP 基础

```
BGP 是互联网的路由协议，用于在不同自治系统（AS）之间交换路由信息。

┌─────────────────────────────────────────────────────────────┐
│                    BGP 基本概念                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  AS (Autonomous System): 自治系统                           │
│  - 一个组织管理的网络集合                                    │
│  - AS 号: 16位 (1-65535) 或 32位                           │
│  - 公有 AS: 1-64511, 私有 AS: 64512-65534                  │
│                                                             │
│  eBGP: 不同 AS 之间的 BGP 对等                              │
│  iBGP: 同一 AS 内部的 BGP 对等                              │
│                                                             │
│  路径矢量协议: 不仅传递路由，还传递路径信息（AS_PATH）        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 BGP 在 K8s 中的应用

```
Calico BGP 模式：

        ┌─────────────────────────┐
        │   核心交换机 (RR)        │
        │   AS 64512               │
        │   Route Reflector        │
        └───────────┬─────────────┘
                    │ iBGP Peering
        ┌───────────┼───────────┐
        │           │           │
   ┌────▼────┐ ┌────▼────┐ ┌────▼────┐
   │ Node 1  │ │ Node 2  │ │ Node 3  │
   │ AS 64512│ │ AS 64512│ │ AS 64512│
   │ 宣告     │ │ 宣告     │ │ 宣告     │
   │10.244.1.0│ │10.244.2.0│ │10.244.3.0│
   │  /24    │ │  /24    │ │  /24    │
   └─────────┘ └─────────┘ └─────────┘

优势：
  - 直接与现有网络基础设施集成
  - 无需 Overlay 封装，性能最好
  - 路由器可以直接访问 Pod IP

配置要点：
  - 与网络团队协调 AS 号
  - 配置 Route Reflector 避免全互联
  - 注意 BGP 路由数量（每个节点一个 /24）
```

### 1.3 BGP 常用命令

```bash
# 查看 BGP 邻居
kubectl exec -n calico-system <calico-node> -- birdcl show protocols

# 查看 BGP 路由
kubectl exec -n calico-system <calico-node> -- birdcl show route

# 查看 BGP 邻居详情
kubectl exec -n calico-system <calico-node> -- birdcl show protocols all bgp

# 查看路由详情
ip route show proto bird
ip route show proto bgp
```

---

## 2. VXLAN 与 Overlay 网络

### 2.1 VXLAN 协议详解

```
VXLAN (Virtual Extensible LAN)

┌─────────────────────────────────────────────────────────────┐
│                    VXLAN 封装格式                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  原始以太网帧（内层）:                                        │
│  ┌────────┬────────┬────────┬────────┬────────┐            │
│  │Dst MAC │Src MAC │  Type  │  Payload  │ FCS  │            │
│  │ 6 bytes│ 6 bytes│ 2 bytes│ 46-1500B │4 bytes│            │
│  └────────┴────────┴────────┴────────┴────────┘            │
│                                                             │
│  VXLAN 封装后（外层）:                                       │
│  ┌────────┬────────┬────────┬───────┬────────┬───────┬─────┐│
│  │Outer IP│ Outer  │  UDP   │VXLAN  │Inner   │ Inner │     ││
│  │Header  │ IP     │Header  │Header │Ethernet│Payload│     ││
│  │20 bytes│        │8 bytes │8 bytes│Header  │       │     ││
│  └────────┴────────┴────────┴───────┴────────┴───────┴─────┘│
│                                                             │
│  VTEP (VXLAN Tunnel Endpoint):                              │
│  - 负责封装/解封装 VXLAN 包                                   │
│  - 通过 UDP 端口 4789（默认）或 8472（Flannel）通信           │
│  - VNI (VXLAN Network Identifier): 24位，隔离不同租户         │
│                                                             │
│  MTU 注意：                                                  │
│  - 以太网 MTU: 1500                                          │
│  - VXLAN 开销: 50 bytes                                      │
│  - 容器 MTU 应设为: 1450                                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VXLAN 与 IPIP 对比

| 特性 | VXLAN | IPIP | GRE |
|------|-------|------|-----|
| 封装层 | L2 over UDP | IP over IP | 通用路由封装 |
| 开销 | 50 bytes | 20 bytes | 24 bytes |
| 端口 | UDP 4789/8472 | IP 协议 4 | IP 协议 47 |
| 多播支持 | 是 | 否 | 是 |
| 防火墙友好 | 需开放 UDP | IP 协议需允许 | IP 协议需允许 |
| NAT 穿越 | 较容易 | 困难 | 困难 |

---

## 3. DPDK（数据平面开发套件）

### 3.1 DPDK 原理

```
传统 Linux 网络 vs DPDK：

传统方式（内核态处理）：
  网卡 → 驱动 → 内核网络栈 → socket → 应用
  多次上下文切换、数据拷贝

DPDK 方式（用户态处理）：
  网卡 → 驱动(PMD) → 用户态内存池 → 应用
  绕过内核，零拷贝，轮询模式

┌─────────────────────────────────────────────────────────────┐
│                    DPDK 架构                                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  User Space                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   App       │  │   App       │  │   App       │        │
│  │ (Nginx/     │  │ (VPP/       │  │ (OVS-DPDK)  │        │
│  │  Envoy)     │  │  FD.io)     │  │             │        │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘        │
│         │                │                │                 │
│  ┌──────▼────────────────▼────────────────▼──────┐         │
│  │              DPDK Libraries                    │         │
│  │  EAL:  Environment Abstraction Layer          │         │
│  │  Mempool: 内存池管理                           │         │
│  │  Ring: 无锁队列                                │         │
│  │  PMD: Poll Mode Driver（轮询网卡）             │         │
│  └────────────────────────────────────────────────┘         │
│                          │                                  │
│  Kernel Space             │  (绕过)                          │
│  ┌───────────────────────┘                                  │
│  │  UIO / VFIO: 用户态 I/O（网卡直通）                        │
│  └──────────────────────────────────────────────────────────┘
│                          │
│  Hardware                ▼
│  ┌──────────────────────────────────────────────────────────┐
│  │                    NIC (网卡)                             │
│  │  - SR-IOV VF (虚拟功能)                                   │
│  │  - 支持 DPDK 的网卡: Intel i40e, Mellanox mlx5, etc.     │
│  └──────────────────────────────────────────────────────────┘
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 DPDK 在 K8s 中的应用

```
K8s 中 DPDK 使用场景：

1. SR-IOV + DPDK:
   - 物理网卡虚拟化（SR-IOV VF）
   - VF 直通到 Pod
   - Pod 内使用 DPDK 驱动

2. OVS-DPDK:
   - Open vSwitch 使用 DPDK 加速
   - 用于 K8s CNI（如 Kube-OVN）

3. 云原生网关：
   - Envoy + DPDK
   - 高性能 L4/L7 负载均衡

配置要求：
  - 大页内存 (HugePages)
  - CPU 隔离/绑定
  - 内核启动参数: intel_iommu=on iommu=pt
```

---

## 4. RDMA（远程直接内存访问）

### 4.1 RDMA 原理

```
RDMA 允许一台机器直接访问另一台机器的内存，无需 CPU 介入。

传统 TCP：                    RDMA：
发送方                        发送方
  │ 1. 应用拷贝数据到内核         │ 1. 应用写入本地内存区域
  │ 2. 内核协议栈处理            │ 2. 网卡直接从内存读取发送
  │ 3. 网卡发送                  │
  │ 4. 接收方网卡收到            │ 接收方
  │ 5. 内核协议栈处理            │ 3. 网卡直接写入本地内存
  │ 6. 拷贝到应用内存            │ 4. 应用直接读取（零拷贝）
  ▼                            ▼
高延迟、高 CPU 占用            低延迟（微秒级）、低 CPU

RDMA 三种实现：
  1. InfiniBand (IB): 专用网络，性能最好
  2. RoCE v1/v2 (RDMA over Converged Ethernet): 以太网
  3. iWARP: TCP 上的 RDMA（较少使用）
```

### 4.2 RDMA 在 K8s 中的应用

```
AI/ML 训练场景：

┌─────────────────────────────────────────────────────────────┐
│                    GPU 集群                                   │
│                                                              │
│  ┌─────────┐          ┌─────────┐          ┌─────────┐     │
│  │ Node 1  │◄────────►│ Node 2  │◄────────►│ Node 3  │     │
│  │         │   RDMA   │         │   RDMA   │         │     │
│  │ GPU x8  │ 100Gbps  │ GPU x8  │ 100Gbps  │ GPU x8  │     │
│  │         │          │         │          │         │     │
│  │ Pod     │          │ Pod     │          │ Pod     │     │
│  │ NCCL    │          │ NCCL    │          │ NCCL    │     │
│  └─────────┘          └─────────┘          └─────────┘     │
│                                                              │
│  K8s 中部署：                                                │
│  - Mellanox OFED 驱动                                        │
│  - SR-IOV Device Plugin                                      │
│  - RDMA Device Plugin (如 k8s-rdma-shared-dev-plugin)       │
│  - Network Operator                                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 SR-IOV（单根 I/O 虚拟化）

```
SR-IOV 允许一个物理网卡虚拟出多个 VF（Virtual Function）：

物理网卡 (PF - Physical Function)
  │
  ├─ VF 1 → Pod A (直通)
  ├─ VF 2 → Pod B (直通)
  ├─ VF 3 → Pod C (直通)
  └─ VF 4 → Pod D (直通)

优势：
  - 接近物理网卡性能
  - 绕过 Linux 网络栈
  - 支持 DPDK、RDMA

K8s 中配置：
  1. BIOS 启用 SR-IOV、VT-d
  2. 内核参数: intel_iommu=on iommu=pt
  3. 安装 SR-IOV Network Operator
  4. 创建 SriovNetworkNodePolicy
  5. Pod 申请 SR-IOV 资源
```

---

## 5. 智能网卡（SmartNIC / DPU）

```
智能网卡演进：

普通网卡          SmartNIC          DPU (Data Processing Unit)
  │                │                    │
  ▼                ▼                    ▼
仅数据收发    + 卸载功能            + 独立处理器
              (TSO/GSO/checksum)    (ARM cores)
                                    + 可编程
                                    + 运行操作系统

功能卸载：
  - TSO/GSO: TCP Segmentation Offload / Generic Segmentation Offload
  - GRO: Generic Receive Offload
  - Checksum Offload: 校验和计算卸载
  - RSS: Receive Side Scaling（多队列）
  - RDMA: 远程内存访问
  - 加密/解密
  - 压缩/解压缩

代表产品：
  - NVIDIA BlueField (DPU)
  - Intel IPU (Infrastructure Processing Unit)
  - AMD Pensando
  - Marvell OCTEON

K8s 中的应用：
  - 网络功能卸载（Cilium eBPF → DPU）
  - 存储卸载（NVMe-oF）
  - 安全卸载（TLS/IPSec）
```

---

## 6. 网络性能优化总结

```
优化层级：

应用层：
  - 连接池复用
  - HTTP/2 或 HTTP/3
  - 批量处理
  - 压缩 (gzip, zstd)

传输层：
  - 增大 TCP 缓冲区
  - 启用 TCP Fast Open
  - 调整拥塞控制算法 (BBR)

网络层：
  - 选择合适的 CNI（Cilium eBPF）
  - 避免不必要的 NAT
  - 使用 DSR (Direct Server Return)

数据链路层：
  - 网卡多队列 (RSS)
  - 队列大小调整
  - 环形缓冲区优化

硬件层：
  - 25G/100G 网卡
  - SR-IOV
  - DPDK
  - RDMA
  - SmartNIC/DPU
```

---

## 参考资源

- [BGP RFC 4271](https://tools.ietf.org/html/rfc4271)
- [VXLAN RFC 7348](https://tools.ietf.org/html/rfc7348)
- [DPDK Documentation](https://doc.dpdk.org/guides/)
- [RDMA Consortium](http://www.rdmaconsortium.org/)
- [NVIDIA BlueField DPU](https://www.nvidia.com/en-us/networking/products/data-processing-unit/)

# CNI 插件深入：Calico vs Cilium vs Flannel

> K8s 网络的核心在于 CNI 插件。深入理解主流 CNI 的实现原理、性能差异和适用场景，是高级云原生工程师的必备能力。

---

## 1. CNI 插件概述

| 插件 | 数据平面 | 网络模式 | 网络策略 | eBPF | 适用场景 |
|------|---------|---------|---------|------|---------|
| **Flannel** | VXLAN/UDP | Overlay | 不支持 | 不支持 | 简单场景、小集群 |
| **Calico** | BGP/IPIP/VXLAN | Underlay/Overlay | 支持 | 可选（eBPF dataplane） | 大规模、需要策略 |
| **Cilium** | eBPF/XDP | Overlay/BGP | 支持（细粒度） | 原生 | 安全、可观测性、高性能 |
| **Weave** | VXLAN | Overlay | 支持 | 不支持 | 简单加密 |
| **Antrea** | OVS | Overlay | 支持 | 可选 | VMware 生态 |

---

## 2. Flannel：简单 Overlay

### 2.1 架构

```
Flannel VXLAN 模式：

Node A (192.168.1.10)                Node B (192.168.1.11)
Pod CIDR: 10.244.1.0/24              Pod CIDR: 10.244.2.0/24

┌─────────────────────┐              ┌─────────────────────┐
│ flannel.1 (VTEP)    │              │ flannel.1 (VTEP)    │
│ 10.244.1.0/32       │◄────────────►│ 10.244.2.0/32       │
│ MAC: ab:cd:ef:...   │   VXLAN      │ MAC: 12:34:56:...   │
│ VTEP IP: 192.168.1.10│  UDP:8472   │ VTEP IP: 192.168.1.11│
└──────────┬──────────┘              └──────────┬──────────┘
           │                                     │
    ┌──────┴──────┐                       ┌──────┴──────┐
    ▼             ▼                       ▼             ▼
┌───────┐     ┌───────┐             ┌───────┐     ┌───────┐
│ Pod   │     │ Pod   │             │ Pod   │     │ Pod   │
│.1.5   │     │.1.6   │             │.2.5   │     │.2.6   │
└───────┘     └───────┘             └───────┘     └───────┘

VXLAN 封装：
  原始帧: [MAC][IP][TCP][DATA]
  VXLAN: [UDP头][VXLAN头][原始以太网帧]
  开销: 50 字节 (20 IP + 8 UDP + 8 VXLAN + 14 以太网)
  所以容器 MTU 应设置为 1450（1500 - 50）
```

### 2.2 Flannel 配置

```yaml
# kube-flannel.yml
net-conf.json: |
  {
    "Network": "10.244.0.0/16",
    "SubnetLen": 24,
    "Backend": {
      "Type": "vxlan",        # vxlan / udp / host-gw / wireguard
      "VNI": 1,
      "Port": 8472
    }
  }

# 后端类型对比：
# vxlan:    UDP 封装，跨子网可用，性能较好
# host-gw:  纯路由，无封装，性能最好，但要求节点二层可达
# udp:      早期实现，性能差，已不推荐
# wireguard: 加密隧道，安全
```

### 2.3 Flannel 的局限

```
缺点：
  1. 无网络策略（NetworkPolicy）支持
  2. 只有 Overlay 网络，性能有损耗
  3. 功能单一，无法满足安全需求
  4. 故障排查困难（隧道封装隐藏了真实路径）

解决方案：
  - Flannel + Calico (Canal): Flannel 负责网络，Calico 负责策略
  - 或者直接使用 Calico/Cilium
```

---

## 3. Calico：路由之王

### 3.1 BGP 模式架构

```
Calico BGP 模式（Underlay）：

              ┌─────────────┐
              │   Router    │  ← BGP Route Reflector
              │   (RR)      │     或全互联 (full mesh)
              └──────┬──────┘
                     │ BGP peering
        ┌────────────┼────────────┐
        │            │            │
   ┌────▼────┐  ┌────▼────┐  ┌────▼────┐
   │ Node A  │  │ Node B  │  │ Node C  │
   │BGP peer │  │BGP peer │  │BGP peer │
   └────┬────┘  └────┬────┘  └────┬────┘
        │            │            │
   Pod: 10.244.1.5   Pod: 10.244.2.5   Pod: 10.244.3.5

特点：
  - 每个节点运行 BIRD (BGP daemon)
  - 节点将本地 Pod CIDR 通过 BGP 宣告
  - 路由器学习到所有 Pod 路由
  - 数据包直接路由，无封装开销

路由表（在节点上）：
  $ ip route
  10.244.2.0/24 via 192.168.1.11 dev eth0 proto bird
  10.244.3.0/24 via 192.168.1.12 dev eth0 proto bird
```

### 3.2 Calico 网络策略

```yaml
# NetworkPolicy: 只允许 frontend 访问 backend 的 8080 端口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

```
Calico 策略实现：

1. 标准 NetworkPolicy（iptables）:
   - 利用 K8s NetworkPolicy API
   - 通过 iptables 规则实现
   - 基于标签的 L3/L4 策略

2. Calico NetworkPolicy（更强大）:
   - GlobalNetworkPolicy: 集群级策略
   - 可以指定 namespaceSelector、serviceAccountSelector
   - 支持规则顺序（order）
   - 支持 log action

3. Calico eBPF dataplane（高性能）:
   - 替代 iptables
   - 更高性能、更低延迟
   - 支持源 IP 保留（Direct Server Return）
```

### 3.3 Calico 架构组件

```
┌─────────────────────────────────────────────────────────────┐
│                         Calico 组件                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  calico-node (DaemonSet)                                    │
│  ───────────────────────                                    │
│  - felix:    编程路由、ACL、NAT（iptables/ipvs/eBPF）        │
│  - BIRD:     BGP 守护进程（路由宣告）                         │
│  - confd:    监听 etcd，生成 BIRD 配置                       │
│                                                             │
│  calico-kube-controllers (Deployment)                       │
│  ────────────────────────────────────                       │
│  - 监听 K8s API，同步 Pod/Namespace/ServiceAccount 信息      │
│  - 处理 HostEndpoint、NetworkPolicy 资源                     │
│                                                             │
│  calico-typha (可选，大规模集群)                              │
│  ───────────────────────────────                            │
│  - 连接 felix 和 etcd 的缓存层                               │
│  - 减少 etcd 压力                                           │
│                                                             │
│  calico-apiserver (可选)                                    │
│  ───────────────────────                                    │
│  - 提供 Calico API Server                                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.4 Calico 关键配置

```bash
# 查看 BGP 对等体
kubectl exec -n calico-system <calico-node> -- calicoctl node status

# 查看 IP Pool
kubectl exec -n calico-system <calico-node> -- calicoctl get ippool -o wide

# 查看工作负载端点（Pod 的网络端点）
kubectl exec -n calico-system <calico-node> -- calicoctl get workloadendpoint

# 查看 BGP 配置
kubectl exec -n calico-system <calico-node> -- calicoctl get bgpconfig

# 性能模式切换
# eBPF dataplane
kubectl patch installation default --type=merge -p '{"spec": {"calicoNetwork": {"linuxDataplane": "BPF"}}}'
```

---

## 4. Cilium：eBPF 革命

### 4.1 eBPF 数据平面

```
Cilium eBPF 架构：

┌─────────────────────────────────────────────────────────────┐
│                      User Space                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Cilium    │  │   Hubble    │  │   Envoy     │         │
│  │   Agent     │  │  (可观测性)  │  │  (L7代理)   │         │
│  │             │  │             │  │             │         │
│  │ - 编译 eBPF │  │ - 流量可视化 │  │ - HTTP/gRPC │         │
│  │ - 策略管理  │  │ - 流日志    │  │   策略      │         │
│  │ - IPAM      │  │ - 安全审计  │  │ - 重试      │         │
│  └──────┬──────┘  └─────────────┘  └─────────────┘         │
└─────────┼───────────────────────────────────────────────────┘
          │ BPF map / perf event
┌─────────▼───────────────────────────────────────────────────┐
│                    Kernel Space (eBPF)                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │               XDP (eXpress Data Path)                 │   │
│  │  网卡驱动层，最早处理点                                 │   │
│  │  - DDoS 防护、快速丢包                                 │   │
│  │  - 加载点: Native / Offloaded / Generic                │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                   │
│  ┌───────────────────────▼──────────────────────────────┐   │
│  │              TC Ingress (Traffic Control)             │   │
│  │  - L3/L4 策略执行                                      │   │
│  │  - Load Balancing (DSR/Maglev)                        │   │
│  │  - 透明加密 (WireGuard/IPSec)                         │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                   │
│  ┌───────────────────────▼──────────────────────────────┐   │
│  │              Socket Layer (sockops)                   │   │
│  │  - socket 级别重定向（绕过 TCP/IP 栈）                 │   │
│  │  - 同节点 Pod 间零拷贝通信                             │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                   │
│  ┌───────────────────────▼──────────────────────────────┐   │
│  │              TC Egress                                  │   │
│  │  - 出站策略                                            │   │
│  │  - NAT/加密                                            │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  BPF Maps（状态存储）:                                       │
│  - cilium_ipcache:     IP → Identity 映射                   │
│  - cilium_lb*:         负载均衡后端                          │
│  - cilium_policy:      网络策略                              │
│  - cilium_ct*:         连接跟踪                              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Cilium 优势

```
相比 iptables：
  - 性能: O(1) vs O(n)，规则数量不影响性能
  - 连接数: 百万级 vs 十万级
  - 延迟: 微秒级 vs 毫秒级

相比 Calico：
  - 原生支持 eBPF，无需切换 dataplane
  - 内置 Hubble 可观测性
  - 更细粒度的安全策略（HTTP method、gRPC API）
  - 内置 L7 负载均衡和服务网格功能

身份模型（Identity-based Security）：
  传统: 基于 IP 的策略 → IP 变化后策略失效
  Cilium: 基于标签的身份 → Pod IP 变化不影响策略
```

### 4.3 Cilium 网络策略

```yaml
# L3/L4 策略（标准）
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l3-l4-policy
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP

# L7 策略（HTTP/gRPC）— Cilium 独有
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-policy
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: web
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/v1/.*"
              - method: POST
                path: "/api/v1/users"
```

### 4.4 Cilium 关键命令

```bash
# 查看 Cilium 状态
cilium status

# 查看端点（Pod）
cilium endpoint list
cilium endpoint get <id>

# 查看 BPF 策略
cilium bpf policy list <endpoint-id>

# 查看负载均衡
cilium bpf lb list

# 查看 IP 缓存（身份映射）
cilium bpf ipcache list

# 查看连接跟踪
cilium bpf ct list global

# 查看 Hubble 流
hubble observe --server localhost:4245
hubble observe --namespace default --pod my-pod

# 追踪数据包路径
cilium monitor
cilium monitor --type drop    # 查看丢包原因
cilium monitor --type trace   # 查看完整路径

# 调试 DNS
cilium policy trace --src-identity <id> --dst-identity <id> --dport 53/UDP
```

---

## 5. CNI 选型决策树

```
集群规模？
  ├─ < 50 节点: Flannel（简单）/ Cilium（可扩展）
  └─ > 50 节点: Calico BGP / Cilium

需要网络策略？
  ├─ 否: Flannel
  └─ 是:
       策略粒度？
       ├─ L3/L4: Calico
       └─ L7 (HTTP/gRPC): Cilium

性能要求？
  ├─ 一般: Calico iptables
  └─ 高: Cilium eBPF / Calico eBPF

可观测性要求？
  ├─ 基础: Calico + 自建
  └─ 深度: Cilium + Hubble

现有网络环境？
  ├─ 私有数据中心，BGP 可用: Calico BGP
  └─ 公有云 /  Overlay: Cilium / Calico VXLAN

安全要求？
  ├─ 基础隔离: Calico
  └─ 零信任、微分段: Cilium
```

---

## 6. CNI 排障

```bash
# 通用排障

# 1. 查看 CNI 插件日志
journalctl -u kubelet | grep -i cni

# 2. 检查 CNI 配置
ls /etc/cni/net.d/
cat /etc/cni/net.d/10-*.conflist

# 3. 检查 CNI 二进制
ls /opt/cni/bin/

# 4. 查看已分配的 IP
# Flannel/Calico
ls /var/lib/cni/networks/
# Cilium
cilium endpoint list

# Calico 特定排障
# 查看 BGP 状态
calicoctl node status
# 查看 felix 日志
kubectl logs -n calico-system -l k8s-app=calico-node

# Cilium 特定排障
# 查看 Agent 状态
cilium status --verbose
# 查看 drop 原因
cilium monitor --type drop
# BPF map 检查
cilium bpf endpoint list
cilium bpf ipcache list
```

---

## 参考资源

- [Calico Documentation](https://docs.tigera.io/)
- [Cilium Documentation](https://docs.cilium.io/)
- [Flannel GitHub](https://github.com/flannel-io/flannel)
- [eBPF.io](https://ebpf.io/)

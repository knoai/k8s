# VLAN、iptables 与 eBPF：网络技术的演进与对比

> 从传统 VLAN 隔离到 iptables 过滤，再到 eBPF 革命，理解网络技术演进的路径，是云原生工程师构建高性能、可观测、安全网络的基础。

---

## 1. 三种技术的定位

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        网络技术演进时间线                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1990s          2000s            2010s             2020s                    │
│    │              │                │                  │                      │
│    ▼              ▼                ▼                  ▼                      │
│  VLAN ──────► iptables ──────► OVS/DPDK ──────► eBPF/XDP                    │
│                                                                             │
│  网络隔离        流量过滤          软件定义网络       内核可编程                │
│  (L2)           (L3/L4)          (Overlay)         (任意层)                  │
│                                                                             │
│  在 Harvester/                                                                │
│  K8s 中的应用:                                                                │
│  • Harvester VM    • kube-proxy     • OVS-CNI       • Cilium               │
│    Network         • Calico策略      • OpenStack      • Hubble               │
│    (Access/Trunk)  • Docker网络      • Neutron        • Tetragon             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

| 维度 | VLAN | iptables | eBPF |
|------|------|----------|------|
| **工作层级** | L2 (数据链路层) | L3/L4 (网络/传输层) | L2-L7 (任意层) |
| **隔离方式** | 广播域隔离 | 包过滤/NAT | 内核可编程逻辑 |
| **性能** | 硬件转发，无开销 | 软件遍历规则链，O(n) | 内核 JIT 编译，O(1) |
| **灵活性** | 低（需物理交换机配合） | 中（基于 IP/port） | 极高（任意逻辑） |
| **可观测性** | 无内置观测 | 有限（计数器） | 原生（perf event/map） |
| **K8s 代表** | Harvester VM Network | kube-proxy iptables 模式 | Cilium eBPF dataplane |

---

## 2. VLAN：网络隔离的基石

### 2.1 VLAN 原理回顾

```
VLAN (Virtual LAN) 通过 802.1Q tag 在物理网络上划分逻辑广播域

以太网帧格式:
┌─────────┬─────────┬─────────┬────────┬────────┬────────┐
│Dst MAC  │Src MAC  │802.1Q   │Type    │Payload │FCS     │
│6 bytes  │6 bytes  │4 bytes  │2 bytes │46-1500B│4 bytes │
└─────────┴─────────┴─────────┴────────┴────────┴────────┘
                      ↑
              ┌───────┴───────┐
              │ TCI (2 bytes)  │
              │  - PCP (3bit)  │ 优先级
              │  - CFI (1bit)  │
              │  - VID (12bit)│ VLAN ID (1-4094)
              └───────────────┘

在 Harvester/K8s 中的 VLAN 实现:

┌─────────────────────────────────────────────────────────────┐
│                    Harvester VLAN 网络                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  物理交换机 (Trunk Port)                                     │
│       │  带 VLAN tag 的包                                     │
│       ▼                                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Harvester 节点                          │   │
│  │                                                      │   │
│  │  ┌─────────────┐    ┌─────────────────────────────┐ │   │
│  │  │  eth1       │───►│  cn-data-br (Linux Bridge)  │ │   │
│  │  │ (物理网卡)   │    │                             │ │   │
│  │  └─────────────┘    │  vlan filtering: on         │ │   │
│  │                     │                             │ │   │
│  │                     │  ┌─────┐  ┌─────┐  ┌─────┐ │ │   │
│  │                     │  │veth │  │veth │  │veth │ │ │   │
│  │                     │  │VM-A │  │VM-B │  │VM-C │ │ │   │
│  │                     │  │V100 │  │V100 │  │V200 │ │ │   │
│  │                     │  └─────┘  └─────┘  └─────┘ │ │   │
│  │                     └─────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  Linux Bridge VLAN 过滤 (kernel 3.x+):                      │
│    bridge vlan add dev vethA vid 100 pvid untagged          │
│    bridge vlan add dev vethB vid 100 pvid untagged          │
│    bridge vlan add dev vethC vid 200 pvid untagged          │
│                                                             │
│  这样 VM-A 和 VM-B 互通，VM-C 在另一个广播域                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VLAN 的局限

```
VLAN 只能做隔离，不能做：
  ✗ 流量过滤（谁可以访问谁）
  ✗ NAT 转换
  ✗ 负载均衡
  ✗ 流量统计/可观测性
  ✗ L7 层控制

这些需要配合 iptables 或 eBPF 实现。
```

---

## 3. iptables：Linux 流量过滤的瑞士军刀

### 3.1 iptables 核心机制

```
已在前文 "02-linux-networking/README.md" 中详细讲解，这里重点对比。

iptables 在 K8s/Harvester 中的典型应用:

┌─────────────────────────────────────────────────────────────┐
│              kube-proxy iptables 模式数据流                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Pod A (10.244.1.5) 访问 Service (10.96.0.1:80)            │
│       │                                                     │
│       ▼                                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  OUTPUT 链                                          │   │
│  │    ↓                                                │   │
│  │  KUBE-SERVICES 链                                   │   │
│  │    ↓ 匹配 10.96.0.1:80                              │   │
│  │  KUBE-SVC-XXX 链                                    │   │
│  │    ↓ 概率选择后端                                    │   │
│  │  KUBE-SEP-XXX 链                                    │   │
│  │    ↓ DNAT 到 10.244.2.3:8080                        │   │
│  │  POSTROUTING 链                                     │   │
│  │    ↓ MASQUERADE (如需)                              │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                     │
│       ▼                                                     │
│  Pod B (10.244.2.3:8080)                                   │
│                                                             │
│  规则数量: O(n) — 每个 Service 新增多条规则                  │
│  性能: 规则越多，遍历时间越长                                 │
│  连接跟踪: 依赖 conntrack 表                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘

iptables 在 Harvester masquerade 中的应用:

  VM (10.0.2.2) 出网访问
    │
    ▼
  tap0 → bridge → iptables MASQUERADE
    │
    ▼
  Pod IP (10.244.1.5) → 物理网卡

  iptables 规则:
    -A KUBEVIRT_POSTINBOUND ! -s 10.0.2.2/32 -d 10.244.1.5/32 -j SNAT --to-source 10.0.2.2
    -A KUBEVIRT_PREINBOUND -d 10.244.1.5/32 -j DNAT --to-destination 10.0.2.2
```

### 3.2 iptables 的性能瓶颈

```bash
# 查看当前规则数量
iptables -t nat -L -n | wc -l
iptables -t filter -L -n | wc -l

# 大规模集群的问题:
# 1. 规则数量爆炸
#    - 1000 个 Service × 每个 3-5 条规则 = 3000-5000 条
#    - 每增加一个连接，遍历所有规则
#
# 2. conntrack 表瓶颈
#    - 默认 65536 条目
#    - 大量短连接场景容易满
#
# 3. 更新延迟
#    - 规则更新需要持有 xtables lock
#    - 大规模更新会导致短暂中断

# 性能对比（Cilium 官方数据）:
# iptables 模式: 1000 Service 时，新连接延迟 ~5ms
# ipvs 模式:     1000 Service 时，新连接延迟 ~0.5ms
# eBPF 模式:     1000 Service 时，新连接延迟 ~0.01ms
```

---

## 4. eBPF：内核可编程的革命

### 4.1 eBPF 如何替代 iptables

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  eBPF vs iptables 架构对比                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  iptables 方式:                                                              │
│                                                                             │
│  数据包 → 内核网络栈 → netfilter 钩子 → 遍历规则链 → 决策                    │
│              ↑                                                              │
│         每次都要走完整流程                                                   │
│                                                                             │
│  eBPF 方式 (Cilium):                                                        │
│                                                                             │
│  数据包 → XDP/TC eBPF 程序 → 直接决策 → 转发/丢弃/重定向                     │
│              ↑                                                              │
│         在最早处理点决策，绕过大部分网络栈                                     │
│                                                                             │
│  关键差异:                                                                   │
│  • iptables: 规则存储在内存链表中，线性遍历                                   │
│  • eBPF: 逻辑编译为 BPF 字节码，JIT 为机器码，直接执行                       │
│  • eBPF: 状态存储在 BPF map（哈希表），O(1) 查找                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 eBPF 在 Cilium 中的网络处理

```
数据包进入 Cilium eBPF 后的处理路径:

┌─────────────────────────────────────────────────────────────┐
│                    入站流量 (Ingress)                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  物理网卡                                                    │
│     │                                                       │
│     ▼                                                       │
│  ┌─────────────┐  ← 最早处理点                               │
│  │ XDP (可选)  │  DDoS 防护、快速丢弃                         │
│  └──────┬──────┘                                            │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────┐                                            │
│  │ TC Ingress  │  ← 主要处理点                               │
│  │  eBPF 程序   │                                            │
│  │             │                                            │
│  │  1. 解析 L2/L3/L4 头                                     │
│  │  2. 查找 ipcache (IP → Identity)                         │
│  │  3. 检查 policy map (允许/拒绝)                           │
│  │  4. 更新 ct map (连接跟踪)                                │
│  │  5. 执行 LB (负载均衡)                                    │
│  │  6. 直接转发到目标 Pod 的 veth                            │
│  └──────┬──────┘                                            │
│         │                                                   │
│         ▼                                                   │
│  目标 Pod veth → Pod 网络命名空间                            │
│                                                             │
│  对比 iptables:                                              │
│  • iptables 需要经过 PREROUTING → FORWARD → POSTROUTING     │
│  • eBPF 在 TC Ingress 直接完成所有决策和转发                  │
│  • 无需 conntrack，eBPF 自己维护连接状态                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    同节点 Pod 间通信优化                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  传统方式:                                                   │
│  Pod A → vethA → bridge → vethB → Pod B                    │
│  (需要经过网桥转发，上下文切换)                               │
│                                                             │
│  Cilium sockops/skb redirect:                                │
│  Pod A → eBPF sockops → 直接写入 Pod B socket               │
│  (绕过 TCP/IP 栈，零拷贝)                                    │
│                                                             │
│  性能提升: 延迟降低 2-3 倍，吞吐量提升 30%+                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 eBPF 实现负载均衡（替代 kube-proxy）

```
Cilium eBPF 负载均衡:

Service IP: 10.96.0.1:443
       │
       ▼
┌─────────────────────────────────────┐
│  eBPF LB 查找                        │
│  • 查 cilium_lb4_services_v2 map    │
│  • 查 cilium_lb4_backends_v2 map    │
│  • 一致性哈希选择后端                │
│  • 直接 DNAT 到 Pod IP              │
└─────────────────────────────────────┘
       │
       ▼
Pod IP: 10.244.2.3:6443

优势:
  • O(1) 查找，与后端数量无关
  • 无需 conntrack 做 NAT
  • 支持 DSR (Direct Server Return)
  • 支持 Maglev 一致性哈希
```

---

## 5. 三种技术的协作与选择

### 5.1 在 Harvester 中的协作

```
Harvester 网络 = VLAN (隔离) + iptables/eBPF (控制)

场景 1: Harvester + Flannel (传统)
  VM Network (VLAN) ──► Linux Bridge ──► veth ──► VM
                                      │
                                      └──► iptables (kube-proxy)
                                      └──► iptables (masquerade NAT)

场景 2: Harvester + Cilium (现代)
  VM Network (VLAN) ──► Linux Bridge ──► veth ──► VM
                                      │
                                      └──► eBPF (CNI)
                                      └──► eBPF (负载均衡)
                                      └──► eBPF (网络策略)
                                      └──► eBPF (可观测性)
```

### 5.2 选择决策树

```
需要网络隔离？
  ├─ 是 → 使用 VLAN (L2)
  └─ 否 → 使用 flat 网络

需要流量过滤/策略？
  ├─ 简单 L3/L4 → iptables (Calico) 或 eBPF (Cilium)
  ├─ 复杂 L7 → eBPF (Cilium) + Envoy
  └─ 不需要 → 无策略

需要高性能？
  ├─ 极致性能 → eBPF/XDP
  ├─ 高并发 → eBPF / ipvs
  └─ 一般 → iptables

需要可观测性？
  ├─ 深度可见 → eBPF (Hubble)
  └─ 基础 → node_exporter + tcpdump
```

---

## 6. 实战：从 iptables 迁移到 eBPF

```bash
# 当前使用 kube-proxy iptables 模式
kubectl get cm kube-proxy -n kube-system -o yaml | grep mode
# mode: "iptables"

# 切换到 ipvs 模式（中间步骤）
kubectl edit cm kube-proxy -n kube-system
# 设置 mode: "ipvs"
kubectl rollout restart ds kube-proxy -n kube-system

# 验证
kubectl logs -n kube-system <kube-proxy-pod> | grep "Using ipvs"
ipvsadm -Ln

# 最终迁移到 Cilium eBPF（替换 kube-proxy）
helm upgrade cilium cilium/cilium --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=auto \
  --set k8sServicePort=6443

# 验证 kube-proxy 已不需要
kubectl get pods -n kube-system -l k8s-app=kube-proxy
# 可以删除 kube-proxy DaemonSet

# 验证 eBPF 负载均衡
cilium bpf lb list
cilium bpf ct list global
```

---

## 7. 性能对比数据

| 指标 | VLAN | iptables | ipvs | eBPF (Cilium) |
|------|------|----------|------|---------------|
| 新连接延迟 | <1μs | ~5ms (1000 svc) | ~0.5ms | ~0.01ms |
| 规则查找 | N/A | O(n) | O(1) | O(1) |
| 最大连接数 | N/A | 受 conntrack 限制 | 百万级 | 百万级 |
| 内存/连接 | N/A | ~200 bytes | ~100 bytes | ~50 bytes |
| 策略粒度 | L2 | L3/L4 | L3/L4 | L3-L7 |
| CPU 占用 | 低 | 中高 | 中 | 低 |

---

## 参考资源

- [Cilium BPF & XDP Reference Guide](https://docs.cilium.io/en/stable/bpf/)
- [Linux Bridge VLAN Filtering](https://wiki.linuxfoundation.org/networking/bridge)
- [iptables Performance](https://thermalcircle.de/doku.php?id=blog:linux:netfilter_ipvs_iptables_comparison)
- [eBPF.io](https://ebpf.io/)

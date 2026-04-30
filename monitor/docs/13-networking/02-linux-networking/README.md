# Linux 网络栈深度解析

> 深入理解 Linux 内核网络处理流程、netfilter 框架、网络命名空间，这是掌握容器网络和 K8s 网络的基石。

---

## 1. Linux 网络数据包处理流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                         用户空间 (User Space)                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │   App A     │  │   App B     │  │  Socket API │                 │
│  │  (Nginx)    │  │  (MySQL)    │  │  send/recv  │                 │
│  └──────┬──────┘  └──────┬──────┘  └─────────────┘                 │
│         │                │                                          │
│  ┌──────▼────────────────▼──────────────────────────────────────┐  │
│  │              Socket Layer (套接字层)                           │  │
│  │  - TCP/UDP 协议栈 (三次握手、滑动窗口、拥塞控制)                │  │
│  │  - Socket Buffer (sk_buff)                                   │  │
│  └─────────────────────┬──────────────────────────────────────────┘  │
└────────────────────────┼────────────────────────────────────────────┘
                         │ 系统调用边界
┌────────────────────────┼────────────────────────────────────────────┐
│                        ▼ 内核空间 (Kernel Space)                     │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │              Transport Layer (TCP/UDP)                         │ │
│  │  - 分段/重组、校验和、序列号管理、ACK处理                       │ │
│  └────────────────────────┬───────────────────────────────────────┘ │
│                           │                                         │
│  ┌────────────────────────▼───────────────────────────────────────┐ │
│  │              Network Layer (IP)                                │ │
│  │  - 路由查找 (FIB)、TTL处理、分片/重组                           │ │
│  └────────────────────────┬───────────────────────────────────────┘ │
│                           │                                         │
│  ┌────────────────────────▼───────────────────────────────────────┐ │
│  │              Netfilter (钩子点: PREROUTING/POSTROUTING等)       │ │
│  │  - iptables/nftables 规则处理                                   │ │
│  └────────────────────────┬───────────────────────────────────────┘ │
│                           │                                         │
│  ┌────────────────────────▼───────────────────────────────────────┐ │
│  │              Link Layer (以太网驱动)                             │ │
│  │  - ARP、MAC地址、网卡驱动 (eth0)                                │ │
│  └────────────────────────┬───────────────────────────────────────┘ │
│                           │                                         │
│  ┌────────────────────────▼───────────────────────────────────────┐ │
│  │              NIC (网卡硬件)                                      │ │
│  │  - DMA、Ring Buffer、硬件卸载 (TSO/GSO)                         │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 sk_buff（Socket Buffer）

`sk_buff` 是 Linux 内核中网络数据包的核心结构体：

```c
struct sk_buff {
    struct sk_buff      *next;          // 链表指针
    struct sk_buff      *prev;
    
    struct sock         *sk;            // 关联的 socket
    struct net_device   *dev;           // 关联的网络设备
    
    unsigned int        len;            // 数据总长度
    unsigned int        data_len;       // 分片数据长度
    __u16               mac_len;        // MAC 头长度
    __u16               hdr_len;        // 可写头部长度
    
    __u32               priority;       // QoS 优先级
    __be16              protocol;       // 三层协议类型
    
    unsigned char       *head;          // 缓冲区起始
    unsigned char       *data;          // 数据起始（可移动）
    unsigned char       *tail;          // 数据结束
    unsigned char       *end;           // 缓冲区结束
    
    // 各层协议头指针
    union {
        struct tcphdr   *th;            // TCP 头
        struct udphdr   *uh;            // UDP 头
        struct icmphdr  *icmph;         // ICMP 头
        struct iphdr    *iph;           // IP 头
        struct ipv6hdr  *ipv6h;         // IPv6 头
        struct ethhdr   *ethh;          // 以太网头
    };
};
```

**关键理解**：`sk_buff` 通过移动 `data` 指针来添加/剥离各层协议头，避免了数据复制。

---

## 2. Netfilter 框架

### 2.1 Netfilter 钩子点

```
入站数据包 (Ingress):

   网络接口
      │
      ▼
┌─────────────┐
│  PREROUTING │  ← DNAT、端口映射 (kube-proxy NodePort)
│  (路由前)    │
└──────┬──────┘
       │
   路由决策: 本机 or 转发?
       │
   ┌───┴───┐
   ▼       ▼
本机    转发
│       │
▼       ▼
┌─────────┐   ┌─────────────┐
│  INPUT  │   │   FORWARD   │  ← 防火墙规则、NetworkPolicy
│ (到本地) │   │  (包转发)    │
└────┬────┘   └──────┬──────┘
     │               │
     ▼               ▼
  应用进程        ┌─────────────┐
                  │ POSTROUTING │  ← SNAT/Masquerade、Mangle
                  │  (路由后)    │
                  └──────┬──────┘
                         │
                         ▼
                      网络接口

出站数据包 (Egress):

  应用进程
      │
      ▼
┌─────────────┐
│   OUTPUT    │  ← 本地生成的包的处理
│  (路由前)    │
└──────┬──────┘
       │
   路由决策
       │
       ▼
┌─────────────┐
│ POSTROUTING │  ← SNAT
│  (路由后)    │
└──────┬──────┘
       │
       ▼
   网络接口
```

### 2.2 iptables 四表五链

```
四表（按优先级排序）：

1. raw表      → 连接跟踪豁免 (PREROUTING, OUTPUT)
2. mangle表   → 修改 TTL/TOS 等 (所有链)
3. nat表      → 地址转换 (PREROUTING, POSTROUTING, OUTPUT)
4. filter表   → 过滤 (INPUT, FORWARD, OUTPUT)

五链：
  PREROUTING  → 数据包进入路由决策前
  INPUT       → 路由到本机的数据包
  FORWARD     → 需要转发的数据包
  OUTPUT      → 本机进程发出的数据包
  POSTROUTING → 路由决策后，即将离开
```

### 2.3 查看 iptables 规则

```bash
# 查看所有规则
iptables -L -n -v --line-numbers

# 查看 nat 表
iptables -t nat -L -n -v

# 查看自定义链
iptables -L KUBE-SERVICES -t nat -n -v

# 查看连接跟踪
conntrack -L
conntrack -L -p tcp --state ESTABLISHED

# K8s 中 kube-proxy 生成的规则
iptables -t nat -L KUBE-SERVICES -n | head -20
iptables -t nat -L KUBE-POSTROUTING -n
```

### 2.4 K8s 中 iptables 的作用

```bash
# kube-proxy iptables 模式下的规则链

# 1. 访问 ClusterIP (10.96.0.1:443)
# PREROUTING/OUTPUT → KUBE-SERVICES → KUBE-SVC-XXX → KUBE-SEP-XXX → DNAT 到 Pod IP

iptables -t nat -L KUBE-SERVICES -n | grep kubernetes
# KUBE-SVC-NPX46M4PTMTKRN6Y  tcp  --  0.0.0.0/0  10.96.0.1  tcp dpt:443

iptables -t nat -L KUBE-SVC-NPX46M4PTMTKRN6Y -n
# KUBE-SEP-XXX  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.333

# 2. NodePort (30080 -> 80)
# KUBE-NODEPORTS → KUBE-SVC-XXX → KUBE-SEP-XXX

# 3. Pod 出网 SNAT
# POSTROUTING → KUBE-POSTROUTING → MASQUERADE
iptables -t nat -L KUBE-POSTROUTING -n
# MASQUERADE  all  --  10.244.0.0/16  !10.244.0.0/16
```

---

## 3. 网络命名空间（Network Namespace）

### 3.1 什么是网络命名空间

```
网络命名空间：独立的网络视图

┌─────────────────────────────────────────────────────────────┐
│                      Host Network                            │
│  eth0: 192.168.1.10                                         │
│  lo: 127.0.0.1                                              │
│  route table, iptables rules                                │
└─────────────────────────────────────────────────────────────┘
       │
       │ clone(CLONE_NEWNET)
       ▼
┌─────────────────────────────────────────────────────────────┐
│                    Pod Network Namespace                     │
│  eth0: 10.244.1.5 (veth pair 的一端)                        │
│  lo: 127.0.0.1                                              │
│  独立的 route table, iptables rules                         │
│                                                              │
│  Pod 内只能看到自己的网络设备，无法直接看到宿主机的 eth0       │
└─────────────────────────────────────────────────────────────┘

每个 Pod 有独立的：
  - 网络接口（veth）
  - 路由表
  - iptables 规则
  - socket
  - /proc/net
```

### 3.2 操作网络命名空间

```bash
# 查看所有网络命名空间
ls /var/run/netns/  # ip netns 管理的
lsns -t net         # 所有进程的网络命名空间

# 进入容器的网络命名空间
# 方式 1: 通过容器 PID
PID=$(docker inspect -f '{{.State.Pid}}' <container>)
sudo nsenter -t $PID -n ip addr

# 方式 2: 通过 crictl（K8s）
PID=$(crictl inspect <container-id> | jq .info.pid)
sudo nsenter -t $PID -n

# 方式 3: 通过 ip netns（需要先创建符号链接）
mkdir -p /var/run/netns
ln -sf /proc/$PID/ns/net /var/run/netns/pod-net
ip netns exec pod-net ip addr
ip netns exec pod-net iptables -L -n -v

# 在 Pod 网络命名空间中抓包
nsenter -t $PID -n tcpdump -i any -w /tmp/pod.pcap

# 在 Pod 网络命名空间中查看路由
nsenter -t $PID -n ip route
nsenter -t $PID -n ss -tan
```

### 3.3 veth pair（虚拟以太网对）

```
veth pair 是成对出现的虚拟网卡，数据从一端进入，从另一端出来。

┌─────────────────────────────────────────────────────────────┐
│                    Host Network Namespace                    │
│                                                              │
│  ┌─────────────┐         ┌─────────────┐                   │
│  │   vethxxx   │◄───────►│   cni0      │  (网桥)           │
│  │  (host端)   │  veth   │  10.244.1.1 │                   │
│  └──────┬──────┘  pair   └──────┬──────┘                   │
│         │                        │                          │
│         │    ┌───────────────────┘                          │
│         │    │                   ┌─────────────┐            │
│         │    └──────────────────►│   vethyyy   │            │
│         │                        │  (host端)   │            │
│         │                        └─────────────┘            │
│         │                                                   │
└─────────┼───────────────────────────────────────────────────┘
          │
          │ (veth pair 连接两个命名空间)
          │
┌─────────┼───────────────────────────────────────────────────┐
│         │         Pod Network Namespace                      │
│         │                                                    │
│  ┌──────▼──────┐                                            │
│  │   eth0      │  IP: 10.244.1.5/24                         │
│  │  (Pod端)    │  GW: 10.244.1.1 (cni0)                     │
│  └─────────────┘                                            │
│                                                              │
└─────────────────────────────────────────────────────────────┘

创建 veth pair 的命令：
  ip link add veth-host type veth peer name veth-pod
  ip link set veth-pod netns <pod-netns>
```

---

## 4. 网桥（Linux Bridge）

```
网桥工作在数据链路层，连接多个网段，类似物理交换机。

K8s 中的网桥（以 Flannel 为例）：

┌─────────────────────────────────────────────────────────────┐
│                          Host                                │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                      cni0 (网桥)                       │   │
│  │                   10.244.1.1/24                       │   │
│  │                                                       │   │
│  │   ┌───────┐  ┌───────┐  ┌───────┐  ┌───────┐       │   │
│  │   │veth1  │  │veth2  │  │veth3  │  │veth4  │       │   │
│  │   └───┬───┘  └───┬───┘  └───┬───┘  └───┬───┘       │   │
│  │       │          │          │          │            │   │
│  └───────┼──────────┼──────────┼──────────┼────────────┘   │
│          │          │          │          │                 │
│  ┌───────┼──────────┼──────────┼──────────┼────────────┐   │
│  │   ┌───▼───┐ ┌───▼───┐ ┌───▼───┐ ┌───▼───┐         │   │
│  │   │ Pod 1 │ │ Pod 2 │ │ Pod 3 │ │ Pod 4 │         │   │
│  │   │.1.5   │ │.1.6   │ │.1.7   │ │.1.8   │         │   │
│  │   └───────┘ └───────┘ └───────┘ └───────┘         │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  同一网桥上的 Pod 直接二层通信，不需要经过路由。              │
└─────────────────────────────────────────────────────────────┘

查看网桥：
  brctl show              # 查看网桥和连接的 veth
  bridge link show        # 更详细的网桥信息
  ip link show type bridge
```

---

## 5. 路由表与策略路由

### 5.1 查看路由表

```bash
# 主路由表
ip route show
ip route show table main

# 所有路由表
ip route show table all

# K8s 中 Pod 的路由
ip route get 10.244.1.5  # 查看到 Pod IP 的路径

# 策略路由
ip rule show
ip route show table local
```

### 5.2 K8s 中的路由

```
Pod 访问 Service IP 的路由过程：

Pod (10.244.1.5) 访问 Service (10.96.0.1:443)
  │
  ▼
Pod 路由表: default via 10.244.1.1 dev eth0
  │
  ▼
veth pair → cni0 (网桥)
  │
  ▼
宿主机路由表: 10.96.0.0/12 dev eth0  (或 kube-proxy 创建的规则)
  │
  ▼
PREROUTING → KUBE-SERVICES (iptables DNAT)
  10.96.0.1:443 → 10.244.2.3:6443
  │
  ▼
路由到目标 Pod (10.244.2.3)
  │
  ▼
通过 flannel/calico 隧道到达目标节点
```

---

## 6. conntrack（连接跟踪）

```bash
# 连接跟踪是 NAT 和状态防火墙的基础
# 查看连接跟踪表
conntrack -L | head -20
conntrack -L -p tcp --state ESTABLISHED

# 统计连接数
conntrack -C

# 查看特定连接
conntrack -L -s 10.244.1.5 -d 10.96.0.1

# K8s 中常见的 conntrack 问题
# 1. conntrack 表满（nf_conntrack: table full）
# 解决：增大 hashsize
sysctl -w net.netfilter.nf_conntrack_max=1048576
sysctl -w net.netfilter.nf_conntrack_buckets=262144

# 2. NAT 端口耗尽
# 解决：缩短超时时间
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=86400
```

---

## 7. 内核网络参数调优

```bash
# /etc/sysctl.conf 或 /etc/sysctl.d/99-k8s-network.conf

# 1. TCP 连接优化
net.core.somaxconn = 32768           # 监听队列长度
net.core.netdev_max_backlog = 65536  # 网卡队列长度
net.ipv4.tcp_max_syn_backlog = 65536 # SYN 队列长度

# 2. TCP 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 3. 端口范围
net.ipv4.ip_local_port_range = 1024 65535

# 4. TIME_WAIT 优化
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 5. 连接跟踪
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_buckets = 262144

# 6. 反向路径过滤（K8s 需要关闭）
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# 应用
sysctl -p
```

---

## 参考资源

- [Linux Kernel Networking](https://www.kernel.org/doc/Documentation/networking/)
- [Illustrated Guide to Monitoring and Tuning the Linux Networking Stack](https://www.datadoghq.com/blog/network-performance-monitoring/)
- [iptables Tutorial](https://iptables-tutorial.frozentux.net/)

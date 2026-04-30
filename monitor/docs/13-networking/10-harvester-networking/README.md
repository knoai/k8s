# Harvester 网络深入：Access 模式与 Trunk 模式

> Harvester 是 Rancher 开源的 HCI（超融合基础设施）平台，基于 K8s + KubeVirt 实现虚拟机管理。理解其网络模型中的 **Access 模式** 和 **Trunk 模式**，是正确使用 Harvester 虚拟网络的关键。

---

## 1. Harvester 网络架构全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Harvester 网络分层架构                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  外部网络 (物理交换机)                                                        │
│       │                                                                     │
│       │  网线连接                                                            │
│       ▼                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Harvester 节点 (Host)                             │   │
│  │                                                                      │   │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐  │   │
│  │  │ 物理网卡 eth0    │    │ 物理网卡 eth1    │    │  Bond 接口       │  │   │
│  │  │ (管理网络)       │    │ (VLAN 网络)      │    │  (LACP/轮询)     │  │   │
│  │  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘  │   │
│  │           │                      │                      │            │   │
│  │           ▼                      ▼                      ▼            │   │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐  │   │
│  │  │ mgmt-br (网桥)   │    │ cn-data-br (网桥)│    │ oob-br (网桥)    │  │   │
│  │  │ Canal/Calico    │    │ VLAN 流量        │    │ Untagged        │  │   │
│  │  │ Overlay 网络     │    │ 桥接转发         │    │ 直通流量         │  │   │
│  │  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘  │   │
│  │           │                      │                      │            │   │
│  │           ▼                      ▼                      ▼            │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │   │
│  │  │              VM Pod (KubeVirt virt-launcher)                     │  │   │
│  │  │                                                                  │  │   │
│  │  │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐       │  │   │
│  │  │   │  eth0 (tap) │    │  eth1 (tap) │    │  eth2 (tap) │       │  │   │
│  │  │   │ masquerade  │    │   bridge    │    │   bridge    │       │  │   │
│  │  │   │  10.0.2.2   │    │  192.168.x  │    │  10.100.x   │       │  │   │
│  │  │   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘       │  │   │
│  │  │          │                  │                  │               │  │   │
│  │  │   ┌──────▼──────────────────▼──────────────────▼──────┐        │  │   │
│  │  │   │              VM (Guest OS)                        │        │  │   │
│  │  │   │  ┌─────────────────────────────────────────────┐  │        │  │   │
│  │  │   │  │  管理网络: 集群内通信 + NAT 出网              │  │        │  │   │
│  │  │   │  │  VLAN 网络: 直连物理网络 + 外部可达           │  │        │  │   │
│  │  │   │  │  Trunk 网络: 单网卡多 VLAN (v1.7+)          │  │        │  │   │
│  │  │   │  └─────────────────────────────────────────────┘  │        │  │   │
│  │  │   └───────────────────────────────────────────────────┘        │  │   │
│  │  └─────────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

三层网络概念：
  1. Cluster Network (集群网络): 定义物理网卡/NIC 的集合
  2. VM Network (虚拟机网络): 基于 Cluster Network 创建的逻辑网络
  3. VM Interface (虚拟机网卡): VM 内看到的网络接口
```

---

## 2. VM Network 的两种模式：Access vs Trunk

在 Harvester 中创建 VM Network（Networks → VM Networks → Create）时，Type 选择 **L2VlanNetwork** 后，需要选择 **Mode**。这就是 Access 和 Trunk 两种模式。

### 2.1 Access 模式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Access 模式（接入模式）                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  定义: VM 网卡只属于一个 VLAN，所有进出流量都自动带/剥同一个 VLAN tag         │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    创建 VM Network (Access)                          │   │
│  │                                                                      │   │
│  │  Type:  L2VlanNetwork                                               │   │
│  │  Mode:  Access          ← 选择 Access                                │   │
│  │  Vlan ID: 100           ← 指定一个 VLAN ID                           │   │
│  │  Cluster Network: cn-data                                            │   │
│  │                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  数据流示意:                                                                 │
│                                                                             │
│  VM 内部 (Guest OS)           Harvester 宿主机            外部交换机        │
│       │                            │                        │              │
│       │  原始以太网帧                 │                        │              │
│       │  (无 VLAN tag)                │                        │              │
│       │                            │                        │              │
│       ▼                            ▼                        ▼              │
│  ┌─────────┐                  ┌─────────┐              ┌─────────┐        │
│  │  eth1   │ ── tap/veth ──► │ bridge  │ ── 加 tag ──►│ Switch  │        │
│  │  .50    │                  │cn-data-br│   VLAN 100   │ Port    │        │
│  └─────────┘                  └─────────┘              └─────────┘        │
│                                                                             │
│  关键行为:                                                                   │
│  • VM 内部完全感知不到 VLAN 的存在                                          │
│  • Harvester 网桥自动为出站包加 VLAN 100 tag                                │
│  • Harvester 网桥自动为入站包剥 VLAN 100 tag                                │
│  • 类似于物理交换机的 Access 端口                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

适用场景:
  ✓ 单个 VM 只需要接入一个 VLAN
  ✓ VM 内部不需要处理 VLAN tag（简单）
  ✓ 大多数业务虚拟机
  ✓ 每个 VLAN 创建一个 VM Network

交换机端口配置:
  interface GigabitEthernet0/1
    switchport mode access
    switchport access vlan 100
```

### 2.2 Trunk 模式（v1.7.0+）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Trunk 模式（中继模式）                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  定义: VM 网卡可以承载多个 VLAN，VM 内部可以发送/接收带不同 VLAN tag 的流量   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    创建 VM Network (Trunk)                           │   │
│  │                                                                      │   │
│  │  Type:  L2VlanNetwork                                               │   │
│  │  Mode:  Trunk           ← 选择 Trunk (v1.7.0+)                       │   │
│  │  Min VLAN ID: 100       ← VLAN 范围起始                              │   │
│  │  Max VLAN ID: 200       ← VLAN 范围结束                              │   │
│  │  Cluster Network: cn-data                                            │   │
│  │                                                                      │   │
│  │  可以指定多个、重叠的 VLAN ID 范围                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  数据流示意:                                                                 │
│                                                                             │
│  VM 内部 (Guest OS)           Harvester 宿主机            外部交换机        │
│       │                            │                        │              │
│       │  带 VLAN tag 的帧           │                        │              │
│       │  (VM 自己管理 VLAN)          │                        │              │
│       │                            │                        │              │
│       ▼                            ▼                        ▼              │
│  ┌─────────┐                  ┌─────────┐              ┌─────────┐        │
│  │  eth1   │ ── tap/veth ──► │ bridge  │ ── 透传 ────►│ Switch  │        │
│  │  .50    │   VLAN 150      │cn-data-br│   VLAN 150   │ Trunk   │        │
│  │  .60    │   VLAN 160      │          │   VLAN 160   │ Port    │        │
│  └─────────┘                  └─────────┘              └─────────┘        │
│                                                                             │
│  关键行为:                                                                   │
│  • VM 内部需要配置 VLAN 子接口（如 eth1.150, eth1.160）                      │
│  • Harvester 网桥透传所有指定范围内的 VLAN tag                                │
│  • VM 操作系统必须支持 802.1Q VLAN                                           │
│  • 类似于物理交换机的 Trunk 端口                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

适用场景:
  ✓ 一个 VM 需要同时接入多个 VLAN（如防火墙、路由器 VM）
  ✓ 网络功能虚拟化 (NFV) 场景
  ✓ 需要减少 VM 网卡数量，用一个网卡处理多 VLAN
  ✓ 容器网络（在 VM 内运行 K8s，需要多 CNI 网络）

交换机端口配置:
  interface GigabitEthernet0/1
    switchport mode trunk
    switchport trunk allowed vlan 100-200

VM 内部配置 (Linux):
  # 创建 VLAN 子接口
  ip link add link eth1 name eth1.150 type vlan id 150
  ip addr add 192.168.150.10/24 dev eth1.150
  ip link set eth1.150 up

  ip link add link eth1 name eth1.160 type vlan id 160
  ip addr add 192.168.160.10/24 dev eth1.160
  ip link set eth1.160 up
```

### 2.3 Access vs Trunk 对比

| 对比项 | Access 模式 | Trunk 模式 |
|--------|-------------|-----------|
| **VLAN 数量** | 单个 VLAN | 多个 VLAN（范围） |
| **VM 内 VLAN 感知** | 无感知，透明 | 需要配置 VLAN 子接口 |
| **VM OS 要求** | 任何 OS | 必须支持 802.1Q |
| **网卡数量** | 每 VLAN 一个网卡 | 一个网卡处理多 VLAN |
| **典型用例** | 普通业务 VM | 路由器/防火墙/NFV VM |
| **交换机端口** | access | trunk |
| **Harvester 版本** | 全版本 | v1.7.0+ |
| **创建字段** | Vlan ID | Min/Max VLAN ID |

---

## 3. VM 网卡类型：bridge vs masquerade

除了 VM Network 的模式，在创建 VM 时配置网卡还有一个重要的 **Type** 字段：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     VM 网卡类型对比                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  bridge 类型（桥接模式）                                                     │
│  ───────────────────────                                                     │
│                                                                             │
│  原理: VM 直接接入 Linux bridge，二层透传                                     │
│                                                                             │
│  VM ──► tap 设备 ──► bridge ──► veth pair ──► 宿主机网络栈 ──► 物理网卡       │
│                                                                             │
│  特点:                                                                       │
│  • VM 获得真实的网络身份（MAC 地址在物理网络中可见）                           │
│  • VM IP 由外部 DHCP/静态分配（不是集群内部 IP）                              │
│  • 外部网络可以直接访问 VM IP（只要路由可达）                                  │
│  • 适用于 VLAN Network 和 Untagged Network                                   │
│                                                                             │
│  限制:                                                                       │
│  ✗ 不支持 Live Migration（热迁移）— KubeVirt 限制                             │
│  ✗ Pod 没有 IP，某些 CNI/安全工具可能不兼容                                   │
│  ✗ MAC 地址需要物理网络支持                                                   │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  masquerade 类型（伪装/NAT 模式）                                            │
│  ───────────────────────────────                                             │
│                                                                             │
│  原理: 使用 iptables NAT 将 VM 流量伪装成 Pod IP 转发                         │
│                                                                             │
│  VM ──► tap 设备 ──► iptables DNAT/SNAT ──► Pod eth0 ──► K8s CNI 网络       │
│                                                                             │
│  特点:                                                                       │
│  • VM 内部使用固定的私有 IP（默认 10.0.2.2/24）                               │
│  • 出站流量通过 NAT 转换，使用 Pod IP 作为源地址                               │
│  • 入站流量通过 iptables DNAT 映射到 VM                                       │
│                                                                             │
│       入站 iptables 规则:                                                    │
│       iptables -t nat -A PREROUTING -j DNAT --to-destination 10.0.2.2        │
│                                                                             │
│  特点:                                                                       │
│  • 支持 Live Migration（热迁移）                                              │
│  • 与 K8s 网络完全兼容                                                        │
│  • 默认用于 Management Network                                                │
│  • 外部访问 VM 需要通过 NodePort/LoadBalancer/Service                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 选择矩阵

| 场景 | 网卡 Type | VM Network | 说明 |
|------|-----------|------------|------|
| VM 只需集群内通信 | masquerade | Management Network | 默认配置，简单 |
| VM 需要外部直接访问 | bridge | VLAN (Access) | VM 有真实 IP |
| VM 需要多个 VLAN | bridge | VLAN (Trunk) | 单网卡多 VLAN |
| VM 需要热迁移 | masquerade | Management Network | bridge 不支持迁移 |
| 防火墙/NFV VM | bridge | VLAN (Trunk) | 处理多 VLAN 流量 |

---

## 4. 物理交换机配合配置

### 4.1 Access 模式场景

```
Harvester 节点                      物理交换机
┌─────────────┐                    ┌─────────────┐
│   eth1      │◄──────────────────►│  Gi0/1      │
│  (VLAN 100) │                    │  Access     │
└─────────────┘                    └─────────────┘
                                        │
                                   switchport mode access
                                   switchport access vlan 100

注意: Harvester v1.6.1+ 行为变化
  • v1.6.1 之前: veth 接口同时关联 VLAN 1 + VLAN 100
  • v1.6.1 之后: veth 接口只关联配置的 VLAN ID
  • 交换机端口必须严格配置为 access 或 trunk（不能依赖 PVID 1）
```

### 4.2 Trunk 模式场景

```
Harvester 节点                      物理交换机
┌─────────────┐                    ┌─────────────┐
│   eth1      │◄──────────────────►│  Gi0/1      │
│ (VLAN       │                    │  Trunk      │
│  100-200)   │                    │             │
└─────────────┘                    └─────────────┘
                                        │
                                   switchport mode trunk
                                   switchport trunk allowed vlan 100-200

关键: Trunk 模式下，VM 内部的 VLAN tag 会被原样透传到交换机
```

---

## 5. 实战：创建不同模式的网络

### 5.1 创建 Access 模式 VM Network

```yaml
# UI 操作: Networks → VM Networks → Create
# 或 kubectl:

apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan100-access
  namespace: default
  annotations:
    network.harvesterhci.io/route: '{"mode":"auto","serverIPAddr":"","cidr":"","gateway":""}'
  labels:
    network.harvesterhci.io/clusternetwork: cn-data
    network.harvesterhci.io/type: L2VlanNetwork
    network.harvesterhci.io/vlan-id: "100"
spec:
  config: >-
    {"cniVersion":"0.3.1","name":"vlan100-access","type":"bridge",
     "bridge":"cn-data-br","promiscMode":true,"vlan":100,"ipam":{}}
```

### 5.2 创建 Trunk 模式 VM Network

```yaml
# v1.7.0+ 支持 Trunk 模式
# UI 操作: Networks → VM Networks → Create
#   Type: L2VlanNetwork
#   Mode: Trunk
#   Min VLAN ID: 100
#   Max VLAN ID: 200

apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan-trunk
  namespace: default
  labels:
    network.harvesterhci.io/clusternetwork: cn-data
    network.harvesterhci.io/type: L2VlanNetwork
    network.harvesterhci.io/trunk: "true"
spec:
  config: >-
    {"cniVersion":"0.3.1","name":"vlan-trunk","type":"bridge",
     "bridge":"cn-data-br","promiscMode":true,
     "vlanTrunk":[{"minID":100,"maxID":200}],"ipam":{}}
```

### 5.3 VM 配置示例

```yaml
# VM YAML 示例：Management + VLAN Access + VLAN Trunk
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: multi-network-vm
  namespace: default
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
            # 1. 管理网络 (masquerade)
            - name: mgmt
              masquerade: {}
            # 2. VLAN 100 Access (bridge)
            - name: vlan100
              bridge: {}
            # 3. VLAN Trunk (bridge) - v1.7.0+
            - name: vlan-trunk
              bridge: {}
        resources:
          requests:
            memory: 2Gi
            cpu: 2
      networks:
        - name: mgmt
          pod: {}  # Management Network
        - name: vlan100
          multus:
            networkName: default/vlan100-access
        - name: vlan-trunk
          multus:
            networkName: default/vlan-trunk
```

---

## 6. 常见问题与排障

### 6.1 VM 获取不到 IP

```bash
# 检查清单

# 1. VM Network 连通性状态
kubectl get network-attachment-definition -n default
# 查看 Network connectivity 列是否为 Active

# 2. 检查 Harvester 节点上的网桥
ssh harvester-node
ip link show
bridge link show
bridge vlan show

# 3. 检查 veth 接口 VLAN 配置
bridge vlan show dev vethxxxxx
# 期望看到: vethxxxxx  100 PVID Egress Untagged  (Access 模式)

# 4. 检查物理交换机端口配置
# 确保交换机端口允许对应 VLAN

# 5. VM 内部检查
kubectl exec -it virt-launcher-xxxxx -- bash
# 在 Pod 中检查 tap 设备
ip link show tap0

# 6. DHCP 测试
# 在 VM 内部执行
sudo dhclient -v eth1
# 或查看 /var/log/messages 中的 DHCP 日志
```

### 6.2 Trunk 模式 VM 内部无法识别 VLAN

```bash
# VM 内部需要手动配置 VLAN 子接口

# 安装 vlan 包
sudo apt-get install vlan    # Debian/Ubuntu
sudo yum install vconfig     # CentOS/RHEL (旧版)

# 加载 8021q 模块
sudo modprobe 8021q

# 创建 VLAN 子接口
sudo ip link add link eth1 name eth1.150 type vlan id 150
sudo ip addr add 192.168.150.10/24 dev eth1.150
sudo ip link set eth1.150 up

# 验证
ip link show eth1.150
cat /proc/net/vlan/config

# 持久化配置 (/etc/network/interfaces 或 Netplan)
```

### 6.3 Access vs Trunk 混淆导致的故障

| 症状 | 可能原因 | 解决 |
|------|---------|------|
| VM 无法获取 IP | 交换机端口是 access，但 VM Network 配置错误 | 检查 VLAN ID 是否匹配 |
| VM 能获取 IP 但无法出网 | 交换机 trunk 未允许对应 VLAN | 检查 `switchport trunk allowed vlan` |
| Trunk VM 只能访问一个 VLAN | VM 内部未配置 VLAN 子接口 | 在 VM 内创建 eth1.X 接口 |
| 网络间歇性中断 | Harvester v1.6.1+ 行为变化，交换机配置不匹配 | 交换机必须配置为 trunk 模式 |
| Live Migration 失败 | 使用了 bridge 类型网卡 | 改用 masquerade 类型 |

---

## 7. 快速决策流程

```
我的 VM 需要什么网络？
        │
        ▼
┌─────────────────────────┐
│ VM 只需要集群内通信？     │
└─────────────────────────┘
   │              │
   是             否
   │              │
   ▼              ▼
Management    ┌─────────────────────────┐
Network       │ VM 需要外部直接访问？    │
(masquerade)  └─────────────────────────┘
                  │              │
                  是             否
                  │              │
                  ▼              ▼
            ┌──────────┐   ┌─────────────────────────┐
            │ VLAN     │   │ VM 需要多个 VLAN？       │
            │ Network  │   └─────────────────────────┘
            │ (bridge) │      │              │
            │ Access   │      是             否
            │ 模式     │      │              │
            └──────────┘      ▼              ▼
                         VLAN Trunk      检查需求
                         (bridge)       是否合理
                         模式           

补充：
  • 需要热迁移 → 必须用 masquerade
  • 需要特定 MAC → 只能用 bridge
  • 简单外部访问 → VLAN Access
  • NFV/防火墙 → VLAN Trunk
```

---

## 参考资源

- [Harvester VM Network 官方文档](https://docs.harvesterhci.io/v1.7/networking/harvester-network)
- [Harvester Network Deep Dive](https://docs.harvesterhci.io/v1.7/networking/deep-dive)
- [KubeVirt Networking](https://kubevirt.io/user-guide/networking/)
- [Linux VLAN 配置](https://wiki.debian.org/VLAN)
- [IEEE 802.1Q 标准](https://standards.ieee.org/standard/802.1Q.html)

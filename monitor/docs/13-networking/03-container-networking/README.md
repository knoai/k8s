# 容器网络原理

> 理解容器网络是掌握 K8s 网络的前提。从 veth pair 到 CNI，从 bridge 到 overlay，深入剖析容器通信的每个环节。

---

## 1. 容器网络模式

```
Docker 网络模式对比：

┌─────────────────────────────────────────────────────────────────┐
│  bridge (默认)                                                  │
│  ─────────────────────                                           │
│  容器通过 veth pair 连接到 docker0 网桥                         │
│  容器之间可通信，与外部通信需要 NAT                             │
│                                                                 │
│  Host ◄──► docker0 (172.17.0.1)                                │
│              │                                                   │
│         ┌────┴────┐                                              │
│         ▼         ▼                                              │
│      veth0     veth1                                             │
│      eth0      eth0                                              │
│     ┌───┐     ┌───┐                                              │
│     │C1 │     │C2 │  172.17.0.2/16  172.17.0.3/16              │
│     └───┘     └───┘                                              │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  host                                                            │
│  ────                                                            │
│  容器直接使用宿主机网络栈，无隔离                                │
│  性能最好，但端口冲突风险                                        │
│                                                                 │
│     ┌───┐                                                       │
│     │ C │  eth0 = 宿主机 eth0                                    │
│     └───┘  直接使用宿主机 IP                                     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  none                                                            │
│  ────                                                            │
│  容器只有 lo 接口，完全隔离                                      │
│  用于多容器 Pod 中不需要网络的 sidecar                           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  container                                                       │
│  ─────────                                                       │
│  容器共享另一个容器的网络命名空间                                │
│  K8s Pod 就是这种模式：所有容器共享 pause 容器的网络             │
│                                                                 │
│     ┌─────────┐                                                 │
│     │ pause   │  ← 网络命名空间持有者                            │
│     │ (infra) │                                                 │
│     └───┬─────┘                                                 │
│         │ 共享 netns                                            │
│     ┌───┴───┐                                                   │
│     ▼       ▼                                                   │
│  ┌─────┐ ┌─────┐                                                │
│  │ app │ │ log │                                                │
│  └─────┘ └─────┘                                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. K8s Pod 网络原理

### 2.1 Pause 容器（Infra 容器）

```
每个 Pod 都有一个隐藏的 pause 容器：

┌─────────────────────────────────────────────────────────────┐
│                      Pod Network Namespace                   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                  Pause 容器                          │    │
│  │  - 持有 Pod 的 network namespace                     │    │
│  │  - PID: 1 (init 进程)                                │    │
│  │  - 实际执行: /pause                                  │    │
│  │  - 镜像: registry.k8s.io/pause:3.9                   │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│              共享 network namespace                          │
│               (所有容器看到相同的网络接口)                     │
│                           │                                  │
│       ┌───────────────────┼───────────────────┐              │
│       ▼                   ▼                   ▼              │
│  ┌─────────┐       ┌─────────┐       ┌─────────┐           │
│  │ Main App│       │ Sidecar │       │  Other  │           │
│  │         │       │(Envoy)  │       │         │           │
│  └─────────┘       └─────────┘       └─────────┘           │
│                                                              │
│  它们共享: eth0, lo, /proc/net, iptables, route table       │
│  所以: localhost 互通, 端口冲突                               │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Pod IP 分配过程

```
Pod 创建 → kubelet 调用 CNI 插件 → 分配 IP

1. kubelet 创建 pause 容器
     ↓
2. kubelet 执行 CNI 插件 (如 /opt/cni/bin/bridge)
     CNI_COMMAND=ADD
     CNI_CONTAINERID=<pod-id>
     CNI_NETNS=/proc/<pid>/ns/net
     CNI_IFNAME=eth0
     ↓
3. CNI 插件在宿主机创建 veth pair
     ip link add veth-host type veth peer name eth0
     ↓
4. CNI 插件将 eth0 放入 Pod netns
     ip link set eth0 netns /proc/<pid>/ns/net
     ↓
5. CNI 插件配置 eth0 IP
     nsenter -t <pid> -n ip addr add 10.244.1.5/24 dev eth0
     nsenter -t <pid> -n ip link set eth0 up
     nsenter -t <pid> -n ip route add default via 10.244.1.1
     ↓
6. CNI 插件将 veth-host 连接到网桥
     ip link set veth-host master cni0
     ↓
7. kubelet 启动应用容器（共享 pause 的网络）
```

---

## 3. CNI（容器网络接口）

### 3.1 CNI 规范

```
CNI 是一个规范，定义了容器运行时和网络插件之间的接口：

┌─────────────────────────────────────────────────────────────┐
│                     Container Runtime                        │
│                    (containerd / CRI-O)                      │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ 1. 创建网络命名空间
                        │ 2. 调用 CNI 插件
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                        CNI Plugin                            │
│                                                              │
│  输入（环境变量 + stdin JSON）:                               │
│    CNI_COMMAND = ADD / DEL / CHECK                           │
│    CNI_CONTAINERID = pod-id                                  │
│    CNI_NETNS = /proc/xxx/ns/net                              │
│    CNI_IFNAME = eth0                                         │
│    stdin: { "type": "bridge", "bridge": "cni0", ... }        │
│                                                              │
│  输出（stdout JSON）:                                         │
│    {                                                          │
│      "cniVersion": "0.4.0",                                  │
│      "interfaces": [...],                                    │
│      "ips": [{ "version": "4", "address": "10.244.1.5/24" }],│
│      "routes": [...],                                        │
│      "dns": {}                                               │
│    }                                                          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 CNI 配置文件

```bash
# /etc/cni/net.d/10-bridge.conf
{
  "cniVersion": "0.4.0",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.244.1.0/24",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
```

### 3.3 手动模拟 CNI 操作

```bash
# 1. 创建网络命名空间
sudo ip netns add test-ns

# 2. 创建 veth pair
sudo ip link add veth-host type veth peer name eth0

# 3. 将 eth0 放入命名空间
sudo ip link set eth0 netns test-ns

# 4. 在命名空间中配置 IP
sudo ip netns exec test-ns ip addr add 10.244.1.100/24 dev eth0
sudo ip netns exec test-ns ip link set eth0 up
sudo ip netns exec test-ns ip link set lo up
sudo ip netns exec test-ns ip route add default via 10.244.1.1

# 5. 宿主机端配置
sudo ip link set veth-host up
sudo ip link set veth-host master cni0  # 如果 cni0 存在

# 6. 测试连通性
sudo ip netns exec test-ns ping 10.244.1.1

# 7. 清理
sudo ip netns del test-ns
```

---

## 4. 容器间通信场景

### 4.1 同一 Pod 内通信

```
Pod 内所有容器共享 network namespace：

┌────────────────────────────────────────┐
│           Pod (10.244.1.5)             │
│                                        │
│  ┌─────────────┐  ┌─────────────┐     │
│  │   Main App  │  │   Sidecar   │     │
│  │  :8080      │  │  (Envoy)    │     │
│  └──────┬──────┘  └─────────────┘     │
│         │                              │
│         └──────► localhost:8080        │
│                  (直接通过 lo 接口)      │
└────────────────────────────────────────┘

原理：共享 netns，所以 localhost 就是同一个 lo 接口
注意：端口不能冲突！
```

### 4.2 同一节点不同 Pod 通信

```
通过网桥二层转发：

┌─────────────────────────────────────────────────────────────┐
│                          Host                                │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                      cni0 (网桥)                       │   │
│  │                   10.244.1.1/24                       │   │
│  │                                                       │   │
│  │   ┌───────┐          ┌───────┐                       │   │
│  │   │vethA  │          │vethB  │                       │   │
│  │   └───┬───┘          └───┬───┘                       │   │
│  │       │                  │                            │   │
│  └───────┼──────────────────┼────────────────────────────┘   │
│          │                  │                                 │
│  ┌───────┼──────────────────┼────────────────────────────┐   │
│  │   ┌───▼───┐         ┌───▼───┐                         │   │
│  │   │ Pod A │         │ Pod B │                         │   │
│  │   │.1.5   │◄───────►│.1.6   │  直接二层转发，无 NAT    │   │
│  │   └───────┘  网桥    └───────┘                         │   │
│  │                                                        │   │
│  └────────────────────────────────────────────────────────┘   │
│                                                              │
│  数据流: Pod A eth0 → vethA → cni0 → vethB → Pod B eth0   │
│  无需经过宿主机路由，直接在二层交换。                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 不同节点 Pod 通信

```
需要 Overlay 网络或路由：

┌────────────────────────┐              ┌────────────────────────┐
│       Node 1           │              │       Node 2           │
│  192.168.1.10          │              │  192.168.1.11          │
│                        │              │                        │
│  ┌─────────────────┐   │   ┌──────┐   │  ┌─────────────────┐   │
│  │   cni0          │   │   │      │   │  │   cni0          │   │
│  │ 10.244.1.1/24   │   │   │ 物理 │   │  │ 10.244.2.1/24   │   │
│  └────────┬────────┘   │   │ 网络  │   │  └────────┬────────┘   │
│           │            │   │      │   │           │            │
│  ┌────────┴────────┐   │   └──────┘   │  ┌────────┴────────┐   │
│  │  Pod A          │   │              │  │  Pod B          │   │
│  │  10.244.1.5     │◄──┼──────────────┼──►│  10.244.2.5     │   │
│  └─────────────────┘   │              │  └─────────────────┘   │
│                        │              │                        │
│  路由: 10.244.2.0/24   │              │  路由: 10.244.1.0/24   │
│       via 192.168.1.11 │              │       via 192.168.1.10 │
└────────────────────────┘              └────────────────────────┘

实现方式：
  1. 路由方案 (Calico BGP): 每个节点发布 Pod CIDR 路由
  2. VXLAN 隧道 (Flannel): Pod 包封装在 UDP 中传输
  3. IPIP 隧道 (Calico): Pod 包封装在 IP 中传输
```

---

## 5. 容器网络排障

```bash
# 1. 查看 Pod 网络接口
kubectl exec <pod> -- ip addr
kubectl exec <pod> -- ip route

# 2. 进入 Pod 网络命名空间排障
PID=$(kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|docker://||')
# 或使用 crictl
PID=$(crictl inspect <container-id> | jq .info.pid)

nsenter -t $PID -n ip addr
nsenter -t $PID -n ip route
nsenter -t $PID -n iptables -L -n -v
nsenter -t $PID -n ss -tan

# 3. 在 Pod 网络命名空间中抓包
nsenter -t $PID -n tcpdump -i eth0 -w /tmp/pod.pcap host 10.96.0.1

# 4. 查看宿主机上网桥
brctl show
bridge link show

# 5. 查看 CNI 分配信息
# host-local IPAM 分配记录
cat /var/lib/cni/networks/mynet/10.244.1.5

# 6. 检查 CNI 插件日志
journalctl -u kubelet | grep -i cni

# 7. 检查路由
ip route show
ip route get 10.244.2.5  # 查看到目标 Pod 的路径

# 8. 检查 iptables NAT
iptables -t nat -L -n -v | grep <pod-ip>
```

---

## 6. 容器网络安全

```bash
# 1. 限制容器出网 (通过 iptables)
# 只允许访问特定网段
iptables -A OUTPUT -p tcp -d 10.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -p tcp -j DROP

# 2. 通过 Docker 网络隔离
# 创建自定义网络，控制互通
docker network create --internal isolated-net
# --internal 表示没有外部访问

# 3. K8s NetworkPolicy（更推荐）
# 见 docs/13-networking/09-network-security/
```

---

## 参考资源

- [CNI Specification](https://www.cni.dev/docs/spec/)
- [Docker Network](https://docs.docker.com/network/)
- [Kubernetes Networking Concepts](https://kubernetes.io/docs/concepts/cluster-administration/networking/)

# 05. 网络体系详解

## K8s 网络模型

### 核心要求

K8s 对网络有**三个基本要求**：

1. **所有 Pod 可以直接通信**（无需 NAT）
   - Pod A (10.244.1.2) 可以直接 ping Pod B (10.244.2.3)
   - 源 IP 就是 Pod 的 IP，不会被转换

2. **所有节点可以直接通信**
   - Node A 可以直接访问 Node B 上的 Pod

3. **Pod 可以看到自己的 IP**
   - 容器内的 `ip addr` 显示的就是 Pod IP

```
┌──────────────┐          ┌──────────────┐
│   Node A     │          │   Node B     │
│  192.168.1.1 │◄────────►│  192.168.1.2 │
│              │  直接通信 │              │
│  ┌────────┐  │          │  ┌────────┐  │
│  │Pod A   │  │◄────────►│  │Pod B   │  │
│  │10.244.1│  │ 直接通信 │  │10.244.2│  │
│  └────────┘  │          │  └────────┘  │
└──────────────┘          └──────────────┘
```

### IP 地址分配

| 地址类型 | 范围 | 分配者 |
|---------|------|--------|
| **Pod IP** | 10.244.0.0/16（CNI 分配） | CNI 插件 |
| **Service ClusterIP** | 10.96.0.0/12（默认） | apiserver |
| **Node IP** | 节点实际网络 | 云平台/管理员 |

---

## CNI — 容器网络接口

### CNI 是什么

CNI（Container Network Interface）是 K8s 与网络插件之间的**标准接口**。

```
Kubelet/Containerd
       │
       ├── 创建 Pod Sandbox（pause 容器）
       │
       ├── 调用 CNI ADD 命令
       │       │
       │       ├── 传递参数：容器 ID、网络命名空间、Pod IP 等
       │       │
       │       └── 调用 CNI 插件二进制文件
       │               │
       │               └── 配置容器网络（分配 IP、设置路由、创建 veth pair）
       │
       └── 返回结果：Pod IP、DNS 配置等
```

### CNI 插件类型

| 类型 | 代表插件 | 特点 |
|------|---------|------|
| **Overlay** | Flannel (VXLAN)、Calico (IPIP)、Weave | 封装包，跨节点通信通过隧道 |
| **路由** | Calico (BGP)、Cilium (BPF) | 直接路由，性能好，需要底层网络配合 |
| **Underlay** | Macvlan、SR-IOV | Pod 直接暴露在物理网络 |

### Flannel — 最简单的 CNI

**原理**：使用 VXLAN 隧道封装跨节点流量。

```
Pod A (10.244.1.2) 访问 Pod B (10.244.2.3)

同节点：
  Pod A ──► cni0 (网桥) ──► Pod B

跨节点：
  Pod A ──► cni0 ──► flannel.1 (VXLAN 设备)
         │
         │ VXLAN 封装
         │ 内部：src=10.244.1.2, dst=10.244.2.3
         │ 外部：src=192.168.1.1, dst=192.168.1.2
         │
         ▼
      Node B ──► flannel.1 ──► cni0 ──► Pod B
```

**后端模式**：
- `vxlan`：默认，封装 UDP 包
- `host-gw`：直接路由，性能最好但需要二层连通
- `udp`：旧版，已废弃
- `aws-vpc`/`ali-vpc`：云厂商集成

### Calico — 企业级 CNI

**两种模式**：

#### BGP 模式（推荐）

```
Pod A (10.244.1.2) 访问 Pod B (10.244.2.3)

同节点：
  Pod A ──► veth ──► caliXXXXX (虚拟网卡) ──► Pod B

跨节点：
  Pod A ──► veth ──► 路由表
         │
         │ 路由：10.244.2.0/24 via 192.168.1.2
         │
         ▼
      Node B ──► 路由表 ──► Pod B
```

**特点**：
- 使用 BGP 协议在节点之间分发路由
- 不封装包，性能最好
- 需要底层网络支持 BGP 或允许任意源/目的 IP

#### IPIP/VXLAN 模式

```
跨节点通信时，将 IP 包封装在另一个 IP 包中：

原始包：src=10.244.1.2, dst=10.244.2.3
封装后：src=192.168.1.1, dst=192.168.1.2, payload=原始包
```

**Calico 的额外能力**：
- **NetworkPolicy**：实现 Pod 级别的防火墙
- **eBPF 数据平面**：替代 iptables，更高性能
- **WireGuard**：加密 Pod 间通信

### Cilium — 基于 eBPF 的 CNI

```
Cilium 使用 eBPF 程序替代 iptables：

传统：Pod ──► veth ──► iptables ──► 路由 ──► 网卡
               │
               └── 规则数量 O(n)，遍历线性链表

eBPF：Pod ──► veth ──► eBPF 程序 ──► 网卡
               │
               └── 规则存储在 BPF Map（哈希表），查询 O(1)
```

**eBPF 优势**：
- 内核级执行，无用户态/内核态切换
- 哈希表查找，O(1) 复杂度
- 可观测性强（能捕获所有网络流量）
- 支持 L3/L4/L7 策略

**Cilium 的额外能力**：
- **Service Mesh**：替代 Istio Sidecar，eBPF 实现负载均衡
- **Hubble**：网络流量可视化
- **Cluster Mesh**：多集群 Pod 直接通信

---

## Service 网络实现

### ClusterIP 实现

```
┌─────────────────────────────────────────────┐
│               Node                           │
│                                              │
│  ┌──────────────────────────────────────┐   │
│  │ kube-proxy (iptables/IPVS)           │   │
│  │                                      │   │
│  │ 规则: 10.96.0.1:80 ──► [10.244.1.2,  │   │
│  │                  10.244.1.3, 10.244.1.4] │   │
│  └──────────────────────────────────────┘   │
│                                              │
│  ┌──────────┐    ┌──────────┐   ┌─────────┐│
│  │Pod A     │    │Pod B     │   │Pod C    ││
│  │10.244.1.2│    │10.244.1.3│   │10.244.1.4│
│  └──────────┘    └──────────┘   └─────────┘│
└─────────────────────────────────────────────┘
```

**iptables 规则链**：
```
PREROUTING → KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx → DNAT
```

### NodePort 实现

```
外部流量 → NodeIP:30080 → kube-proxy → DNAT → PodIP:80

iptables 规则：
-A KUBE-NODEPORTS -p tcp -m tcp --dport 30080
  -j KUBE-SVC-xxx
```

**NodePort 范围**：30000-32767

### LoadBalancer 实现

```
云厂商场景：

外部流量 ──► 云 LB (公网 IP) ──► NodePort ──► Pod
                     │
                     │ Cloud Controller Manager 创建
                     │
                     ▼
                ┌─────────┐
                │  云 LB   │
                │  (ELB)   │
                └────┬────┘
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
    Node:30080  Node:30080  Node:30080
        │            │            │
        └────────────┼────────────┘
                     ▼
                   Pod:80
```

### ExternalName 实现

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-external
spec:
  type: ExternalName
  externalName: database.example.com
```

**实现**：创建 DNS CNAME 记录，将 `my-external.default.svc.cluster.local` 指向 `database.example.com`。

---

## DNS

### CoreDNS

CoreDNS 是 K8s 集群的 DNS 服务器。

```
Pod 查询 DNS
    │
    ├── /etc/resolv.conf
    │   └── nameserver 10.96.0.10
    │   └── search default.svc.cluster.local svc.cluster.local cluster.local
    │
    └── 请求发送到 CoreDNS Service (ClusterIP: 10.96.0.10)
            │
            └── CoreDNS Pod 处理
                    │
                    ├── K8s 内部域名：查询 apiserver 获取 Endpoints
                    │   └── cluster.local 域
                    │
                    └── 外部域名：转发到上游 DNS
                        └── /etc/resolv.conf 中配置的上游
```

**DNS 记录格式**：

| 资源 | DNS 记录 |
|------|---------|
| Service | `service-name.namespace.svc.cluster.local` |
| Pod（默认）| 无（需要 Headless Service） |
| Headless Service | 直接返回 Pod IP |
| StatefulSet Pod | `pod-name.service-name.namespace.svc.cluster.local` |

### Headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-headless
spec:
  clusterIP: None  # ← 设置为 None
  selector:
    app: my-app
```

**特点**：
- 不分配 ClusterIP
- DNS 查询直接返回后端 Pod IP 列表
- 适合需要直接访问 Pod 的场景（如 StatefulSet）

```
普通 Service DNS：
  my-svc → 10.96.0.1（ClusterIP）

Headless Service DNS：
  my-headless → [10.244.1.2, 10.244.1.3, 10.244.1.4]
```

---

## Ingress

### 为什么需要 Ingress

Service 类型的问题：
- NodePort：端口范围受限（30000-32767），需要记住端口号
- LoadBalancer：每个 Service 创建一个云 LB，成本高

**Ingress 提供**：
- 基于域名/路径的路由
- 一个入口（一个 LB 或一个 NodePort）暴露多个 Service
- SSL/TLS 终止

```
外部请求
    │
    ▼
┌─────────┐
│ Ingress │  ← 定义路由规则
│ Controller │
│ (nginx/traefik/envoy) │
└────┬────┘
     │
     ├── /api → Service A
     ├── /web → Service B
     └── /    → Service C
```

### Ingress 资源

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /v1
        pathType: Prefix
        backend:
          service:
            name: api-v1
            port:
              number: 80
      - path: /v2
        pathType: Prefix
        backend:
          service:
            name: api-v2
            port:
              number: 80
  - host: web.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
  tls:
  - hosts:
    - api.example.com
    secretName: api-tls-secret
```

### Ingress Controller

Ingress 资源只是**声明**，需要 Ingress Controller 来实现。

| Controller | 特点 |
|-----------|------|
| **NGINX Ingress** | 最流行，功能全面 |
| **Traefik** | 云原生，自动服务发现 |
| **HAProxy** | 高性能 |
| **Envoy / Contour** | 基于 Envoy，功能强大 |
| **Istio Ingress Gateway** | Service Mesh 集成 |
| **云厂商 Ingress** | 集成云 LB（ALB、CLB） |

---

## NetworkPolicy

### 作用

NetworkPolicy 定义 Pod 级别的**防火墙规则**，控制哪些流量可以进出 Pod。

```
默认情况：所有 Pod 之间完全互通

应用 NetworkPolicy 后：
  frontend Pod ──► 只允许来自 Ingress Controller 的流量
  backend Pod  ──► 只允许来自 frontend 的流量
  database Pod ──► 只允许来自 backend 的流量
```

### 示例

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 3306
```

**规则含义**：
- 只选择 label `app=backend` 的 Pod
- Ingress：只允许来自 `app=frontend` 的流量，端口 8080
- Egress：只允许访问 `app=database`，端口 3306

### 实现要求

NetworkPolicy 需要 CNI 插件支持：
- **Calico**：完全支持
- **Cilium**：完全支持
- **Flannel**：不支持（需要使用 Canal = Flannel + Calico policy）
- **Weave**：支持

---

## 网络排查命令

```bash
# 查看 Pod IP
kubectl get pod -o wide

# 查看 Service 和 Endpoints
kubectl get svc,ep

# 进入 Pod 测试网络
curl http://service-name.namespace.svc.cluster.local:80

# 查看节点路由
ip route

# 查看 iptables 规则
iptables -t nat -L KUBE-SERVICES -n

# 查看 IPVS 规则
ipvsadm -Ln

# 查看 CNI 配置
cat /etc/cni/net.d/*.conf

# 查看 Pod 网络命名空间
ls /proc/$(docker inspect -f '{{.State.Pid}}' <container-id>)/ns/net

# 使用 nsenter 进入网络命名空间
nsenter -t <pid> -n ip addr

# 查看 CoreDNS 日志
kubectl logs -n kube-system -l k8s-app=kube-dns

# 测试 DNS
kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default
```

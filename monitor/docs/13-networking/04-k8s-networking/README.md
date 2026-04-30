# Kubernetes 网络深入

> K8s 网络是云原生中最复杂的部分之一。理解 Pod IP、Service、kube-proxy、DNS 的工作原理，是定位网络故障的核心能力。

---

## 1. K8s 网络模型

### 1.1 核心要求

K8s 对网络有 3 个基本要求：

```
1. 所有 Pod 可以在不使用 NAT 的情况下与其他 Pod 通信
   → Pod IP 是真实的、可路由的（在集群内）

2. 所有节点可以在不使用 NAT 的情况下与所有 Pod 通信
   → 节点可以直接访问 Pod IP

3. Pod 看到的自己的 IP 与其他 Pod 看到的它的 IP 相同
   → 没有端口映射或 IP 伪装
```

### 1.2 三种 IP 地址

```
┌─────────────────────────────────────────────────────────────┐
│                          外部用户                            │
│                                                              │
│  访问 my-service.default.svc.cluster.local:80               │
│                          │                                   │
│                          ▼                                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              Service ClusterIP: 10.96.0.100           │  │  ← 虚拟 IP
│  │              (存在于 iptables/ipvs 规则中)             │  │
│  │                                                       │  │
│  │   ┌─────────────┐    ┌─────────────┐                │  │
│  │   │ Pod A       │    │ Pod B       │                │  │
│  │   │ 10.244.1.5  │    │ 10.244.2.3  │                │  │  ← 真实 Pod IP
│  │   │ :8080       │    │ :8080       │                │  │
│  │   └─────────────┘    └─────────────┘                │  │
│  │                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  外部访问: NodeIP:30080 (NodePort) 或 LoadBalancer IP       │  ← 外部 IP
└─────────────────────────────────────────────────────────────┘

三类 IP：
  1. Pod IP: 10.244.x.x     — 容器真实 IP，生命周期与 Pod 绑定
  2. ClusterIP: 10.96.x.x   — Service 虚拟 IP，存在于所有节点
  3. External IP: 公网 IP    — NodePort/LoadBalancer/Ingress 暴露
```

---

## 2. Service 原理

### 2.1 Service 类型

| 类型 | 说明 | 使用场景 |
|------|------|----------|
| **ClusterIP** | 集群内部虚拟 IP（默认） | 服务间调用 |
| **NodePort** | 每个节点开放一个端口 | 开发测试、直接暴露 |
| **LoadBalancer** | 云厂商负载均衡器 | 生产环境外部访问 |
| **ExternalName** | DNS CNAME 记录 | 外部服务映射 |
| **Headless** | 无 ClusterIP，返回 Pod IP | StatefulSet、服务发现 |

### 2.2 kube-proxy 的三种模式

```
┌─────────────────────────────────────────────────────────────┐
│                    kube-proxy 模式对比                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  iptables 模式（默认）                                       │
│  ─────────────────────                                       │
│  使用 iptables DNAT 实现负载均衡                              │
│  优点：简单、内核原生                                        │
│  缺点：规则多（O(n)）、无法优雅关闭连接、无健康检查            │
│                                                             │
│  规则链：PREROUTING → KUBE-SERVICES → KUBE-SVC-XXX          │
│           → KUBE-SEP-XXX (概率 DNAT 到 Pod IP)              │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ipvs 模式（推荐）                                          │
│  ─────────────────                                          │
│  使用 Linux IPVS 实现负载均衡                                 │
│  优点：性能高（O(1)）、支持多种调度算法、连接优雅关闭          │
│  缺点：需要加载 ipvs 内核模块                                 │
│                                                             │
│  实现：ipvsadm -Ln                                          │
│  TCP  10.96.0.1:443 rr                                     │
│    -> 10.244.1.5:6443        Masq    1      0          0   │
│    -> 10.244.2.3:6443        Masq    1      0          0   │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  nftables 模式（实验性）                                     │
│  ──────────────────────                                     │
│  使用 nftables 替代 iptables                                  │
│  优点：统一框架、性能更好                                     │
│  缺点：较新，生态不如 iptables 成熟                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 iptables 模式详解

```bash
# 查看 Service 的 iptables 规则
iptables -t nat -L KUBE-SERVICES -n | grep my-service
# KUBE-SVC-ABC123  tcp  --  0.0.0.0/0  10.96.0.100  tcp dpt:80

# 查看负载均衡规则
iptables -t nat -L KUBE-SVC-ABC123 -n
# KUBE-SEP-XXX  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.333
# KUBE-SEP-YYY  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.500
# KUBE-SEP-ZZZ  all  --  0.0.0.0/0  0.0.0.0/0

# 查看 DNAT 规则
iptables -t nat -L KUBE-SEP-XXX -n
# DNAT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp to:10.244.1.5:8080

# 完整的访问流程
Pod 访问 10.96.0.100:80
  → OUTPUT → KUBE-SERVICES → KUBE-SVC-ABC123
  → 按概率选择 KUBE-SEP-XXX → DNAT 到 10.244.1.5:8080
  → 路由到目标 Pod
  → POSTROUTING → KUBE-POSTROUTING（如需 MASQUERADE）
```

### 2.4 ipvs 模式详解

```bash
# 启用 ipvs 模式
kubectl edit cm kube-proxy -n kube-system
# 设置 mode: "ipvs"
# kubectl rollout restart ds kube-proxy -n kube-system

# 查看 ipvs 规则
ipvsadm -Ln
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port Scheduler Flags
#   -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
# TCP  10.96.0.1:443 rr
#   -> 10.244.1.5:6443              Masq    1      12         3
#   -> 10.244.2.3:6443              Masq    1      8          2

# 调度算法
# rr: Round Robin（轮询）
# lc: Least Connection（最少连接）
# dh: Destination Hashing
# sh: Source Hashing
# sed: Shortest Expected Delay
# nq: Never Queue
```

### 2.5 Headless Service

```yaml
# headless-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-db
spec:
  clusterIP: None  # 这就是 Headless
  selector:
    app: my-db
  ports:
    - port: 3306
```

```
Headless Service 特点：

1. DNS 直接返回 Pod IP，而不是 ClusterIP
   $ nslookup my-db.default.svc.cluster.local
   Address: 10.244.1.5
   Address: 10.244.2.3

2. 每个 Pod 有独立的 DNS 记录
   my-db-0.my-db.default.svc.cluster.local -> 10.244.1.5
   my-db-1.my-db.default.svc.cluster.local -> 10.244.2.3

3. 客户端直接连接 Pod IP，没有负载均衡层

4. 适用场景：
   - StatefulSet（需要稳定的网络标识）
   - 客户端需要知道所有后端（如 gRPC 客户端负载均衡）
```

---

## 3. K8s DNS（CoreDNS）

### 3.1 DNS 架构

```
Pod DNS 解析流程：

Pod (dnsPolicy: ClusterFirst)
  │
  │ resolv.conf:
  │   nameserver 10.96.0.10
  │   search default.svc.cluster.local svc.cluster.local cluster.local
  │   options ndots:5
  │
  ▼
CoreDNS Pod (10.96.0.10)
  │
  ▼
CoreDNS 插件链：
  kubernetes: 解析 *.svc.cluster.local（K8s 服务发现）
  etcd: 解析自定义 DNS 记录
  forward: 转发到上游 DNS（如 8.8.8.8）
  cache: 缓存结果
  loop: 检测循环
  prometheus: 暴露指标
  errors: 错误日志
```

### 3.2 DNS 记录类型

```
Service DNS：
  <service>.<namespace>.svc.cluster.local
  例: kubernetes.default.svc.cluster.local -> 10.96.0.1

Headless Service DNS：
  <pod-name>.<service>.<namespace>.svc.cluster.local
  例: my-db-0.my-db.default.svc.cluster.local -> 10.244.1.5

Pod DNS（需启用）：
  <pod-ip>.<namespace>.pod.cluster.local
  例: 10-244-1-5.default.pod.cluster.local -> 10.244.1.5

SRV 记录（用于端口发现）：
  _http._tcp.<service>.<namespace>.svc.cluster.local
```

### 3.3 CoreDNS 配置

```yaml
# CoreDNS Corefile
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure  # 启用 Pod DNS
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
```

### 3.4 DNS 排障

```bash
# 1. 查看 Pod 的 DNS 配置
kubectl exec <pod> -- cat /etc/resolv.conf

# 2. DNS 解析测试
kubectl exec -it <pod> -- nslookup kubernetes.default
kubectl exec -it <pod> -- dig @10.96.0.10 kubernetes.default.svc.cluster.local

# 3. 测试 CoreDNS
kubectl exec -it -n kube-system <coredns-pod> -- nslookup kubernetes.default

# 4. 查看 CoreDNS 日志
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100

# 5. CoreDNS 指标
kubectl exec -n kube-system <coredns-pod> -- wget -qO- http://localhost:9153/metrics | grep coredns_dns_request_duration_seconds

# 6. 常见 DNS 问题：ndots:5
# 如果查询不含足够点号，会依次尝试 search 域
# my-service → my-service.default.svc.cluster.local → ...
# 这可能导致 N+1 次查询，性能下降
# 解决：使用 FQDN（末尾加.）或调整 ndots
```

---

## 4. Ingress

### 4.1 Ingress 架构

```
外部流量 → Ingress Controller → Service → Pod

┌─────────────────────────────────────────────────────────────┐
│                    外部流量                                   │
│                      │                                       │
│  ┌───────────────────▼───────────────────┐                   │
│  │       Ingress Controller              │                   │
│  │  (Nginx/Traefik/Envoy Gateway)        │                   │
│  │                                       │                   │
│  │  TLS 终止、路由、限流、重写、认证        │                   │
│  │                                       │                   │
│  │  /api/*  →  api-service:80            │                   │
│  │  /web/*  →  web-service:80            │                   │
│  │  /grpc   →  grpc-service:50051        │                   │
│  └───────────────────┬───────────────────┘                   │
│                      │                                       │
│              ┌───────┴───────┐                               │
│              ▼               ▼                               │
│        ┌─────────┐     ┌─────────┐                          │
│        │ Service │     │ Service │                          │
│        └────┬────┘     └────┬────┘                          │
│             │               │                                │
│        ┌────┴────┐     ┌────┴────┐                          │
│        ▼         ▼     ▼         ▼                          │
│      Pod       Pod   Pod       Pod                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Ingress 配置示例

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rate-limit: "100"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: api-tls
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
```

---

## 5. K8s 网络排障流程

```bash
# 问题：Pod A 无法访问 Service B

# Step 1: 检查 Pod 状态
kubectl get pod <pod-a> -o wide
kubectl describe pod <pod-a> | grep -A5 Events

# Step 2: 检查 Service 是否存在
kubectl get svc <svc-b>
kubectl describe svc <svc-b>  # 查看 Endpoints

# Step 3: 检查 Endpoints（Pod 是否被选中）
kubectl get endpoints <svc-b>
# 如果为空，检查 Service selector 和 Pod labels 是否匹配

# Step 4: 从 Pod 内测试连通性
kubectl exec <pod-a> -- curl -v <svc-b>:<port>
kubectl exec <pod-a> -- nslookup <svc-b>

# Step 5: 检查 DNS 解析
kubectl exec <pod-a> -- cat /etc/resolv.conf
kubectl exec <pod-a> -- dig <svc-b>.default.svc.cluster.local

# Step 6: 检查 kube-proxy
kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=50

# Step 7: 查看 iptables/ipvs 规则
# 在节点上执行
iptables -t nat -L KUBE-SERVICES -n | grep <svc-ip>
ipvsadm -Ln | grep <svc-ip>

# Step 8: 抓包
# 在 Pod 网络命名空间抓包
nsenter -t <pod-pid> -n tcpdump -i eth0 -w /tmp/capture.pcap host <svc-ip>

# Step 9: 检查 NetworkPolicy
kubectl get networkpolicy --all-namespaces
kubectl describe networkpolicy <policy-name>

# Step 10: 检查节点路由
ip route get <pod-ip>
```

---

## 参考资源

- [Kubernetes Networking](https://kubernetes.io/docs/concepts/services-networking/)
- [Service](https://kubernetes.io/docs/concepts/services-networking/service/)
- [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [CoreDNS](https://coredns.io/manual/toc/)

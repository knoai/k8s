# 第19章 K8s 网络进阶篇：CNI 插件与 Service 网络

> **本章目标**：深入理解 K8s 网络的核心机制。从 CNI 插件原理到 Service 网络模型，从 Ingress 到 Gateway API，建立完整的网络知识体系。
>
> 读完本章后，你应该能够：理解主流 CNI 插件的工作原理；配置 Service 和 Ingress；设计 NetworkPolicy 策略；排查网络故障。

---

## 19.1 K8s 网络基础回顾

### 19.1.1 K8s 网络模型

K8s 网络模型规定了三个核心要求：

1. **Pod-to-Pod**：所有 Pod 可以直接通信（无需 NAT）
2. **Pod-to-Service**：Pod 可以通过 Service 访问其他 Pod
3. **External-to-Service**：外部可以通过 Service 访问 Pod

```
┌─────────────────────────────────────────────────────────────┐
│                    K8s 网络模型                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐               │
│   │ Pod A   │◄──►│ Pod B   │◄──►│ Pod C   │               │
│   │10.0.1.2 │    │10.0.2.3 │    │10.0.1.4 │               │
│   └────┬────┘    └────┬────┘    └────┬────┘               │
│        │              │              │                      │
│        └──────────────┼──────────────┘                      │
│                       │                                      │
│              ┌────────▼────────┐                            │
│              │     Service     │                            │
│              │  10.96.0.1:80   │                            │
│              └────────┬────────┘                            │
│                       │                                      │
│              ┌────────▼────────┐                            │
│              │   Ingress/LB    │                            │
│              │  203.0.113.10   │                            │
│              └─────────────────┘                            │
│                                                              │
│  核心原则：                                                   │
│  - 每个 Pod 有独立的 IP（IP-per-Pod）                         │
│  - Pod IP 在集群内可直接路由                                  │
│  - NAT 只发生在集群边界                                       │
└─────────────────────────────────────────────────────────────┘
```

### 19.1.2 CNI 规范

CNI（Container Network Interface）是容器网络的标准接口：

```
CNI 工作流程：

kubelet 创建 Pod
    │
    ▼ 调用 CRI（如 containerd）
containerd 创建网络命名空间
    │
    ▼ 调用 CNI 插件（/opt/cni/bin/）
CNI 插件执行 ADD 操作
    │
    ├─ 1. 从 IPAM 分配 IP
    ├─ 2. 创建 veth 对（一端在容器，一端在主机）
    ├─ 3. 配置路由
    ├─ 4. 配置网络策略（可选）
    └─ 5. 返回结果（IP、路由、DNS）给 kubelet

CNI 配置文件：/etc/cni/net.d/10-xxx.conf
{
  "cniVersion": "0.4.0",
  "name": "mynet",
  "type": "bridge",       // CNI 插件类型
  "bridge": "cni0",
  "ipam": {
    "type": "host-local",  // IPAM 插件
    "subnet": "10.0.0.0/24"
  }
}
```

---

## 19.2 CNI 插件详解

### 19.2.1 Flannel：简单 Overlay 网络

**架构**：

```
┌─────────────┐              ┌─────────────┐
│   Node 1    │              │   Node 2    │
│  10.0.1.0/24│              │  10.0.2.0/24│
│             │              │             │
│  ┌───────┐  │              │  ┌───────┐  │
│  │ Pod   │──┼──► flannel.1 │  │ Pod   │  │
│  │10.0.1.2│  │   VXLAN     │  │10.0.2.3│  │
│  └───────┘  │   8472/UDP   │  └───────┘  │
│     │       │      │       │     │       │
│  cni0       │      ▼       │  cni0       │
│  10.0.1.1/24│   宿主机网络  │  10.0.2.1/24│
└─────────────┘              └─────────────┘

数据包流程：
Pod(10.0.1.2) → cni0 → flannel.1 → VXLAN(8472/UDP) → 宿主机网络 → Node 2 flannel.1 → cni0 → Pod(10.0.2.3)
```

**后端模式**：

| 后端 | 原理 | 适用场景 | 性能 |
|------|------|---------|------|
| **VXLAN** | UDP 隧道封装 | 通用，默认推荐 | 中等 |
| **host-gw** | 直接路由 | 二层互通环境 | 高 |
| **UDP** | 用户态封装 | 测试，不推荐 | 低 |
| **Alloc** | 云厂商分配 | AWS/GCE | 高 |

```bash
# 部署
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 查看配置
kubectl get configmap kube-flannel-cfg -n kube-flannel -o yaml

# 切换后端模式（修改 ConfigMap 后重启）
kubectl edit cm kube-flannel-cfg -n kube-flannel
# Type: "host-gw" 或 "vxlan"
```

**Flannel 特点**：
- ✅ 简单易用，配置少
- ✅ 社区成熟，文档丰富
- ❌ 无 NetworkPolicy 支持（需配合 Calico policy-only 模式）
- ❌ 无高级网络功能（负载均衡、可观测性）

### 19.2.2 Calico：BGP + 策略

**架构**：

```
┌─────────────────────────────────────────────────────────────┐
│                       Calico 网络                            │
│                                                             │
│  ┌─────────────┐         ┌─────────────┐                   │
│  │   Node 1    │◄─BGP───►│   Node 2    │                   │
│  │             │         │             │                   │
│  │  ┌───────┐  │         │  ┌───────┐  │                   │
│  │  │ Pod   │  │         │  │ Pod   │  │                   │
│  │  │10.0.1.2│  │         │  │10.0.2.3│  │                   │
│  │  └───────┘  │         │  └───────┘  │                   │
│  │     │       │         │     │       │                   │
│  │  caliXXX    │         │  caliXXX    │                   │
│  │  (veth)     │         │  (veth)     │                   │
│  └─────────────┘         └─────────────┘                   │
│                                                             │
│  BGP 模式：每个节点作为路由器，直接发布 Pod 路由            │
│  IPIP/VXLAN 模式：Overlay 封装（底层网络不支持 BGP 时）    │
└─────────────────────────────────────────────────────────────┘
```

**部署**：

```bash
# 使用 Operator 部署
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/custom-resources.yaml

# 查看 BGP 对等体
kubectl exec -n calico-system calico-node-xxx -- calicoctl node status

# 使用 calicoctl
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calicoctl.yaml
kubectl exec -ti -n kube-system calicoctl -- /calicoctl get nodes
```

**Calico 三种模式**：

| 模式 | 数据平面 | 特点 | 适用场景 |
|------|---------|------|---------|
| **BGP** | 直接路由 | 高性能，无封装开销 | 物理网络支持 BGP |
| **IPIP** | IP in IP 隧道 | 通用性好，轻微开销 | 跨子网部署 |
| **VXLAN** | UDP 隧道 | 兼容性好，无 BGP 要求 | 云环境 |

```yaml
# 切换模式
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
```

### 19.2.3 Cilium：eBPF 革命

**架构**：

```
┌─────────────────────────────────────────────────────────────┐
│                      Cilium 网络                             │
│                                                             │
│  ┌─────────────┐         ┌─────────────┐                   │
│  │   Node 1    │◄────────►│   Node 2    │                   │
│  │             │  VXLAN   │             │                   │
│  │  ┌───────┐  │ 或路由   │  ┌───────┐  │                   │
│  │  │ Pod   │  │          │  │ Pod   │  │                   │
│  │  │(身份)  │  │          │  │(身份)  │  │                   │
│  │  └───────┘  │          │  └───────┘  │                   │
│  │     │       │          │     │       │                   │
│  │  lxcXXXX    │          │  lxcXXXX    │                   │
│  │  (eBPF)     │          │  (eBPF)     │                   │
│  │             │          │             │                   │
│  │ Cilium Agent│          │ Cilium Agent│                   │
│  │ (控制平面)   │          │ (控制平面)   │                   │
│  └─────────────┘          └─────────────┘                   │
│                                                             │
│  eBPF 程序替代 kube-proxy、iptables、conntrack              │
│  身份感知网络策略（基于 Pod 标签，非 IP 依赖）               │
└─────────────────────────────────────────────────────────────┘
```

**部署**：

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=auto \
  --set k8sServicePort=6443

# 验证
cilium status
cilium connectivity test
```

**Cilium 核心特性**：

| 特性 | 说明 | 安全价值 |
|------|------|---------|
| **kube-proxy 替代** | eBPF 直接处理 Service 负载均衡 | 减少攻击面 |
| **身份感知安全** | 基于 Pod 标签而非 IP 地址 | 策略不受 IP 变化影响 |
| **L7 策略** | HTTP/gRPC/DNS 层过滤 | 应用层访问控制 |
| **Hubble** | 内置网络可观测性 | 流量可视化、故障排查 |
| **Cluster Mesh** | 多集群互联 | 跨集群安全策略 |
| **WireGuard** | Pod 间自动加密 | 传输加密 |
| **Bandwidth Manager** | eBPF 带宽管理 | QoS、DDoS 防护 |

### 19.2.4 CNI 插件对比

| 特性 | Flannel | Calico | Cilium |
|------|---------|--------|--------|
| 复杂度 | 低 | 中 | 中-高 |
| 性能 | 中 | 高(BGP) | 极高(eBPF) |
| NetworkPolicy | ❌ | ✅ L3-L4 | ✅ L3-L7 |
| 可观测性 | ❌ | 基础 | 强(Hubble) |
| 加密 | ❌ | WireGuard | WireGuard |
| Service Mesh | ❌ | ❌ | ✅(无 Sidecar) |
| kube-proxy 替代 | ❌ | 部分 | ✅ |
| 多集群 | ❌ | ✅ | ✅(ClusterMesh) |
| 适用场景 | 简单集群 | 生产通用 | 高级需求 |

---

## 19.3 Service 网络深入

### 19.3.1 Service 类型对比

| 类型 | 访问方式 | 负载均衡 | 适用场景 |
|------|---------|---------|---------|
| **ClusterIP** | 集群内部 | kube-proxy | 内部服务通信 |
| **NodePort** | `<NodeIP>:<Port>` | kube-proxy | 开发测试 |
| **LoadBalancer** | 云 LB IP | 云 LB + kube-proxy | 生产外部访问 |
| **ExternalName** | CNAME 重定向 | DNS | 外部服务映射 |

### 19.3.2 Headless Service

```yaml
# Headless Service：不分配 ClusterIP，直接返回 Pod IP
apiVersion: v1
kind: Service
metadata:
  name: stateful-app
spec:
  clusterIP: None    # Headless
  selector:
    app: stateful-app
  ports:
  - port: 80
```

**用途**：
- StatefulSet 直接访问特定 Pod：`pod-0.stateful-app.default.svc.cluster.local`
- 需要直接控制负载均衡的场景
- 自定义服务发现

### 19.3.3 ExternalTrafficPolicy

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local    # 或 Cluster（默认）
  selector:
    app: web
  ports:
  - port: 80
```

| 策略 | 行为 | 特点 |
|------|------|------|
| **Cluster** | 流量可能经过 kube-proxy 转发到其他节点 | 负载均衡好，多一次跳转，丢失源 IP |
| **Local** | 只转发到本地 Pod，无本地 Pod 则丢弃 | 保留客户端源 IP，可能不均 |

### 19.3.4 Session Affinity

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
  - port: 80
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600    # 会话保持 1 小时
```

### 19.3.5 EndpointSlice（K8s 1.21+ 默认）

```
EndpointSlice 替代 Endpoints：

旧模型（Endpoints）：
- 单个 Endpoints 对象包含所有后端 IP
- 超过 1000 个 Pod 时性能下降
- 任何变更触发全量更新

新模型（EndpointSlice）：
- 将后端拆分为多个 Slice（默认每 Slice 100 个端点）
- 增量更新，减少 API Server 负载
- 支持双栈（IPv4 + IPv6）

查看 EndpointSlice：
kubectl get endpointslices -l kubernetes.io/service-name=web
```

---

## 19.4 Ingress 与 Gateway API

### 19.4.1 Ingress 基础与安全加固

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    # 重写路径
    nginx.ingress.kubernetes.io/rewrite-target: /
    
    # 强制 HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    
    # 限速
    nginx.ingress.kubernetes.io/limit-rps: "100"
    nginx.ingress.kubernetes.io/limit-connections: "50"
    
    # HSTS
    nginx.ingress.kubernetes.io/hsts: "true"
    nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
    nginx.ingress.kubernetes.io/hsts-include-subdomains: "true"
    
    # 安全头
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-XSS-Protection "1; mode=block" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # CORS
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.example.com"
    
    # WAF（ModSecurity）
    nginx.ingress.kubernetes.io/enable-modsecurity: "true"
    nginx.ingress.kubernetes.io/enable-owasp-core-rules: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - api.example.com
    secretName: api-tls-secret
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

### 19.4.2 Gateway API（下一代 Ingress）

**核心资源层次**：

```
GatewayClass  →  Gateway  →  HTTPRoute/TCPRoute/GRPCRoute
   (基础设施)     (监听器)        (路由规则)
      │              │                  │
      ▼              ▼                  ▼
   由平台管理员   由集群运维定义      由应用开发者定义
   定义可用的    创建实际入口点       配置应用路由
   Gateway 类型
```

**Gateway API 完整示例**：

```yaml
# GatewayClass（平台管理员）
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller

---
# Gateway（集群运维）
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: ingress-nginx
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-tls
    allowedRoutes:
      namespaces:
        from: All

---
# HTTPRoute（应用开发者 - API 路由）
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: production
spec:
  parentRefs:
  - name: public-gateway
    namespace: ingress-nginx
  hostnames:
  - api.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1
    backendRefs:
    - name: api-v1
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /v2
    backendRefs:
    - name: api-v2
      port: 80
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /

---
# HTTPRoute（流量分割 - 金丝雀发布）
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: canary-route
  namespace: production
spec:
  parentRefs:
  - name: public-gateway
    namespace: ingress-nginx
  hostnames:
  - app.example.com
  rules:
  - backendRefs:
    - name: app-stable
      port: 80
      weight: 90
    - name: app-canary
      port: 80
      weight: 10
```

---

## 19.5 NetworkPolicy 实战

### 19.5.1 默认拒绝策略（零信任起点）

```yaml
# 默认拒绝所有入站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Ingress

---
# 默认拒绝所有出站流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Egress
```

### 19.5.2 微服务网络策略模板

```yaml
# 1. Frontend：只允许外部 Ingress 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080

---
# 2. Backend：只允许 frontend 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: production
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
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53

---
# 3. Database：只允许 backend 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 3306
```

### 19.5.3 NetworkPolicy 局限性

| 局限 | 说明 | 解决方案 |
|------|------|---------|
| 只能限制 Pod 级别 | 无法限制到容器级别 | 使用 Cilium L7 策略 |
| 只能控制 L3/L4 | 无法控制 HTTP 路径 | 使用 Cilium L7 / Istio |
| 不支持日志 | 无法查看被阻断的流量 | 使用 Cilium Hubble |
| 依赖 CNI 实现 | 不是所有 CNI 都支持 | 使用 Calico/Cilium |
| 无流量统计 | 无法分析流量大小 | 使用 Cilium Hubble |

---

## 19.6 K8s DNS

### 19.6.1 CoreDNS 工作原理

```
Pod 发起 DNS 查询
    │
    ▼
/etc/resolv.conf（由 kubelet 配置）
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
    │
    ▼
CoreDNS Service (ClusterIP: 10.96.0.10)
    │
    ▼
CoreDNS Pod (kube-system)
    │
    ├─ K8s 插件：解析 cluster.local 域名
    │   ├─ <service>.<namespace>.svc.cluster.local → ClusterIP
    │   ├─ <pod-ip>.<namespace>.pod.cluster.local → Pod IP
    │   └─ <statefulset-pod>.<service>.<namespace>.svc.cluster.local → Pod IP
    │
    ├─ forward 插件：转发到上游 DNS
    │   └─ /etc/resolv.conf 或指定服务器
    │
    └─ hosts/cache 插件：本地缓存
```

```bash
# 查看 CoreDNS 配置
kubectl get configmap coredns -n kube-system -o yaml

# 测试 DNS 解析
kubectl run -it --rm debug --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default

# 自定义 DNS 配置（Pod 级别）
apiVersion: v1
kind: Pod
spec:
  dnsPolicy: "None"
  dnsConfig:
    nameservers:
      - 10.96.0.10
    searches:
      - default.svc.cluster.local
      - svc.cluster.local
    options:
      - name: ndots
        value: "2"
```

---

## 19.7 网络故障排查

### 19.7.1 排查工具箱

```bash
# ========== 基础连通性 ==========
# Pod 内测试
kubectl exec -it <pod> -- ping <target-ip>
kubectl exec -it <pod> -- wget -qO- <target>:<port>
kubectl exec -it <pod> -- curl -v <target>:<port>

# ========== DNS 排查 ==========
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup kubernetes.default
kubectl exec -it <pod> -- nslookup <service>.<namespace>

# 查看 CoreDNS 日志
kubectl logs -n kube-system -l k8s-app=kube-dns

# ========== Service 排查 ==========
kubectl get svc <service> -o wide
kubectl get endpoints <service>
kubectl get endpointslices -l kubernetes.io/service-name=<service>

# 测试 Service IP
kubectl run -it --rm debug --image=busybox -- wget -qO- <cluster-ip>:<port>

# ========== CNI 排查 ==========
# 查看节点路由
kubectl exec -it <pod> -- ip route
kubectl exec -it <pod> -- ip addr

# 节点上查看
ip route
ip addr show cni0
ip addr show flannel.1

# ========== iptables/nftables ==========
# 查看 kube-proxy 规则
iptables -t nat -L KUBE-SERVICES -n | head -20
iptables -t nat -L KUBE-POSTROUTING -n

# ========== Cilium 排查 ==========
cilium status
cilium endpoint list
cilium endpoint get <endpoint-id>
cilium monitor  # 实时流量监控

# Hubble 观测
hubble observe --namespace production
hubble observe --pod <pod-name> --follow
```

### 19.7.2 常见网络问题排查流程

```
问题：Pod A 无法访问 Pod B

步骤 1：确认 Pod IP 是否正确
kubectl get pod <pod-b> -o wide
kubectl exec -it <pod-a> -- ping <pod-b-ip>
→ 如果不通，检查 CNI 配置

步骤 2：检查 NetworkPolicy
kubectl get networkpolicies --all-namespaces
→ 如果存在策略，检查是否阻止了流量

步骤 3：检查 Service
kubectl get svc <service>
kubectl get endpoints <service>
→ 如果 endpoints 为空，检查 selector 和 Pod 标签

步骤 4：检查 DNS
kubectl exec -it <pod-a> -- nslookup <service>.<namespace>
→ 如果解析失败，检查 CoreDNS

步骤 5：检查防火墙/安全组
→ 云厂商安全组、节点防火墙
```

---

## 19.8 本章实验

### 实验 19.1：CNI 插件对比测试（20 分钟）

```bash
# 步骤 1：查看当前 CNI
kubectl get pods -n kube-system | grep -E "flannel|calico|cilium"

# 步骤 2：测试 Pod 跨节点通信
kubectl run test1 --image=busybox -n default -- sleep 3600
kubectl run test2 --image=busybox -n default -- sleep 3600

# 获取 IP
kubectl get pods -o wide

# 在 test1 中 ping test2
kubectl exec -it test1 -- ping <test2-ip>

# 清理
kubectl delete pod test1 test2
```

### 实验 19.2：NetworkPolicy 隔离测试（25 分钟）

```bash
# 步骤 1：创建测试命名空间
kubectl create ns net-test

# 步骤 2：部署应用
kubectl run frontend --image=busybox -n net-test -- sleep 3600
kubectl run backend --image=busybox -n net-test -- sleep 3600
kubectl run database --image=busybox -n net-test -- sleep 3600

# 步骤 3：应用默认拒绝
kubectl apply -n net-test -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF

# 步骤 4：测试（应全部失败）
kubectl exec -n net-test frontend -- wget -qO- --timeout=5 backend || echo "BLOCKED"

# 步骤 5：添加策略
kubectl apply -n net-test -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
spec:
  podSelector:
    matchLabels:
      run: backend
  ingress:
  - from:
    - podSelector:
        matchLabels:
          run: frontend
EOF

# 步骤 6：验证
kubectl exec -n net-test frontend -- wget -qO- --timeout=5 backend

# 清理
kubectl delete namespace net-test
```

### 实验 19.3：Ingress + TLS 配置（25 分钟）

```bash
# 步骤 1：安装 NGINX Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml

# 步骤 2：等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=120s

# 步骤 3：创建测试应用
kubectl create deployment echo --image=ealen/echo-server
kubectl expose deployment echo --port=80

# 步骤 4：创建自签名证书
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=echo.example.com"
kubectl create secret tls echo-tls --cert=tls.crt --key=tls.key

# 步骤 5：创建 Ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-ingress
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - echo.example.com
    secretName: echo-tls
  rules:
  - host: echo.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: echo
            port:
              number: 80
EOF

# 步骤 6：测试
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
curl -k -H "Host: echo.example.com" https://$NODE_IP

# 清理
kubectl delete deployment echo
kubectl delete service echo
kubectl delete ingress echo-ingress
kubectl delete secret echo-tls
```

---

## 19.9 网络性能调优实战

### 19.9.1 CNI 性能基准测试

**测试工具与指标**：

| 工具 | 用途 | 关键指标 |
|------|------|----------|
| iperf3 | 带宽测试 | 吞吐量 (Gbps) |
| netperf | 延迟测试 | RTT (μs) |
| sockperf | 套接字性能 | P99 延迟 |
| k8s-netperf | K8s 专用 | Pod-to-Pod 性能 |

**iperf3 测试示例**：

```bash
# 服务端 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: iperf-server
spec:
  containers:
  - name: iperf
    image: networkstatic/iperf3
    args: ["-s"]
EOF

# 客户端 Pod（跨节点测试）
kubectl run iperf-client --rm -it --image=networkstatic/iperf3 \
  --overrides='{"spec":{"affinity":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchLabels":{"app":"iperf"}},"topologyKey":"kubernetes.io/hostname"}]}}}}' \
  -- -c iperf-server -t 30 -i 1 -P 4

# 典型结果分析：
# 同节点 Pod: ~40-50 Gbps (veth 直连)
# 跨节点 Pod (VXLAN): ~5-10 Gbps (封装开销)
# 跨节点 Pod (BGP): ~8-15 Gbps (无封装)
# 跨可用区: ~2-5 Gbps (物理网络限制)
```

### 19.9.2 内核网络调优参数

```bash
# sysctl 网络优化（在所有节点上执行）
cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-network.conf
# 连接跟踪优化
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=86400

# TCP 性能优化
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8096
net.ipv4.ip_local_port_range=1024 65535

# 网卡队列优化
net.core.netdev_max_backlog=65536
net.core.rmem_max=16777216
net.core.wmem_max=16777216

# ARP 缓存优化
net.ipv4.neigh.default.gc_thresh1=8192
net.ipv4.neigh.default.gc_thresh2=32768
net.ipv4.neigh.default.gc_thresh3=65536
EOF
sudo sysctl --system
```

### 19.9.3 Service 性能优化

**ExternalTrafficPolicy 选择**：

```
┌─────────────────────────────────────────────────────────────┐
│ ExternalTrafficPolicy=Cluster（默认）                        │
│                                                              │
│  External ──► Node1 ──► kube-proxy ──► 可能转发到 Node2     │
│                                                              │
│  优点：负载均衡均匀，所有节点都能接收流量                      │
│  缺点：额外一跳，SNAT 隐藏真实源 IP                           │
├─────────────────────────────────────────────────────────────┤
│ ExternalTrafficPolicy=Local                                  │
│                                                              │
│  External ──► Node1 ──► Pod（必须在该节点上）                │
│                                                              │
│  优点：无额外跳转，保留真实源 IP                               │
│  缺点：负载可能不均，节点无 Pod 时流量丢弃                      │
└─────────────────────────────────────────────────────────────┘
```

**使用场景**：
- `Cluster`：通用场景，对外部可见性无要求
- `Local`：需要真实客户端 IP（如日志分析、地理位置）、会话保持、性能敏感

**拓扑感知路由（Topology Aware Routing）**：
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  annotations:
    service.kubernetes.io/topology-mode: Auto  # 或 "Preferred"
spec:
  selector:
    app: backend
  ports:
  - port: 80
```

### 19.9.4 DNS 性能优化

```yaml
# CoreDNS 性能调优
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        
        # 增加缓存 TTL
        cache 30 {
            success 9984 300   # 成功响应缓存 5 分钟
            denial 9984 60     # NXDOMAIN 缓存 1 分钟
        }
        
        # 负载均衡策略
        loadbalance round_robin
        
        # 使用节点本地缓存（NodeLocal DNSCache）
        # 部署 NodeLocal DNSCache DaemonSet
        forward . /etc/resolv.conf {
            max_concurrent 1000
        }
        
        prometheus :9153
        forward . /etc/resolv.conf
        reload
    }
```

**NodeLocal DNSCache**：
```bash
# 部署 NodeLocal DNSCache
kubectl apply -f https://github.com/kubernetes/kubernetes/raw/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml

# 效果：
# - DNS 查询从 Pod → 本地缓存（127.0.0.1:53）
# - 减少跨节点 DNS 流量
# - 降低 CoreDNS 负载
# - 减少 DNS 查询延迟（从 ~5ms 降到 ~0.1ms）
```

---

## 19.10 生产环境网络故障排查工具箱

### 19.10.1 分层排查速查表

| 层次 | 检查命令 | 常见问题 |
|------|----------|----------|
| **Pod** | `kubectl get pod -o wide` | Pod 未 Running |
| **Service** | `kubectl get endpoints` | Endpoint 为空 |
| **DNS** | `nslookup / dig` | CoreDNS 故障 |
| **NetworkPolicy** | `kubectl get networkpolicy` | 策略阻断 |
| **CNI** | `ip addr / ip route` | 路由缺失 |
| **节点网络** | `iptables -L -n` | 防火墙规则 |
| **物理网络** | `ping / traceroute` | 网络分区 |

### 19.10.2 高级排查命令

```bash
# 1. 查看 Pod 网络命名空间
kubectl exec -it <pod> -- nsenter -t 1 -n ip addr

# 2. 查看 CNI 分配的 IP
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName'

# 3. 检查 iptables 规则（kube-proxy iptables 模式）
sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers | head -20

# 4. 检查 IPVS 规则（kube-proxy ipvs 模式）
sudo ipvsadm -Ln | grep <service-ip>

# 5. 检查 CNI 链路和路由
ip link show cni0
ip route show | grep <pod-cidr>

# 6. 抓包分析
kubectl debug -it <pod> --image=nicolaka/netshoot -- tcpdump -i eth0 -n port 80

# 7. 使用 Cilium 诊断（如使用 Cilium）
cilium endpoint list
cilium monitor --related-to <endpoint-id>
cilium bpf lb list
```

### 19.10.3 典型故障案例

**案例 1：CNI 未正确配置导致 Pod 无法通信**

```bash
# 现象：Pod 在同一节点可通信，跨节点不可通信
# 诊断：
ip route show  # 查看是否有到其他节点 Pod CIDR 的路由
# CNI 配置（Calico BGP）
calicoctl node status  # 检查 BGP 邻居状态

# 修复：
# Flannel: 检查 UDP 8472 端口
# Calico: 检查 BGP 邻居是否建立
# Cilium: 检查隧道模式配置
```

**案例 2：conntrack 表满导致连接失败**

```bash
# 现象：大量连接超时，dmesg 显示 "nf_conntrack: table full"
# 诊断：
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 修复：
echo 2097152 | sudo tee /proc/sys/net/netfilter/nf_conntrack_max
# 或分析 conntrack 表找异常连接
conntrack -L | awk '{print $3}' | sort | uniq -c | sort -rn | head
```

**案例 3：MTU 不匹配导致大包丢失**

```bash
# 现象：小数据包正常，大数据包丢失
# 诊断：
ping -M do -s 1472 <pod-ip>  # 测试 MTU
# 如果失败，说明 MTU 设置有问题

# 修复：
# CNI 配置中设置正确 MTU
# VXLAN: 物理网卡 MTU - 50 bytes
# IPIP: 物理网卡 MTU - 20 bytes
```

---

## 19.11 本章练习题

### 选择题

1. **Flannel 的默认后端模式是什么？**
   - A. host-gw
   - B. VXLAN
   - C. UDP
   - D. BGP

2. **Calico 的 BGP 模式相比 VXLAN 模式的优势是什么？**
   - A. 配置更简单
   - B. 无封装开销，性能更高
   - C. 不需要物理网络支持
   - D. 支持更多功能

3. **Cilium 使用什么技术实现高性能网络？**
   - A. iptables
   - B. eBPF
   - C. OVS
   - D. VPP

4. **Gateway API 相比传统 Ingress 的主要优势是什么？**
   - A. 性能更高
   - B. 角色分离（基础设施/运维/开发者）
   - C. 配置更简单
   - D. 支持更多协议

### 简答题

1. 对比 Flannel、Calico 和 Cilium 三种 CNI 插件的架构差异。各自的优缺点和适用场景是什么？

2. 解释 NetworkPolicy 的默认拒绝策略。为什么这是零信任网络的起点？

3. 描述 Service 的 ExternalTrafficPolicy=Local 和 Cluster 的区别。在什么场景下应该选择 Local？

4. K8s DNS 解析的完整流程是什么？如果 Pod 无法解析 Service 域名，应该如何排查？

### 实践题

1. **CNI 切换实验**（30 分钟）：
   - 记录当前 CNI 类型和配置
   - 如果当前是 Flannel，尝试了解切换到 Calico 的步骤
   - 测试 Pod 跨节点通信

2. **网络策略设计**（30 分钟）：
   - 设计一个三层微服务架构的网络策略（frontend → backend → database）
   - 只允许 frontend 访问 backend，backend 访问 database
   - 所有 Pod 都可以访问 DNS
   - 在测试集群中部署并验证

3. **Ingress 安全加固**（25 分钟）：
   - 部署一个应用并配置 Ingress
   - 添加 TLS 终止
   - 配置限速、HSTS、安全头
   - 测试各项安全配置是否生效

---

## 19.12 网络架构决策指南

### 19.12.1 CNI 选型决策树

```
集群规模与需求 → 推荐 CNI

< 50 节点，简单需求    → Flannel (VXLAN)
< 50 节点，安全需求    → Calico (BGP + NetworkPolicy)
> 100 节点，高性能     → Cilium (eBPF)
> 100 节点，多集群     → Cilium ClusterMesh
混合云/跨云           → Calico (跨子网 BGP) / Submariner
Windows 节点          → Calico (Windows 支持)
需要 L7 可观测性       → Cilium (Hubble)
需要 Service Mesh      → Cilium + Istio / 纯 Cilium Service Mesh
严格安全合规           → Cilium (eBPF + Tetragon)
```

### 19.12.2 Service 类型选择指南

| 访问来源 | 推荐类型 | 说明 |
|----------|----------|------|
| 集群内部 | ClusterIP | 默认，最稳定 |
| 节点本地测试 | NodePort | 端口范围 30000-32767 |
| 生产外部流量 | LoadBalancer | 云厂商提供，有成本 |
| 需要固定 IP | Headless + ExternalIPs | 直接访问 Pod IP |
| 需要会话保持 | ClusterIP + SessionAffinity | 基于客户端 IP |
| 需要真实客户端 IP | LoadBalancer + Local | ExternalTrafficPolicy=Local |
| 外部 DNS 名称 | ExternalName | CNAME 到外部服务 |

---

## 19.13 网络可观测性实战

### 19.13.1 Hubble 与 Cilium 网络观测

```bash
# Hubble CLI 安装与使用
hubble status
hubble observe --namespace production --follow

# 查看被丢弃的流量（安全分析）
hubble observe --verdict DROPPED --namespace production

# 查看 HTTP 请求详情
hubble observe --protocol http --http-method GET

# 导出流量拓扑到文件
hubble observe -o json --last 1000 > traffic.json
jq -r '[.[] | {src: .source.identity, dst: .destination.identity, verdict: .verdict}] | unique' traffic.json
```

### 19.13.2 CoreDNS 观测与故障排查

```bash
# CoreDNS 性能指标
kubectl top pod -n kube-system -l k8s-app=kube-dns

# DNS 查询日志（启用 log 插件）
kubectl logs -n kube-system -l k8s-app=kube-dns | grep "NOERROR\|NXDOMAIN\|SERVFAIL"

# DNS 延迟直方图（Prometheus）
# coredns_dns_request_duration_seconds_bucket
# coredns_forward_request_duration_seconds_bucket

# 检测 DNS 放大攻击
kubectl logs -n kube-system -l k8s-app=kube-dns | \
  awk '{print $4}' | sort | uniq -c | sort -rn | head
```

---

## 19.14 网络设计模式

### 19.14.1 命名空间网络隔离模式

```
模式 1: 共享网络（默认）
  所有命名空间共享集群网络
  └── NetworkPolicy 实现逻辑隔离
  └── 适用: 小型团队，开发测试环境

模式 2: 子网隔离
  每个命名空间分配独立 CIDR
  └── Cilium / Calico 支持
  └── 适用: 多租户，合规要求

模式 3: VPC 隔离（云厂商）
  每个命名空间映射到独立子网/VPC
  └── EKS VPC CNI / Azure CNI
  └── 适用: 严格隔离，金融政务
```

### 19.14.2 出口流量控制模式

```yaml
# 模式 A: 默认允许，显式拒绝
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-external
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress: []
  # 需要配合允许规则使用（KYverno 辅助生成）

---
# 模式 B: 默认拒绝，白名单放行（推荐）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
  - to:
    - podSelector: {}  # 允许同命名空间通信
```

---

## 19.10 本章小结

| 主题 | 核心要点 |
|------|---------|
| **Flannel** | VXLAN Overlay，简单但功能有限 |
| **Calico** | BGP + IPIP/VXLAN，功能全面 |
| **Cilium** | eBPF 革命，高性能 + 可观测性 |
| **Service** | ClusterIP/NodePort/LoadBalancer/Headless |
| **Ingress** | L7 路由，注解配置，安全加固 |
| **Gateway API** | 下一代 Ingress，角色分离 |
| **NetworkPolicy** | 零信任起点，默认拒绝 |
| **DNS** | CoreDNS，集群内服务发现 |
| **故障排查** | ping/curl/nslookup/iptables/cilium |

**推荐阅读**：
- K8s 网络模型：https://kubernetes.io/docs/concepts/cluster-administration/networking/
- Cilium 文档：https://docs.cilium.io/
- Calico 文档：https://docs.tigera.io/
- Gateway API：https://gateway-api.sigs.k8s.io/

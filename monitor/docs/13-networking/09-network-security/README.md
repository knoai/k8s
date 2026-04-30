# 网络安全与零信任

> 在云原生环境中，网络安全从边界防御转向微分段和零信任。理解 NetworkPolicy、服务网格安全、加密通信，是构建安全基础设施的核心。

---

## 1. K8s 网络安全模型

```
传统安全模型 vs 零信任模型：

传统（边界安全）：             零信任（永不信任，始终验证）：
  ┌─────────┐                   ┌─────────┐
  │ 防火墙  │ ← 边界            │ 每个 Pod │ ← 都需验证
  └────┬────┘                   └────┬────┘
       │                            │
  内部 = 信任                    内部 ≠ 自动信任
                                基于身份验证和授权

K8s 中的零信任层次：
  1. 网络层: NetworkPolicy（L3/L4）
  2. 服务网格: mTLS + 授权策略（L4/L7）
  3. 应用层: 认证/授权/审计（OAuth/OIDC/RBAC）
  4. 运行时: eBPF 安全监控
```

---

## 2. NetworkPolicy

### 2.1 核心概念

```
默认行为：K8s 中所有 Pod 之间网络是互通的（开放）

NetworkPolicy 通过标签选择 Pod，定义允许/拒绝的流量规则：

┌─────────────────────────────────────────────────────────────┐
│                    NetworkPolicy 模型                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  spec.podSelector: 选择受策略影响的 Pod                      │
│                                                             │
│  spec.policyTypes:                                          │
│    - Ingress: 入站规则                                       │
│    - Egress: 出站规则                                        │
│                                                             │
│  规则逻辑：白名单，未匹配的流量被拒绝                          │
│  无 NetworkPolicy = 全部允许                                 │
│  空 NetworkPolicy = 全部拒绝                                 │
│                                                             │
│  关键限制（标准 NetworkPolicy）：                             │
│  - 无法做日志                                                │
│  - 无法拒绝（只能允许）                                       │
│  - 无法做 L7 过滤                                            │
│  - 无法集群级策略                                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 NetworkPolicy 配置

```yaml
# 1. 默认拒绝所有入站
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}  # 选择所有 Pod
  policyTypes:
    - Ingress
  # 无 ingress 规则 = 拒绝所有入站
---
# 2. 允许特定 Pod 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend
spec:
  podSelector:
    matchLabels:
      app: backend
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
---
# 3. 允许跨 Namespace 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
spec:
  podSelector:
    matchLabels:
      app: web
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
        - podSelector:
            matchLabels:
              app: prometheus
---
# 4. 允许 DNS 出站
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# 5. 完整的出站控制
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restricted-egress
spec:
  podSelector:
    matchLabels:
      app: sensitive-app
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: api-gateway
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # 允许访问数据库
    - to:
        - podSelector:
            matchLabels:
              app: database
      ports:
        - protocol: TCP
          port: 3306
    # 允许访问 DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

### 2.3 NetworkPolicy 实现差异

| CNI | 实现方式 | 特点 |
|-----|---------|------|
| Calico | iptables/eBPF | 最成熟，支持 GlobalNetworkPolicy |
| Cilium | eBPF | 性能最好，支持 L7 |
| Weave | iptables | 功能基础 |
| Antrea | OVS | VMware 生态 |
| Flannel | 不支持 | 需要配合 Canal |

---

## 3. Cilium 高级网络安全

### 3.1 CiliumNetworkPolicy

```yaml
# Cilium 特有的强大策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-security
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    # L4 规则
    - fromEndpoints:
        - matchLabels:
            app: web
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              # 只允许 GET /api/ 和 POST /api/users
              - method: GET
                path: "/api/.*"
              - method: POST
                path: "/api/users"
                # HTTP 头过滤
                headers:
                  - name: Content-Type
                    presence: true
    # 基于 ServiceAccount
    - fromEntities:
        - cluster
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
---
# 拒绝策略（Cilium 支持 deny）
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: block-bad-actors
spec:
  endpointSelector:
    matchLabels:
      app: critical
  ingressDeny:
    - fromEndpoints:
        - matchLabels:
            app: untrusted
```

### 3.2 Cilium 安全身份模型

```
Cilium 使用身份而非 IP 做安全策略：

Pod 启动 → Cilium 分配身份（基于标签）→ 策略基于身份执行

┌─────────────────────────────────────────────────────────────┐
│                    Cilium Identity                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Identity 1: app=frontend, team=web, env=prod               │
│     │                                                       │
│     │  可以访问 Identity 2 的 8080 端口                       │
│     ▼                                                       │
│  Identity 2: app=backend, team=api, env=prod                │
│                                                             │
│  如果 Pod IP 变化（如重启），身份不变，策略仍然有效            │
│                                                             │
│  查看身份：                                                  │
│  cilium endpoint list                                       │
│  cilium identity list                                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 服务网格安全（Istio）

### 4.1 mTLS（双向 TLS）

```
Istio mTLS 模式：

┌─────────────────────────────────────────────────────────────┐
│                    mTLS 模式对比                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  PERMISSIVE (宽容模式)                                       │
│  ─────────────────────                                       │
│  同时接受明文和 TLS，便于渐进迁移                              │
│                                                             │
│  STRICT (严格模式)                                          │
│  ─────────────────                                          │
│  强制 mTLS，拒绝明文连接                                      │
│                                                             │
│  DISABLE (禁用)                                             │
│  ───────────────                                            │
│  明文通信，不使用 mTLS                                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

```yaml
# 强制整个 Namespace 使用 mTLS
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT
---
# 授权策略（L4/L7 访问控制）
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: api-policy
  namespace: production
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
    # 只允许来自 frontend 的 GET 请求
    - from:
        - source:
            principals: ["cluster.local/ns/production/sa/frontend"]
      to:
        - operation:
            methods: ["GET"]
            paths: ["/api/*"]
    # 允许来自 admin 的任何请求
    - from:
        - source:
            principals: ["cluster.local/ns/production/sa/admin"]
```

### 4.2 证书管理

```bash
# Istio 证书轮转
istioctl proxy-config secret <pod> -n <namespace>

# 查看证书过期时间
kubectl exec <pod> -c istio-proxy -- cat /etc/certs/cert-chain.pem | openssl x509 -noout -dates

# cert-manager 自动证书管理
# 用于 Ingress TLS 和 Istio Gateway
```

---

## 5. 网络加密

### 5.1 WireGuard

```
WireGuard: 现代、简洁、高性能的 VPN/加密协议

K8s 中的应用：
  - Cilium: 原生支持 WireGuard 加密 Pod 间通信
  - Tailscale: 基于 WireGuard 的网络连接

Cilium WireGuard 配置：
  helm upgrade cilium cilium/cilium --namespace kube-system \
    --set encryption.enabled=true \
    --set encryption.type=wireguard

# 验证加密
kubectl exec -it <pod> -- tcpdump -i any -n
# 如果看到加密后的 UDP 包，说明 WireGuard 生效
```

### 5.2 IPSec

```
IPSec: 传统的 IP 层加密

K8s 中的应用：
  - Cilium: 支持 IPSec 加密
  - Calico: 支持 WireGuard 和 IPSec

Cilium IPSec 配置：
  # 创建密钥
  kubectl create -n kube-system secret generic cilium-ipsec-keys \
    --from-literal=keys="3+ rfc4106(gcm(aes)) $(echo $(dd if=/dev/urandom count=20 bs=1 2> /dev/null | xxd -p -c 64)) 128"
  
  helm upgrade cilium cilium/cilium --namespace kube-system \
    --set encryption.enabled=true \
    --set encryption.type=ipsec
```

---

## 6. 网络安全审计与合规

### 6.1 流量审计日志

```yaml
# Cilium 审计日志
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: audit-policy
spec:
  endpointSelector: {}
  ingressDeny:
    - {}
  ingress:
    - fromEntities:
        - all
      # 记录日志而不是丢弃
      # 使用 Cilium 的 monitor/hubble 流日志
```

```bash
# Hubble 流日志可用于安全审计
# 查看所有被拒绝的流量
hubble observe --type drop --since 1h

# 查看特定 Pod 的所有连接
hubble observe --pod sensitive-app --since 24h -o json

# 导出审计日志
hubble observe --since 24h -o json > audit-log.json
```

### 6.2 网络安全检查清单

```
□ 默认拒绝所有流量，按需开放
□ 每个 Namespace 有默认 deny 策略
□ 最小权限原则（只允许必要的端口）
□ 敏感应用启用 mTLS
□ Pod 间通信加密（WireGuard/IPSec）
□ 启用网络审计日志
□ 定期审查 NetworkPolicy
□ 出站流量限制（防止数据外泄）
□ DNS 流量监控（检测 C2 通信）
□ eBPF 运行时安全监控
```

---

## 7. 面试高频题

**Q: NetworkPolicy 的默认行为是什么？**

<details>
<summary>答案</summary>

- **没有 NetworkPolicy**：所有 Pod 默认可以互相通信（开放）
- **有空 NetworkPolicy**（spec 只有 podSelector: {}）：拒绝所有流量
- **有规则 NetworkPolicy**：白名单模式，只匹配规则的流量被允许，其余被拒绝

</details>

**Q: 为什么 Cilium 的 identity-based 策略比 IP-based 更好？**

<details>
<summary>答案</summary>

1. **动态环境适应性**：Pod IP 是动态的，重启后 IP 变化，IP-based 策略失效；identity 基于标签，Pod 重建后身份不变
2. **规模性**：IP 策略需要为每个 Pod 维护规则，大规模时 iptables 规则爆炸；identity 策略数量与身份种类成正比，不是 Pod 数量
3. **安全性**：IP 可以被伪造，身份由 Cilium Agent 管理，更可信

</details>

**Q: mTLS 解决了什么问题？**

<details>
<summary>答案</summary>

1. **身份验证**：确保通信双方是预期的服务，而非伪造者
2. **加密**：防止数据在传输中被窃听
3. **完整性**：防止数据被篡改

在云原生中特别重要，因为 Pod IP 是动态的，传统基于 IP 的信任模型不适用。

</details>

---

## 参考资源

- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Cilium Security](https://docs.cilium.io/en/stable/security/)
- [Istio Security](https://istio.io/latest/docs/concepts/security/)
- [NIST Zero Trust Architecture](https://www.nist.gov/publications/zero-trust-architecture)

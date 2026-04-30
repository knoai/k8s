# 05 - 多租户与隔离

多租户（Multitenancy）是平台工程的核心挑战之一。在一个共享的 K8s 集群中，
如何让多个团队安全、公平、高效地共存？本章覆盖命名空间隔离、
资源配额、网络策略、vCluster 等关键技术。

## 学习目标

1. 理解多租户的隔离层次（软隔离 vs 硬隔离）
2. 掌握 ResourceQuota 和 LimitRange 的配置
3. 学会使用 NetworkPolicy 实现网络隔离
4. 了解 vCluster 的架构和适用场景
5. 掌握租户间的安全边界设计
6. 理解 Pod Security Standards 和 RBAC 最佳实践

## 核心概念

### 隔离层次

多租户的隔离可以从多个维度实现:

| 层次 | 机制 | 强度 | 适用场景 | 成本 |
|------|------|------|---------|------|
| 逻辑隔离 | 命名空间 + RBAC | 弱 | 同一组织的不同团队 | 低 |
| 资源隔离 | ResourceQuota + LimitRange | 中 | 防止资源争抢 | 低 |
| 网络隔离 | NetworkPolicy | 中 | 防止未授权访问 | 低 |
| 节点隔离 | 节点亲和性/污点 | 强 | 敏感工作负载 | 中 |
| 集群隔离 | 独立集群 / vCluster | 最强 | 不同组织/强合规 | 高 |

**选择原则**: 隔离强度与成本正相关。在满足安全需求的前提下，
选择成本最低的隔离方案。

大多数企业从逻辑隔离开始，逐步增加资源隔离和网络隔离，
只有在强合规场景下才使用集群隔离。

### ResourceQuota 和 LimitRange

**ResourceQuota**: 限制命名空间的总资源使用量
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "50"
    services: "10"
    persistentvolumeclaims: "10"
```

**LimitRange**: 限制单个 Pod/容器的资源范围
```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: team-a-limits
  namespace: team-a
spec:
  limits:
  - default:
      cpu: "1"
      memory: 1Gi
    defaultRequest:
      cpu: "100m"
      memory: 128Mi
    type: Container
```

两者区别:
- ResourceQuota 限制命名空间总资源（所有 Pod 加起来）
- LimitRange 限制单个 Pod 资源（每个 Pod 独立）

### NetworkPolicy

NetworkPolicy 实现命名空间级别的网络隔离:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: team-a
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: team-a
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
  policyTypes:
  - Ingress
```

**注意**: NetworkPolicy 需要 CNI 支持（Calico、Cilium 支持，Flannel 不支持）。

**最佳实践**:
- 默认 deny-all（拒绝所有流量）
- 按需开放特定端口和来源
- egress 规则限制出站流量（防止数据泄露）
- 使用命名空间选择器实现跨命名空间访问控制

### vCluster

vCluster 在共享集群上创建虚拟集群，提供更强的隔离:

```bash
# 安装 vcluster CLI
curl -s -L https://github.com/loft-sh/vcluster/releases/latest | sed -n 's/.*href="\([^"]*vcluster-linux-amd64\).*//p' | xargs -I {} curl -s -L {} -o vcluster && chmod +x vcluster

# 创建虚拟集群
vcluster create team-a -n vcluster-team-a
```

**vCluster 架构**:
```
Physical Cluster
├── vcluster-team-a (Namespace)
│   ├── vcluster (Control Plane: API Server, Controller Manager)
│   └── Syncer (将虚拟资源同步到物理集群)
├── vcluster-team-b (Namespace)
│   └── vcluster
```

**优势**:
- 每个团队有自己的 API Server，可以自定义 CRD
- 强隔离，团队间互不干扰
- 资源利用率高于独立集群
- 快速创建和销毁（秒级）

**劣势**:
- 额外的同步开销
- 某些高级功能受限（如某些准入控制器）
- 调试复杂度增加

### Pod Security Standards

K8s 内置的 Pod 安全标准:

| 级别 | 描述 | 适用场景 |
|------|------|---------|
| Privileged | 无限制 | 系统组件、管理员 |
| Baseline | 最小限制，防止已知漏洞 | 大多数应用 |
| Restricted | 最严格，遵循 Pod 加固最佳实践 | 安全敏感应用 |

```yaml
# 在命名空间上启用 Restricted 策略
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

## 模块内容

### 命名空间隔离

文件: `namespace-isolation.md`

命名空间是 K8s 多租户的基础隔离单元:
- 资源隔离: ResourceQuota、LimitRange
- 权限隔离: RBAC（Role/RoleBinding）
- 网络隔离: NetworkPolicy
- 资源命名隔离: 同一命名空间内资源名唯一

### 资源配额管理

文件: `resource-quotas.md`

配额策略设计:
- 按团队历史使用量 + 20% 增长预留
- 设置硬限制（Hard）和软限制（Soft，可临时超限）
- 定期审查配额使用情况，动态调整
- 配额告警: 当使用率达到 80% 时通知团队

### 网络隔离

文件: `network-isolation.md`

NetworkPolicy 最佳实践:
- 默认拒绝所有流量（deny-all）
- 按需开放特定端口和来源
- egress 规则限制出站流量（防止数据泄露）
- 使用命名空间选择器实现跨命名空间访问

### vCluster 实践

文件: `vcluster-practice.md`

vCluster 适用场景:
- 开发/测试环境（快速创建和销毁）
- 多团队共享生产集群（需要强隔离）
- 临时项目（无需独立集群）
- 多版本 K8s 测试

## 面试常见问题

**Q: 软隔离和硬隔离的区别？**

A:
- **软隔离**（命名空间 + RBAC）: 共享内核，共享节点，成本低
- **硬隔离**（独立集群 / vCluster）: 独立控制面，成本高但隔离强

选择: 同一组织内用软隔离，不同组织或强合规场景用硬隔离。

**Q: NetworkPolicy 的局限性？**

A:
1. 需要 CNI 支持（Flannel 不支持）
2. 只支持 L3/L4，不支持 L7（HTTP 路径）
3. 规则复杂时难以调试
4. 无法阻止节点级别的访问（如节点上直接 curl）
5. 大规模集群中规则数量过多可能影响性能

**Q: vCluster 和独立集群如何选择？**

A:
- **vCluster**: 成本低、管理简单、适合大多数场景
- **独立集群**: 完全隔离、无限制、适合强合规场景

决策矩阵:
- 同一组织 + 成本敏感 → vCluster
- 不同组织 + 强合规 → 独立集群
- 快速实验 + 临时使用 → vCluster

**Q: 多租户下的安全最佳实践？**

A:
1. 每个团队独立的命名空间
2. 默认拒绝的网络策略
3. Pod Security Standards（Restricted）
4. 资源配额防止 DOS
5. 审计日志记录所有操作
6. 定期安全扫描（镜像、配置）
7. RBAC 最小权限原则
8. Secret 加密（KMS / Sealed Secrets）

**Q: ResourceQuota 和 LimitRange 的区别？**

A:
- **ResourceQuota**: 限制命名空间的总资源（所有 Pod 加起来不能超过）
- **LimitRange**: 限制单个 Pod/容器的资源（每个 Pod 不能超过）

两者配合使用: ResourceQuota 防止团队过度使用，LimitRange 防止单个应用耗尽资源。

**Q: 如何处理资源争抢（Noisy Neighbor）？**

A:
1. **ResourceQuota**: 限制命名空间总资源
2. **LimitRange**: 限制单个 Pod 资源
3. **QoS 类别**: 设置 Guaranteed/Burstable/BestEffort
4. **PriorityClass**: 高优先级 Pod 优先调度
5. **Cgroup 限制**: 内核级别的资源限制

**Q: vCluster 的性能开销？**

A:
- 控制面: 虚拟 API Server 需要额外内存（约 100-200MB）
- 同步: Syncer 将虚拟资源同步到物理集群，有轻微延迟
- 网络: 虚拟 Pod 通过 Syncer 路由，延迟增加 < 1ms
- 总体: 对于一般应用，性能影响可忽略

## 参考资源

- [K8s 多租户指南](https://kubernetes.io/docs/concepts/security/multi-tenancy/)
- [vCluster 文档](https://www.vcluster.com/docs/)
- [NetworkPolicy 详解](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [RBAC 最佳实践](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## 多租户实践进阶

### 租户 onboarding 流程

新团队加入平台的流程:

```
1. 申请命名空间
   → 提交工单（团队名、负责人、预估资源）
   
2. 平台团队审批
   → 检查命名冲突、资源充足性
   
3. 自动创建资源
   → 命名空间 + ResourceQuota + LimitRange
   → 默认 NetworkPolicy（deny-all）
   → RBAC Role/RoleBinding
   → ServiceAccount
   
4. 团队接入
   → 提供 kubeconfig
   → 提供平台使用文档
   → 安排培训
```

### 资源配额管理策略

**动态配额调整**:
```bash
# 监控配额使用率
kubectl get resourcequota -A --output=jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .status.used}{@key}{"="}{@value}{" "}{end}{"\n"}{end}'

# 当使用率达到 80% 时通知团队
# 当使用率达到 100% 时阻止新 Pod 创建
```

**配额模板（按团队规模）**:

| 团队规模 | CPU Request | CPU Limit | 内存 Request | 内存 Limit | Pod 数 |
|---------|------------|-----------|-------------|-----------|--------|
| 小（1-5人） | 10 | 20 | 20Gi | 40Gi | 30 |
| 中（5-15人） | 20 | 40 | 40Gi | 80Gi | 60 |
| 大（15+人） | 50 | 100 | 100Gi | 200Gi | 150 |

### 网络隔离最佳实践

**默认策略模板**:
```yaml
# deny-all.yaml - 默认拒绝所有流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# allow-dns.yaml - 允许 DNS 查询
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
---
# allow-same-namespace.yaml - 允许同命名空间通信
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}
```

**跨命名空间访问控制**:
```yaml
# 允许 team-a 访问 team-b 的 api 服务
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-team-a
  namespace: team-b
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: team-a
    ports:
    - protocol: TCP
      port: 8080
```

### vCluster 生产实践

**vCluster 高可用配置**:
```yaml
# vcluster 的 values.yaml
api:
  image: rancher/k3s:v1.28.2-k3s1
  replicas: 2  # 高可用

syncer:
  replicas: 2

storage:
  persistence: true
  size: 5Gi
```

**vCluster 备份策略**:
```bash
# 备份 vcluster 的 etcd 数据
kubectl exec -n vcluster-team-a vcluster-team-a-0 -- tar czf - /data > vcluster-backup.tar.gz

# 恢复
kubectl cp vcluster-backup.tar.gz vcluster-team-a/vcluster-team-a-0:/tmp/
kubectl exec -n vcluster-team-a vcluster-team-a-0 -- tar xzf /tmp/vcluster-backup.tar.gz -C /
```

### 多租户安全加固

**审计日志配置**:
```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources: ["pods", "services", "secrets"]
- level: Metadata
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: ["roles", "rolebindings"]
```

**镜像安全扫描**:
```bash
# 使用 Trivy 扫描镜像
 trivy image myapp:latest

# 集成到 CI/CD
# 拒绝 HIGH/CRITICAL 漏洞的镜像
```

**运行时安全（Falco）**:
```yaml
# falco-rule.yaml
- rule: Unauthorized Container Privilege Escalation
  desc: Detect privilege escalation in containers
  condition: spawned_process and container and user.uid=0
  output: "Privilege escalation detected"
  priority: CRITICAL
```

## 面试常见问题补充

**Q: 命名空间隔离的局限性？**

A:
1. 共享内核: 一个命名空间的容器可以访问宿主机的内核接口
2. 共享节点: 一个命名空间的 Pod 可能与其他命名空间的 Pod 在同一节点
3. 共享网络: 默认情况下所有 Pod 可以互相通信
4. 共享 etcd: 所有命名空间的数据存储在同一个 etcd 中

解决: 结合 NetworkPolicy、PodSecurity、ResourceQuota 使用。

**Q: 如何实现租户间的成本分摊？**

A:
1. 使用 OpenCost/Kubecost 采集成本数据
2. 按命名空间标签聚合成本
3. 每月生成成本报告
4. 超预算时发送告警

**Q: vCluster 的 etcd 数据如何备份？**

A:
- vCluster 使用 SQLite（默认）或 etcd
- 备份 SQLite 文件: 直接复制 /data/state.db
- 备份 etcd: 使用 etcdctl snapshot save
- 建议: 每天自动备份，保留 7 天


### 多租户成本分摊方案

**OpenCost 集成**:
```bash
# 安装 OpenCost
kubectl apply -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/opencost.yaml

# 查看命名空间成本
kubectl port-forward -n opencost svc/opencost 9003:9003
curl http://localhost:9003/allocation/compute \
  -d 'window=7d' \
  -d 'aggregate=namespace' \
  -d 'accumulate=true'
```

**成本分摊维度**:
- 按命名空间（团队维度）
- 按 Label（项目/环境维度）
- 按 Pod（应用维度）
- 按 StorageClass（存储维度）

**成本告警**:
```yaml
# cost-alert.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cost-alerts
spec:
  groups:
  - name: cost
    rules:
    - alert: NamespaceCostOverBudget
      expr: |
        sum(opencost_allocation_cpu_cost + opencost_allocation_memory_cost) by (namespace)
        > 1000
      for: 1d
      labels:
        severity: warning
      annotations:
        summary: "命名空间 {{ $labels.namespace }} 成本超标"
```

### 多租户网络策略模板

**生产级 NetworkPolicy 模板库**:

```yaml
# templates/allow-ingress-nginx.yaml
# 允许 Nginx Ingress Controller 访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-nginx
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
      podSelector:
        matchLabels:
          app.kubernetes.io/name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
---
# templates/allow-monitoring.yaml
# 允许监控抓取指标
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
spec:
  podSelector:
    matchLabels:
      metrics: enabled
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
      podSelector:
        matchLabels:
          app: prometheus
    ports:
    - protocol: TCP
      port: 9090
---
# templates/allow-egress-internet.yaml
# 允许访问外网（需限制）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-internet
spec:
  podSelector:
    matchLabels:
      internet: allowed
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
```

### HNC (Hierarchical Namespace Controller)

**层级命名空间**:
```yaml
# 创建父命名空间
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
---
# 创建子命名空间
apiVersion: hnc.x-k8s.io/v1alpha2
kind: SubnamespaceAnchor
metadata:
  namespace: team-alpha
  name: dev
---
# 资源自动继承
# team-alpha 的 ResourceQuota 和 NetworkPolicy
# 自动应用到 team-alpha-dev
```

**HNC 优势**:
- 层级权限继承
- 资源配额自动传播
- 网络策略自动传播
- 支持多级嵌套

### 多租户数据库隔离方案

| 方案 | 隔离级别 | 成本 | 复杂度 |
|------|---------|------|--------|
| 单实例多 Schema | 低 | 低 | 低 |
| 单实例多数据库 | 中 | 低 | 中 |
| 多实例（按租户） | 高 | 高 | 中 |
| 独立集群 | 最高 | 最高 | 高 |

**推荐**: SaaS 场景使用单实例多数据库，金融场景使用独立集群。


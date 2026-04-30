# K8s 多租户策略深度解析

> 多租户是平台工程的核心挑战。本节从命名空间隔离到虚拟集群，深入分析 6 种多租户方案、安全边界和实际落地经验。

---

## 一、多租户模型对比

```
多租户需求层次：

Level 1：软隔离（Soft Multi-tenancy）
  - 场景：内部团队共享集群
  - 信任度：高（同公司）
  - 隔离手段：RBAC + NetworkPolicy + ResourceQuota
  - 成本：低
  - 性能损耗：0%

Level 2：中等隔离（Firm Multi-tenancy）
  - 场景：BU 之间共享集群
  - 信任度：中
  - 隔离手段：+ PodSecurityPolicy/PodSecurity + OPA/Kyverno
  - 成本：中
  - 性能损耗：< 5%

Level 3：硬隔离（Hard Multi-tenancy）
  - 场景：SaaS 平台、外部客户
  - 信任度：低/无
  - 隔离手段：+ 虚拟集群（vCluster）/ 独立集群
  - 成本：高
  - 性能损耗：5-15%
```

| 方案 | 隔离级别 | 适用场景 | 成本 | 复杂度 |
|------|---------|---------|------|--------|
| 命名空间 + RBAC | 软隔离 | 内部小团队 | 低 | 低 |
| + NetworkPolicy | 软隔离 | 内部中等团队 | 低 | 中 |
| + ResourceQuota/LimitRange | 软隔离 | 资源管控 | 低 | 中 |
| + Pod Security | 中等隔离 | 安全合规 | 低 | 中 |
| + OPA/Kyverno | 中等隔离 | 策略治理 | 中 | 中高 |
| vCluster | 硬隔离 | BU/外部客户 | 中 | 中 |
| 独立集群 | 硬隔离 | 金融/政务 | 高 | 高 |

---

## 二、命名空间隔离

### 2.1 基础隔离配置

```yaml
# === 命名空间模板 ===
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
  labels:
    team: alpha
    environment: production
    cost-center: "CC-12345"

---
# === ResourceQuota：资源配额 ===
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-quota
  namespace: team-alpha
spec:
  hard:
    # 计算资源
    requests.cpu: "20"          # 所有 Pod CPU requests 总和
    requests.memory: 100Gi      # 所有 Pod Memory requests 总和
    limits.cpu: "40"            # 所有 Pod CPU limits 总和
    limits.memory: 200Gi        # 所有 Pod Memory limits 总和
    
    # 存储资源
    requests.storage: 500Gi     # PVC 总容量
    persistentvolumeclaims: "10" # PVC 数量
    
    # 对象数量
    pods: "50"                  # Pod 数量上限
    services: "20"              # Service 数量上限
    secrets: "50"               # Secret 数量上限
    configmaps: "50"            # ConfigMap 数量上限
    replicationcontrollers: "20" # RC 数量上限
    services.loadbalancers: "5"  # LoadBalancer 数量上限
    services.nodeports: "5"      # NodePort 数量上限

---
# === LimitRange：默认资源限制 ===
apiVersion: v1
kind: LimitRange
metadata:
  name: team-alpha-limits
  namespace: team-alpha
spec:
  limits:
  # Pod 级别默认
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    type: Container
  
  # PVC 级别默认
  - max:
      storage: 100Gi
    min:
      storage: 1Gi
    type: PersistentVolumeClaim

---
# === NetworkPolicy：网络隔离 ===
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: team-alpha-default-deny
  namespace: team-alpha
spec:
  podSelector: {}              # 选中所有 Pod
  policyTypes:
  - Ingress
  - Egress
  # 无规则 = 拒绝所有流量（默认拒绝）

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: team-alpha-allow-internal
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # 允许同命名空间通信
  - from:
    - podSelector: {}
  # 允许来自 ingress-nginx 的流量
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
  egress:
  # 允许同命名空间通信
  - to:
    - podSelector: {}
  # 允许 DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
  # 允许外部 HTTPS
  - to: []
    ports:
    - protocol: TCP
      port: 443
```

### 2.2 RBAC 配置

```yaml
# === 团队管理员角色 ===
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-alpha-admin
  namespace: team-alpha
rules:
# 完整权限（除了删除命名空间）
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]

---
# === 团队开发者角色（受限） ===
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: team-alpha-developer
  namespace: team-alpha
rules:
# 工作负载管理
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "deployments", "replicasets", "statefulsets", "daemonsets", "jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# ConfigMap 和 Secret（只读自己的，不能读其他团队的）
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]

# Service 管理
- apiGroups: [""]
  resources: ["services", "endpoints"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]

# Ingress 管理
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]

# PVC 管理（但不能删除已有数据的 PVC）
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]

# 禁止操作（显式拒绝）
- apiGroups: [""]
  resources: ["resourcequotas", "limitranges"]
  verbs: []

---
# === 角色绑定 ===
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-alpha-admin-binding
  namespace: team-alpha
subjects:
- kind: Group
  name: team-alpha-admin@mycompany.com
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: team-alpha-admin
  apiGroup: rbac.authorization.k8s.io

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-alpha-dev-binding
  namespace: team-alpha
subjects:
- kind: Group
  name: team-alpha-dev@mycompany.com
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: team-alpha-developer
  apiGroup: rbac.authorization.k8s.io
```

---

## 三、Pod 安全

### 3.1 Pod Security Standards

```yaml
# K8s 内置的 Pod 安全标准（1.23+）

# privileged：最宽松，允许所有配置
# baseline：中等，禁止已知安全风险
# restricted：最严格，遵循 Pod 加固最佳实践

# 命名空间级别启用
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
  labels:
    pod-security.kubernetes.io/enforce: restricted    # 强制
    pod-security.kubernetes.io/audit: restricted      # 审计
    pod-security.kubernetes.io/warn: restricted        # 警告

# restricted 策略要求：
# 1. 禁止以 root 运行
# 2. 禁止特权容器
# 3. 禁止 hostNetwork/hostPID/hostIPC
# 4. 禁止 hostPath
# 5. 只读根文件系统
# 6. 禁止 capabilities（只允许 NET_BIND_SERVICE）
# 7. Seccomp 默认配置文件
# 8. 禁止 volume 类型（hostPath、nfs 等）

# 合规 Pod 示例
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
  namespace: team-alpha
spec:
  securityContext:
    runAsNonRoot: true        # 必须以非 root 运行
    runAsUser: 1000           # 指定用户 ID
    runAsGroup: 1000          # 指定组 ID
    fsGroup: 1000             # 卷组 ID
    seccompProfile:
      type: RuntimeDefault    # 使用默认 seccomp
  containers:
  - name: app
    image: myapp:v1.2.3
    securityContext:
      allowPrivilegeEscalation: false    # 禁止特权提升
      readOnlyRootFilesystem: true       # 只读根文件系统
      capabilities:
        drop:
        - ALL                           # 丢弃所有 capabilities
        add:
        - NET_BIND_SERVICE              # 只允许绑定低端口
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /cache
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir:
      sizeLimit: 100Mi
```

### 3.2 Kyverno 策略加固

```yaml
# Kyverno 策略：强制 Pod 安全标准
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pod-security
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  # 禁止特权容器
  - name: check-privileged
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Privileged containers are not allowed"
      pattern:
        spec:
          containers:
          - securityContext:
              =(privileged): "false"

  # 禁止 root 用户
  - name: check-run-as-non-root
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Running as root is not allowed"
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true

  # 要求资源限制
  - name: check-resources
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "CPU and memory limits are required"
      pattern:
        spec:
          containers:
          - resources:
              limits:
                memory: "?*"
                cpu: "?*"
              requests:
                memory: "?*"
                cpu: "?*"

  # 禁止 latest 标签
  - name: check-image-tag
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Using 'latest' tag is not allowed"
      pattern:
        spec:
          containers:
          - image: "!*:latest"

  # 要求只读根文件系统
  - name: check-read-only-root-fs
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Read-only root filesystem is required"
      pattern:
        spec:
          containers:
          - securityContext:
              readOnlyRootFilesystem: true

  # 禁止 hostPath
  - name: check-host-path
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "HostPath volumes are not allowed"
      pattern:
        spec:
          =(volumes):
          - X(hostPath): "null"
```

---

## 四、虚拟集群（vCluster）

### 4.1 vCluster 架构

```
vCluster 架构：

  宿主集群（Host Cluster）
  │
  ├─ vCluster Pod（包含完整的 K8s 控制平面）
  │   │
  │   ├─ API Server（轻量级，基于 k3s）
  │   ├─ Controller Manager
  │   ├─ etcd（SQLite 或外置）
  │   └─ Syncer（核心组件）
  │       - 将 vCluster 资源同步到宿主集群
  │       - Pod → 宿主集群的 Pod（加前缀隔离）
  │       - Service → 宿主集群的 Service
  │       - ConfigMap/Secret → 宿主集群的 ConfigMap/Secret
  │
  ├─ vCluster 的 Pod（实际运行在宿主集群中）
  │   name: team-alpha-app-xxx
  │   namespace: vcluster-team-alpha-x-app
  │
  └─ vCluster 的 Service
      name: team-alpha-svc-xxx

用户视角：
  kubeconfig → vCluster API Server
  看起来就是一个完整的 K8s 集群
  可以创建 Namespace、CRD、Operator
  有独立的 RBAC、NetworkPolicy

隔离边界：
  - 控制平面：完全隔离（独立的 API Server、etcd）
  - 工作负载：在宿主集群中运行（通过 Syncer 转换）
  - 网络：共享宿主集群网络（需要 CNI 支持）
  - 存储：共享宿主集群存储（PVC 映射）
```

### 4.2 vCluster 部署

```bash
# 安装 vcluster CLI
curl -s -L https://github.com/loft-sh/vcluster/releases/latest | \
  sed -n 's/.*href="\([^"]*vcluster-linux-amd64\)".*/\1/p' | \
  xargs -I {} curl -s -L -o vcluster {}
chmod +x vcluster
sudo mv vcluster /usr/local/bin

# 创建 vCluster
vcluster create team-alpha \
  --namespace vcluster-team-alpha \
  --expose-local \
  --connect

# 输出：
# info   Creating namespace vcluster-team-alpha
# info   Creating vcluster team-alpha...
# done   Successfully created vcluster team-alpha
# done   Virtual cluster kube config written to: ./kubeconfig.yaml

# 连接到 vCluster
export KUBECONFIG=./kubeconfig.yaml
kubectl get nodes
# NAME               STATUS   ROLES    AGE   VERSION
# team-alpha         Ready    <none>   1m    v1.28.2+k3s1
# ← 看起来是一个独立的集群！

# 在 vCluster 中创建资源
kubectl create namespace app
kubectl run nginx --image=nginx -n app

# 在宿主集群中查看
export KUBECONFIG=~/.kube/config
kubectl get pods -n vcluster-team-alpha
# NAME                   READY   STATUS    RESTARTS   AGE
# team-alpha-0           2/2     Running   0          5m
# team-alpha-app-nginx   1/1     Running   0          1m
# ← vCluster 的 Pod 在宿主集群中运行
```

### 4.3 vCluster 隔离策略

```yaml
# vCluster 高级配置
apiVersion: vcluster.loft.sh/v1
kind: VirtualCluster
metadata:
  name: team-alpha
  namespace: vcluster-team-alpha
spec:
  controlPlane:
    # 使用外置 etcd（高可用）
    backingStore:
      etcd:
        deploy:
          enabled: true
          statefulSet:
            resources:
              requests:
                memory: 512Mi
                cpu: 200m
    
    # 资源限制
    distro:
      k3s:
        enabled: true
    
    coredns:
      resources:
        requests:
          memory: 64Mi
          cpu: 20m
  
  sync:
    # 同步到宿主集群的资源映射
    toHost:
      pods:
        enabled: true
        # Pod 命名转换：vCluster Pod → host-vcluster-pod
        rewriteHosts: true
      services:
        enabled: true
      configMaps:
        enabled: true
      secrets:
        enabled: true
      persistentVolumeClaims:
        enabled: true
    
    # 从宿主集群同步到 vCluster
    fromHost:
      nodes:
        enabled: true
        # 只显示部分节点信息
        selector:
          labels:
            team: alpha
      events:
        enabled: true
  
  # 网络隔离
  networking:
    # 是否暴露 Service 到宿主集群
    exposeServices:
      enabled: true
    
    # 是否允许访问宿主集群 Service
    replicateServices:
      fromHost:
      - from: kube-system/kube-dns
        to: kube-system/kube-dns
  
  # 资源配额（宿主集群级别）
  isolation:
    enabled: true
    resourceQuota:
      enabled: true
      quota:
        hard:
          cpu: "40"
          memory: 200Gi
          pods: "100"
    
    limitRange:
      enabled: true
      default:
        cpu: "1"
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
    
    # 网络策略
    networkPolicy:
      enabled: true
      outgoingConnections:
        ipBlock:
          cidr: 0.0.0.0/0
          except:
          - 10.0.0.0/8    # 禁止访问内部网络
```

---

## 五、成本分摊与 FinOps

```yaml
# 使用 Labels 进行成本分摊
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha
  labels:
    # 成本分摊标签
    cost-center: "CC-12345"
    team: "alpha"
    environment: "production"
    project: "platform"

# 所有资源自动继承命名空间标签
# 通过 OpenCost / Kubecost 按标签统计成本

# ResourceQuota 成本限制
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-monthly-budget
  namespace: team-alpha
spec:
  hard:
    # 基于历史数据估算
    requests.cpu: "100"          # ≈ $500/月（AWS m5.xlarge）
    requests.memory: 500Gi       # ≈ $1000/月
    requests.storage: 2Ti        # ≈ $200/月
    requests.nvidia.com/gpu: "4" # ≈ $2000/月（A100）
    # 总预算：约 $3700/月

# 超配额告警
groups:
- name: resource-quota
  rules:
  - alert: ResourceQuotaNearLimit
    expr: |
      kube_resourcequota{resource="requests.cpu", type="used"} 
      / 
      kube_resourcequota{resource="requests.cpu", type="hard"} > 0.8
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Namespace {{ $labels.namespace }} CPU quota > 80%"
```

---

## 六、面试要点

```
Q: 软隔离和硬隔离的区别？如何选择？

A: 核心区别在信任边界：

   软隔离（命名空间 + 策略）：
   - 共享 K8s 控制平面
   - 通过 RBAC/NetworkPolicy/Quota 隔离
   - 风险：内核漏洞可能逃逸
   - 成本：低
   - 适用：内部团队、高信任环境
   
   硬隔离（vCluster/独立集群）：
   - 独立的控制平面
   - 完全隔离的 API Server、etcd
   - 风险：仅共享内核和运行时
   - 成本：中-高
   - 适用：外部客户、低信任环境、强合规
   
   选择建议：
   - 内部团队（< 50 人）：命名空间隔离
   - BU 级别（50-500 人）：vCluster
   - 外部客户 / 金融：独立集群

Q: 如何防止租户间的资源抢占？

A: 多层防护：

   1. ResourceQuota：
      - 限制命名空间的总资源
      - 防止单个租户耗尽集群资源
   
   2. LimitRange：
      - 设置默认资源限制
      - 防止无限制的资源申请
   
   3. PriorityClass + Preemption：
      - 系统服务：system-cluster-critical
      - 核心业务：high-priority
      - 批处理：low-priority
      - 低优先级可被高优先级抢占
   
   4. PodDisruptionBudget：
      - 保证最小可用副本数
      - 防止驱逐导致服务不可用
   
   5. 节点亲和性/污点：
      - 为不同租户分配专用节点池
      - 物理隔离（虽然成本高）

Q: vCluster 与 Namespace 隔离的优劣？

A: vCluster 优势：
   - 独立的控制平面（可以自定义 API、CRD）
   - 独立的 RBAC（租户可以管理自己的角色）
   - 租户感知不到共享（体验像独立集群）
   - 可以运行 Operator（需要集群级别权限）
   
   vCluster 劣势：
   - 额外的资源开销（API Server + etcd）
   - 性能损耗（Syncer 同步延迟）
   - 调试更复杂（需要跨集群排查）
   - 网络共享（无法完全隔离）
   
   Namespace 优势：
   - 轻量（无额外控制平面）
   - 性能好（原生 K8s 路径）
   - 简单（标准 K8s 概念）
   
   Namespace 劣势：
   - 无法自定义 CRD（需要集群权限）
   - RBAC 复杂（需要仔细配置）
   - 租户可以看到集群级资源（Nodes、StorageClass）
```

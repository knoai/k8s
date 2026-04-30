# 多租户 - 深度实操指南

> 从基础 Namespace 隔离到生产级 vCluster + Capsule 多租户方案，
> 每个实验包含真实验证步骤和常见错误排查。

---

## 实验 1：Namespace 基础隔离与资源配额

### 场景
为不同团队创建隔离的命名空间，设置资源配额和默认限制。

### 执行

```bash
# 创建两个团队的命名空间
kubectl create namespace team-alpha-prod
kubectl create namespace team-beta-prod

# 为 team-alpha 配置 ResourceQuota
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-alpha-quota
  namespace: team-alpha-prod
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 80Gi
    limits.cpu: "40"
    limits.memory: 160Gi
    pods: "50"
    services: "10"
    persistentvolumeclaims: "20"
    services.loadbalancers: "2"
    configmaps: "50"
    secrets: "50"
EOF

# 配置 LimitRange（默认和最大值限制）
kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: team-alpha-limits
  namespace: team-alpha-prod
spec:
  limits:
  - default:
      cpu: "1000m"
      memory: "2Gi"
    defaultRequest:
      cpu: "100m"
      memory: "256Mi"
    max:
      cpu: "4"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container
  - max:
      storage: "100Gi"
    min:
      storage: "1Gi"
    type: PersistentVolumeClaim
EOF

# 验证配额
kubectl describe resourcequota team-alpha-quota -n team-alpha-prod
```

### 预期输出

```
Name:            team-alpha-quota
Namespace:       team-alpha-prod
Resource         Used   Hard
--------         ----   ----
configmaps       0      50
limits.cpu       0      40
limits.memory    0      160Gi
persistentvolumeclaims 0 20
pods             0      50
requests.cpu     0      20
requests.memory  0      80Gi
secrets          1      50
services         0      10
services.loadbalancers 0 2
```

### 验证配额限制生效

```bash
# 尝试创建超大 Pod（应失败）
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: oversized-pod
  namespace: team-alpha-prod
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      limits:
        cpu: "8"
        memory: "16Gi"
      requests:
        cpu: "4"
        memory: "8Gi"
EOF

# 预期错误：
# Error from server (Forbidden): pods "oversized-pod" is forbidden:
# maximum cpu usage per Container is 4, but limit is 8

# 创建合规 Pod（应成功）
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: normal-pod
  namespace: team-alpha-prod
spec:
  containers:
  - name: app
    image: nginx:alpine
    resources:
      limits:
        cpu: "2"
        memory: "4Gi"
      requests:
        cpu: "500m"
        memory: "1Gi"
EOF

kubectl get pod normal-pod -n team-alpha-prod
# NAME         READY   STATUS    RESTARTS   AGE
# normal-pod   1/1     Running   0          5s

# 验证自动注入的默认资源
kubectl get pod normal-pod -n team-alpha-prod -o jsonpath='{.spec.containers[0].resources}' | jq .
# 如果没有手动设置，LimitRange 会自动注入默认值
```

---

## 实验 2：NetworkPolicy 网络隔离

### 场景
实现命名空间级别的网络隔离，只允许特定的跨命名空间通信。

### 执行

```bash
# 在 team-alpha-prod 中创建默认拒绝策略
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-alpha-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# 允许同命名空间通信
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: team-alpha-prod
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector: {}
EOF

# 允许访问 kube-dns（必须，否则 DNS 解析失败）
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: team-alpha-prod
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
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
EOF

# 允许 team-beta 访问 team-alpha 的 API 服务
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-team-beta
  namespace: team-alpha-prod
spec:
  podSelector:
    matchLabels:
      app: api-gateway
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          team: team-beta
    ports:
    - protocol: TCP
      port: 8080
EOF
```

### 验证网络隔离

```bash
# 在 team-alpha-prod 中创建测试 Pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: alpha-web
  namespace: team-alpha-prod
  labels:
    app: web
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
EOF

# 在 team-beta-prod 中创建测试 Pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: beta-client
  namespace: team-beta-prod
  labels:
    team: team-beta
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
EOF

# 等待 Pod 就绪
kubectl wait --for=condition=ready pod alpha-web -n team-alpha-prod --timeout=60s
kubectl wait --for=condition=ready pod beta-client -n team-beta-prod --timeout=60s

# 测试 1：同命名空间通信（应成功）
kubectl exec alpha-web -n team-alpha-prod -- wget -qO- http://localhost:80
# <!DOCTYPE html>
# <html>
# ...

# 测试 2：跨命名空间访问（无允许策略时应失败）
kubectl exec beta-client -n team-beta-prod -- wget -qO- --timeout=3 http://alpha-web.team-alpha-prod.svc.cluster.local:80 2>&1
# wget: download timed out

# 测试 3：DNS 解析（必须能解析，即使连接被拒绝）
kubectl exec beta-client -n team-beta-prod -- nslookup alpha-web.team-alpha-prod.svc.cluster.local
# Server:    10.96.0.10
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
#
# Name:      alpha-web.team-alpha-prod.svc.cluster.local
# Address 1: 10.244.1.x
```

### 常见错误

```bash
# 错误 1：NetworkPolicy 不生效
# 原因：CNI 插件不支持 NetworkPolicy（如 Flannel 默认不支持）
# 解决：使用 Calico/Cilium
kubectl get pods -n kube-system | grep -E 'calico|cilium'

# 错误 2：Pod 无法解析 DNS
# 原因：忘记允许到 kube-dns 的 egress
# 解决：添加 allow-dns NetworkPolicy

# 错误 3：策略冲突
# 多个 NetworkPolicy 是 "或" 关系，不是 "与"
# 如果有一个策略允许，则允许
```

---

## 实验 3：vCluster 虚拟集群

### 场景
为每个团队提供独立的虚拟 K8s 集群，隔离控制平面但共享工作节点。

### 前置条件

```bash
# 安装 vcluster CLI
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-darwin-amd64" && \
  chmod +x vcluster && \
  sudo mv vcluster /usr/local/bin/

# 验证
vcluster --version
# vcluster version 0.18.x
```

### 执行

```bash
# 创建虚拟集群
vcluster create team-alpha-vcluster \
  --namespace vcluster-team-alpha \
  --connect=false \
  --expose-local=false

# 预期输出：
# info   Creating namespace vcluster-team-alpha
# info   Create vcluster team-alpha-vcluster...
# info   successfully created vcluster team-alpha-vcluster in namespace vcluster-team-alpha

# 查看虚拟集群 Pod（在宿主机集群中）
kubectl get pods -n vcluster-team-alpha
# NAME                                                  READY   STATUS    RESTARTS
# team-alpha-vcluster-0                                 2/2     Running   0
# coredns-team-alpha-vcluster-x8c4f6d48-xxxxx          1/1     Running   0

# 连接虚拟集群
vcluster connect team-alpha-vcluster -n vcluster-team-alpha

# 验证：这是虚拟集群，只看到 1 个 "节点"
kubectl get nodes
# NAME                     STATUS   ROLES    AGE   VERSION
# team-alpha-vcluster-0    Ready    <none>   2m    v1.28.2

# 在虚拟集群中创建资源
kubectl create namespace test
kubectl run nginx --image=nginx -n test
kubectl get pods -n test
# NAME    READY   STATUS    RESTARTS
# nginx   1/1     Running   0
```

### 验证宿主机视角

```bash
# 在另一个终端，查看宿主机集群
kubectl config use-context kind-platform-lab  # 或你的宿主机上下文
kubectl get pods -n vcluster-team-alpha
# 看到 nginx Pod 以同步的方式运行在宿主机中：
# NAME                                                  READY
# team-alpha-vcluster-0                                 2/2
# coredns-team-alpha-vcluster-x8c4f6d48-xxxxx          1/1
# nginx-x-test-x-team-alpha-vcluster                   1/1   <- 虚拟集群中的 Pod

# 查看 Pod 名称映射规则
# 虚拟集群: nginx (namespace: test)
# 宿主机: nginx-x-test-x-team-alpha-vcluster (namespace: vcluster-team-alpha)
```

### 断开连接

```bash
vcluster disconnect
kubectl config current-context
# 回到宿主机上下文
```

### 清理

```bash
vcluster delete team-alpha-vcluster -n vcluster-team-alpha
kubectl delete namespace vcluster-team-alpha
```

---

## 实验 4：Capsule 多租户方案

### 场景
使用 Capsule 实现基于租户（Tenant）的多租户管理，自动隔离命名空间和网络。

### 执行

```bash
# 安装 Capsule
helm repo add clastix https://clastix.github.io/charts
helm repo update
helm install capsule clastix/capsule \
  --namespace capsule-system \
  --create-namespace \
  --set "manager.options.forceTenantPrefix=false"

# 等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=capsule -n capsule-system --timeout=120s

# 创建 Tenant（租户）
kubectl apply -f - <<EOF
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: oil-production
spec:
  owners:
  - name: alice
    kind: User
  - name: oil-team
    kind: Group
  namespaceOptions:
    additionalMetadata:
      labels:
        capsule.clastix.io/tenant: oil-production
        cost-center: oil-and-gas
    quota: 5  # 最多 5 个命名空间
  networkPolicies:
    items:
    - policyTypes:
      - Ingress
      - Egress
      podSelector: {}
      ingress:
      - from:
        - namespaceSelector:
            matchLabels:
              capsule.clastix.io/tenant: oil-production
      egress:
      - to:
        - namespaceSelector:
            matchLabels:
              capsule.clastix.io/tenant: oil-production
      - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
        ports:
        - protocol: UDP
          port: 53
  resourceQuotas:
    items:
    - hard:
        limits.cpu: "20"
        limits.memory: 40Gi
        requests.cpu: "10"
        requests.memory: 20Gi
        pods: "30"
  limitRanges:
    items:
    - limits:
      - default:
          cpu: "500m"
          memory: "1Gi"
        defaultRequest:
          cpu: "100m"
          memory: "256Mi"
        type: Container
  serviceOptions:
    additionalMetadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
EOF

# 验证 Tenant 创建
kubectl get tenants
# NAME             STATE    NAMESPACE QUOTA   NAMESPACE COUNT   NODE SELECTOR
# oil-production   Active   5                 0
```

### 以租户用户身份操作

```bash
# 模拟用户 alice 创建命名空间
# （实际环境中通过 kubeconfig 或 OIDC 认证）

# 创建属于 oil-production 租户的命名空间
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: oil-prod-api
  labels:
    capsule.clastix.io/tenant: oil-production
EOF

# Capsule 会自动：
# 1. 验证命名空间属于该租户
# 2. 应用 Tenant 中定义的 ResourceQuota
# 3. 应用 Tenant 中定义的 LimitRange
# 4. 应用 Tenant 中定义的 NetworkPolicy

# 验证自动注入的策略
kubectl describe namespace oil-prod-api

kubectl get resourcequota -n oil-prod-api
# NAME                AGE   REQUEST                                                                                                                      LIMIT
# capsule-oil-production-0   10s   requests.cpu: 0/10, requests.memory: 0/20Gi, pods: 0/30   limits.cpu: 0/20, limits.memory: 0/40Gi

kubectl get limitrange -n oil-prod-api
# NAME                AGE
# capsule-oil-production-0   10s

kubectl get networkpolicy -n oil-prod-api
# NAME                POD-SELECTOR   AGE
# capsule-oil-production-0   <none>         10s
```

### 验证跨租户隔离

```bash
# 创建另一个租户
kubectl apply -f - <<EOF
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: gas-production
spec:
  owners:
  - name: bob
    kind: User
  namespaceOptions:
    additionalMetadata:
      labels:
        capsule.clastix.io/tenant: gas-production
  networkPolicies:
    items:
    - policyTypes:
      - Ingress
      - Egress
      podSelector: {}
      ingress:
      - from:
        - namespaceSelector:
            matchLabels:
              capsule.clastix.io/tenant: gas-production
EOF

# 创建 gas 命名空间
kubectl create namespace gas-prod-api
kubectl label namespace gas-prod-api capsule.clastix.io/tenant=gas-production

# oil 和 gas 命名空间之间的 Pod 默认无法通信
# 验证方法与实验 2 相同
```

---

## 实验 5：HNC 层级命名空间

### 场景
使用 HNC（Hierarchical Namespace Controller）实现命名空间层级结构，
父命名空间的 RBAC 和 NetworkPolicy 自动继承到子命名空间。

### 执行

```bash
# 安装 HNC
kubectl apply -f https://github.com/kubernetes-sigs/hierarchical-namespaces/releases/download/v1.1.0/hnc-manager.yaml

# 等待就绪
kubectl wait --for=condition=ready pod -l app=hnc-controller-manager -n hnc-system --timeout=120s

# 安装 kubectl 插件（可选，方便操作）
curl -L https://github.com/kubernetes-sigs/hierarchical-namespaces/releases/download/v1.1.0/kubectl-hns -o kubectl-hns && \
  chmod +x kubectl-hns && \
  sudo mv kubectl-hns /usr/local/bin/

# 创建层级结构
# 父命名空间：team-alpha
#   ├── team-alpha-dev
#   ├── team-alpha-staging
#   └── team-alpha-prod

kubectl create namespace team-alpha
kubectl label namespace team-alpha hnc.x-k8s.io/subnamespace-of="" --overwrite=false || true

# 使用 HNC 创建子命名空间
kubectl apply -f - <<EOF
apiVersion: hnc.x-k8s.io/v1alpha2
kind: SubnamespaceAnchor
metadata:
  namespace: team-alpha
  name: dev
---
apiVersion: hnc.x-k8s.io/v1alpha2
kind: SubnamespaceAnchor
metadata:
  namespace: team-alpha
  name: staging
---
apiVersion: hnc.x-k8s.io/v1alpha2
kind: SubnamespaceAnchor
metadata:
  namespace: team-alpha
  name: prod
EOF

# 验证层级
kubectl hns tree team-alpha
# team-alpha
# ├── dev
# ├── staging
# └── prod
```

### 验证 RBAC 继承

```bash
# 在父命名空间创建 RoleBinding
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-alpha-admin
  namespace: team-alpha
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- kind: Group
  name: team-alpha@company.io
  apiGroup: rbac.authorization.k8s.io
EOF

# HNC 会自动同步到子命名空间
kubectl get rolebinding -n team-alpha-dev
# NAME               ROLE                AGE
# team-alpha-admin   ClusterRole/admin   10s

kubectl get rolebinding -n team-alpha-staging
# NAME               ROLE                AGE
# team-alpha-admin   ClusterRole/admin   10s

kubectl get rolebinding -n team-alpha-prod
# NAME               ROLE                AGE
# team-alpha-admin   ClusterRole/admin   10s
```

### 验证 NetworkPolicy 继承

```bash
# 在父命名空间创建 NetworkPolicy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# 等待同步（约 10-30 秒）
sleep 15

# 验证子命名空间也拥有该策略
kubectl get networkpolicy -n team-alpha-dev
# NAME           POD-SELECTOR   AGE
# default-deny   <none>         5s
```

### 清理

```bash
# 删除子命名空间
kubectl delete subnamespaceanchor dev -n team-alpha
kubectl delete subnamespaceanchor staging -n team-alpha
kubectl delete subnamespaceanchor prod -n team-alpha

# 删除父命名空间
kubectl delete namespace team-alpha
```

---

## 实验 6：多租户成本分摊验证

### 场景
使用 kube-resource-report 或手动脚本计算每个命名空间的资源成本。

### 执行

```bash
# 安装 kube-resource-report（简化版）
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: resource-report
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: resource-report
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "namespaces"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: resource-report
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: resource-report
subjects:
- kind: ServiceAccount
  name: resource-report
  namespace: kube-system
EOF

# 手动计算各命名空间资源使用
cat > calculate-cost.sh <<'SCRIPT'
#!/bin/bash
echo "=== 命名空间资源使用统计 ==="
echo ""
printf "%-25s %-10s %-10s %-10s %-10s\n" "Namespace" "CPU Req" "CPU Lim" "Mem Req" "Mem Lim"
printf "%-25s %-10s %-10s %-10s %-10s\n" "---------" "-------" "-------" "-------" "-------"

for ns in team-alpha-prod team-beta-prod; do
  CPU_REQ=$(kubectl top pods -n $ns --no-headers 2>/dev/null | awk '{sum+=$2} END {printf "%.0f", sum}' | sed 's/m//')
  CPU_LIM=$(kubectl get pods -n $ns -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.limits.cpu}{"\n"}{end}{end}' 2>/dev/null | awk '{sum+=$1} END {print sum}')
  MEM_REQ=$(kubectl top pods -n $ns --no-headers 2>/dev/null | awk '{sum+=$3} END {printf "%.0f", sum}')
  MEM_LIM=$(kubectl get pods -n $ns -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.limits.memory}{"\n"}{end}{end}' 2>/dev/null | numfmt --from=iec 2>/dev/null | awk '{sum+=$1} END {print sum/1024/1024"Mi"}')
  
  printf "%-25s %-10s %-10s %-10s %-10s\n" "$ns" "${CPU_REQ:-0}m" "${CPU_LIM:-0}" "${MEM_REQ:-0}" "${MEM_LIM:-0}"
done
SCRIPT
chmod +x calculate-cost.sh
bash calculate-cost.sh
```

---

## 排障速查表

```
问题                          排查命令                                          解决
─────────────────────────────────────────────────────────────────────────────────────────
ResourceQuota 超限            kubectl describe resourcequota -n <ns>            删除资源或申请增大配额
LimitRange 不生效             kubectl describe limitrange -n <ns>              检查 LimitRange 定义、重新创建
NetworkPolicy 不生效          kubectl get pods -n kube-system | grep calico    确认 CNI 支持 NetworkPolicy
vCluster 无法连接             kubectl get pods -n <ns>                          检查 vcluster Pod 状态
Capsule 拒绝命名空间创建      kubectl describe tenant <name>                    检查 namespace quota 是否已满
HNC 策略未同步                kubectl get hierarchyconfiguration -n <ns>        检查 HNC webhook 状态
跨租户 Pod 能通信             kubectl get networkpolicy -n <ns>                检查 NetworkPolicy 定义、CNI 支持
─────────────────────────────────────────────────────────────────────────────────────────
```

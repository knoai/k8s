# 生产排障：Pod 调度 stuck Pending

> Pod  stuck in Pending 是 Kubernetes 中最常见的调度问题之一。
> 本节提供从"无节点可调度"到"有节点但不满足条件"的完整排查方法。

---

## Pending 根因分类

```
Pod Status: Pending
       │
       ├─ 1. 无可用节点（0/3 nodes are available）
       │   ├─ 1.1 资源不足：insufficient cpu/memory
       │   ├─ 1.2 污点排斥：node(s) had taint
       │   ├─ 1.3 节点选择器不匹配：node selector mismatch
       │   ├─ 1.4 亲和性/反亲和性不满足
       │   ├─ 1.5 节点未就绪：node not ready
       │   └─ 1.6 无 CSI 驱动：no volume plugin matched
       │
       ├─ 2. 有可用节点但绑定失败
       │   ├─ 2.1 Volume 绑定失败
       │   ├─ 2.2 网络插件未就绪
       │   ├─ 2.3 镜像拉取失败（但 kubelet 先报告 Pending）
       │   └─ 2.4 初始化容器失败
       │
       └─ 3. 调度器本身问题
           ├─ 3.1 kube-scheduler 未运行
           ├─ 3.2 自定义调度器配置错误
           └─ 3.3 调度队列积压
```

---

## 诊断命令速查

### 基础诊断

```bash
# 1. 查看 Pod 事件（最关键！）
kubectl describe pod <pod-name>

# 典型输出（资源不足）：
# Events:
#   Type     Reason            Age   From               Message
#   ----     ------            ----  ----               -------
#   Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available:
#     1 node(s) had taint {node-role.kubernetes.io/control-plane: }, that the pod didn't tolerate,
#     2 Insufficient cpu.  ← 关键信息！

# 典型输出（污点排斥）：
#   Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available:
#     3 node(s) had taint {dedicated: gpu}, that the pod didn't tolerate.

# 典型输出（PVC 未绑定）：
#   Warning  FailedScheduling  5s    default-scheduler  
#     0/3 nodes are available: 3 pod has unbound immediate PersistentVolumeClaims.

# 2. 查看 Pod 资源请求
kubectl get pod <pod-name> -o yaml | grep -A 5 resources

# 输出：
#   resources:
#     requests:
#       cpu: "4"           ← 请求 4 核 CPU
#       memory: "16Gi"     ← 请求 16GB 内存
#       nvidia.com/gpu: 1  ← 请求 1 块 GPU

# 3. 查看节点资源
kubectl top node

# 输出：
# NAME         CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# node-1       100m         2%     1024Mi          6%
# node-2       200m         4%     2048Mi          12%
# node-3       150m         3%     1536Mi          9%
# ← 看起来 CPU 使用率很低，但 allocatable 可能已经用满

# 4. 查看节点可分配资源
cat > node-resources.sh <<'SCRIPT'
#!/bin/bash
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  echo "=== $node ==="
  kubectl get node $node -o json | jq -r '
    {
      name: .metadata.name,
      cpu_capacity: .status.capacity.cpu,
      cpu_allocatable: .status.allocatable.cpu,
      mem_capacity: .status.capacity.memory,
      mem_allocatable: .status.allocatable.memory,
      pods_capacity: .status.capacity.pods,
      pods_allocatable: .status.allocatable.pods
    }
  '
done
SCRIPT
bash node-resources.sh

# 输出：
# === node-1 ===
# {
#   "name": "node-1",
#   "cpu_capacity": "8",
#   "cpu_allocatable": "6",       ← 系统预留了 2 核
#   "mem_capacity": "32896Mi",
#   "mem_allocatable": "28928Mi", ← 系统预留了 ~4GB
#   "pods_capacity": "110",
#   "pods_allocatable": "110"
# }
```

### 资源分配详情

```bash
# 查看节点上所有 Pod 的资源请求总和
kubectl get pods --all-namespaces --field-selector spec.nodeName=node-1 \
  -o json | jq -r '
    .items[] | 
    select(.status.phase == "Running") |
    {
      name: .metadata.name,
      namespace: .metadata.namespace,
      cpu: (.spec.containers[].resources.requests.cpu // "0"),
      mem: (.spec.containers[].resources.requests.memory // "0")
    } | "\(.namespace)/\(.name): CPU=\(.cpu), MEM=\(.mem)"
  '

# 或者使用 kubectl resource-capacity 插件
kubectl resource-capacity --util --sort cpu.util

# 输出：
# NODE     CPU REQUESTS   CPU LIMITS   CPU UTIL   MEMORY REQUESTS   MEMORY LIMITS   MEMORY UTIL
# node-1   5600m (93%)    8000m (133%) 25%        24576Mi (84%)     32768Mi (113%)  45%
# node-2   5800m (96%)    8000m (133%) 30%        26112Mi (90%)     32768Mi (113%)  52%
# node-3   5400m (90%)    8000m (133%) 22%        24064Mi (83%)     32768Mi (113%)  38%
# ← CPU requests 已占用 93-96%，虽然 utilization 只有 22-30%
```

---

## 根因 1：CPU/Memory Requests 超配

### 现象

```bash
# Pod 事件
kubectl describe pod my-app-xxx
# Events:
#   Warning  FailedScheduling  30s  default-scheduler  0/3 nodes are available:
#     3 Insufficient cpu.

# 但 kubectl top node 显示 CPU 使用率只有 30%
# 为什么？因为 requests 已经占满了
```

### 诊断

```bash
# 查看所有 Pending Pod 的资源需求
cat > pending-resources.sh <<'SCRIPT'
#!/bin/bash
echo "Pending Pods 资源需求汇总："
kubectl get pods --all-namespaces --field-selector status.phase=Pending \
  -o json | jq -r '
    [.items[] | {
      name: .metadata.name,
      namespace: .metadata.namespace,
      cpu: [.spec.containers[].resources.requests.cpu // "0"] | add,
      mem: [.spec.containers[].resources.requests.memory // "0"] | add
    }] | group_by(.namespace) | .[] | {
      namespace: .[0].namespace,
      pending_count: length,
      total_cpu_requests: [.[].cpu] | add,
      total_mem_requests: [.[].mem] | add
    } | "\(.namespace): \(.pending_count) pods, CPU=\(.total_cpu_requests), MEM=\(.total_mem_requests)"
  '
SCRIPT
bash pending-resources.sh

# 输出：
# Pending Pods 资源需求汇总：
# production: 15 pods, CPU=45, MEM=180Gi
# staging: 3 pods, CPU=6, MEM=24Gi
# ← production 需要 45 核 CPU，但所有节点加起来 allocatable 只有 18 核
```

### 修复

```bash
# 方案 1：水平扩容节点（HPA 节点）
# 如果使用 Cluster Autoscaler：
kubectl get nodes
# NAME                                       STATUS   ROLES    AGE   VERSION
# ip-10-0-1-10.us-west-2.compute.internal    Ready    <none>   1d    v1.28.0
# ip-10-0-1-11.us-west-2.compute.internal    Ready    <none>   1d    v1.28.0
# ip-10-0-1-12.us-west-2.compute.internal    Ready    <none>   1d    v1.28.0

# Cluster Autoscaler 会自动检测 Pending Pod 并扩容
# 查看 CA 日志：
kubectl logs -n kube-system deployment/cluster-autoscaler | grep -E "Scale-up|Insufficient"
# I0115 08:30:00.123456 cluster.go:123] Scale-up: group <node-group> 
#   size set to 5 instead of 3 (max: 10)

# 方案 2：降低 Pod requests（如果 limit > request）
# 原配置：
# resources:
#   requests:
#     cpu: "4"
#     memory: "16Gi"
#   limits:
#     cpu: "8"
#     memory: "32Gi"

# 修复：降低 requests（但保持 limits）
# resources:
#   requests:
#     cpu: "1"          ← 降低到实际需要的值
#     memory: "4Gi"     ← 使用 metrics 数据确定
#   limits:
#     cpu: "8"
#     memory: "32Gi"

# 方案 3：使用 VPA（垂直 Pod 自动伸缩）自动调整
kubectl apply -f - <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
  namespace: production
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
    - containerName: '*'
      minAllowed:
        cpu: 100m
        memory: 128Mi
      maxAllowed:
        cpu: 4
        memory: 16Gi
      controlledResources: ["cpu", "memory"]
EOF
```

---

## 根因 2：污点（Taint）与容忍（Toleration）不匹配

### 现象

```bash
# Pod 事件
kubectl describe pod gpu-app-xxx
# Warning  FailedScheduling  5s  default-scheduler  0/3 nodes are available:
#   3 node(s) had taint {nvidia.com/gpu: present}, that the pod didn't tolerate.
```

### 诊断

```bash
# 查看所有节点的污点
kubectl get nodes -o json | jq -r '
  .items[] | {
    name: .metadata.name,
    taints: [.spec.taints[]? | "\(.key)=\(.value):\(.effect)"] | join(", ")
  } | "\(.name): \(.taints)"
'

# 输出：
# node-1: node-role.kubernetes.io/control-plane=:NoSchedule
# node-2: dedicated=gpu:NoSchedule, nvidia.com/gpu=present:NoSchedule
# node-3: dedicated=gpu:NoSchedule, nvidia.com/gpu=present:NoSchedule
# ← 工作节点都有 taint，Pod 必须有对应的 toleration

# 查看 Pod 的容忍度
kubectl get pod gpu-app-xxx -o json | jq '.spec.tolerations'
# null  ← 没有 toleration！
```

### 修复

```yaml
apiVersion: v1
kind: Pod
spec:
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  # 或者精确匹配：
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoSchedule"
```

---

## 根因 3：节点亲和性 / Pod 反亲和性

### 现象

```bash
kubectl describe pod my-app-xxx
# Warning  FailedScheduling  5s  default-scheduler  0/3 nodes are available:
#   1 node(s) didn't match pod affinity/anti-affinity,
#   1 node(s) didn't match pod anti-affinity rules,
#   1 node(s) had taint {node-role.kubernetes.io/control-plane: }, that the pod didn't tolerate.
```

### 诊断

```bash
# 查看 Pod 的亲和性配置
kubectl get pod my-app-xxx -o yaml | grep -A 50 affinity

# 输出：
# affinity:
#   podAntiAffinity:
#     requiredDuringSchedulingIgnoredDuringExecution:
#     - labelSelector:
#         matchExpressions:
#         - key: app
#           operator: In
#           values:
#           - my-app
#       topologyKey: kubernetes.io/hostname
# ← 要求同一节点上不能有相同 app=my-app 的 Pod

# 检查当前部署情况
kubectl get pods -l app=my-app -o wide
# NAME        READY   STATUS    RESTARTS   AGE   NODE
# my-app-0    1/1     Running   0          1h    node-1
# my-app-1    1/1     Running   0          1h    node-2
# my-app-2    1/1     Running   0          1h    node-3
# ← 3 个副本已经分布在 3 个节点上，再扩容一个副本就会 Pending！
```

### 修复

```yaml
# 方案 1：将 required 改为 preferred（软约束）
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - my-app
        topologyKey: kubernetes.io/hostname

# 方案 2：扩展节点或调整拓扑域
# 使用 zone 而不是 hostname 作为拓扑域
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app
          operator: In
          values:
          - my-app
      topologyKey: topology.kubernetes.io/zone
# ← 这样同一 zone 内只能有一个副本，但不同 node 可以共存
```

---

## 根因 4：PVC 未绑定

### 现象

```bash
kubectl describe pod my-app-xxx
# Events:
#   Warning  FailedScheduling  5s  default-scheduler  0/3 nodes are available:
#     3 pod has unbound immediate PersistentVolumeClaims.

# 查看 PVC 状态
kubectl get pvc
# NAME        STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# my-data     Pending                                      gp3            10m
# ← PVC 处于 Pending

kubectl describe pvc my-data
# Events:
#   Type     Reason              Age  From
#   ----     ------              ----  ----
#   Warning  ProvisioningFailed  5s   persistentvolume-controller  
#     storageclass.storage.k8s.io "gp3" not found
# ← StorageClass gp3 不存在！
```

### 修复

```bash
# 方案 1：创建缺失的 StorageClass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
EOF

# 方案 2：修改 PVC 使用存在的 StorageClass
kubectl patch pvc my-data -p '{"spec":{"storageClassName":"gp2"}}'

# 方案 3：如果不需要持久化，使用 emptyDir
# volumes:
# - name: data
#   emptyDir: {}
```

---

## 根因 5：调度器未运行

### 现象

```bash
# 所有 Pod 都 Pending，即使资源充足
kubectl get pods --all-namespaces
# NAMESPACE   NAME        READY   STATUS    RESTARTS   AGE
# default     app-1       0/1     Pending   0          30m
# default     app-2       0/1     Pending   0          30m

# 查看 kube-scheduler
kubectl get pods -n kube-system -l component=kube-scheduler
# No resources found in kube-system namespace.
# ← 调度器 Pod 不存在！

# 查看静态 Pod 配置
ls /etc/kubernetes/manifests/
# kube-apiserver.yaml  kube-controller-manager.yaml
# ← kube-scheduler.yaml 缺失！
```

### 修复

```bash
# 恢复 kube-scheduler 静态 Pod
cat > /etc/kubernetes/manifests/kube-scheduler.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: kube-scheduler
    image: registry.k8s.io/kube-scheduler:v1.28.0
    command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --kubeconfig=/etc/kubernetes/scheduler.conf
    - --leader-elect=true
    livenessProbe:
      httpGet:
        path: /healthz
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
    resources:
      requests:
        cpu: 100m
EOF

# 等待调度器启动
kubectl wait --for=condition=ready pod -n kube-system kube-scheduler-<node> --timeout=60s

# 验证
kubectl get pods -n kube-system -l component=kube-scheduler
# NAME                  READY   STATUS    RESTARTS   AGE
# kube-scheduler-node1  1/1     Running   0          10s
```

---

## 根因 6：CSI 驱动未就绪

### 现象

```bash
kubectl describe pod my-app-xxx
# Events:
#   Warning  FailedScheduling  5s  default-scheduler  
#     0/3 nodes are available:
#     3 node(s) did not have enough free storage.
#     3 node(s) had volume node affinity conflict.

# 查看 CSI 节点状态
kubectl get csinode
# NAME     DRIVERS   AGE
# node-1   0         1d
# node-2   0         1d
# node-3   0         1d
# ← 没有 CSI 驱动注册！

# 查看 CSI 插件 Pod
kubectl get pods -n kube-system -l app=ebs-csi-node
# NAME                  READY   STATUS    RESTARTS   AGE
# ebs-csi-node-abc      0/3     CrashLoopBackOff   5          10m
# ← CSI 节点插件崩溃

kubectl logs -n kube-system ebs-csi-node-abc -c ebs-plugin
# Error: AWS credentials not found
# ← IAM 角色配置错误
```

### 修复

```bash
# 检查 CSI 驱动 Pod
kubectl get pods -n kube-system | grep csi

# 修复 CSI 驱动（以 AWS EBS CSI 为例）
# 1. 确认 IAM 角色和权限
# 2. 确认 CSI 驱动版本兼容
# 3. 重启 CSI 节点 DaemonSet
kubectl rollout restart daemonset ebs-csi-node -n kube-system

# 验证
kubectl get csinode
# NAME     DRIVERS   AGE
# node-1   1         1m
# node-2   1         1m
# node-3   1         1m
```

---

## 自动化诊断脚本

```bash
#!/bin/bash
# diagnose-pending.sh <pod-name> <namespace>

POD=${1:-}
NS=${2:-default}

if [ -z "$POD" ]; then
  echo "Usage: $0 <pod-name> [namespace]"
  echo ""
  echo "All Pending pods:"
  kubectl get pods --all-namespaces --field-selector status.phase=Pending \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,AGE:.metadata.age,NODE:.spec.nodeName
  exit 1
fi

echo "=========================================="
echo "  Pod Pending 诊断: $NS/$POD"
echo "=========================================="

echo ""
echo "=== 1. Pod 状态 ==="
kubectl get pod $POD -n $NS

echo ""
echo "=== 2. Pod 事件 ==="
kubectl describe pod $POD -n $NS | grep -A 30 "Events:"

echo ""
echo "=== 3. 资源请求 ==="
kubectl get pod $POD -n $NS -o json | jq -r '
  .spec.containers[] | 
  "\(.name): CPU request=\(.resources.requests.cpu // "无"), MEM request=\(.resources.requests.memory // "无")"
'

echo ""
echo "=== 4. 污点检查 ==="
kubectl get pod $POD -n $NS -o json | jq -r '.spec.tolerations // "无 tolerations"'

echo ""
echo "=== 5. 节点亲和性 ==="
kubectl get pod $POD -n $NS -o json | jq '.spec.affinity // "无 affinity"'

echo ""
echo "=== 6. PVC 状态 ==="
PVC=$(kubectl get pod $POD -n $NS -o json | jq -r '.spec.volumes[]?.persistentVolumeClaim.claimName // empty')
if [ -n "$PVC" ]; then
  echo "PVC: $PVC"
  kubectl get pvc $PVC -n $NS
  kubectl describe pvc $PVC -n $NS | grep -A 5 "Events:"
else
  echo "无 PVC"
fi

echo ""
echo "=== 7. 节点资源概览 ==="
kubectl top node

echo ""
echo "=== 8. 调度器状态 ==="
kubectl get pods -n kube-system -l component=kube-scheduler

echo ""
echo "=========================================="
echo "  诊断完成"
echo "=========================================="
```

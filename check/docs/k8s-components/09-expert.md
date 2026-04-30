# 09. 专家进阶

## API Machinery

### API 架构

```
┌─────────────────────────────────────────┐
│              apiserver                   │
│                                          │
│  REST Path: /api/v1/namespaces/{ns}/pods │
│             │      │      │     │       │
│             │      │      │     └── Resource
│             │      │      └─────── Namespace scope
│             │      └─────────────── API Group
│             └────────────────────── API Version
│                                          │
│  内部对象：internalversion.Pod            │
│       │                                  │
│       ▼                                  │
│  版本化对象：v1.Pod                       │
│       │                                  │
│       ▼                                  │
│  JSON/YAML ──► etcd                     │
└─────────────────────────────────────────┘
```

### API 版本规则

| 版本级别 | 说明 | 示例 |
|---------|------|------|
| `Alpha` | 可能不兼容，默认禁用 | `v1alpha1` |
| `Beta` | 基本稳定，可能微调 | `v1beta1` |
| `Stable` | 长期支持，保证兼容 | `v1` |

### 资源版本控制

```
用户创建 Pod
    │
    └── apiserver 生成 metadata.resourceVersion = "12345"
    │
    └── 写入 etcd

用户更新 Pod
    │
    ├── 请求中包含 resourceVersion = "12345"
    │
    ├── apiserver 检查当前 etcd 中版本是否为 "12345"
    │   └── 如果不是 → 返回 409 Conflict（乐观锁冲突）
    │
    └── 更新成功 → 新 resourceVersion = "12346"
```

### Watch 机制

```
客户端 ──► apiserver: GET /api/v1/pods?watch=true

apiserver ──► etcd: Watch
    │
    ├── 初始 List：返回当前所有 Pod
    │
    └── 持续推送事件：
            ADDED    → 新 Pod 创建
            MODIFIED → Pod 更新
            DELETED  → Pod 删除
            BOOKMARK → 心跳（保持连接）
            ERROR    → 错误
```

**List-Watch 模式**：

```
Controller 启动：
    1. List：获取所有当前资源（resourceVersion=X）
    2. Watch：从 resourceVersion=X 开始监听变化
    3. 处理事件队列（Add/Update/Delete）
    4. 如果 Watch 断开，从最新的 resourceVersion 重新 Watch
```

---

## 调度框架（Scheduling Framework）

### 调度框架架构（1.19+）

调度器被扩展为**插件化框架**，不同阶段可插入自定义插件。

```
调度周期（Scheduling Cycle）→ 绑定周期（Binding Cycle）

Scheduling Cycle（同步，单线程）：
    │
    ├── PreFilter（预选前准备）
    │       └── 计算 Pod 的资源需求
    │
    ├── Filter（预选）
    │       └── 过滤不符合条件的节点
    │
    ├── PostFilter（预选后）
    │       └── 如果没有节点通过，尝试抢占
    │
    ├── PreScore（打分前准备）
    │
    ├── Score（打分）
    │       └── 给节点打分
    │
    ├── Reserve（预留）
    │       └── 预留节点资源
    │
    └── Permit（批准）
            └── 等待/批准/拒绝

Binding Cycle（异步，可并行）：
    │
    ├── PreBind（绑定前）
    │       └── 准备存储卷
    │
    ├── Bind（绑定）
    │       └── 调用 apiserver 更新 Pod 的 nodeName
    │
    └── PostBind（绑定后）
            └── 清理预留
```

### 自定义调度插件

```go
// 自定义 Filter 插件
package myplugin

type MyFilter struct{}

func (f *MyFilter) Name() string {
    return "MyFilter"
}

func (f *MyFilter) Filter(ctx context.Context, state *framework.CycleState,
    pod *v1.Pod, nodeInfo *framework.NodeInfo) *framework.Status {
    
    // 自定义过滤逻辑
    if nodeInfo.Node().Labels["zone"] != pod.Labels["preferred-zone"] {
        return framework.NewStatus(framework.Unschedulable, "zone mismatch")
    }
    return framework.NewStatus(framework.Success)
}
```

### 调度器配置

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  plugins:
    filter:
      enabled:
      - name: MyFilter
      disabled:
      - name: NodeResourcesFit
    score:
      enabled:
      - name: MyScore
        weight: 10
```

---

## CRD 与 Operator

### CRD — 自定义资源定义

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.example.com
spec:
  group: example.com
  names:
    kind: WebApp
    plural: webapps
    singular: webapp
    shortNames:
    - wa
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              replicas:
                type: integer
                minimum: 1
                maximum: 100
              image:
                type: string
          status:
            type: object
            properties:
              readyReplicas:
                type: integer
    subresources:
      status: {}  # 启用 /status 子资源
    additionalPrinterColumns:
    - name: Replicas
      type: integer
      jsonPath: .spec.replicas
    - name: Ready
      type: integer
      jsonPath: .status.readyReplicas
```

### Operator 模式

```
用户创建 CR
    │
    ▼
┌──────────────────┐
│   Operator       │
│   (Controller)   │
│                  │
│  Watch CR 变化   │
│       │          │
│       ▼          │
│  Reconcile Loop  │
│       │          │
│       ├── 读取期望状态（CR spec）
│       ├── 读取实际状态（子资源）
│       ├── 计算差异
│       └── 执行动作（创建/更新/删除子资源）
│                  │
└──────────────────┘
    │
    ▼
子资源（Deployment/Service/ConfigMap...）
```

### Operator 开发框架

| 框架 | 语言 | 特点 |
|------|------|------|
| **Operator SDK** | Go | CNCF 官方，功能最全 |
| **Kubebuilder** | Go | 与 Operator SDK 合并 |
| **Operator Framework (Ansible)** | YAML | 无需写代码 |
| **Operator Framework (Helm)** | Helm Chart | 简单场景 |
| **Kopf** | Python | Python 开发者友好 |
| **KubeOps (Java)** | Java | Spring 生态 |

### Reconcile 逻辑示例

```go
func (r *WebAppReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    // 1. 获取 CR
    webapp := &examplev1.WebApp{}
    if err := r.Get(ctx, req.NamespacedName, webapp); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
    
    // 2. 获取或创建 Deployment
    deploy := &appsv1.Deployment{}
    deployName := types.NamespacedName{
        Name:      webapp.Name,
        Namespace: webapp.Namespace,
    }
    
    if err := r.Get(ctx, deployName, deploy); err != nil {
        if errors.IsNotFound(err) {
            // 创建 Deployment
            deploy = r.newDeployment(webapp)
            if err := r.Create(ctx, deploy); err != nil {
                return ctrl.Result{}, err
            }
        }
    }
    
    // 3. 同步期望状态
    expectedReplicas := webapp.Spec.Replicas
    if *deploy.Spec.Replicas != expectedReplicas {
        deploy.Spec.Replicas = &expectedReplicas
        if err := r.Update(ctx, deploy); err != nil {
            return ctrl.Result{}, err
        }
    }
    
    // 4. 更新 CR 状态
    webapp.Status.ReadyReplicas = deploy.Status.ReadyReplicas
    if err := r.Status().Update(ctx, webapp); err != nil {
        return ctrl.Result{}, err
    }
    
    return ctrl.Result{}, nil
}
```

---

## 准入控制器 Webhook

### Mutating Webhook 示例

```go
// 自动为 Pod 添加 Sidecar
func (s *SidecarInjector) Mutate(ctx context.Context, req admission.Request) admission.Response {
    pod := &corev1.Pod{}
    if err := s.decoder.Decode(req, pod); err != nil {
        return admission.Errored(http.StatusBadRequest, err)
    }
    
    // 检查是否需要注入
    if pod.Annotations["inject-sidecar"] != "true" {
        return admission.Allowed("no injection needed")
    }
    
    // 注入 Sidecar
    sidecar := corev1.Container{
        Name:  "sidecar",
        Image: "busybox",
        Command: []string{"sh", "-c", "sleep 3600"},
    }
    pod.Spec.Containers = append(pod.Spec.Containers, sidecar)
    
    // 返回修改后的对象
    marshaledPod, err := json.Marshal(pod)
    if err != nil {
        return admission.Errored(http.StatusInternalServerError, err)
    }
    
    return admission.PatchResponseFromRaw(req.Object.Raw, marshaledPod)
}
```

### Validating Webhook 示例

```go
// 验证 Pod 资源限制
func (v *PodValidator) Validate(ctx context.Context, req admission.Request) admission.Response {
    pod := &corev1.Pod{}
    if err := v.decoder.Decode(req, pod); err != nil {
        return admission.Errored(http.StatusBadRequest, err)
    }
    
    for _, container := range pod.Spec.Containers {
        if container.Resources.Limits.Memory().IsZero() {
            return admission.Denied(
                fmt.Sprintf("container %s must have memory limit", container.Name))
        }
    }
    
    return admission.Allowed("")
}
```

---

## 自定义控制器开发

### informer 机制

```
Informer 架构：

┌─────────────────────────────────────────┐
│              Informer                    │
│                                          │
│  Reflector ──► DeltaFIFO ──► Indexer    │
│      │           │            │          │
│      │           │            │          │
│      │           ▼            │          │
│      │      事件处理器        │          │
│      │      │                │          │
│      │      ├── AddFunc       │          │
│      │      ├── UpdateFunc     │          │
│      │      └── DeleteFunc     │          │
│      │                         │          │
│      └──── Watch/List ────────► apiserver │
│                                          │
└─────────────────────────────────────────┘
```

### 最小控制器示例

```go
package main

import (
    "context"
    "time"
    
    corev1 "k8s.io/api/core/v1"
    "k8s.io/client-go/informers"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/cache"
    "k8s.io/client-go/tools/clientcmd"
)

func main() {
    // 创建客户端
    config, _ := clientcmd.BuildConfigFromFlags("", "~/.kube/config")
    clientset, _ := kubernetes.NewForConfig(config)
    
    // 创建 Informer 工厂
    factory := informers.NewSharedInformerFactory(clientset, 30*time.Second)
    
    // 获取 Pod Informer
    podInformer := factory.Core().V1().Pods().Informer()
    
    // 注册事件处理器
    podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            fmt.Printf("Pod added: %s/%s\n", pod.Namespace, pod.Name)
        },
        UpdateFunc: func(old, new interface{}) {
            pod := new.(*corev1.Pod)
            fmt.Printf("Pod updated: %s/%s\n", pod.Namespace, pod.Name)
        },
        DeleteFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            fmt.Printf("Pod deleted: %s/%s\n", pod.Namespace, pod.Name)
        },
    })
    
    // 启动 Informer
    stopCh := make(chan struct{})
    factory.Start(stopCh)
    factory.WaitForCacheSync(stopCh)
    
    // 阻塞运行
    <-stopCh
}
```

---

## 高级调度

### Pod 拓扑分布约束

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 6
  template:
    spec:
      topologySpreadConstraints:
      - maxSkew: 1           # 最大差异数
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: my-app
```

**效果**：6 个副本均匀分布在 3 个可用区，每个区 2 个。

### Pod 优先级与抢占

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "High priority applications"
---
apiVersion: v1
kind: Pod
spec:
  priorityClassName: high-priority
```

**抢占机制**：

```
高优先级 Pod 需要调度，但无足够资源
    │
    ├── 找到可被抢占的低优先级 Pod
    ├── 驱逐低优先级 Pod
    ├── 等待低优先级 Pod 终止
    └── 调度高优先级 Pod
```

### Descheduler

Descheduler 用于**重新平衡**已调度的 Pod。

| 策略 | 作用 |
|------|------|
| `RemoveDuplicates` | 同一节点上移除重复的 Pod |
| `LowNodeUtilization` | 将 Pod 从低利用率节点迁移 |
| `RemovePodsViolatingTopologySpreadConstraint` | 修正拓扑分布不均 |
| `RemovePodsHavingTooManyRestarts` | 移除重启过多的 Pod |

---

## etcd 高级

### etcd 性能调优

```bash
# 1. 使用 SSD（必需）
# etcd 对延迟极度敏感，HDD 会导致严重性能问题

# 2. 独立磁盘
# etcd 数据目录应放在独立磁盘上
--data-dir=/var/lib/etcd

# 3. 快照频率
--snapshot-count=10000

# 4. 压缩
# 自动压缩历史版本
--auto-compaction-mode=periodic
--auto-compaction-retention=1h

# 5. 配额
--quota-backend-bytes=8589934592  # 8GB
```

### etcd 备份与恢复

```bash
# 备份
ETCDCTL_API=3 etcdctl snapshot save backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 恢复（到新集群）
etcdctl snapshot restore backup.db \
  --data-dir=/var/lib/etcd-new
```

---

## 性能优化

### apiserver 性能

```bash
# 1. 启用 API Priority and Fairness (1.20+)
# 防止某个客户端占用过多资源

# 2. 增加缓存大小
--watch-cache-sizes=node#1000,pod#10000

# 3. 启用流式 List（1.27+）
# 减少大 List 请求的内存占用

# 4. 分页查询
kubectl get pods --chunk-size=500
```

### kubelet 性能

```yaml
# /var/lib/kubelet/config.yaml
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "5%"
evictionSoft:
  memory.available: "200Mi"
  nodefs.available: "10%"
evictionSoftGracePeriod:
  memory.available: "1m"
  nodefs.available: "1m"
```

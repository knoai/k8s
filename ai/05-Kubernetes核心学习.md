# 05 - Kubernetes 核心学习

> 从 K8s 小白到 CKA 认证通过的系统学习指南

---

## 一、K8s 架构深度理解

### 1.1 控制平面组件

```
┌─────────────────────────────────────────────────────────┐
│                    Control Plane                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │ API Server  │  │   etcd      │  │ Scheduler   │     │
│  │ (REST入口)   │  │ (数据存储)   │  │ (调度器)     │     │
│  └──────┬──────┘  └─────────────┘  └──────┬──────┘     │
│         │                                   │           │
│  ┌──────┴───────────────────────────────────┴──────┐    │
│  │         Controller Manager                      │    │
│  │  (Deployment/StatefulSet/Job...控制器)          │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────┐
│                    Worker Node                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │   kubelet   │  │ kube-proxy  │  │ Container   │    │
│  │ (节点代理)   │  │ (网络代理)   │  │ Runtime     │    │
│  └─────────────┘  └─────────────┘  │ (docker/     │    │
│                                     │  containerd) │    │
│                                     └─────────────┘    │
└─────────────────────────────────────────────────────────┘
```

### 1.2 各组件详解

| 组件 | 功能 | 故障影响 | 高可用方案 |
|------|------|----------|-----------|
| **API Server** | 所有操作的入口，REST API | 集群不可用 | 多实例 + LB |
| **etcd** | 分布式键值存储，保存集群状态 | 数据丢失 | 3/5 节点集群 |
| **Scheduler** | Pod 调度决策 | 无法创建新 Pod | 多实例（一主多备） |
| **Controller Manager** | 维护资源期望状态 | 自愈失效 | 多实例 |
| **kubelet** | 节点上管理 Pod 生命周期 | 该节点 Pod 异常 | 节点级，无 HA |
| **kube-proxy** | 维护 Service 网络规则 | 服务访问异常 |  DaemonSet |

---

## 二、核心对象深度解析

### 2.1 Pod（最重要）

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-training-pod
  labels:
    app: training
    version: v1
spec:
  # 初始化容器：主容器启动前执行
  initContainers:
    - name: init-data
      image: busybox
      command: ['sh', '-c', 'wget -O /data/dataset.zip http://data-server/dataset.zip']
      volumeMounts:
        - name: data-volume
          mountPath: /data
  
  # 主容器
  containers:
    - name: trainer
      image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
      command: ["python", "train.py"]
      resources:
        limits:
          nvidia.com/gpu: 2
          memory: "64Gi"
          cpu: "16"
        requests:
          nvidia.com/gpu: 2
          memory: "32Gi"
          cpu: "8"
      env:
        - name: CUDA_VISIBLE_DEVICES
          value: "0,1"
        - name: BATCH_SIZE
          valueFrom:
            configMapKeyRef:
              name: training-config
              key: batch_size
      volumeMounts:
        - name: data-volume
          mountPath: /data
        - name: model-output
          mountPath: /output
      # 探针
      livenessProbe:
        exec:
          command:
            - python
            - -c
            - "import torch; print(torch.cuda.is_available())"
        initialDelaySeconds: 30
        periodSeconds: 60
  
  # 节点亲和性：调度到 GPU 节点
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: nvidia.com/gpu.present
                operator: In
                values: ["true"]
  
  # 容忍 GPU 节点污点
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  
  volumes:
    - name: data-volume
      persistentVolumeClaim:
        claimName: training-data-pvc
    - name: model-output
      persistentVolumeClaim:
        claimName: model-output-pvc
```

### 2.2 Pod 生命周期与状态

```
Pending → ContainerCreating → Running → Succeeded/Failed
   │            │                │
   │            ▼                ▼
   │      拉取镜像中          CrashLoopBackOff
   │      挂载卷中            ImagePullBackOff
   │      初始化容器运行        Evicted
   ▼
Scheduling（调度中）
   - 资源不足
   - 节点选择器不匹配
   - 污点/容忍不匹配
```

**常见状态排查**：

| 状态 | 原因 | 排查命令 |
|------|------|----------|
| `Pending` | 资源不足/调度失败 | `kubectl describe pod` 看 Events |
| `CrashLoopBackOff` | 容器反复崩溃 | `kubectl logs --previous` |
| `ImagePullBackOff` | 镜像拉取失败 | 检查镜像名、Secret、网络 |
| `OOMKilled` | 内存超限 | 增加 limits.memory |
| `Evicted` | 节点资源压力 | `kubectl describe node` |

### 2.3 Deployment（无状态应用）

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ml-api
  labels:
    app: ml-api
spec:
  replicas: 3
  # 选择器，必须匹配 template.labels
  selector:
    matchLabels:
      app: ml-api
  # 更新策略
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%        # 更新时最多超出的 Pod 数
      maxUnavailable: 0    # 更新时最少可用的 Pod 数（0=零停机）
  # 回滚配置
  revisionHistoryLimit: 10
  minReadySeconds: 30      # Pod ready 后等待多久算可用
  template:
    metadata:
      labels:
        app: ml-api
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
        - name: api
          image: ml-api:v1.2.3
          ports:
            - containerPort: 8080
          resources:
            limits:
              memory: "2Gi"
              cpu: "2000m"
          # 优雅终止
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
      terminationGracePeriodSeconds: 60
```

**Deployment 关键操作**：

```bash
# 滚动更新
kubectl set image deployment/ml-api api=ml-api:v1.2.4

# 查看更新状态
kubectl rollout status deployment/ml-api

# 暂停更新
kubectl rollout pause deployment/ml-api

# 恢复更新
kubectl rollout resume deployment/ml-api

# 回滚到上一个版本
kubectl rollout undo deployment/ml-api

# 回滚到指定版本
kubectl rollout undo deployment/ml-api --to-revision=3

# 查看历史版本
kubectl rollout history deployment/ml-api
```

### 2.4 Job / CronJob（批处理）

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: data-preprocessing
spec:
  # 完成数量
  completions: 1
  # 并行度
  parallelism: 1
  # 失败重试
  backoffLimit: 3
  # TTL，完成后自动清理
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: processor
          image: data-processor:latest
          command: ["python", "preprocess.py"]
          resources:
            requests:
              memory: "8Gi"
              cpu: "4"
```

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-training
spec:
  # 每天凌晨 2 点执行
  schedule: "0 2 * * *"
  # 超时时间
  startingDeadlineSeconds: 3600
  # 并发策略
  concurrencyPolicy: Forbid  # Forbid / Allow / Replace
  # 保留历史
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: trainer
              image: trainer:latest
              command: ["python", "train.py"]
```

### 2.5 StatefulSet（有状态应用）

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: milvus-standalone
spec:
  serviceName: milvus
  replicas: 1
  selector:
    matchLabels:
      app: milvus
  template:
    metadata:
      labels:
        app: milvus
    spec:
      containers:
        - name: milvus
          image: milvusdb/milvus:v2.4.0
          ports:
            - containerPort: 19530
          volumeMounts:
            - name: data
              mountPath: /var/lib/milvus
  # 关键：每个 Pod 有独立的 PVC
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
```

**StatefulSet 特点**：
- 稳定网络标识：`pod-name-N.service-name`
- 有序部署/扩缩：0→1→2
- 独立存储：每个 Pod 有自己的 PVC

---

## 三、调度深度理解

### 3.1 调度流程

```
1. Pod 创建 → 写入 etcd
2. Scheduler Watch 到未调度 Pod
3. 过滤阶段（Predicates）
   - 资源足够？
   - 节点亲和性匹配？
   - 污点容忍？
   - PV 绑定？
4. 评分阶段（Priorities）
   - 资源平衡
   - 节点亲和性权重
   - Pod 反亲和性
5. 选择最优节点 → 绑定 Pod → 写入 etcd
6. kubelet 监听到绑定 → 创建 Pod
```

### 3.2 资源请求与限制

```yaml
resources:
  requests:
    memory: "256Mi"    # 调度依据：节点需有这么多可用内存
    cpu: "250m"        # 调度依据：节点需有这么多可用 CPU
  limits:
    memory: "512Mi"    # 硬限制：超出即 OOMKilled
    cpu: "500m"        # 软限制：超出可被节流（不杀进程）
```

**重要**：GPU 没有 requests/limits 区别，`limits.nvidia.com/gpu` 同时是请求和限制。

### 3.3 完整调度示例

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-training
spec:
  # 节点亲和：优先选择 GPU 节点，必须满足 zone=zone-a
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: zone
                operator: In
                values: ["zone-a", "zone-b"]
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: gpu-type
                operator: In
                values: ["a100"]
        - weight: 50
          preference:
            matchExpressions:
              - key: network
                operator: In
                values: ["ib"]  # InfiniBand
  
  # Pod 反亲和：同一模型服务的 Pod 分散到不同节点
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values: ["llm-service"]
        topologyKey: kubernetes.io/hostname
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["llm-service"]
          topologyKey: topology.kubernetes.io/zone
  
  # Pod 亲和：推理服务靠近向量数据库
  podAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["milvus"]
          topologyKey: kubernetes.io/hostname
  
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "gpu"
      effect: "NoSchedule"
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  
  containers:
    - name: trainer
      image: pytorch/pytorch:latest
      resources:
        limits:
          nvidia.com/gpu: 4
          memory: "256Gi"
```

---

## 四、网络与存储

### 4.1 Service 类型详解

| 类型 | 访问方式 | 适用场景 |
|------|----------|----------|
| **ClusterIP** | 集群内部 DNS | 微服务间通信 |
| **NodePort** | `<NodeIP>:<Port>` | 测试/开发 |
| **LoadBalancer** | 云厂商 LB IP | 生产外部访问 |
| **ExternalName** | DNS CNAME | 外部服务映射 |
| **Headless** | Pod IP 直接访问 | StatefulSet |

```yaml
# Headless Service（StatefulSet 必备）
apiVersion: v1
kind: Service
metadata:
  name: milvus
spec:
  clusterIP: None  # Headless
  selector:
    app: milvus
  ports:
    - port: 19530
---
# 普通 ClusterIP
apiVersion: v1
kind: Service
metadata:
  name: llm-api
spec:
  selector:
    app: llm-api
  ports:
    - port: 80
      targetPort: 8000
      protocol: TCP
```

### 4.2 Ingress 与 Gateway API

```yaml
# 传统 Ingress（Ingress-NGINX）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ml-platform
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rate-limit: "100"
spec:
  tls:
    - hosts:
        - ml.example.com
      secretName: ml-tls
  rules:
    - host: ml.example.com
      http:
        paths:
          - path: /api/v1
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
          - path: /notebook
            pathType: Prefix
            backend:
              service:
                name: jupyter-service
                port:
                  number: 8888
```

```yaml
# Gateway API（新一代，推荐）
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ml-gateway
spec:
  gatewayClassName: envoy
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        certificateRefs:
          - name: ml-tls-cert
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-route
spec:
  parentRefs:
    - name: ml-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/chat
      backendRefs:
        - name: llm-service-v1
          port: 8000
          weight: 90
        - name: llm-service-v2
          port: 8000
          weight: 10
```

### 4.3 StorageClass 与动态供给

```yaml
# NFS StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-fast
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
reclaimPolicy: Retain
allowVolumeExpansion: true
mountOptions:
  - hard
  - nfsvers=4.1
---
# 使用
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-storage
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-fast
  resources:
    requests:
      storage: 500Gi
```

---

## 五、RBAC 与安全

### 5.1 ServiceAccount + Role + RoleBinding

```yaml
# ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ml-pipeline-sa
  namespace: kubeflow
---
# Role（命名空间级别）
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ml-pipeline-role
  namespace: kubeflow
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/exec"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "create", "delete"]
---
# RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ml-pipeline-binding
  namespace: kubeflow
subjects:
  - kind: ServiceAccount
    name: ml-pipeline-sa
    namespace: kubeflow
roleRef:
  kind: Role
  name: ml-pipeline-role
  apiGroup: rbac.authorization.k8s.io
```

### 5.2 NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ml-api-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: ml-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # 只允许来自 ingress-gateway 的流量
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
        - podSelector:
            matchLabels:
              app: ingress-nginx
      ports:
        - protocol: TCP
          port: 8000
  egress:
    # 只允许访问数据库和 Redis
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - protocol: TCP
          port: 5432
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 6379
```

---

## 六、Helm 包管理

### 6.1 Chart 结构

```
my-chart/
├── Chart.yaml          # Chart 元数据
├── values.yaml         # 默认配置值
├── charts/             # 依赖的 Chart
├── templates/          # K8s 模板文件
│   ├── _helpers.tpl    # 辅助模板
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── hpa.yaml
└── README.md
```

### 6.2 模板语法

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-chart.fullname" . }}
  labels:
    {{- include "my-chart.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  {{- if .Values.autoscaling.enabled }}
  {{- else }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  template:
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          {{- with .Values.nodeSelector }}
          nodeSelector:
            {{- toYaml . | nindent 8 }}
          {{- end }}
```

```yaml
# values.yaml
replicaCount: 2

image:
  repository: myapp
  tag: "v1.0.0"

resources:
  limits:
    cpu: 1000m
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 1Gi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

nodeSelector:
  node-type: gpu
```

---

## 七、故障排查手册

### 7.1 排查流程

```
1. kubectl get <resource> -o wide
   └─ 查看状态、节点、IP

2. kubectl describe <resource> <name>
   └─ 查看 Events、条件、详细信息

3. kubectl logs <pod> [-c <container>] [--previous]
   └─ 查看日志

4. kubectl exec -it <pod> -- /bin/sh
   └─ 进入容器排查

5. kubectl get events --sort-by='.lastTimestamp'
   └─ 查看集群事件
```

### 7.2 常见问题速查

| 问题 | 诊断 | 解决 |
|------|------|------|
| Pod 一直 Pending | `kubectl describe pod` 看 Events | 资源不足/调度失败 |
| ImagePullBackOff | `kubectl describe pod` | 检查镜像名/Secret |
| CrashLoopBackOff | `kubectl logs --previous` | 应用启动失败 |
| OOMKilled | `kubectl describe pod` | 增加 memory limits |
| 服务访问不通 | `kubectl get endpoints` | 检查 selector/端口 |
| PVC 一直 Pending | `kubectl describe pvc` | 检查 StorageClass |
| GPU 不可用 | `kubectl describe node` | 检查 GPU Operator |

---

## 八、CKA 认证攻略

### 8.1 考试信息

| 项目 | 内容 |
|------|------|
| 时长 | 2 小时 |
| 题数 | 17 题 |
| 满分 | 100 分 |
| 通过 | 66 分 |
| 形式 | 远程监考，命令行操作 |
| 允许 | 官方文档 (kubernetes.io) |
| 费用 | $395（或培训包含） |

### 8.2 高频考点

| 考点 | 分值 | 难度 |
|------|------|------|
| 集群升级 | 7% | 中 |
| ETCD 备份恢复 | 7% | 中 |
| NetworkPolicy | 7% | 中 |
| Service/Deployment | 10% | 低 |
| Pod 调度 | 10% | 中 |
| PVC/StorageClass | 7% | 中 |
| RBAC | 10% | 中 |
| 节点维护 | 7% | 低 |
| 排查故障节点 | 10% | 高 |
| 自定义调度器 | 7% | 高 |
| Sidecar/Init | 10% | 中 |
| 日志监控 | 8% | 低 |

### 8.3 备考建议

1. **KodeKloud 课程**：系统学习，有实验环境
2. **Killer.sh 模拟**：最接近真题，做 3 遍以上
3. **熟练文档搜索**：考试允许查文档，但要快
4. **命令行速度**：`kubectl` 别名、vim 熟练
5. **时间管理**：简单题 5min，难题 15min

```bash
# ~/.bashrc 中的 CKA 备考别名
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias kgp='kubectl get pods -o wide'
alias kgn='kubectl get nodes -o wide'
alias kgs='kubectl get svc -o wide'
alias kdf='kubectl delete -f'
alias kaf='kubectl apply -f'
alias kl='kubectl logs'
alias kex='kubectl exec -it'
```

# 08 - AI Infra 专家进阶

> 大规模 AI 基础设施的设计与优化：GPU 虚拟化、高级调度、网络优化、FinOps

---

## 一、GPU 虚拟化与共享

### 1.1 为什么需要 GPU 虚拟化？

```
问题：单用户独占 1 张 A100 80GB，实际只用 20GB
浪费：60GB 显存闲置，GPU 利用率 <30%

解决：GPU 虚拟化 → 多用户/多任务共享
效果：利用率 30% → 90%，成本降低 3-5×
```

### 1.2 方案对比深度分析

| 方案 | 隔离级别 | 显存切分 | 算力切分 | 故障隔离 | 适用场景 |
|------|----------|----------|----------|----------|----------|
| **Time Slicing** | 进程级时间片 | 无 | 时间共享 | 差 | 开发测试 |
| **MIG** | 硬件级 | 固定大小 | 固定比例 | 完整 | A100/H100 生产 |
| **HAMi vGPU** | 显存隔离 | 任意比例 | 可选限制 | 软隔离 | 通用生产 |
| **MPS** | CUDA Context | 无 | 时间共享 | 进程间共享 | 同用户多模型 |
| **vCluster** | 集群级 | 整卡 | 整卡 | 完整 | 强隔离多租户 |

### 1.3 HAMi 深度实战

#### 架构原理

```
┌─────────────────────────────────────────┐
│  User Pod A (申请 0.5 GPU, 20GB)         │
│  User Pod B (申请 0.3 GPU, 12GB)         │
│  User Pod C (申请 0.2 GPU, 8GB)          │
└────────────┬────────────┬───────────────┘
             │            │
             ▼            ▼
┌─────────────────────────────────────────┐
│  HAMi Scheduler Extender               │
│  └── 调度决策：哪个物理 GPU 承载        │
└─────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│  HAMi Device Plugin                    │
│  └── 拦截 CUDA 调用，做显存/算力限制    │
└─────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│  Physical GPU (40GB)                    │
└─────────────────────────────────────────┘
```

#### 安装配置

```bash
# 安装 HAMi
helm repo add hami-charts https://project-hami.github.io/HAMi/
helm repo update
helm install hami hami-charts/hami \
  --namespace kube-system \
  --set scheduler.kubeScheduler.enabled=true \
  --set devicePlugin.passDeviceToContainer=true

# 验证
kubectl get pods -n kube-system | grep hami
kubectl inspect gpushare-node  # 查看 vGPU 分配情况
```

#### 使用 vGPU

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-small
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
          args:
            - --model
            - Qwen/Qwen2.5-4B-Instruct
            - --dtype
            - half
          resources:
            limits:
              nvidia.com/gpu: 0.5        # 申请半个 GPU
              nvidia.com/gpumem: 8000    # 限制显存 8GB
              nvidia.com/gpucores: 50    # 限制算力 50%（可选）
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: embedding-service
spec:
  replicas: 5
  template:
    spec:
      containers:
        - name: tei
          image: ghcr.io/huggingface/text-embeddings-inference:1.5
          resources:
            limits:
              nvidia.com/gpu: 0.2        # 申请 1/5 GPU
              nvidia.com/gpumem: 4000    # 限制显存 4GB
```

### 1.4 MIG 配置（A100/H100）

```bash
# 查看 MIG 支持的配置
nvidia-smi mig -lgip

# 创建 MIG 实例（A100 40GB 示例）
# 配置：2 个 3g.20gb + 1 个 2g.10gb + 1 个 1g.5gb
nvidia-smi mig -cgi 9,9,19,14 -C

# 查看创建的实例
nvidia-smi mig -lgi

# K8s 中使用
apiVersion: v1
kind: Pod
metadata:
  name: mig-pod
spec:
  containers:
    - name: gpu-app
      image: nvidia/cuda:12.0-base
      resources:
        limits:
          nvidia.com/mig-3g.20gb: 1
```

**MIG 配置文件**：

```yaml
# /etc/nvidia-mig-manager/config.yaml
version: v1
mig-configs:
  all-disabled:
    - devices: all
      mig-enabled: false
  
  all-1g.5gb:
    - devices: all
      mig-enabled: true
      mig-devices:
        1g.5gb: 7
  
  balanced:
    - devices: all
      mig-enabled: true
      mig-devices:
        3g.20gb: 2
        2g.10gb: 1
        1g.5gb: 1
```

---

## 二、高级调度策略

### 2.1 Kueue 队列管理

#### 核心概念

| 概念 | 说明 |
|------|------|
| **ClusterQueue** | 集群级资源池，定义总资源配额 |
| **LocalQueue** | 命名空间级队列，用户提交入口 |
| **ResourceFlavor** | 资源类型定义（GPU 型号等） |
| **Workload** | 被调度的作业单元 |
| **Admission** | 准入检查，资源足够才允许执行 |

#### 配置示例

```yaml
# 1. 定义资源类型
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: nvidia-a100-40gb
spec:
  nodeLabels:
    nvidia.com/gpu.product: NVIDIA-A100-SXM4-40GB
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: nvidia-h100-80gb
spec:
  nodeLabels:
    nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
---
# 2. 定义集群队列
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: gpu-cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: nvidia-a100-40gb
          resources:
            - name: "cpu"
              nominalQuota: 256
              borrowingLimit: 64
            - name: "memory"
              nominalQuota: 1Ti
            - name: "nvidia.com/gpu"
              nominalQuota: 32
        - name: nvidia-h100-80gb
          resources:
            - name: "cpu"
              nominalQuota: 128
            - name: "memory"
              nominalQuota: 512Gi
            - name: "nvidia.com/gpu"
              nominalQuota: 16
  preemption:
    reclaimWithinCohort: Any
    borrowWithinCohort:
      policy: LowerPriority
      maxPriorityThreshold: 100
---
# 3. 定义本地队列
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: team-a-gpu
  namespace: team-a
spec:
  clusterQueue: gpu-cluster-queue
---
# 4. 提交作业（Workload）
apiVersion: batch/v1
kind: Job
metadata:
  name: team-a-training
  namespace: team-a
  labels:
    kueue.x-k8s.io/queue-name: team-a-gpu
spec:
  template:
    spec:
      containers:
        - name: trainer
          image: pytorch/pytorch:latest
          resources:
            limits:
              nvidia.com/gpu: 4
      restartPolicy: Never
```

### 2.2 优先级与抢占

```yaml
# 优先级类
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: inference-critical
value: 1000000
globalDefault: false
description: "核心业务推理服务，不可被抢占"
preemptionPolicy: Never              # 不抢占他人，也不被抢占
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: training-batch
value: 100000
globalDefault: false
description: "批量训练任务，可被抢占"
preemptionPolicy: PreemptLowerPriority
---
# 使用
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-production
spec:
  template:
    spec:
      priorityClassName: inference-critical
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
```

### 2.3 拓扑感知调度

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: topology-training
spec:
  schedulerName: volcano
  plugins:
    pytorch: []
    env: []
    svc: []
  policies:
    - event: PodEvicted
      action: RestartJob
  tasks:
    - replicas: 8
      name: worker
      template:
        spec:
          affinity:
            podAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchExpressions:
                      - key: volcano.sh/job-name
                        operator: In
                        values: ["topology-training"]
                  topologyKey: kubernetes.io/hostname   # 同节点优先
            podAntiAffinity:
              preferredDuringSchedulingIgnoredDuringExecution:
                - weight: 100
                  podAffinityTerm:
                    labelSelector:
                      matchExpressions:
                        - key: volcano.sh/job-name
                          operator: In
                          values: ["topology-training"]
                    topologyKey: topology.kubernetes.io/zone  # 跨可用区容错
          containers:
            - name: worker
              image: pytorch/pytorch:latest
              resources:
                limits:
                  nvidia.com/gpu: 1
```

---

## 三、网络优化

### 3.1 RDMA / InfiniBand 原理

```
传统 TCP/IP 网络：
应用 → Socket → TCP/IP 协议栈 → 网卡驱动 → 网卡 → 线缆
延迟：~50-100μs

RDMA 网络：
应用 → Verbs API → 网卡（硬件处理协议） → 线缆
延迟：~1-2μs（InfiniBand）

优势：
- 零拷贝：数据直接从应用内存到网卡
- 内核旁路：不经过操作系统网络栈
- CPU 卸载：协议处理由网卡硬件完成
```

### 3.2 NCCL 环境变量调优

```bash
# 基础配置
export NCCL_DEBUG=INFO                    # 调试信息级别
export NCCL_IB_DISABLE=0                  # 启用 InfiniBand
export NCCL_SOCKET_IFNAME=ib0             # 指定 IB 网卡
export NCCL_NET_GDR_LEVEL=5               # GPU Direct RDMA 级别
export NCCL_TREE_THRESHOLD=0              # 始终使用 Tree AllReduce

# 性能调优
export NCCL_BUFFSIZE=2097152              # 通信缓冲区大小（2MB）
export NCCL_P2P_LEVEL=NVL                 # NVLink 优先
export NCCL_SHARP_DISABLE=0               # 启用 SHARP（交换机内聚合）
export NCCL_ALGO=RING                     # AllReduce 算法：RING/TREE

# 多机优化
export NCCL_CROSS_NIC=1                   # 跨 NIC 通信
export NCCL_IB_HCA=mlx5_0,mlx5_1          # 指定 IB 设备
export NCCL_IB_GID_INDEX=3                # RoCE v2
export NCCL_IB_TC=106                     # 流量类别
export NCCL_IB_QPS_PER_CONNECTION=4       # 每连接 QP 数
```

### 3.3 网络性能测试

```bash
# IB 带宽测试（服务器端）
ib_write_bw -d mlx5_0 --report_gbits

# IB 带宽测试（客户端）
ib_write_bw -d mlx5_0 <server_ip> --report_gbits

# IB 延迟测试
ib_write_lat -d mlx5_0

# NCCL 性能测试
mpirun -np 8 ./build/all_reduce_perf -b 8M -e 1G -f 2 -g 1

# PyTorch 分布式测试
python -m torch.distributed.run \
  --nproc_per_node=8 \
  --nnodes=2 \
  --node_rank=0 \
  --master_addr=<master_ip> \
  benchmark_all_reduce.py
```

### 3.4 多机网络配置检查清单

- [ ] IB 网卡状态正常：`ibstat`、`ibstatus`
- [ ] IB 子网管理器运行：`systemctl status opensm`
- [ ] RDMA 连接正常：`rping -s` / `rping -c <ip>`
- [ ] GPU Direct RDMA 启用：`nvidia-smi topo -m`
- [ ] NCCL 测试通过：`all_reduce_perf` 达到理论带宽 80%+
- [ ] 防火墙放行 IB 端口（如果启用）

---

## 四、可观测性体系

### 4.1 GPU 监控架构

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ DCGM Exporter│────▶│ Prometheus  │────▶│  Grafana    │
│ (GPU 指标)   │     │ (时序数据库) │     │ (可视化)    │
└─────────────┘     └─────────────┘     └─────────────┘
       │
       ├── dcgm_gpu_utilization
       ├── dcgm_mem_copy_utilization
       ├── dcgm_power_usage
       ├── dcgm_temperature
       ├── dcgm_pcie_tx_bytes
       └── dcgm_xid_errors
```

### 4.2 DCGM Exporter 部署

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
    spec:
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.0-3.2.0-ubuntu22.04
          env:
            - name: DCGM_EXPORTER_LISTEN
              value: ":9400"
          ports:
            - name: metrics
              containerPort: 9400
          resources:
            limits:
              memory: "256Mi"
              cpu: "500m"
```

### 4.3 关键告警规则

```yaml
groups:
  - name: gpu-alerts
    rules:
      - alert: GPUUtilizationLow
        expr: avg_over_time(dcgm_gpu_utilization[5m]) < 30
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "GPU {{ $labels.gpu }} 利用率持续低于 30%"
          description: "节点 {{ $labels.instance }} GPU {{ $labels.gpu }} 利用率 {{ $value }}%"
          
      - alert: GPUOverheating
        expr: dcgm_temperature > 85
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "GPU 温度过高"
          
      - alert: GPUXidError
        expr: increase(dcgm_xid_errors_count[5m]) > 0
        labels:
          severity: critical
        annotations:
          summary: "GPU 出现 Xid 错误: {{ $labels.xid }}"
          description: "Xid 错误码含义请查阅 NVIDIA 文档"
          
      - alert: GPUMemoryNearFull
        expr: dcgm_fb_used / dcgm_fb_free > 0.95
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "GPU 显存即将耗尽"
          
      - alert: InferenceHighLatency
        expr: histogram_quantile(0.99, rate(vllm_time_to_first_token_seconds_bucket[5m])) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "推理 P99 延迟超过 2s"
```

### 4.4 LLM 推理监控面板

| 面板 | PromQL | 说明 |
|------|--------|------|
| QPS | `rate(vllm_request_count[1m])` | 每秒请求数 |
| TTFT P50/P99 | `histogram_quantile(0.5/0.99, rate(vllm_time_to_first_token_seconds_bucket[5m]))` | 首 Token 延迟 |
| TPOT | `rate(vllm_generation_tokens_total[1m]) / rate(vllm_generation_requests_total[1m])` | 每输出 Token 时间 |
| GPU 利用率 | `dcgm_gpu_utilization` | 计算利用率 |
| 显存使用 | `dcgm_fb_used / 1024 / 1024 / 1024` | GB |
| 队列深度 | `vllm_num_requests_waiting` | 等待请求数 |
| Token 吞吐 | `rate(vllm_generation_tokens_total[1m])` | tokens/s |

---

## 五、FinOps：GPU 成本优化

### 5.1 成本构成分析

```
GPU 集群年度成本（示例：100 张 A100 40GB）
├── 机器成本：$2/h × 100 × 8760h = $1,752,000
├── 网络成本：IB 交换机 + 线缆 = $200,000
├── 存储成本：NVMe SSD + 对象存储 = $100,000
├── 人力成本：5 人 × $150k = $750,000
└── 其他：电力、机房 = $200,000
    总计：~$3M/年

优化目标：通过利用率提升，等效节省 30-50% = $1-1.5M
```

### 5.2 Karpenter 自动扩缩

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: gpu-spot
spec:
  template:
    metadata:
      labels:
        node-type: gpu-spot
    spec:
      requirements:
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["p4d.24xlarge", "p3.8xlarge"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]          # 优先 Spot
        - key: nvidia.com/gpu.product
          operator: In
          values: ["NVIDIA-A100-SXM4-40GB"]
      taints:
        - key: spot
          value: "true"
          effect: NoSchedule
  limits:
    nvidia.com/gpu: 100
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h
    budgets:
      - nodes: "10%"
        schedule: "0 9-17 * * mon-fri"  # 工作时间最多回收 10%
---
# 使用 Spot 的 Pod
apiVersion: batch/v1
kind: Job
metadata:
  name: spot-training
spec:
  template:
    spec:
      tolerations:
        - key: spot
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: trainer
          image: pytorch/pytorch:latest
          resources:
            limits:
              nvidia.com/gpu: 4
          # 配置 Checkpoint 保存
          command:
            - python
            - train.py
            - --checkpoint-interval=100
            - --checkpoint-path=s3://checkpoints/
      restartPolicy: OnFailure
```

### 5.3 成本分摊与计费

```python
# GPU 使用成本分摊系统
class GPUCostAllocator:
    def __init__(self):
        self.gpu_hourly_cost = {
            "NVIDIA-A100-SXM4-40GB": 2.0,
            "NVIDIA-A100-SXM4-80GB": 3.5,
            "NVIDIA-H100-80GB": 5.0,
            "NVIDIA-A10G": 1.2,
        }
    
    def calculate_daily_cost(self, namespace: str) -> dict:
        """按 Namespace 计算每日 GPU 成本"""
        pods = get_pods_by_namespace(namespace)
        total_cost = 0.0
        gpu_breakdown = {}
        
        for pod in pods:
            for container in pod.spec.containers:
                gpu_limit = container.resources.limits.get("nvidia.com/gpu", 0)
                if gpu_limit > 0:
                    node = get_node(pod.spec.node_name)
                    gpu_type = node.labels.get("nvidia.com/gpu.product")
                    hours = pod.runtime_hours
                    
                    cost = gpu_limit * hours * self.gpu_hourly_cost.get(gpu_type, 2.0)
                    total_cost += cost
                    gpu_breakdown[gpu_type] = gpu_breakdown.get(gpu_type, 0) + cost
        
        return {
            "namespace": namespace,
            "total_cost": total_cost,
            "gpu_breakdown": gpu_breakdown,
            "date": datetime.now().strftime("%Y-%m-%d")
        }
```

---

## 六、安全与治理

### 6.1 多租户隔离方案

| 隔离维度 | 技术方案 | 说明 |
|----------|----------|------|
| **网络隔离** | NetworkPolicy + Cilium | 命名空间间默认拒绝 |
| **存储隔离** | PVC + StorageClass | 每个租户独立存储配额 |
| **计算隔离** | HAMi / MIG | GPU 资源隔离 |
| **权限隔离** | RBAC + ServiceAccount | 最小权限原则 |
| **镜像隔离** | Harbor 多项目 | 镜像签名与扫描 |
| **审计隔离** | 审计日志分租户 | 操作可追溯 |

### 6.2 Kyverno 策略完整配置

```yaml
# 1. 禁止特权容器
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  validationFailureAction: Enforce
  rules:
    - name: privileged-containers
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
                  allowPrivilegeEscalation: "false"
                  privileged: "false"
---
# 2. 强制 GPU 资源限制
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-gpu-limits
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-gpu-limits
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "GPU requests must be specified and equal to limits"
        pattern:
          spec:
            containers:
              - resources:
                  limits:
                    nvidia.com/gpu: "?*"
                  requests:
                    nvidia.com/gpu: "?= Limits.nvidia.com/gpu"
---
# 3. 强制镜像签名
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        resources:
          kinds:
            - Pod
      verifyImages:
        - imageReferences:
            - "your-registry.com/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |
                      -----BEGIN PUBLIC KEY-----
                      ...
                      -----END PUBLIC KEY-----
```

### 6.3 镜像安全扫描

```yaml
# Trivy Operator 自动扫描
apiVersion: aquasecurity.github.io/v1alpha1
kind: Trivy
metadata:
  name: trivy-scan
spec:
  scanPolicy:
    severity:
      - CRITICAL
      - HIGH
    ignoreUnfixed: false
  report:
    format: summary
```

---

## 七、专家级实践项目

### 项目 1：多租户 GPU 云平台

**架构**：
```
租户 A (team-a)
├── Namespace: team-a
├── ResourceQuota: 8 GPU, 256GB RAM
├── NetworkPolicy: 仅允许访问公共服务
├── LocalQueue: team-a-queue (Kueue)
└── Pods: 使用 HAMi vGPU 共享

租户 B (team-b)
├── Namespace: team-b
├── ResourceQuota: 16 GPU, 512GB RAM
├── NetworkPolicy: 隔离于租户 A
├── LocalQueue: team-b-queue (Kueue)
└── Pods: 使用 HAMi vGPU 共享

平台管理
├── ClusterQueue: 总资源池
├── Kyverno: 策略强制
├── Prometheus+Grafana: 监控计费
└── Harbor: 镜像仓库
```

**功能清单**：
- [ ] 租户自助申请资源配额
- [ ] vGPU 细粒度分配（显存/算力）
- [ ] 按 Namespace 成本统计与告警
- [ ] 网络隔离与安全防护
- [ ] 镜像扫描与签名验证

### 项目 2：生产级 LLM 推理平台

**架构**：
```
流量入口
├── CDN / WAF
├── Envoy Gateway
│   └── 限流 / 认证 / 路由
├── KServe InferenceService
│   ├── vLLM Pod × N（自动扩缩）
│   ├── Prometheus 监控
│   └── KEDA 自动扩缩
└── 模型存储（JuiceFS + S3）
```

**功能清单**：
- [ ] 多模型版本管理
- [ ] Canary / A-B 测试
- [ ] KEDA 基于队列长度自动扩缩
- [ ] Prometheus + Grafana 全链路监控
- [ ] 请求日志与审计
- [ ] 成本控制与限额

### 项目 3：大规模训练网络优化

**目标**：优化 64 节点 × 8 GPU 分布式训练性能。

**优化清单**：
- [ ] IB 网络拓扑优化
- [ ] NCCL 参数调优
- [ ] GPU 亲和性调度
- [ ] Checkpoint 异步保存
- [ ] 训练故障自动恢复

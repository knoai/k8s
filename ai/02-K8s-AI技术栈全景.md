# 02 - K8s AI 技术栈全景

> Kubernetes AI Native 生态组件分层详解与技术选型指南

---

## 一、架构总览

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 6. AI 工作流与智能编排层                                                │
│    Kubeflow │ AIBrix │ LangGraph │ KubeEdge │ Flyte │ Airflow         │
├─────────────────────────────────────────────────────────────────────────┤
│ 5. 推理服务层                                                           │
│    KServe │ vLLM │ TensorRT-LLM │ SGLang │ TGI │ LMDeploy │ Kaito    │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. 调度与资源管理层                                                     │
│    Volcano │ Kueue │ Karpenter │ HAMi │ DraNet │ GPU Operator │ Yunikorn│
├─────────────────────────────────────────────────────────────────────────┤
│ 3. 存储与数据层                                                         │
│    JuiceFS │ MinIO │ Alluxio │ Open Data Hub │ Ceph │ CephFS        │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. 网络与服务入口层                                                     │
│    Envoy Gateway │ Cilium │ Ingress-NGINX │ Calico │ Multus        │
├─────────────────────────────────────────────────────────────────────────┤
│ 1. 可观测与智能运维层                                                   │
│    Prometheus │ Grafana │ OpenTelemetry │ KEDA │ K8sGPT │ Kyverno   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 二、推理服务层（第 5 层）

### 2.1 核心组件详解

#### KServe

| 属性 | 详情 |
|------|------|
| **定位** | K8s 原生模型服务框架，CNCF Incubating 项目 |
| **核心概念** | InferenceService CRD、Predictor、Transformer、Explainer |
| **自动扩缩** | 支持 KPA（Knative）、HPA、自定义指标 |
| **高级特性** | Canary 发布、A/B 测试、多模型管理、GPU 自动伸缩 |
| **支持框架** | TFServing、TorchServe、ONNXRuntime、Triton、vLLM、HuggingFace |
| **适用场景** | 企业级模型服务统一入口 |

**关键 YAML 示例**：
```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: gs://kfserving-examples/models/sklearn/1.0/model
```

#### vLLM

| 属性 | 详情 |
|------|------|
| **定位** | 高性能 LLM 推理引擎 |
| **核心技术** | PagedAttention、Continuous Batching、Prefix Caching |
| **性能提升** | 相比 HF TGI，吞吐提升 5-10× |
| **量化支持** | AWQ、GPTQ、FP8、SqueezeLLM |
| **分布式** | Tensor Parallel、Pipeline Parallel |
| **适用场景** | LLM 生产推理首选 |

**启动命令**：
```bash
vllm serve meta-llama/Llama-3.1-8B-Instruct \
  --tensor-parallel-size 1 \
  --dtype half \
  --max-model-len 8192
```

#### TensorRT-LLM

| 属性 | 详情 |
|------|------|
| **定位** | NVIDIA 官方高性能推理引擎 |
| **优势** | NVIDIA GPU 上极致性能，FP8 支持最好 |
| **劣势** | 仅支持 NVIDIA、编译时间长、灵活性低 |
| **适用场景** | H100/A100 生产环境，追求极致性能 |

### 2.2 推理引擎选型决策

```
问题 1：什么模型？
├── LLM（>1B 参数）
│   ├── NVIDIA GPU → TensorRT-LLM（极致）/ vLLM（通用）
│   ├── 国产 GPU → vLLM / LMDeploy
│   └── CPU/边缘 → llama.cpp / Ollama
├── 传统 ML（<1B）
│   └── Triton / TorchServe / MLServer
└── 多模态
    └── vLLM（支持 vision）/ 自研服务

问题 2：什么场景？
├── 高并发在线服务 → vLLM + KServe + KEDA
├── 低延迟交互 → TensorRT-LLM + Triton
├── 离线批量推理 → Ray + Batch 处理
└── 边缘/本地 → llama.cpp / MLC-LLM
```

---

## 三、调度与资源管理层（第 4 层）

### 3.1 为什么需要专用调度器？

传统 K8s 调度器的局限：
- 不支持 **Gang Scheduling**（All-or-Nothing）
- 无 **Queue** 概念
- 不感知 **GPU 拓扑**
- 不支持 **Job 优先级与抢占**

### 3.2 核心组件详解

#### Volcano

| 属性 | 详情 |
|------|------|
| **定位** | 批处理与 AI 作业调度器 |
| **核心能力** | Gang Scheduling、Queue、优先级、拓扑感知、抢占 |
| **资源模型** | Job → Task → Pod |
| **适用场景** | 分布式训练、大规模批处理 |

**关键概念**：
```
Queue（队列）→ 资源配额 + 优先级
  └── Job（作业）→ Gang Scheduling 单位
       └── Task（任务组）→ 同构副本
            └── Pod（实例）→ 实际运行单元
```

#### Kueue

| 属性 | 详情 |
|------|------|
| **定位** | K8s 官方作业队列管理器（SIG Scheduling） |
| **核心能力** | ClusterQueue、LocalQueue、ResourceFlavor、Workloads |
| **优势** | 与 K8s 原生深度集成，社区活跃 |
| **适用场景** | 多租户 GPU 集群资源管理 |

#### Karpenter

| 属性 | 详情 |
|------|------|
| **定位** | 节点自动扩缩容（替代 Cluster Autoscaler） |
| **核心能力** | 秒级启动、多实例类型、Spot 实例、Consolidation |
| **优势** | 比 CAS 更快、更省、更灵活 |
| **适用场景** | GPU 节点池弹性供给 |

#### HAMi

| 属性 | 详情 |
|------|------|
| **定位** | 异构算力虚拟化（原 Volcano vGPU） |
| **核心能力** | GPU 显存隔离、算力限制、多卡虚拟化 |
| **模式** | HAMi-Core（软隔离）/ Dynamic MIG（硬隔离） |
| **适用场景** | 多租户 GPU 共享 |

### 3.3 调度方案选型

| 场景 | 推荐方案 | 说明 |
|------|----------|------|
| 单集群分布式训练 | Volcano | Gang Scheduling 必需 |
| 多租户配额管理 | Kueue + Volcano | 队列 + 调度配合 |
| GPU 共享（多小任务） | HAMi + 默认调度器 | vGPU 隔离 |
| 节点弹性扩缩 | Karpenter | 快速响应 |
| 大规模混部 | Volcano + Kueue + HAMi | 全栈方案 |

---

## 四、存储与数据层（第 3 层）

### 4.1 AI 场景存储需求

| 需求 | 特点 | 传统存储问题 |
|------|------|-------------|
| 大模型文件 | 数十 GB，顺序读 | NFS 性能差 |
| 训练数据 | 海量小文件，高并发 | 元数据瓶颈 |
| 检查点 | 频繁写入，大文件 | 写入延迟高 |
| 多节点共享 | 所有节点同时读 | 带宽不足 |

### 4.2 核心组件

#### JuiceFS

| 属性 | 详情 |
|------|------|
| **架构** | 数据存对象存储（S3/MinIO），元数据存 Redis/DB |
| **优势** | POSIX 兼容、高吞吐、缓存加速、K8s CSI 支持 |
| **适用场景** | 模型权重共享、训练数据存储 |

```yaml
# JuiceFS PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-storage
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: juicefs-sc
  resources:
    requests:
      storage: 1Ti
```

#### MinIO

| 属性 | 详情 |
|------|------|
| **定位** | 高性能对象存储，S3 兼容 |
| **优势** | 轻量、高性能、K8s 原生 |
| **适用场景** | 模型 Artifact 存储、日志、备份 |

#### Alluxio

| 属性 | 详情 |
|------|------|
| **定位** | 数据编排层，统一数据访问 |
| **优势** | 跨存储统一访问、智能缓存、零拷贝 |
| **适用场景** | 多云/混合云数据访问 |

### 4.3 存储方案选型

```
模型权重存储    → JuiceFS（POSIX + 缓存）
训练数据        → JuiceFS / Alluxio + 底层 S3
Checkpoint      → 本地 NVMe SSD + 异步上传 S3
日志/Artifact   → MinIO / S3
实时特征        → Redis / Feature Store
```

---

## 五、网络与服务入口层（第 2 层）

### 5.1 AI 场景网络需求

| 场景 | 带宽需求 | 延迟要求 | 技术 |
|------|----------|----------|------|
| 单节点多卡 | 900GB/s (NVLink) | <1μs | NVLink + NVSwitch |
| 单机多节点 | 200-400Gbps | <2μs | InfiniBand / RoCE |
| 跨可用区 | 25-100Gbps | <10ms | VPC 网络 |
| 公网访问 | 1-10Gbps | <100ms | CDN + LB |

### 5.2 核心组件

#### Cilium

| 属性 | 详情 |
|------|------|
| **定位** | eBPF 驱动的网络、安全与可观测性 |
| **核心能力** | 零信任网络、流量加密、网络策略、Hubble 观测 |
| **优势** | 性能高、可观测性强、安全策略灵活 |
| **适用场景** | 多租户 GPU 集群网络隔离 |

#### Envoy Gateway + Inference Extension

| 属性 | 详情 |
|------|------|
| **定位** | K8s Gateway API 实现，支持推理感知路由 |
| **核心能力** | 模型版本路由、A/B 测试、流量镜像 |
| **适用场景** | 模型服务入口网关 |

---

## 六、可观测与智能运维层（第 1 层）

### 6.1 AI 场景特有监控需求

| 维度 | 传统应用 | AI 应用 |
|------|----------|--------|
| 资源 | CPU/内存 | **GPU 利用率/显存/温度/功耗** |
| 性能 | 请求延迟 | **TTFT / TPOT / Token 吞吐** |
| 业务 | QPS/错误率 | **模型准确率 / 幻觉率** |
| 数据 | 日志/ trace | **数据漂移 / 模型退化** |

### 6.2 核心组件

#### DCGM Exporter

NVIDIA 官方 GPU 监控，关键指标：
- `DCGM_FI_DEV_GPU_UTIL` — GPU 计算利用率
- `DCGM_FI_DEV_MEM_COPY_UTIL` — 显存带宽利用率
- `DCGM_FI_DEV_POWER_USAGE` — 功耗
- `DCGM_FI_DEV_XID_ERRORS` — GPU 错误码
- `DCGM_FI_PROF_PCIE_TX_BYTES` — PCIe 发送带宽

#### KEDA

事件驱动自动扩缩容，支持触发器：
- Prometheus 指标（GPU 利用率、请求队列长度）
- Kafka 消息队列
- HTTP 请求速率
- Cron（定时扩缩）

#### K8sGPT

AI 辅助诊断工具，使用 LLM 分析 K8s 事件：
```bash
k8sgpt analyze --explain
# 自动分析 Pod 异常并给出修复建议
```

---

## 七、AI 工作流与编排层（第 6 层）

### 7.1 工作流类型对比

| 类型 | 代表工具 | 特点 | 适用 |
|------|----------|------|------|
| **ML Pipeline** | Kubeflow Pipelines | 面向 ML 全生命周期 | 训练→评估→部署 |
| **通用工作流** | Airflow / Argo | 通用 DAG 编排 | ETL / 数据处理 |
| **Agent 工作流** | LangGraph / AutoGen | 面向 LLM Agent | 多步推理 / 工具调用 |
| **训练专用** | Kubeflow Trainer / Ray Train | 分布式训练抽象 | 大规模训练 |
| **推理架构** | AIBrix | LLM 推理研究框架 | 调度+缓存+混合架构 |

### 7.2 Kubeflow 组件关系

```
Kubeflow Platform
├── Central Dashboard          # 统一入口
├── Notebooks                  # 交互式开发
├── Pipelines                  # 工作流编排
│   └── SDK (DSL)              # Python SDK
├── KServe                     # 模型服务
├── Katib                      # 超参数调优
├── Training Operator          # 分布式训练
│   ├── TFJob                  # TensorFlow
│   ├── PyTorchJob             # PyTorch
│   ├── MPIJob                 # MPI
│   └── XGBoostJob             # XGBoost
└── Model Registry             # 模型版本管理
```

---

## 八、技术栈选型总图

### 8.1 按场景选型

| 场景 | 推荐组合 |
|------|----------|
| **中小企业 MLOps** | Kubeflow + KServe + MLflow + MinIO |
| **大厂训练平台** | Volcano + Ray + JuiceFS + Prometheus |
| **LLM 推理服务** | vLLM + KServe + KEDA + Envoy Gateway |
| **多租户 GPU 云** | HAMi + Kueue + Cilium + Grafana |
| **边缘 AI** | KubeEdge + llama.cpp + MinIO |
| **国产替代** | Volcano + MindSpore + 昇腾 NPU |

### 8.2 按规模选型

| 规模 | GPU 数量 | 推荐方案 |
|------|----------|----------|
| 实验室 | 1-4 | minikube + vLLM + MLflow |
| 部门级 | 4-32 | RKE/k3s + Kubeflow + Volcano |
| 公司级 | 32-256 | 商业 K8s + 全栈 Kubeflow + Kueue |
| 超大规模 | 256+ | 自研平台 + 多集群联邦 + 定制调度 |

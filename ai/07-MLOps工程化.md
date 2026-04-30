# 07 - MLOps 工程化

> 企业级 AI 工作流的全链路能力构建：Pipeline、Katib、Volcano、Ray、vLLM

---

## 一、Kubeflow Pipelines 高级

### 1.1 自定义组件开发

```python
# 方式 1：轻量 Python 组件（推荐简单场景）
from kfp import dsl

@dsl.component(
    base_image='python:3.9-slim',
    packages_to_install=['pandas', 'numpy']
)
def process_data(
    input_path: str,
    output_path: dsl.OutputPath(str),
    normalize: bool = True
):
    import pandas as pd
    import numpy as np
    
    df = pd.read_csv(input_path)
    
    if normalize:
        df = (df - df.mean()) / df.std()
    
    df.to_csv(output_path, index=False)

# 方式 2：容器化组件（推荐复杂/可复用场景）
# 先构建镜像 docker build -t my-component:latest .
process_op = dsl.ContainerOp(
    name='process-data',
    image='my-component:latest',
    command=['python', 'process.py'],
    arguments=['--input', input_path, '--output', output_path],
    file_outputs={'output': '/output/data.csv'}
)
```

### 1.2 Artifact 与元数据传递

```python
from kfp.dsl import Input, Output, Dataset, Model, Metrics, ClassificationMetrics

@dsl.component
def train_and_evaluate(
    train_data: Input[Dataset],
    test_data: Input[Dataset],
    model: Output[Model],
    metrics: Output[Metrics],
    classification_metrics: Output[ClassificationMetrics]
):
    import json
    import pickle
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.metrics import accuracy_score, confusion_matrix
    
    # 加载数据
    import pandas as pd
    train_df = pd.read_csv(f"{train_data.path}/train.csv")
    test_df = pd.read_csv(f"{test_data.path}/test.csv")
    
    # 训练
    X_train, y_train = train_df.drop('target', axis=1), train_df['target']
    X_test, y_test = test_df.drop('target', axis=1), test_df['target']
    
    clf = RandomForestClassifier(n_estimators=100)
    clf.fit(X_train, y_train)
    
    # 评估
    y_pred = clf.predict(X_test)
    acc = accuracy_score(y_test, y_pred)
    cm = confusion_matrix(y_test, y_pred)
    
    # 保存模型 Artifact
    with open(f"{model.path}/model.pkl", 'wb') as f:
        pickle.dump(clf, f)
    
    # 保存指标
    metrics_dict = {"accuracy": acc, "precision": 0.92, "recall": 0.89}
    with open(metrics.path, 'w') as f:
        json.dump(metrics_dict, f)
    
    # 保存分类指标（可视化）
    classification_metrics.log_confusion_matrix(
        categories=['class_0', 'class_1', 'class_2'],
        matrix=cm.tolist()
    )
```

### 1.3 条件、循环与并行

```python
@dsl.pipeline(name='advanced-pipeline')
def advanced_pipeline(threshold: float = 0.9):
    # 数据预处理
    preprocess = preprocess_task()
    
    # 条件分支：数据量决定训练策略
    with dsl.Condition(preprocess.outputs['data_size'] > 100000):
        # 大数据：分布式训练
        train = distributed_train_task(data=preprocess.outputs['dataset'])
    
    with dsl.Condition(preprocess.outputs['data_size'] <= 100000):
        # 小数据：单机训练
        train = single_node_train_task(data=preprocess.outputs['dataset'])
    
    # 并行评估多种模型
    with dsl.ParallelFor(['random_forest', 'xgboost', 'svm']) as algorithm:
        eval_task = evaluate_task(
            model=train.outputs['model'],
            algorithm=algorithm
        )
    
    # 选择最佳模型
    select_best = select_best_model_task(
        metrics=dsl.Collected(eval_task.outputs['metrics'])
    )
    
    # 部署最佳模型
    with dsl.Condition(select_best.outputs['accuracy'] > threshold):
        deploy = deploy_task(model=select_best.outputs['model'])
    
    with dsl.Condition(select_best.outputs['accuracy'] <= threshold):
        alert = send_alert_task(message="Model accuracy below threshold")
```

### 1.4 与外部系统集成

```python
# 触发 Pipeline 的多种方式

# 方式 1：手动触发
client.run_pipeline(experiment_id, 'run-name', 'pipeline.yaml')

# 方式 2：定时触发（Cron）
from kfp import Client
client.create_recurring_run(
    experiment_id=experiment_id,
    job_name='daily-training',
    description='Run training daily at 2 AM',
    start_time='2024-01-01T02:00:00Z',
    cron_expression='0 2 * * *',
    pipeline_package_path='pipeline.yaml',
    params={'epochs': 50}
)

# 方式 3：事件触发（文件上传）
# 使用 KNative Eventing 或 Argo Events
# S3 有新文件 → 触发 Pipeline
```

---

## 二、Katib 自动调参深入

### 2.1 搜索算法对比

| 算法 | 类型 | 适用场景 | 收敛速度 |
|------|------|----------|----------|
| **Random** | 无梯度 | 初始探索 | 慢 |
| **Grid** | 网格 | 参数空间小 | 中 |
| **Bayesian Optimization** | 代理模型 | 昂贵评估 | **快** |
| **Hyperband** | 早停 | 大数据集 | **快** |
| **TPE** | 树结构 | 混合类型参数 | 快 |
| **CMA-ES** | 进化 | 连续参数 | 中 |
| **NAS** | 神经网络架构 | 模型结构设计 | 慢 |

### 2.2 高级 Katib 配置

```yaml
apiVersion: kubeflow.org/v1beta1
kind: Experiment
metadata:
  name: bayesian-optimization
spec:
  parallelTrialCount: 5
  maxTrialCount: 50
  maxFailedTrialCount: 5
  objective:
    type: maximize
    goal: 0.99
    objectiveMetricName: validation_accuracy
    additionalMetricNames:
      - train_accuracy
      - loss
  algorithm:
    algorithmName: bayesianoptimization
    algorithmSettings:
      - name: num_initial_random
        value: "10"
      - name: acquisition_func
        value: ei  # expected_improvement
  parameters:
    - name: learning_rate
      parameterType: double
      feasibleSpace:
        min: "1e-5"
        max: "1e-1"
        step: "1e-5"
    - name: num_layers
      parameterType: int
      feasibleSpace:
        min: "2"
        max: "10"
    - name: activation
      parameterType: categorical
      feasibleSpace:
        list:
          - relu
          - leaky_relu
          - swish
          - gelu
    - name: dropout_rate
      parameterType: double
      feasibleSpace:
        min: "0.0"
        max: "0.5"
  metricsCollectorSpec:
    collector:
      kind: StdOut
    source:
      filter:
        metricsFormat:
          - "([\\w|-]+)\\s*=\\s*([+-]?\\d*(\\.\\d+)?([Ee][+-]?\\d+)?)"
  nasConfig:
    graphConfig:
      numLayers: 8
    operations:
      - operationType: convolution
        parameters:
          - name: filter_size
            parameterType: categorical
            feasibleSpace:
              list: ["3", "5", "7"]
          - name: num_filter
            parameterType: categorical
            feasibleSpace:
              list: ["32", "64", "128", "256"]
      - operationType: pooling
        parameters:
          - name: type
            parameterType: categorical
            feasibleSpace:
              list: ["max", "average"]
```

---

## 三、Volcano 批处理调度

### 3.1 核心概念详解

```
Queue（队列）
├── weight: 1-65535          # 权重，决定资源分配比例
├── capability:              # 资源上限
│   ├── cpu: "64"
│   ├── memory: "256Gi"
│   └── nvidia.com/gpu: "16"
├── reclaimable: true        # 是否允许回收
└── jobs:                    # 属于该队列的 Job
    └── Job（作业）
        ├── minAvailable: N   # Gang Scheduling：至少 N 个 Pod 启动
        ├── schedulerName: volcano
        ├── queue: default
        └── tasks:
            └── Task（任务组）
                ├── replicas: 4
                ├── template: PodTemplate
                └── policies:
                    └── event: TaskCompleted
                        action: CompleteJob
```

### 3.2 分布式训练 Job

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: pytorch-distributed-training
spec:
  schedulerName: volcano
  minAvailable: 4              # 必须 4 个都启动才开始（Gang Scheduling）
  queue: gpu-training          # 使用 gpu-training 队列
  priorityClassName: high-priority
  tasks:
    - replicas: 1
      name: master
      policies:
        - event: TaskCompleted
          action: CompleteJob
      template:
        spec:
          containers:
            - name: pytorch-master
              image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
              command:
                - python
                - -m
                - torch.distributed.launch
                - --nproc_per_node=2
                - --nnodes=4
                - --node_rank=0
                - --master_addr=master
                - --master_port=29500
                - train.py
              resources:
                limits:
                  nvidia.com/gpu: 2
                  memory: "64Gi"
              env:
                - name: NCCL_DEBUG
                  value: "INFO"
                - name: NCCL_IB_DISABLE
                  value: "0"
          restartPolicy: OnFailure
    
    - replicas: 3
      name: worker
      template:
        spec:
          containers:
            - name: pytorch-worker
              image: pytorch/pytorch:2.0.1-cuda11.7-cudnn8-runtime
              command:
                - python
                - -m
                - torch.distributed.launch
                - --nproc_per_node=2
                - --nnodes=4
                - --node_rank={{.TaskIndex}}  # Volcano 注入的变量
                - --master_addr=master
                - --master_port=29500
                - train.py
              resources:
                limits:
                  nvidia.com/gpu: 2
                  memory: "64Gi"
          restartPolicy: OnFailure
```

### 3.3 Volcano 队列与优先级

```yaml
# 高优先级队列
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: inference-queue
spec:
  weight: 10                # 高权重
  capability:
    cpu: "128"
    memory: "512Gi"
    nvidia.com/gpu: "32"
  reclaimable: true         # 允许抢占低优先级资源
  
---
# 低优先级队列
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: training-queue
spec:
  weight: 5
  capability:
    cpu: "256"
    memory: "1024Gi"
    nvidia.com/gpu: "64"
  reclaimable: true

---
# 优先级类
apiVersion: scheduling.volcano.sh/v1beta1
kind: PodGroup
metadata:
  name: critical-training
spec:
  minMember: 4
  queue: inference-queue
  priorityClassName: system-critical
  minResources:
    cpu: "32"
    memory: "128Gi"
    nvidia.com/gpu: "8"
```

### 3.4 拓扑感知调度

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: topology-aware-training
spec:
  schedulerName: volcano
  plugins:
    pytorch: ["--master_port=29500"]
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
          containers:
            - name: worker
              image: pytorch/pytorch:latest
              resources:
                limits:
                  nvidia.com/gpu: 1
          # 拓扑感知：同一 Job 的 Pod 尽量在同一拓扑域
          affinity:
            podAffinity:
              preferredDuringSchedulingIgnoredDuringExecution:
                - weight: 100
                  podAffinityTerm:
                    labelSelector:
                      matchExpressions:
                        - key: volcano.sh/job-name
                          operator: In
                          values: ["topology-aware-training"]
                    topologyKey: kubernetes.io/hostname
```

---

## 四、Ray 分布式计算

### 4.1 Ray 核心概念

| 概念 | 说明 | 类比 |
|------|------|------|
| **Remote Function** | 分布式执行的函数 | `@ray.remote` |
| **Actor** | 有状态的分布式对象 | 分布式类实例 |
| **Placement Group** | 资源预留组 | Pod 亲和性 |
| **Object Store** | 共享内存对象存储 | 分布式缓存 |
| **Serve** | 模型服务框架 | KServe |
| **Train** | 分布式训练封装 | PyTorchJob |

### 4.2 Ray 基础用法

```python
import ray
import torch

# 初始化（单机）
ray.init()

# 初始化（连接已有集群）
ray.init(address="ray://head-service:10001")

# Remote Function
@ray.remote(num_gpus=1)
def train_model(config, data_ref):
    data = ray.get(data_ref)
    model = create_model(config)
    model.cuda()
    # 训练...
    return model.state_dict()

# 提交任务
futures = [train_model.remote(config, data) for config in configs]
results = ray.get(futures)  # 阻塞等待全部完成

# Actor（有状态）
@ray.remote(num_gpus=1)
class ModelServer:
    def __init__(self, model_path):
        self.model = load_model(model_path)
        self.model.cuda()
    
    def predict(self, batch):
        with torch.no_grad():
            return self.model(batch)

# 创建 Actor
server = ModelServer.remote("/models/resnet50.pt")

# 调用 Actor 方法
future = server.predict.remote(batch)
result = ray.get(future)

# Placement Group（资源预留）
bundle1 = {"GPU": 2, "CPU": 16}
bundle2 = {"GPU": 2, "CPU": 16}
pg = ray.util.placement_group([bundle1, bundle2], strategy="STRICT_SPREAD")

# 在指定 Placement Group 中运行
server = ModelServer.options(placement_group=pg).remote("/models/model.pt")
```

### 4.3 KubeRay：K8s 上的 Ray

```yaml
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: ray-gpu-cluster
spec:
  headGroupSpec:
    rayStartParams:
      dashboard-host: "0.0.0.0"
      block: "true"
    template:
      spec:
        containers:
          - name: ray-head
            image: rayproject/ray:2.9.0-gpu
            resources:
              limits:
                cpu: "8"
                memory: "32Gi"
            ports:
              - containerPort: 6379   # Redis
              - containerPort: 8265   # Dashboard
              - containerPort: 10001  # Client
  workerGroupSpecs:
    - replicas: 4
      minReplicas: 2
      maxReplicas: 10
      groupName: gpu-workers
      rayStartParams:
        block: "true"
        num-gpus: "2"
      template:
        spec:
          containers:
            - name: ray-worker
              image: rayproject/ray:2.9.0-gpu
              resources:
                limits:
                  nvidia.com/gpu: 2
                  cpu: "16"
                  memory: "128Gi"
                requests:
                  nvidia.com/gpu: 2
                  cpu: "8"
                  memory: "64Gi"
          # 节点亲和：调度到 GPU 节点
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: nvidia.com/gpu.present
                        operator: In
                        values: ["true"]
```

### 4.4 Ray Train 分布式训练

```python
from ray.train.torch import TorchTrainer
from ray.train import ScalingConfig, CheckpointConfig, RunConfig

def train_func(config):
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader
    
    # Ray Train 自动设置分布式环境
    import ray.train.torch
    ray.train.torch.accelerate()
    
    model = create_model()
    model = ray.train.torch.prepare_model(model)
    
    train_loader = create_dataloader()
    train_loader = ray.train.torch.prepare_data_loader(train_loader)
    
    optimizer = torch.optim.Adam(model.parameters(), lr=config["lr"])
    
    for epoch in range(config["epochs"]):
        for batch in train_loader:
            optimizer.zero_grad()
            loss = model(batch)
            loss.backward()
            optimizer.step()
        
        # 报告指标和保存检查点
        ray.train.report(
            metrics={"loss": loss.item(), "epoch": epoch},
            checkpoint=ray.train.Checkpoint.from_dict({"model": model.state_dict()})
        )

trainer = TorchTrainer(
    train_loop_per_worker=train_func,
    train_loop_config={"lr": 0.001, "epochs": 10, "batch_size": 32},
    scaling_config=ScalingConfig(
        num_workers=4,        # 4 个 worker
        use_gpu=True,         # 使用 GPU
        resources_per_worker={"GPU": 2, "CPU": 16}
    ),
    run_config=RunConfig(
        name="distributed-training",
        checkpoint_config=CheckpointConfig(num_to_keep=3)
    )
)

result = trainer.fit()
print(f"Best loss: {result.metrics['loss']}")
```

### 4.5 Ray Serve 模型服务

```python
from ray import serve
from starlette.requests import Request
import torch

@serve.deployment(
    num_replicas=3,           # 3 个副本
    ray_actor_options={"num_gpus": 1}
)
class LLMDeployment:
    def __init__(self, model_path: str):
        from transformers import AutoModelForCausalLM, AutoTokenizer
        self.model = AutoModelForCausalLM.from_pretrained(
            model_path,
            torch_dtype=torch.float16,
            device_map="auto"
        )
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)
    
    async def __call__(self, request: Request):
        body = await request.json()
        prompt = body["prompt"]
        
        inputs = self.tokenizer(prompt, return_tensors="pt").to("cuda")
        outputs = self.model.generate(**inputs, max_new_tokens=512)
        response = self.tokenizer.decode(outputs[0], skip_special_tokens=True)
        
        return {"response": response}

# 部署
serve.run(LLMDeployment.bind(model_path="meta-llama/Llama-3.1-8B"))

# 调用
curl -X POST http://localhost:8000/ \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Hello, how are you?"}'
```

---

## 五、vLLM 生产部署

### 5.1 核心参数调优

```bash
vllm serve meta-llama/Llama-3.1-8B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --dtype half \                          # FP16，节省显存
  --tensor-parallel-size 1 \              # 单卡
  --pipeline-parallel-size 1 \            # 无流水线并行
  --gpu-memory-utilization 0.90 \         # GPU 显存利用率上限
  --max-model-len 8192 \                  # 最大上下文长度
  --max-num-seqs 256 \                    # 最大并发序列数
  --max-num-batched-tokens 4096 \         # 每批最大 token 数
  --enable-prefix-caching \               # 前缀缓存，复用 system prompt
  --enable-chunked-prefill \              # 分块预填充，提升吞吐
  --quantization awq \                    # AWQ 量化（如果模型支持）
  --kv-cache-dtype fp8 \                  # KV Cache FP8（H100）
  --seed 42 \                             # 随机种子
  --disable-log-requests                  # 生产环境减少日志
```

### 5.2 多卡部署

```bash
# Tensor Parallel = 2（2 卡拆分模型）
vllm serve meta-llama/Llama-3.1-70B-Instruct \
  --tensor-parallel-size 2 \
  --dtype half

# TP=4 + Pipeline Parallel=2（8 卡）
vllm serve meta-llama/Llama-3.1-405B-Instruct \
  --tensor-parallel-size 4 \
  --pipeline-parallel-size 2 \
  --dtype half
```

### 5.3 与 KServe 集成

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: vllm-llama
spec:
  predictor:
    containers:
      - name: vllm
        image: vllm/vllm-openai:v0.6.0
        args:
          - --model
          - meta-llama/Llama-3.1-8B-Instruct
          - --dtype
          - half
          - --tensor-parallel-size
          - "1"
          - --gpu-memory-utilization
          - "0.90"
          - --max-model-len
          - "8192"
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "24Gi"
        ports:
          - containerPort: 8000
```

---

## 六、数据与存储工程化

### 6.1 MinIO 对象存储

```bash
# 安装
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install minio bitnami/minio \
  --set auth.rootUser=minioadmin \
  --set auth.rootPassword=minioadmin \
  --set persistence.size=500Gi \
  --set replicas=4

# 创建 bucket
mc alias set local http://minio:9000 minioadmin minioadmin
mc mb local/ml-models
mc mb local/ml-datasets
mc mb local/ml-artifacts

# 上传模型
mc cp -r ./my-model local/ml-models/v1/
```

### 6.2 JuiceFS 高性能文件系统

```bash
# 创建 JuiceFS 文件系统
juicefs format \
  --storage s3 \
  --bucket http://minio:9000/juicefs \
  --access-key minioadmin \
  --secret-key minioadmin \
  redis://redis:6379/1 \
  ml-storage

# K8s 部署 CSI
kubectl apply -f https://github.com/juicedata/juicefs-csi-driver/deploy/k8s.yaml

# StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: juicefs-sc
provisioner: csi.juicefs.com
parameters:
  csi.storage.k8s.io/provisioner-secret-name: juicefs-secret
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-publish-secret-name: juicefs-secret
  csi.storage.k8s.io/node-publish-secret-namespace: default
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

### 6.3 数据版本管理（DVC）

```bash
# 初始化
dvc init
git commit -m "Initialize DVC"

# 添加数据
dvc add data/training-set.csv
git add data/training-set.csv.dvc data/.gitignore
git commit -m "Add training data"

# 推送到远程存储
dvc remote add -d storage s3://mybucket/dvc-store
dvc push

# 版本切换
git checkout v1.0
dvc checkout  # 恢复对应版本的数据
```

---

## 七、本阶段实践项目

### 项目 1：端到端 MLOps 流水线

**架构**：
```
Git Push → Webhook → Pipeline Trigger
                ↓
        ┌───────────────┐
        │ 1. 数据验证    │  ← Great Expectations
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ 2. 数据预处理  │  ← Pandas / Spark
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ 3. Katib 调参  │  ← 自动超参数搜索
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ 4. 模型训练    │  ← PyTorchJob / Volcano
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ 5. 模型评估    │  ← 自动测试集评估
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ 6. MLflow 注册 │  ← 注册到 Model Registry
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ 7. KServe 部署 │  ← 自动部署到推理服务
        └───────────────┘
```

### 项目 2：Volcano 分布式训练平台

**目标**：搭建支持多种框架的分布式训练平台。

**功能清单**：
- [ ] 多队列管理（训练/推理/开发）
- [ ] Gang Scheduling 保证资源原子分配
- [ ] 优先级抢占与资源回收
- [ ] 拓扑感知调度优化通信
- [ ] 训练任务自动 Checkpoint 与恢复

### 项目 3：vLLM 推理集群

**目标**：搭建生产级 LLM 推理服务。

**功能清单**：
- [ ] 多模型管理（不同版本/不同规模）
- [ ] 自动扩缩容（KEDA + HPA）
- [ ] 请求路由与负载均衡
- [ ] 监控告警（延迟/吞吐/错误率）
- [ ] 量化模型部署降低成本

# 06 - AI on K8s 基础

> GPU 调度、Kubeflow 全家桶、KServe 模型服务、MLflow 实验追踪

---

## 一、GPU 在 K8s 上的工作原理

### 1.1 NVIDIA 软件栈全景

```
┌─────────────────────────────────────────┐
│  应用层：PyTorch/TensorFlow/JAX        │
├─────────────────────────────────────────┤
│  CUDA Runtime / cuDNN / cuBLAS          │
├─────────────────────────────────────────┤
│  NVIDIA Driver (内核模块)                │
├─────────────────────────────────────────┤
│  NVIDIA GPU Operator (K8s)              │
│  ├── NVIDIA Driver DaemonSet            │
│  ├── NVIDIA Container Toolkit           │
│  ├── NVIDIA Device Plugin               │
│  ├── DCGM Exporter                      │
│  └── GPU Feature Discovery              │
├─────────────────────────────────────────┤
│  Container Runtime (containerd/cri-o)   │
│  ├── runc                               │
│  └── nvidia-container-runtime           │
├─────────────────────────────────────────┤
│  K8s Scheduler                          │
│  └── Extended Resources: nvidia.com/gpu │
└─────────────────────────────────────────┘
```

### 1.2 Device Plugin 机制详解

Device Plugin 是 K8s 的扩展机制，允许第三方设备（GPU/FPGA/等）接入调度系统。

```
1. Device Plugin 以 DaemonSet 运行在每个节点
2. 启动时通过 gRPC 向 kubelet 注册
3. 定期报告节点上的设备列表和健康状态
4. kubelet 将设备信息上报给 API Server
5. 调度器根据资源请求分配设备
6. Pod 创建时，kubelet 调用 Device Plugin 的 Allocate()
7. Device Plugin 设置容器环境变量（如 CUDA_VISIBLE_DEVICES）
```

### 1.3 GPU Operator 安装

```bash
# 添加 Helm 仓库
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# 安装 GPU Operator（最简）
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace

# 生产环境安装（自定义配置）
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=true \
  --set toolkit.enabled=true \
  --set devicePlugin.enabled=true \
  --set dcgmExporter.enabled=true \
  --set gfd.enabled=true \
  --set mig.strategy=mixed

# 验证安装
kubectl get pods -n gpu-operator
kubectl get nodes -o json | jq '.items[].status.capacity | select(."nvidia.com/gpu")'
```

### 1.4 GPU Feature Discovery

GPU Feature Discovery (GFD) 会自动为节点打上 GPU 相关标签：

```bash
kubectl get node <gpu-node> --show-labels

# 典型标签
nvidia.com/gpu.product=NVIDIA-A100-SXM4-40GB
nvidia.com/gpu.memory=40960
nvidia.com/gpu.count=8
nvidia.com/gpu.family=ampere
nvidia.com/cuda.driver.major=525
nvidia.com/mig.capable=true
```

### 1.5 在 Pod 中使用 GPU

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  containers:
    - name: cuda
      image: nvidia/cuda:12.0-base
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1  # 申请 1 个 GPU
        requests:
          nvidia.com/gpu: 1  # GPU 的 requests 必须等于 limits
```

**重要规则**：
- GPU 资源不能超售（`requests == limits`）
- 不支持分数 GPU（除非使用 vGPU/HAMi）
- 一个 GPU 只能分配给一个 Pod（除非 MIG/vGPU）

---

## 二、Kubeflow 入门与实战

### 2.1 Kubeflow 架构

```
Kubeflow Central Dashboard
    │
    ├── Notebooks        # JupyterLab 开发环境
    ├── Pipelines        # ML 工作流编排
    │   ├── SDK (kfp)    # Python DSL
    │   ├── UI           # 可视化编辑器
    │   └── Backend      # Argo/Tekton 执行引擎
    ├── Katib            # 超参数调优 (AutoML)
    ├── Training Operator # 分布式训练任务
    │   ├── TFJob
    │   ├── PyTorchJob
    │   ├── MPIJob
    │   └── XGBoostJob
    ├── KServe           # 模型推理服务
    └── Model Registry   # 模型版本管理
```

### 2.2 安装部署

```bash
# 方式 1：官方 Manifest（适合学习）
# 注意：需要足够的节点资源
export KUBEFLOW_VERSION=v1.8.0
wget https://github.com/kubeflow/manifests/archive/refs/tags/${KUBEFLOW_VERSION}.tar.gz
tar -xzf ${KUBEFLOW_VERSION}.tar.gz
cd manifests-${KUBEFLOW_VERSION}
while ! kustomize build example | kubectl apply -f -; do
  echo "Retrying to apply resources..."
  sleep 10
done

# 方式 2：MinKF（minikube 快速体验）
minikube start --cpus 6 --memory 12288 --disk-size=50g
minikube addons enable ingress
kubectl apply -f https://raw.githubusercontent.com/kubeflow/kubeflow/master/components/crud-web-apps/jupyter/manifests/base/deployment.yaml

# 方式 3：生产环境（组件按需安装）
# 只安装需要的组件
kubectl apply -k github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=2.0.0
kubectl apply -k github.com/kubeflow/pipelines/manifests/kustomize/env/platform-agnostic-pns?ref=2.0.0
kubectl apply -k github.com/kubeflow/training-operator/manifests/overlays/standalone?ref=v1.7.0
```

### 2.3 Kubeflow Notebooks

```yaml
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: gpu-notebook
  namespace: kubeflow-user-example-com
spec:
  template:
    spec:
      containers:
        - name: jupyter
          image: kubeflownotebookswg/jupyter-pytorch-cuda-full:v1.8.0
          resources:
            limits:
              nvidia.com/gpu: 1
              memory: "16Gi"
              cpu: "8"
            requests:
              memory: "8Gi"
              cpu: "4"
          volumeMounts:
            - name: workspace
              mountPath: /home/jovyan
      volumes:
        - name: workspace
          persistentVolumeClaim:
            claimName: notebook-workspace
```

### 2.4 Kubeflow Pipelines 实战

#### Pipeline DSL 基础

```python
import kfp
from kfp import dsl
from kfp.dsl import Input, Output, Dataset, Model, Metrics

# 定义组件（方式 1：容器化组件）
@dsl.component(
    base_image='python:3.9',
    packages_to_install=['pandas', 'scikit-learn']
)
def preprocess_data(
    input_path: str,
    output_dataset: Output[Dataset]
):
    import pandas as pd
    from sklearn.model_selection import train_test_split
    
    df = pd.read_csv(input_path)
    train, test = train_test_split(df, test_size=0.2)
    
    train.to_csv(f"{output_dataset.path}/train.csv", index=False)
    test.to_csv(f"{output_dataset.path}/test.csv", index=False)

# 定义组件（方式 2：轻量 Python 组件）
@dsl.component
def train_model(
    train_data: Input[Dataset],
    model: Output[Model],
    metrics: Output[Metrics],
    epochs: int = 10,
    learning_rate: float = 0.001
):
    import json
    import torch
    import torch.nn as nn
    
    # 训练逻辑...
    accuracy = 0.95
    
    # 保存模型
    torch.save(model.state_dict(), f"{model.path}/model.pt")
    
    # 保存指标
    with open(metrics.path, 'w') as f:
        json.dump({"accuracy": accuracy, "epochs": epochs}, f)

# 定义 Pipeline
@dsl.pipeline(
    name='Training Pipeline',
    description='End-to-end ML training pipeline'
)
def training_pipeline(
    data_url: str = 's3://bucket/dataset.csv',
    epochs: int = 10
):
    # 数据预处理
    preprocess_task = preprocess_data(input_path=data_url)
    
    # 训练（依赖预处理完成）
    train_task = train_model(
        train_data=preprocess_task.outputs['output_dataset'],
        epochs=epochs
    )
    
    # 设置资源
    train_task.set_cpu_request('4')
    train_task.set_cpu_limit('8')
    train_task.set_memory_request('16Gi')
    train_task.set_memory_limit('32Gi')
    train_task.set_gpu_limit('1')
    
    # 使用节点亲和
    train_task.add_node_selector_constraint(
        label_name='nvidia.com/gpu.present',
        values=['true']
    )

# 编译并提交
compiler.Compiler().compile(
    pipeline_func=training_pipeline,
    package_path='training_pipeline.yaml'
)

client = kfp.Client(host='http://kubeflow-pipeline-ui:8080')
experiment = client.create_experiment(name='default')
run = client.run_pipeline(
    experiment_id=experiment.id,
    job_name='training-run-001',
    pipeline_package_path='training_pipeline.yaml',
    params={'epochs': 20}
)
```

#### Pipeline 高级特性

```python
# 条件分支
with dsl.Condition(preprocess_task.outputs['data_size'] > 1000):
    train_large = train_large_model(...)

with dsl.Condition(preprocess_task.outputs['data_size'] <= 1000):
    train_small = train_small_model(...)

# 并行 For 循环
with dsl.ParallelFor([{'lr': 0.01}, {'lr': 0.001}, {'lr': 0.0001}]) as item:
    train_task = train_model(learning_rate=item.lr)

# 退出处理（清理资源）
exit_task = clean_up_resources()
dsl.ExitHandler(exit_task, name='Cleanup')

# 重试策略
train_task.set_retry(
    num_retries=3,
    backoff_duration='60s',
    backoff_factor=2
)
```

### 2.5 Katib 超参数调优

```yaml
apiVersion: kubeflow.org/v1beta1
kind: Experiment
metadata:
  name: random-example
  namespace: kubeflow
spec:
  parallelTrialCount: 3      # 同时运行 3 个 trial
  maxTrialCount: 12          # 最多 12 个 trial
  maxFailedTrialCount: 3     # 最多允许 3 个失败
  objective:
    type: maximize
    goal: 0.99
    objectiveMetricName: accuracy
  algorithm:
    algorithmName: random
  parameters:
    - name: learning_rate
      parameterType: double
      feasibleSpace:
        min: "0.001"
        max: "0.1"
    - name: batch_size
      parameterType: int
      feasibleSpace:
        min: "32"
        max: "256"
    - name: optimizer
      parameterType: categorical
      feasibleSpace:
        list:
          - adam
          - sgd
          - adamw
  trialTemplate:
    primaryContainerName: training-container
    trialParameters:
      - name: learningRate
        reference: learning_rate
      - name: batchSize
        reference: batch_size
      - name: optimizerType
        reference: optimizer
    trialSpec:
      apiVersion: batch/v1
      kind: Job
      spec:
        template:
          spec:
            containers:
              - name: training-container
                image: docker.io/kubeflowkatib/pytorch-mnist:v1beta1-45c5727
                command:
                  - "python"
                  - "/opt/pytorch-mnist/mnist.py"
                  - "--epochs=10"
                  - "--lr=${trialParameters.learningRate}"
                  - "--batch-size=${trialParameters.batchSize}"
                  - "--optimizer=${trialParameters.optimizerType}"
                resources:
                  limits:
                    nvidia.com/gpu: 1
            restartPolicy: Never
```

### 2.6 Training Operator 分布式训练

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: pytorch-distributed-example
  namespace: kubeflow
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          containers:
            - name: pytorch
              image: docker.io/kubeflowkatib/pytorch-mnist:v1beta1-45c5727
              command:
                - "python"
                - "/opt/pytorch-mnist/mnist.py"
                - "--backend=nccl"
                - "--epochs=10"
              resources:
                limits:
                  nvidia.com/gpu: 2
              env:
                - name: NCCL_DEBUG
                  value: "INFO"
    Worker:
      replicas: 3
      restartPolicy: OnFailure
      template:
        spec:
          containers:
            - name: pytorch
              image: docker.io/kubeflowkatib/pytorch-mnist:v1beta1-45c5727
              command:
                - "python"
                - "/opt/pytorch-mnist/mnist.py"
                - "--backend=nccl"
                - "--epochs=10"
              resources:
                limits:
                  nvidia.com/gpu: 2
```

---

## 三、KServe 模型服务

### 3.1 KServe 核心概念

| 概念 | 说明 |
|------|------|
| **InferenceService** | 顶层 CRD，定义模型服务 |
| **Predictor** | 推理服务核心，必须 |
| **Transformer** | 预处理/后处理，可选 |
| **Explainer** | 模型可解释性，可选 |

### 3.2 基础部署

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
  namespace: default
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      storageUri: gs://kfserving-examples/models/sklearn/1.0/model
      resources:
        limits:
          cpu: "1"
          memory: 2Gi
```

### 3.3 GPU 模型部署

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llm-service
  annotations:
    # 自动扩缩容配置
    autoscaling.knative.dev/target-utilization-percentage: "80"
    autoscaling.knative.dev/min-scale: "1"
    autoscaling.knative.dev/max-scale: "10"
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      storageUri: s3://models/llama-3-8b
      args:
        - --dtype=half
        - --max-model-len=8192
      env:
        - name: HF_HOME
          value: /tmp/hf_home
      resources:
        limits:
          nvidia.com/gpu: 1
          memory: "24Gi"
        requests:
          nvidia.com/gpu: 1
          memory: "16Gi"
```

### 3.4 Canary 发布

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llm-service
spec:
  predictor:
    canaryTrafficPercent: 20   # 20% 流量到新版本
    model:
      modelFormat:
        name: huggingface
      storageUri: s3://models/v2
```

### 3.5 A/B 测试

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llm-ab-test
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      storageUri: s3://models/v1
  transformer:
    containers:
      - name: transformer
        image: ab-test-router:latest
        args:
          - --model_a=http://llm-v1:8080
          - --model_b=http://llm-v2:8080
          - --split=50:50
```

### 3.6 KServe 支持 Runtime 列表

| Runtime | 框架 | 说明 |
|---------|------|------|
| sklearn | Scikit-learn | pickle 模型 |
| xgboost | XGBoost | 原生模型 |
| tensorflow | TensorFlow | SavedModel |
| pytorch | PyTorch | TorchScript |
| onnx | ONNX | 通用格式 |
| triton | 多框架 | NVIDIA Triton |
| huggingface | HuggingFace | Transformers |
| lightgbm | LightGBM | 原生模型 |
| paddle | PaddlePaddle | 百度框架 |

---

## 四、MLflow 实验追踪

### 4.1 核心概念

| 概念 | 说明 |
|------|------|
| **Tracking** | 记录参数、指标、Artifact |
| **Projects** | 可复现的项目打包 |
| **Models** | 模型打包格式 |
| **Model Registry** | 模型生命周期管理 |
| **Deployments** | 模型部署（有限支持） |

### 4.2 K8s 上部署 MLflow

```yaml
# MLflow Tracking Server
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow-tracking
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mlflow-tracking
  template:
    spec:
      containers:
        - name: mlflow
          image: mlflow/mlflow:latest
          command:
            - mlflow
            - server
            - --host=0.0.0.0
            - --port=5000
            - --backend-store-uri=postgresql://mlflow:password@postgres:5432/mlflow
            - --default-artifact-root=s3://mlflow-artifacts
          ports:
            - containerPort: 5000
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: aws-credentials
                  key: access-key
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow-tracking
spec:
  selector:
    app: mlflow-tracking
  ports:
    - port: 5000
```

### 4.3 代码集成

```python
import mlflow
import mlflow.pytorch
from mlflow.tracking import MlflowClient

# 设置 Tracking URI
mlflow.set_tracking_uri("http://mlflow-tracking:5000")
mlflow.set_experiment("image-classification")

# 开始实验
with mlflow.start_run(run_name="resnet50-experiment"):
    # 记录参数
    mlflow.log_param("model", "resnet50")
    mlflow.log_param("epochs", 100)
    mlflow.log_param("batch_size", 32)
    mlflow.log_param("learning_rate", 0.001)
    
    # 训练循环
    for epoch in range(100):
        train_loss = train_epoch(...)
        val_acc = validate(...)
        
        # 记录指标
        mlflow.log_metric("train_loss", train_loss, step=epoch)
        mlflow.log_metric("val_acc", val_acc, step=epoch)
    
    # 记录模型
    mlflow.pytorch.log_model(model, "model")
    
    # 记录 Artifact
    mlflow.log_artifact("confusion_matrix.png")
    mlflow.log_artifact("training_log.txt")

# 模型注册
client = MlflowClient()
model_version = client.create_model_version(
    name="image-classifier",
    source="runs:/<run_id>/model",
    run_id="<run_id>"
)

# 阶段转换（Staging → Production）
client.transition_model_version_stage(
    name="image-classifier",
    version=model_version.version,
    stage="Production"
)
```

### 4.4 模型加载与推理

```python
import mlflow.pyfunc

# 从 Model Registry 加载
model = mlflow.pyfunc.load_model("models:/image-classifier/Production")
# 或指定版本
model = mlflow.pyfunc.load_model("models:/image-classifier/3")

# 推理
predictions = model.predict(input_data)
```

---

## 五、本阶段实践项目

### 项目 1：K8s 上运行 GPU 训练

**目标**：在 K8s 集群上成功运行一个 GPU 训练任务。

**步骤**：
1. 安装 GPU Operator
2. 验证 GPU 节点可调度
3. 创建一个挂载 GPU 的 Pod
4. 运行 PyTorch MNIST 训练脚本
5. 监控 GPU 利用率

```bash
# 验证
kubectl apply -f gpu-training-pod.yaml
kubectl logs -f gpu-training-pod
nvidia-smi  # 在节点上查看
```

### 项目 2：Kubeflow Pipeline 入门

**目标**：构建一个完整的训练流水线。

**步骤**：
1. 安装 Kubeflow Pipelines
2. 编写 3 阶段 Pipeline：数据下载 → 预处理 → 训练
3. 在 UI 上提交并查看运行结果
4. 用 Katib 对训练进行超参数调优

### 项目 3：KServe 部署模型

**目标**：部署一个可访问的推理服务。

**步骤**：
1. 准备一个训练好的模型（sklearn/pytorch）
2. 打包并上传到对象存储（MinIO/S3）
3. 编写 InferenceService YAML
4. 部署并测试推理接口
5. 配置 Canary 发布新版本

```bash
# 测试推理
curl -v http://sklearn-iris.default.svc.cluster.local/v1/models/sklearn-iris:predict \
  -H "Content-Type: application/json" \
  -d '{"instances": [[6.2, 3.4, 5.4, 2.3]]}'
```

### 项目 4：MLflow 全流程集成

**目标**：实验追踪 + 模型注册 + 与 Pipeline 集成。

**步骤**：
1. 部署 MLflow Tracking Server
2. 在训练代码中集成 MLflow
3. 记录参数、指标、模型
4. 在 Model Registry 中管理版本
5. KServe 从 MLflow 加载模型部署

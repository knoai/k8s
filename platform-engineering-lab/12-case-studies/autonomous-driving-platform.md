# 案例研究：自动驾驶平台工程实践

> 自动驾驶是平台工程最极端的挑战之一：
> 每辆车每天产生 2-10TB 数据，仿真测试需要百万 CPU 核时，
> 模型训练需要千卡 GPU 集群，而安全要求零容忍。
> 本案例基于头部自动驾驶公司的真实实践整理。

---

## 第一章：自动驾驶的数据洪流

### 1.1 数据规模

```
单车数据产量：
  - 摄像头（8 个）：~2GB/小时
  - 激光雷达（1-2 个）：~5GB/小时
  - 毫米波雷达（5 个）：~100MB/小时
  - CAN 总线：~50MB/小时
  - GPS/IMU：~20MB/小时
  - 总计：~7.2GB/小时 = ~173GB/天

车队规模：
  - 测试车队：100-500 辆
  - 量产车队：10,000-100,000 辆（带数据采集功能）
  
总数据量：
  - 测试车队：100 辆 × 173GB = 17.3TB/天
  - 量产车队：10,000 辆 × 50GB（精简采集）= 500TB/天
  - 年数据量：180PB（测试）+ 180EB（量产，但大部分不保存）

存储挑战：
  - 原始数据保留期：2-5 年（法规要求）
  - 标注数据：永久保留
  - 模型 Checkpoint：保留最新 10 个版本
```

### 1.2 数据流水线

```
数据采集 → 边缘压缩 → 上传到云 → 数据清洗 → 数据标注 → 模型训练 → 仿真测试 → OTA 部署
  │          │           │          │          │          │          │         │
  │          │           │          │          │          │          │         │
  车辆       4G/5G      对象存储   Spark/    人工+AI    GPU 集群   仿真集群   车端
             夜间上传    (S3/OSS)   Flink     标注      (Volcano)  (K8s)     (边缘 K8s)

关键指标：
  - 数据上传窗口：夜间 0:00-6:00（6 小时）
  - 上传带宽需求：500TB / 6h = 23TB/h = 6.5GB/s
  - 需要 10Gbps+ 专线
```

---

## 第二章：K8s 上的 AI 训练平台

### 2.1 训练任务特征

```
感知模型训练（CNN/Transformer）：
  - 数据量：100TB-1PB 图像
  - 模型大小：100MB-10GB
  - GPU 需求：100-1000 卡
  - 训练时间：1-7 天
  - 框架：PyTorch + DDP / Megatron-LM

规划模型训练（强化学习）：
  - 数据量：10TB 仿真轨迹
  - 模型大小：1GB-100GB
  - GPU 需求：10-100 卡
  - 训练时间：3-30 天
  - 框架：Ray RLlib / DI-engine

仿真测试：
  - 场景数：100 万+ 场景
  - 每场景运行时间：1-10 分钟
  - CPU 需求：1000-10000 核
  - 框架：Carla / LGSVL / 自研
```

### 2.2 千卡 GPU 集群调度

```yaml
# 使用 Volcano 进行 GPU 任务调度
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: perception-training-v2.1
  namespace: autonomous-driving
spec:
  schedulerName: volcano
  minAvailable: 8  # 8 个 Pod 必须同时启动
  queue: training-queue
  priorityClassName: high-priority
  tasks:
  - name: worker
    replicas: 8
    template:
      spec:
        containers:
        - name: pytorch
          image: autonomous-driving/training:v2.1
          command:
          - python
          - -m
          - torch.distributed.launch
          - --nproc_per_node=8
          - --nnodes=8
          - train_perception.py
          resources:
            limits:
              nvidia.com/gpu: 8          # 每 Pod 8 张 A100
              memory: 1Ti
              cpu: "128"
            requests:
              nvidia.com/gpu: 8
              memory: 1Ti
              cpu: "128"
          volumeMounts:
          - name: training-data
            mountPath: /data
          - name: model-output
            mountPath: /output
        volumes:
        - name: training-data
          persistentVolumeClaim:
            claimName: training-data-pvc
        - name: model-output
          persistentVolumeClaim:
            claimName: model-output-pvc
        restartPolicy: Never
```

### 2.3 GPU 集群性能优化

```
网络优化（NCCL）：
  - 使用 RoCE v2 或 InfiniBand
  - 带宽：200Gbps/400Gbps
  - 延迟：< 2us
  
存储优化：
  - 训练数据使用并行文件系统（Lustre/BeeGFS）
  - 吞吐量：100GB/s+
  - Checkpoint 使用高速 NVMe SSD

调度优化：
  - Gang Scheduling：8 节点 × 8 GPU 必须同时调度
  - 拓扑感知：优先将任务调度到同一交换机下的节点
  - 避免网络拥塞

实际数据（某头部公司）：
  - 千卡 A100 集群
  - 线性加速比：85%（理想 100%）
  - 主要瓶颈：数据加载（IO）和参数同步（网络）
```

---

## 第三章：数据标注平台

### 3.1 标注任务类型

```
2D 标注：
  - 目标检测框（Bounding Box）
  - 语义分割（Pixel-level）
  - 车道线标注
  - 交通标志识别
  
3D 标注：
  - 点云标注（3D Bounding Box）
  - 点云语义分割
  - 连续帧追踪

标注效率：
  - 2D 框标注：500 张/人/天
  - 3D 点云标注：50 帧/人/天
  - 语义分割：20 张/人/天

成本：
  - 2D 框：¥0.1-0.5/张
  - 3D 点云：¥2-10/帧
  - 月标注费用：¥500-2000 万
```

### 3.2 标注平台架构

```
┌────────────────────────────────────────────────────────────────────┐
│                    标注平台（基于 K8s）                             │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐ │
│  │ 任务分发    │  │ 质量检查    │  │ 数据管理                    │ │
│  │ (Argo)      │  │ (自动+人工) │  │ (MinIO + 数据库)           │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘ │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ 标注工作台（Web 应用，1000+ 并发标注员）                      │  │
│  │ - 2D/3D 标注工具                                             │  │
│  │ - AI 辅助预标注（减少 70% 工作量）                           │  │
│  │ - 多人协作 + 冲突解决                                        │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘

AI 辅助标注：
  - 使用上一版模型自动预标注
  - 标注员只需修正错误
  - 效率提升：3-5 倍
  - 质量：预标注准确率 80-90%
```

---

## 第四章：仿真测试平台

### 4.1 仿真测试规模

```
测试场景库：
  - 基础场景：10,000+（直行、转弯、变道）
  - 危险场景：100,000+（Cut-in、行人横穿）
  - 极端场景：1,000,000+（恶劣天气、传感器故障）

每日仿真量：
  - 场景数：100 万+
  - 总里程：10 亿+ 公里（虚拟）
  - 相当于实际测试 100 年

K8s 调度挑战：
  - 每场景需要 1-4 CPU 核
  - 100 万场景 = 400 万 CPU 核时/天
  - 需要使用 Spot 实例降低成本
```

### 4.2 仿真平台架构

```yaml
# 仿真任务（使用 Argo Workflows）
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: simulation-batch-
  namespace: simulation
spec:
  serviceAccountName: argo-workflow
  parallelism: 1000  # 最多 1000 个并发 Pod
  templates:
  - name: run-scenario
    inputs:
      parameters:
      - name: scenario-id
    container:
      image: autonomous-driving/simulator:v3.2
      command: [python, run_scenario.py]
      args:
      - --scenario-id={{inputs.parameters.scenario-id}}
      - --model-version=v2.1.3
      - --output=/output/result.json
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
        limits:
          cpu: "4"
          memory: 8Gi
      volumeMounts:
      - name: model
        mountPath: /models
      - name: output
        mountPath: /output
    volumes:
    - name: model
      persistentVolumeClaim:
        claimName: model-pvc
    - name: output
      emptyDir: {}
    
  - name: process-results
    script:
      image: python:3.9
      command: [python]
      source: |
        import json, glob
        results = []
        for f in glob.glob('/output/*/result.json'):
            with open(f) as fh:
                results.append(json.load(fh))
        # 统计分析
        pass_rate = sum(1 for r in results if r['pass']) / len(results)
        print(f"Pass rate: {pass_rate:.2%}")
        
  # 使用循环生成 10000 个场景任务
  - name: main
    steps:
    - - name: run-scenarios
        template: run-scenario
        arguments:
          parameters:
          - name: scenario-id
            value: "{{item}}"
        withItems: [1, 2, 3, ..., 10000]
    - - name: process-results
        template: process-results
```

---

## 第五章：OTA 与车端部署

### 5.1 OTA 架构

```
云端模型训练 → 模型验证 → 模型打包 → OTA 下发 → 车端更新
     │            │          │         │          │
     │            │          │         │          │
  GPU集群      仿真测试    Docker镜像  CDN分发    边缘K8s
                              +        +         +
                           模型文件   断点续传   A/B测试

OTA 要求：
  - 包大小：500MB-5GB（模型 + 代码）
  - 下载时间：< 30 分钟（4G 网络）
  - 更新失败回滚：< 5 分钟
  - 更新成功率：> 99.9%
```

### 5.2 车端边缘 K8s

```yaml
# 车辆上的边缘 K8s（使用 K3s）
# 用途：运行感知模型、规划算法、数据预处理

apiVersion: apps/v1
kind: Deployment
metadata:
  name: perception-inference
  namespace: edge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: perception
  template:
    metadata:
      labels:
        app: perception
    spec:
      nodeSelector:
        device: orin-x  # NVIDIA Orin X
      containers:
      - name: perception
        image: autonomous-driving/perception:v2.1.3
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 16Gi
        env:
        - name: MODEL_PATH
          value: /models/perception-v2.1.3.trt
        - name: INPUT_TOPIC
          value: /camera/front/compressed
        - name: OUTPUT_TOPIC
          value: /perception/objects
        volumeMounts:
        - name: model
          mountPath: /models
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: model
        hostPath:
          path: /data/models
      - name: tmp
        emptyDir:
          medium: Memory  # 使用 tmpfs，减少磁盘写入
```

---

## 第六章：面试核心考点

```
Q: 自动驾驶平台与普通互联网平台最大的区别？

A:
   1. 数据规模：
      - 每车每天 100-200GB
      - 车队 10 万辆 = 20PB/天
      - 存储和带宽需求是互联网平台的 100 倍
   
   2. 算力需求：
      - 训练需要千卡 GPU 集群
      - 仿真需要百万 CPU 核时/天
      - 需要使用批量调度（Volcano）和 Spot 实例
   
   3. 安全要求：
      - 零容忍（Zero Tolerance）
      - 模型更新必须经过仿真测试
      - OTA 失败必须能回滚
   
   4. 边缘计算：
      - 车端需要实时推理（< 100ms）
      - 使用边缘 K8s（K3s）部署模型
      - 需要考虑车端资源限制（功耗、散热）

Q: 千卡 GPU 集群的调度挑战？

A:
   1. Gang Scheduling：
      - 100 节点 × 8 GPU 必须同时调度
      - 否则部分节点空闲，资源浪费
   
   2. 拓扑感知：
      - 优先调度到同一交换机下的节点
      - 减少 NCCL 通信延迟
   
   3. 抢占与优先级：
      - 紧急训练任务可以抢占低优先级任务
      - 需要 Checkpoint 机制保存中间状态
   
   4. 数据本地性：
      - 训练数据在共享存储（Lustre）
      - 需要高带宽存储网络
```

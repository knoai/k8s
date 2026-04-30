# 14 - GPU 利用率优化实战

> 从 30% 到 90%+ 的 GPU 利用率提升方法论

---

## 一、GPU 利用率现状分析

### 1.1 行业普遍问题

| 场景 | 典型利用率 | 根本原因 |
|------|-----------|----------|
| 单用户交互 | 10-20% | 请求稀疏，GPU 大量空闲 |
| 低并发服务 | 20-35% | batch_size=1，算力浪费 |
| 多模型混部 | 30-50% | 资源碎片化，调度不合理 |
| 训练任务 | 60-80% | 数据加载瓶颈 |
| **优化后推理** | **85-95%** | 连续批处理、高并发 |

### 1.2 GPU 利用率诊断

```bash
# 实时监控 GPU
watch -n 1 nvidia-smi

# DCGM 详细指标
dcgmi dmon -e 1001,1002,1003,1004,1005
# 1001=gpu_utilization, 1002=mem_copy_utilization
# 1003=power_usage, 1004=pcie_tx_bytes, 1005=pcie_rx_bytes

# 查看 GPU 进程
nvidia-smi pmon -s um -o T

# 分析 GPU 空闲原因
nsys profile -t cuda,nvtx,osrt -o report.qdrep python your_script.py
```

---

## 二、推理场景优化

### 2.1 Continuous Batching（连续批处理）

传统静态批处理 vs 连续批处理：

```
静态批处理：
Req1 [========]  
Req2 [====]      等待 Req1
Req3 [==========] 等待 Req1,Req2
         └─ GPU 空闲等待最长请求完成

连续批处理（vLLM PagedAttention）：
Req1 [====|====]  中途插入新请求
Req2 [====]       
Req3 [==|==|==]   动态抢占/插入
         └─ GPU 几乎无空闲
```

**vLLM 启用配置**：
```bash
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --dtype half \
  --max-num-seqs 256 \        # 最大并发序列数
  --max-num-batched-tokens 4096 \  # 每批最大 token 数
  --enable-chunked-prefill    # 分块预填充，进一步提升吞吐
```

### 2.2 动态批处理大小调优

```python
# 找到最优 batch_size
import itertools

for max_seqs in [16, 32, 64, 128, 256]:
    for batched_tokens in [1024, 2048, 4096, 8192]:
        throughput = benchmark(
            max_num_seqs=max_seqs,
            max_num_batched_tokens=batched_tokens
        )
        print(f"seqs={max_seqs}, tokens={batched_tokens}: {throughput} tokens/s")
```

**典型最优配置**：

| GPU | 模型 | 最优 max_num_seqs | 最优 batched_tokens | 利用率 |
|-----|------|-------------------|---------------------|--------|
| RTX 4090 24GB | 7B FP16 | 64-128 | 4096 | 88% |
| A100 40GB | 32B FP16 | 32-64 | 8192 | 85% |
| H100 80GB | 70B FP8 | 16-32 | 16384 | 90% |

### 2.3 Prefix Caching（前缀缓存）

复用相同 system prompt 的 KV Cache：

```bash
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --enable-prefix-caching \
  --dtype half

# 效果：相同前缀的请求，首 token 延迟降低 50-70%
```

### 2.4 投机解码（Speculative Decoding）

用小模型猜测大模型输出，加速 1.5-2.5×：

```bash
vllm serve meta-llama/Llama-3.1-70B-Instruct \
  --speculative-model meta-llama/Llama-3.1-8B-Instruct \
  --num-speculative-tokens 5 \
  --dtype half
```

---

## 三、GPU 共享与虚拟化

### 3.1 方案对比

| 方案 | 隔离性 | 利用率提升 | 复杂度 | 推荐场景 |
|------|--------|-----------|--------|----------|
| **Time Slicing** | 进程级 | 2-4× | 低 | 开发测试 |
| **MIG** | 硬件级 | 固定切分 | 中 | A100/H100 生产 |
| **HAMi vGPU** | 显存隔离 | 3-5× | 中 | 多租户生产 |
| **MPS** | 上下文共享 | 1.5-2× | 低 | 同进程多模型 |
| **Multi-Instance** | 完全隔离 | 固定 | 高 | 严格 SLA |

### 3.2 HAMi vGPU 实战

```bash
# 安装 HAMi
helm repo add hami-charts https://project-hami.github.io/HAMi/
helm install hami hami-charts/hami -n kube-system

# 查看 vGPU 资源
kubectl inspect gpushare-node

# 部署时申请 vGPU
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-small
spec:
  template:
    spec:
      containers:
        - name: vllm
          resources:
            limits:
              nvidia.com/gpu: 0.5        # 申请半个 GPU
              nvidia.com/gpumem: 8000    # 限制显存 8GB
              nvidia.com/gpucores: 50    # 限制算力 50%
```

### 3.3 MIG 配置（A100/H100）

```bash
# 查看可用 MIG 配置
nvidia-smi mig -lgip

# 创建 3g.40gb 实例（A100 40GB 可切 2 个）
nvidia-smi mig -cgi 9,9 -C

# K8s 中使用 MIG
resources:
  limits:
    nvidia.com/mig-3g.40gb: 1

# 查看 MIG 设备
nvidia-smi mig -lgi
```

### 3.4 混部策略：推理 + 训练

```yaml
# 白天：推理服务占主要资源
# 夜间：训练任务抢占空闲资源

apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: night-training
spec:
  schedulerName: volcano
  queue: training-queue
  tasks:
    - replicas: 1
      name: trainer
      template:
        spec:
          nodeSelector:
            gpu-workload: mixed
          containers:
            - name: train
              image: pytorch/pytorch:latest
              resources:
                limits:
                  nvidia.com/gpu: 4
              # 只在夜间运行
          affinity:
            nodeAffinity:
              preferredDuringSchedulingIgnoredDuringExecution:
                - weight: 100
                  preference:
                    matchExpressions:
                      - key: time-zone
                        operator: In
                        values: ["night"]
```

---

## 四、KV Cache 优化

### 4.1 KV Cache 内存占用公式

```
KV_Cache = 2 × num_layers × hidden_size × seq_len × batch_size × sizeof(dtype)

例：Llama-3-70B
  = 2 × 80 × 8192 × 8192 × 32 × 2 bytes
  = ~655 GB (FP16, 32并发, 8K上下文)
```

### 4.2 KV Cache 压缩技术

| 技术 | 压缩比 | 精度损失 | 实现方式 |
|------|--------|----------|----------|
| **KV Cache Quantization** | 2× (FP16→INT8) | <2% | vLLM `--kv-cache-dtype fp8` |
| **StreamingLLM** | 动态 | <3% | 只保留最近 + 注意力汇聚点 |
| **H2O (Heavy Hitter Oracle)** | 20-50% | <3% | 保留重要 token 的 KV |
| **SnapKV** | 30-50% | <2% | 自适应 KV 压缩 |

```bash
# FP8 KV Cache（H100 推荐）
vllm serve meta-llama/Llama-3.1-70B-Instruct \
  --kv-cache-dtype fp8 \
  --dtype half

# 使用 StreamingLLM 支持超长上下文
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --max-model-len 1000000 \
  --enable-prefix-caching
```

### 4.3 PagedAttention 内存管理

```
传统：预分配连续内存 → 内存碎片 + 浪费
       [====    ][========    ][==        ]
       
PagedAttention：按块分配 → 接近 100% 利用
       [块1][块2][块3][块4][块5]...
       按需分配，非连续，支持共享
```

---

## 五、模型并行优化

### 5.1 Tensor Parallel 通信优化

```bash
# 使用 NVLink（单机多卡）
export NCCL_P2P_LEVEL=NVL

# 使用 SHARP（InfiniBand 交换机内聚合）
export NCCL_SHARP_DISABLE=0

# 选择合适的 AllReduce 算法
export NCCL_ALGO=RING  # 或 TREE
```

### 5.2 Pipeline Parallel 气泡优化

```
传统 Pipeline：大量气泡（空闲）
[F1][F2][F3][F4][B1][B2][B3][B4]
    └─ 等待前向完成

1F1B (One Forward One Backward)：减少气泡
[F1][F2][B1][F3][B2][B4][B3]

Interleaved Schedule：进一步减少
[PP1][PP2][PP1][PP3][PP2][PP1]...
```

---

## 六、训练场景 GPU 优化

### 6.1 数据加载瓶颈消除

```python
# PyTorch DataLoader 优化
dataloader = DataLoader(
    dataset,
    batch_size=64,
    num_workers=8,        # 根据 CPU 核心数调整
    pin_memory=True,      # 使用锁页内存，加速 GPU 传输
    prefetch_factor=4,    # 预取批次
    persistent_workers=True,  # 保持 worker 进程
)
```

### 6.2 混合精度训练

```python
from torch.cuda.amp import autocast, GradScaler

scaler = GradScaler()

for data, target in dataloader:
    optimizer.zero_grad()
    
    with autocast():  # FP16 前向
        output = model(data)
        loss = criterion(output, target)
    
    scaler.scale(loss).backward()
    scaler.step(optimizer)
    scaler.update()
```

### 6.3 梯度累积

```python
# 显存不足时，用梯度累积模拟大 batch
accumulation_steps = 4

for i, (data, target) in enumerate(dataloader):
    with autocast():
        output = model(data)
        loss = criterion(output, target) / accumulation_steps
    
    loss.backward()
    
    if (i + 1) % accumulation_steps == 0:
        optimizer.step()
        optimizer.zero_grad()
```

### 6.4 DeepSpeed ZeRO 优化

| ZeRO Stage | 优化内容 | 显存节省 | 适用 |
|------------|----------|----------|------|
| **Stage 1** | 优化器状态分片 | 4× | 大模型微调 |
| **Stage 2** | + 梯度分片 | 8× | 中等模型 |
| **Stage 3** | + 参数分片 | 与数据并行度线性相关 | 超大模型 |

```json
{
  "zero_optimization": {
    "stage": 2,
    "offload_optimizer": {
      "device": "cpu",
      "pin_memory": true
    },
    "allgather_partitions": true,
    "allgather_bucket_size": 2e8,
    "overlap_comm": true,
    "reduce_scatter": true
  },
  "train_batch_size": "auto",
  "train_micro_batch_size_per_gpu": "auto",
  "gradient_accumulation_steps": "auto"
}
```

---

## 七、集群级利用率优化

### 7.1 调度策略优化

```yaml
# Volcano 队列配置：优先级 + 抢占
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: inference-queue
spec:
  weight: 8        # 推理优先级高
  capability:
    nvidia.com/gpu: 16
  reclaimable: true
  
---
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata:
  name: training-queue
spec:
  weight: 2        # 训练优先级低，可被抢占
  capability:
    nvidia.com/gpu: 32
  reclaimable: true
```

### 7.2 GPU 碎片整理

```bash
# 使用 Cluster Autoscaler + Descheduler
descheduler_policy.yaml:
profiles:
  - name: RemovePodsViolatingTopologySpreadConstraint
    pluginConfig:
      - name: RemovePodsViolatingTopologySpreadConstraint
        args:
          includeSoftConstraints: true
  - name: HighNodeUtilization
    pluginConfig:
      - name: HighNodeUtilization
        args:
          thresholds:
            nvidia.com/gpu: 20   # GPU 利用率 <20% 触发重调度
```

### 7.3 动态模型加载/卸载

```python
# 闲时卸载模型到 CPU/磁盘，用时再加载
import torch

class DynamicModelManager:
    def __init__(self):
        self.models = {}
        self.device = 'cuda'
    
    def load_model(self, model_name):
        if model_name not in self.models:
            model = load_from_disk(model_name)
            self.models[model_name] = model.to(self.device)
        return self.models[model_name]
    
    def unload_inactive(self, timeout=300):
        """卸载 5 分钟未使用的模型"""
        for name, (model, last_used) in list(self.models.items()):
            if time.time() - last_used > timeout:
                model.cpu()  # 移到 CPU
                torch.cuda.empty_cache()
```

---

## 八、利用率监控与调优闭环

### 8.1 关键监控指标

| 指标 | 采集方式 | 健康值 | 优化方向 |
|------|----------|--------|----------|
| `dcgm_gpu_utilization` | DCGM | 80-95% | <60% 需优化 |
| `dcgm_mem_copy_utilization` | DCGM | <30% | 过高说明数据瓶颈 |
| `vllm:gpu_cache_usage_perc` | vLLM metrics | 70-90% | KV Cache 配置 |
| `vllm:num_requests_waiting` | vLLM metrics | <10 | 增加并发或扩容 |
| `nccl_all_reduce_time` | NCCL | <20% step time | 检查网络 |
| `data_loader_time` | PyTorch Profiler | <10% step time | 增加 worker |

### 8.2 调优流程

```
1. 采集指标 → 2. 识别瓶颈 → 3. 针对性优化 → 4. 验证效果 → 5. 固化配置

瓶颈类型          优化手段
─────────────────────────────────────────
GPU 利用率低       → 增加并发/batch_size/连续批处理
显存带宽饱和       → 量化/减少数据搬运
PCIe 瓶颈         → 使用锁页内存/pin_memory
CPU 数据瓶颈       → 增加 num_workers/使用 DALI
网络通信瓶颈       → NVLink/SHARP/拓扑感知调度
KV Cache 溢出      → 压缩/限制上下文/Prefix Caching
```

---

## 九、实战案例：从 35% 到 92%

### 背景
- 服务：Qwen2.5-14B 推理服务
- 硬件：4×A100 40GB
- 初始利用率：35%
- 目标：>90%

### 优化步骤

| 步骤 | 优化内容 | 利用率 | 提升 |
|------|----------|--------|------|
| 初始 | 单请求串行处理 | 35% | — |
| 1 | 启用 Continuous Batching | 55% | +20% |
| 2 | max_num_seqs 从 16→64 | 72% | +17% |
| 3 | Prefix Caching 启用 | 78% | +6% |
| 4 | KV Cache FP8 量化 | 82% | +4% |
| 5 | 增加 batch 到 128 | 88% | +6% |
| 6 | 多模型混部（vGPU） | 92% | +4% |

### 最终配置

```bash
vllm serve Qwen/Qwen2.5-14B-Instruct \
  --tensor-parallel-size 2 \
  --dtype half \
  --kv-cache-dtype fp8 \
  --max-num-seqs 128 \
  --max-num-batched-tokens 8192 \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --gpu-memory-utilization 0.92
```


---

# 第四部分：GPU 架构与性能理论

---

## 第16章 GPU 架构深度解析

### 16.1 NVIDIA GPU 架构演进

NVIDIA GPU 从 Pascal 到 Hopper 经历了四代重大革新，每一代都针对 AI 计算进行了专门设计。

#### Pascal (2016) - AI 起点

Pascal 是 NVIDIA 首个在消费级支持 FP16 的架构。P100 引入了 HBM2 显存，但缺乏专用 AI 加速单元，FP16 性能仅为 FP32 的一半。

```
P100 规格：
- 3584 CUDA Cores
- 16GB HBM2
- 732 GB/s 带宽
- FP16: 21.2 TFLOPS
- 无 Tensor Core
```

#### Volta (2017) - Tensor Core 诞生

V100 引入了第一代 Tensor Core，专门用于 4×4×4 FP16 矩阵乘加运算。这是 AI 训练的革命性突破。

```
Tensor Core 工作原理：

传统 CUDA Core：
D = A × B + C  →  需要 64 次 FMA 运算（4×4×4）
每次 FMA = 2 个时钟周期
总计 = 128 个时钟周期

Tensor Core：
D = A × B + C  →  单个 mma.sync.aligned.m8n8k4 指令
只需 1 个时钟周期
加速比 = 128×
```

#### Ampere (2020) - 稀疏性与 MIG

A100 引入了第三代 Tensor Core，支持结构化稀疏性和 TF32 格式。MIG 技术允许将单张 A100 物理切分为最多 7 个独立实例。

```
A100 关键创新：
1. TF32：FP32 的动态范围 + FP16 的吞吐量
2. 结构化稀疏性：2:4 稀疏模式，2× 加速
3. MIG：硬件级 GPU 虚拟化
4. 第三代 NVLink：600 GB/s
```

#### Hopper (2022) - Transformer 专用

H100 是首个专为 Transformer 设计的架构。Transformer Engine 硬件自动在 FP8 和 FP16/BF16 之间动态切换。

```
H100 关键创新：
1. Transformer Engine：FP8 精度自动管理
2. DPX：动态规划加速
3. 第四代 NVLink：900 GB/s
4. HBM3：3.35 TB/s 带宽
```

### 16.2 SM（Streaming Multiprocessor）内部结构

SM 是 GPU 的核心计算单元。理解 SM 结构是优化的基础。

```
┌─────────────────────────────────────────────────────────────┐
│                    Streaming Multiprocessor (SM)             │
│                                                              │
│  ┌─────────────────┐    ┌─────────────────┐                 │
│  │ Warp Scheduler 0│    │ Warp Scheduler 1│                 │
│  │  - 管理 16 个   │    │  - 管理 16 个   │                 │
│  │    warp         │    │    warp         │                 │
│  │  - 每时钟周期   │    │  - 每时钟周期   │                 │
│  │    发射 1 指令  │    │    发射 1 指令  │                 │
│  └────────┬────────┘    └────────┬────────┘                 │
│           │                      │                           │
│  ┌────────▼──────────────────────▼────────┐                 │
│  │         Execution Units                  │                 │
│  │                                          │                 │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐      │                 │
│  │  │FP32 │ │FP32 │ │FP32 │ │FP32 │      │                 │
│  │  │Core │ │Core │ │Core │ │Core │      │                 │
│  │  │(×16)│ │(×16)│ │(×16)│ │(×16)│      │                 │
│  │  └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘      │                 │
│  │     │       │       │       │          │                 │
│  │  ┌──▼───────▼───────▼───────▼──┐      │                 │
│  │  │   Tensor Core (×4, H100)    │      │                 │
│  │  │  - FP64/FP32/FP16/BF16/FP8  │      │                 │
│  │  │  - INT8/INT4                │      │                 │
│  │  └─────────────────────────────┘      │                 │
│  │                                          │                 │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐     │                 │
│  │  │LD/ST│ │LD/ST│ │SFU  │ │SFU  │     │                 │
│  │  │Unit │ │Unit │ │     │ │     │     │                 │
│  │  └─────┘ └─────┘ └─────┘ └─────┘     │                 │
│  └────────────────────────────────────────┘                 │
│                                                              │
│  ┌────────────────────────────────────────┐                 │
│  │  Shared Memory / L1 Cache (228KB)      │                 │
│  │  - 可配置为 Shared Memory 或 L1        │                 │
│  │  - 分为 32 个 bank                     │                 │
│  │  - 延迟：~20 个时钟周期                │                 │
│  └────────────────────────────────────────┘                 │
│                                                              │
│  ┌────────────────────────────────────────┐                 │
│  │  Register File (256KB)                 │                 │
│  │  - 65536 个 32 位寄存器                │                 │
│  │  - 延迟：1 个时钟周期                  │                 │
│  │  - 每个线程最多 255 个寄存器           │                 │
│  └────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

**Warp 调度原理：**

```
Warp = 32 个线程（SIMT 执行模型）

Warp 调度流程：
1. Warp Scheduler 从就绪队列中选择 warp
2. 检查 warp 中所有线程的操作数是否就绪
3. 如果就绪，发射指令到执行单元
4. 如果未就绪（如内存等待），切换至其他 warp

关键概念：
- Warp Divergence：同一 warp 中线程走不同分支
  if (threadIdx.x % 2 == 0) { A } else { B }
  → warp 先执行 A（偶数线程），再执行 B（奇数线程）
  → 效率减半

- Occupancy：活跃的 warp 数 / 最大 warp 数
  H100 每个 SM 支持 64 个 warp
  高 Occupancy 可以隐藏内存延迟
```

### 16.3 GPU 内存层次结构详解

```
速度 ─────────────────────────────────────────► 容量
1ns        20ns       200ns       800ns      10μs
 │          │          │           │          │
 ▼          ▼          ▼           ▼          ▼
┌────┐   ┌────────┐  ┌─────┐   ┌──────┐   ┌──────┐
│Reg │   │Shared  │  │L2   │   │HBM   │   │System│
│File│   │Memory  │  │Cache│   │(VRAM)│   │RAM   │
│    │   │/L1     │  │     │   │      │   │      │
│1TB/s│  │10TB/s  │  │4TB/s│   │3TB/s │   │50GB/s│
│256KB│  │228KB   │  │50MB │   │80GB  │   │1TB   │
└────┘   └────────┘  └─────┘   └──────┘   └──────┘

每级延迟增加 10×，带宽减少 10×
```

**内存访问优化原则：**

1. **寄存器优先**：最常用的数据放在寄存器
2. **共享内存复用**：同一线程块内数据共享
3. **合并全局内存访问**：同一 warp 访问连续地址
4. **利用 L2 缓存**：A100 50MB L2 可缓存大量 KV Cache
5. **避免 bank conflict**：共享内存的 32 个 bank

### 16.4 Roofline 模型

Roofline 模型是分析 GPU 性能瓶颈的经典方法。

```
性能 (FLOP/s)
     │
     │        ┌────────────── 峰值算力（平顶）
     │       /│
     │      / │
     │     /  │
     │    /   │
     │   /    │
     │  /     │
     │ /      │
     │/  显存带宽限制（斜坡）
     └────────┴────────────────►
              运算强度 (FLOP/Byte)

运算强度 = 计算量 (FLOP) / 数据量 (Byte)

关键阈值：
- 峰值算力 / 显存带宽 = 运算强度阈值
- H100: 1979 TFLOPS / 3.35 TB/s = 590 FLOP/Byte
- 低于阈值：内存瓶颈
- 高于阈值：计算瓶颈
```

**LLM 推理的 Roofline 分析：**

```python
# Attention 计算的运算强度
# Q @ K^T: (seq_len, head_dim) @ (head_dim, seq_len)
# 计算量: 2 * seq_len^2 * head_dim FLOP
# 数据量: 2 * seq_len * head_dim * 2 bytes (FP16)
# 运算强度: seq_len / 2

# 当 seq_len = 4096 时:
# 运算强度 = 2048 FLOP/Byte
# H100 阈值 = 590
# 2048 > 590 → 计算瓶颈（可以利用 Tensor Core）

# 当 seq_len = 512 时:
# 运算强度 = 256 FLOP/Byte
# 256 < 590 → 内存瓶颈（需要优化内存访问）
```

---

## 第17章 Attention 优化演进史

### 17.1 标准 Attention 的问题

```python
# 标准 Self-Attention
# Q, K, V: (batch, seq_len, head_dim)

# 1. Q @ K^T: O(n^2 * d)
scores = Q @ K.transpose(-2, -1) / sqrt(d)
# 计算量: 2 * batch * heads * seq_len^2 * head_dim

# 2. Softmax
attn_weights = softmax(scores, dim=-1)

# 3. @ V: O(n^2 * d)
output = attn_weights @ V
# 计算量: 2 * batch * heads * seq_len^2 * head_dim

# 总计算量: 4 * batch * heads * seq_len^2 * head_dim
# 显存: O(seq_len^2) 的 attention matrix
```

**当 seq_len = 32768 时：**
- Attention matrix: 32768 × 32768 × 2 bytes = 2GB per head!
- 计算量: 4 × 32 × 32768² × 128 = 175 TFLOP

### 17.2 FlashAttention (2022)

FlashAttention 的核心思想：**分块计算 Attention，避免实例化完整的 Attention Matrix**。

```python
# FlashAttention 算法（简化版）
def flash_attention(Q, K, V, block_size=256):
    """
    Q, K, V: (seq_len, head_dim)
    """
    seq_len, head_dim = Q.shape
    O = torch.zeros_like(Q)
    L = torch.zeros(seq_len)
    
    # 分块处理
    for i in range(0, seq_len, block_size):
        Qi = Q[i:i+block_size]
        
        # 初始化局部 softmax 统计
        m = torch.full((block_size,), float('-inf'))
        l = torch.zeros(block_size)
        
        for j in range(0, seq_len, block_size):
            Kj = K[j:j+block_size]
            Vj = V[j:j+block_size]
            
            # 计算局部 attention scores
            Sij = Qi @ Kj.T / sqrt(head_dim)
            
            # 在线 softmax
            mij = Sij.max(dim=-1).values
            Pij = torch.exp(Sij - mij.unsqueeze(-1))
            lij = Pij.sum(dim=-1)
            
            # 更新全局统计
            m_new = torch.max(m, mij)
            l = torch.exp(m - m_new) * l + torch.exp(mij - m_new) * lij
            
            # 更新输出
            O[i:i+block_size] = ...
    
    return O
```

**FlashAttention 的优势：**
- 显存：从 O(N²) 降到 O(N)
- 速度：2-4× 加速（由于更好的内存访问模式）
- 精度：无近似，精确计算

### 17.3 FlashAttention-2 (2023)

改进点：
1. 减少非 matmul 的 FLOP
2. 更好的 Warp 调度，减少 idle
3. 支持 Head 维度高达 256

### 17.4 FlashDecoding (2023)

针对**长序列推理**的优化。问题：生成阶段（Decode）的 seq_len=1，无法利用 FlashAttention 的并行性。

```python
# FlashDecoding 核心思想：
# 将 KV Cache 分成多个 chunk，并行计算

# 传统 Decode：
# q: (1, head_dim)
# k, v: (seq_len, head_dim)
# 只能顺序计算，利用率极低

# FlashDecoding：
# 将 k, v 分成 8 个 chunk
# 每个 chunk 并行计算 local attention
# 最后合并结果

# 加速比：8×（在 A100 上）
```

### 17.5 PagedAttention (vLLM)

前面已详细讲解，核心是将 KV Cache 分块管理，类似 OS 虚拟内存。

**Attention 优化对比表：**

| 方法 | 显存复杂度 | 计算复杂度 | 精度 | 适用场景 |
|------|-----------|-----------|------|----------|
| 标准 Attention | O(N²) | O(N²) | 精确 | 短序列 |
| FlashAttention | O(N) | O(N²) | 精确 | 训练/长序列 |
| FlashDecoding | O(N) | O(N²) | 精确 | 推理/长序列 |
| PagedAttention | O(N) | O(N²) | 精确 | 批处理推理 |
| Sparse Attention | O(N√N) | O(N√N) | 近似 | 极长序列 |
| Linear Attention | O(N) | O(N) | 近似 | 理论最优 |

---

## 第18章 批处理策略深度对比

### 18.1 静态批处理（Static Batching）

```python
# 等待 batch_size 个请求，一起处理
batch_size = 8

# 收集请求
requests = []
while len(requests) < batch_size:
    req = get_request(timeout=100ms)
    if req:
        requests.append(req)

# 一起推理
inputs = pad_to_same_length([r.input for r in requests])
outputs = model.generate(inputs)

# 问题：
# 1. 需要等待 batch 满，延迟高
# 2. 不同长度的请求需要 pad，浪费计算
# 3. 先生成的请求需要等待后生成的，GPU 空闲
```

### 18.2 动态批处理（Dynamic Batching / In-flight Batching）

```python
# 核心思想：请求随时加入、随时退出

# vLLM 的调度循环：
while True:
    # 1. 接受新请求
    new_requests = accept_new_requests()
    
    # 2. 添加新请求的 prompt tokens
    for req in new_requests:
        scheduler.add_request(req)
    
    # 3. 所有正在运行的请求生成 1 个 token
    for req in running_requests:
        if not req.done():
            scheduler.schedule_token_generation(req)
    
    # 4. 完成的请求移除
    running_requests = [r for r in running_requests if not r.done()]
    
    # 5. 执行一次 forward
    model_step()
```

**关键优化：不同请求可以处于不同生成阶段**

```
时间 T1:
  Req1: [prompt][t1]  ← 新请求，在做 prefill
  Req2: [prompt][t1][t2][t3]  ← 生成中
  Req3: [prompt][t1]  ← 新请求

时间 T2:
  Req1: [prompt][t1][t2]  ← 继续生成
  Req2: [prompt][t1][t2][t3][t4]  ← 继续生成
  Req3: [prompt][t1][t2]  ← 继续生成
  Req4: [prompt]  ← 新请求加入

所有请求共享一次 forward！
```

### 18.3 迭代级批处理（Iteration-level Batching）

这是 vLLM 和 TGI 使用的策略，也是目前最先进的批处理方式。

```python
# 迭代级调度的核心数据结构
class Scheduler:
    def __init__(self):
        self.waiting = []      # 等待 prefill 的请求
        self.running = []      # 正在生成 token 的请求
        self.swapped = []      # 被换出到 CPU 的请求
    
    def step(self):
        # 1. 尝试调度 waiting 请求做 prefill
        scheduled = []
        for seq_group in self.waiting:
            if self.can_allocate(seq_group):
                scheduled.append(seq_group)
                self.waiting.remove(seq_group)
        
        # 2. running 请求继续生成
        for seq_group in self.running:
            scheduled.append(seq_group)
        
        # 3. 执行 forward
        # prefill 请求和 decode 请求可以混合在一个 batch 中
        outputs = self.model.forward(scheduled)
        
        # 4. 处理输出
        for seq_group, output in zip(scheduled, outputs):
            if seq_group.is_prefill():
                # Prefill 完成，转为 decode
                seq_group.set_decode()
                self.running.append(seq_group)
            else:
                # Decode 生成新 token
                seq_group.append_token(output)
                if seq_group.is_finished():
                    self.running.remove(seq_group)
        
        return outputs
```

**迭代级批处理的优势：**

| 指标 | 静态批处理 | 动态批处理 | 迭代级批处理 |
|------|----------|----------|------------|
| GPU利用率 | 20-40% | 50-70% | 80-95% |
| 平均延迟 | 高 | 中 | 低 |
| 尾延迟 | 极高 | 高 | 中 |
| 实现复杂度 | 低 | 中 | 高 |
| 吞吐 | 低 | 中 | 高 |

---

## 第19章 Profiling 工具使用指南

### 19.1 Nsight Systems

Nsight Systems 是 NVIDIA 提供的系统级性能分析工具，可以查看 CPU 和 GPU 的时间线。

```bash
# 安装
sudo apt install nvidia-nsight-systems

# 基本使用
nsys profile -o profile_report \
  --trace=cuda,nvtx,osrt \
  python inference.py

# 查看报告
nsys-ui profile_report.nsys-rep

# 关键参数：
# --trace=cuda: 追踪 CUDA API 调用
# --trace=nvtx: 追踪 NVTX 标记（代码中的注释）
# --trace=osrt: 追踪操作系统运行时
# --sample=cpu: CPU 采样
# --duration=60: 追踪 60 秒
```

**Nsight Systems 报告解读：**

```
时间线视图：
├─ CPU Threads
│  ├─ Main Thread: [数据加载][预处理][=========CUDA Launch=========]
│  └─ DataLoader: [加载batch 1][加载batch 2][加载batch 3]
│
├─ CUDA API
│  ├─ cudaLaunchKernel: |←→| |←→| |←→| |←→|
│  ├─ cudaMemcpy: |←→|        |←→|
│  └─ cudaStreamSynchronize: |←──────────→|
│
└─ GPU Streams
   ├─ Stream 1: [Kernel A][Kernel B][Kernel C]
   ├─ Stream 2:        [Kernel D][Kernel E]
   └─ Stream 3: [memcpy H2D]        [memcpy D2H]

关键指标：
- GPU idle time: GPU 空闲时间占比
- CPU-GPU overlap: CPU 和 GPU 并行工作的比例
- Kernel launch latency: 从 cudaLaunchKernel 到实际执行的时间
```

### 19.2 Nsight Compute

Nsight Compute 是内核级性能分析工具，可以深入分析单个 CUDA Kernel 的性能。

```bash
# 基本使用
ncu -o profile \
  --metrics sm__throughput.avg.pct_of_peak_sustained_elapsed \
  python inference.py

# 查看报告
ncu-ui profile.ncu-rep

# 常用指标：
# sm__throughput: SM 利用率
# dram__throughput: 显存带宽利用率
# l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum: L1/TEX 加载量
# smsp__sass_thread_inst_executed_op_fadd_pred_on.sum: FADD 指令数
```

**关键指标解读：**

| 指标 | 健康值 | 说明 |
|------|--------|------|
| SM Utilization | >80% | SM 利用率 |
| Memory Throughput | >70% | 显存带宽利用率 |
| L2 Hit Rate | >80% | L2 缓存命中率 |
| Occupancy | >60% | Warp 占用率 |
| Tensor Core Utilization | >50% | Tensor Core 利用率 |

### 19.3 PyTorch Profiler

```python
import torch
from torch.profiler import profile, record_function, ProfilerActivity

# 使用 PyTorch Profiler
with profile(
    activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
    record_shapes=True,
    profile_memory=True,
    with_stack=True
) as prof:
    
    with record_function("model_inference"):
        output = model.generate(input_ids)
    
    with record_function("post_process"):
        result = post_process(output)

# 打印结果
print(prof.key_averages().table(sort_by="cuda_time_total", row_limit=10))

# 导出为 Chrome trace
prof.export_chrome_trace("trace.json")
# 在 chrome://tracing 中打开

# 典型输出：
# -------------------------  ------------  ------------  ------------  ------------
#                      Name    Self CPU %      Self CUDA    CUDA total    # of Calls
# -------------------------  ------------  ------------  ------------  ------------
#              aten::matmul         5.2%      125.23 ms      450.12 ms          256
#               aten::linear         3.1%       89.45 ms      312.34 ms          128
#            aten::softmax         1.8%       45.67 ms       67.89 ms          128
# -------------------------  ------------  ------------  ------------  ------------
```

---

## 第20章 真实案例深度剖析

### 案例1：某电商平台 LLM 客服优化

**背景：**
- 模型：Qwen2.5-14B-Instruct
- 硬件：8×RTX 4090
- 场景：智能客服，回答用户咨询
- 日均请求：500 万次

**初始状态：**

| 指标 | 数值 | 问题 |
|------|------|------|
| GPU利用率 | 28% | 极低 |
| P99延迟 | 4.2s | 过高 |
| 单卡吞吐 | 15 t/s | 低 |
| 并发数 | 2 | 几乎无并发 |
| 日均成本 | $2400 | 高 |

**优化过程：**

**第1步：启用 Continuous Batching**
```bash
# 之前：每个请求单独处理
# 之后：batch 处理
vllm serve ... --max-num-seqs 64

# 效果：
# GPU利用率: 28% → 55%
# 吞吐: 15 → 35 t/s
```

**第2步：Prefix Caching**
```bash
# 所有请求都有相同的 system prompt
vllm serve ... --enable-prefix-caching

# 效果：
# TTFT: 800ms → 200ms
# GPU利用率: 55% → 68%
```

**第3步：调整 max-num-batched-tokens**
```bash
# 实验不同值
for t in 1024 2048 4096 8192; do
  vllm serve ... --max-num-batched-tokens $t
  benchmark.sh
done

# 最优值：4096
# 吞吐: 35 → 52 t/s
# GPU利用率: 68% → 78%
```

**第4步：INT8 量化**
```bash
vllm serve Qwen/Qwen2.5-14B-Instruct-AWQ \
  --quantization awq

# 效果：
# 显存节省 50%
# 并发数: 8 → 24
# GPU利用率: 78% → 88%
```

**第5步：动态模型加载**
```python
# 夜间低峰期卸载模型，释放显存给其他任务
# 高峰期前预热加载

class DynamicModelManager:
    def __init__(self):
        self.models = {}
    
    def load(self, model_name):
        if model_name not in self.models:
            self.models[model_name] = load_model(model_name)
    
    def unload(self, model_name):
        if model_name in self.models:
            del self.models[model_name]
            torch.cuda.empty_cache()
```

**最终状态：**

| 指标 | 优化前 | 优化后 | 提升 |
|------|--------|--------|------|
| GPU利用率 | 28% | 92% | 3.3× |
| P99延迟 | 4.2s | 450ms | 9.3× |
| 单卡吞吐 | 15 t/s | 78 t/s | 5.2× |
| 并发数 | 2 | 32 | 16× |
| 日均成本 | $2400 | $720 | 3.3× |

### 案例2：某金融公司 RAG 系统优化

**背景：**
- Embedding模型 + 14B LLM 推理混部
- 8×A100 40GB

**优化策略：**
1. HAMi vGPU：Embedding 用 0.3 GPU，LLM 用 0.7 GPU
2. 时间片调度：白天推理优先，夜间训练优先
3. KV Cache 压缩：FP8 量化

**结果：**
- GPU利用率从 35% 提升到 85%
- 成本降低 60%

### 案例3：某大厂训练集群网络优化

**背景：**
- 64 节点 × 8 A100 = 512 GPU
- 训练 70B 模型，MFU（Model FLOPs Utilization）仅 25%

**瓶颈分析：**
1. Nsight 分析发现 AllReduce 占 40% 时间
2. IB 带宽测试发现仅达到理论值的 50%

**优化措施：**
1. IB 网络调优：
```bash
export NCCL_IB_GID_INDEX=3
export NCCL_IB_TC=106
export NCCL_IB_QPS_PER_CONNECTION=4
export NCCL_SOCKET_NTHREADS=2
```

2. 拓扑感知调度：
```yaml
# 确保同一 Job 的 Pod 在同一个 ToR 交换机下
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: job-name
              operator: In
              values: ["training-70b"]
        topologyKey: topology.kubernetes.io/rack
```

3. Gradient Bucket 调优：
```python
# PyTorch DDP
torch.distributed.init_process_group(
    backend='nccl',
    bucket_cap_mb=100  # 从默认 25MB 提升到 100MB
)
```

**结果：**
- AllReduce 时间从 40% 降到 18%
- MFU 从 25% 提升到 52%
- 训练速度提升 2.1×


---

# 第四部分：GPU 架构与性能优化原理

---

## 第16章 GPU 架构深度解析

### 16.1 NVIDIA GPU 架构演进与计算模型

#### GPU 与 CPU 的本质区别

```
CPU 架构（以 Intel Xeon 为例）：
┌─────────────────────────────────────────┐
│  少量核心（64核）                        │
│  每个核心强大、复杂                       │
│  ├── 大缓存（L1: 32KB, L2: 1MB, L3: 36MB）│
│  ├── 分支预测、乱序执行                    │
│  ├── 高精度时钟（3GHz+）                  │
│  └── 适合串行任务、复杂逻辑               │
└─────────────────────────────────────────┘

GPU 架构（以 H100 为例）：
┌─────────────────────────────────────────┐
│  大量核心（16896 CUDA Core）             │
│  每个核心简单、专一                       │
│  ├── 小缓存（L1: 256KB per SM）          │
│  ├── 无分支预测（或简单）                  │
│  ├── SIMT 执行模型                        │
│  └── 适合并行任务、数据并行计算            │
└─────────────────────────────────────────┘
```

**SIMT（Single Instruction Multiple Threads）执行模型：**

```
Warp = 32 个线程（NVIDIA GPU 的基本执行单位）

Warp 调度器一次发射一条指令，32 个线程同时执行
如果线程走不同分支，需要串行执行每个分支（线程发散）

示例：
if (thread_id % 2 == 0) {
    // 偶数线程执行 A
} else {
    // 奇数线程执行 B
}

执行流程：
Cycle 1-10: Warp 中偶数线程执行 A，奇数线程等待
Cycle 11-20: Warp 中奇数线程执行 B，偶数线程等待
→ 实际执行时间 = A时间 + B时间（线程发散惩罚）
```

### 16.2 内存层次结构详解

#### 各层级内存的特性

| 内存类型 | 大小（per SM） | 延迟 | 带宽 | 生命周期 | 可见范围 |
|----------|---------------|------|------|----------|----------|
| **寄存器** | 256KB | 1 cycle | ~20TB/s | 线程 | 单个线程 |
| **共享内存/L1** | 164KB 可配置 | ~20 cycles | ~10TB/s | 线程块 | 同线程块 |
| **L2 缓存** | 全芯片共享 | ~200 cycles | ~2-4TB/s | 全局 | 所有 SM |
| **HBM 显存** | 80GB | ~400 cycles | 3.35TB/s | 全局 | 所有 SM |
| **系统内存** | 主机内存 | ~数μs | 50GB/s | 主机 | CPU+GPU |

#### 内存访问模式优化

```
好的内存访问模式（合并访问）：
Warp 中的线程访问连续地址
Thread 0: addr + 0
Thread 1: addr + 4
Thread 2: addr + 8
...
Thread 31: addr + 124
→ 合并为 1-2 次 128B 事务

坏的内存访问模式（随机访问）：
Thread 0: addr + 1000
Thread 1: addr + 57
Thread 2: addr + 3024
...
→ 32 次独立事务
→ 性能下降 10-100 倍
```

### 16.3 Tensor Core 工作原理

Tensor Core 是 NVIDIA GPU 上专门用于加速矩阵乘法的硬件单元。

#### 矩阵乘法加速原理

```
传统 CUDA Core 计算 4×4×4 矩阵乘法：

for i in 0..3:
  for j in 0..3:
    for k in 0..3:
      C[i][j] += A[i][k] * B[k][j]
      
→ 64 次 FMA 运算
→ 需要 64 条指令
→ 64 个时钟周期（假设每个周期1条指令）

Tensor Core 计算 4×4×4 矩阵乘法：

mma.sync.aligned.m8n8k4.row.col.f16.f16.f16.f16
→ 1 条指令
→ 1 个时钟周期
→ 完成 4×4×4 的矩阵乘加

加速比：64×（对于小矩阵）
```

#### 不同架构的 Tensor Core 能力

| 架构 | Tensor Core 代数 | 支持精度 | 矩阵大小 | 稀疏加速 |
|------|------------------|----------|----------|----------|
| Volta | 第1代 | FP16 | 4×4×4 | 否 |
| Turing | 第2代 | FP16, INT8, INT4 | 4×4×4 | 否 |
| Ampere | 第3代 | FP16, BF16, TF32, INT8, 稀疏FP16 | 8×8×4 | 2× |
| Hopper | 第4代 | FP16, BF16, FP8, 稀疏FP8/FP16 | 16×16×8 | 2× |

### 16.4 Roofline 模型在 GPU 上的应用

Roofline 模型是分析程序性能瓶颈的理论框架。

```
                    计算性能 (TFLOPS)
                         │
    峰值算力 ────────────┼────────────────────── 平顶
    (Tensor Core)        │
                         │           ╱
    峰值算力 ────────────┼──────────╱─────────── 内存带宽受限区
    (CUDA Core)          │         ╱
                         │        ╱
                         │       ╱
                         │      ╱
    内存带宽斜率 ────────┼─────╱────────────────
                         │    ╱
                         │   ╱
                         │  ╱
                         │ ╱
                         │╱
                         └──────────────────────►
                         计算强度 (FLOPs/Byte)

计算强度 = 每个字节数据进行的浮点运算次数

区域判断：
- 点在斜线下方 → 内存带宽瓶颈
- 点在平顶下方 → 计算瓶颈
- 靠近斜线和平顶交界 → 均衡
```

**Transformer 推理的计算强度分析：**

```
计算强度 = 计算量 / 显存访问量

Attention 层：
- QK^T 矩阵乘法: O(n²d) 计算, O(n²) 内存访问
- 计算强度 ≈ d (hidden_size)

FFN 层：
- 两个矩阵乘法: O(nd²) 计算, O(nd) 内存访问
- 计算强度 ≈ d

对于 d=4096：
- 理论计算强度 = 4096 FLOPs/Byte
- H100 内存带宽 = 3.35TB/s → 斜率 = 3.35 × 10¹² Byte/s
- 需要 3.35 × 10¹² × 4096 = 13.7 PFLOPS 才能达到计算瓶颈
- H100 FP16 峰值 = 989 TFLOPS → 实际在带宽瓶颈区！

结论：
大多数 Transformer 推理操作都是内存带宽瓶颈的，
因此提高 GPU 利用率的关键是：
1. 提高内存带宽利用率（合并访问、缓存命中）
2. 减少内存访问量（量化、KV Cache压缩）
3. 提高计算强度（增大 batch_size）
```

---

## 第17章 推理优化深度指南

### 17.1 Attention 机制优化演进史

#### 标准 Attention（O(n²) 复杂度）

```python
# 标准 Self-Attention
import torch
import torch.nn as nn

def standard_attention(Q, K, V, mask=None):
    """
    Q, K, V: [batch, heads, seq_len, head_dim]
    """
    # Q @ K^T
    scores = torch.matmul(Q, K.transpose(-2, -1))  # [batch, heads, seq, seq]
    scores = scores / math.sqrt(Q.size(-1))
    
    if mask is not None:
        scores = scores.masked_fill(mask == 0, float('-inf'))
    
    # Softmax
    attn_weights = torch.softmax(scores, dim=-1)
    
    # @ V
    output = torch.matmul(attn_weights, V)  # [batch, heads, seq, head_dim]
    
    return output

# 计算复杂度：
# QK^T: O(seq_len² × head_dim)
# Softmax: O(seq_len²)
# @V: O(seq_len² × head_dim)
# 总复杂度：O(seq_len² × head_dim)
# 
# 当 seq_len = 8192, head_dim = 128:
# 计算量 ≈ 8192² × 128 ≈ 8.6 × 10⁹ FLOPs
```

#### FlashAttention（分块 + 重计算）

FlashAttention 的核心思想是：**避免将完整的注意力矩阵写入 HBM（高带宽显存），而是在 SRAM（快速缓存）中分块计算。**

```python
# FlashAttention 伪代码
def flash_attention(Q, K, V, block_size=64):
    """
    分块计算 Attention，避免 materialize 完整的注意力矩阵
    """
    seq_len = Q.size(2)
    head_dim = Q.size(3)
    
    # 初始化输出
    O = torch.zeros_like(Q)
    L = torch.zeros(Q.size(0), Q.size(1), seq_len, 1)
    M = torch.full((Q.size(0), Q.size(1), seq_len, 1), float('-inf'))
    
    # 分块数
    num_blocks = seq_len // block_size
    
    for j in range(num_blocks):
        # 加载 K, V 的一个块到 SRAM
        Kj = K[:, :, j*block_size:(j+1)*block_size, :]
        Vj = V[:, :, j*block_size:(j+1)*block_size, :]
        
        for i in range(num_blocks):
            # 加载 Q 的一个块
            Qi = Q[:, :, i*block_size:(i+1)*block_size, :]
            
            # 在 SRAM 中计算 S = Qi @ Kj^T
            Sij = torch.matmul(Qi, Kj.transpose(-2, -1))
            
            # Online Softmax（不需要完整矩阵）
            # 更新 running max
            Mij = torch.max(M[:, :, i*block_size:(i+1)*block_size], 
                           Sij.max(dim=-1, keepdim=True).values)
            
            # 计算 P = exp(S - M)
            Pij = torch.exp(Sij - Mij)
            
            # 更新输出
            O[:, :, i*block_size:(i+1)*block_size] += torch.matmul(Pij, Vj)
            L[:, :, i*block_size:(i+1)*block_size] += Pij.sum(dim=-1, keepdim=True)
    
    # 归一化
    O = O / L
    
    return O

# 优势：
# 1. 不需要存储完整的 [seq, seq] 注意力矩阵
# 2. HBM 读写量从 O(seq²) 降低到 O(seq)
# 3. 对于长序列，速度提升 2-4 倍
```

#### PagedAttention（vLLM）

前面第12章已详细讲解，这里补充内部实现细节：

```python
# PagedAttention 的核心：Block Table 管理

class PagedAttentionKernel:
    def __init__(self, block_size=16, num_blocks=10000):
        self.block_size = block_size
        self.num_blocks = num_blocks
        self.block_table = {}  # seq_id -> [block_ids]
        self.free_blocks = list(range(num_blocks))
    
    def allocate(self, seq_id, num_tokens):
        """为序列分配物理块"""
        num_blocks_needed = (num_tokens + self.block_size - 1) // self.block_size
        
        blocks = []
        for _ in range(num_blocks_needed):
            if not self.free_blocks:
                raise OutOfMemoryError("No free blocks")
            blocks.append(self.free_blocks.pop())
        
        self.block_table[seq_id] = blocks
        return blocks
    
    def append(self, seq_id, new_token_k, new_token_v):
        """追加新 token 的 KV Cache"""
        blocks = self.block_table[seq_id]
        last_block = blocks[-1]
        
        # 检查最后一个块是否已满
        if self.is_block_full(last_block):
            # 分配新块
            new_block = self.free_blocks.pop()
            blocks.append(new_block)
            last_block = new_block
        
        # 写入 KV Cache
        self.write_kv(last_block, new_token_k, new_token_v)
    
    def copy_on_write(self, from_seq, to_seq):
        """Copy-on-Write 复制（用于 beam search / 共享前缀）"""
        # 初始共享相同的块
        self.block_table[to_seq] = self.block_table[from_seq].copy()
        
        # 设置引用计数
        for block in self.block_table[to_seq]:
            self.ref_count[block] += 1
    
    def fork(self, parent_seq, child_seq):
        """分叉序列，共享前缀"""
        self.block_table[child_seq] = self.block_table[parent_seq].copy()
        for block in self.block_table[child_seq]:
            self.ref_count[block] += 1
```

#### FlashDecoding（长序列解码优化）

FlashDecoding 解决的是**长序列生成时，单 token 解码的并行度不足问题**。

```python
# 问题：生成第 N+1 个 token 时
# Q 只有 1 个 token，但 K, V 有 N 个 token
# 矩阵乘法退化成了向量-矩阵乘法，无法充分利用 Tensor Core

# FlashDecoding 解决方案：
# 将 K, V 分成多个块，并行计算每个块的 attention
# 最后合并结果

def flash_decoding(Q_single, K, V, block_size=1024):
    """
    Q_single: [1, head_dim]
    K, V: [seq_len, head_dim]
    """
    seq_len = K.size(0)
    num_blocks = (seq_len + block_size - 1) // block_size
    
    # 并行计算每个块的 attention
    partial_outputs = []
    partial_maxes = []
    partial_sums = []
    
    for i in range(num_blocks):
        start = i * block_size
        end = min((i + 1) * block_size, seq_len)
        
        Ki = K[start:end]
        Vi = V[start:end]
        
        # 这个块可以在一个 thread block 中计算
        Si = torch.matmul(Q_single, Ki.T)
        mi = Si.max()
        Pi = torch.exp(Si - mi)
       Oi = torch.matmul(Pi, Vi)
        li = Pi.sum()
        
        partial_outputs.append(Oi)
        partial_maxes.append(mi)
        partial_sums.append(li)
    
    # 合并所有块的结果（需要处理 softmax 的归一化）
    # ... 使用 online softmax 合并
    
    return final_output

# 效果：
# 标准解码：1 个 warp 处理所有 K, V
# FlashDecoding：num_blocks 个 warp 并行处理
# 对于 32K 序列，block=1K，可以并行 32 个 warp
# 加速比：~4-8×
```

### 17.2 批处理策略深度对比

#### 四种批处理策略

| 策略 | 原理 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|----------|
| **静态批处理** | 固定 batch_size，等所有请求完成后一起返回 | 实现简单 | GPU 空闲等待 | 离线推理 |
| **动态批处理** | 运行时收集请求，达到一定数量或超时后处理 | 减少等待 | 仍有空闲 | 在线服务 |
| **连续批处理** | 新请求随时加入，完成的请求随时退出 | GPU 利用率高 | 实现复杂 | **在线服务首选** |
| **迭代级批处理** | 每个解码迭代重新选择 batch | 最优利用率 | 调度开销大 | 极致性能 |

#### 连续批处理实现细节

```python
class ContinuousBatchingScheduler:
    def __init__(self, max_batch_size=256, max_model_len=8192):
        self.waiting = deque()      # 等待队列
        self.running = []            # 正在运行的序列组
        self.max_batch_size = max_batch_size
        self.max_model_len = max_model_len
        self.block_manager = BlockManager()
    
    def step(self):
        """每个解码步骤调用一次"""
        
        # 1. 尝试将 waiting 中的请求加入 running
        while self.waiting:
            seq_group = self.waiting[0]
            
            # 检查是否可以分配显存
            if not self.can_allocate(seq_group):
                break
            
            # 检查 batch size 限制
            if len(self.running) >= self.max_batch_size:
                break
            
            # 检查序列长度限制
            if seq_group.get_len() >= self.max_model_len:
                break
            
            # 加入 running
            self.running.append(seq_group)
            self.waiting.popleft()
            
            # 分配 KV Cache 块
            self.block_manager.allocate(seq_group)
        
        # 2. 执行一步前向推理
        # 收集所有 running 序列的 input_ids
        input_ids = []
        positions = []
        for seq_group in self.running:
            seq = seq_group.get_seqs(status=SequenceStatus.RUNNING)[0]
            input_ids.append(seq.get_last_token_id())
            positions.append(seq.get_len() - 1)
        
        # 构建 attention mask（处理不同长度）
        # 调用模型前向
        # ...
        
        # 3. 处理完成的序列
        finished = []
        for seq_group in self.running:
            if seq_group.is_finished():
                finished.append(seq_group)
                self.block_manager.free(seq_group)
        
        for seq_group in finished:
            self.running.remove(seq_group)
        
        # 4. 处理被抢占的序列（显存不足时）
        if not self.can_run_all():
            # 选择低优先级序列进行抢占
            victims = self.select_preemption_victims()
            for victim in victims:
                # 将 KV Cache 换出到 CPU
                self.swap_out(victim)
                self.running.remove(victim)
                self.swapped.append(victim)
    
    def can_allocate(self, seq_group):
        """检查是否有足够的空闲块"""
        num_required_blocks = seq_group.get_num_required_blocks()
        return self.block_manager.num_free_blocks() >= num_required_blocks
```

### 17.3 KV Cache 优化策略

#### KV Cache 压缩技术

| 技术 | 原理 | 压缩比 | 精度损失 | 实现难度 |
|------|------|--------|----------|----------|
| **FP8 量化** | KV Cache 从 FP16 转为 FP8 | 2× | <1% | 低（H100原生） |
| **INT8 量化** | 对称/非对称量化 | 2× | 2-3% | 中 |
| **分组量化** | per-head 或 per-layer 不同精度 | 2-4× | 3-5% | 中 |
| **H2O（Heavy Hitter Oracle）** | 只保留重要的 KV | 20-50% | <3% | 高 |
| **StreamingLLM** | 只保留最近 + attention sinks | 50-90% | <3% | 中 |
| **SnapKV** | 自适应压缩 | 30-50% | <2% | 高 |

#### StreamingLLM 实现

```python
class StreamingLLM:
    def __init__(self, sink_tokens=4, recent_tokens=1024):
        """
        sink_tokens: 始终保留的起始 token 数量（attention sinks）
        recent_tokens: 最近保留的 token 数量
        """
        self.sink_tokens = sink_tokens
        self.recent_tokens = recent_tokens
        self.evicted_tokens = 0
    
    def get_kv_cache_window(self, total_tokens):
        """确定需要保留的 KV Cache 窗口"""
        if total_tokens <= self.sink_tokens + self.recent_tokens:
            # 全部保留
            return list(range(total_tokens))
        
        # 保留 sink tokens + 最近的 tokens
        kept_indices = (
            list(range(self.sink_tokens)) +  # 前 4 个 sink tokens
            list(range(total_tokens - self.recent_tokens, total_tokens))  # 最近 1024 个
        )
        
        self.evicted_tokens = total_tokens - len(kept_indices)
        return kept_indices
    
    def compress_kv_cache(self, K, V, total_tokens):
        """压缩 KV Cache"""
        kept_indices = self.get_kv_cache_window(total_tokens)
        K_compressed = K[:, :, kept_indices, :]
        V_compressed = V[:, :, kept_indices, :]
        return K_compressed, V_compressed

# 原理说明：
# 为什么 sink tokens 有效？
# 1. Softmax 的注意力权重总和为 1
# 2. 如果没有初始 token 的注意力，其他 token 的注意力分布会不稳定
# 3. 保留前几个 token（通常是 system prompt 的一部分）可以稳定注意力模式
# 4. 实验表明保留 4 个初始 token 即可获得接近完整的性能
```

### 17.4 多轮对话优化

#### 上下文复用策略

```python
class ConversationManager:
    def __init__(self, model, tokenizer):
        self.model = model
        self.tokenizer = tokenizer
        self.cache = {}  # conversation_id -> KV Cache
    
    def generate_with_context_reuse(self, conversation_id, new_message):
        """
        多轮对话时复用之前的 KV Cache
        """
        if conversation_id in self.cache:
            # 复用之前的 KV Cache
            past_kv = self.cache[conversation_id]
            
            # 只编码新消息
            new_tokens = self.tokenizer.encode(new_message)
            
            # 使用 past_key_values 参数传入缓存
            output = self.model.generate(
                input_ids=new_tokens,
                past_key_values=past_kv,
                use_cache=True
            )
            
            # 更新缓存
            self.cache[conversation_id] = output.past_key_values
            
        else:
            # 第一次对话，完整编码
            full_prompt = self.build_prompt(new_message)
            tokens = self.tokenizer.encode(full_prompt)
            
            output = self.model.generate(
                input_ids=tokens,
                use_cache=True
            )
            
            self.cache[conversation_id] = output.past_key_values
        
        return output
    
    def manage_cache_size(self):
        """
        当缓存过大时，策略：
        1. LRU 淘汰
        2. 压缩旧对话的 KV Cache
        3. 将不活跃的对话缓存换出到 CPU/磁盘
        """
        if len(self.cache) > 1000:  # 最多保留 1000 个对话
            # LRU 淘汰
            oldest = min(self.cache, key=lambda k: self.cache[k].last_accessed)
            del self.cache[oldest]
```

---

## 第18章 训练优化深度指南

### 18.1 分布式并行策略

#### 数据并行（Data Parallelism）

```
数据并行原理：

Model (完整副本)        Model (完整副本)        Model (完整副本)
    GPU 0                  GPU 1                   GPU N
      │                      │                       │
      ▼                      ▼                       ▼
  Batch 0/N             Batch 1/N               Batch (N-1)/N
      │                      │                       │
      ▼                      ▼                       ▼
   Grad 0                 Grad 1                  Grad N
      │                      │                       │
      └──────────┬───────────┴──────────┬────────────┘
                 │     AllReduce         │
                 ▼                       ▼
            平均梯度 = (Grad0 + Grad1 + ... + GradN) / N
                 │
                 ▼
            所有 GPU 更新模型
```

**AllReduce 通信模式：**

```python
# Ring AllReduce（最常用）
# N 个 GPU，每个持有梯度的一部分
# 需要 2(N-1) 步完成全局同步

# 步骤示例（4个GPU）：
# Step 1: GPU0→GPU1, GPU1→GPU2, GPU2→GPU3, GPU3→GPU0 (Scatter-Reduce)
# Step 2: GPU0→GPU1, GPU1→GPU2, GPU2→GPU3, GPU3→GPU0
# Step 3: GPU0→GPU1, GPU1→GPU2, GPU2→GPU3, GPU3→GPU0
# ...
# 最终每个GPU都有完整的平均梯度

# 通信量分析：
# 总通信量 = 2(N-1)/N × 模型大小
# 当 N 很大时，通信量 ≈ 2 × 模型大小
# 即每个 GPU 需要发送和接收各一份完整的梯度
```

#### 张量并行（Tensor Parallelism）

```
张量并行原理（以 MLP 层为例）：

输入 X ──► ┌─────────────────┐
            │  Linear 1       │
            │  Y = X @ W       │
            │  W: [d, 4d]      │
            └────────┬────────┘
                     │
                     ▼
            ┌────────┴────────┐
            │                 │
        GPU 0              GPU 1
            │                 │
            ▼                 ▼
      W0: [d, 2d]      W1: [d, 2d]
            │                 │
            ▼                 ▼
          Y0 = X@W0       Y1 = X@W1
            │                 │
            └────────┬────────┘
                     │
                  AllGather
                     │
                     ▼
                  Y = [Y0, Y1]  # 拼接
                     │
                     ▼
            ┌─────────────────┐
            │  Linear 2       │
            │  W: [4d, d]      │
            │                 │
            │  按行切分        │
            │  GPU0: W[0:2d]   │
            │  GPU1: W[2d:4d]  │
            └─────────────────┘
```

#### 流水线并行（Pipeline Parallelism）

```
流水线并行原理：

GPU 0 (Layers 0-3)    GPU 1 (Layers 4-7)    GPU 2 (Layers 8-11)
      │                      │                      │
      ▼                      ▼                      ▼
  ┌────────┐            ┌────────┐            ┌────────┐
  │ Forward │  ───────►  │ Forward │  ───────►  │ Forward │
  │ Micro-batch 0      │  Micro-batch 0      │  Micro-batch 0
  └────────┘            └────────┘            └────────┘
      │                      │                      │
      ▼                      ▼                      ▼
  ┌────────┐            ┌────────┐            ┌────────┐
  │ Forward │  ───────►  │ Forward │  ───────►  │ Forward │
  │ Micro-batch 1      │  Micro-batch 1      │  Micro-batch 1
  └────────┘            └────────┘            └────────┘
      ▲                      ▲                      ▲
      │                      │                      │
  ┌────────┐            ┌────────┐            ┌────────┐
  │ Backward│  ◄───────  │ Backward│  ◄───────  │ Backward│
  └────────┘            └────────┘            └────────┘

气泡问题（Pipeline Bubble）：
 时间 ──────────────────────────────────────────►
 
 GPU0: [F0][F1][F2][F3][B0][B1][B2][B3]
 GPU1:      [F0][F1][F2][F3][B0][B1][B2][B3]
 GPU2:           [F0][F1][F2][F3][B0][B1][B2][B3]
 
 气泡 = 空闲时间（等待其他GPU）
 
 减少气泡的方法：
 1. 增加 micro-batch 数量
 2. 使用 1F1B（One Forward One Backward）调度
 3. 使用 Interleaved 调度
```

### 18.2 DeepSpeed ZeRO 详解

#### ZeRO Stage 1：优化器状态分片

```python
# 问题：Adam 优化器需要保存动量和二阶矩
# 参数：Φ
# 动量：m
# 二阶矩：v
# 总显存 = 参数 × 4（FP32参数 + FP32梯度 + 动量 + 二阶矩）

# ZeRO Stage 1：
# 每个 GPU 只保存 1/N 的优化器状态

# GPU 0: 保存 m[0:Φ/N], v[0:Φ/N]
# GPU 1: 保存 m[Φ/N:2Φ/N], v[Φ/N:2Φ/N]
# ...

# 更新流程：
# 1. AllReduce 梯度（数据并行）
# 2. 每个 GPU 更新自己负责的参数
# 3. AllGather 更新后的参数

# 显存节省：4×
```

#### ZeRO Stage 2：+ 梯度分片

```python
# 梯度也分片存储

# 前向传播：正常计算
# 反向传播：
#   计算完一层梯度后，立即 Reduce-Scatter 到对应的 GPU
#   释放本 GPU 的完整梯度

# GPU 0: 保存 grad[0:Φ/N], m[0:Φ/N], v[0:Φ/N]
# GPU 1: 保存 grad[Φ/N:2Φ/N], m[Φ/N:2Φ/N], v[Φ/N:2Φ/N]

# 显存节省：8×
```

#### ZeRO Stage 3：+ 参数分片

```python
# 参数本身也分片存储

# GPU 0: 保存 param[0:Φ/N], grad[0:Φ/N], m[0:Φ/N], v[0:Φ/N]
# ...

# 前向传播时：
# 需要 param[i:j] 时，从对应 GPU AllGather 过来
# 用完后释放

# 显存节省：与数据并行度线性相关
# 64 GPU 时，每个 GPU 显存 = 原始显存 / 64
```

#### ZeRO Infinity：NVMe 卸载

```python
# 将优化器状态卸载到 CPU 内存或 NVMe SSD

# 配置示例（ds_config.json）：
{
  "zero_optimization": {
    "stage": 3,
    "offload_optimizer": {
      "device": "nvme",  # 或 "cpu"
      "nvme_path": "/local_nvme",
      "pin_memory": true
    },
    "offload_param": {
      "device": "nvme",
      "nvme_path": "/local_nvme"
    }
  }
}

# 显存节省：可将训练扩展到单张 GPU 训练百亿参数模型
# 代价：速度降低（CPU/NVMe 通信开销）
```

### 18.3 混合精度训练数值稳定性

#### FP16 训练的问题

```python
# 问题 1：梯度下溢（Gradient Underflow）
# 小梯度在 FP16 中表示为 0
# 解决：Loss Scaling

# 问题 2：参数更新不精确
# 大参数 + 小梯度 = 更新被忽略
# 解决：FP32 主权重

# PyTorch Automatic Mixed Precision (AMP)
from torch.cuda.amp import autocast, GradScaler

scaler = GradScaler()

for data, target in dataloader:
    optimizer.zero_grad()
    
    # 前向传播使用 FP16
    with autocast():
        output = model(data)
        loss = criterion(output, target)
    
    # 反向传播使用 FP16，但梯度缩放
    scaler.scale(loss).backward()
    
    # 优化器步骤（在 FP32 中执行）
    scaler.step(optimizer)
    scaler.update()

# GradScaler 内部机制：
# 1. 初始化 loss_scale = 65536.0
# 2. 反向传播前：loss = loss × loss_scale
# 3. 反向传播后：grad = grad × loss_scale
# 4. 检查梯度是否包含 inf/nan
#    - 如果有：跳过更新，loss_scale /= 2
#    - 如果没有：正常更新，loss_scale *= 1.001（缓慢增长）
```

---

## 第19章 Profiling 工具使用指南

### 19.1 PyTorch Profiler

```python
import torch
from torch.profiler import profile, record_function, ProfilerActivity

# 基本使用
with profile(
    activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
    record_shapes=True,
    profile_memory=True,
    with_stack=True
) as prof:
    
    with record_function("model_inference"):
        output = model(input_ids)
    
    with record_function("loss_computation"):
        loss = criterion(output, targets)
    
    with record_function("backward"):
        loss.backward()

# 打印结果
print(prof.key_averages().table(sort_by="cuda_time_total", row_limit=10))

# 导出 Chrome 追踪文件
prof.export_chrome_trace("trace.json")

# 导出 Flame Graph
prof.export_stacks("stacks.txt", "self_cuda_time_total")
```

### 19.2 Nsight Systems

```bash
# 安装
sudo apt install nsight-systems-2024.1

# 基本使用
nsys profile -o report \
  --trace=cuda,nvtx,osrt \
  python train.py

# 查看报告
nsys-ui report.nsys-rep

# 关键分析指标
# 1. CUDA API 时间 vs GPU 执行时间
#    - 如果 API 时间 >> 执行时间 → CPU 瓶颈
# 2. GPU 利用率时间线
#    - 空闲间隙 → 数据加载或同步瓶颈
# 3. NVTX 标记的时间范围
#    - 可以标记自定义区域进行分析
```

### 19.3 Nsight Compute

```bash
# 内核级分析
ncu -o profile \
  --metrics sm__throughput.avg.pct_of_peak_sustained_elapsed \
  python train.py

# 关键指标
# - sm__throughput: SM 利用率
# - dram__throughput: 显存带宽利用率
# - l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum: L1 缓存命中率
# - smsp__sass_thread_inst_executed_op_fadd_pred_on.sum: FADD 指令数

ncu-ui profile.ncu-rep
```

---

## 第20章 真实案例深度剖析

### 20.1 案例：某电商平台 LLM 客服（7B 模型，RTX 4090）

#### 业务背景

- 平台日均咨询量：50 万次
- 高峰期 QPS：100
- 模型：Qwen2.5-7B-Instruct
- 硬件：2×RTX 4090

#### 初始状态

```
初始配置：
- 单卡部署，batch_size=1
- max_model_len=8192
- 无量化

性能数据：
- 平均延迟：2.5s
- P99 延迟：8s
- GPU 利用率：25%
- 吞吐量：8 t/s
- 并发处理能力：4 QPS

问题分析：
1. batch_size=1 → GPU 大部分时间空闲等待
2. 无 Prefix Caching → 相同前缀重复计算
3. 单卡 → 无法水平扩展
```

#### 优化过程

**第 1 步：启用 Continuous Batching**

```bash
# 调整参数
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --max-num-seqs 64 \           # 从 1 增加到 64
  --max-num-batched-tokens 4096  # 限制每批 token 数

效果：
- GPU 利用率：25% → 55%
- 吞吐量：8 t/s → 35 t/s
- 并发能力：4 QPS → 20 QPS
```

**第 2 步：Prefix Caching**

```bash
vllm serve ... \
  --enable-prefix-caching  # 缓存 system prompt

效果：
- 首 token 延迟：1.2s → 0.3s（复用缓存时）
- GPU 利用率：55% → 65%
```

**第 3 步：双卡部署 + 负载均衡**

```yaml
# Deployment replicas=2
# 每个副本使用 1 张 RTX 4090
# Service 做轮询负载均衡

效果：
- 总并发能力：20 QPS → 40 QPS
- 可承载高峰期流量
```

**第 4 步：INT8 量化**

```bash
vllm serve Qwen/Qwen2.5-7B-Instruct-AWQ \
  --quantization awq

效果：
- 模型加载速度提升（权重减半）
- 显存占用：16GB → 8GB
- 单卡可承载更多并发
- 吞吐量：35 t/s → 48 t/s
- GPU 利用率：65% → 78%
```

**第 5 步：动态批处理调优**

```bash
# 根据实际负载调整参数
vllm serve ... \
  --max-num-seqs 128 \
  --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.92

效果：
- GPU 利用率：78% → 90%
- 吞吐量：48 t/s → 58 t/s
```

#### 最终状态

```
优化后配置：
- 双卡 INT8，Continuous Batching
- max_num_seqs=128
- Prefix Caching 启用

性能数据：
- 平均延迟：0.8s
- P99 延迟：2s
- GPU 利用率：90%
- 吞吐量：58 t/s per GPU
- 并发处理能力：80 QPS（双卡）
- 成本降低：无需升级到 A100

总结：
优化前：25% 利用率，4 QPS
优化后：90% 利用率，80 QPS
提升：20 倍并发能力
```

### 20.2 案例：某金融公司 RAG 系统（14B 模型，A100）

#### 优化 Embedding 服务 + 推理服务混部

```
初始架构：
- Embedding 服务：单独 1×A100
- 推理服务：单独 2×A100
- 问题：Embedding 利用率 15%，推理利用率 70%

优化方案：
- 使用 HAMi vGPU 混部
- Embedding：0.3 GPU, 6GB 显存
- 推理：0.7 GPU, 28GB 显存
- 总资源不变，但利用率提升

效果：
- GPU 数量：3×A100 → 2×A100
- 成本降低：33%
```

### 20.3 案例：某大厂训练集群（256×A100）

#### 网络优化

```
初始状态：
- 256 张 A100，16 台服务器
- 使用 PCIe 进行多机通信
- 训练 GPT-3 级别模型
- MFU（Model FLOPs Utilization）：25%

问题分析：
- PCIe 带宽 32GB/s，远低于 NVLink 的 600GB/s
- AllReduce 通信占总时间的 60%

优化方案：
1. 升级为 InfiniBand 网络（200Gbps）
2. 优化 NCCL 配置
3. 使用拓扑感知调度

优化后：
- MFU：25% → 52%
- 训练速度提升 2 倍
- 同等模型训练时间减半
```

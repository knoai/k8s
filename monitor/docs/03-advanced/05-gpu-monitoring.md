# GPU 集群监控（AI Infra 方向）

> 市场 JD 高频要求："熟悉 NVIDIA DCGM/NVML 工具，能采集 GPU 底层硬件指标并进行性能分析"、"大模型推理平台监控"

---

## 1. GPU 监控的独特挑战

| 挑战 | 说明 |
|------|------|
| **多层级指标** | 硬件（温度/功耗）→ 驱动 → CUDA → 应用（推理框架） |
| **共享调度** | MIG（Multi-Instance GPU）、时间切片、vGPU |
| **通信瓶颈** | NVLink、RDMA、InfiniBand 网络监控 |
| **显存管理** | OOM 不杀死进程，而是 CUDA 报错 |
| **批处理特性** | 推理服务的动态 batching 影响延迟 |

---

## 2. GPU 指标分层

```
┌─────────────────────────────────────────────────────────────┐
│                    应用层（推理框架）                          │
│  vLLM / TensorRT-LLM / Triton / Ray Serve                   │
│  - 请求队列长度、批处理大小、生成 token 速率                  │
├─────────────────────────────────────────────────────────────┤
│                    框架层（CUDA/PyTorch）                     │
│  - CUDA Kernel 执行时间、Stream 利用率                        │
├─────────────────────────────────────────────────────────────┤
│                    驱动层（NVIDIA Driver）                    │
│  - Context 数量、Compute 利用率、显存带宽                     │
├─────────────────────────────────────────────────────────────┤
│                    硬件层（GPU 芯片）                          │
│  - 温度、功耗、SM 占用率、NVLink 带宽、ECC 错误               │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. DCGM（Data Center GPU Manager）

### 3.1 DCGM 概述

NVIDIA 官方数据中心 GPU 监控工具，提供丰富的 GPU 健康与性能指标。

**核心能力**：
- GPU 健康检查与诊断
- 细粒度性能指标采集
- 策略管理（温度阈值、功耗限制）
- 与 Prometheus/Grafana 集成

### 3.2 DCGM Exporter 部署

```yaml
# dcgm-exporter.yaml
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
      hostNetwork: true
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
          env:
            - name: DCGM_EXPORTER_LISTEN
              value: ":9400"
          ports:
            - containerPort: 9400
              name: metrics
          resources:
            limits:
              nvidia.com/gpu: "0"  # DCGM 不需要分配 GPU
          volumeMounts:
            - name: nvidia-install-dir
              mountPath: /usr/local/nvidia
      volumes:
        - name: nvidia-install-dir
          hostPath:
            path: /usr/local/nvidia
---
apiVersion: v1
kind: Service
metadata:
  name: dcgm-exporter
  namespace: monitoring
  labels:
    app: dcgm-exporter
spec:
  selector:
    app: dcgm-exporter
  ports:
    - port: 9400
      targetPort: 9400
      name: metrics
```

### 3.3 ServiceMonitor 配置

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics
```

### 3.4 核心 GPU 指标

| 指标名 | 说明 | 告警阈值建议 |
|--------|------|-------------|
| `DCGM_FI_DEV_GPU_UTIL` | GPU 计算利用率 | > 95% 持续 10min |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | 显存带宽利用率 | > 90% 持续 10min |
| `DCGM_FI_DEV_POWER_USAGE` | 功耗（瓦） | > 额定功率 90% |
| `DCGM_FI_DEV_GPU_TEMP` | GPU 温度 | > 85°C |
| `DCGM_FI_DEV_FB_USED` | 显存使用量（MB） | > 总显存 90% |
| `DCGM_FI_DEV_FB_FREE` | 显存剩余量（MB） | < 5% |
| `DCGM_FI_DEV_SM_CLOCK` | SM 时钟频率 | 降频时关注 |
| `DCGM_FI_DEV_ECC_SBE_VOL_TOTAL` | 单比特 ECC 错误 | > 0 |
| `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL` | 双比特 ECC 错误 | > 0（立即处理）|
| `DCGM_FI_DEV_XID_ERRORS` | XID 错误码 | > 0 |

### 3.5 GPU 告警规则

```yaml
groups:
  - name: gpu-alerts
    rules:
      # GPU 温度过高
      - alert: GPUHighTemperature
        expr: DCGM_FI_DEV_GPU_TEMP > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "GPU {{ $labels.gpu }} 温度过高"
          description: "当前温度: {{ $value }}°C"

      # GPU 显存不足
      - alert: GPUMemoryHigh
        expr: |
          DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.9
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "GPU {{ $labels.gpu }} 显存使用率过高"

      # ECC 双比特错误（硬件故障）
      - alert: GPUECCDoubleBitError
        expr: DCGM_FI_DEV_ECC_DBE_VOL_TOTAL > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "GPU {{ $labels.gpu }} 发生 ECC 双比特错误"
          description: "可能存在硬件故障，建议更换 GPU"

      # XID 错误
      - alert: GPUXIDError
        expr: DCGM_FI_DEV_XID_ERRORS > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "GPU {{ $labels.gpu }} 发生 XID 错误 {{ $value }}"

      # GPU 利用率低但显存高（可能存在内存泄漏）
      - alert: GPULowUtilHighMemory
        expr: |
          DCGM_FI_DEV_GPU_UTIL < 10
          and
          (DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)) > 0.8
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "GPU {{ $labels.gpu }} 利用率低但显存高"
          description: "可能存在显存泄漏"
```

---

## 4. vLLM / 大模型推理监控

### 4.1 vLLM 内置指标

vLLM 原生支持 Prometheus 指标导出：

| 指标 | 说明 |
|------|------|
| `vllm:gpu_cache_usage_perc` | KV Cache 使用率 |
| `vllm:num_requests_running` | 正在执行的请求数 |
| `vllm:num_requests_waiting` | 等待队列长度 |
| `vllm:prompt_tokens_total` | Prompt token 总数 |
| `vllm:generation_tokens_total` | 生成 token 总数 |
| `vllm:time_to_first_token_seconds` | TTFT（首 token 延迟）|
| `vllm:time_per_output_token_seconds` | TPOT（每个输出 token 耗时）|
| `vllm:e2e_request_latency_seconds` | 端到端请求延迟 |

### 4.2 大模型推理黄金指标

```yaml
# 大模型推理服务 SLO
groups:
  - name: llm-slo
    rules:
      # TTFT P99 < 500ms
      - record: slo:llm:ttft_p99
        expr: histogram_quantile(0.99, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))
      
      # TPOT P99 < 50ms/token
      - record: slo:llm:tpot_p99
        expr: histogram_quantile(0.99, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))
      
      # 吞吐量: tokens/s
      - record: slo:llm:throughput
        expr: sum(rate(vllm:generation_tokens_total[1m]))
      
      # KV Cache 使用率
      - record: slo:llm:kv_cache_usage
        expr: avg(vllm:gpu_cache_usage_perc)
```

### 4.3 推理服务 Grafana 面板关键图表

```
┌─────────────────────────────────────────────────────────────┐
│  请求量 (QPS)        平均延迟        错误率        GPU 利用率 │
├─────────────────────────────────────────────────────────────┤
│  TTFT 分布 (P50/P90/P99)                                    │
├─────────────────────────────────────────────────────────────┤
│  TPOT 分布 (P50/P90/P99)                                    │
├─────────────────────────────────────────────────────────────┤
│  KV Cache 使用率趋势                                         │
├─────────────────────────────────────────────────────────────┤
│  等待队列长度 + 批处理大小                                    │
├─────────────────────────────────────────────────────────────┤
│  GPU 显存使用 + 温度 + 功耗                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. RDMA / InfiniBand 网络监控

### 5.1 RDMA 监控指标

```yaml
# 使用 ibstat / perfquery 采集
- alert: RDMAHighRetryRate
  expr: rate(rdma_port_rnr_nak_retry_err_total[5m]) > 10
  labels:
    severity: warning

- alert: RDMALinkDown
  expr: rdma_port_state != 4  # 4 = Active
  labels:
    severity: critical
```

---

## 6. MIG（Multi-Instance GPU）监控

### 6.1 MIG 实例指标

```promql
# 查看 MIG 实例分配
DCGM_FI_DEV_MIG_INSTANCE_ID

# MIG 实例的显存使用
DCGM_FI_DEV_FB_USED{gpu="0", mig_instance="1"}

# MIG 实例计算利用率
DCGM_FI_DEV_GPU_UTIL{gpu="0", mig_instance="1"}
```

---

## 7. GPU 故障排查手册

### 7.1 常见 GPU 故障

| 现象 | 可能原因 | 排查命令 |
|------|----------|----------|
| GPU 利用率 100% 但吞吐低 | 显存带宽瓶颈 | `nvidia-smi dmon` |
| 训练 loss 为 NaN | 硬件 ECC 错误 / 温度过高 | `nvidia-smi -q -d ECC` |
| 多卡训练卡住 | NCCL 通信异常 / RDMA 故障 | `nvidia-smi topo -m` |
| OOM 但显存显示有余 | 内存碎片 / CUDA Cache | `pytorch: empty_cache()` |
| 推理延迟抖动 | Batch 大小变化 / 抢占 | vLLM metrics |

### 7.2 常用排查命令

```bash
# 查看 GPU 状态
nvidia-smi
nvidia-smi -q

# 实时监控
nvidia-smi dmon -s pucm
watch -n 1 nvidia-smi

# 查看进程
nvidia-smi pmon -c 10

# ECC 错误查询
nvidia-smi -q -d ECC

# GPU 拓扑
nvidia-smi topo -m

# DCGM 诊断
dcgmi diag -r 3

# 查看 MIG 配置
nvidia-smi mig -lgip
nvidia-smi mig -lgi
```

---

## 参考资源

- [NVIDIA DCGM 文档](https://developer.nvidia.com/dcgm)
- [NVIDIA Data Center GPU Metrics](https://docs.nvidia.com/datacenter/dcgm/latest/dcgm-api/dcgm-api-field-ids.html)
- [vLLM Metrics](https://docs.vllm.ai/en/latest/serving/metrics.html)
- [Ray Serve Monitoring](https://docs.ray.io/en/latest/serve/monitoring.html)

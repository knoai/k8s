# 案例研究：医疗/生命科学平台工程实践

> 医疗行业是平台工程最具挑战性的领域之一。
> HIPAA 合规、FDA 验证、基因测序的海量算力需求、医学影像的实时推理——
> 每一个需求都足以让普通平台架构崩溃。
> 本案例基于北美大型医疗系统和中国基因测序公司的真实实践整理。

---

## 第一章：医疗行业的特殊约束

### 1.1 监管合规矩阵

医疗行业的平台不是"先上线后合规"，而是"不合规不能上线"。

```
┌─────────────────┬─────────────────────────────┬────────────────────────────────────────┐
│ 法规            │ 技术要求                    │ K8s 平台实现                           │
├─────────────────┼─────────────────────────────┼────────────────────────────────────────┤
│ HIPAA (美国)    │ 访问控制、审计日志、加密    │ RBAC + OIDC、API Server 审计、KMS      │
│ GDPR (欧盟)     │ 数据最小化、被遗忘权        │ 数据分类标签、自动清理策略             │
│ FDA 21 CFR Part │ 计算机系统验证 (CSV)        │ 变更管理、配置冻结、电子签名           │
│   11            │                             │                                        │
│ 等保三级 (中国) │ 物理隔离、访问审计、容灾    │ 专有云部署、国密算法、两地三中心       │
│ GxP             │ 数据完整性 (ALCOA+)         │ 不可变存储、WORM、区块链存证           │
└─────────────────┴─────────────────────────────┴────────────────────────────────────────┘

关键数字：
  - HIPAA 审计日志保留期：6 年
  - FDA 验证文档：平均每个系统 500-2000 页
  - 等保三级测评周期：每年一次
  - GxP 数据不可篡改要求：永久
```

### 1.2 PHI（受保护健康信息）的生命周期

```
数据分类：

  Level 1 - 公开数据
    - 医院位置、科室介绍
    - 无需特殊保护
    
  Level 2 - 内部数据
    - 医生排班、设备维护记录
    - 标准访问控制即可
    
  Level 3 - 敏感数据
    - 患者姓名、联系方式
    - 需要加密 + 审计
    
  Level 4 - PHI（最高级别）
    - 诊断结果、基因序列、影像数据
    - 端到端加密、不可变审计、最小权限

K8s 实现：
  - 每个 Level 对应独立的 Namespace 隔离
  - Level 4 的 Namespace 附加 NetworkPolicy（默认拒绝所有出站）
  - 每个访问 Level 4 数据的操作记录到不可变审计日志
```

---

## 第二章：基因测序平台架构

### 2.1 测序流程与算力需求

```
完整流程：

样本采集 → DNA提取 → 测序仪(BCL) → 碱基识别(FASTQ) → 比对(BAM) → 变异检测(VCF) → 分析报告
  │                                                                           │
  │  边缘节点                │  对象存储           │  K8s 计算集群              │
  │  (Illumina/Nanopore)     │  (S3/OSS)           │  (GPU + 批量调度)          │
  │                          │                     │                            │
  耗时：数小时                耗时：分钟             耗时：数小时-数天              耗时：分钟
  数据量：TB 级原始数据        数据量：PB 级存储      CPU/GPU 密集型计算           数据量：GB 级报告

关键数字：
  - 单个人类全基因组：~300GB 原始数据（BCL）
  - 碱基识别后（FASTQ）：~100GB
  - 比对后（BAM）：~200GB
  - 变异检测后（VCF）：~1GB
  - 一个 1000 人队列研究：总数据量 ~1PB
```

### 2.2 K8s 上的基因测序流水线

```yaml
# 使用 Argo Workflows 编排的测序流水线
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: genome-analysis-
  namespace: genomics-pipeline
spec:
  serviceAccountName: argo-workflow
  volumes:
  - name: input-data
    persistentVolumeClaim:
      claimName: sequencing-data-pvc
  - name: reference-genome
    persistentVolumeClaim:
      claimName: hg38-reference-pvc
  - name: scratch
    emptyDir:
      sizeLimit: 500Gi
  
  templates:
  # Step 1: BCL to FASTQ (碱基识别，高 IO)
  - name: bcl2fastq
    container:
      image: genomics/bcl2fastq:2.20
      command: [bcl2fastq]
      args:
      - --input-dir=/data/raw
      - --output-dir=/data/fastq
      - --no-lane-splitting
      resources:
        requests:
          memory: 64Gi
          cpu: "16"
          ephemeral-storage: 200Gi
        limits:
          memory: 128Gi
          cpu: "32"
      volumeMounts:
      - name: input-data
        mountPath: /data
      - name: scratch
        mountPath: /tmp
    
  # Step 2: Alignment (BWA-MEM，计算密集型)
  - name: bwa-alignment
    inputs:
      parameters:
      - name: sample-id
    container:
      image: genomics/bwa-samtools:0.7.17
      command: [sh, -c]
      args:
      - |
        bwa mem -t 32 -R "@RG\tID:${sample-id}\tSM:${sample-id}" \
          /reference/hg38.fa \
          /data/fastq/${sample-id}_R1.fastq.gz \
          /data/fastq/${sample-id}_R2.fastq.gz \
        | samtools sort -@ 8 -m 2G -o /data/aligned/${sample-id}.bam -
        samtools index /data/aligned/${sample-id}.bam
      resources:
        requests:
          memory: 128Gi
          cpu: "32"
        limits:
          memory: 256Gi
          cpu: "64"
      volumeMounts:
      - name: input-data
        mountPath: /data
      - name: reference-genome
        mountPath: /reference
      - name: scratch
        mountPath: /tmp
    
  # Step 3: Variant Calling (GATK HaplotypeCaller，内存密集型)
  - name: gatk-variant-calling
    inputs:
      parameters:
      - name: sample-id
    container:
      image: broadinstitute/gatk:4.4.0
      command: [gatk, HaplotypeCaller]
      args:
      - -R
      - /reference/hg38.fa
      - -I
      - /data/aligned/${sample-id}.bam
      - -O
      - /data/variants/${sample-id}.g.vcf.gz
      - -ERC
      - GVCF
      resources:
        requests:
          memory: 64Gi
          cpu: "16"
        limits:
          memory: 128Gi
          cpu: "32"
      volumeMounts:
      - name: input-data
        mountPath: /data
      - name: reference-genome
        mountPath: /reference
```

### 2.3 批量调度优化（Volcano）

```
基因测序的调度挑战：

问题 1：资源碎片化
  - 集群有 100 个节点，每个节点 64C/256GB
  - BWA 任务需要 32C/128GB
  - 默认 Kubernetes Scheduler 可能将任务分散调度
  - 结果：每个节点只能跑 1 个任务，50% 资源浪费

问题 2：任务依赖
  - Step 2（Alignment）依赖 Step 1（BCL→FASTQ）完成
  - 传统 CronJob 无法表达这种 DAG 依赖

问题 3：数据本地性
  - 原始数据在 S3/OSS，下载到本地需要时间
  - 如果任务被调度到没有数据的节点，重复下载

Volcano 解决方案：
  - Gang Scheduling：一组相关任务必须同时调度，或都不调度
  - Queue + Priority：高优先级项目优先使用资源
  - Co-scheduling：将数据下载和计算任务调度到同一节点
```

```yaml
# Volcano Job 示例
apiVersion: batch.volcano.sh/v1alpha1
kind: Job
metadata:
  name: genome-batch-001
  namespace: genomics-pipeline
spec:
  schedulerName: volcano
  minAvailable: 3  # 3 个任务必须同时启动
  queue: genomics-queue
  priorityClassName: high-priority
  tasks:
  - name: bcl2fastq
    template:
      spec:
        containers:
        - name: bcl2fastq
          image: genomics/bcl2fastq:2.20
          resources:
            requests:
              memory: 64Gi
              cpu: "16"
        restartPolicy: Never
  - name: bwa-alignment
    depends:
      iteration: 0
      name: bcl2fastq  # 依赖 bcl2fastq 完成
    template:
      spec:
        containers:
        - name: bwa
          image: genomics/bwa-samtools:0.7.17
          resources:
            requests:
              memory: 128Gi
              cpu: "32"
        restartPolicy: Never
  - name: variant-calling
    depends:
      iteration: 0
      name: bwa-alignment
    template:
      spec:
        containers:
        - name: gatk
          image: broadinstitute/gatk:4.4.0
          resources:
            requests:
              memory: 64Gi
              cpu: "16"
        restartPolicy: Never
```

---

## 第三章：HIPAA 合规的 K8s 平台实现

### 3.1 审计日志架构

```
HIPAA 要求：所有对 PHI 的访问必须被记录，且记录不可篡改。

架构设计：

API Server 审计日志
    │
    ├── 实时流 → Fluentd/Fluent Bit
    │              │
    │              ├──→ SIEM (Splunk / QRadar / 阿里云 SLS)
    │              │       └── 实时告警（异常访问模式）
    │              │
    │              ├──→ Kafka → 数据湖（S3 / OSS）
    │              │       └── 合规报告生成（月度/季度）
    │              │
    │              └──→ WORM 存储（AWS Glacier / 阿里云归档）
    │                      └── 留存 7 年（HIPAA 要求）
    │
    └── 本地保留 → 节点磁盘（7 天）
            └── 故障排查使用

K8s 审计策略配置：
  - Level: RequestResponse（记录请求体和响应体）
  - 针对含 PHI 的 Namespace：记录所有操作
  - 针对其他 Namespace：只记录元数据
  - 审计日志文件：/var/log/audit/audit.log
  - 轮转策略：每日轮转，保留 30 天本地 + 7 年归档
```

```yaml
# 审计策略示例
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Level 1: 对含 PHI 的命名空间记录所有请求和响应
- level: RequestResponse
  namespaces: ["phi-research-*", "clinical-trials-*"]
  omitStages:
  - RequestReceived
  resources:
  - group: ""
    resources: ["pods", "configmaps", "secrets"]

# Level 2: 对其他命名空间只记录元数据
- level: Metadata
  omitStages:
  - RequestReceived

# 排除系统组件的高频请求
- level: None
  userGroups: ["system:serviceaccounts:kube-system"]
  resources:
  - group: ""
    resources: ["endpoints", "nodes", "pods", "services"]
```

### 3.2 PHI 命名空间隔离

```yaml
# 每个 PHI 项目独立的命名空间，默认拒绝所有出站
apiVersion: v1
kind: Namespace
metadata:
  name: phi-research-project-001
  labels:
    data-classification: phi
    hipaa-compliant: "true"
    project-id: "PRJ-2024-001"
    irb-approval: "IRB-2024-12345"
---
# 默认拒绝所有入站和出站
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: phi-default-deny-all
  namespace: phi-research-project-001
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# 允许访问对象存储（用于上传/下载数据）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: phi-allow-object-storage
  namespace: phi-research-project-001
spec:
  podSelector:
    matchLabels:
      app: data-uploader
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: object-storage-gateway
    ports:
    - protocol: TCP
      port: 443
  - to:  # DNS
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
---
# 允许监控（只读）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: phi-allow-monitoring
  namespace: phi-research-project-001
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 9090  # metrics
```

### 3.3 镜像签名验证

```yaml
# 使用 Kyverno 验证镜像签名（Cosign）
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
  - name: verify-genomics-images
    match:
      resources:
        kinds:
        - Pod
        namespaces:
        - "phi-*"
    verifyImages:
    - imageReferences:
      - "genomics/*"
      - "broadinstitute/*"
      attestors:
      - entries:
        - keys:
            publicKeys: |
              -----BEGIN PUBLIC KEY-----
              MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
              -----END PUBLIC KEY-----
```

---

## 第四章：医学影像 AI 推理平台

### 4.1 场景：CT 影像辅助诊断

```
业务场景：
  医院 PACS 系统 → DICOM 路由 → K8s 推理集群 → AI 模型 → 结果返回放射科医生

延迟要求：
  - 单张 CT 切片（512×512）推理 < 100ms
  - 完整 CT（300-500 张切片）批量推理 < 30s
  - 紧急病例（急诊）优先处理

模型要求：
  - 3D U-Net 分割模型
  - GPU 推理（CUDA + TensorRT）
  - 模型大小 2-5GB
  - 批处理：单样本或 4 样本 batch
```

### 4.2 GPU 推理服务部署

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ct-segmentation-model
  namespace: medical-ai
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ct-segmentation
  template:
    metadata:
      labels:
        app: ct-segmentation
    spec:
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-A100-SXM4-40GB
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: inference
        image: medical-ai/ct-segmentation:v2.1
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 9090
          name: metrics
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 32Gi
            cpu: "8"
          requests:
            nvidia.com/gpu: 1
            memory: 16Gi
            cpu: "4"
        env:
        - name: MODEL_PATH
          value: /models/ct-segmentation-v2.1.trt
        - name: BATCH_SIZE
          value: "4"
        - name: MAX_INPUT_SIZE
          value: "512"
        volumeMounts:
        - name: model-cache
          mountPath: /models
        - name: dicom-tmp
          mountPath: /tmp/dicom
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60  # 模型加载需要较长时间
          periodSeconds: 30
          timeoutSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        startupProbe:
          httpGet:
            path: /ready
            port: 8080
          failureThreshold: 30
          periodSeconds: 10
      volumes:
      - name: model-cache
        persistentVolumeClaim:
          claimName: model-cache-pvc
      - name: dicom-tmp
        emptyDir:
          sizeLimit: 50Gi
      # 模型预热：InitContainer 加载模型到 GPU 显存
      initContainers:
      - name: model-warmup
        image: medical-ai/ct-segmentation:v2.1
        command: ["python", "warmup.py"]
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 32Gi
        volumeMounts:
        - name: model-cache
          mountPath: /models
        env:
        - name: MODEL_PATH
          value: /models/ct-segmentation-v2.1.trt
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ct-segmentation-hpa
  namespace: medical-ai
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ct-segmentation-model
  minReplicas: 3
  maxReplicas: 20
  metrics:
  - type: Pods
    pods:
      metric:
        name: gpu_utilization
      target:
        type: AverageValue
        averageValue: "70"
  - type: External
    external:
      metric:
        name: dicom_queue_length
      target:
        type: AverageValue
        averageValue: "10"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Pods
        value: 5
        periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Pods
        value: 1
        periodSeconds: 120
```

### 4.3 边缘部署（医院本地机房）

```yaml
# 医院机房部署边缘 K8s 节点
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-inference
  namespace: hospital-edge
spec:
  replicas: 1
  template:
    spec:
      nodeSelector:
        location: hospital-edge
      tolerations:
      - key: "edge-node"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values: [edge-inference]
              topologyKey: kubernetes.io/hostname
      containers:
      - name: inference
        image: medical-ai/ct-segmentation:v2.1-trt
        # TensorRT 优化版本，模型更小、推理更快
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 16Gi
          requests:
            nvidia.com/gpu: 1
            memory: 8Gi
        env:
        - name: INFERENCE_MODE
          value: "edge"  # 边缘模式：减少内存占用
        - name: OFFLINE_MODE
          value: "true"  # 不依赖云端
```

---

## 第五章：数据生命周期管理

### 5.1 自动化数据分层

```
基因数据的存储成本：
  - 原始数据（BCL）：保留 90 天，然后归档
  - FASTQ：保留 1 年，然后冷存
  - BAM：保留 7 年（研究需要）
  - VCF：永久保留
  - 分析报告：永久保留

自动化策略（使用 S3 Lifecycle + Crossplane）：

apiVersion: s3.aws.upbound.io/v1beta1
kind: BucketLifecycleConfiguration
metadata:
  name: genomics-data-lifecycle
spec:
  forProvider:
    bucketRef:
      name: genomics-raw-data-bucket
    rule:
    - id: bcl-transition
      status: Enabled
      filter:
        prefix: "bcl/"
      transition:
      - days: 30
        storageClass: STANDARD_IA
      - days: 90
        storageClass: GLACIER
      expiration:
        days: 365
    - id: bam-transition
      status: Enabled
      filter:
        prefix: "bam/"
      transition:
      - days: 90
        storageClass: STANDARD_IA
      - days: 365
        storageClass: GLACIER
      # 不设置 expiration，永久保留
```

---

## 第六章：面试核心考点

```
Q: 医疗行业的 K8s 平台与普通互联网平台最大的三个区别？

A:
   1. 合规是第一优先级：
      - HIPAA/GDPR/等保的要求必须在设计阶段就满足
      - 审计日志必须不可篡改，留存 6-7 年
      - 任何变更都需要可追溯的电子签名
   
   2. 算力需求巨大且不均衡：
      - 基因测序需要批量调度（Volcano），不是标准 Deployment
      - 单次任务可能需要 128GB 内存、32 核 CPU
      - 高峰期（样本送达后）算力需求是平时的 10 倍
   
   3. 数据分级和安全隔离：
      - PHI 数据必须在独立命名空间，默认拒绝所有网络访问
      - 镜像必须签名验证
      - 任何对 PHI 的访问都必须记录审计日志

Q: 如何在 K8s 中实现 HIPAA 审计要求？

A:
   1. API Server 审计日志：
      - 开启 --audit-log-path 和 --audit-policy-file
      - 对含 PHI 的 Namespace 使用 RequestResponse 级别
   
   2. 日志不可篡改：
      - 实时流式传输到 WORM 存储
      - 使用区块链或数字签名保证完整性
   
   3. 访问控制：
      - RBAC 最小权限原则
      - 定期审计 RBAC 规则（每季度）
      - 使用 OIDC + MFA 认证
   
   4. 网络隔离：
      - PHI Namespace 默认 deny-all
      - 只允许访问特定的分析服务和对象存储

Q: 基因测序平台为什么需要 Volcano 而不是默认 Scheduler？

A:
   默认 Kubernetes Scheduler 的问题：
   1. 不支持 Gang Scheduling：BWA 任务需要 32C/128GB，
      如果集群只剩 20C/100GB，默认调度器会部分调度，
      导致任务卡住
   2. 不支持任务依赖：Step 2 必须在 Step 1 完成后启动
   3. 不支持数据本地性：无法将计算任务调度到已有数据的节点
   
   Volcano 的优势：
   1. Gang Scheduling：一组任务要么全部调度，要么都不调度
   2. Queue + Priority：不同项目/样本可以排队
   3. Co-scheduling：数据下载和计算可以绑定到同一节点
   4. 支持多种调度策略（FIFO、Fair Sharing、Priority）
```

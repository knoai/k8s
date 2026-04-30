# 案例研究：Serverless 平台工程实践

> Serverless 不是"没有服务器"，而是"服务器不可见"。
> 本案例分析如何在企业环境中构建 Serverless 平台，
> 涵盖 Knative、OpenFunction、FaaS 架构和冷启动优化。

---

## 第一章：Serverless 的本质

### 1.1 什么是 Serverless？

```
Serverless 的核心特征：

1. 无服务器管理
   - 开发者不需要管理服务器
   - 平台自动分配和回收资源
   - 例：写一段代码，平台自动部署到容器中

2. 按需付费
   - 按请求次数和计算时间计费
   - 不使用时费用为 0
   - 例：函数每月被调用 100 万次，费用 $0.20

3. 自动伸缩
   - 从 0 到无限
   - 请求来时自动创建实例
   - 请求结束后自动销毁实例

4. 事件驱动
   - 函数由事件触发
   - HTTP 请求、消息队列、定时任务、文件上传
   - 例：用户上传图片 → 触发缩略图生成函数

对比：
  ┌─────────────┬─────────────┬─────────────┬─────────────┐
  │ 维度        │ 传统 VM     │ K8s         │ Serverless  │
  ├─────────────┼─────────────┼─────────────┼─────────────┤
  │ 管理成本    │ 高          │ 中          │ 低          │
  │ 伸缩速度    │ 分钟        │ 秒-分钟     │ 毫秒-秒     │
  │ 计费粒度    │ 小时        │ 秒          │ 毫秒        │
  │ 冷启动      │ 无          │ 秒          │ 毫秒-秒     │
  │ 适用场景    │ 长时运行    │ 通用        │ 短时任务    │
  └─────────────┴─────────────┴─────────────┴─────────────┘
```

### 1.2 Serverless 的两种形态

```
BaaS（Backend as a Service）：
  - 使用云厂商提供的后端服务
  - 数据库（Firebase、DynamoDB）
  - 认证（Auth0、Cognito）
  - 存储（S3、Cloud Storage）
  - 开发者只需写前端代码

FaaS（Function as a Service）：
  - 将业务逻辑写成函数
  - 上传到平台
  - 由事件触发执行
  - 例：AWS Lambda、阿里云函数计算、Knative

企业级 Serverless 平台：
  - 基于 K8s 构建
  - 使用 Knative 或 OpenFunction
  - 支持私有云部署
  - 满足安全和合规要求
```

---

## 第二章：Knative 架构与实践

### 2.1 Knative 核心组件

```
Knative 架构：

┌────────────────────────────────────────────────────────────────────┐
│                         Knative Serving                            │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐ │
│  │ Service     │  │ Route       │  │ Revision                    │ │
│  │ (服务定义)   │  │ (流量路由)   │  │ (版本管理)                   │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘ │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Configuration → Revision → Deployment → Pod (Autoscaler)   │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│                         Knative Eventing                           │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐ │
│  │ Source      │  │ Broker      │  │ Trigger                     │ │
│  │ (事件源)     │  │ (事件总线)   │  │ (事件触发器)                 │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘ │
│                                                                      │
│  事件源：GitHub、Kafka、S3、定时任务、HTTP                            │
│  事件处理：事件 → Broker → Trigger → Service                         │
└────────────────────────────────────────────────────────────────────┘

核心优势：
  1. 基于 K8s，兼容现有基础设施
  2. 自动伸缩到 0（Scale to Zero）
  3. 蓝绿部署和金丝雀发布
  4. 支持私有云部署
```

### 2.2 Knative Service 示例

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: hello-function
  namespace: default
spec:
  template:
    metadata:
      annotations:
        # 自动伸缩配置
        autoscaling.knative.dev/minScale: "0"    # 最小 0 实例
        autoscaling.knative.dev/maxScale: "100"  # 最大 100 实例
        autoscaling.knative.dev/targetBurstCapacity: "80"
        autoscaling.knative.dev/targetUtilizationPercentage: "70"
        # 冷启动并发
        autoscaling.knative.dev/window: "60s"
    spec:
      containerConcurrency: 100  # 每个容器最多 100 并发
      timeoutSeconds: 300        # 超时 5 分钟
      containers:
      - image: gcr.io/knative-samples/helloworld-go
        ports:
        - containerPort: 8080
        env:
        - name: TARGET
          value: "World"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
```

### 2.3 自动伸缩原理

```
Knative Autoscaler 工作流程：

1. 请求到达
   → Activator 接收请求
   → 检查当前 Pod 数量
   
2. 如果 Pod 数为 0（Scale to Zero）
   → Activator 缓冲请求
   → 通知 Autoscaler
   → Autoscaler 创建 Pod
   → Pod Ready 后，Activator 转发请求
   
3. 如果并发超过阈值
   → Autoscaler 计算需要的 Pod 数
   → 公式：desiredPods = ceil(observedConcurrency / targetConcurrency)
   → 例：observed=500, target=100 → desired=5
   → 创建新的 Pod
   
4. 请求减少
   → Autoscaler 定期检查（默认 2 秒）
   → 如果并发低于阈值，减少 Pod
   → 最终可以缩容到 0

关键指标：
  - 稳定请求数：concurrency = 请求数 / Pod 数
  - 每秒请求数（RPS）：作为备选指标
  - 自定义指标：CPU、内存、队列长度
```

---

## 第三章：冷启动优化

### 3.1 冷启动的组成

```
冷启动时间分解（Scale from 0）：

1. 调度延迟：100-500ms
   - K8s Scheduler 选择节点
   - 如果需要新节点：+30-60 秒（Cluster Autoscaler）
   
2. 镜像拉取：1-30 秒
   - 小镜像（< 100MB）：1-3 秒
   - 大镜像（> 1GB）：10-30 秒
   
3. 容器启动：100-500ms
   - 创建容器
   - 启动进程
   
4. 应用初始化：100ms-10 秒
   - 加载配置
   - 建立数据库连接池
   - 加载模型（AI 应用）
   
总计：2 秒 - 60 秒

优化目标：< 1 秒（对用户体验敏感的函数）
```

### 3.2 冷启动优化策略

```
策略 1：镜像优化
  - 使用多阶段构建，减小镜像大小
  - 使用 distroless 或 alpine 基础镜像
  - 镜像 < 100MB：拉取时间 < 3 秒

策略 2：预热池（Pool Warmers）
  - 保持一定数量的"预热" Pod
  - 请求来时从预热池分配
  - 用完回收回预热池
  - 成本 vs 延迟的权衡

策略 3：Snapshot/Checkpoint
  - 应用初始化后创建快照
  - 下次启动从快照恢复
  - 例：CRIU（Checkpoint/Restore in Userspace）

策略 4：常驻实例（Min Instances）
  - 设置 minScale=1 或更高
  - 避免缩容到 0
  - 适用于高频调用的函数

策略 5：节点选择
  - 使用 NodeAffinity 将函数调度到已有节点的节点
  - 避免触发 Cluster Autoscaler
```

### 3.3 预热池实现

```yaml
# 使用 Knative 的 minScale 保持预热实例
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: api-function
  namespace: default
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "3"  # 始终保持 3 个实例
        autoscaling.knative.dev/maxScale: "50"
    spec:
      containers:
      - image: my-api-function:v1.0
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
```

---

## 第四章：企业级 Serverless 平台

### 4.1 平台架构

```
企业级 Serverless 平台（基于 K8s + Knative）：

开发者 Portal
    │
    ├── 函数编写（Web IDE / VS Code 插件）
    ├── 函数部署（Git 推送触发）
    ├── 函数监控（调用次数、延迟、错误率）
    └── 函数日志（实时查看）
          │
          ▼
    ┌─────────────────────────────────────────────────────────────┐
    │                    平台控制平面                              │
    │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
    │  │ Function    │  │ Build       │  │ Registry            │  │
    │  │ Manager     │  │ Pipeline    │  │ (Harbor/ACR)        │  │
    │  └─────────────┘  └─────────────┘  └─────────────────────┘  │
    └─────────────────────────────────────────────────────────────┘
          │
          ▼
    ┌─────────────────────────────────────────────────────────────┐
    │                    Knative on K8s                            │
    │  - Serving（自动伸缩）                                       │
    │  - Eventing（事件驱动）                                      │
    │  - Autoscaler（弹性调度）                                    │
    └─────────────────────────────────────────────────────────────┘
          │
          ▼
    ┌─────────────────────────────────────────────────────────────┐
    │                    基础设施层                                │
    │  - K8s 集群（多可用区）                                      │
    │  - Ceph/MinIO（对象存储）                                    │
    │  - Kafka（消息队列）                                         │
    │  - PostgreSQL（元数据存储）                                  │
    └─────────────────────────────────────────────────────────────┘
```

### 4.2 安全与隔离

```yaml
# 函数级别的安全隔离
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: user-function
  namespace: tenant-a
spec:
  template:
    spec:
      containers:
      - image: user-function:v1.0
        securityContext:
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
      # 网络隔离
      serviceAccountName: function-sa
      # 使用 NetworkPolicy 限制函数的网络访问
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: function-isolation
  namespace: tenant-a
spec:
  podSelector:
    matchLabels:
      serving.knative.dev/service: user-function
  policyTypes:
  - Egress
  egress:
  # 只允许访问数据库和 Kafka
  - to:
    - namespaceSelector:
        matchLabels:
          name: database
    ports:
    - protocol: TCP
      port: 5432
  - to:
    - namespaceSelector:
        matchLabels:
          name: kafka
    ports:
    - protocol: TCP
      port: 9092
```

---

## 第五章：面试核心考点

```
Q: Serverless 和传统 K8s 部署有什么区别？

A:
   传统 K8s（Deployment）：
   - 需要预先定义副本数
   - 资源持续占用（即使无请求）
   - 适合长时运行的服务
   
   Serverless（Knative）：
   - 按请求自动伸缩
   - 可以缩容到 0（无请求时无成本）
   - 适合事件驱动的短时任务
   - 有冷启动延迟

Q: 冷启动如何优化？

A:
   1. 镜像优化：减小镜像大小，使用 alpine/distroless
   2. 预热池：保持 minScale > 0 的实例
   3. 应用优化：减少初始化时间
   4. 节点优化：预置节点，避免触发 Cluster Autoscaler
   5. 快照恢复：使用 CRIU 等技术
   
   权衡：
   - minScale=0：成本最低，但冷启动 2-60 秒
   - minScale=3：成本中等，冷启动 < 100ms
   - minScale=10：成本高，但无冷启动

Q: 什么场景不适合 Serverless？

A:
   1. 长时运行的任务（> 15 分钟）
      - 超时限制
      - 成本可能高于常驻实例
      
   2. 需要持久连接的场景
      - WebSocket
      - 长轮询
      - Knative 默认不支持（需要配置）
      
   3. 对延迟极度敏感的场景
      - 高频交易
      - 实时游戏服务器
      - 冷启动延迟不可接受
      
   4. 需要大量本地状态的场景
      - 大型缓存
      - 本地文件系统依赖
      - Serverless 实例是无状态的
```

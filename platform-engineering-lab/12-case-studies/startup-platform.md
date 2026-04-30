# 案例研究：中小企业从 0 到 1 建设 K8s 平台

> 大多数平台工程师不是在 Netflix 或字节跳动工作，而是在 50-500 人规模的科技公司。
> 本案例基于真实的中型企业平台建设工程，提供可复制、可落地的 12 个月路线图。
> 所有数据来自匿名化的实际项目，包含踩坑记录和量化结果。

---

## 第一章：起点评估

### 1.1 假设的公司"TechFlow"

```
公司概况：
  - 规模：120 人，技术团队 40 人
  - 业务：SaaS 工具，服务 500+ 企业客户
  - 现有架构：阿里云 ECS + 手动部署
  - 技术债务：部署脚本分散在各开发者电脑，无标准化

痛点排序（按开发者调研）：
  ┌─────────────────────┬──────────┬─────────────────────────────────────┐
  │ 痛点                │ 严重度   │ 具体表现                            │
  ├─────────────────────┼──────────┼─────────────────────────────────────┤
  │ 部署慢              │ 9.2/10   │ 生产部署需要 2 小时，涉及 8 个步骤  │
  │ 环境不一致          │ 8.7/10   │ "在我本地能跑" 每周出现 3-5 次      │
  │ 故障恢复慢          │ 8.5/10   │ 平均恢复时间 4 小时                 │
  │ 新人上手难          │ 7.8/10   │ 新开发者熟悉部署流程需要 2 周       │
  │ 资源浪费            │ 6.5/10   │ 开发环境 ECS 长期运行，无人使用     │
  └─────────────────────┴──────────┴─────────────────────────────────────┘

预算约束：
  - 云平台费用：¥55,000/月（$8,000）
  - 平台团队预算：2 人
  - 月度平台工具增量预算：$500
```

### 1.2 关键决策：不自建任何基础设施

```
决策原则：
  "除非有 5+ 人全职 SRE 团队，否则不自建任何基础设施组件。"

技术选型（托管优先）：

┌─────────────────┬─────────────────────────┬─────────────────────────────┐
│ 组件            │ 选型                    │ 放弃的方案                  │
├─────────────────┼─────────────────────────┼─────────────────────────────┤
│ K8s 发行版      │ 阿里云 ACK Pro 托管版   │ 自建 Kubeadm（无运维人力）  │
│ CNI             │ Terway (ENI)            │ Calico（额外维护成本）      │
│ Ingress         │ ALB Ingress Controller  │ NGINX Ingress（需配证书）   │
│ GitOps          │ ArgoCD                  │ Flux（学习资源少）          │
│ 监控            │ Prometheus + Grafana    │ 阿里云 ARMS（费用高）       │
│ 日志            │ 阿里云 SLS              │ ELK（维护成本高）           │
│ CI/CD           │ GitHub Actions          │ Jenkins（额外维护服务器）   │
│ 镜像仓库        │ 阿里云 ACR              │ Harbor（额外维护）          │
│ Secret 管理     │ 阿里云 KMS + External   │ Vault（学习成本高）         │
│                 │   Secrets Operator      │                             │
└─────────────────┴─────────────────────────┴─────────────────────────────┘

预算分配（月度增量 $500）：
  ┌────────────────────────────┬──────────┐
  │ 项目                       │ 费用     │
  ├────────────────────────────┼──────────┤
  │ ACK Pro 版集群（3 节点）   │ $200     │
  │ Prometheus 监控存储        │ $50      │
  │ SLS 日志存储               │ $100     │
  │ ACR 镜像仓库               │ $50      │
  │ 预留/突发                  │ $100     │
  └────────────────────────────┴──────────┘
```

---

## 第二章：第 1-2 月——评估与准备

### 2.1 团队组建

```
角色分配：
  - 平台负责人（从 SRE 团队抽调，50% 时间投入平台）
    - 职责：技术选型、架构设计、向上管理
    - 背景：5 年运维经验，熟悉 K8s 和阿里云
    
  - 平台工程师（后端转岗，全职投入）
    - 职责：具体实施、文档编写、开发者支持
    - 背景：3 年后端开发经验，对 Docker 有基础了解

工作时间分配：
  ┌────────────────────────────┬──────────┐
  │ 活动                       │ 占比     │
  ├────────────────────────────┼──────────┤
  │ 学习与实验                 │ 40%      │
  │ 与开发者沟通需求           │ 30%      │
  │ 搭建平台组件               │ 20%      │
  │ 文档和培训材料             │ 10%      │
  └────────────────────────────┴──────────┘
```

### 2.2 技术选型验证

```bash
# Week 1-2：搭建实验环境
# 使用阿里云 ACK 按量付费集群（验证后删除）

# 创建实验集群
aliyun cs POST /clusters \
  --body '{
    "name": "platform-lab",
    "cluster_type": "ManagedKubernetes",
    "region_id": "cn-hangzhou",
    "vpc_id": "vpc-xxxxxx",
    "vswitch_ids": ["vsw-xxxxxx"],
    "worker_instance_types": ["ecs.g7.xlarge"],
    "num_of_nodes": 3,
    "runtime": {"name":"containerd","version":"1.6"}
  }'

# Week 3-4：验证核心流程
# 1. 部署一个简单的应用到 ACK
# 2. 配置 ALB Ingress
# 3. 配置 ArgoCD 自动同步
# 4. 配置 Prometheus 监控
# 5. 配置 SLS 日志采集

# 验证清单：
□ 应用能正常部署和访问
□ 监控能看到 CPU/内存/请求量
□ 日志能正常采集和查询
□ Git 提交后 ArgoCD 自动同步
□ 扩容和缩容正常工作
□ 故障时告警能发到钉钉
```

---

## 第三章：第 3-4 月——迁移第一个服务

### 3.1 服务选择标准

```
选择第一个迁移服务的标准：

必须满足（全部）：
  ✅ 无状态（不依赖本地存储）
  ✅ 无数据库（或数据库已在 RDS，不迁移）
  ✅ 流量低（出问题影响小）
  ✅ 负责人积极配合

加分项：
  - 有现成的 Dockerfile
  - 有健康检查端点
  - 使用环境变量配置（非配置文件）

TechFlow 的选择：内部 Admin 工具
  - 日活用户：5 人（内部使用）
  - 技术栈：Node.js + Express
  - 已有 Dockerfile
  - 负责人：平台工程师本人（ dogfooding ）
```

### 3.2 迁移过程

```bash
# Week 1：容器化
# 优化 Dockerfile（多阶段构建）
cat > Dockerfile <<'EOF'
# 构建阶段
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# 运行阶段
FROM node:18-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .
EXPOSE 3000
USER node
CMD ["node", "server.js"]
EOF

# 构建并推送镜像
docker build -t registry.cn-hangzhou.aliyuncs.com/techflow/admin-tool:v1.0.0 .
docker push registry.cn-hangzhou.aliyuncs.com/techflow/admin-tool:v1.0.0

# Week 2：编写 K8s 配置
# 先手动 kubectl apply 验证
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: admin-tool
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: admin-tool
  namespace: admin-tool
spec:
  replicas: 2
  selector:
    matchLabels:
      app: admin-tool
  template:
    metadata:
      labels:
        app: admin-tool
    spec:
      containers:
      - name: app
        image: registry.cn-hangzhou.aliyuncs.com/techflow/admin-tool:v1.0.0
        ports:
        - containerPort: 3000
        env:
        - name: NODE_ENV
          value: production
        resources:
          requests:
            memory: 128Mi
            cpu: 100m
          limits:
            memory: 256Mi
            cpu: 200m
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: admin-tool
  namespace: admin-tool
spec:
  selector:
    app: admin-tool
  ports:
  - port: 80
    targetPort: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: admin-tool
  namespace: admin-tool
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
  - host: admin.techflow.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: admin-tool
            port:
              number: 80
EOF

# Week 3：接入 ArgoCD
# 创建 Git 仓库存放配置
git init
git add k8s/
git commit -m "Add admin-tool k8s manifests"
git push origin main

# 在 ArgoCD UI 中创建 Application
# 验证自动同步：git push → ArgoCD 自动部署

# Week 4：切流
# DNS 从 ECS IP 切换到 ALB 域名
# 观察 24 小时，确认无异常后下线 ECS
```

### 3.3 踩过的坑

```
坑 1：JVM 堆内存设置过大
  问题：容器 limit 1GB，JVM Xmx 2GB → OOMKilled
  修复：使用容器感知 JVM 参数
    -XX:+UseContainerSupport
    -XX:MaxRAMPercentage=75.0
  
  实际输出：
    修改前：Pod 每 30 分钟重启一次
    修改后：Pod 连续运行 7 天无重启

坑 2：健康检查配置错误
  问题：livenessProbe 路径是 /，但应用根路径需要 2s 查询数据库
  修复：
    livenessProbe: /actuator/health/liveness（不查库）
    readinessProbe: /actuator/health/readiness（查库）
  
  实际输出：
    修改前：探针频繁失败，Pod 被反复重启
    修改后：探针成功率 99.9%

坑 3：日志丢失
  问题：应用直接写文件，Pod 重启后日志消失
  修复：应用改为写 stdout，由 SLS 采集
  
  实际输出：
    修改前：故障排查时无日志可查
    修改后：日志保留 30 天，支持关键词搜索
```

---

## 第四章：第 5-6 月——标准化与模板化

### 4.1 内部 Helm Chart

```yaml
# company-base-chart/values.yaml
# 标准化模板，所有服务使用同一套配置

image:
  repository: ""
  tag: "latest"
  pullPolicy: IfNotPresent

replicaCount: 2

resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 100m
    memory: 256Mi

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
  hosts:
    - host: "{{ .Values.name }}.techflow.io"
      paths:
        - path: /
          pathType: Prefix

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

monitoring:
  enabled: true
  serviceMonitor:
    enabled: true
    path: /actuator/prometheus

# 安全基线
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  allowPrivilegeEscalation: false

# 亲和性
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - "{{ .Values.name }}"
        topologyKey: kubernetes.io/hostname
```

### 4.2 开发者使用方式

```bash
# 每个新项目只需修改 values.yaml
cat > my-service-values.yaml <<EOF
name: my-service
image:
  repository: registry.cn-hangzhou.aliyuncs.com/techflow/my-service
  tag: v1.0.0

resources:
  limits:
    memory: 2Gi
    cpu: 2000m

ingress:
  hosts:
    - host: my-service.techflow.io
EOF

# 一键部署
helm install my-service company-base-chart -f my-service-values.yaml

# 升级
helm upgrade my-service company-base-chart -f my-service-values.yaml --set image.tag=v1.1.0
```

---

## 第五章：第 7-8 月——多环境管理

### 5.1 环境矩阵

```
┌─────────────┬──────────────┬─────────────┬─────────────────────────────────────┐
│ 环境        │ 集群         │ 配置差异    │ 用途                                │
├─────────────┼──────────────┼─────────────┼─────────────────────────────────────┤
│ dev         │ 共享 ACK     │ 1 副本，无  │ 开发自测                            │
│             │              │ HPA         │                                     │
├─────────────┼──────────────┼─────────────┼─────────────────────────────────────┤
│ staging     │ 共享 ACK     │ 1 副本，    │ 集成测试                            │
│             │              │ 模拟生产    │                                     │
├─────────────┼──────────────┼─────────────┼─────────────────────────────────────┤
│ prod        │ 独立 ACK     │ 2+ 副本，   │ 生产                                │
│             │              │ HPA，PDB    │                                     │
└─────────────┴──────────────┴─────────────┴─────────────────────────────────────┘

Git 分支策略：
  gitops-repo/
  ├── apps/
  │   ├── my-service/
  │   │   ├── base/                 # 公共配置
  │   │   │   ├── deployment.yaml
  │   │   │   ├── service.yaml
  │   │   │   └── kustomization.yaml
  │   │   ├── overlays/
  │   │   │   ├── dev/              # dev 覆盖
  │   │   │   │   ├── replica-patch.yaml
  │   │   │   │   └── kustomization.yaml
  │   │   │   ├── staging/          # staging 覆盖
  │   │   │   └── prod/             # prod 覆盖
  │   │   │       ├── replica-patch.yaml
  │   │   │       ├── hpa.yaml
  │   │   │       ├── pdb.yaml
  │   │   │       └── kustomization.yaml
```

### 5.2 ArgoCD ApplicationSet

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-service
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - env: dev
        cluster: https://kubernetes.default.svc
        namespace: dev
      - env: staging
        cluster: https://kubernetes.default.svc
        namespace: staging
      - env: prod
        cluster: https://prod-cluster.api
        namespace: prod
  template:
    metadata:
      name: 'my-service-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/techflow/gitops.git
        targetRevision: HEAD
        path: 'apps/my-service/overlays/{{env}}'
      destination:
        server: '{{cluster}}'
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: '{{env == "prod" | ternary "false" "true"}}'
```

---

## 第六章：第 9-10 月——安全与成本治理

### 6.1 安全加固

```yaml
# Kyverno 策略（逐步推行）
# 第 1 个月：Audit 模式，不拦截
# 第 2 个月：Enforce 模式

# 策略 1：禁止特权容器
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-privileged
    match:
      resources:
        kinds: [Pod]
    validate:
      message: "Privileged containers are forbidden"
      pattern:
        spec:
          containers:
          - securityContext:
              privileged: "false"

# 策略 2：强制资源限制
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-limits
    match:
      resources:
        kinds: [Deployment]
    validate:
      message: "CPU/memory limits and requests are required"
      pattern:
        spec:
          template:
            spec:
              containers:
              - resources:
                  limits:
                    memory: "?*"
                    cpu: "?*"
                  requests:
                    memory: "?*"
                    cpu: "?*"
```

### 6.2 成本优化

```bash
# Week 1：发现闲置资源
kubectl get pods --all-namespaces | grep Completed
# 删除 Completed Job

kubectl get pvc --all-namespaces | grep -v Bound
# 清理未绑定 PVC

# Week 2：VPA 推荐调整
# 部署 Goldilocks，获取资源推荐
kubectl apply -f https://raw.githubusercontent.com/FairwindsOps/goldilocks/master/manifests/dashboard/install.yaml

# Week 3：Spot 实例引入
# 非核心服务使用 Spot 节点
nodeSelector:
  karpenter.sh/capacity-type: spot

# 月度效果：云成本从 $8,000 降到 $5,500
```

---

## 第七章：第 11-12 月——平台产品化

### 7.1 开发者体验度量

```
┌────────────────────────┬──────────┬──────────┐
│ 指标                   │ 年初     │ 年末     │
├────────────────────────┼──────────┼──────────┤
│ 新服务上线时间         │ 2 周     │ 2 小时   │
│ 部署频率               │ 每周 1 次│ 每天 10+ │
│ 故障恢复时间（MTTR）   │ 4 小时   │ 15 分钟  │
│ 开发者满意度           │ 3.5/5    │ 4.5/5    │
│ 生产事故数             │ 8/季度   │ 1/季度   │
│ 云成本                 │ $8,000   │ $5,500   │
└────────────────────────┴──────────┴──────────┘
```

### 7.2 建立开发者门户（Backstage）

```yaml
# 服务模板
# 开发者在 Backstage 点击"创建服务"
# 自动生成：Git 仓库 + CI/CD + K8s 配置 + 监控 + 文档

# 2 个月后采用率 80%
```

---

## 第八章：关键决策回顾

### 做得对的事 ✅

```
1. 不自建 K8s
   - 托管 ACK 省下的运维人力，投入平台工具开发
   - 平台团队 2 人就能支撑 40 人开发团队

2. 从小开始
   - 只迁移一个服务，验证完整流程后再推广
   - 避免"大爆炸式"迁移

3. 标准化先行
   - 第一个服务还没跑稳就开始写 Helm Chart
   - 后续服务迁移时间从 2 周降到 2 天

4. 度量驱动
   - 每月跟踪开发者满意度、上线时间、故障率
   - 数据说话，不是感觉
```

### 踩过的坑 ⚠️

```
1. 过早追求"完美架构"
   - 错误：第 1 个月就想做多集群联邦
   - 正确：单集群跑稳了再说
   - 教训：MVP 思维适用于平台建设的每个阶段

2. 忽视开发者培训
   - 错误：给了工具但没教怎么用
   - 正确：每两周一次 Lunch & Learn
   - 教训：平台采用率 = 功能价值 / 学习成本

3. 安全策略推行太急
   - 错误：一上来就 Enforce，导致开发者无法部署
   - 正确：先 Audit 观察 1 个月
   - 教训：安全策略的推行速度 = 开发者接受度

4. 监控不足就迁移核心服务
   - 错误：第 3 个月就迁移支付服务
   - 正确：监控覆盖率 100% 后再迁移核心链路
   - 教训：没有监控的迁移是盲飞
```

---

## 第九章：给中小企业平台工程师的建议

```
团队规模：
  - 2-3 人平台团队支撑 40 人开发团队是合理的
  - 超过 100 人开发团队才需要 5+ 人平台团队

预算占比：
  - 云成本的 5-10% 投入平台工具是合理的
  - 例：月云成本 $10,000 → 平台工具 $500-1000

技术债务：
  - 允许有 20% 的"非标准"服务
  - 强制 100% 标准会适得其反
  - 重点保证 80% 的核心服务标准化

度量指标：
  - 关注"开发者上线时间"和"故障恢复时间"
  - 不要关注"K8s 集群数量"
  - 平台的价值体现在开发效率，不是技术复杂度

向上管理：
  - 每月给 CTO 发一页纸的平台价值报告
  - 包含：节省时间、减少故障、成本优化
  - 用数字说话，不要用技术术语
```

---

## 第十章：12 个月投入产出

```
┌────────────────────┬─────────────────────────────────────┐
│ 投入               │ 产出                                │
├────────────────────┼─────────────────────────────────────┤
│ 2 人 × 12 月       │ 部署效率提升 10 倍                  │
│ = 24 人月          │ （2 周 → 2 小时）                   │
├────────────────────┼─────────────────────────────────────┤
│ $6,000 工具费用    │ MTTR 从 4h → 15min                │
├────────────────────┼─────────────────────────────────────┤
│ 3 次重大故障       │ 开发者满意度 +1.0                   │
│ （学习成本）       │ （3.5 → 4.5）                       │
├────────────────────┼─────────────────────────────────────┤
│ 无数加班           │ 生产事故 -87%                       │
│                    │ （8/季度 → 1/季度）                 │
└────────────────────┴─────────────────────────────────────┘

ROI 计算：
  - 平台团队成本：24 人月 ≈ ¥60 万
  - 开发效率提升：40 人团队 × 30% 效率提升 = 12 人月/月
  - 年化收益：12 人月/月 × 12 月 = 144 人月 ≈ ¥360 万
  - ROI：360 / 60 = 6x

结论：
  平台团队的存在，让 40 人开发团队的整体效率提升 30%。
  这不是成本，是投资。
```

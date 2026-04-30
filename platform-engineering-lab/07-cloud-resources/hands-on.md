# 云资源编排 - Crossplane 深度实操

> 云原生时代，基础设施管理不应依赖人工工单和 Terraform 本地执行。
> Crossplane 将云资源（RDS、S3、VPC 等）封装为 Kubernetes 自定义资源，
> 让开发者通过 YAML 自助申请基础设施，平台团队通过 Composition 控制资源的配置边界。

---

## 第一章：为什么需要 Crossplane？

### 1.1 传统基础设施管理的痛点

```
场景 1：开发者需要创建数据库
  传统流程：
  1. 开发者在 Jira 提交工单 "申请 MySQL 数据库"
  2. DBA 团队 2 天后回复，要求填写 15 项参数
  3. 开发者不知道实例类型、存储类型、备份策略怎么选
  4. DBA 手动在控制台创建，配置可能因人而异
  5. 开发者收到连接串，但密码 rotation 策略不清楚
  
  问题：
  - 等待时间长（平均 2-5 天）
  - 配置不一致（不同 DBA 创建的参数不同）
  - 缺乏审计（谁在什么时候改了什么）

场景 2：环境销毁后资源残留
  测试环境删除后，S3 bucket、RDS 快照、IAM 策略没有被清理
  → 月度云账单多出 30% 的 "幽灵资源"

场景 3：多云环境下的配置差异
  阿里云 RDS 的参数名和 AWS RDS 不同
  → 每个云需要独立的 Terraform 模块
  → 团队需要学习多套 API
```

### 1.2 Crossplane 的解决方案

```
核心思想：将云资源抽象为 Kubernetes 资源

开发者视角：
  只需要知道 "我要一个数据库"
  apiVersion: database.company.io/v1alpha1
  kind: PostgreSQLInstance
  spec:
    parameters:
      storageGB: 20
      version: "14"

平台团队视角：
  定义 "数据库" 应该包含什么：
  - 主实例 + 只读副本
  - 自动备份（7 天保留）
  - 监控告警
  - 加密存储
  - 网络隔离（Security Group）
  
  所有这些通过 Composition 一次性定义，
  开发者无需了解底层实现。

优势：
  1. 自助服务：开发者 5 分钟获得资源，不是 5 天
  2. 标准化：所有数据库配置一致，符合安全基线
  3. GitOps 友好：资源定义存储在 Git，ArgoCD 自动同步
  4. 生命周期管理：删除 Claim → 自动删除所有云资源
  5. 多云一致：同一个 Claim，阿里云/ AWS/ GCP 都可以满足
```

### 1.3 Crossplane 架构

```
┌────────────────────────────────────────────────────────────────────┐
│                        Developer / Platform Engineer                 │
│                          │                                          │
│              ┌───────────▼───────────┐                              │
│              │  Claim (XRC)           │  "我要一个数据库"            │
│              │  PostgreSQLInstance    │                              │
│              └───────────┬───────────┘                              │
└──────────────────────────┼─────────────────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────────────────┐
│                      Crossplane Control Plane                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │
│  │ Composite       │  │ Composition     │  │ Provider            │  │
│  │ Resource (XR)   │  │ (资源配置模板)   │  │ (云厂商驱动)         │  │
│  │                 │  │                 │  │                     │  │
│  │ XPostgreSQLInstance│               │  │ provider-aws-rds     │  │
│  └────────┬────────┘  └────────┬────────┘  └──────────┬──────────┘  │
│           │                    │                       │             │
│           │        ┌───────────▼───────────┐          │             │
│           │        │  Patch / Transform     │          │             │
│           │        │  (字段映射)            │          │             │
│           │        └───────────┬───────────┘          │             │
│           │                    │                       │             │
│  ┌────────▼────────┐  ┌────────▼────────┐  ┌─────────▼──────────┐  │
│  │ RDSInstance     │  │ DBSubnetGroup   │  │ SecurityGroup      │  │
│  │ (Managed Resource)│  │ (Managed Resource)│  │ (Managed Resource) │  │
│  └─────────────────┘  └─────────────────┘  └────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────────────┐
│                      Cloud Provider (AWS / 阿里云 / GCP)             │
│                      ┌─────────────────┐                           │
│                      │ RDS / PolarDB   │                           │
│                      │ S3 / OSS        │                           │
│                      │ VPC / VPC       │                           │
│                      └─────────────────┘                           │
└────────────────────────────────────────────────────────────────────┘

核心概念：
  - Provider：云厂商驱动（AWS Provider、阿里云 Provider）
  - Managed Resource (MR)：直接映射到云资源的 K8s 资源（如 RDSInstance）
  - Composite Resource Definition (XRD)：定义自定义资源 API（如 XPostgreSQLInstance）
  - Composition：将 XRD 映射到一组 MR 的模板
  - Claim (XRC)：开发者在命名空间中创建的资源请求
```

---

## 第二章：Crossplane 安装与配置

### 2.1 安装 Crossplane

```bash
# 创建命名空间
kubectl create namespace crossplane-system

# 安装 Crossplane（Helm）
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --set replicas=2 \
  --set resourcesCrossplane.requests.cpu=100m \
  --set resourcesCrossplane.requests.memory=256Mi \
  --set resourcesCrossplane.limits.cpu=1000m \
  --set resourcesCrossplane.limits.memory=1Gi

# 等待就绪
kubectl wait --for=condition=ready pod -l app=crossplane -n crossplane-system --timeout=120s

# 验证安装
kubectl get pods -n crossplane-system
# NAME                                       READY   STATUS    RESTARTS   AGE
# crossplane-xxx                             1/1     Running   0          2m
# crossplane-yyy                             1/1     Running   0          2m
# crossplane-rbac-manager-zzz                1/1     Running   0          2m

# 安装 Crossplane CLI（kubectl 插件）
curl -sL https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh | sh
sudo mv crossplane /usr/local/bin/

# 验证 CLI
crossplane version
# Client Version: 1.14.x
# Server Version: 1.14.x
```

### 2.2 安装云厂商 Provider

```bash
# 安装 AWS Provider（以 AWS 为例）
cat > provider-aws.yaml <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v1.0.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v1.0.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-ec2
spec:
  package: xpkg.upbound.io/upbound/provider-aws-ec2:v1.0.0
EOF

kubectl apply -f provider-aws.yaml

# 等待 Provider 就绪（约 2-5 分钟，需要下载镜像）
watch kubectl get providers

# 预期输出：
# NAME                  INSTALLED   HEALTHY   PACKAGE                                           AGE
# provider-aws-ec2      True        True      xpkg.upbound.io/upbound/provider-aws-ec2:v1.0.0   3m
# provider-aws-rds      True        True      xpkg.upbound.io/upbound/provider-aws-rds:v1.0.0   3m
# provider-aws-s3       True        True      xpkg.upbound.io/upbound/provider-aws-s3:v1.0.0   3m

# 如果 HEALTHY 为 False，查看原因：
kubectl describe provider provider-aws-rds
kubectl logs -n crossplane-system deployment/crossplane | grep provider-aws-rds
```

### 2.3 配置云厂商凭证

```bash
# 方法 1：使用 AWS IAM 密钥（测试环境）
# 注意：生产环境应使用 IRSA（EKS）或 IAM Role

# 创建 Secret 存储 AWS 凭证
export AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

cat > aws-creds.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: aws-creds
  namespace: crossplane-system
stringData:
  creds: |
    [default]
    aws_access_key_id = ${AWS_ACCESS_KEY_ID}
    aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF

kubectl apply -f aws-creds.yaml

# 创建 ProviderConfig（指定使用哪个凭证）
cat > provider-config.yaml <<'EOF'
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: creds
  region: us-east-1
EOF

kubectl apply -f provider-config.yaml

# 验证 ProviderConfig
kubectl get providerconfig
# NAME      AGE
# default   10s
```

---

## 第三章：定义复合资源（XRD + Composition）

### 3.1 场景：定义 "标准数据库" 抽象

平台团队决定：开发者的 "标准数据库" 应该自动包含：
- RDS PostgreSQL 实例（指定版本）
- 数据库子网组
- 安全组（只允许应用命名空间访问）
- 自动备份（7 天保留）
- 加密存储

### 3.2 创建 XRD（Composite Resource Definition）

```bash
cat > xrd-postgresql.yaml <<'EOF'
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.company.io
spec:
  group: database.company.io
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  versions:
  - name: v1alpha1
    served: true
    referenceable: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              parameters:
                type: object
                properties:
                  region:
                    type: string
                    enum: [us-east-1, us-west-2, eu-west-1]
                    default: us-east-1
                  storageGB:
                    type: integer
                    minimum: 20
                    maximum: 1000
                    default: 20
                  version:
                    type: string
                    enum: ["13", "14", "15"]
                    default: "14"
                  instanceClass:
                    type: string
                    enum: [db.t3.micro, db.t3.small, db.t3.medium, db.r5.large]
                    default: db.t3.micro
                  backupRetentionDays:
                    type: integer
                    minimum: 7
                    maximum: 35
                    default: 7
                  multiAZ:
                    type: boolean
                    default: false
                required:
                - storageGB
                - version
            required:
            - parameters
          status:
            type: object
            properties:
              endpoint:
                type: string
              port:
                type: integer
EOF

kubectl apply -f xrd-postgresql.yaml

# 验证 XRD 创建成功
kubectl get xrd
# NAME                                       ESTABLISHED   OFFERED   AGE
# xpostgresqlinstances.database.company.io   True          True      10s

# 验证 CRD 被自动创建
kubectl get crd | grep database.company.io
# postgresqlinstances.database.company.io        2024-01-15T10:00:00Z
# xpostgresqlinstances.database.company.io       2024-01-15T10:00:00Z
```

### 3.3 创建 Composition（资源配置模板）

```bash
cat > composition-postgresql.yaml <<'EOF'
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-aws
  labels:
    provider: aws
    tier: standard
spec:
  compositeTypeRef:
    apiVersion: database.company.io/v1alpha1
    kind: XPostgreSQLInstance
  resources:
  - name: db-subnet-group
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: SubnetGroup
      spec:
        forProvider:
          description: "Subnet group for PostgreSQL"
          subnetIds:
          - subnet-0aaaaaaa
          - subnet-0bbbbbbb
        providerConfigRef:
          name: default
    patches:
    - fromFieldPath: "metadata.name"
      toFieldPath: "metadata.name"
      transforms:
      - type: string
        string:
          fmt: "%s-subnet-group"

  - name: db-security-group
    base:
      apiVersion: ec2.aws.upbound.io/v1beta1
      kind: SecurityGroup
      spec:
        forProvider:
          description: "Security group for PostgreSQL"
          vpcId: vpc-0ccccccc
          ingress:
          - fromPort: 5432
            toPort: 5432
            protocol: tcp
            cidrBlocks: ["10.0.0.0/8"]
        providerConfigRef:
          name: default
    patches:
    - fromFieldPath: "metadata.name"
      toFieldPath: "metadata.name"
      transforms:
      - type: string
        string:
          fmt: "%s-sg"

  - name: rds-instance
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: Instance
      spec:
        forProvider:
          engine: postgres
          publiclyAccessible: false
          storageEncrypted: true
          autoMinorVersionUpgrade: true
          backupRetentionPeriod: 7
          skipFinalSnapshot: true
          applyImmediately: false
        providerConfigRef:
          name: default
        writeConnectionSecretToRef:
          namespace: crossplane-system
    patches:
    # 从 XRD spec.parameters.region 映射到 RDS region
    - fromFieldPath: "spec.parameters.region"
      toFieldPath: "spec.forProvider.region"
    
    # 从 XRD spec.parameters.storageGB 映射到 allocatedStorage
    - fromFieldPath: "spec.parameters.storageGB"
      toFieldPath: "spec.forProvider.allocatedStorage"
    
    # 从 XRD spec.parameters.version 映射到 engineVersion
    - fromFieldPath: "spec.parameters.version"
      toFieldPath: "spec.forProvider.engineVersion"
    
    # 从 XRD spec.parameters.instanceClass 映射到 instanceClass
    - fromFieldPath: "spec.parameters.instanceClass"
      toFieldPath: "spec.forProvider.instanceClass"
    
    # 从 XRD spec.parameters.backupRetentionDays 映射
    - fromFieldPath: "spec.parameters.backupRetentionDays"
      toFieldPath: "spec.forProvider.backupRetentionPeriod"
    
    # 从 XRD spec.parameters.multiAZ 映射
    - fromFieldPath: "spec.parameters.multiAZ"
      toFieldPath: "spec.forProvider.multiAz"
    
    # DB subnet group 引用
    - fromFieldPath: "metadata.name"
      toFieldPath: "spec.forProvider.dbSubnetGroupName"
      transforms:
      - type: string
        string:
          fmt: "%s-subnet-group"
    
    # VPC security group 引用
    - fromFieldPath: "metadata.name"
      toFieldPath: "spec.forProvider.vpcSecurityGroupIds"
      transforms:
      - type: string
        string:
          fmt: "[%s-sg]"
    
    # 连接 Secret 名称
    - fromFieldPath: "metadata.name"
      toFieldPath: "spec.writeConnectionSecretToRef.name"
      transforms:
      - type: string
        string:
          fmt: "%s-connection"

  # 连接详情（密码等）
  connectionDetails:
  - fromConnectionSecretKey: attribute.endpoint
    name: endpoint
  - fromConnectionSecretKey: attribute.port
    name: port
  - fromConnectionSecretKey: attribute.username
    name: username
  - fromConnectionSecretKey: attribute.password
    name: password
EOF

kubectl apply -f composition-postgresql.yaml

# 验证 Composition
kubectl get composition
# NAME             AGE
# postgresql-aws   10s
```

---

## 第四章：开发者使用 Claim 申请资源

### 4.1 创建 Claim

```bash
# 开发者在自己的命名空间中创建 Claim
# 不需要了解 RDS、Subnet Group、Security Group

kubectl create namespace team-alpha

kubectl apply -f - <<EOF
apiVersion: database.company.io/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: payment-db
  namespace: team-alpha
  labels:
    team: team-alpha
    app: payment-service
spec:
  parameters:
    region: us-east-1
    storageGB: 50
    version: "14"
    instanceClass: db.t3.small
    backupRetentionDays: 14
    multiAZ: true
  compositionRef:
    name: postgresql-aws
  writeConnectionSecretToRef:
    name: payment-db-connection
EOF

# 查看 Claim 状态
kubectl get postgresqlinstance -n team-alpha
# NAME         READY   CONNECTION-SECRET         AGE
# payment-db   True    payment-db-connection     5m

# 查看底层创建的 XPostgreSQLInstance（集群级）
kubectl get xpostgresqlinstance
# NAME                     READY   COMPOSITION    AGE
# payment-db-xxxxx         True    postgresql-aws 5m

# 查看所有被创建的云资源
kubectl get managed -l crossplane.io/claim-name=payment-db
# NAME                        READY   SYNCED   EXTERNAL-NAME          AGE
# instance.rds.aws.upbound.io/payment-db-xxxxx-rds-instance    True    True     payment-db-xxxxx-rds-instance   5m
# subnetgroup.rds.aws.upbound.io/payment-db-xxxxx-subnet-group True    True     payment-db-xxxxx-subnet-group   5m
# securitygroup.ec2.aws.upbound.io/payment-db-xxxxx-sg         True    True     payment-db-xxxxx-sg             5m
```

### 4.2 使用连接 Secret

```bash
# 查看自动创建的连接 Secret
kubectl get secret payment-db-connection -n team-alpha -o yaml

# data 字段包含：
# - endpoint: RDS 终端节点
# - port: 5432
# - username: 管理员用户名
# - password: 自动生成的密码

# 在应用中引用
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: team-alpha
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
      - name: app
        image: payment-service:v1.2.3
        env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: payment-db-connection
              key: endpoint
        - name: DB_PORT
          valueFrom:
            secretKeyRef:
              name: payment-db-connection
              key: port
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: payment-db-connection
              key: username
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: payment-db-connection
              key: password
EOF
```

### 4.3 资源生命周期管理

```bash
# 开发者删除 Claim → 所有云资源自动清理
kubectl delete postgresqlinstance payment-db -n team-alpha

# 验证清理
kubectl get postgresqlinstance -n team-alpha
# No resources found

kubectl get xpostgresqlinstance | grep payment-db
# No resources found

# AWS 控制台验证：RDS 实例状态变为 "Deleting"
```

---

## 第五章：与 ArgoCD 集成

### 5.1 GitOps 管理 Crossplane 配置

```bash
# 将 Crossplane 配置纳入 GitOps 管理
# gitops-repo/
# ├── crossplane/
# │   ├── providers/           # Provider 和 ProviderConfig
# │   ├── xrds/                # XRD 定义
# │   ├── compositions/        # Composition 模板
# │   └── claims/              # 各团队的 Claim（或按团队分目录）

# 创建 ArgoCD Application
cat > crossplane-platform-app.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-platform
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: https://github.com/company/platform-gitops.git
    targetRevision: main
    path: crossplane/
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    syncOptions:
    - ServerSideApply=true
    - CreateNamespace=true
    automated:
      prune: true
      selfHeal: true
EOF

kubectl apply -f crossplane-platform-app.yaml
```

---

## 第六章：排障与面试要点

### 6.1 常见错误排查

```bash
# 错误 1：Claim 一直 Not Ready
kubectl describe postgresqlinstance payment-db -n team-alpha
# 查看 Events 和 Conditions

# 常见原因：
# - Provider 未安装或 HEALTHY=false
kubectl get providers
# - ProviderConfig 凭证错误
kubectl get providerconfig
# - Composition 字段映射错误
kubectl describe composition postgresql-aws

# 错误 2：Managed Resource SYNCED=false
kubectl describe instance.rds.aws.upbound.io <name>
# 查看 Message 字段，通常是云 API 返回的错误：
# - 配额不足
# - 参数无效
# - 权限不足

# 错误 3：Secret 未创建
# 检查 writeConnectionSecretToRef 配置
# 检查 connectionDetails 在 Composition 中是否正确映射
```

### 6.2 面试核心考点

```
Q: Crossplane 和 Terraform 有什么区别？

A:
   Terraform：
   - 命令式工具：执行 terraform apply 创建资源
   - 状态文件存储在本地或远程后端
   - 没有原生 K8s 集成
   - 适合一次性基础设施搭建
   
   Crossplane：
   - 声明式控制器：通过 YAML 定义，控制器持续调和
   - 利用 K8s etcd 作为状态存储
   - 原生 K8s 资源，支持 GitOps
   - 适合持续运营和自助服务
   
   两者关系：
   - Terraform 更适合初始环境搭建（VPC、网络拓扑）
   - Crossplane 更适合动态资源供给（数据库、缓存、队列）
   - 可以结合使用：Crossplane 调用 Terraform Provider

Q: XRD、Composition、Claim 三者是什么关系？

A:
   XRD（Composite Resource Definition）：
   - 定义自定义资源 API（类似 CRD）
   - 定义开发者可以配置哪些参数
   - 集群级资源
   
   Composition：
   - 定义 XRD 如何映射到云资源
   - 一个 XRD 可以有多个 Composition（不同云厂商）
   - 集群级资源
   
   Claim：
   - 开发者在命名空间中创建的资源请求
   - 引用 XRD 和 Composition
   - 命名空间级资源
   
   关系：
   Claim → XRD → Composition → Managed Resources → Cloud Resources

Q: 如何实现多云资源抽象？

A:
   1. 定义云无关的 XRD（如 database.company.io/PostgreSQLInstance）
   2. 为每个云创建 Composition：
      - postgresql-aws（映射到 AWS RDS）
      - postgresql-alibaba（映射到阿里云 RDS）
      - postgresql-gcp（映射到 Cloud SQL）
   3. 开发者的 Claim 不指定 Composition，由平台选择
   4. 或使用 compositionSelector 按标签选择
```

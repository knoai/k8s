# 案例研究：AWS 云原生平台工程实践

> 深入分析 AWS 自身如何使用 Kubernetes 和云原生技术构建内部平台，
> 以及 EKS、Karpenter、AWS Load Balancer Controller 等核心组件的生产实践。

---

## 第一章：AWS 平台工程概述

### 1.1 AWS 内部平台演进

```
演进时间线：

2015-2017：EC2 + 自研编排
  - 使用 EC2 实例部署应用
  - 自研的部署工具（基于 CloudFormation）
  - 挑战：部署慢、资源利用率低、扩展性差

2018-2020：ECS + EKS 双轨
  - 新服务使用 ECS（容器化起步）
  - 复杂服务迁移到 EKS（需要 K8s 生态）
  - 挑战：两套系统增加运维复杂度

2021-2023：EKS 统一
  - 统一使用 Amazon EKS
  - 内部平台团队（Platform Engineering）负责基础设施
  - 开发团队专注于业务逻辑
  - 关键成果：
    - 部署频率：从周级 → 日级 → 小时级
    - 资源利用率：从 15% → 55%
    - 故障恢复时间：从 30min → 5min

2024-至今：FinOps + AI 辅助
  - 引入 Karpenter 替代 Cluster Autoscaler
  - Spot 实例使用率 > 70%
  - AI 辅助容量规划
```

### 1.2 AWS 平台团队组织

```
Platform Engineering Team 结构：

┌──────────────────────────────────────────────────────────────┐
│  VP of Platform Engineering                                  │
├──────────────┬──────────────┬──────────────┬─────────────────┤
│ Compute      │ Networking   │ Storage      │ Security        │
│ Platform     │ Platform     │ Platform     │ Platform        │
├──────────────┼──────────────┼──────────────┼─────────────────┤
│ • EKS 管理   │ • VPC 设计   │ • EBS/EFS   │ • IAM 策略      │
│ • 节点管理   │ • 负载均衡   │ • S3 策略   │ • 密钥管理      │
│ • 自动伸缩   │ • Service Mesh│ • 备份策略  │ • 合规审计      │
│ • 成本优化   │ • 多区域网络 │ • 生命周期  │ • 零信任        │
└──────────────┴──────────────┴──────────────┴─────────────────┘

平台即产品（Platform as a Product）：
  - 内部开发者是"客户"
  - 平台有产品负责人（PM）
  - 有清晰的 SLA 和 Roadmap
  - 定期用户满意度调研
```

---

## 第二章：EKS 生产实践

### 2.1 集群架构

```
生产 EKS 集群配置：

控制平面（AWS 托管）：
  - 版本：1.28
  - 模式：Private + Public endpoint
  - 日志：API Server、Audit、Authenticator
  - 加密：KMS 加密 secrets

数据平面（Self-managed + Managed Node Groups）：
  ┌─────────────────────────────────────────────────────────────┐
  │  Managed Node Group 1：通用工作负载                         │
  │  ├─ 实例类型：m6i.xlarge (4C/16GB)                          │
  │  ├─ 数量：10-50 节点（HPA + Cluster Autoscaler）           │
  │  ├─ 操作系统：Amazon Linux 2 (EKS Optimized)                │
  │  ├─ 磁盘：100GB gp3                                         │
  │  └─ 标签：workload-type=general                             │
  ├─────────────────────────────────────────────────────────────┤
  │  Managed Node Group 2：计算密集型                           │
  │  ├─ 实例类型：c6i.2xlarge (8C/16GB)                         │
  │  ├─ 数量：5-20 节点                                         │
  │  └─ 标签：workload-type=compute                             │
  ├─────────────────────────────────────────────────────────────┤
  │  Karpenter NodePool：Spot 实例（突发负载）                  │
  │  ├─ 实例类型：多种（m6i, c6i, r6i）                         │
  │  ├─ 容量类型：Spot                                          │
  │  ├─ 数量：0-100 节点（自动）                                │
  │  └─ 标签：capacity-type=spot                                │
  ├─────────────────────────────────────────────────────────────┤
  │  Fargate：无服务器工作负载（CI/CD、Job）                    │
  │  └─ Profile：特定 namespace 自动 Fargate                    │
  └─────────────────────────────────────────────────────────────┘

网络：
  - VPC CNI：自定义子网，/20 给 Pod
  - Service：AWS Load Balancer Controller（NLB/ALB）
  - Ingress：ALB + WAF + Shield
```

### 2.2 EKS 安全加固

```bash
# 1. 控制平面日志
cat > eks-cluster-config.yaml <<'EOF'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: production
  region: us-east-1
  version: "1.28"

vpc:
  id: vpc-xxxxxxxxx
  subnets:
    private:
      us-east-1a: { id: subnet-xxxxxxxxx }
      us-east-1b: { id: subnet-yyyyyyyyy }
      us-east-1c: { id: subnet-zzzzzzzzz }

managedNodeGroups:
  - name: general
    instanceType: m6i.xlarge
    desiredCapacity: 10
    minSize: 5
    maxSize: 50
    privateNetworking: true
    ssh:
      allow: false  # 禁止 SSH，使用 SSM
    iam:
      withAddonPolicies:
        autoScaler: true
        cloudWatch: true
        albIngress: true

addons:
  - name: vpc-cni
    version: latest
    configurationValues: |
      {
        "env": {
          "ENABLE_PREFIX_DELEGATION": "true",
          "WARM_PREFIX_TARGET": "1"
        }
      }
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest

cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
    logRetentionInDays: 90
EOF

# 创建集群
eksctl create cluster -f eks-cluster-config.yaml

# 2. IAM Roles for Service Account (IRSA)
cat > irsa-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:sub": "system:serviceaccount:production:app-sa"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name app-irsa-role \
  --assume-role-policy-document file://irsa-trust-policy.json

aws iam attach-role-policy \
  --role-name app-irsa-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

# Pod 使用 ServiceAccount 自动获取 AWS 凭证
# 无需 IAM 实例角色，最小权限原则
```

### 2.3 Karpenter 生产配置

```yaml
# Karpenter NodePool（替代 Cluster Autoscaler）
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m6i.large", "m6i.xlarge", "m6i.2xlarge", "c6i.xlarge", "r6i.xlarge"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      nodeClassRef:
        name: default
      expireAfter: 720h  # 30 天后替换节点（安全更新）
      terminationGracePeriod: 30m
  limits:
    cpu: 1000
    memory: 4000Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: KarpenterNodeRole-production
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "true"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "true"
  amiSelectorTerms:
    - alias: al2@latest
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        encrypted: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required  # IMDSv2
  detailedMonitoring: true
```

---

## 第三章：AWS 负载均衡与 Ingress

### 3.1 AWS Load Balancer Controller

```yaml
# Ingress 配置（ALB + WAF + HTTPS 重定向）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: production
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/xxxxxx
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
    alb.ingress.kubernetes.io/success-codes: "200"
    alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:us-east-1:123456789012:regional/webacl/xxxxxx
    alb.ingress.kubernetes.io/shield-advanced-protection: "true"
spec:
  ingressClassName: alb
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-service
            port:
              number: 80
```

### 3.2 NLB 用于 TCP/UDP 流量

```yaml
# Service 类型 LoadBalancer（NLB）
apiVersion: v1
kind: Service
metadata:
  name: websocket-service
  namespace: production
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: tcp
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: traffic-port
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout: "5"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "3"
spec:
  type: LoadBalancer
  selector:
    app: websocket-gateway
  ports:
  - name: websocket
    port: 443
    targetPort: 8080
    protocol: TCP
  sessionAffinity: None
```

---

## 第四章：成本优化实践

### 4.1 Spot 实例策略

```
Spot 实例使用策略：

适用工作负载：
  ✅ 无状态 Web 服务
  ✅ 批处理 Job
  ✅ CI/CD Pipeline
  ✅ 开发/测试环境
  ✅ 可容忍中断的数据处理

不适用工作负载：
  ❌ 数据库主节点
  ❌ 实时交易系统
  ❌ 有状态服务（除非有完善的 checkpoint）

中断处理：
  - AWS Node Termination Handler 提前 2 分钟通知
  - Pod 优先级：关键服务使用 On-Demand
  - PDB 保证最小可用副本数

配置示例：
  Karpenter NodePool 中 capacity-type: ["spot", "on-demand"]
  Spot 权重：2（优先使用 Spot）
  On-Demand 兜底：当 Spot 不可用时自动切换

实际数据：
  - Spot 节省：70%（相比 On-Demand）
  - Spot 中断率：< 5%/月
  - 中断恢复时间：< 60 秒（Karpenter 自动替换）
```

### 4.2 Graviton (ARM) 迁移

```
迁移策略：
  阶段 1：新服务直接使用 Graviton3
  阶段 2：无状态服务逐步迁移（蓝绿部署）
  阶段 3：有状态服务评估后迁移
  阶段 4：遗留 x86 服务保持现状

兼容性检查：
  - 容器镜像是否支持 multi-arch（amd64 + arm64）
  - 第三方依赖是否有 ARM 版本
  - 性能基准测试对比

成本对比（m6i.xlarge vs m6g.xlarge）：
  ┌─────────────────┬─────────────┬─────────────┬─────────────┐
  │ 指标            │ x86 (m6i)   │ ARM (m6g)   │ 差异        │
  ├─────────────────┼─────────────┼─────────────┼─────────────┤
  │ 单价/小时       │ $0.192      │ $0.154      │ -20%        │
  │ 性能（SPECint） │ 100 (基准)  │ 110         │ +10%        │
  │ 性价比          │ 100 (基准)  │ 137         │ +37%        │
  └─────────────────┴─────────────┴─────────────┴─────────────┘
```

---

## 第五章：可观测性

### 5.1 CloudWatch Container Insights

```bash
# 启用 Container Insights
eksctl utils update-cluster-logging \
  --cluster production \
  --enable-types all \
  --approve

# 关键指标
aws cloudwatch get-metric-statistics \
  --namespace ContainerInsights \
  --metric-name pod_memory_utilization \
  --dimensions Name=ClusterName,Value=production \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --period 300 \
  --statistics Average

# Prometheus + CloudWatch Agent（自定义指标）
cat > cloudwatch-agent-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cwagent-config
  namespace: amazon-cloudwatch
data:
  cwagentconfig.json: |
    {
      "logs": {
        "metrics_collected": {
          "kubernetes": {
            "cluster_name": "production",
            "metrics_collection_interval": 60
          }
        }
      },
      "metrics": {
        "namespace": "EKS/Production",
        "metrics_collected": {
          "disk": {
            "resources": ["*"],
            "measurement": ["used_percent"]
          },
          "cpu": {
            "measurement": ["usage_idle", "usage_iowait"]
          }
        }
      }
    }
EOF
```

### 5.2 X-Ray 分布式追踪

```yaml
# X-Ray DaemonSet
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: xray-daemon
  namespace: aws-observability
spec:
  selector:
    matchLabels:
      app: xray-daemon
  template:
    spec:
      containers:
      - name: xray-daemon
        image: amazon/aws-xray-daemon
        ports:
        - containerPort: 2000
          protocol: UDP
        resources:
          limits:
            cpu: 256m
            memory: 256Mi

# 应用集成（Go SDK）
# import "github.com/aws/aws-xray-sdk-go/xray"
# xray.Configure(xray.Config{DaemonAddr: "127.0.0.1:2000"})
```

---

## 第六章：面试核心考点

```
Q: "AWS EKS 和自管 K8s 相比有什么优势和劣势？"

A:
   优势：
   1. 托管控制平面：AWS 负责 API Server、etcd 的高可用和升级
   2. 集成 AWS 生态：IAM、ALB/NLB、EBS、S3 无缝集成
   3. 安全合规：符合 SOC2、PCI-DSS、HIPAA 等
   4. 多区域：一键创建跨区域集群
   
   劣势：
   1. 成本：EKS 控制平面 $72/月/集群 + 节点费用
   2. 灵活性：部分 K8s 配置不可定制
   3. 供应商锁定：深度依赖 AWS 生态
   
   选择建议：
   - 已在 AWS 上的团队：首选 EKS
   - 多云策略：考虑 EKS Anywhere 或自管
   - 成本敏感：自管 + Spot 实例

Q: "Karpenter 相比 Cluster Autoscaler 有什么优势？"

A:
   1. 启动速度：
      - CA：2-3 分钟（需要创建 Auto Scaling Group）
      - Karpenter：20-30 秒（直接启动 EC2 实例）
   
   2. 节点选择粒度：
      - CA：节点组级别（固定实例类型）
      - Karpenter：单个实例级别（动态选择最优类型）
   
   3. 碎片化处理：
      - CA：差（节点组边界限制）
      - Karpenter：好（consolidation 自动迁移 Pod）
   
   4. Spot 支持：
      - CA：需要配置多个节点组
      - Karpenter：原生支持，自动切换容量类型
   
   5. 实际数据：
      - 节点利用率提升：35% → 65%
      - 成本节省：20-30%

Q: "AWS 上如何实现 K8s 集群的最小权限原则？"

A:
   1. IRSA（IAM Roles for Service Accounts）：
      - 每个 ServiceAccount 绑定独立的 IAM Role
      - Pod 只能访问被授权的 AWS 资源
      - 无需节点级别的 IAM 角色
   
   2. VPC CNI 的 IAM 策略：
      - 最小化 ec2:CreateNetworkInterface 权限
      - 限制到特定子网和安全组
   
   3. 节点 IAM 角色：
      - 只保留必要的权限（EC2、EBS、ECR）
      - 删除 S3、DynamoDB 等不必要的权限
   
   4. 审计：
      - CloudTrail 记录所有 API 调用
      - IAM Access Analyzer 识别过度授权
```

---

## 参考资源

```
官方文档：
  - Amazon EKS: https://docs.aws.amazon.com/eks/
  - AWS Load Balancer Controller: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
  - Karpenter: https://karpenter.sh/

AWS 博客：
  - "Best Practices for Cluster Autoscaling"
  - "EKS Security Best Practices"
  - "Optimizing EKS Costs with Karpenter"

开源项目：
  - eksctl: https://eksctl.io/
  - AWS Node Termination Handler: https://github.com/aws/aws-node-termination-handler
```

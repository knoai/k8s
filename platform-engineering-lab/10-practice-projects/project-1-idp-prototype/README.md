# 项目 1: IDP 原型构建（Internal Developer Platform Prototype）

## 项目概述

本项目是整个平台工程实验室的**入门实战项目**，目标是构建一个**最小可用的内部开发者平台（IDP）原型**。通过集成 **Backstage（开发者门户）** 和 **ArgoCD（GitOps 持续交付）**，体验平台工程的核心理念：自助服务、标准化和认知减负。

**项目定位**: 初学者友好 → 适合第一次接触平台工程概念的工程师

**预计耗时**: 10-15 分钟（全自动部署）+ 30 分钟（手动实验）

**前置知识**: Kubernetes 基础、Git 基础、Docker 基础

---

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    开发者体验层                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   Backstage  │  │   Software   │  │   TechDocs   │       │
│  │   门户 UI    │  │   Templates  │  │   技术文档   │       │
│  │  localhost   │  │  (服务模板)  │  │  (Markdown)  │       │
│  │   :30030     │  │              │  │              │       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
│         │                 │                 │                │
│         └─────────────────┼─────────────────┘                │
│                           │                                  │
│  ┌────────────────────────┴────────────────────────┐         │
│  │              GitOps 持续交付层                   │         │
│  │  ┌──────────────┐      ┌──────────────┐         │         │
│  │  │    ArgoCD    │─────→│  K8s Cluster │         │         │
│  │  │  声明式同步  │      │   (Kind)     │         │         │
│  │  │  多集群管理  │      │   3 节点     │         │         │
│  │  └──────────────┘      └──────────────┘         │         │
│  └─────────────────────────────────────────────────┘         │
│                           │                                  │
│  ┌────────────────────────┴────────────────────────┐         │
│  │              基础设施层                          │         │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │         │
│  │  │ Control  │  │ Worker-1 │  │ Worker-2 │      │         │
│  │  │  Plane   │  │ (工作)   │  │ (工作)   │      │         │
│  │  └──────────┘  └──────────┘  └──────────┘      │         │
│  └─────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

---

## 核心组件详解

### 1. Backstage（开发者门户）

**定位**: Spotify 开源的内部开发者平台框架，提供统一的服务目录、软件模板和技术文档。

**本项目中部署的功能**:
- **服务目录（Software Catalog）**: 注册和管理所有服务的元数据（owner、依赖、文档链接）
- **软件模板（Scaffolder）**: 定义标准化的服务创建流程，一键生成代码仓库 + CI 配置 + K8s 清单
- **TechDocs**: 将 Markdown 文档渲染为美观的技术文档站

**访问方式**:
```bash
# 脚本自动暴露为 NodePort
open http://localhost:30030
```

**关键配置**:
```yaml
# app-config.yaml 核心片段
app:
  baseUrl: http://localhost:30030
backend:
  baseUrl: http://localhost:30030
  listen:
    port: 7007
```

### 2. ArgoCD（GitOps 引擎）

**定位**: 声明式持续交付工具，将 Git 仓库作为系统的"唯一真理来源"。

**本项目中部署的功能**:
- **Application 管理**: 定义 K8s 资源的期望状态
- **自动同步（Auto-Sync）**: Git 变更自动同步到集群
- **健康检查**: 自动检测 Pod、Service、Ingress 的健康状态

**访问方式**:
```bash
# 脚本自动暴露为 NodePort，密码自动生成
ARGO_PORT=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
ARGO_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
echo "URL: https://localhost:$ARGO_PORT"
echo "User: admin / Pass: $ARGO_PASS"
```

### 3. Kind（本地 K8s 集群）

**定位**: 在 Docker 中运行的多节点 K8s 集群，用于本地开发和测试。

**本项目的集群规格**:
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: idp-lab
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30030  # Backstage
    hostPort: 30030
  - containerPort: 30080  # ArgoCD (via Ingress)
    hostPort: 30080
- role: worker
- role: worker
```

---

## 实验指南

### 实验 1: 部署完整环境

```bash
# 1. 进入项目目录
cd platform-engineering-lab/10-practice-projects/project-1-idp-prototype

# 2. 运行一键部署脚本
./bootstrap.sh

# 预期输出:
# ==============================================
#   IDP 原型构建 - Bootstrap
#   预计时间: 10-15 分钟
# ==============================================
# ...
# ✓ 集群创建完成
# ✓ Ingress Nginx 安装完成
# ✓ ArgoCD 安装完成
# ✓ Backstage 安装完成
# ==============================================
#   IDP 原型构建完成
```

### 实验 2: 在 ArgoCD 中创建第一个 Application

```bash
# 1. 登录 ArgoCD CLI
ARGO_PORT=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
ARGO_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
argocd login localhost:$ARGO_PORT --username admin --password $ARGO_PASS --insecure

# 2. 创建一个示例 Application
argocd app create demo-app \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace demo \
  --sync-policy automated

# 3. 查看应用状态
argocd app list
argocd app get demo-app

# 4. 验证 Pod 已创建
kubectl get pods -n demo
```

**预期结果**:
- ArgoCD UI 中显示 demo-app 为 "Healthy" + "Synced"
- demo 命名空间下创建 guestbook-ui Deployment + Service

### 实验 3: 在 Backstage 中注册组件

```bash
# 1. 准备一个 catalog-info.yaml
cat > /tmp/catalog-info.yaml << 'EOF'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: demo-service
  description: 示例微服务
  annotations:
    github.com/project-slug: my-org/demo-service
    backstage.io/techdocs-ref: dir:.
spec:
  type: service
  lifecycle: production
  owner: team-platform
  system: platform
  dependsOn:
    - resource:default/postgres-db
EOF

# 2. 将文件提交到 Git 仓库
# 3. 在 Backstage UI 中点击 "Create" → "Register Existing Component"
# 4. 输入 catalog-info.yaml 的 Raw URL
# 5. 查看组件详情页，包含依赖关系图
```

### 实验 4: 创建 Software Template（高级）

```yaml
# template.yaml - 定义一个 Node.js 服务模板
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: nodejs-service-template
  title: Node.js 微服务模板
  description: 创建一个新的 Node.js 微服务，包含 CI/CD 和 K8s 配置
spec:
  owner: team-platform
  type: service
  parameters:
    - title: 服务信息
      required:
        - name
        - owner
      properties:
        name:
          title: 服务名称
          type: string
          pattern: '^[a-z0-9-]+$'
        owner:
          title: 所属团队
          type: string
          ui:field: OwnerPicker
  steps:
    - id: fetch
      name: 获取模板
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
    - id: publish
      name: 发布到 GitHub
      action: publish:github
      input:
        repoUrl: github.com?owner=my-org&repo=${{ parameters.name }}
    - id: register
      name: 注册到目录
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
```

---

## 面试知识点

**Q: 什么是内部开发者平台（IDP）？**

A: IDP 是一层抽象，位于复杂的基础设施之上，为开发者提供自助服务能力。核心价值:
1. **自助服务**: 开发者无需提交工单即可创建服务、申请资源
2. **标准化**: 统一的技术栈、CI/CD 流程、监控规范
3. **黄金路径**: 提供经过验证的最佳实践模板，降低出错率
4. **认知减负**: 开发者只需关注业务逻辑，无需理解底层基础设施
5. **规模化**: 让 100 个团队以同样高标准交付

**Q: GitOps 的核心原则是什么？**

A: 四大原则:
1. **声明式**: 系统的期望状态存储在 Git 中（YAML/JSON），而非命令式脚本
2. **版本化**: 所有变更都有 Git 历史记录，完整审计
3. **自动同步**: 代理（如 ArgoCD、Flux）持续监控 Git 和集群的差异，自动同步
4. **一致性**: Git 是唯一的真理来源（Single Source of Truth）

优势:
- 回滚简单: `git revert` 即可回滚
- 审计完整: 谁在何时做了什么变更一目了然
- 协作友好: 使用开发者熟悉的 Git 工作流（PR、Review、Merge）
- 灾难恢复: 新集群 + Git 仓库 = 完整恢复

**Q: Backstage 的软件模板（Scaffolder）如何工作？**

A: 工作流:
1. **定义模板**: 编写 `template.yaml`，声明参数（服务名、语言、端口等）和步骤序列
2. **用户填写**: 开发者在 Backstage UI 中填写参数
3. **执行步骤**: 按顺序运行 Actions:
   - `fetch:template`: 从模板仓库拉取模板文件
   - `publish:github`: 创建 GitHub 仓库并推送代码
   - `register`: 将新组件注册到 Backstage Catalog
4. **结果产出**: 新的代码仓库 + CI 配置 + K8s manifests + Catalog 条目

**Q: 为什么用 Kind 而不是 Minikube 或云集群？**

A: 对比:

| 特性 | Kind | Minikube | 云集群 (EKS/GKE) |
|------|------|----------|-----------------|
| 启动速度 | 快（2-3 分钟） | 中（5-10 分钟） | 慢（10-15 分钟） |
| 资源占用 | 低（Docker 容器） | 中（VM 或容器） | 高（付费资源） |
| 多节点 | 原生支持 | 需配置 | 原生支持 |
| 网络 | Docker 网络，端口映射方便 | 需隧道或端口转发 | 需配置安全组 |
| CI/CD | 非常适合 | 适合 | 不适合（成本高） |
| 生产级 | 不适合 | 不适合 | 适合 |

本项目选择 Kind 的原因: 快速、轻量、多节点支持、零成本、适合教学。

**Q: IDP 和传统的运维工单系统有什么区别？**

A: 关键差异:

| 维度 | 传统工单系统 | IDP |
|------|------------|-----|
| 交互方式 | 提交工单 → 等待审批 → 人工执行 | 自助界面 → 即时生效 |
| 交付时间 | 小时/天 | 分钟 |
| 标准化 | 依赖人工检查 | 通过模板强制标准化 |
| 可扩展性 | 线性（需增加运维人员） | 亚线性（自动化处理） |
| 开发者体验 | 差（黑盒等待） | 好（透明、即时反馈） |
| 错误率 | 人工操作易出错 | 模板化减少错误 |

---

## 故障排查

**问题 1: Backstage 无法访问（localhost:30030 无响应）**

```bash
# 检查 Pod 状态
kubectl get pods -n backstage

# 检查日志
kubectl logs -n backstage -l app=backstage --tail=50

# 常见原因:
# 1. 镜像拉取失败（网络问题）
# 2. 内存不足（Kind 节点内存 < 4GB）
# 3. 端口冲突（30030 被占用）
```

**问题 2: ArgoCD 同步失败**

```bash
# 查看 Application 状态和错误信息
argocd app get demo-app

# 常见原因:
# 1. Git 仓库 URL 错误
# 2. 路径下没有 K8s manifests
# 3. 目标命名空间不存在
# 4. 权限不足（ArgoCD 没有权限创建资源）
```

**问题 3: Kind 集群启动失败**

```bash
# 检查 Docker 状态
docker info | grep -E "Memory|CPUs"

# 删除并重建集群
kind delete cluster --name idp-lab
./bootstrap.sh
```

---

## 扩展挑战

1. **集成 K8s 插件**: 配置 Backstage 的 K8s 插件，在组件页面直接查看 Pod 状态和资源使用
2. **添加 TechDocs**: 为 demo-service 编写 MkDocs 文档，在 Backstage 中渲染
3. **多环境管理**: 在 ArgoCD 中创建 dev/staging/prod 三个 Application，使用 ApplicationSet 管理
4. **自定义模板**: 创建一个 Spring Boot 服务模板，包含 Dockerfile、GitHub Actions CI、K8s Deployment
5. **集成 Prometheus**: 在 Backstage 中展示服务的监控指标（错误率、延迟）

---

## 参考资源

- [Backstage 官方文档](https://backstage.io/docs/)
- [ArgoCD 官方文档](https://argo-cd.readthedocs.io/)
- [Kind 快速入门](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [GitOps 原则](https://opengitops.dev/)
- [Platform Engineering 社区](https://platformengineering.org/)

---

*本项目是平台工程实验室系列的第一课。完成本项目后，建议继续学习 [项目 2: 延迟诊断](../project-2-latency-delta/) 和 [项目 3: 中间件性能](../project-3-middleware-perf/)。*

## 生产环境部署注意事项

### 从 Kind 到生产集群的迁移清单

**安全加固**:
- [ ] ArgoCD 使用 SSO/OIDC 认证，禁用默认 admin 账号
- [ ] Backstage 启用身份认证（GitHub/Google OAuth）
- [ ] 所有服务使用 HTTPS（Let's Encrypt 或企业证书）
- [ ] 启用 NetworkPolicy，限制 Pod 间通信
- [ ] 镜像扫描（Trivy/Snyk）集成到 CI/CD

**高可用配置**:
- [ ] Backstage: 多副本 + 数据库持久化（PostgreSQL）
- [ ] ArgoCD: HA 模式（3 个 API Server + 3 个 Redis）
- [ ] Kind → 生产 K8s（EKS/GKE/AKS）
- [ ] Ingress: 使用云负载均衡器（AWS ALB/GCP LB）

**可观测性**:
- [ ] Backstage 和 ArgoCD 接入 Prometheus 监控
- [ ] 关键指标告警（Pod 重启、同步失败、内存使用）
- [ ] 日志收集（Loki/ELK）

**备份策略**:
```bash
# ArgoCD 配置备份
argocd admin export > argocd-backup.yaml

# Backstage 数据库备份
kubectl exec -n backstage postgres-0 -- pg_dump backstage > backstage-db.sql
```

### 性能基准参考

| 指标 | 单节点 Kind | 生产（3 副本） |
|------|------------|--------------|
| Backstage 启动时间 | 30-60s | 20-30s |
| ArgoCD 同步延迟 | 5-10s | 3-5s |
| 并发 Application 数 | 50 | 500+ |
| 用户并发数 | 10 | 1000+ |

### 成本估算（月度）

**Kind 本地环境**: $0（使用本地 Docker）

**AWS 生产环境（最小规模）**:
- EKS 控制面: $72/月
- 3× m6i.xlarge 节点: $280/月
- ALB: $22/月 + LCU
- RDS PostgreSQL (db.t3.micro): $13/月
- **总计**: ~$400/月（可支持 50-100 开发者）

---

*最后更新: 2024-01-15 | 维护者: platform-engineering-lab 团队*

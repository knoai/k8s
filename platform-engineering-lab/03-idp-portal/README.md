# 03 - 开发者门户（IDP Portal）

开发者门户是平台工程的"脸面"，直接决定开发者体验（DX）和平台采用率。

---

## 3.1 门户选型

| 方案 | 类型 | 定制性 | 社区 | 适用场景 |
|------|------|--------|------|---------|
| **Backstage** | 开源框架 | 极高 | CNCF 孵化 | 有前端团队的大中型企业 |
| **Port** | 商业 SaaS | 高 | 活跃 | 快速启动，中小团队 |
| **Cortex** | 商业 | 中 | 一般 | 服务目录为主 |
| **OpsLevel** | 商业 | 中 | 一般 | 成熟企业 |
| **自研** | 定制 | 100% | 无 | 超大型企业特殊需求 |

**市场趋势**：Backstage 已成为事实标准，Spotify 开源，被 AWS、Expedia、Netflix 等采用。

---

## 3.2 Backstage 深度架构

### 核心组件

```
┌─────────────────────────────────────────────────┐
│  Frontend (React)                                │
│  ├── App 插件系统                                 │
│  ├── 服务目录 (Software Catalog)                  │
│  ├── 模板 (Scaffolder)                           │
│  ├── 技术文档 (TechDocs)                         │
│  └── 自定义插件                                   │
├─────────────────────────────────────────────────┤
│  Backend (Node.js)                               │
│  ├── Plugin 服务                                  │
│  ├── 身份认证 (Auth)                             │
│  └── 数据库 (PostgreSQL/SQLite)                  │
├─────────────────────────────────────────────────┤
│  Integrations                                    │
│  ├── GitHub/GitLab/Bitbucket                     │
│  ├── Kubernetes                                  │
│  ├── ArgoCD / PagerDuty / SonarQube             │
│  └── 自定义 API                                  │
└─────────────────────────────────────────────────┘
```

### 软件目录（Software Catalog）

Backstage 的核心是统一的服务目录，自动同步所有服务和资源。

**实体类型**：
- **Component**: 软件组件（服务、前端、库）
- **API**: 接口定义（OpenAPI, AsyncAPI, GraphQL）
- **Resource**: 基础设施资源（数据库、S3 Bucket、K8s 集群）
- **System**: 系统（多个组件的集合）
- **Domain**: 业务领域
- **User/Group**: 组织和人员

**catalog-info.yaml 示例**：
```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payment-service
  description: 支付核心服务
  annotations:
    # K8s 集成：自动显示该服务的 Pod 状态
    backstage.io/kubernetes-id: payment-service
    # ArgoCD 集成：显示部署状态
    argocd/app-name: payment-service
    # SonarQube 集成
    sonarqube.org/project-key: company_payment-service
    # Grafana 仪表盘
    grafana/dashboard-selector: "tags @> ['payment']"
  tags:
    - java
    - spring-boot
    - payments
  links:
    - url: https://payment-service.docs.company.io
      title: 技术文档
      icon: docs
    - url: https://grafana.company.io/d/payment
      title: 监控
      icon: dashboard
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: checkout
  dependsOn:
    - resource:payment-db
    - component:fraud-detection-service
  providesApis:
    - payment-api
---
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: payment-db
  annotations:
    backstage.io/kubernetes-id: payment-db
spec:
  type: database
  owner: dba-team
  system: checkout
```

### Scaffolder（软件模板）

让开发者在 UI 上填写表单，自动生成代码仓库和基础设施。

**模板定义示例**（template.yaml）：
```yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: microservice-template
  title: 标准微服务
  description: 创建一个基于 Spring Boot 的微服务，包含 CI/CD 和 K8s 配置
spec:
  owner: platform-team
  type: service

  parameters:
    - title: 基本信息
      required:
        - name
        - owner
      properties:
        name:
          title: 服务名称
          type: string
          pattern: '^[a-z0-9-]+$'
        owner:
          title: 团队
          type: string
          ui:field: OwnerPicker
        description:
          title: 描述
          type: string
        database:
          title: 需要数据库？
          type: boolean
          default: false

    - title: 部署配置
      properties:
        environment:
          title: 初始环境
          type: array
          items:
            type: string
            enum: ['dev', 'staging']
          default: ['dev']
        replicas:
          title: 副本数
          type: number
          default: 2

  steps:
    - id: fetch-base
      name: 获取模板
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
          description: ${{ parameters.description }}
          database: ${{ parameters.database }}

    - id: publish
      name: 创建 Git 仓库
      action: publish:github
      input:
        allowedHosts: ['github.com']
        description: ${{ parameters.description }}
        repoUrl: github.com?owner=company&repo=${{ parameters.name }}

    - id: register
      name: 注册到目录
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: '/catalog-info.yaml'

    - id: create-argocd-app
      name: 创建 ArgoCD 应用
      action: http:backstage:request
      input:
        method: POST
        path: /api/proxy/argocd/api/v1/applications
        headers:
          Content-Type: application/json
        body:
          metadata:
            name: ${{ parameters.name }}
          spec:
            project: default
            source:
              repoURL: ${{ steps.publish.output.remoteUrl }}
              path: k8s/overlays/dev
            destination:
              server: https://kubernetes.default.svc
              namespace: ${{ parameters.owner }}

  output:
    links:
      - title: 代码仓库
        url: ${{ steps.publish.output.remoteUrl }}
      - title: 服务目录
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
    text:
      - "✅ 服务 ${{ parameters.name }} 已创建"
      - "📦 仓库: ${{ steps.publish.output.remoteUrl }}"
      - "🚀 ArgoCD 应用已自动创建"
```

**模板骨架（skeleton/）结构**：
```
skeleton/
├── README.md
├── Dockerfile
├── src/
│   └── ...
├── .github/
│   └── workflows/
│       └── ci.yaml
└── k8s/
    ├── base/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   └── kustomization.yaml
    └── overlays/
        ├── dev/
        │   └── kustomization.yaml
        └── staging/
            └── kustomization.yaml
```

---

## 3.3 插件生态系统

### 必装插件

| 插件 | 功能 | 安装命令 |
|------|------|---------|
| **Kubernetes** | 查看 Pod/Deployment/Service 状态 | `@backstage/plugin-kubernetes` |
| **ArgoCD** | 显示部署状态和健康度 | `@backstage/plugin-argocd` |
| **SonarQube** | 代码质量看板 | `@backstage/plugin-sonarqube` |
| **TechDocs** | Markdown 文档渲染 | `@backstage/plugin-techdocs` |
| **PagerDuty** | 值班和告警集成 | `@backstage/plugin-pagerduty` |

### 自定义插件开发

当现有插件不满足需求时，平台团队需要自己开发：

```bash
# 创建新插件
yarn new --select plugin
# 命名: cost-insights

# 插件目录结构
plugins/
└── cost-insights/
    ├── src/
    │   ├── components/
    │   │   ├── CostOverviewPage/
    │   │   └── CostBreakdownCard/
    │   ├── api/
    │   │   └── CostInsightsApi.ts
    │   └── plugin.ts
    └── package.json
```

---

## 3.4 身份与权限

### 认证集成

Backstage 支持多种身份提供商：

```yaml
# app-config.yaml
auth:
  environment: production
  providers:
    github:
      production:
        clientId: ${AUTH_GITHUB_CLIENT_ID}
        clientSecret: ${AUTH_GITHUB_CLIENT_SECRET}
    oidc:
      production:
        clientId: ${AUTH_OIDC_CLIENT_ID}
        clientSecret: ${AUTH_OIDC_CLIENT_SECRET}
        metadataUrl: https://company.okta.com/.well-known/openid-configuration
    # 国内企业常用
    ldap:
      production:
        ldapOptions:
          url: ldap://ldap.company.io
```

### 权限框架（Permission Framework）

控制谁能看到什么、能执行什么操作：

```yaml
# 权限策略示例
permission:
  enabled: true
  policies:
    - allow:
        resource: catalog-entity
        action: read
        conditions:
          rule: IS_ENTITY_OWNER
          params:
            claims:
              - group:default/team-payments
    - deny:
        resource: scaffolder-template
        action: execute
        conditions:
          rule: IS_ENTITY_KIND
          params:
            kind: Template
            name: infrastructure-template
```

---

## 3.5 生产部署

### 架构模式

```
┌─────────────────────────────────────────┐
│  Ingress (HTTPS)                        │
│  ├── backstage.company.io               │
│  └── *.backstage.company.io             │
├─────────────────────────────────────────┤
│  Backstage Frontend (Next.js build)     │
│  → Static files via Nginx/CDN           │
├─────────────────────────────────────────┤
│  Backstage Backend (Node.js)            │
│  → 3+ replicas, PDB                     │
│  → 连接到 PostgreSQL                    │
├─────────────────────────────────────────┤
│  PostgreSQL (HA: Patroni / Cloud RDS)   │
│  → 定期备份                             │
└─────────────────────────────────────────┘
```

### Helm 部署

```yaml
# values.yaml
backstage:
  image:
    repository: company.registry.io/backstage
    tag: v1.2.3
  replicas: 3
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
    limits:
      memory: 2Gi
      cpu: 1000m

  appConfig:
    app:
      baseUrl: https://backstage.company.io
    backend:
      baseUrl: https://backstage.company.io
      database:
        client: pg
        connection:
          host: ${POSTGRES_HOST}
          port: 5432
          user: ${POSTGRES_USER}
          password: ${POSTGRES_PASSWORD}

  extraEnvVarsSecrets:
    - name: backstage-secrets

postgresql:
  enabled: false  # 使用外部 RDS

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: backstage.company.io
      paths:
        - path: /
          pathType: Prefix
```

---

## 3.6 替代方案：Port

如果团队没有前端资源，可考虑 Port（商业 SaaS）：

```yaml
# Port 的 Blueprint（类似 Backstage Entity）
{
  "identifier": "microservice",
  "title": "Microservice",
  "schema": {
    "properties": {
      "language": {
        "type": "string",
        "enum": ["Java", "Go", "Python", "Node.js"]
      },
      "team": {
        "type": "string"
      }
    }
  }
}
```

**Port vs Backstage 对比**：
- Port：开箱即用，SaaS 免运维，按用户收费
- Backstage：完全可控，免费，需要投入前端/Node.js 人力

---

## 最佳实践清单

- [ ] 定义标准化的 catalog-info.yaml 模板，强制所有新服务注册
- [ ] Scaffolder 模板覆盖 80% 以上的新建服务场景
- [ ] TechDocs 与代码仓库同步，文档即代码
- [ ] 集成至少 5 个关键系统（K8s/ArgoCD/监控/告警/代码质量）
- [ ] 建立平台采用率度量（DAU/MAU、模板使用次数）

## IDP 门户运营与度量

### 平台采用率度量

**关键指标（North Star Metrics）**:

| 指标 | 计算方式 | 健康阈值 | 采集方法 |
|------|---------|---------|---------|
| 日活跃开发者（DAU） | 每日登录 Backstage 的唯一用户 | > 50% 总开发者 | Backstage 访问日志 |
| 模板使用率 | 每月使用 Scaffolder 创建的服务数 / 总新建服务数 | > 80% | Backstage 数据库 |
| 自助服务完成率 | 无需平台团队介入完成的请求比例 | > 90% | 工单系统对比 |
| 门户 NPS | 开发者推荐意愿（0-10 分） | > 50 | 季度调查 |
| 平均发现时间 | 新开发者找到所需文档的时间 | < 5 分钟 | 用户测试 |

**度量仪表盘设计**:
```yaml
# 在 Backstage 中创建平台度量页面
# 使用 backstage-plugin-analytics-module-ga 或自定义 API

# 示例：模板使用统计
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: platform-metrics
  annotations:
    grafana/dashboard-url: https://grafana.internal/d/platform-adoption
    datadoghq.com/dashboard-url: https://app.datadoghq.com/dashboard/platform
```

### 开发者反馈循环

**反馈渠道矩阵**:

| 渠道 | 响应时间 | 适用场景 | 工具 |
|------|---------|---------|------|
| 实时支持 | < 1 小时 | 阻塞性问题 | Slack #platform-support |
| 工单系统 | < 4 小时 | 资源申请、权限问题 | Jira / GitHub Issues |
| 用户访谈 | 每周 | 深度需求挖掘 | Zoom / 线下 |
| 满意度调查 | 每季度 | 整体体验度量 | Typeform / SurveyMonkey |
| 使用数据 | 实时 | 行为分析 | Backstage Analytics |

**反馈处理流程**:
```
收集 → 分类 → 优先级排序 → 迭代计划 → 发布 → 通知用户 → 度量改善
  ↑___________________________________________________________|
```

### IDP 技术选型对比

| 特性 | Backstage (开源) | Port (SaaS) | Cortex (SaaS) | OpsLevel (SaaS) |
|------|-----------------|-------------|---------------|-----------------|
| 自托管 | ✅ | ❌ | ❌ | ❌ |
| 软件模板 | ✅ 强大 | ✅ 中等 | ✅ 中等 | ✅ 中等 |
| 服务目录 | ✅ 灵活 | ✅ 开箱即用 | ✅ 开箱即用 | ✅ 开箱即用 |
| K8s 集成 | ✅ 插件 | ✅ 原生 | ✅ 原生 | ✅ 原生 |
| 成本 | 免费（人力成本高） | $$$ | $$$ | $$$ |
| 定制性 | 极高 | 中 | 中 | 中 |
| 社区生态 | 极大（Spotify + CNCF） | 中 | 小 | 小 |

**选型建议**:
- **初创公司（< 50 开发者）**: Port 或 Cortex，快速启动
- **成长型公司（50-500 开发者）**: Backstage，投资回报率最高
- **大型企业（> 500 开发者）**: Backstage 或混合方案（核心自研 + Backstage 框架）

## 面试常见问题补充

**Q: Backstage 的软件目录（Software Catalog）如何保持数据新鲜？**

A: 三种机制:
1. **Git 集成**: catalog-info.yaml 提交到 Git 后自动更新（Webhook）
2. **定期刷新**: Backstage 定期轮询 Git 仓库（默认 5 分钟）
3. **API 推送**: 外部系统通过 Backstage API 直接更新实体

最佳实践:
- 将 catalog-info.yaml 放在服务代码仓库根目录
- CI/CD 中验证 YAML 格式（防止提交错误数据）
- 设置实体过期策略（3 个月无更新自动归档）

**Q: 如何衡量 IDP 的投资回报率？**

A: 定量指标:
- **时间节省**: (旧流程时间 - 新流程时间) × 使用次数 × 开发者时薪
  - 例: 创建新服务从 3 天缩短到 30 分钟
  - 每月 10 个新服务 × (3 天 - 0.5 天) × $400/天 = $10,000/月

- **故障减少**: 标准化模板减少配置错误
  - 例: 配置错误导致的故障从 5 次/月降至 1 次/月
  - 节省: 4 次 × 平均修复成本 $2,000 = $8,000/月

- **认知减负**: 开发者满意度提升 → 留存率提升
  - 例: 开发者流失率从 15% 降至 10%
  - 节省: 5 人 × 招聘成本 $50,000 = $250,000/年

定性指标:
- 开发者 NPS 提升
- 技术债务减少
- 跨团队协作效率提升


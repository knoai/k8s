# Backstage IDP 平台搭建深度指南

> Backstage 是 Spotify 开源的内部开发者平台（IDP）框架。
> 本节从安装配置到插件开发，提供完整的生产级搭建指南。

---

## 一、Backstage 架构

### 1.1 核心组件

```
Backstage 架构：

┌─────────────────────────────────────────┐
│  Backstage Frontend（React SPA）        │
│   - 插件系统（Plugin System）           │
│   - 统一导航和布局                      │
│   - 组件库（Storybook）                 │
└──────────────┬──────────────────────────┘
               │ HTTP
               ▼
┌─────────────────────────────────────────┐
│  Backstage Backend（Node.js）           │
│   - Plugin Backend                      │
│   - 数据库（PostgreSQL/SQLite）         │
│   - 认证（OAuth/OIDC/LDAP）             │
│   - 权限（Permission Framework）        │
│   - 搜索（Search Engine）               │
│   - 任务调度（Scaffolder）              │
└──────────────┬──────────────────────────┘
               │
    ┌──────────┼──────────┐
    ▼          ▼          ▼
  Catalog   Scaffolder  TechDocs
  (软件目录) (模板编排)  (文档系统)
```

### 1.2 核心概念

| 概念 | 说明 | 示例 |
|------|------|------|
| Entity | Backstage 中的基本对象 | Component、API、Resource、System、Domain |
| Component | 软件组件 | 服务、库、网站 |
| API | 接口定义 | OpenAPI、GraphQL、gRPC |
| Resource | 基础设施资源 |数据库、S3 Bucket、K8s 集群 |
| System | 系统（多个 Component 组成） | 订单系统、支付系统 |
| Domain | 业务领域 |电商、物流、金融 |
| Location | 实体定义文件的位置 | GitHub URL、文件路径 |
| Template | Scaffolder 模板 | 新建微服务、新建前端项目 |

---

## 二、安装与配置

### 2.1 初始化项目

```bash
# 安装 Backstage CLI
npx @backstage/create-app@latest
# 输入应用名称：platform-portal

# 目录结构
cd platform-portal
ls -la
# ├── app-config.yaml           # 主配置文件
# ├── app-config.production.yaml # 生产环境配置
# ├── packages/
# │   ├── app/                  # 前端应用
# │   └── backend/              # 后端应用
# ├── plugins/                  # 自定义插件
# └── catalog-info.yaml         # 本项目的实体定义

# 本地启动
yarn install
yarn dev
# 访问 http://localhost:3000
```

### 2.2 生产配置

```yaml
# app-config.production.yaml
app:
  title: Platform Engineering Portal
  baseUrl: https://platform.mycompany.com

backend:
  baseUrl: https://platform.mycompany.com
  listen:
    port: 7007
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}
  cache:
    store: redis
    connection: ${REDIS_URL}
  cors:
    origin: https://platform.mycompany.com
    methods: [GET, HEAD, PATCH, POST, PUT, DELETE]
    credentials: true

# 认证配置
auth:
  environment: production
  providers:
    github:
      production:
        clientId: ${GITHUB_CLIENT_ID}
        clientSecret: ${GITHUB_CLIENT_SECRET}
    oidc:
      production:
        metadataUrl: https://auth.mycompany.com/.well-known/openid-configuration
        clientId: ${OIDC_CLIENT_ID}
        clientSecret: ${OIDC_CLIENT_SECRET}
        tokenSignedResponseAlg: RS256
        scope: openid profile email groups

# 权限配置
permission:
  enabled: true

# 软件目录配置
catalog:
  locations:
  - type: url
    target: https://github.com/my-org/catalog/blob/main/all.yaml
    rules:
    - allow: [Component, System, API, Resource, Domain]
  processors:
    githubOrg:
      users:
        - type: url
          target: https://github.com/my-org

# Scaffolder 模板配置
scaffolder:
  allowedHosts:
    - github.com
    - gitlab.mycompany.com

# TechDocs 配置
techdocs:
  builder: external
  generator:
    runIn: docker
  publisher:
    type: awsS3
    awsS3:
      bucketName: ${TECHDOCS_S3_BUCKET}
      region: ${AWS_REGION}
      credentials:
        accessKeyId: ${AWS_ACCESS_KEY_ID}
        secretAccessKey: ${AWS_SECRET_ACCESS_KEY}

# Kubernetes 插件配置
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
  - type: config
    clusters:
    - url: https://prod-cluster.mycompany.com
      name: production
      authProvider: oidc
      skipTLSVerify: false
      skipMetricsLookup: false
    - url: https://staging-cluster.mycompany.com
      name: staging
      authProvider: serviceAccount
      serviceAccountToken: ${STAGING_K8S_TOKEN}
```

---

## 三、软件目录（Catalog）

### 3.1 实体定义

```yaml
# catalog-info.yaml - 组件定义
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: order-service
  description: 订单核心服务
  labels:
    tier: backend
    language: java
    framework: spring-boot
  annotations:
    github.com/project-slug: my-org/order-service
    backstage.io/techdocs-ref: dir:.
    backstage.io/kubernetes-id: order-service
    sonarqube.org/project-key: my-org_order-service
    prometheus.io/rule: mem_usage|cpu_usage
    grafana/dashboard-selector: "tags@~(service) + tags@~(order)"
    pagerduty.com/service-id: PABC123
  tags:
    - java
    - spring-boot
    - mysql
    - redis
  links:
    - url: https://order-service.mycompany.com/docs
      title: API 文档
      icon: docs
    - url: https://grafana.mycompany.com/d/order-service
      title: 监控面板
      icon: dashboard
    - url: https://pagerduty.mycompany.com/service/PABC123
      title: PagerDuty
      icon: alert
spec:
  type: service
  lifecycle: production
  owner: team-alpha
  system: order-system
  dependsOn:
    - resource:order-mysql
    - resource:order-redis
  providesApis:
    - order-api
  consumesApis:
    - payment-api
    - inventory-api

---
# API 定义
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: order-api
  description: 订单服务 REST API
spec:
  type: openapi
  lifecycle: production
  owner: team-alpha
  system: order-system
  definition:
    $text: https://github.com/my-org/order-service/blob/main/openapi.yaml

---
# 资源定义
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: order-mysql
  description: 订单数据库
spec:
  type: database
  owner: dba-team
  system: order-system
  dependsOn:
    - resource:mysql-cluster-prod

---
# 系统定义
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: order-system
  description: 订单履约系统
tags:
  - core-business
spec:
  owner: team-alpha
  domain: ecommerce

---
# 领域定义
apiVersion: backstage.io/v1alpha1
kind: Domain
metadata:
  name: ecommerce
  description: 电商核心业务
tags:
  - core-business
spec:
  owner: platform-team
```

### 3.2 自动发现

```yaml
# 从 GitHub 自动发现 catalog-info.yaml
# app-config.yaml
catalog:
  providers:
    github:
      providerId:
        organization: my-org
        catalogPath: /catalog-info.yaml
        filters:
          branch: main
          repository: ^service-.*
        schedule:
          frequency: { minutes: 30 }
          timeout: { minutes: 3 }
```

---

## 四、Scaffolder 模板

### 4.1 微服务模板

```yaml
# template.yaml - 新建 Spring Boot 微服务
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: spring-boot-service
  title: Spring Boot 微服务
  description: 创建标准的 Spring Boot 微服务项目
  tags:
    - java
    - spring-boot
    - microservice
spec:
  owner: platform-team
  type: service

  # 用户输入参数
  parameters:
    - title: 基本信息
      required:
        - serviceName
        - owner
        - description
      properties:
        serviceName:
          title: 服务名称
          type: string
          pattern: ^[a-z][a-z0-9-]*$
          ui:autofocus: true
        owner:
          title: 负责人
          type: string
          ui:field: OwnerPicker
          ui:options:
            allowedKinds:
              - Group
        description:
          title: 描述
          type: string
          ui:widget: textarea
    
    - title: 技术选型
      properties:
        javaVersion:
          title: Java 版本
          type: string
          enum: ["17", "21"]
          default: "17"
        database:
          title: 数据库
          type: string
          enum: ["mysql", "postgresql", "mongodb", "none"]
          default: "mysql"
        cache:
          title: 缓存
          type: string
          enum: ["redis", "none"]
          default: "redis"
        messaging:
          title: 消息队列
          type: string
          enum: ["kafka", "rabbitmq", "none"]
          default: "kafka"
    
    - title: 部署配置
      properties:
        replicas:
          title: 副本数
          type: number
          default: 3
          minimum: 1
          maximum: 10
        resources:
          title: 资源限制
          type: object
          properties:
            cpu:
              title: CPU
              type: string
              default: "500m"
            memory:
              title: 内存
              type: string
              default: "1Gi"

  # 执行步骤
  steps:
    - id: fetch-template
      name: 获取模板
      action: fetch:template
      input:
        url: ./skeleton
        values:
          serviceName: ${{ parameters.serviceName }}
          owner: ${{ parameters.owner }}
          description: ${{ parameters.description }}
          javaVersion: ${{ parameters.javaVersion }}
          database: ${{ parameters.database }}
          cache: ${{ parameters.cache }}
          messaging: ${{ parameters.messaging }}
          replicas: ${{ parameters.replicas }}
          resources: ${{ parameters.resources }}

    - id: publish-github
      name: 创建 GitHub 仓库
      action: publish:github
      input:
        allowedHosts: ['github.com']
        description: ${{ parameters.description }}
        repoUrl: github.com?repo=${{ parameters.serviceName }}&owner=my-org
        defaultBranch: main
        protectDefaultBranch: true
        protectEnforceAdmins: true

    - id: register-catalog
      name: 注册到软件目录
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish-github.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml

  # 输出
  output:
    links:
      - title: 仓库
        url: ${{ steps.publish-github.output.remoteUrl }}
      - title: 软件目录
        icon: catalog
        entityRef: ${{ steps.register-catalog.output.entityRef }}
    text:
      - title: 完成
        content: |
          服务 ${{ parameters.serviceName }} 已创建！
          
          接下来：
          1. 克隆仓库：git clone ${{ steps.publish-github.output.remoteUrl }}
          2. 安装依赖：./mvnw install
          3. 本地启动：./mvnw spring-boot:run
          4. 部署到 K8s：kubectl apply -f k8s/
```

---

## 五、插件开发

### 5.1 自定义插件

```bash
# 创建新插件
yarn new --select plugin
# 输入插件名称：cost-explorer

# 目录结构
plugins/cost-explorer/
├── src/
│   ├── components/
│   │   └── CostExplorerPage/
│   │       └── CostExplorerPage.tsx
│   ├── api/
│   │   └── CostExplorerApi.ts
│   └── plugin.ts
├── package.json
└── dev/
```

```typescript
// plugins/cost-explorer/src/plugin.ts
import {
  createPlugin,
  createRoutableExtension,
} from '@backstage/core-plugin-api';
import { rootRouteRef } from './routes';

export const costExplorerPlugin = createPlugin({
  id: 'cost-explorer',
  routes: {
    root: rootRouteRef,
  },
});

export const CostExplorerPage = costExplorerPlugin.provide(
  createRoutableExtension({
    name: 'CostExplorerPage',
    component: () =>
      import('./components/CostExplorerPage').then(m => m.CostExplorerPage),
    mountPoint: rootRouteRef,
  }),
);

// plugins/cost-explorer/src/api/CostExplorerApi.ts
export interface CostExplorerApi {
  getCostsByTeam(team: string): Promise<CostData[]>;
  getCostsByService(service: string): Promise<CostData[]>;
}

export interface CostData {
  month: string;
  compute: number;
  storage: number;
  network: number;
  total: number;
}
```

---

## 六、面试要点

```
Q: Backstage 与 Port、Cortex 等 IDP 工具的区别？

A: 
   Backstage：
   - 开源免费（Apache 2.0）
   - 高度可定制（插件系统）
   - 需要自建和运维
   - 社区活跃（CNCF Sandbox）
   
   Port：
   - 商业 SaaS
   - 开箱即用
   - 按用户收费
   - 不需要运维
   
   Cortex：
   - 商业 SaaS
   - 专注服务目录和评分
   - 与 Backstage 类似但更轻量
   
   选择建议：
   - 有平台团队：Backstage（定制能力强）
   - 快速上手：Port 或 Cortex
   - 已有 K8s 生态：Backstage（集成更好）

Q: Backstage 的软件目录（Catalog）如何与 K8s 集成？

A: 三种集成方式：

   1. Kubernetes 插件：
      - 在 Backstage 中查看 K8s 资源
      - Pod 状态、日志、事件
      - 需要配置 K8s 集群访问权限
   
   2. 注解关联：
      - 在 catalog-info.yaml 中添加注解
      - backstage.io/kubernetes-id: order-service
      - Backstage 自动关联 K8s 资源
   
   3. ArgoCD 插件：
      - 显示应用的部署状态
      - 同步状态、健康状态
      - 点击跳转到 ArgoCD UI
   
   实际效果：
   - 开发者在 Backstage 中看到服务的完整信息
   - 代码、文档、监控、K8s 状态一站式查看
```

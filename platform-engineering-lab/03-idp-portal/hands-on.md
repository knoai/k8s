# 开发者门户 - Backstage 深度实操

> 从本地开发到生产部署的完整 Backstage 实践，包含真实报错排查、
> 插件开发调试、Kubernetes 集成验证和权限模型配置。

---

## 实验 1：本地启动 Backstage（含常见问题排查）

### 场景
在本地 Mac/Linux 环境搭建 Backstage 开发环境，用于后续实验。

### 前置检查

```bash
# 检查 Node.js 版本（需要 18.x 或 20.x）
node --version
# v18.19.0

# 检查 Yarn 版本（需要 1.x，不支持 2+）
yarn --version
# 1.22.21

# 检查 Git
git --version
# git version 2.43.0
```

### 执行

```bash
# 创建 Backstage 应用（约 5-10 分钟）
npx @backstage/create-app@latest
# ? Enter a name for the app [required] platform-portal
# ? Select database for the backend [Use arrows to move/type to filter]
# ❯ SQLite
#   PostgreSQL

# 选择 SQLite（本地开发），PostgreSQL（生产）

# 进入项目
cd platform-portal

# 安装依赖（约 3-5 分钟）
yarn install

# 启动开发服务器
yarn dev
```

### 预期输出

```
# 终端 1（backend）：
[0] webpack compiled successfully
[1] 2024-01-15T10:00:00.000Z backstage info Listening on :7007

# 终端 2（frontend）：
[0]  starting development server...
[0] Compiled successfully!
[0] You can now view platform-portal in the browser.
[0]   Local:            http://localhost:3000
```

### 访问验证

```bash
# 打开浏览器访问 http://localhost:3000
# 应看到 Backstage 首页，包含：
# - 搜索框
# - 快捷链接（Create、Docs、APIs）
# - 示例组件列表
```

### 常见错误排查

```bash
# 错误 1：Node.js 版本不兼容
# error @backstage/cli@0.25.0: The engine "node" is incompatible with this module.
# 解决：使用 nvm 切换版本
nvm install 18
nvm use 18

# 错误 2：Yarn 版本过高
# error This project uses yarn 1.x
# 解决：
npm install -g yarn@1.22.21

# 错误 3：端口被占用
# Error: listen EADDRINUSE: address already in use :::7007
# 解决：查找并终止占用进程
lsof -ti:7007 | xargs kill -9
lsof -ti:3000 | xargs kill -9

# 错误 4：SQLite 权限错误
# SQLITE_CANTOPEN: unable to open database file
# 解决：确保目录有写权限
chmod 755 packages/backend/

# 错误 5：内存溢出
# FATAL ERROR: Reached heap limit Allocation failed
# 解决：增大 Node.js 内存限制
export NODE_OPTIONS="--max-old-space-size=4096"
yarn dev
```

---

## 实验 2：软件目录集成与实体验证

### 场景
将 GitHub 仓库中的服务信息导入 Backstage 软件目录。

### 执行

```bash
# 编辑 app-config.yaml
cat >> app-config.yaml <<'EOF'
integrations:
  github:
    - host: github.com
      token: ${GITHUB_TOKEN}

catalog:
  import:
    entityFilename: catalog-info.yaml
  rules:
    - allow: [Component, System, API, Resource, Domain]
  locations:
    - type: url
      target: https://github.com/backstage/software-templates/blob/main/scaffolder-templates/docs-template/template.yaml
      rules:
        - allow: [Template]
EOF

# 设置 GitHub Token（需要 repo 权限）
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx

# 创建本地 catalog-info.yaml 测试
cat > /tmp/catalog-info.yaml <<'EOF'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payment-service
  description: 支付核心服务
  annotations:
    github.com/project-slug: company/payment-service
    backstage.io/techdocs-ref: dir:.
  tags:
    - java
    - spring-boot
    - payment
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: payment-platform
  providesApis:
    - payment-api
  dependsOn:
    - resource:payment-db
    - resource:payment-redis
---
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: payment-db
  description: 支付主数据库
tags:
  - mysql
  - rds
spec:
  type: database
  owner: team-dba
  system: payment-platform
EOF

# 注册到本地目录
curl -X POST http://localhost:7007/api/catalog/locations \
  -H "Content-Type: application/json" \
  -d '{"type":"file","target":"/tmp/catalog-info.yaml"}'
```

### 预期输出

```bash
# 验证实体已注册
kubectl get component payment-service 2>/dev/null || curl -s http://localhost:7007/api/catalog/entities | jq '.[] | select(.metadata.name=="payment-service")'

# 预期返回：
# {
#   "apiVersion": "backstage.io/v1alpha1",
#   "kind": "Component",
#   "metadata": {
#     "name": "payment-service",
#     "description": "支付核心服务",
#     "annotations": {
#       "github.com/project-slug": "company/payment-service"
#     },
#     "tags": ["java", "spring-boot", "payment"]
#   },
#   "spec": {
#     "type": "service",
#     "lifecycle": "production",
#     "owner": "team-payments"
#   }
# }
```

### 验证依赖关系

```bash
# 在浏览器中查看 payment-service 的实体页面
# http://localhost:3000/catalog/default/component/payment-service

# 应看到：
# - About 卡片：类型、生命周期、Owner
# - Relations 图：依赖的 API 和资源
# - 依赖列表：payment-db、payment-redis
```

---

## 实验 3：创建软件模板（Scaffolder）

### 场景
创建一个完整的微服务模板，开发者填写表单后自动生成代码仓库和 CI/CD 配置。

### 执行

```bash
mkdir -p templates/microservice-template/skeleton

# 创建模板定义
cat > templates/microservice-template/template.yaml <<'EOF'
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: microservice-template
  title: Standard Microservice
  description: Create a new microservice with CI/CD, K8s manifests, and monitoring setup
  tags:
    - recommended
    - microservice
spec:
  owner: platform-team
  type: service

  parameters:
    - title: Service Information
      required:
        - name
        - owner
        - language
      properties:
        name:
          title: Service Name
          type: string
          pattern: '^[a-z0-9-]+$'
          ui:autofocus: true
          description: Unique service name (lowercase, hyphen-separated)
        owner:
          title: Owner
          type: string
          description: Team that owns this service
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              kind: Group
        language:
          title: Programming Language
          type: string
          enum: [java, go, nodejs, python]
          default: java
        description:
          title: Description
          type: string
          ui:widget: textarea
          description: Brief description of the service

    - title: Infrastructure
      properties:
        enableDatabase:
          title: Enable Database
          type: boolean
          default: false
        enableCache:
          title: Enable Redis Cache
          type: boolean
          default: false
        replicas:
          title: Initial Replicas
          type: number
          default: 2
          minimum: 1
          maximum: 10

  steps:
    - id: fetch-base
      name: Fetch Skeleton
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          owner: ${{ parameters.owner }}
          language: ${{ parameters.language }}
          description: ${{ parameters.description }}
          enableDatabase: ${{ parameters.enableDatabase }}
          enableCache: ${{ parameters.enableCache }}
          replicas: ${{ parameters.replicas }}

    - id: publish
      name: Publish to GitHub
      action: publish:github
      input:
        repoUrl: github.com?owner=company&repo=${{ parameters.name }}
        defaultBranch: main
        repoVisibility: internal
        topics:
          - microservice
          - ${{ parameters.language }}

    - id: register
      name: Register in Catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: '/catalog-info.yaml'

  output:
    links:
      - title: Repository
        url: ${{ steps.publish.output.remoteUrl }}
      - title: Open in Catalog
        icon: catalog
        entityRef: ${{ steps.register.output.entityRef }}
    text:
      - title: Next Steps
        content: |
          Your service `${{ parameters.name }}` has been created!
          1. Clone the repository
          2. Run `./scripts/setup.sh` to install dependencies
          3. Run `./scripts/dev.sh` to start locally
EOF

# 创建骨架文件
cat > templates/microservice-template/skeleton/README.md <<'EOF'
# ${{ values.name }}

${{ values.description }}

## Owner

${{ values.owner }}

## Technology Stack

- Language: ${{ values.language }}
- Database: ${{ "Yes" if values.enableDatabase else "No" }}
- Cache: ${{ "Yes" if values.enableCache else "No" }}
- Replicas: ${{ values.replicas }}
EOF

cat > templates/microservice-template/skeleton/catalog-info.yaml <<'EOF'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: ${{ values.name }}
  description: ${{ values.description }}
  annotations:
    github.com/project-slug: company/${{ values.name }}
spec:
  type: service
  owner: ${{ values.owner }}
  lifecycle: experimental
EOF

cat > templates/microservice-template/skeleton/k8s-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${{ values.name }}
  labels:
    app: ${{ values.name }}
spec:
  replicas: ${{ values.replicas }}
  selector:
    matchLabels:
      app: ${{ values.name }}
  template:
    metadata:
      labels:
        app: ${{ values.name }}
    spec:
      containers:
      - name: app
        image: company/${{ values.name }}:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
EOF
```

### 注册模板

```bash
# 将模板注册到 Backstage
curl -X POST http://localhost:7007/api/scaffolder/v2/templates \
  -H "Content-Type: application/json" \
  -d '{
    "type": "file",
    "target": "'$(pwd)'/templates/microservice-template/template.yaml"
  }'

# 或在 app-config.yaml 中添加：
cat >> app-config.yaml <<'EOF'
catalog:
  locations:
    - type: file
      target: ../../templates/microservice-template/template.yaml
      rules:
        - allow: [Template]
EOF

# 重启 Backstage
cd platform-portal && yarn dev
```

### 验证模板

```bash
# 访问 http://localhost:3000/create
# 应看到 "Standard Microservice" 模板卡片

# 点击后应看到表单：
# - Service Name: [输入框]
# - Owner: [下拉选择]
# - Language: [java/go/nodejs/python]
# - Enable Database: [开关]
# - Enable Redis Cache: [开关]
# - Initial Replicas: [数字输入]
```

---

## 实验 4：Kubernetes 插件集成

### 场景
在 Backstage 中查看 K8s 集群中的 Pod 状态和日志。

### 前置条件

```bash
# 确保有 K8s 集群（使用实验 1 创建的 Kind 集群）
kubectl config current-context
# kind-platform-lab

# 创建一个测试服务
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: backstage-demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: backstage-demo
  labels:
    app: demo-app
    backstage.io/kubernetes-id: payment-service
spec:
  replicas: 3
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
        backstage.io/kubernetes-id: payment-service
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: backstage-demo
spec:
  selector:
    app: demo-app
  ports:
  - port: 80
EOF

# 验证 Pod 运行
kubectl get pods -n backstage-demo
# NAME                       READY   STATUS    RESTARTS   AGE
# demo-app-xxxxx-xxxxx      1/1     Running   0          30s
# demo-app-xxxxx-xxxxx      1/1     Running   0          30s
# demo-app-xxxxx-xxxxx      1/1     Running   0          30s
```

### 配置 Backstage K8s 插件

```bash
# 1. 安装插件
cd platform-portal
yarn add --cwd packages/app @backstage/plugin-kubernetes
yarn add --cwd packages/backend @backstage/plugin-kubernetes-backend

# 2. 配置后端（packages/backend/src/plugins/kubernetes.ts）
mkdir -p packages/backend/src/plugins
cat > packages/backend/src/plugins/kubernetes.ts <<'EOF'
import { KubernetesBuilder } from '@backstage/plugin-kubernetes-backend';
import { Router } from 'express';
import { PluginEnvironment } from '../types';

export default async function createPlugin(
  env: PluginEnvironment,
): Promise<Router> {
  const { router } = await KubernetesBuilder.createBuilder({
    logger: env.logger,
    config: env.config,
    catalogApi: env.catalog.getEntityByRef,
    permissions: env.permissions,
  }).build();
  return router;
}
EOF

# 3. 配置 app-config.yaml
cat >> app-config.yaml <<'EOF'
kubernetes:
  serviceLocatorMethod:
    type: multiTenant
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc
          name: kind-platform-lab
          authProvider: serviceAccount
          skipTLSVerify: true
          skipMetricsLookup: true
EOF

# 4. 创建 ServiceAccount（在 K8s 集群中）
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backstage-k8s-plugin
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: backstage-k8s-readonly
rules:
- apiGroups: ['']
  resources: ['pods', 'services', 'configmaps']
  verbs: ['get', 'list', 'watch']
- apiGroups: ['apps']
  resources: ['deployments', 'replicasets']
  verbs: ['get', 'list', 'watch']
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backstage-k8s-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: backstage-k8s-readonly
subjects:
- kind: ServiceAccount
  name: backstage-k8s-plugin
  namespace: default
EOF

# 5. 获取 Token 并配置到 Backstage
K8S_TOKEN=$(kubectl create token backstage-k8s-plugin -n default --duration=24h)
echo "K8S_SERVICE_ACCOUNT_TOKEN=$K8S_TOKEN"

# 将 Token 写入 app-config.local.yaml
cat > app-config.local.yaml <<EOF
kubernetes:
  clusterLocatorMethods:
    - type: config
      clusters:
        - url: https://kubernetes.default.svc
          name: kind-platform-lab
          authProvider: serviceAccount
          serviceAccountToken: ${K8S_TOKEN}
          skipTLSVerify: true
          skipMetricsLookup: true
EOF
```

### 验证集成

```bash
# 重启 Backstage
yarn dev

# 在浏览器中访问 payment-service 实体页面
# http://localhost:3000/catalog/default/component/payment-service

# 应看到 Kubernetes 标签页，显示：
# - Deployment: demo-app (3/3 replicas ready)
# - Pods: 3 个 Pod 的运行状态
# - 可以点击 Pod 查看日志
```

---

## 实验 5：权限框架配置

### 场景
配置 Backstage 权限系统，限制普通开发者只能查看自己团队的服务。

### 执行

```bash
# 安装权限插件
cd platform-portal
yarn add --cwd packages/backend @backstage/plugin-permission-backend
yarn add --cwd packages/backend @backstage/plugin-permission-node

# 创建自定义权限策略
cat > packages/backend/src/plugins/permission.ts <<'EOF'
import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  policyExtensionPoint,
  PolicyDecision,
  AuthorizeResult,
} from '@backstage/plugin-permission-node/alpha';
import {
  PermissionEvaluator,
  toPermissionEvaluator,
} from '@backstage/plugin-permission-common';
import {
  CatalogPermission,
  catalogEntityReadPermission,
} from '@backstage/plugin-catalog-common/alpha';

class TeamBasedPolicy {
  async handle(
    request: {
      permission: { name: string };
      identity?: { ownershipEntityRefs?: string[] };
    },
  ): Promise<PolicyDecision> {
    // 允许读取所有 catalog 实体（简化示例）
    if (request.permission.name === catalogEntityReadPermission.name) {
      return { result: AuthorizeResult.ALLOW };
    }
    
    // 默认允许
    return { result: AuthorizeResult.ALLOW };
  }
}

export const customPermissionModule = createBackendModule({
  pluginId: 'permission',
  moduleId: 'custom-policy',
  register(reg) {
    reg.registerInit({
      deps: { policy: policyExtensionPoint },
      async init({ policy }) {
        policy.setPolicy(new TeamBasedPolicy());
      },
    });
  },
});
EOF
```

### 验证权限

```bash
# 启用权限后，未认证用户访问受限资源会返回 403
# 测试：
curl -s http://localhost:7007/api/catalog/entities | head -c 200
# 应返回实体列表（guest 用户默认有权限）
```

---

## 实验 6：Docker 构建与 K8s 部署

### 场景
将 Backstage 打包为 Docker 镜像并部署到 Kind 集群。

### 执行

```bash
cd platform-portal

# 1. 构建生产版本
yarn install
yarn tsc
yarn build:backend

# 2. 构建 Docker 镜像
docker build . -f packages/backend/Dockerfile -t backstage:local

# 3. 加载到 Kind
kind load docker-image backstage:local --name platform-lab

# 4. 部署到 K8s
kubectl create namespace backstage
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backstage
  namespace: backstage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backstage
  template:
    metadata:
      labels:
        app: backstage
    spec:
      containers:
      - name: backstage
        image: backstage:local
        ports:
        - containerPort: 7007
        env:
        - name: NODE_ENV
          value: production
        - name: BACKSTAGE_BACKEND_URL
          value: http://localhost:7007
        resources:
          requests:
            memory: 512Mi
            cpu: 250m
          limits:
            memory: 1Gi
            cpu: 1000m
---
apiVersion: v1
kind: Service
metadata:
  name: backstage
  namespace: backstage
spec:
  selector:
    app: backstage
  ports:
  - port: 7007
    targetPort: 7007
EOF

# 5. 验证部署
kubectl get pods -n backstage
kubectl logs -n backstage deployment/backstage --tail=50
```

### 验证

```bash
# 端口转发访问
kubectl port-forward svc/backstage 7007:7007 -n backstage &

# 测试
open http://localhost:7007
# 或使用 curl
curl -s http://localhost:7007/api/catalog/entities | jq '.[0].metadata.name'
```

---

## 排障速查表

```
问题                            排查命令/方法                              解决
─────────────────────────────────────────────────────────────────────────────────────
Backstage 启动失败              cat packages/backend/log/*.log            检查 Node 版本、端口占用、内存
模板不显示                      curl /api/scaffolder/v2/templates         检查 catalog.locations 配置
catalog-info.yaml 解析失败      Backstage 日志中的 YAMLError              验证 YAML 语法、必填字段
K8s 插件无数据                  kubectl get pods -n backstage-demo        检查 Pod 标签、ServiceAccount 权限
数据库连接失败                  检查 packages/backend/app-config.yaml    SQLite 路径正确、PostgreSQL 网络连通
权限 403                       检查 permission.ts 配置                   确认策略返回 ALLOW
构建 Docker 失败                docker build 输出                         确认 yarn build:backend 成功
─────────────────────────────────────────────────────────────────────────────────────
```

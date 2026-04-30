# KubeSphere 项目概览文档（中文版）

> **版本**：v3.1.x（release-3.2 分支）  
> **仓库**：`github.com/kubesphere/kubesphere`（后端核心）  
> **语言**：Go 1.16  
> **协议**：Apache 2.0

---

## 一、项目简介

KubeSphere 是一个**面向云原生应用的分布式操作系统**，构建在 Kubernetes 之上，提供多集群管理、DevOps、可观测性、服务网格、多租户等企业级能力。本仓库为 KubeSphere 的**后端核心代码**，采用前后端分离架构，前端 UI 位于独立的 `console` 仓库。

KubeSphere 的定位是：
- 降低企业使用 Kubernetes 的门槛
- 提供开箱即用的云原生工具集
- 支持多云、数据中心和边缘计算场景

---

## 二、系统架构

### 2.1 整体架构

KubeSphere 采用经典的前后分离 + 双层后端架构：

```
┌─────────────────────────────────────────────────────────────┐
│                      前端层 (Console)                        │
│            React 独立仓库：kubesphere/console                 │
└─────────────────────────┬───────────────────────────────────┘
                          │ REST API
┌─────────────────────────▼───────────────────────────────────┐
│                     ks-apiserver                              │
│              （API 网关，端口 9090）                            │
│    ┌─────────────┬─────────────┬─────────────┐               │
│    │  认证授权   │  API 路由   │  审计日志   │               │
│    └─────────────┴─────────────┴─────────────┘               │
│                      kapis/* (扩展 API)                       │
└─────────────────────────┬───────────────────────────────────┘
                          │ K8s API / WebSocket
┌─────────────────────────▼───────────────────────────────────┐
│              ks-controller-manager                            │
│         （控制器管理器，端口 8443/8080）                        │
│    ┌─────────────┬─────────────┬─────────────┐               │
│    │  业务控制器 │  准入 Webhook│ Helm Operator│              │
│    └─────────────┴─────────────┴─────────────┘               │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                   Kubernetes 集群                             │
│    ┌─────────────┬─────────────┬─────────────┐               │
│    │  工作负载   │  存储/网络  │  命名空间   │               │
│    └─────────────┴─────────────┴─────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 核心进程

| 进程 | 入口路径 | 核心职责 |
|------|----------|----------|
| **ks-apiserver** | `cmd/ks-apiserver/` | REST API 统一入口，聚合所有 KubeSphere 扩展 API，处理认证/授权/审计，代理到 K8s API Server |
| **ks-controller-manager** | `cmd/controller-manager/` | 运行所有业务控制器与准入 Webhook，基于 `controller-runtime` 框架，同时作为 Helm Operator 管理 Gateway |

### 2.3 代码目录结构

```
kubesphere/
├── cmd/                          # 主程序入口
│   ├── ks-apiserver/             # API 网关服务器
│   └── controller-manager/       # 控制器管理器
├── pkg/                          # 核心业务代码（~10,000+ .go 文件）
│   ├── api/                      # 内部 API 类型与工具
│   ├── apiserver/                # API 服务器框架（认证、授权、审计、路由）
│   ├── client/                   # 生成的 Clientset / Informers / Listers
│   ├── constants/                # 全局常量
│   ├── controller/               # 业务控制器（30+ 个）
│   ├── informers/                # 共享 Informer 工厂
│   ├── kapis/                    # KubeSphere 扩展 API（按领域划分）
│   ├── models/                   # 业务模型/服务层
│   ├── server/                   # 通用服务器工具
│   ├── simple/client/            # 外部服务客户端封装
│   ├── utils/                    # 工具库
│   ├── version/                  # 版本信息
│   └── webhook/                  # 准入 Webhook
├── api/                          # OpenAPI 规范与 API 规则
├── config/                       # 部署配置
│   ├── crds/                     # CRD YAML 定义
│   ├── gateway/                  # 网关 Helm Chart
│   └── ks-core/                  # 核心 Helm Chart
├── staging/src/kubesphere.io/    # 独立发布的子模块
│   ├── api/                      # KubeSphere API Schema（CRD Go 类型）
│   └── client-go/                # 自动生成的 Go 客户端
├── build/                        # Dockerfile（多阶段构建）
├── docs/                         # 文档与架构图片
├── hack/                         # 构建/开发脚本
├── install/                      # 安装脚本与 Swagger UI
├── test/                         # E2E 测试
└── tools/                        # 代码生成工具
```

### 2.4 核心模块详解

#### API 层（`pkg/kapis/*`）

按领域划分的扩展 API 组，注册到 `go-restful` 容器：

| API 组 | 说明 |
|--------|------|
| `cluster` | 多集群管理 |
| `devops` (v1alpha2/v1alpha3) | DevOps / Jenkins 集成 |
| `iam` | 身份与访问管理 |
| `monitoring` / `alerting` / `metering` | 可观测性与计费 |
| `network` | 网络策略 / IPPool |
| `notification` | 通知系统 |
| `openpitrix` | 应用商店（Helm 应用生命周期） |
| `servicemesh` | Istio 服务网格 |
| `tenant` | 多租户（Workspace/Project） |
| `terminal` | Web Terminal |
| `gateway` | 网关管理 |
| `operations` / `resources` | 运维与资源管理 |

#### 控制器层（`pkg/controller/*`）

使用 `controller-runtime` Manager 管理，核心控制器包括：

| 控制器 | 职责 |
|--------|------|
| `user` | 用户生命周期与 LDAP 同步 |
| `workspace` / `workspacetemplate` | 租户与 RBAC |
| `namespace` | 命名空间管理 |
| `application` | Application CR 调和 |
| `helm` (repo/category/release) | Helm 应用商店 |
| `cluster` | 多集群联邦 |
| `quota` | 资源配额 |
| `network` / `virtualservice` / `destinationrule` | 网络与服务网格 |
| `notification` | 通知配置 |
| `storage` | 存储管理 |

#### 模型层（`pkg/models/*`）

业务逻辑抽象，对应各领域的 Service 层：

| 模块 | 说明 |
|------|------|
| `auth` | 认证/密码/OAuth/Token |
| `iam` | 用户/角色/组管理 |
| `resources` / `workloads` | K8s 资源查询与转换 |
| `monitoring` / `logging` / `auditing` / `events` | 可观测性数据聚合 |
| `devops` / `openpitrix` / `gateway` / `tenant` | 各领域业务逻辑 |

#### 客户端封装（`pkg/simple/client/*`）

对外部系统的统一客户端接口：

| 客户端 | 外部系统 |
|--------|----------|
| `k8s` | Kubernetes / Istio / Snapshot / Prometheus |
| `devops` (jenkins) | Jenkins 流水线 |
| `monitoring` (prometheus) | 监控指标查询 |
| `logging` / `auditing` / `events` (elasticsearch) | 日志与审计 |
| `ldap` | 身份目录 |
| `s3` | 对象存储 |
| `sonarqube` | 代码质量 |
| `multicluster` | 多集群代理 |

### 2.5 技术栈

| 类别 | 技术 |
|------|------|
| **编程语言** | Go 1.16 |
| **容器基础镜像** | Alpine 3.11 |
| **Web 框架** | `emicklei/go-restful` |
| **K8s 控制器** | `controller-runtime` |
| **K8s 客户端** | `client-go` v12.0.0 |
| **CLI** | `spf13/cobra` + `spf13/viper` |
| **Helm** | Helm v3.6.3 |
| **服务网格** | Istio |
| **多集群联邦** | Kubefed v0.8.1 |
| **监控** | Prometheus + Alertmanager |
| **日志/审计** | Elasticsearch + Fluent Bit |
| **认证** | OIDC / LDAP / OAuth2 / JWT |
| **数据库** | MySQL |
| **缓存** | Redis |
| **测试** | Ginkgo + Gomega |
| **代码生成** | controller-gen / code-generator / openapi-gen |

---

## 三、核心功能

KubeSphere 提供以下开箱即用的云原生能力：

### 3.1 Kubernetes 集群部署
- 支持在任何基础设施上部署 Kubernetes
- 支持在线和离线（Air-gapped）安装

### 3.2 多集群管理
- 集中控制平面管理多个 K8s 集群
- 支持跨云厂商的应用分发
- 基于 Kubefed 实现跨集群资源分发

### 3.3 DevOps（CI/CD）
- 基于 Jenkins 的开箱即用 CI/CD
- 支持 B2I（Binary-to-Image）和 S2I（Source-to-Image）
- 流水线图形化编排
- 集成 SonarQube 代码质量分析

### 3.4 云原生可观测性
- **监控**：多维度监控、自定义告警规则
- **日志**：多租户日志查询、日志收集与检索
- **审计**：操作审计追踪
- **事件**：Kubernetes 事件管理
- **通知**：告警通知多渠道推送（邮件、Slack、Webhook 等）

### 3.5 服务网格（Service Mesh）
- 基于 Istio 的微服务治理
- 细粒度流量管理（金丝雀发布、蓝绿部署、熔断）
- 分布式链路追踪
- 微服务可观测性

### 3.6 应用商店
- 基于 Helm 的应用全生命周期管理
- 应用上传、发布、部署、升级、回滚
- 企业级应用仓库管理

### 3.7 边缘计算
- 集成 KubeEdge
- 支持边缘设备应用部署
- 边缘节点日志与监控查看

### 3.8 计量计费
- 统一仪表盘跟踪多层级资源消耗
- 支持 Workspace / Project / Pod 级别统计
- 辅助成本规划与资源优化

### 3.9 存储与网络
- 支持多种存储后端：GlusterFS、Ceph RBD、NFS、LocalPV
- 提供 OpenELB 负载均衡
- 支持 Calico、Flannel、Kube-OVN 等网络方案
- IPPool 与网络策略管理

### 3.10 多租户与 RBAC
- **统一认证**：支持本地用户、LDAP/AD、OAuth2/OIDC
- **三层授权体系**：Global → Workspace → Project
- **细粒度 RBAC**：角色与权限灵活配置
- **用户组管理**：支持部门级批量授权

---

## 四、如何运行

### 4.1 前置条件

- Go 1.16+
- Docker
- Kubernetes 集群（v1.19+）或 Kind
- kubectl
- Helm 3（可选）

### 4.2 方式一：快速体验（生产/测试环境，官方推荐）

在已有 Kubernetes 集群上执行：

```bash
# 1. 安装 KubeSphere 安装器
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.1.1/kubesphere-installer.yaml

# 2. 应用集群配置
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.1.1/cluster-configuration.yaml

# 3. 查看安装日志
kubectl logs -n kubesphere-system -l app=ks-install -f

# 4. 安装完成后访问
# URL: http://<NodeIP>:30880
# 默认账号：admin / P@88w0rd
```

### 4.3 方式二：从源码构建并部署

```bash
# 1. 克隆代码
git clone https://github.com/kubesphere/kubesphere.git
cd kubesphere

# 2. 构建二进制文件
make binary
# 或分别构建：
# make ks-apiserver
# make ks-controller-manager

# 3. 构建 Docker 镜像
make container

# 4. 推送镜像到仓库（可选）
make container-push

# 5. 使用 Helm 部署到 K8s
make helm-deploy

# 6. 或使用 Kustomize 部署
make deploy
```

### 4.4 方式三：开发环境（Kind）快速验证

```bash
# 一键在 Kind 中部署并运行 E2E 测试
make kind-e2e

# 或手动操作：
kind create cluster
KIND_LOAD_IMAGE=y hack/deploy-kubesphere.sh
```

### 4.5 方式四：Helm 手动安装

```bash
# 1. 拷贝 CRD 到 chart 目录并打包
make helm-package

# 2. 使用 Helm 安装/升级
helm upgrade --install ks-core ./config/ks-core \
  -n kubesphere-system \
  --create-namespace

# 3. 卸载
make helm-uninstall
```

### 4.6 常用 Makefile 命令

| 命令 | 说明 |
|------|------|
| `make all` | 运行测试并构建所有二进制 |
| `make ks-apiserver` | 仅构建 API Server |
| `make ks-controller-manager` | 仅构建 Controller Manager |
| `make binary` | 构建所有二进制 |
| `make test` | 运行单元测试 |
| `make e2e` | 构建 E2E 测试二进制 |
| `make kind-e2e` | 在 Kind 集群中运行 E2E 测试 |
| `make container` | 本地构建 Docker 镜像 |
| `make container-push` | 构建并推送 Docker 镜像 |
| `make container-cross` | 多架构（amd64/arm64）镜像构建 |
| `make helm-package` | 打包 ks-core Helm Chart |
| `make helm-deploy` | 通过 Helm 部署到 kubesphere-system |
| `make manifests` | 生成 CRD、RBAC 等 manifest |
| `make verify-all` | 运行所有验证脚本 |
| `make fmt` / `make goimports` | 代码格式化 |
| `make clientset` | 生成客户端代码 |
| `make clean` | 清理构建产物 |

### 4.7 Docker 镜像说明

| 镜像 | Dockerfile | 说明 |
|------|-----------|------|
| `kubesphere/ks-apiserver` | `build/ks-apiserver/Dockerfile` | 暴露端口 9090，内含 helm 工具 |
| `kubesphere/ks-controller-manager` | `build/ks-controller-manager/Dockerfile` | 暴露端口 8443/8080，内含 helm + kustomize |

### 4.8 开发调试

```bash
# 初始化开发环境
hack/init_env.sh

# 下载 kubebuilder 测试依赖
make test-env

# 代码格式化与静态检查
make fmt
make goimports
make vet
make verify-all

# 生成代码（修改 CRD 后执行）
make manifests
make clientset
make openapi
make deepcopy
```

---

## 五、架构特点总结

1. **前后端分离**：本仓库为纯后端（Go），前端 UI 在独立仓库 `kubesphere/console`
2. **松耦合插件化**：DevOps、ServiceMesh、Monitoring 等可按需启用
3. **多层缓存策略**：SharedInformer + controller-runtime Cache + Redis 会话缓存
4. **多集群联邦**：基于 Kubefed 实现跨集群资源分发
5. **统一网关**：`ks-apiserver` 作为单一入口，聚合 K8s 原生 API 与 KubeSphere 扩展 API
6. **RBAC + 多租户**：三层授权体系（Global / Workspace / Project）
7. **代码生成完善**：大量使用 controller-gen、deepcopy-gen、client-gen、openapi-gen 维护 API 与客户端代码
8. **Operator 特性**：`ks-controller-manager` 同时作为 Helm Operator 管理 Gateway 和 Ingress

---

## 六、相关资源

- **官方文档**：[https://kubesphere.io/docs](https://kubesphere.io/docs)
- **GitHub 仓库**：[https://github.com/kubesphere/kubesphere](https://github.com/kubesphere/kubesphere)
- **前端仓库**：[https://github.com/kubesphere/console](https://github.com/kubesphere/console)
- **安装器仓库**：[https://github.com/kubesphere/ks-installer](https://github.com/kubesphere/ks-installer)
- **社区论坛**：[https://kubesphere.io/forum](https://kubesphere.io/forum)

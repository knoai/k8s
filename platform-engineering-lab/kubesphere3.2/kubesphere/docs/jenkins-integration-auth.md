# KubeSphere 与 Jenkins 对接及授权机制详解

> **适用版本**：KubeSphere v3.1.x / v3.2（release-3.2 分支）  
> **文档定位**：面向开发者与架构师，深入解读 KubeSphere DevOps 模块与 Jenkins 的集成原理，重点剖析授权认证机制

---

## 目录

1. [架构总览](#一架构总览)
2. [核心组件与文件映射](#二核心组件与文件映射)
3. [Jenkins 客户端初始化](#三jenkins-客户端初始化)
4. [双重认证机制](#四双重认证机制)
5. [Bearer Token → Basic Auth 转换](#五bearer-token--basic-auth-转换)
6. [权限映射与 RBAC](#六权限映射与-rbac)
7. [Pipeline 运行时身份传递](#七pipeline-运行时身份传递)
8. [Crumb 防护与连接控制](#八crumb-防护与连接控制)
9. [配置项汇总](#九配置项汇总)
10. [总结：完整授权流程图](#十总结完整授权流程图)

---

## 一、架构总览

KubeSphere 的 DevOps 模块采用 **"CRD 作为源数据 + Jenkins 作为执行引擎"** 的架构设计。KubeSphere 不直接替代 Jenkins，而是将其作为底层的 CI/CD 执行引擎，通过 REST API 进行深度集成。

### 1.1 整体架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          KubeSphere UI / CLI                                │
│                  (用户持有 JWT Bearer Token)                                 │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │ REST API
┌─────────────────────────────────▼───────────────────────────────────────────┐
│  pkg/kapis/devops/v1alpha3/register.go                                      │
│  GenericProxy → 将 DevOps 请求代理到 ks-devops 或直接处理                    │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│  pkg/models/devops/devops.go                                                │
│  DevopsOperator                                                             │
│  ├── CRD 操作：DevOpsProject / Pipeline / Credential (通过 K8s API)         │
│  └── Jenkins 操作：通过 devopsClient (devops.Interface) 透传请求            │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│  pkg/simple/client/devops/jenkins/                                          │
│  Jenkins 结构体（实现 devops.Interface）                                     │
│  ├── pipeline.go       → Blue Ocean API（Run/Stop/Log/Nodes/Steps）        │
│  ├── project_pipeline.go → Job CRUD + XML 配置转换                          │
│  ├── credential.go     → Jenkins Credentials API                            │
│  ├── role.go           → Role-Strategy Plugin API                           │
│  ├── request.go        → HTTP 基础层（Auth / Crumb / 连接池）               │
│  └── pure_request.go   → 纯请求转发（Bearer → Basic Token 转换）            │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │ HTTP REST
┌─────────────────────────────────▼───────────────────────────────────────────┐
│                         Jenkins Server                                      │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────┐ │
│  │ Blue Ocean      │  │ Role-Strategy   │  │ Credentials Plugin          │ │
│  │ Plugin          │  │ Plugin          │  │                             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────────┐ │
│  │ Pipeline Plugin │  │ SCM Plugins     │  │ OAuth/Reverse Proxy Auth    │ │
│  │                 │  │ (Git/GitLab/...)│  │                             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 核心设计理念

| 设计点 | 说明 |
|--------|------|
| **CRD 为源** | DevOpsProject、Pipeline、Credential 以 K8s CRD/Secret 形式存储，Jenkins 仅作为执行引擎 |
| **Folder-Project 映射** | KubeSphere 的 `DevOpsProject` 对应 Jenkins 的一个 `Folder` |
| **Namespace 隔离** | 每个 DevOpsProject 有 `Status.AdminNamespace`，Pipeline 和 Credential 存放其中 |
| **状态注释同步** | CRD 使用 Annotation 标记同步状态，如 `devopsproject.devops.kubesphere.io/syncstatus` |
| **实时查询** | KubeSphere 采用"请求时实时查询 Jenkins"模式，而非 Controller 主动轮询同步状态 |

---

## 二、核心组件与文件映射

### 2.1 Jenkins Client 层

| 文件路径 | 职责 |
|---------|------|
| `pkg/simple/client/devops/jenkins/jenkins.go` | Jenkins 主客户端结构体，封装所有 Jenkins REST API 调用，包含角色管理 API |
| `pkg/simple/client/devops/jenkins/request.go` | HTTP 请求器（Requester），处理 Basic Auth、Crumb、连接池控制、Bearer → Basic 转换 |
| `pkg/simple/client/devops/jenkins/pure_request.go` | 纯请求转发（`SendPureRequest` / `SendPureRequestWithHeaderResp`），用于 Blue Ocean API 透传 |
| `pkg/simple/client/devops/jenkins/options.go` | Jenkins 连接配置（Host / Username / Password / MaxConnections / Endpoint） |
| `pkg/simple/client/devops/jenkins/devops.go` | DevOps 客户端工厂，`NewDevopsClient` 创建 Jenkins 实例 |
| `pkg/simple/client/devops/jenkins/README.md` | 说明 Fork 自 `gojenkins`，扩展了 Credentials / Pipeline / RBAC |

### 2.2 Pipeline 操作层

| 文件路径 | 职责 |
|---------|------|
| `pkg/simple/client/devops/jenkins/pipeline.go` | Pipeline 运行态操作（Run / Stop / Replay / GetLog / Artifacts / Nodes / Steps） |
| `pkg/simple/client/devops/jenkins/project_pipeline.go` | Pipeline 静态配置 CRUD（Create / Update / Delete / GetConfig） |
| `pkg/simple/client/devops/jenkins/pipeline_internal.go` | Pipeline XML 配置生成与解析 |
| `pkg/simple/client/devops/jenkins/pipeline_model_converter.go` | Jenkinsfile ↔ JSON 互转，调用 `/pipeline-model-converter` |

### 2.3 底层对象封装

| 文件路径 | 职责 |
|---------|------|
| `pkg/simple/client/devops/jenkins/job.go` | Job 封装（Build 触发、Config 更新/获取、状态轮询） |
| `pkg/simple/client/devops/jenkins/folder.go` | Folder 封装（DevOpsProject 映射为 Jenkins Folder） |
| `pkg/simple/client/devops/jenkins/build.go` | Build 封装（状态、日志、测试报告、上下游关联） |
| `pkg/simple/client/devops/jenkins/credential.go` | Credential 在 Jenkins 中的 CRUD（SSH / UsernamePassword / SecretText / Kubeconfig） |
| `pkg/simple/client/devops/jenkins/role.go` | RBAC 角色管理（GlobalRole / ProjectRole，基于 role-strategy 插件） |

### 2.4 权限与常量定义

| 文件路径 | 职责 |
|---------|------|
| `pkg/simple/client/devops/role.go` | `GlobalPermissionIds` / `ProjectPermissionIds` 权限常量定义 |
| `pkg/simple/client/devops/jenkins/constants.go` | `GLOBAL_ROLE`、`PROJECT_ROLE` 常量 |
| `pkg/simple/client/devops/pipeline.go` | `HttpParameters` 结构体定义、`PipelineOperator` 接口 |

### 2.5 API / Model 层

| 文件路径 | 职责 |
|---------|------|
| `pkg/kapis/devops/v1alpha3/register.go` | DevOps API 注册，通过 GenericProxy 代理请求 |
| `pkg/models/devops/devops.go` | DevopsOperator 实现，桥接 K8s CRD 与 Jenkins Client |
| `pkg/models/tenant/devops.go` | KubeSphere 侧 DevOps Project 列表的 RBAC 控制 |

### 2.6 CRD 类型定义

| 文件路径 | 职责 |
|---------|------|
| `staging/src/kubesphere.io/api/devops/v1alpha3/pipeline_types.go` | Pipeline CRD（NoScmPipeline / MultiBranchPipeline） |
| `staging/src/kubesphere.io/api/devops/v1alpha3/devopsproject_types.go` | DevOpsProject CRD（集群级资源，Status.AdminNamespace） |
| `staging/src/kubesphere.io/api/devops/v1alpha3/credential_types.go` | Credential 类型定义 |

### 2.7 配置层

| 文件路径 | 职责 |
|---------|------|
| `pkg/apiserver/config/config.go` | 全局 Config 包含 `*jenkins.Options`（`DevopsOptions`） |
| `cmd/ks-apiserver/app/options/options.go` | APIServer 启动选项，加载 Jenkins 配置 |
| `cmd/controller-manager/app/options/options.go` | Controller Manager 启动选项 |
| `pkg/apiserver/authentication/token/issuer.go` | JWT `Claims` 定义（含 `Username` 字段） |

---

## 三、Jenkins 客户端初始化

### 3.1 配置结构体

`pkg/simple/client/devops/jenkins/options.go`：

```go
type Options struct {
    Host           string `json:",omitempty" yaml:"host" description:"Jenkins service host address"`
    Username       string `json:",omitempty" yaml:"username" description:"Jenkins admin username"`
    Password       string `json:",omitempty" yaml:"password" description:"Jenkins admin password"`
    MaxConnections int    `json:"maxConnections,omitempty" yaml:"maxConnections"`
    Endpoint       string `json:"endpoint,omitempty" yaml:"endpoint" description:"The endpoint of the ks-devops apiserver"`
}
```

**配置来源**：
- 配置文件：`/etc/kubesphere/kubesphere.yaml` 中的 `devops` 段
- 命令行参数：`--jenkins-host`、`--jenkins-username`、`--jenkins-password`、`--jenkins-max-connections`
- 校验逻辑：若 `Host` 非空，则 `Username` 和 `Password` 必须非空

### 3.2 客户端创建流程

```go
// pkg/simple/client/devops/jenkins/devops.go
func NewDevopsClient(options *Options) (devops.Interface, error) {
    jenkins := CreateJenkins(nil, options.Host, options.MaxConnections, options.Username, options.Password)
    return jenkins, nil
}
```

```go
// pkg/simple/client/devops/jenkins/jenkins.go
func CreateJenkins(client *http.Client, base string, maxConnection int, auth ...interface{}) *Jenkins {
    j := &Jenkins{}
    j.Server = base
    j.Requester = &Requester{
        Base:        base,
        SslVerify:   true,
        Client:      client,
        connControl: make(chan struct{}, maxConnection),
    }
    if len(auth) == 2 {
        j.Requester.BasicAuth = &BasicAuth{
            Username: auth[0].(string),
            Password: auth[1].(string),
        }
    }
    return j
}
```

**关键结论**：KubeSphere 使用一个**固定的 Jenkins 管理员账号**（通过 Basic Auth）与 Jenkins 后端建立基础连接。

### 3.3 连接池控制

`Requester` 内部使用 `connControl chan struct{}`（容量为 `maxConnections`）限制并发连接数：

```go
// 每个 HTTP 请求前
r.connControl <- struct{}{}

// 请求完成后释放
<-r.connControl
```

这防止了高并发场景下对 Jenkins 的过度压力。

---

## 四、双重认证机制

KubeSphere 与 Jenkins 之间存在**两条独立的认证通道**：

### 4.1 管理员通道：固定 Basic Auth

**用途**：KubeSphere 主动发起的管理操作，如创建 Job、分配角色、创建凭证、删除资源等。

**实现位置**：`pkg/simple/client/devops/jenkins/request.go`

```go
if r.BasicAuth != nil {
    req.SetBasicAuth(r.BasicAuth.Username, r.BasicAuth.Password)
}
```

**认证信息**：
- Username：`options.Username`（Jenkins 管理员用户名）
- Password：`options.Password`（Jenkins 管理员密码 或 API Token）

**典型调用场景**：
- `CreateDevOpsProject` → 创建 Jenkins Folder
- `CreateProjectPipeline` → 创建 Jenkins Job
- `AssignGlobalRole` / `AssignProjectRole` → 角色分配
- `CreateCredentialInProject` → 创建 Jenkins Credential
- `DeleteUserInProject` → 从 Jenkins 项目中移除用户

### 4.2 用户通道：Bearer Token → Basic Auth

**用途**：代表用户身份发起的操作，如查看 Pipeline、触发构建、获取日志、重播流水线等。

**实现位置**：`pkg/simple/client/devops/jenkins/pure_request.go`

**核心函数**：`SendPureRequestWithHeaderResp`

```go
func (j *Jenkins) SendPureRequestWithHeaderResp(
    path string,
    httpParameters *devops.HttpParameters,
) ([]byte, http.Header, error) {
    // ...
    header := httpParameters.Header
    SetBasicBearTokenHeader(&header)   // <-- 关键：Bearer → Basic 转换

    newRequest := &http.Request{
        Method:   httpParameters.Method,
        URL:      apiURL,
        Header:   header,
        Body:     httpParameters.Body,
        // ...
    }
    resp, err := client.Do(newRequest)
    // ...
}
```

**认证信息**：
- Username：从用户 JWT Token 的 `Claim.Username` 提取
- Password：用户原始的 Bearer Token
- 最终格式：`Authorization: Basic base64(username:bear_token)`

**典型调用场景**：
- `RunPipeline` → 触发 Pipeline 构建
- `GetPipelineRun` → 查看 Pipeline Run 状态
- `GetRunLog` / `GetStepLog` → 获取构建日志
- `StopPipeline` / `ReplayPipeline` → 停止/重播构建
- `ListPipelineRuns` → 列出 Pipeline 运行历史

---

## 五、Bearer Token → Basic Auth 转换

这是 KubeSphere 实现 Jenkins SSO（单点登录）的**核心机制**。

### 5.1 转换函数详解

`pkg/simple/client/devops/jenkins/request.go`：

```go
// set basic token for jenkins auth
func SetBasicBearTokenHeader(header *http.Header) error {
    bearTokenArray := strings.Split(header.Get("Authorization"), " ")
    bearFlag := bearTokenArray[0]

    if strings.ToLower(bearFlag) == "bearer" {
        bearToken := bearTokenArray[1]
        claim := authtoken.Claims{}
        parser := jwt.Parser{}

        // 注意：ParseUnverified 仅解析 Token，不验证签名！
        _, _, err = parser.ParseUnverified(bearToken, &claim)
        if err != nil {
            return err
        }

        creds := base64.StdEncoding.EncodeToString(
            []byte(fmt.Sprintf("%s:%s", claim.Username, bearToken)),
        )
        header.Set("Authorization", fmt.Sprintf("Basic %s", creds))
    }
    return nil
}
```

### 5.2 转换流程解析

```
┌────────────────────────────────────────────────────────────────────┐
│  1. 用户请求 KubeSphere API                                        │
│     Header: Authorization: Bearer <JWT_Token>                      │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  2. ks-apiserver 接收请求                                          │
│     pkg/models/devops/devops.go:convertToHttpParameters(req)       │
│     完整保留原始 Header（含 Bearer Token）                          │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  3. Jenkins Client 调用 SendPureRequestWithHeaderResp              │
│     pkg/simple/client/devops/jenkins/pure_request.go               │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  4. SetBasicBearTokenHeader 执行转换                               │
│     a. 提取 Bearer Token                                           │
│     b. 使用 jwt.ParseUnverified 解析 Claim（不解密/不验证签名！）   │
│     c. 获取 claim.Username                                         │
│     d. 构造 Basic Auth: base64(username:bear_token)                │
│     e. 重写 Header: Authorization: Basic <base64>                  │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│  5. 请求发送到 Jenkins                                             │
│     Header: Authorization: Basic base64(username:JWT_Token)        │
│     Jenkins 认证插件验证 Token 有效性，识别用户身份                  │
└────────────────────────────────────────────────────────────────────┘
```

### 5.3 关键注意点

| 注意点 | 说明 |
|--------|------|
| **不解密 JWT** | `ParseUnverified` 仅提取 Payload 中的 `Username`，不做签名验证 |
| **Token 透传** | 原始 JWT Token 作为 Basic Auth 的 Password 部分完整传递给 Jenkins |
| **Jenkins 端验证** | 实际的 Token 有效性校验由 Jenkins 端的认证插件（如 OAuth / Reverse Proxy / KubeSphere 定制认证器）完成 |
| **单点登录效果** | 用户只需登录 KubeSphere，即可无缝访问 Jenkins 功能，无需再次输入 Jenkins 密码 |

---

## 六、权限映射与 RBAC

KubeSphere 与 Jenkins 各自维护一套权限体系，通过**用户名映射（SID）**实现权限同步。

### 6.1 KubeSphere 侧：K8s RBAC

KubeSphere 使用 Kubernetes 原生的 RBAC 机制控制 DevOps 资源的访问：

**集群级权限**：
- `list devopsprojects` → 查看所有 DevOps Project
- `create devopsprojects` → 创建 DevOps Project

**企业空间级权限**：
- `manage devopsprojects` → 管理企业空间下的 DevOps Project
- `view devopsprojects` → 查看企业空间下的 DevOps Project

**项目级权限**：
- `manage pipelines` → 管理 Pipeline
- `run pipelines` → 运行 Pipeline
- `view pipelines` → 查看 Pipeline

**实现位置**：`pkg/models/tenant/devops.go`

```go
// ListDevOpsProjects 使用 authorizer.AttributesRecord 判断权限
func (t *tenantOperator) ListDevOpsProjects(...) {
    // 1. 判断集群级 list 权限
    // 2. 若否，查询用户的 RoleBinding
    // 3. 通过 Namespace Label "kubesphere.io/devopsproject" 找到关联的 DevOps Project
}
```

### 6.2 Jenkins 侧：Role Strategy 插件

KubeSphere 通过调用 Jenkins **Role-based Authorization Strategy** 插件的 REST API 实现权限映射。

**角色类型常量**（`pkg/simple/client/devops/jenkins/constants.go`）：

```go
const (
    GLOBAL_ROLE  = "globalRoles"
    PROJECT_ROLE = "projectRoles"
)
```

**全局权限定义**（`pkg/simple/client/devops/role.go`）：

```go
type GlobalPermissionIds struct {
    OverallAdminister      bool `json:"hudson.model.Hudson.Administer"`
    OverallRead            bool `json:"hudson.model.Hudson.Read"`
    ItemBuild              bool `json:"hudson.model.Item.Build"`
    ItemCancel             bool `json:"hudson.model.Item.Cancel"`
    ItemConfigure          bool `json:"hudson.model.Item.Configure"`
    ItemCreate             bool `json:"hudson.model.Item.Create"`
    ItemDelete             bool `json:"hudson.model.Item.Delete"`
    ItemDiscover           bool `json:"hudson.model.Item.Discover"`
    ItemMove               bool `json:"hudson.model.Item.Move"`
    ItemRead               bool `json:"hudson.model.Item.Read"`
    ItemWorkspace          bool `json:"hudson.model.Item.Workspace"`
    RunDelete              bool `json:"hudson.model.Run.Delete"`
    RunReplay              bool `json:"hudson.model.Run.Replay"`
    RunUpdate              bool `json:"hudson.model.Run.Update"`
    // ...
}
```

**项目级权限定义**：

```go
type ProjectPermissionIds struct {
    ItemBuild      bool `json:"hudson.model.Item.Build"`
    ItemCancel     bool `json:"hudson.model.Item.Cancel"`
    ItemConfigure  bool `json:"hudson.model.Item.Configure"`
    ItemCreate     bool `json:"hudson.model.Item.Create"`
    ItemDelete     bool `json:"hudson.model.Item.Delete"`
    ItemDiscover   bool `json:"hudson.model.Item.Discover"`
    ItemMove       bool `json:"hudson.model.Item.Move"`
    ItemRead       bool `json:"hudson.model.Item.Read"`
    ItemWorkspace  bool `json:"hudson.model.Item.Workspace"`
    RunDelete      bool `json:"hudson.model.Run.Delete"`
    RunReplay      bool `json:"hudson.model.Run.Replay"`
    RunUpdate      bool `json:"hudson.model.Run.Update"`
    // ...
}
```

### 6.3 角色管理 API

`pkg/simple/client/devops/jenkins/jenkins.go`：

```go
// 分配全局角色
func (j *Jenkins) AssignGlobalRole(roleName string, sid string) error

// 分配项目角色（pattern 通常为 project-name/*）
func (j *Jenkins) AssignProjectRole(roleName string, sid string) error

// 从项目中移除用户
func (j *Jenkins) DeleteUserInProject(username string) error
```

`pkg/simple/client/devops/jenkins/role.go`：

```go
// 添加/更新全局角色
func (j *Jenkins) AddGlobalRole(roleName string, ids GlobalPermissionIds, overwrite bool) error

// 添加/更新项目角色
func (j *Jenkins) AddProjectRole(roleName string, pattern string, ids ProjectPermissionIds, overwrite bool) error
```

### 6.4 权限映射机制

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        KubeSphere 侧                                         │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐ │
│  │  User           │    │  WorkspaceRole  │    │  DevOps Project CRD     │ │
│  │  (username)     │───→│  / RoleBinding  │───→│  (Namespace 隔离)       │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            │ 用户名作为 SID
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Jenkins 侧                                            │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────────────┐ │
│  │  SID            │    │  GlobalRole     │    │  ProjectRole            │ │
│  │  (username)     │───→│  (Admin/Viewer) │    │  (pattern: project/*)   │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

**映射规则**：
- KubeSphere 的 `DevOpsProject Owner` → Jenkins `admin` 全局角色 或 项目管理员角色
- KubeSphere 的 `DevOpsProject Maintainer` → Jenkins 项目维护者角色（Build/Configure/Create）
- KubeSphere 的 `DevOpsProject Developer` → Jenkins 项目开发者角色（Build/Read）
- KubeSphere 的 `DevOpsProject Reporter` → Jenkins 项目只读角色（Read）

**核心结论**：KubeSphere 不直接让 Jenkins 复用 KubeSphere 的 RBAC 对象，而是**在 Jenkins 中维护一套平行的 Role Strategy 角色体系**，通过 Admin Client 将 KubeSphere 用户（作为 SID）同步映射到 Jenkins 的 Global/Project Role 上。

---

## 七、Pipeline 运行时身份传递

### 7.1 完整链路

以 `RunPipeline`（触发 Pipeline 构建）为例：

**Step 1**：用户发起请求
```
POST /kapis/devops.kubesphere.io/v1alpha3/devops/{project}/pipelines/{pipeline}/run
Authorization: Bearer <JWT_Token>
```

**Step 2**：`ks-apiserver` 处理
```go
// pkg/models/devops/devops.go
func (d *devopsOperator) RunPipeline(request *restful.Request, response *restful.Response) {
    httpParameters := convertToHttpParameters(request.Request)
    // httpParameters.Header 中保留了原始 Bearer Token
    res, err := d.devopsClient.RunPipeline(projectName, pipelineName, httpParameters)
    // ...
}
```

**Step 3**：Jenkins Client 构造 Pipeline 对象
```go
// pkg/simple/client/devops/jenkins/jenkins.go
func (j *Jenkins) RunPipeline(projectName, pipelineName string, httpParameters *devops.HttpParameters) (*devops.RunPipeline, error) {
    PipelineOjb := &Pipeline{
        HttpParameters: httpParameters,
        Jenkins:        j,
        Path:           fmt.Sprintf(RunPipelineUrl, projectName, pipelineName),
    }
    res, err := PipelineOjb.RunPipeline()
    return res, err
}
```

**Step 4**：Pipeline 执行发送
```go
// pkg/simple/client/devops/jenkins/pipeline.go
func (p *Pipeline) RunPipeline() (*devops.RunPipeline, error) {
    res, err := p.Jenkins.SendPureRequest(p.Path, p.HttpParameters)
    // ...
}
```

**Step 5**：请求转发 + Token 转换
```go
// pkg/simple/client/devops/jenkins/pure_request.go
func (j *Jenkins) SendPureRequest(path string, httpParameters *devops.HttpParameters) ([]byte, error) {
    res, _, err := j.SendPureRequestWithHeaderResp(path, httpParameters)
    return res, err
}
```

**Step 6**：Jenkins 接收并处理
```
POST /blue/rest/organizations/jenkins/pipelines/{project}/pipelines/{pipeline}/runs/
Authorization: Basic base64(username:JWT_Token)
```

Jenkins 认证插件验证 Token → 识别用户身份 → 根据 Role Strategy 判断该 SID 是否有 `Item.Build` 权限 → 执行或拒绝。

### 7.2 请求透传的数据结构

`pkg/simple/client/devops/pipeline.go`：

```go
type HttpParameters struct {
    Method   string
    Header   http.Header
    Body     io.ReadCloser
    Form     url.Values
    PostForm url.Values
    Url      *url.URL
}
```

`pkg/models/devops/devops.go`：

```go
func convertToHttpParameters(req *http.Request) *devops.HttpParameters {
    return &devops.HttpParameters{
        Method:   req.Method,
        Header:   req.Header,      // <-- 完整保留，含 Authorization
        Body:     req.Body,
        Form:     req.Form,
        PostForm: req.PostForm,
        Url:      req.URL,
    }
}
```

### 7.3 管理员操作的例外

`pipeline.go:738-806` 的 `CheckCron` 方法中，**没有使用用户透传 Token**，而是直接使用固定管理员 Basic Auth：

```go
reqJenkins.SetBasicAuth(
    p.Jenkins.Requester.BasicAuth.Username,
    p.Jenkins.Requester.BasicAuth.Password,
)
```

这是因为该 Jenkins API 返回 HTML（非 JSON），需要特殊解析，且不涉及用户身份差异。

---

## 八、Crumb 防护与连接控制

### 8.1 Crumb（CSRF 防护）

Jenkins 默认启用 CSRF 防护，需要在 POST/PUT 请求中附加 Crumb。

`pkg/simple/client/devops/jenkins/request.go`：

```go
func (r *Requester) SetCrumb(jenkins *Jenkins) error {
    crumbData := map[string]string{}
    _, err := r.GetJSON("/crumbIssuer/api/json", &crumbData, nil)
    if err != nil {
        return err
    }
    r.Headers.Set(crumbData["crumbRequestField"], crumbData["crumb"])
    return nil
}
```

**工作流程**：
1. 首次 POST/PUT 前调用 `/crumbIssuer/api/json`
2. 获取 `crumbRequestField`（通常是 `Jenkins-Crumb`）和 `crumb` 值
3. 在后续请求头中自动附加

### 8.2 连接池控制

```go
type Requester struct {
    Base        string
    BasicAuth   *BasicAuth
    Client      *http.Client
    SslVerify   bool
    connControl chan struct{}  // 容量 = maxConnections
}
```

**限流逻辑**：
- 请求前：`connControl <- struct{}{}`（阻塞直到有可用槽位）
- 请求后：`<-connControl`（释放槽位）
- 默认最大连接数：通过 `--jenkins-max-connections` 配置

---

## 九、配置项汇总

### 9.1 Jenkins 连接配置

| 配置项 | 命令行参数 | 配置文件字段 | 说明 |
|--------|-----------|-------------|------|
| Host | `--jenkins-host` | `devops.host` | Jenkins 服务地址 |
| Username | `--jenkins-username` | `devops.username` | Jenkins 管理员用户名 |
| Password | `--jenkins-password` | `devops.password` | Jenkins 管理员密码/API Token |
| MaxConnections | `--jenkins-max-connections` | `devops.maxConnections` | 最大并发连接数 |
| Endpoint | - | `devops.endpoint` | ks-devops API Server 地址 |

### 9.2 关键常量

| 常量 | 值 | 位置 |
|------|-----|------|
| `KubesphereDevOpsNamespace` | `"kubesphere-devops-system"` | `pkg/constants/constants.go` |
| `UserNameHeader` | `"X-Token-Username"` | `pkg/constants/constants.go` |
| `GLOBAL_ROLE` | `"globalRoles"` | `pkg/simple/client/devops/jenkins/constants.go` |
| `PROJECT_ROLE` | `"projectRoles"` | `pkg/simple/client/devops/jenkins/constants.go` |

### 9.3 JWT Claims

`pkg/apiserver/authentication/token/issuer.go`：

```go
type Claims struct {
    Username          string              `json:"username,omitempty"`
    // ...
}
```

---

## 十、总结：完整授权流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              用户认证阶段                                    │
│                                                                             │
│   用户登录 KubeSphere ──→ 获取 JWT Bearer Token                             │
│   (通过 KubeSphere IAM / LDAP / OIDC)                                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼ Bearer Token
┌─────────────────────────────────────────────────────────────────────────────┐
│                          管理员操作通道                                      │
│   （KubeSphere → Jenkins，固定 Basic Auth）                                  │
│                                                                             │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────────────┐ │
│   │ Create Job  │    │ Assign Role │    │ Create/Update/Delete Credential │ │
│   │ Delete Job  │    │ Add User    │    │ Manage Folder                   │ │
│   └─────────────┘    └─────────────┘    └─────────────────────────────────┘ │
│                                                                             │
│   Auth: Basic base64(admin_username:admin_password)                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          用户操作通道                                        │
│   （用户 → KubeSphere → Jenkins，Bearer → Basic 转换）                       │
│                                                                             │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────────────┐ │
│   │ Run Pipeline│    │ View Log    │    │ Stop / Replay Pipeline          │ │
│   │ View Status │    │ Artifacts   │    │ List Runs / Nodes / Steps       │ │
│   └─────────────┘    └─────────────┘    └─────────────────────────────────┘ │
│                                                                             │
│   Step 1: 用户请求 KubeSphere API                                           │
│           Authorization: Bearer <JWT_Token>                                 │
│                                                                             │
│   Step 2: KubeSphere 透传 Header                                            │
│           convertToHttpParameters(req) 保留原始 Header                       │
│                                                                             │
│   Step 3: SetBasicBearTokenHeader 转换                                       │
│           提取 claim.Username                                               │
│           构造: Basic base64(username:JWT_Token)                            │
│                                                                             │
│   Step 4: Jenkins 接收请求                                                  │
│           Authorization: Basic <base64(username:JWT_Token)>                 │
│           Jenkins 认证插件验证 Token → 识别 SID                             │
│                                                                             │
│   Step 5: Role Strategy 鉴权                                                │
│           查询 SID 所属 Global/Project Role                                 │
│           判断是否有 Item.Build / Item.Read 等权限                          │
│           执行或返回 403                                                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 核心设计要点

| 要点 | 说明 |
|------|------|
| **双通道设计** | 管理操作用固定管理员账号，用户操作用 Token 透传 |
| **Token 转换** | Bearer Token → Basic Auth，实现 SSO |
| **SID 映射** | KubeSphere 用户名作为 Jenkins Role Strategy 的 SID |
| **平行权限** | Jenkins 维护独立的 Global/Project Role，不与 KubeSphere RBAC 直接复用 |
| **实时查询** | Pipeline 状态实时从 Jenkins 获取，不做本地缓存同步 |
| **连接保护** | 连接池限流 + Crumb CSRF 防护 |

---

> **相关文件速查表**
>
> | 主题 | 核心文件 |
> |------|---------|
> | Jenkins Client 初始化 | `pkg/simple/client/devops/jenkins/options.go` / `devops.go` / `jenkins.go` |
> | Bearer → Basic 转换 | `pkg/simple/client/devops/jenkins/request.go` |
> | 请求透传 | `pkg/simple/client/devops/jenkins/pure_request.go` |
> | Pipeline 运行时 | `pkg/simple/client/devops/jenkins/pipeline.go` |
> | 角色管理 | `pkg/simple/client/devops/jenkins/role.go` / `jenkins.go` |
> | 权限常量 | `pkg/simple/client/devops/role.go` / `jenkins/constants.go` |
> | DevOps 业务逻辑 | `pkg/models/devops/devops.go` |
> | CRD 定义 | `staging/src/kubesphere.io/api/devops/v1alpha3/*.go` |

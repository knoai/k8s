# KubeSphere-Jenkins 角色同步 Web 工具

> 一个轻量级 Web 工具，用于检测和修复 KubeSphere 用户在 Jenkins 中的角色同步问题。

## 功能特性

| 功能 | 说明 |
|------|------|
| 🔍 **自动扫描** | 自动对比 KubeSphere 用户列表和 Jenkins admin 角色 SID 列表 |
| 📊 **状态看板** | 实时展示总用户数、已同步数、缺失数 |
| 🔧 **一键修复** | 支持单个修复和批量修复所有缺失用户 |
| 🔎 **搜索过滤** | 支持按用户名搜索，按同步状态过滤 |
| 📋 **操作日志** | 记录每次修复操作的结果 |
| 🏥 **健康检查** | 自动检测 Jenkins 服务健康状态 |

## 项目结构

```
jenkins-role-sync-web/
├── main.py               # 主应用（FastAPI + 前端页面一体）
├── requirements.txt      # Python 依赖
├── Dockerfile            # 容器构建配置
├── k8s-deployment.yaml   # K8s 部署清单
└── README.md             # 本文档
```

## 快速开始

### 方式一：本地运行（开发调试）

```bash
# 1. 进入项目目录
cd tools/jenkins-role-sync-web

# 2. 安装依赖
pip install -r requirements.txt

# 3. 配置环境变量
export JENKINS_HOST="http://jenkins.kubesphere-devops-system:8080"
export JENKINS_USER="admin"
export JENKINS_PASS="your-password-or-api-token"

# 4. 启动服务
python main.py

# 5. 浏览器访问
open http://localhost:8080
```

### 方式二：Docker 运行

```bash
# 1. 构建镜像
docker build -t jenkins-role-sync-web:latest .

# 2. 运行容器
docker run -d \
  -p 8080:8080 \
  -e JENKINS_HOST="http://host.docker.internal:8080" \
  -e JENKINS_USER="admin" \
  -e JENKINS_PASS="your-password" \
  --name jenkins-sync \
  jenkins-role-sync-web:latest

# 3. 访问
open http://localhost:8080
```

### 方式三：部署到 Kubernetes（推荐）

```bash
# 1. 修改 k8s-deployment.yaml 中的 Jenkins 密码
# 找到 Secret 部分，将 YOUR_JENKINS_ADMIN_PASSWORD_OR_API_TOKEN 替换为实际密码

# 2. 部署到集群
kubectl apply -f k8s-deployment.yaml

# 3. 查看 Pod 状态
kubectl get pod -n kubesphere-system -l app=jenkins-role-sync-web

# 4. 端口转发访问（临时）
kubectl port-forward -n kubesphere-system svc/jenkins-role-sync-web 8080:80
open http://localhost:8080

# 5. 或配置 Ingress 后通过域名访问
```

## 环境变量配置

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `JENKINS_HOST` | `http://jenkins.kubesphere-devops-system:8080` | Jenkins 服务地址 |
| `JENKINS_USER` | `admin` | Jenkins 管理员用户名 |
| `JENKINS_PASS` | （空） | Jenkins 管理员密码或 API Token |
| `JENKINS_TIMEOUT` | `30` | Jenkins API 请求超时（秒） |
| `ROLE_NAME` | `admin` | 要检查和分配的角色名 |
| `ROLE_TYPE` | `globalRoles` | 角色类型（globalRoles/projectRoles） |
| `PORT` | `8080` | Web 服务监听端口 |

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/` | 前端页面 |
| GET | `/api/health` | 健康检查 |
| GET | `/api/users` | 获取用户同步状态（`force_refresh=true` 强制刷新） |
| POST | `/api/users/{username}/fix` | 修复单个用户 |
| POST | `/api/users/fix-all` | 批量修复所有缺失用户 |
| GET | `/api/logs` | 获取操作日志 |

## 使用流程

```
1. 打开 Web 页面
        │
        ▼
2. 查看状态看板（总用户数 / 已同步 / 缺失）
        │
        ▼
3. 点击 "刷新扫描" 获取最新数据
        │
        ▼
4. 查看用户列表，红色标记的为缺失角色用户
        │
        ▼
5. 选择修复方式：
   ├── 单个修复：点击用户行右侧的 "修复" 按钮
   └── 批量修复：点击顶部 "一键修复全部" 按钮
        │
        ▼
6. 修复完成后状态变为蓝色"已修复"，刷新后变为绿色"已同步"
```

## 界面截图说明

页面包含以下区域：

- **配置信息栏**：显示当前连接的 Jenkins 地址、用户、角色和健康状况
- **统计卡片**：总用户数、已同步数、缺失数（红色高亮）
- **操作工具栏**：刷新扫描、一键修复、搜索框
- **过滤标签**：全部 / 缺失角色 / 已同步
- **用户表格**：用户名、显示名、邮箱、状态、Jenkins 角色、操作按钮

## 注意事项

1. **权限要求**：
   - 工具需要 K8s `list users` 权限（iam.kubesphere.io/v1alpha2）
   - 需要 Jenkins 管理员账号的密码或 API Token
   - Jenkins 必须启用 Role Strategy 插件

2. **安全性**：
   - Jenkins 密码通过 K8s Secret 注入，不要在代码中硬编码
   - 建议通过 Ingress + HTTPS 暴露服务
   - 生产环境建议添加认证（如 OAuth Proxy）

3. **性能**：
   - 批量修复时默认间隔 0.5 秒，避免压垮 Jenkins
   - 扫描操作会缓存结果，可通过 `force_refresh` 强制刷新

4. **兼容性**：
   - 测试环境：KubeSphere 3.1.x / 3.2 + Jenkins 2.x
   - 要求 Jenkins 安装 Role-based Authorization Strategy 插件

## 故障排查

| 问题 | 排查方法 |
|------|---------|
| 页面显示 "无法连接到后端服务" | 检查 Pod 是否运行：`kubectl get pod -n kubesphere-system -l app=jenkins-role-sync-web` |
| Jenkins 状态显示 "异常" | 检查 JENKINS_HOST 是否可达，网络策略是否允许跨命名空间访问 |
| 扫描结果为空 | 检查 ServiceAccount 是否有读取 User CRD 的权限 |
| 修复失败 | 检查 JENKINS_PASS 是否正确，Jenkins 管理员是否有 Role Strategy 管理权限 |
| 403 Forbidden | Jenkins 安全 realm 可能拒绝了请求，检查 Jenkins 日志 |

## 扩展开发

如需扩展功能，可以修改 `main.py`：

- **支持项目角色同步**：修改 `ROLE_TYPE=projectRoles`，添加项目 ID 参数
- **添加定时任务**：集成 APScheduler 实现自动周期性扫描修复
- **增加通知功能**：修复完成后发送 Slack/邮件通知
- **添加更多角色支持**：不仅限于 admin 角色

## License

Apache 2.0

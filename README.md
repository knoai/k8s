# K8s 全栈学习与实践仓库

[![GitHub](https://img.shields.io/badge/GitHub-knoai%2Fk8s-blue)](https://github.com/knoai/k8s)

本仓库是一个围绕 **Kubernetes 云原生生态** 的系统性学习与实践资料库，涵盖 AI on K8s、集群监控、安全、平台工程、验收测试等多个方向，适合从入门到进阶的工程师、SRE、平台开发者使用。

> 📌 **核心理念**：理论 + 实践 + 工具化，所有资料均经过实际场景验证，并提供可直接运行的代码与配置。

---

## 📂 仓库结构

```
.
├── ai/                          # AI on K8s 技术栈与学习路线
├── check/                       # K8s 集群一键验收测试工具（已容器化 + Helm Chart 化）
├── monitor/                     # Kubernetes 全链路监控方案
├── platform-engineering-lab/    # 平台工程实验室（IDP / GitOps / FinOps / 多租户等）
├── safe/                        # K8s 安全学习路线与攻防资料
└── README.md                    # 本文件
```

---

## 🚀 各模块速览

### 1. `check/` — K8s 集群验收测试工具

**定位**：交付前或周期性巡检时，对 K8s 集群进行一键自动化验收。

**覆盖检查项**：
- 环境预检（kubectl、权限、连接性）
- 节点健康（Ready 率、压力状态）
- 核心组件（kube-system Pod、apiserver 延迟、etcd 健康）
- 网络功能（DNS、跨节点通信、DaemonSet 就绪）
- 存储供给（StorageClass、PVC 动态绑定）
- 调度策略（污点容忍、资源配额、并发压测）
- 安全基线（RBAC、NetworkPolicy、PodSecurity）
- 高可用（多 Master、etcd 成员健康）
- Operator/CRD 专项（CRD Established、Operator Pod Ready、CR 生命周期）
- 性能基准（iperf3 网络吞吐、调度并发压测）

**容器化 & Helm Chart 化特性**：
- 🐳 **容器镜像**：基于 Alpine，内置 `kubectl`、`jq`、`bash`
- 📦 **Helm Chart**：支持 Job（一次性验收）与 CronJob（定时巡检）双模式
- 🔐 **RBAC 自动创建**：ServiceAccount + ClusterRole，覆盖测试所需全部权限
- 🔔 **飞书通知**：验收完成后自动发送摘要卡片到飞书群
- 📤 **报告导出**：支持上传到 S3 / S3-Compatible 存储，或 HTTP POST 到自定义接口
- ⚙️ **ConfigMap 驱动配置**：所有开关、阈值通过 Helm Values 注入，无需重建镜像

**快速使用**：

```bash
# 构建镜像
cd check/
docker build -t k8s-acceptance:0.1.0 .

# 一次性验收
helm install acceptance-test ./charts/k8s-acceptance \
  --namespace k8s-acceptance --create-namespace

# 定时巡检 + 飞书通知 + S3 导出
helm install acceptance-cron ./charts/k8s-acceptance \
  --namespace k8s-acceptance --create-namespace \
  --set job.enabled=false \
  --set cronjob.enabled=true \
  --set cronjob.schedule="0 2 * * 1" \
  --set clusterName="prod-k8s" \
  --set notification.feishu.enabled=true \
  --set secrets.feishuWebhookUrl="https://open.feishu.cn/open-apis/bot/v2/hook/xxx" \
  --set export.s3.enabled=true \
  --set export.s3.endpoint="http://minio.example.com:9000" \
  --set export.s3.bucket="k8s-reports" \
  --set secrets.s3AccessKey="xxx" \
  --set secrets.s3SecretKey="yyy"
```

详见 [`check/charts/k8s-acceptance/README.md`](check/charts/k8s-acceptance/README.md)。

---

### 2. `monitor/` — Kubernetes 全链路监控方案

**技术栈**：OpenTelemetry + Prometheus + Grafana + eBPF

**覆盖层次**：
- 基础设施（节点资源、内核指标）
- K8s 编排层（Pod/Deployment/Service 指标、事件）
- 应用服务（JVM、Go、Python OTel 探针）
- 业务指标（自定义 Exporter、SLO/SLI）
- 网络可观测（Cilium Hubble、eBPF 网络流）

**内容**：
- 监控案例（Prometheus CRD、JVM 监控、Grafana 集成、全链路可观测）
- Dashboard 与告警规则（JSON + YAML）
- OTel Collector、Hubble eBPF 等核心组件的部署清单
- 排查手册与面试题

---

### 3. `platform-engineering-lab/` — 平台工程实验室

**定位**：从核心概念到生产实践的平台工程学习路线。

**包含模块**：
| 编号 | 主题 | 关键词 |
|------|------|--------|
| 01 | 核心概念 | 容器运行时、K8s 架构、资源模型 |
| 02 | K8s 进阶 | 网络深入、调度深入 |
| 03 | IDP 门户 | Backstage 搭建与使用 |
| 04 | GitOps | ArgoCD 深入、CI/CD 集成 |
| 05 | 多租户 | 隔离策略、Namespace as a Service |
| 06 | Policy as Code | Kyverno 实战 |
| 07 | 云资源管理 | Crossplane 实战 |
| 08 | FinOps | 成本优化 |
| 09 | 可观测性 | 监控栈构建 |
| 10 | 实践项目 | IDP 原型、延迟排查、中间件性能、JVM 诊断、Service Mesh、平台完整案例 |
| 11 | 生产排障 | apiserver/etcd/CNI/调度/数据库等真实故障案例 |
| 12 | 案例研究 | 字节、阿里、AWS、Netflix、银行合规等多行业平台案例 |
| 13 | 性能基准 | apiserver、etcd、CNI 等调参与压测 |
| 14 | 源码深入 | ArgoCD、Kyverno 控制器源码解析 |

---

### 4. `ai/` — AI on K8s 技术栈

**面向人群**：希望在 K8s 上运行 AI/ML 工作负载的工程师。

**内容覆盖**：
- 市场行情与招聘分析
- K8s + AI 技术栈全景（MLOps、LLM 部署、GPU 调度）
- 学习路线图（从基础到专家）
- 大模型部署实战、GPU 利用率优化
- 高可用架构设计、模型价值提升
- 面试求职指南

---

### 5. `safe/` — K8s 安全学习资料

**内容**：
- 完整学习路线与资料清单
- 教材：Linux/容器基础 → K8s 入门 → CKA → 平台安全 → 应用安全 → 运行时/网络安全 → DevSecOps → 高级架构
- 专题：隧道技术与攻防靶标、漏洞与攻防案例库、云厂商托管安全、容器逃逸、日志审计与 SIEM、Admission Webhook 开发、Helm 安全

---

## 🛠 快速开始

```bash
# 克隆仓库
git clone https://github.com/knoai/k8s.git
cd k8s

# 查看各模块详情
cat check/README.md
cat monitor/README.md
cat platform-engineering-lab/README.md
```

---

## 📌 提交规范

本仓库采用 [Conventional Commits](https://www.conventionalcommits.org/) 规范：

- `feat`: 新功能
- `fix`: 修复
- `docs`: 文档更新
- `refactor`: 重构
- `chore`: 构建/工具变动

---

## 📄 License

本仓库内容仅供学习交流使用，引用外部资料时遵循原作者许可协议。

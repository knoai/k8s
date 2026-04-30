# Kubernetes 安全学习资料清单（基础 → 专家）

> 整理时间：2026-04-27
> 范围：书籍、课程、文档、工具、靶场、认证、社区资源

---

## 一、认证考试资料

### 1.1 认证路径
| 顺序 | 认证 | 全称 | 前提 | 费用 | 有效期 |
|------|------|------|------|------|--------|
| 1 | KCNA | Kubernetes and Cloud Native Associate | 无 | $250 | 3年 |
| 2 | CKA | Certified Kubernetes Administrator | 无 | $395 | 3年 |
| 3 | CKS | Certified Kubernetes Security Specialist | 需持CKA | $395 | 2年 |

### 1.2 认证备考资料

| 资料名 | 类型 | 说明 | 获取方式 |
|--------|------|------|---------|
| CKA Exam Curriculum (v1.33) | 官方考纲 | Linux基金会发布的考试大纲 | cncf.io |
| CKS Exam Curriculum (v1.33) | 官方考纲 | 安全专项考试范围 | cncf.io |
| CKA Handbook | 官方手册 | 考试规则、环境说明 | cncf.io |
| Killer.sh | 模拟考试 | 官方合作模拟环境，8小时 | 买CKS赠送 |

---

## 二、按阶段学习书籍

### 阶段一：基础入门（Linux + 容器 + K8s）

| 书名 | 作者 | 出版社 | 难度 | 重点 |
|------|------|--------|------|------|
| 《鸟哥的Linux私房菜》 | 鸟哥 | 机械工业出版社 | ⭐⭐ | Linux系统管理基础 |
| 《Docker技术入门与实战》 | 杨保华 | 机械工业出版社 | ⭐⭐ | Docker容器基础 |
| 《Kubernetes权威指南》 | 龚正 等 | 电子工业出版社 | ⭐⭐⭐ | K8s中文经典入门 |
| 《The Kubernetes Book》 | Nigel Poulton | Leanpub | ⭐⭐ | 英文快速入门，每年更新 |

### 阶段二：CKA进阶（集群管理）

| 书名 | 作者 | 出版社 | 难度 | 重点 |
|------|------|--------|------|------|
| **《CKA Study Guide, 2nd Edition》** | Benjamin Muschko | O'Reilly | ⭐⭐⭐ | **2026新版，对齐v1.33考纲，必看** |
| 《Kubernetes: Up and Running, 3rd Ed》 | Brendan Burns等 | O'Reilly | ⭐⭐⭐ | K8s创始人撰写，权威参考 |
| 《Kubernetes in Action, 2nd Ed》 | Marko Lukša | Manning | ⭐⭐⭐⭐ | 深入理解内部机制 |

### 阶段三：CKS安全专项（核心阶段）

| 书名 | 作者 | 出版社 | 难度 | 重点 |
|------|------|--------|------|------|
| **《Learning Kubernetes Security, 2nd Ed》** | Raul Lapaz | Packt | ⭐⭐⭐⭐ | **2025新版，CKS备考核心** |
| **《Docker and Kubernetes Security》** | Mohammad-Ali A'rabi | - | ⭐⭐⭐⭐ | **2025年出版，供应链+运行时安全** |
| 《Kubernetes Security Guide》 | Liz Rice等 | O'Reilly | ⭐⭐⭐⭐ | 容器安全经典 |
| 《Container Security》 | Liz Rice | O'Reilly | ⭐⭐⭐ | 容器底层安全机制 |

### 阶段四：专家进阶

| 书名 | 作者 | 出版社 | 难度 | 重点 |
|------|------|--------|------|------|
| 《Kubernetes Best Practices, 2nd Ed》 | Brendan Burns等 | O'Reilly | ⭐⭐⭐⭐ | 生产环境最佳实践 |
| 《BPF Performance Tools》 | Brendan Gregg | Addison-Wesley | ⭐⭐⭐⭐⭐ | eBPF原理与编程 |
| 《Programming Kubernetes》 | M. Hausenblas等 | O'Reilly | ⭐⭐⭐⭐⭐ | K8s Operator开发 |
| 《Kubernetes Patterns》 | Bilgin Ibryam等 | O'Reilly | ⭐⭐⭐⭐ | 云原生设计模式 |

---

## 三、在线课程清单

### 3.1 付费课程（高价值）

| 平台 | 课程名 | 讲师/机构 | 适用阶段 | 特点 |
|------|--------|----------|---------|------|
| **KodeKloud** | CKA Certification Course | Mumshad | CKA备考 | 最推荐，自带实验环境 |
| **KodeKloud** | CKS Certification Course | Mumshad | CKS备考 | 覆盖全部考点，实操丰富 |
| **Udemy** | Kubernetes CKS 2025 | Kim Wuestkamp | CKS备考 | 更新及时，性价比高 |
| **Linux基金会** | LFS260: Kubernetes Security | 官方 | CKS备考 | 官方课程，含考试费套餐 |
| **51CTO学堂** | 云原生K8s安全专家CKS | 宽哥 | CKS备考 | 中文，送考试环境 |
| **Coursera** | Cloud Security Specialization | Google Cloud | 基础安全 | 系统性好 |

### 3.2 免费资源

| 资源 | 类型 | 说明 | 链接 |
|------|------|------|------|
| Kubernetes官方文档 | 文档 | 考试可查阅，最权威 | kubernetes.io/docs |
| Kubernetes Security SIG | 社区 | 安全特别兴趣组文档 | github.com/kubernetes/sig-security |
| Kubecampus.io | 免费课程 | Rancher提供的K8s免费课 | kubecampus.io |
| CNCF webinars | 视频 | 官方技术分享 | cncf.io/webinars |
| B站K8s教程 | 视频 | 中文免费资源 | 搜索"Kubernetes" |

---

## 四、官方文档与规范

| 文档名 | 说明 | 链接 |
|--------|------|------|
| Kubernetes官方文档 | 考试可查阅 | https://kubernetes.io/docs/ |
| Kubernetes Security文档 | 安全专题 | https://kubernetes.io/docs/concepts/security/ |
| CIS Kubernetes Benchmark | 安全基线标准 | https://www.cisecurity.org/benchmark/kubernetes |
| NSA/CISA K8s Hardening | 美国国安局加固指南 | https://media.defense.gov/ |
| NIST SP 800-190 | 容器安全指南 | https://csrc.nist.gov/ |
| OWASP Docker Top 10 | Docker安全风险 | https://owasp.org/www-project-docker-top-10/ |

---

## 五、安全工具清单（按功能分类）

### 5.1 镜像安全

| 工具 | 用途 | 开源 | 维护方 | 推荐指数 |
|------|------|------|--------|---------|
| **Trivy** | 镜像/文件系统/IaC漏洞扫描 | ✅ | Aqua Security | ⭐⭐⭐⭐⭐ |
| Grype | 基于SBOM的漏洞扫描 | ✅ | Anchore | ⭐⭐⭐⭐ |
| Clair | 镜像静态分析 | ✅ | Quay | ⭐⭐⭐ |
| Snyk | 依赖+容器扫描 | 部分免费 | Snyk | ⭐⭐⭐⭐ |

### 5.2 运行时安全

| 工具 | 用途 | 开源 | CNCF状态 | 推荐指数 |
|------|------|------|---------|---------|
| **Falco** | 系统调用异常检测 | ✅ | Graduated | ⭐⭐⭐⭐⭐ |
| **Tetragon** | eBPF可观测+执行控制 | ✅ | - | ⭐⭐⭐⭐⭐ |
| Sysdig | 容器监控+安全 | 部分免费 | - | ⭐⭐⭐⭐ |

### 5.3 策略引擎（准入控制）

| 工具 | 策略语言 | 开源 | CNCF状态 | 推荐指数 |
|------|---------|------|---------|---------|
| **Kyverno** | YAML原生 | ✅ | Incubating | ⭐⭐⭐⭐⭐ |
| **OPA/Gatekeeper** | Rego | ✅ | Graduated | ⭐⭐⭐⭐⭐ |
| jsPolicy | JavaScript | ✅ | - | ⭐⭐⭐ |

### 5.4 网络安全

| 工具 | 技术 | 开源 | CNCF状态 | 推荐指数 |
|------|------|------|---------|---------|
| **Cilium** | eBPF | ✅ | Graduated | ⭐⭐⭐⭐⭐ |
| Calico | iptables/BPF | ✅ | - | ⭐⭐⭐⭐ |
| Antrea | OVS | ✅ | Sandbox | ⭐⭐⭐ |

### 5.5 合规与态势管理

| 工具 | 用途 | 开源 | CNCF状态 | 推荐指数 |
|------|------|------|---------|---------|
| **Kubescape** | 综合态势+合规扫描 | ✅ | Incubating | ⭐⭐⭐⭐⭐ |
| **kube-bench** | CIS Benchmark检测 | ✅ | - | ⭐⭐⭐⭐⭐ |
| kube-hunter | 集群渗透测试 | ✅ | - | ⭐⭐⭐⭐ |

### 5.6 IaC与配置扫描

| 工具 | 用途 | 开源 | 推荐指数 |
|------|------|------|---------|
| **Checkov** | Terraform/CloudFormation/K8s扫描 | ✅ | ⭐⭐⭐⭐⭐ |
| KubeLinter | K8s YAML静态检查 | ✅ | ⭐⭐⭐⭐ |
| Terrascan | IaC安全扫描 | ✅ | ⭐⭐⭐ |

### 5.7 镜像签名与供应链

| 工具 | 用途 | 开源 | 推荐指数 |
|------|------|------|---------|
| **cosign** | 镜像签名验证 | ✅ | ⭐⭐⭐⭐⭐ |
| **Syft** | SBOM生成 | ✅ | ⭐⭐⭐⭐⭐ |
| Notary | 镜像信任 | ✅ | ⭐⭐⭐ |

---

## 六、实战靶场与实验环境

| 名称 | 类型 | 费用 | 说明 |
|------|------|------|------|
| **Killercoda** | 在线实验 | 免费 | 交互式K8s场景，推荐 |
| **Kubernetes Goat** | 漏洞靶场 | 免费 | 故意设计漏洞的K8s环境 |
| **BadPods** | 漏洞示例 | 免费 | GitHub: BishopFox/badpods |
| **KodeKloud Labs** | 付费实验 | 订阅 | CKA/CKS仿真环境 |
| **Play with Kubernetes** | 在线集群 | 免费 | 临时K8s实验环境 |
| **Kind** | 本地工具 | 免费 | 本地快速起多节点集群 |
| **minikube** | 本地工具 | 免费 | 单机K8s学习环境 |
| **k3s** | 本地工具 | 免费 | 轻量级K8s发行版 |

---

## 七、社区与资讯

| 名称 | 类型 | 说明 |
|------|------|------|
| CNCF Slack #kubernetes-security | 即时通讯 | K8s安全频道 |
| Kubernetes Security SIG | 官方社区 | 安全特性讨论 |
| Falco Slack | 即时通讯 | 运行时安全社区 |
| Cilium Slack | 即时通讯 | eBPF网络社区 |
| Trail of Bits Blog | 博客 | 顶尖安全公司容器安全研究 |
| Aqua Security Blog | 博客 | 容器安全前沿 |
| Sysdig Blog | 博客 | Falco与云安全 |
| ARMO Blog | 博客 | Kubescape与K8s安全 |
| Reddit r/kubernetes | 论坛 | K8s综合讨论 |
| Hacker News | 论坛 | 技术资讯 |

---

## 八、安全标准与合规框架

| 标准 | 适用场景 | 说明 |
|------|---------|------|
| **CIS Kubernetes Benchmark** | 通用 | 最流行的K8s安全基线 |
| **NSA/CISA K8s Hardening** | 政企 | 美国国安局加固指南 |
| **等保2.0** | 国内政企 | 中国网络安全等级保护 |
| **PCI DSS** | 金融支付 | 支付卡行业数据安全标准 |
| **SOC 2** | SaaS企业 | 服务组织控制报告 |
| **NIST 800-190** | 通用 | 容器安全指南 |
| **Pod Security Standards** | K8s内置 | Kubernetes官方安全标准 |

---

## 九、Go语言资源（K8s开发必备）

| 资源 | 类型 | 说明 |
|------|------|------|
| 《The Go Programming Language》 | 书籍 | Go语言权威教程 |
| client-go | 库 | K8s官方Go客户端 |
| Kubebuilder | 框架 | 开发K8s Operator |
| controller-runtime | 库 | 控制器运行时 |

---

## 十、快速启动Checklist

### 第一步：环境准备
- [ ] 安装 Docker
- [ ] 安装 minikube 或 kind
- [ ] 安装 kubectl
- [ ] 注册 Killercoda 账号

### 第二步：基础学习
- [ ] 完成 Docker 官方 Get Started
- [ ] 完成 Kubernetes 官方 tutorials
- [ ] 读完《CKA Study Guide》或同等级中文资料

### 第三步：安全专项
- [ ] 读完《Learning Kubernetes Security》
- [ ] 在 Killercoda 完成 RBAC/NetworkPolicy 实验
- [ ] 部署并配置 Falco
- [ ] 部署并配置 Trivy CI扫描
- [ ] 部署 Kyverno 或 OPA Gatekeeper

### 第四步：考试认证
- [ ] 报名 CKA 考试
- [ ] 完成 Killer.sh 模拟考试
- [ ] 通过 CKA
- [ ] 报名 CKS 考试
- [ ] 通过 CKS

### 第五步：专家进阶
- [ ] 阅读 eBPF 相关资料
- [ ] 编写自定义 Admission Webhook
- [ ] 完成 Kubernetes Goat 全部场景
- [ ] 参与开源项目贡献

---

> 💡 **使用建议**：按阶段顺序学习，每个阶段完成后进行实践验证。CKA/CKS 认证是求职硬通货，但真正的能力来自解决生产环境安全问题的实战经验。

# 知识库结构总览

```
k8s-monitor/
│
├── 📘 INDEX.md                              # 学习手册（基础→专家四级路径）
├── 📘 STRUCTURE.md                          # 本文档（结构总览）
├── 📘 README.md                             # 方案概述（架构+选型+部署）
├── 🔧 Makefile                              # 一键部署脚本
│
├── 📚 docs/                                 # 学习文档（核心）
│   │
│   ├── 🎯 00-market-analysis/
│   │   └── README.md                        # 招聘市场分析、技能矩阵、面试考点
│   │
│   ├── 🌱 01-fundamentals/                  # 基础篇（L1 初级）
│   │   ├── 01-kubernetes-monitoring-basics.md   # K8s监控概念、Prometheus/Grafana入门
│   │   └── 02-promql-basics.md                  # PromQL基础查询语法
│   │
│   ├── 🚀 02-intermediate/                  # 进阶篇（L2 中级）
│   │   ├── 01-opentelemetry-guide.md            # OpenTelemetry统一采集
│   │   ├── 02-logging-with-loki.md              # Loki日志系统
│   │   ├── 03-long-term-storage.md              # Thanos/VictoriaMetrics长期存储
│   │   └── 04-profiling.md                      # 持续性能剖析Pyroscope/Parca
│   │
│   ├── 🔥 03-advanced/                      # 精通篇（L3 高级）
│   │   ├── 01-ebpf-observability.md             # eBPF无侵入监控
│   │   ├── 02-promql-advanced.md                # 高级PromQL+SRE/SLO
│   │   ├── 03-production-practices.md           # 生产最佳实践
│   │   ├── 04-intelligent-alerting.md           # 智能告警与异常检测
│   │   └── 05-gpu-monitoring.md                 # GPU集群监控（AI Infra）
│   │
│   ├── 📋 04-cheatsheets/                   # 速查手册
│   │   ├── promql-cheatsheet.md                 # PromQL速查
│   │   ├── otel-collector-cheatsheet.md         # OTel Collector配置速查
│   │   └── kubectl-debug-cheatsheet.md          # K8s监控排障速查
│   │
│   ├── 💼 05-interview/                     # 面试与实战
│   │   ├── custom-exporter-dev.md               # 自定义Exporter/Collector开发
│   │   └── interview-questions.md               # 面试题精编
│   │
│   ├── ⚙️ 06-prometheus-crd-deep-dive/      # Prometheus CRD专项
│   │   └── 01-operator-crds.md                  # Operator CRD深入
│   │
│   ├── ☕ 07-jvm-monitoring/                # JVM监控专项
│   │   └── 01-jvm-metrics-deep-dive.md          # JVM采集与监控深度实战
│   │
│   ├── 📊 08-grafana-deep-dive/             # Grafana集成专项
│   │   └── 01-grafana-operator-provisioning.md  # Grafana Operator+Provisioning深入
│   │
│   ├── 📐 09-governance/                    # 可观测性治理 ⭐ 新增
│   │   └── README.md                            # 命名规范/标签规范/Dashboard规范/告警规范
│   │
│   ├── 🗄️ 10-middleware-monitoring/         # 中间件监控 ⭐ 新增
│   │   └── README.md                            # Redis/Kafka/MySQL/PostgreSQL/ES/MongoDB
│   │
│   ├── 🔄 11-gitops-cicd/                   # GitOps集成 ⭐ 新增
│   │   └── README.md                            # Kustomize/ArgoCD/监控即代码
│   │
│   └── 🔀 12-service-mesh/                  # Service Mesh监控 ⭐ 新增
│       └── README.md                            # Istio监控/Kiali/Ambient Mesh
│
├── 🔧 cases/                                # 实践案例
│   ├── case1-prometheus-crd/
│   │   └── README.md                        # 案例一：Prometheus CRD全栈实战
│   ├── case2-jvm-monitoring/
│   │   └── README.md                        # 案例二：JVM三种方式对比
│   ├── case3-grafana-integration/
│   │   └── README.md                        # 案例三：Grafana数据关联下钻
│   └── case4-fullstack-observability/
│       └── README.md                        # 案例四：微服务全链路可观测
│
├── 📦 manifests/                            # 部署清单
│   ├── otel-collector.yaml                  # OTel Collector DaemonSet+Service+RBAC
│   └── hubble-ebpf.yaml                     # Cilium Hubble部署
│
├── ⚠️ rules/                                # 告警规则
│   └── prometheus-alerts.yaml               # 节点/Pod/应用/控制面告警
│
├── 📊 dashboards/                           # Dashboard模板
│   └── grafana-k8s-overview.json            # K8s集群概览Dashboard
│
├── 💡 examples/                             # 应用接入示例
│   ├── app-java-otel.yaml                   # Java应用OTel Agent注入
│   └── app-go-otel.yaml                     # Go应用OTel SDK集成
│
└── 🛠️ scripts/                              # 工具脚本 ⭐ 新增
    ├── validate-setup.sh                    # 监控体系健康检查
    ├── load-test.sh                         # 压测脚本
    └── cleanup.sh                           # 环境清理脚本
```

---

## 按学习级别快速导航

### L1 初级工程师

| 序号 | 文档 | 说明 | 预估时间 |
|------|------|------|----------|
| 1 | `docs/00-market-analysis/README.md` | 了解招聘需求 | 30分钟 |
| 2 | `docs/01-fundamentals/01-kubernetes-monitoring-basics.md` | 监控基础概念 | 2小时 |
| 3 | `docs/01-fundamentals/02-promql-basics.md` | PromQL基础 | 3小时 |
| 4 | `docs/04-cheatsheets/promql-cheatsheet.md` | 日常速查 | 反复查阅 |
| 5 | `README.md` | 方案整体了解 | 30分钟 |
| 6 | `Makefile` | 一键部署实践 | 1小时 |

### L2 中级工程师

| 序号 | 文档 | 说明 | 预估时间 |
|------|------|------|----------|
| 7 | `docs/02-intermediate/01-opentelemetry-guide.md` | OTel统一采集 | 4小时 |
| 8 | `docs/02-intermediate/02-logging-with-loki.md` | Loki日志系统 | 3小时 |
| 9 | `docs/02-intermediate/03-long-term-storage.md` | 长期存储方案 | 3小时 |
| 10 | `docs/02-intermediate/04-profiling.md` | 性能剖析 | 3小时 |
| 11 | `examples/app-java-otel.yaml` | Java接入实践 | 1小时 |
| 12 | `examples/app-go-otel.yaml` | Go接入实践 | 1小时 |
| 13 | `manifests/otel-collector.yaml` | Collector部署 | 1小时 |
| 14 | `cases/case2-jvm-monitoring/README.md` | JVM三种方式对比 | 3小时 |
| 15 | `docs/10-middleware-monitoring/README.md` | 中间件监控 | 3小时 ⭐ |

### L3 高级工程师

| 序号 | 文档 | 说明 | 预估时间 |
|------|------|------|----------|
| 16 | `docs/03-advanced/01-ebpf-observability.md` | eBPF监控 | 4小时 |
| 17 | `docs/03-advanced/02-promql-advanced.md` | SLO工程 | 4小时 |
| 18 | `docs/03-advanced/03-production-practices.md` | 生产实践 | 4小时 |
| 19 | `docs/03-advanced/04-intelligent-alerting.md` | 智能告警 | 4小时 |
| 20 | `docs/03-advanced/05-gpu-monitoring.md` | GPU监控 | 3小时 |
| 21 | `docs/06-prometheus-crd-deep-dive/01-operator-crds.md` | CRD深入 | 4小时 |
| 22 | `docs/07-jvm-monitoring/01-jvm-metrics-deep-dive.md` | JVM深入 | 4小时 |
| 23 | `docs/08-grafana-deep-dive/01-grafana-operator-provisioning.md` | Grafana深入 | 4小时 |
| 24 | `docs/09-governance/README.md` | 可观测性治理 | 2小时 ⭐ |
| 25 | `docs/11-gitops-cicd/README.md` | GitOps集成 | 3小时 ⭐ |
| 26 | `docs/12-service-mesh/README.md` | Service Mesh | 3小时 ⭐ |
| 27 | `cases/case1-prometheus-crd/README.md` | CRD实战 | 3小时 |
| 28 | `cases/case3-grafana-integration/README.md` | 数据关联实战 | 3小时 |
| 29 | `rules/prometheus-alerts.yaml` | 告警规则实战 | 1小时 |
| 30 | `manifests/hubble-ebpf.yaml` | eBPF部署 | 1小时 |

### L4 专家

| 序号 | 文档 | 说明 | 预估时间 |
|------|------|------|----------|
| 31 | `docs/05-interview/custom-exporter-dev.md` | 自定义开发 | 6小时 |
| 32 | `docs/05-interview/interview-questions.md` | 面试题精编 | 4小时 |
| 33 | `cases/case4-fullstack-observability/README.md` | 综合大案例 | 1-2天 |
| 34 | `dashboards/grafana-k8s-overview.json` | Dashboard开发 | 2小时 |
| 35 | `scripts/validate-setup.sh` | 健康检查脚本 | 1小时 ⭐ |
| 36 | `scripts/load-test.sh` | 压测脚本 | 30分钟 ⭐ |

---

## 按主题快速导航

### 核心概念
- 监控基础 → `docs/01-fundamentals/01-kubernetes-monitoring-basics.md`
- PromQL语法 → `docs/01-fundamentals/02-promql-basics.md`
- 可观测性三大支柱 → `docs/02-intermediate/01-opentelemetry-guide.md`
- 治理规范 → `docs/09-governance/README.md` ⭐

### 组件部署
- OTelCollector → `manifests/otel-collector.yaml`
- eBPF(Hubble) → `manifests/hubble-ebpf.yaml`
- 一键部署 → `Makefile`
- 健康检查 → `scripts/validate-setup.sh` ⭐

### 告警规则
- 基础告警 → `rules/prometheus-alerts.yaml`
- 高级告警(PromQL) → `docs/03-advanced/02-promql-advanced.md`
- 智能告警 → `docs/03-advanced/04-intelligent-alerting.md`

### 应用接入
- Java(OTel) → `examples/app-java-otel.yaml`
- Go(OTel) → `examples/app-go-otel.yaml`
- JVM监控 → `docs/07-jvm-monitoring/01-jvm-metrics-deep-dive.md`

### 中间件监控
- Redis/Kafka/MySQL → `docs/10-middleware-monitoring/README.md` ⭐

### 进阶技术
- eBPF → `docs/03-advanced/01-ebpf-observability.md`
- Service Mesh → `docs/12-service-mesh/README.md` ⭐
- GitOps → `docs/11-gitops-cicd/README.md` ⭐
- GPU监控 → `docs/03-advanced/05-gpu-monitoring.md`

### 实践案例
- CRD实战 → `cases/case1-prometheus-crd/`
- JVM对比 → `cases/case2-jvm-monitoring/`
- 数据关联 → `cases/case3-grafana-integration/`
- 综合实战 → `cases/case4-fullstack-observability/`

### 工具脚本
- 健康检查 → `scripts/validate-setup.sh`
- 压测 → `scripts/load-test.sh`
- 清理 → `scripts/cleanup.sh`

---

## 文档依赖关系

```
L1 基础篇
  └── 01-kubernetes-monitoring-basics.md
       └── 02-promql-basics.md
            └── 04-cheatsheets/* (并行参考)

L2 进阶篇
  └── 01-opentelemetry-guide.md
       ├── 02-logging-with-loki.md (并行)
       ├── 03-long-term-storage.md (并行)
       └── 04-profiling.md (并行)
            ├── examples/* (实践)
            └── 10-middleware-monitoring/* (扩展)

L3 精通篇
  ├── 03-advanced/01-ebpf-observability.md
  ├── 03-advanced/02-promql-advanced.md
  ├── 03-advanced/03-production-practices.md
  ├── 03-advanced/04-intelligent-alerting.md
  ├── 03-advanced/05-gpu-monitoring.md
  ├── 06-prometheus-crd-deep-dive/01-operator-crds.md
  ├── 07-jvm-monitoring/01-jvm-metrics-deep-dive.md
  ├── 08-grafana-deep-dive/01-grafana-operator-provisioning.md
  ├── 09-governance/README.md (规范)
  ├── 11-gitops-cicd/README.md (流程)
  ├── 12-service-mesh/README.md (扩展)
  └── cases/* (综合实践)

L4 专家
  └── 05-interview/* (面试与开发)
       └── scripts/* (工具)
```

---

## 文件统计

| 类别 | 数量 | 说明 |
|------|------|------|
| 学习文档 | 23个 | docs/目录下，按级别组织 |
| 实践案例 | 4个 | cases/目录下，完整操作手册 |
| 部署清单 | 2个 | manifests/目录下，可直接apply |
| 告警规则 | 1个 | rules/目录下，PrometheusRule |
| Dashboard | 1个 | dashboards/目录下，Grafana JSON |
| 应用示例 | 2个 | examples/目录下，Java+Go |
| 速查手册 | 3个 | cheatsheets/目录下 |
| 工具脚本 | 3个 | scripts/目录下 ⭐ |
| **总文件数** | **39个** | |

---

## 如何使用本文档

1. **新手入门**：从 `INDEX.md` 开始，按 L1 → L2 → L3 → L4 顺序学习
2. **问题排查**：查看 `docs/04-cheatsheets/` 和 `cases/` 中的对应案例
3. **面试准备**：重点阅读 `docs/05-interview/` 和 `docs/00-market-analysis/`
4. **生产部署**：参考 `manifests/`、`rules/`、`Makefile`、`scripts/`
5. **团队规范**：参考 `docs/09-governance/README.md`
6. **快速查阅**：打开本文档，按主题找到对应文件路径

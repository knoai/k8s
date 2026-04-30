# K8s 全链路监控 - 完整学习手册（基础到专家）

> 本文档是整个知识库的导航和使用指南，按能力级别组织，帮助你系统性地从入门到专家。

---

## 📖 知识库总览

```
k8s-monitor/
├── INDEX.md                          ← 你在这里（本手册）
├── README.md                         ← 方案概述（快速了解）
├── Makefile                          ← 一键部署脚本
│
├── docs/                             ← 📚 学习文档（核心）
│   ├── 00-market-analysis/           ← 招聘市场分析
│   ├── 01-fundamentals/              ← 基础篇
│   ├── 02-intermediate/              ← 进阶篇
│   ├── 03-advanced/                  ← 精通篇
│   ├── 04-cheatsheets/               ← 速查手册
│   ├── 05-interview/                 ← 面试与实战
│   ├── 06-prometheus-crd-deep-dive/  ← CRD专项
│   ├── 07-jvm-monitoring/            ← JVM专项
│   └── 08-grafana-deep-dive/         ← Grafana专项
│
├── cases/                            ← 🔧 实践案例
│   ├── case1-prometheus-crd/         ← CRD全栈实战
│   ├── case2-jvm-monitoring/         ← JVM三种方式对比
│   ├── case3-grafana-integration/    ← 数据关联下钻
│   └── case4-fullstack-observability/← 微服务综合实战
│
├── manifests/                        ← 📦 部署清单
│   ├── otel-collector.yaml
│   └── hubble-ebpf.yaml
│
├── rules/                            ← ⚠️ 告警规则
│   └── prometheus-alerts.yaml
│
├── dashboards/                       ← 📊 Dashboard模板
│   └── grafana-k8s-overview.json
│
└── examples/                         ← 💡 应用接入示例
    ├── app-java-otel.yaml
    └── app-go-otel.yaml
```

---

## 🎯 四级能力模型

| 级别 | 目标 | 适合人群 | 预计时间 |
|------|------|----------|----------|
| **L1 初级** | 能部署监控，看懂 Dashboard | 运维新手、开发转运维 | 1-2 周 |
| **L2 中级** | 能配置采集，写 PromQL，搭告警 | SRE、DevOps 工程师 | 3-4 周 |
| **L3 高级** | 能设计架构，优化性能，排障 | 监控平台负责人 | 2-3 月 |
| **L4 专家** | 能开发组件，参与开源，主导标准 | 架构师、技术专家 | 持续 |

---

## 🌱 L1 初级工程师

### 能力定义
> 能够使用 Helm 部署监控组件，看懂 Grafana Dashboard，能执行基础查询，响应常规告警。

### 学习路径

```
第 1 步: 了解市场 → docs/00-market-analysis/README.md
         （30分钟了解招聘需求和技能方向）

第 2 步: 监控基础 → docs/01-fundamentals/01-kubernetes-monitoring-basics.md
         （掌握 Metrics/Logs/Traces 概念，四大黄金指标，RED/USE 方法）

第 3 步: PromQL 基础 → docs/01-fundamentals/02-promql-basics.md
         （数据类型、选择器、rate()、聚合操作符、直方图分位）

第 4 步: 速查手册 → docs/04-cheatsheets/
         （日常工作中反复查阅，加深记忆）
```

### 实践任务

```bash
# 任务 1: 一键部署监控栈
cd /Users/yu/Documents/it/k8s/monitor
make namespace
make prometheus
make grafana

# 任务 2: 导入 Dashboard
# 在 Grafana 中导入 ID: 6417 (K8s Cluster Monitoring)
# 导入 ID: 1860 (Node Exporter Full)

# 任务 3: 执行 10 个基础 PromQL 查询
# 见 docs/04-cheatsheets/promql-cheatsheet.md "实战查询示例" 部分
```

### 验证标准
- [ ] 能独立部署 kube-prometheus-stack
- [ ] 能解释 Counter/Gauge/Histogram/Summary 的区别
- [ ] 能编写 10 个常用 PromQL 查询
- [ ] 能看懂 Node Exporter 和 K8s Dashboard

---

## 🚀 L2 中级工程师

### 能力定义
> 能配置 OpenTelemetry 采集，掌握链路追踪，部署长期存储，搭建日志系统，编写告警规则。

### 学习路径

```
第 5 步: OpenTelemetry → docs/02-intermediate/01-opentelemetry-guide.md
          （掌握 Collector 架构、采样策略、Trace 上下文传播、多信号关联）

第 6 步: Loki 日志 → docs/02-intermediate/02-logging-with-loki.md
          （LogQL 查询、日志结构化、Promtail 配置）

第 7 步: 长期存储 → docs/02-intermediate/03-long-term-storage.md
          （Thanos/VictoriaMetrics 部署、Prometheus Remote Write、高基数问题）

第 8 步: 性能剖析 → docs/02-intermediate/04-profiling.md
          （Pyroscope/Parca 部署、火焰图解读、CPU/Memory Profile）
```

### 实践任务

```bash
# 任务 4: 部署 OTel Collector
kubectl apply -f manifests/otel-collector.yaml

# 任务 5: 为 Java 应用接入 OTel Agent
kubectl apply -f examples/app-java-otel.yaml

# 任务 6: 部署 Loki 并配置日志采集
make loki

# 任务 7: 部署 VictoriaMetrics
helm install vm grafana/victoria-metrics-single -n monitoring

# 任务 8: 案例二 - JVM 三种方式对比
cd cases/case2-jvm-monitoring
# 按 README 步骤执行，对比三种采集方式
```

### 验证标准
- [ ] 能独立部署 OTel Collector（DaemonSet + Gateway）
- [ ] 能为 Java/Go 应用接入自动埋点
- [ ] 能实现 Metrics → Trace → Logs 的关联查询
- [ ] 能部署 VictoriaMetrics 并配置 Remote Write
- [ ] 能看懂火焰图并定位热点函数

---

## 🔥 L3 高级工程师

### 能力定义
> 能设计监控架构，解决高基数/性能问题，掌握 eBPF，实现智能告警，GPU 监控，生产级优化。

### 学习路径

```
第 9 步: eBPF 监控 → docs/03-advanced/01-ebpf-observability.md
          （Hubble/Pixie/DeepFlow 部署、网络拓扑、无侵入追踪）

第 10 步: 高级 PromQL + SRE → docs/03-advanced/02-promql-advanced.md
           （预测告警、SLO/Error Budget、多窗口燃烧率、OpenSLO）

第 11 步: 生产最佳实践 → docs/03-advanced/03-production-practices.md
           （高可用架构、基数控制、存储分层、安全合规、成本优化）

第 12 步: 智能告警 → docs/03-advanced/04-intelligent-alerting.md
           （Prophet 动态阈值、Isolation Forest、根因分析、告警降噪）

第 13 步: GPU 监控 → docs/03-advanced/05-gpu-monitoring.md
           （DCGM、vLLM 指标、大模型推理 SLO、RDMA 网络）
```

### 专项深化（任选 1-2 个方向）

```
方向 A: Prometheus CRD 深入 → docs/06-prometheus-crd-deep-dive/
         （Operator CRD 全栈、relabel 原理、分片、Thanos Sidecar）

方向 B: JVM 监控深入 → docs/07-jvm-monitoring/
         （JMX Exporter/OTel Agent/Micrometer 对比、GC 调优、OOM 定位）

方向 C: Grafana 集成深入 → docs/08-grafana-deep-dive/
         （Operator CRD、Provisioning、Exemplars、插件开发）
```

### 实践任务

```bash
# 任务 9: 案例一 - CRD 全栈实战
cd cases/case1-prometheus-crd
# 手写 Prometheus + ServiceMonitor + PrometheusRule + Alertmanager

# 任务 10: 案例三 - Grafana 数据关联
cd cases/case3-grafana-integration
# 实现 Metrics → Trace → Logs 完整下钻

# 任务 11: 部署 Cilium + Hubble
make hubble
# 查看网络拓扑和服务依赖图

# 任务 12: 编写 SLO 告警
# 使用 docs/03-advanced/02-promql-advanced.md 中的多窗口燃烧率模板

# 任务 13: 动态阈值脚本
# 使用 docs/03-advanced/04-intelligent-alerting.md 中的 Prophet 示例
```

### 验证标准
- [ ] 能设计支撑 1000 节点 K8s 集群的监控架构
- [ ] 能解决 Prometheus 高基数导致的 OOM 问题
- [ ] 能编写 SLO 定义和燃烧率告警规则
- [ ] 能通过 Hubble 定位网络问题
- [ ] 能配置 GPU 监控和 vLLM 推理指标
- [ ] 能实现基于异常检测的智能告警

---

## 👑 L4 专家

### 能力定义
> 能开发监控组件，参与开源社区，主导可观测性标准，解决最复杂的性能问题。

### 学习路径

```
第 14 步: 自定义开发 → docs/05-interview/custom-exporter-dev.md
            （Go 编写 Exporter、OTel Collector Processor、Webhook 处理器）

第 15 步: 面试精编 → docs/05-interview/interview-questions.md
            （技术原理、场景设计、故障排查、编程实战）

第 16 步: 开源参与
            - 阅读 Prometheus/OTel 源码
            - 提交 PR（good-first-issue）
            - 撰写技术博客
```

### 实践任务

```bash
# 任务 14: 案例四 - 微服务全链路可观测
cd cases/case4-fullstack-observability
# 从零搭建 Metrics + Logs + Traces + Profiles 平台

# 任务 15: 自定义 Go Exporter
# 参考 docs/05-interview/custom-exporter-dev.md 编写业务指标 Exporter

# 任务 16: 模拟面试
# 回答 docs/05-interview/interview-questions.md 中的所有问题

# 任务 17: GitHub 开源项目
# 发布一个监控小工具（如自定义 Exporter、Alertmanager 处理器）
```

### 验证标准
- [ ] 能独立开发一个完整的 Prometheus Exporter
- [ ] 能深入解释 Prometheus TSDB 存储原理
- [ ] 能回答 90% 以上的面试题
- [ ] 在 GitHub 有可观测性相关的开源贡献
- [ ] 能主导团队的可观测性标准制定

---

## 📅 推荐学习计划

### 全职学习（每天 6-8 小时）

| 周次 | 级别 | 内容 |
|------|------|------|
| 第 1 周 | L1 | 基础文档 + PromQL + 一键部署 |
| 第 2 周 | L2 | OTel + Loki + VM + Profile |
| 第 3 周 | L2/L3 | 案例一 + 案例二 + 案例三 |
| 第 4 周 | L3 | eBPF + SLO + 智能告警 + GPU |
| 第 5 周 | L3/L4 | 案例四 + 专项深化（CRD/JVM/Grafana） |
| 第 6 周 | L4 | 自定义开发 + 面试准备 + 开源项目 |

### 业余学习（每天 2 小时）

| 阶段 | 时长 | 内容 |
|------|------|------|
| 阶段 1 | 2 周 | L1 基础 + PromQL |
| 阶段 2 | 3 周 | L2 OTel + Loki + VM |
| 阶段 3 | 4 周 | L3 eBPF + SLO + 生产实践 |
| 阶段 4 | 4 周 | 案例实践 + 面试题 |
| 阶段 5 | 持续 | 开源贡献 + 技术博客 |

---

## 🗂️ 按场景快速查找

### 我要部署...

| 目标 | 文档/文件 |
|------|----------|
| 一键部署全套监控 | `make all` |
| 部署 OTel Collector | `manifests/otel-collector.yaml` |
| 部署 eBPF 网络监控 | `manifests/hubble-ebpf.yaml` + `make hubble` |
| 部署 JVM 监控 | `examples/app-java-otel.yaml` |
| 部署 Go 应用监控 | `examples/app-go-otel.yaml` |

### 我要配置...

| 目标 | 文档 |
|------|------|
| Prometheus CRD | `docs/06-prometheus-crd-deep-dive/01-operator-crds.md` |
| 告警规则 | `rules/prometheus-alerts.yaml` |
| Grafana Dashboard | `dashboards/grafana-k8s-overview.json` |
| JVM 采集方式对比 | `docs/07-jvm-monitoring/01-jvm-metrics-deep-dive.md` |
| Grafana 数据源关联 | `docs/08-grafana-deep-dive/01-grafana-operator-provisioning.md` |

### 我要查询...

| 目标 | 文档 |
|------|------|
| PromQL 语法速查 | `docs/04-cheatsheets/promql-cheatsheet.md` |
| OTel Collector 配置速查 | `docs/04-cheatsheets/otel-collector-cheatsheet.md` |
| K8s 排障命令速查 | `docs/04-cheatsheets/kubectl-debug-cheatsheet.md` |

### 我要面试...

| 目标 | 文档 |
|------|------|
| 市场招聘分析 | `docs/00-market-analysis/README.md` |
| 面试题精编 | `docs/05-interview/interview-questions.md` |
| 编程实战 | `docs/05-interview/custom-exporter-dev.md` |

### 我要实战...

| 目标 | 文档 |
|------|------|
| CRD 全栈实战 | `cases/case1-prometheus-crd/README.md` |
| JVM 三种方式对比 | `cases/case2-jvm-monitoring/README.md` |
| 数据关联下钻 | `cases/case3-grafana-integration/README.md` |
| 微服务综合实战 | `cases/case4-fullstack-observability/README.md` |

---

## 💡 学习技巧

### 1. 先读后做
每个文档的阅读顺序：
1. 快速浏览标题和架构图（5 分钟）
2. 精读核心概念和配置（30 分钟）
3. 动手实践案例（1-2 小时）
4. 回顾总结输出笔记（30 分钟）

### 2. 输出倒逼输入
- 每学完一个阶段，写一篇技术博客
- 在团队内部分享（哪怕只是给同事讲 10 分钟）
- 整理自己的速查表

### 3. 问题驱动
不要从头到尾线性阅读，遇到实际问题再查文档：
- "Prometheus OOM 了" → 查生产实践 + 长期存储
- "Java 应用 GC 频繁" → 查 JVM 监控 + 告警规则
- "告警太多太吵" → 查智能告警 + Alertmanager 配置

### 4. 构建自己的知识库
建议 fork 这个仓库，添加：
- 你公司的实际配置（脱敏后）
- 你遇到的故障案例和解决方案
- 你自己的面试题答案

---

## 🏆 能力自测表

复制以下表格，定期自测：

```markdown
| 能力项 | L1 | L2 | L3 | L4 | 当前水平 |
|--------|----|----|----|----|----------|
| 部署 Prometheus + Grafana | ☐ | | | | |
| 编写 PromQL 基础查询 | ☐ | | | | |
| 配置 ServiceMonitor | | ☐ | | | |
| 部署 OTel Collector | | ☐ | | | |
| 应用接入链路追踪 | | ☐ | | | |
| 配置 Loki 日志采集 | | ☐ | | | |
| 部署 VM/Thanos 长期存储 | | ☐ | | | |
| 性能剖析与火焰图 | | ☐ | | | |
| Prometheus CRD 深入 | | | ☐ | | |
| eBPF 网络监控 | | | ☐ | | |
| SLO/Error Budget | | | ☐ | | |
| 智能告警与异常检测 | | | ☐ | | |
| GPU 集群监控 | | | ☐ | | |
| 自定义 Exporter 开发 | | | | ☐ | |
| 开源社区贡献 | | | | ☐ | |
```

---

## 📚 扩展阅读

### 官方文档
- [Prometheus 官方文档](https://prometheus.io/docs/)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [OpenTelemetry 官方文档](https://opentelemetry.io/docs/)
- [Grafana 官方文档](https://grafana.com/docs/)
- [Cilium 官方文档](https://docs.cilium.io/)

### 经典书籍
- 《Google SRE 运维解密》
- 《Learning eBPF》- Liz Rice (O'Reilly)
- 《BPF Performance Tools》- Brendan Gregg

### 社区资源
- [CNCF Observability Whitepaper](https://github.com/cncf/tag-observability)
- [OpenSLO 规范](https://openslo.com/)

---

## 更新日志

| 日期 | 内容 |
|------|------|
| 2024-01 | 初始版本：方案设计 + 基础文档 |
| 2024-02 | 深化版本：市场分析 + 长期存储 + Profiling + GPU |
| 2024-03 | 深化版本：CRD 深入 + JVM 监控 + Grafana 集成 |
| 2024-04 | 实战版本：4 个完整案例 + 学习手册 |

---

> **最后建议**：不要试图一次学完所有内容。根据你当前的级别，选择对应的内容开始，边学边用，在实践中成长。

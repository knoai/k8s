# K8s 全链路监控学习路径

> 从基础到精通的系统性技术资料，结合市场招聘要求深化，按学习阶段分类整理。

---

## 学习路线图

```
Phase 0: 市场认知 (先读后学)
├── 00-market-analysis/README.md          # 招聘市场分析、技能矩阵、面试考点

Phase 1: 基础篇 (1-2 周)
├── 01-fundamentals/
│   ├── 01-kubernetes-monitoring-basics.md    # K8s 监控概念、Prometheus/Grafana 入门
│   └── 02-promql-basics.md                   # PromQL 基础查询语法

Phase 2: 进阶篇 (2-4 周)
├── 02-intermediate/
│   ├── 01-opentelemetry-guide.md             # OpenTelemetry 统一采集
│   ├── 02-logging-with-loki.md               # Loki 日志系统
│   ├── 03-long-term-storage.md               # Thanos/VictoriaMetrics 长期存储
│   └── 04-profiling.md                       # 持续性能剖析 Pyroscope/Parca

Phase 3: 精通篇 (持续学习)
├── 03-advanced/
│   ├── 01-ebpf-observability.md              # eBPF 无侵入监控
│   ├── 02-promql-advanced.md                 # 高级 PromQL + SRE/SLO
│   ├── 03-production-practices.md            # 生产最佳实践
│   ├── 04-intelligent-alerting.md            # 智能告警与异常检测
│   └── 05-gpu-monitoring.md                  # GPU 集群监控（AI Infra）

Phase 4: 专项深化 ⭐ 新增
├── 06-prometheus-crd-deep-dive/
│   └── 01-operator-crds.md                   # Prometheus Operator CRD 深入
├── 07-jvm-monitoring/
│   └── 01-jvm-metrics-deep-dive.md           # JVM 采集与监控深度实战
├── 08-grafana-deep-dive/
│   └── 01-grafana-operator-provisioning.md   # Grafana Operator + Provisioning 深入

Phase 5: 网络知识体系 ⭐ 新增（核心补齐）
├── 13-networking/
│   ├── 01-network-fundamentals/              # TCP/IP、OSI、协议详解
│   ├── 02-linux-networking/                  # Linux 网络栈、netfilter、namespace
│   ├── 03-container-networking/              # veth、bridge、CNI
│   ├── 04-k8s-networking/                    # Service、kube-proxy、DNS、Ingress
│   ├── 05-cni-deep-dive/                     # Flannel/Calico/Cilium 深入
│   ├── 06-advanced-networking/               # BGP、VXLAN、DPDK、RDMA
│   ├── 07-network-troubleshooting/           # 排障方法论、工具链实战
│   ├── 08-network-observability/             # eBPF 监控、Hubble、网络 SLO
│   ├── 09-network-security/                  # NetworkPolicy、零信任、mTLS
│   ├── 10-harvester-networking/              # Harvester Access/Trunk 模式
│   └── 11-vlan-iptables-ebpf/                # VLAN/iptables/eBPF 对比演进

Phase 6: 长期存储与 CNI 深入 ⭐ 新增
├── 14-thanos-deep-dive/
│   └── README.md                             # Thanos 架构/组件/部署/优化
├── 15-victoriametrics-deep-dive/
│   └── README.md                             # VictoriaMetrics 单节点/集群/性能
└── 16-cilium-deep-dive/
    └── README.md                             # Cilium eBPF 数据平面/策略/Hubble

Phase 7: SRE 与智能运维 ⭐ 新增
├── 17-slo-sre/
│   └── README.md                             # SLI/SLO/SLA、错误预算、燃烧率告警
└── 18-aiops/
    └── README.md                             # 异常检测算法、告警降噪、Prophet、RCA

Phase 6: 面试与实战
├── 05-interview/
│   ├── custom-exporter-dev.md                # 自定义 Exporter/Collector 开发
│   └── interview-questions.md                # 面试题精编（原理/场景/排查/编程）

速查手册 (日常参考)
├── 04-cheatsheets/
│   ├── promql-cheatsheet.md                  # PromQL 速查
│   ├── otel-collector-cheatsheet.md          # OTel Collector 配置速查
│   └── kubectl-debug-cheatsheet.md           # K8s 监控排障速查
```

---

## 各阶段学习目标

### Phase 0: 市场认知 ⭐ 新增

**目标**：了解市场需求，明确学习方向和简历关键词

- [ ] 阅读市场招聘分析，了解岗位画像和薪资范围
- [ ] 对照技能矩阵，评估自身水平
- [ ] 明确差异化竞争力方向（深度专家 / AI Infra / 平台工程）
- [ ] 优化简历关键词

### Phase 1: 基础篇

**目标**：掌握 K8s 监控的核心概念和基础工具

- [ ] 理解 Metrics/Logs/Traces 三种信号
- [ ] 掌握 Prometheus 架构和指标类型
- [ ] 能够使用 Helm 部署 Prometheus + Grafana
- [ ] 熟练编写 PromQL 基础查询
- [ ] 导入和使用 Dashboard

**实践任务**：
1. 在测试集群部署 `kube-prometheus-stack`
2. 导入 Node Exporter 和 K8s 集群 Dashboard
3. 编写 10 个常用 PromQL 查询
4. 配置 3 条基础告警规则

### Phase 2: 进阶篇 ⭐ 深化

**目标**：构建统一的可观测性平台，掌握招聘高频技能

- [ ] 理解 OpenTelemetry 架构和三大信号
- [ ] 部署和配置 OpenTelemetry Collector
- [ ] 掌握链路追踪的上下文传播
- [ ] 理解采样策略（头部/尾部采样）
- [ ] 掌握 Loki 日志采集和 LogQL 查询
- [ ] **熟悉 VictoriaMetrics/Thanos 长期存储方案** ⭐
- [ ] **掌握持续性能剖析（Profiling）** ⭐
- [ ] 实现 Metrics + Logs + Traces 的关联

**实践任务**：
1. 部署 OTel Collector（DaemonSet + Gateway）
2. 为一个 Java/Go 应用接入自动埋点
3. 部署 Loki 并配置日志采集
4. **部署 VictoriaMetrics，配置 Prometheus Remote Write** ⭐
5. **部署 Pyroscope，采集应用 CPU/Memory Profile** ⭐
6. 在 Grafana 中实现从 Metrics → Trace → Logs → Profile 的下钻

### Phase 3: 精通篇 ⭐ 大量新增

**目标**：掌握生产级监控架构和高级技术，达到高级岗位水平

- [ ] 理解 eBPF 原理和适用场景
- [ ] 部署 Cilium + Hubble 网络可观测
- [ ] 掌握高级 PromQL 和预测告警
- [ ] 理解 SLO/Error Budget 工程
- [ ] 掌握告警降噪和多窗口燃烧率
- [ ] 掌握生产环境的性能优化和成本控制
- [ ] **掌握智能告警与异常检测算法** ⭐
- [ ] **掌握 GPU 集群监控（DCGM/vLLM）** ⭐

**实践任务**：
1. 部署 Cilium + Hubble，查看网络拓扑
2. 编写 SLO 定义和燃烧率告警
3. 设计监控系统的高可用架构
4. **实现一个基于 Prophet 的动态阈值告警脚本** ⭐
5. **部署 DCGM Exporter，配置 GPU 告警规则** ⭐
6. 进行一次完整的故障演练

### Phase 4: 网络知识体系 ⭐ 核心补齐

**目标**：补足网络知识短板，从 TCP/IP 基础到 Cilium eBPF，建立完整网络认知

- [ ] **理解 TCP/IP 协议栈（OSI、三次握手、连接状态）** ⭐
- [ ] **理解 Linux 网络栈（sk_buff、netfilter、namespace）** ⭐
- [ ] **理解容器网络（veth、bridge、CNI）** ⭐
- [ ] **理解 K8s 网络（Service、kube-proxy、DNS）** ⭐
- [ ] **掌握 CNI 插件选型（Flannel/Calico/Cilium）** ⭐
- [ ] **掌握网络排障方法论和工具链** ⭐
- [ ] **理解 eBPF 网络可观测性（Hubble）** ⭐
- [ ] **掌握 NetworkPolicy 和零信任安全** ⭐
- [ ] 了解高级网络技术（BGP、VXLAN、DPDK、RDMA）⭐

**实践任务**：
1. **手动创建 veth pair + bridge，理解容器网络原理** ⭐
2. **使用 tcpdump 抓包分析 TCP 三次握手/四次挥手** ⭐
3. **对比 iptables 和 ipvs 模式下的 Service 访问路径** ⭐
4. **部署 Flannel/Calico/Cilium，对比网络策略实现差异** ⭐
5. **使用 Hubble 观察 Pod 间流量拓扑** ⭐
6. **编写 NetworkPolicy，使用 Cilium 监控策略效果** ⭐
7. **模拟网络故障（MTU、conntrack 满、DNS 超时）并排查** ⭐

### Phase 5: 专项深化 ⭐ 本次新增

**目标**：深入掌握 Prometheus CRD、JVM 监控、Grafana 集成三个高频面试方向

- [ ] **深入理解 Prometheus Operator 所有 CRD** ⭐
  - Prometheus / ServiceMonitor / PodMonitor / PrometheusRule / Alertmanager / Probe
  - relabelings vs metricRelabelings 的区别
  - 多副本分片（Sharding）配置
  - Thanos Sidecar 集成
- [ ] **精通 JVM 指标采集与调优** ⭐
  - JMX Exporter（Agent 和独立进程模式）
  - OTel Java Agent 自动埋点
  - Micrometer 代码埋点（Spring Boot）
  - GC 指标分析与内存泄漏检测
  - JVM 告警规则精编
- [ ] **精通 Grafana 声明式配置** ⭐
  - Grafana Operator CRD（Grafana / GrafanaDatasource / GrafanaDashboard）
  - Provisioning（数据源 / Dashboard / 告警规则即代码）
  - 高级变量用法与数据关联（Metrics → Trace → Logs）
  - Exemplars 关联与下钻

**实践任务**：
1. **手写一套完整的 Prometheus Operator CRD（含 ServiceMonitor + PrometheusRule + AlertmanagerConfig）** ⭐
2. **部署一个 Spring Boot 应用，分别用 JMX Exporter、OTel Agent、Micrometer 三种方式采集 JVM 指标** ⭐
3. **使用 Grafana Operator + Provisioning 管理全部 Dashboard 和数据源** ⭐
4. 实现 Metrics → Trace → Logs 的完整数据关联下钻

### Phase 6: 面试与实战 ⭐ 新增

**目标**：具备独立开发能力和面试竞争力

- [ ] **能用 Go 编写自定义 Prometheus Exporter** ⭐
- [ ] **能用 Go 开发自定义 OTel Collector Processor** ⭐
- [ ] 掌握面试高频技术原理
- [ ] 能够设计大规模监控方案
- [ ] 具备系统故障排查思维

**实践任务**：
1. 用 Go 实现一个业务指标 Exporter
2. 实现 Alertmanager Webhook 告警处理器
3. 模拟面试：回答 20 道面试题
4. 在 GitHub 发布一个开源监控小工具

---

## 市场技能矩阵对照

| 技能领域 | 初级（1-3年） | 中级（3-5年） | 高级（5年+） |
|----------|---------------|---------------|--------------|
| **Prometheus** | 部署配置、基础查询 | Recording Rules、联邦、长期存储 | TSDB 原理、源码级优化、二次开发 |
| **Prometheus Operator** | Helm 一键部署 | ServiceMonitor/PrometheusRule 配置 | CRD 全栈深入、Controller 原理、多集群联邦 |
| **Grafana** | Dashboard 导入使用 | 自定义面板、变量、Alert | Operator、Provisioning、插件开发 |
| **OTel** | SDK 接入、基础配置 | Collector 定制、采样策略 | 协议实现、高性能 Agent 开发 |
| **eBPF** | 了解概念、使用工具 | bpftrace、Hubble 使用 | 编写 eBPF 程序、CO-RE |
| **K8s** | 基础资源管理 | Operator 开发、调度优化 | 源码理解、Controller 开发 |
| **JVM 监控** | 了解 JMX | JMX Exporter / OTel Agent 部署 | 三种采集方式对比、GC 调优、内存泄漏定位 |
| **编程** | Shell/Python 脚本 | Go 开发 Exporter | C++/Go 高性能组件开发 |
| **Profiling** | 了解概念 | Pyroscope 使用 | 火焰图分析、性能优化 |
| **GPU 监控** | 了解 DCGM | 部署 GPU Exporter | 大模型推理监控、性能调优 |
| **智能告警** | 静态阈值 | 动态阈值、SLO | AIOps、异常检测算法 |
| **SRE** | 响应告警、故障处理 | SLO 定义、On-call 优化 | 混沌工程、容量规划 |

---

## 差异化竞争力构建

### 方向一：深度技术专家（适合大厂基础架构）
- [ ] 深入 Prometheus/OTel 源码，提交 PR
- [ ] 参与 Cilium/eBPF 社区
- [ ] 发表技术博客/演讲
- [ ] 掌握 C++/Go 高性能组件开发

### 方向二：AI Infra 专项（适合 AI 公司）⭐ 热门
- [ ] 学习 GPU 监控（DCGM、NVML）
- [ ] 大模型推理框架（vLLM、TensorRT-LLM）
- [ ] AI 训练链路追踪
- [ ] RDMA/InfiniBand 网络监控

### 方向三：平台工程（适合中型公司）
- [ ] 可观测性平台产品化能力
- [ ] 多租户、成本优化（FinOps）
- [ ] 低代码 Dashboard/告警配置
- [ ] 智能告警与 AIOps

---

## 简历关键词优化

```
必写关键词：
  Prometheus、Grafana、Kubernetes、OpenTelemetry、Go

重要关键词（提升通过率）：
  eBPF、Thanos、VictoriaMetrics、Cilium、SLO、Profiling

专项关键词（深化方向）：
  Prometheus Operator、JVM 监控、Grafana Provisioning、
  ServiceMonitor、PrometheusRule、JMX Exporter、Micrometer

网络专项关键词：
  CNI、Calico、Cilium、eBPF、Hubble、VXLAN、BGP、NetworkPolicy、
  iptables、netfilter、TCP/IP、Linux 网络栈、mTLS、零信任

加分关键词（脱颖而出）：
  开源贡献、GPU监控、大模型、CNCF项目、AIOps、异常检测
```

---

## 实践 checklist

### 部署验证
- [ ] Prometheus 正常采集所有 targets
- [ ] Grafana Dashboard 显示正常
- [ ] Alertmanager 告警通知可达
- [ ] Loki 日志可正常查询
- [ ] Tempo 链路可正常查询
- [ ] OTel Collector 无报错
- [ ] eBPF Agent 正常运行
- [ ] VictoriaMetrics/Thanos 长期存储正常 ⭐
- [ ] Pyroscope Profile 可查看 ⭐
- [ ] DCGM GPU 指标正常采集 ⭐

### Prometheus CRD 深化验证 ⭐ 新增
- [ ] 手写 Prometheus CRD（含 remoteWrite、storage、 affinity）
- [ ] 手写 ServiceMonitor（含 relabelings、metricRelabelings）
- [ ] 手写 PodMonitor（采集 Envoy Sidecar 指标）
- [ ] 手写 PrometheusRule（含 Recording Rules + Alert Rules）
- [ ] 手写 Alertmanager 路由配置（多级路由 + 抑制）
- [ ] 配置 Probe（Blackbox 探测外部服务）

### JVM 采集验证 ⭐ 新增
- [ ] Spring Boot 应用部署 JMX Exporter
- [ ] Spring Boot 应用部署 OTel Java Agent
- [ ] Spring Boot 应用集成 Micrometer
- [ ] 三种方式采集的指标对比
- [ ] JVM 告警规则生效（堆内存、GC、线程）
- [ ] JVM Dashboard 正常显示

### Grafana 集成验证 ⭐ 新增
- [ ] Grafana Operator 部署
- [ ] GrafanaDatasource CRD 配置所有数据源
- [ ] GrafanaDashboard CRD 自动加载 Dashboard
- [ ] Provisioning 管理全部配置
- [ ] Exemplars 关联跳转到 Trace
- [ ] Trace 关联跳转到 Logs

### 数据关联验证
- [ ] Metrics 中点击 Exemplar 可跳转到 Trace
- [ ] Trace 详情中可查看相关日志
- [ ] 日志中包含 TraceID
- [ ] 告警消息附带 Trace/日志链接
- [ ] Grafana 可查看 CPU/Memory 火焰图 ⭐

### 故障演练
- [ ] 模拟 Pod OOM，验证告警和排查流程
- [ ] 模拟节点宕机，验证告警抑制生效
- [ ] 模拟服务延迟升高，验证链路追踪定位
- [ ] 模拟网络策略误配，验证 Hubble 发现
- [ ] 模拟 GPU ECC 错误，验证 DCGM 告警 ⭐
- [ ] 模拟 JVM Full GC，验证 JVM 告警 ⭐
- [ ] **模拟 MTU 问题，验证网络分片/丢包排查** ⭐
- [ ] **模拟 conntrack 表满，验证连接异常排查** ⭐
- [ ] **模拟 DNS 解析失败，验证 CoreDNS 排障** ⭐
- [ ] **模拟 Service 访问不通，验证 kube-proxy 排障** ⭐

### 开发能力验证 ⭐
- [ ] 用 Go 编写自定义 Exporter
- [ ] 实现 Alertmanager Webhook 处理器
- [ ] 编写动态阈值告警脚本
- [ ] GitHub 发布一个监控相关项目

---

## 参考资源

### 官方文档
- [Prometheus 官方文档](https://prometheus.io/docs/introduction/overview/)
- [Prometheus Operator 文档](https://prometheus-operator.dev/)
- [Grafana 官方文档](https://grafana.com/docs/)
- [Grafana Operator](https://grafana.github.io/grafana-operator/)
- [OpenTelemetry 官方文档](https://opentelemetry.io/docs/)
- [Loki 官方文档](https://grafana.com/docs/loki/latest/)
- [Thanos 官方文档](https://thanos.io/)
- [VictoriaMetrics 文档](https://docs.victoriametrics.com/)
- [Cilium 官方文档](https://docs.cilium.io/)
- [NVIDIA DCGM 文档](https://developer.nvidia.com/dcgm)
- [JMX Exporter](https://github.com/prometheus/jmx_exporter)
- [Micrometer 文档](https://micrometer.io/docs)

### 经典书籍
- 《Google SRE 运维解密》- SRE 圣经
- 《Learning eBPF》- Liz Rice (O'Reilly, 2023)
- 《BPF Performance Tools》- Brendan Gregg

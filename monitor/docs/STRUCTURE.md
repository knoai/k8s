# 项目结构总览

> 完整的文件索引和快速导航。

---

## 目录树

```
docs/
├── README.md                              # 学习路线总览（主入口）
├── STRUCTURE.md                           # 本文件
│
├── 00-market-analysis/
│   └── README.md                          # 招聘市场分析与技能矩阵
│
├── 01-fundamentals/
│   ├── 01-kubernetes-monitoring-basics.md # K8s 监控基础概念
│   └── 02-promql-basics.md                # PromQL 基础查询语法
│
├── 02-intermediate/
│   ├── 01-opentelemetry-guide.md          # OpenTelemetry 统一采集
│   ├── 02-logging-with-loki.md            # Loki 日志系统
│   ├── 03-long-term-storage.md            # Thanos/VictoriaMetrics 长期存储
│   └── 04-profiling.md                    # 持续性能剖析
│
├── 03-advanced/
│   ├── 01-ebpf-observability.md           # eBPF 无侵入监控
│   ├── 02-promql-advanced.md              # 高级 PromQL + SRE/SLO
│   ├── 03-production-practices.md         # 生产最佳实践
│   ├── 04-intelligent-alerting.md         # 智能告警与异常检测
│   └── 05-gpu-monitoring.md               # GPU 集群监控
│
├── 04-cheatsheets/
│   ├── promql-cheatsheet.md               # PromQL 速查手册
│   ├── otel-collector-cheatsheet.md       # OTel Collector 配置速查
│   └── kubectl-debug-cheatsheet.md        # K8s 监控排障速查
│
├── 05-interview/
│   ├── custom-exporter-dev.md             # 自定义 Exporter/Collector 开发
│   └── interview-questions.md             # 面试题精编
│
├── 06-prometheus-crd-deep-dive/
│   └── 01-operator-crds.md                # Prometheus Operator CRD 深入
│
├── 07-jvm-monitoring/
│   └── 01-jvm-metrics-deep-dive.md        # JVM 三种采集方式深度对比
│
├── 08-grafana-deep-dive/
│   └── 01-grafana-operator-provisioning.md # Grafana Operator + Provisioning
│
├── 09-observability-governance/
│   └── README.md                          # 可观测性治理规范
│
├── 10-middleware-monitoring/
│   └── README.md                          # 中间件监控（Redis/Kafka/MySQL/ES/MongoDB）
│
├── 11-gitops-monitoring-as-code/
│   └── README.md                          # GitOps 与监控即代码
│
├── 12-service-mesh/
│   └── README.md                          # Service Mesh 监控（Istio）
│
├── 13-networking/                          # ⭐ 网络知识体系（本次新增）
│   ├── README.md                          # 网络知识总览与学习路线
│   ├── 01-network-fundamentals/
│   │   └── README.md                      # TCP/IP 协议栈详解
│   ├── 02-linux-networking/
│   │   └── README.md                      # Linux 网络栈深度解析
│   ├── 03-container-networking/
│   │   └── README.md                      # 容器网络原理
│   ├── 04-k8s-networking/
│   │   └── README.md                      # K8s 网络深入
│   ├── 05-cni-deep-dive/
│   │   └── README.md                      # CNI 插件深入对比
│   ├── 06-advanced-networking/
│   │   └── README.md                      # 高级网络技术（BGP/VXLAN/DPDK/RDMA）
│   ├── 07-network-troubleshooting/
│   │   └── README.md                      # 网络排障实战
│   ├── 08-network-observability/
│   │   └── README.md                      # 网络可观测性（eBPF/Hubble）
│   ├── 09-network-security/
│   │   └── README.md                      # 网络安全与零信任
│   ├── 10-harvester-networking/
│   │   └── README.md                      # Harvester Access/Trunk 模式
│   └── 11-vlan-iptables-ebpf/
│       └── README.md                      # VLAN/iptables/eBPF 对比演进
│
├── 14-thanos-deep-dive/
│   └── README.md                          # Thanos 架构/组件/部署/优化
│
├── 15-victoriametrics-deep-dive/
│   └── README.md                          # VictoriaMetrics 单节点/集群/性能
│
├── 16-cilium-deep-dive/
│   └── README.md                          # Cilium eBPF 数据平面/策略/Hubble
│
├── 17-slo-sre/
│   └── README.md                          # SLI/SLO/SLA、错误预算、燃烧率告警
│
└── 18-aiops/
    └── README.md                          # 异常检测算法、告警降噪、Prophet、RCA

manifests/                                 # K8s YAML 部署清单
├── prometheus/
├── grafana/
├── loki/
├── tempo/
├── otel-collector.yaml                    # OpenTelemetry Collector
├── hubble-ebpf.yaml                       # Cilium Hubble 网络可观测
├── blackbox-exporter.yaml                 # Blackbox 探测
└── ...

scripts/                                   # 运维脚本
├── validate-setup.sh                      # 部署验证
├── load-test.sh                           # 压测脚本
├── cleanup.sh                             # 环境清理
└── ...

Makefile                                   # 一键部署入口
```

---

## 按学习阶段快速导航

| 阶段 | 目录 | 预计时间 | 核心产出 |
|------|------|----------|----------|
| 市场认知 | `00-market-analysis/` | 1 天 | 明确目标岗位和技能差距 |
| 基础篇 | `01-fundamentals/` | 1-2 周 | 能部署基础监控 |
| 进阶篇 | `02-intermediate/` | 2-4 周 | 统一可观测性平台 |
| 精通篇 | `03-advanced/` | 持续 | 生产级架构能力 |
| **网络补齐** | **`13-networking/`** | **2-4 周** | **网络排障与安全意识** |
| 专项深化 | `06-08*/` | 2-3 周 | CRD/JVM/Grafana 专精 |
| 面试实战 | `05-interview/` | 1-2 周 | 面试通过能力 |

---

## 关键文件速查

| 我想了解... | 去读... |
|-------------|---------|
| 市场需要什么技能 | `00-market-analysis/README.md` |
| PromQL 怎么写 | `04-cheatsheets/promql-cheatsheet.md` |
| OTel Collector 怎么配 | `04-cheatsheets/otel-collector-cheatsheet.md` |
| eBPF 是什么 | `03-advanced/01-ebpf-observability.md` |
| **TCP 三次握手细节** | **`13-networking/01-network-fundamentals/`** |
| **iptables 怎么工作** | **`13-networking/02-linux-networking/`** |
| **Pod 怎么拿到 IP** | **`13-networking/03-container-networking/`** |
| **Service 原理** | **`13-networking/04-k8s-networking/`** |
| **Calico vs Cilium** | **`13-networking/05-cni-deep-dive/`** |
| **网络不通怎么排查** | **`13-networking/07-network-troubleshooting/`** |
| SLO 怎么设计 | `03-advanced/02-promql-advanced.md` |
| 自定义 Exporter 开发 | `05-interview/custom-exporter-dev.md` |
| 面试题 | `05-interview/interview-questions.md` |
| CRD 详解 | `06-prometheus-crd-deep-dive/01-operator-crds.md` |
| JVM 监控 | `07-jvm-monitoring/01-jvm-metrics-deep-dive.md` |
| Grafana 深度配置 | `08-grafana-deep-dive/01-grafana-operator-provisioning.md` |

---

## 文档统计

- 总文档数: 35+
- 代码/配置示例: 200+
- 面试题: 50+
- 实践任务: 40+

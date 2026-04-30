# 市场招聘要求分析

> 基于 2024-2026 年主流招聘平台（BOSS直聘、猎聘、智联、脉脉、字节/阿里/腾讯官网）的 K8s 监控/SRE/可观测性岗位 JD 分析

---

## 一、岗位画像

### 典型岗位名称
- K8S 云原生监控研发工程师
- 云原生可观测性高级开发工程师
- SRE 工程师 / 平台工程师
- AI Infra SRE
- 可观测性平台产品经理/工程师
- 基础架构工程师（监控方向）

### 薪资范围（一线城市）
| 级别 | 年限 | 薪资范围 |
|------|------|----------|
| 初级 | 1-3 年 | 20-35K |
| 中级 | 3-5 年 | 35-55K |
| 高级 | 5-8 年 | 50-80K |
| 专家 | 8 年+ | 70-120K+ |

---

## 二、核心技术要求词频分析

### 2.1 必会技能（出现频率 > 80%）

| 技能 | 出现频率 | 要求深度 |
|------|----------|----------|
| **Prometheus** | 95% | 精通架构、TSDB 原理、高基数优化 |
| **Grafana** | 90% | Dashboard 设计、变量、告警配置 |
| **Kubernetes** | 95% | 深度理解 Kubelet/CNI/CSI/Operator |
| **Docker/容器** | 85% | 容器运行时、镜像、网络 |
| **Linux** | 90% | 内核协议栈、性能分析、系统调用 |
| **Go** | 80% | 能独立开发监控组件、Exporter |

### 2.2 重要技能（出现频率 50-80%）

| 技能 | 出现频率 | 典型要求 |
|------|----------|----------|
| **OpenTelemetry** | 75% | "有落地经验"、"构建标准化数据链路" |
| **eBPF** | 65% | "能够编写探测程序"、"网络可观测" |
| **分布式追踪** | 70% | Jaeger/Tempo/SkyWalking 使用与定制 |
| **日志系统** | 70% | Loki/ELK 大规模集群运维 |
| **Thanos/VM** | 60% | "长期存储方案"、"解决 Active Series 爆炸" |
| **SLO 工程** | 55% | "定义 SLI/SLO"、"Error Budget" |
| **Service Mesh** | 50% | Istio/Cilium 流量管理 |

### 2.3 加分技能（出现频率 < 50%）

| 技能 | 出现频率 | 典型场景 |
|------|----------|----------|
| **GPU 监控** | 35% | AI Infra（DCGM/NVML） |
| **Profiling** | 30% | 持续性能剖析（Pyroscope/Parca） |
| **AIOps/异常检测** | 25% | 智能告警、根因分析 |
| **开源贡献** | 20% | "社区核心代码贡献" |
| **大模型监控** | 15% | vLLM/TensorRT-LLM 推理监控 |
| **FinOps** | 10% | 云成本优化 |

---

## 三、典型 JD 拆解

### 3.1 字节跳动 - 云原生可观测高级研发

> 负责支撑公司可观测系统的开发建设

**硬性要求**：
- 精通 C++17，高性能 SDK/Agent 内核开发
- 单机资源损耗控制（高并发低消耗）
- 基于 client-go/Informer 构建元数据索引
- eBPF 探测 K8s 内核态事件
- 异步 I/O、内存池、流控算法优化

**技术栈**：OpenTelemetry、Prometheus、LoongCollector、Cilium

### 3.2 阿里云 - K8s 可观测性高级研发

> 构建支撑万级 GPU 节点的全栈感知系统

**硬性要求**：
- 精通 Golang/C++，内存管理、多线程并发、无锁化设计
- 深度理解 K8s 架构（Kubelet、CRI/CNI/CSI）
- 复杂 Controller 开发经验
- eBPF 实战，编写高性能探测程序
- 解决 Prometheus Active Series 爆炸与高基数压缩
- 海量日志采集（Inotify/Polling）、内存背压控制
- Raft/etcd 一致性协议

**加分项**：
- GPU 指标监测、AI 训练日志分析
- OpenTelemetry/Prometheus/Cilium 社区核心代码贡献

### 3.3 AI Infra SRE（通用 JD）

**硬性要求**：
- 3 年以上 SRE/DevOps/Platform Engineering 经验
- 精通 Prometheus+Grafana，熟悉 Thanos/Mimir/VictoriaMetrics
- 熟练使用分布式追踪（Jaeger/Tempo/Zipkin）
- 掌握日志系统（Loki/ELK/Splunk）
- 精通 Python 或 Go，开发监控插件、告警处理器
- K8s Operator、Custom Metrics、VPA
- Linux 系统与网络调试（tcpdump、perf、eBPF）
- SLO/SLI/SLO Burn Rate 实战经验

**加分项**：
- 大模型推理平台（vLLM/Triton/TGI）监控
- NVIDIA DCGM/NVML GPU 指标采集
- OpenTelemetry 落地经验
- 时序异常检测算法（Prophet、LSTM-AE）
- GitHub 开源可观测性工具贡献

---

## 四、技能矩阵对照表

| 技能领域 | 初级（1-3年） | 中级（3-5年） | 高级（5年+） |
|----------|---------------|---------------|--------------|
| **Prometheus** | 部署配置、基础查询 | Recording Rules、联邦、长期存储 | TSDB 原理、源码级优化、二次开发 |
| **Grafana** | Dashboard 导入使用 | 自定义面板、变量、Alert | 插件开发、数据源对接 |
| **OTel** | SDK 接入、基础配置 | Collector 定制、采样策略 | 协议实现、高性能 Agent 开发 |
| **eBPF** | 了解概念、使用工具 | bpftrace、Hubble 使用 | 编写 eBPF 程序、CO-RE |
| **K8s** | 基础资源管理 | Operator 开发、调度优化 | 源码理解、Controller 开发 |
| **编程** | Shell/Python 脚本 | Go 开发 Exporter | C++/Go 高性能组件开发 |
| **SRE** | 响应告警、故障处理 | SLO 定义、On-call 优化 | 混沌工程、容量规划、AIOps |

---

## 五、面试高频考点

### 5.1 技术原理类
1. Prometheus TSDB 存储原理（chunk、WAL、checkpoint）
2. 高基数指标的危害及解决方案
3. Counter 为什么不能直接查询，必须用 rate()
4. OpenTelemetry 上下文传播机制（W3C/B3）
5. eBPF 程序加载流程（Verifier → JIT → Hook）
6. Histogram vs Summary 的区别
7. Tail Sampling 的实现原理

### 5.2 场景设计类
1. 设计一个支撑 1000 节点 K8s 集群的监控方案
2. 如何实现跨集群统一监控视图？
3. 如何实现 Metrics/Logs/Traces 的关联下钻？
4. 设计一个智能告警降噪系统
5. GPU 集群监控需要关注哪些指标？

### 5.3 故障排查类
1. Prometheus OOM 怎么排查？
2. 某个服务延迟升高，如何从监控定位根因？
3. OTel Collector 数据丢失怎么排查？
4. eBPF 程序加载失败可能的原因？

### 5.4 编程实战类
1. 用 Go 写一个自定义 Exporter
2. 实现一个简单的 Tail Sampling 逻辑
3. 编写一个 eBPF 程序统计 TCP 连接数

---

## 六、学习建议

### 6.1 差异化竞争力构建

**方向一：深度技术专家**
- 深入 Prometheus/OTel 源码
- 参与开源社区贡献（PR/Maintainer）
- 发表技术博客/演讲

**方向二：AI Infra 专项**
- 学习 GPU 监控（DCGM、NVML）
- 大模型推理框架（vLLM、TensorRT-LLM）
- AI 训练链路追踪

**方向三：平台工程**
- 可观测性平台产品化能力
- 多租户、成本优化
- 低代码 Dashboard/告警配置

### 6.2 简历关键词优化

```
必写：Prometheus、Grafana、Kubernetes、OpenTelemetry、Go
选写：eBPF、Thanos、VictoriaMetrics、Cilium、SLO、AIOps
加分：开源贡献、GPU监控、大模型、CNCF项目
```

---

## 参考招聘来源

- [字节跳动 - 云原生可观测](https://jobs.bytedance.com/)
- [阿里云 - K8s 可观测性](https://www.zhipin.com/)
- [BOSS直聘 - 云原生监控](https://www.zhipin.com/)
- [猎聘 - 可观测性工程师](https://www.liepin.com/)
- [脉脉 - 可观测性研发](https://maimai.cn/)

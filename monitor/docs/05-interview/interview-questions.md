# K8s 监控面试题精编

> 基于市场招聘 JD 高频考点整理，覆盖技术原理、场景设计、故障排查、编程实战

---

## 一、技术原理类

### Prometheus

**Q1: Prometheus TSDB 存储原理是什么？chunk、WAL、checkpoint 分别是什么？**

<details>
<summary>参考答案</summary>

- **WAL（Write-Ahead Log）**：Prometheus 先将样本写入 WAL，保证数据不丢失，崩溃后可恢复
- **Memory Head**：内存中的活跃数据块，最近 2 小时（默认）的数据保存在内存
- **Chunk**：时间序列数据的压缩块，每个 chunk 包含一个时间范围内的样本
- **Block**：每 2 小时（默认）将内存中的 head 刷到磁盘形成一个 block，包含 chunk 文件、索引、元数据
- **Checkpoint**：定期将 WAL 中已持久化到 block 的数据截断，防止 WAL 无限增长
- **Compaction**：后台合并小 block 为大 block，同时进行降采样和索引优化

</details>

**Q2: Counter 为什么不能直接查询，必须用 rate() 或 irate()？**

<details>
<summary>参考答案</summary>

- Counter 是单调递增的计数器，重启后会归零重置
- 直接查询 Counter 的绝对值没有业务意义（只会越来越大）
- `rate()` 计算时间范围内的平均增长率（每秒增量），反映真实的业务速率
- `irate()` 使用最后两个样本计算瞬时率，对突变更敏感
- 直接使用 Counter 会导致：重启后出现巨大负值、无法反映真实业务趋势

</details>

**Q3: 什么是高基数（High Cardinality）问题？如何解决？**

<details>
<summary>参考答案</summary>

- **高基数**：指标的 label 取值数量过多（如 user_id、session_id 作为 label），导致时间序列爆炸
- **危害**：Prometheus 内存 OOM、查询变慢、启动时间增加、TSDB 压缩率下降
- **检测**：`count by (__name__) ({__name__=~".+"})` 查看指标数量
- **解决**：
  1. 标签归一化：`/api/users/123` → `/api/users/{id}`
  2. relabel 删除高基数标签
  3. 将高基数数据放到 Traces/Logs 而非 Metrics
  4. 使用 VictoriaMetrics 等支持更高基数的存储

</details>

**Q4: Histogram 和 Summary 的区别？**

<details>
<summary>参考答案</summary>

| 特性 | Histogram | Summary |
|------|-----------|---------|
| 分位数计算 | 服务端计算（推荐） | 客户端计算 |
| 可聚合性 | ✅ 可以聚合 | ❌ 不可聚合 |
| 精度 | 依赖 bucket 划分 | 精确 |
| 资源消耗 | 较低 | 较高 |
| 使用场景 | 服务端监控、多实例聚合 | 客户端精确分位 |

- **推荐**：服务端监控使用 Histogram，因为可以跨实例聚合计算全局分位

</details>

### OpenTelemetry

**Q5: OpenTelemetry 上下文传播机制是什么？W3C Trace Context 格式？**

<details>
<summary>参考答案</summary>

- **Trace Context**：通过 HTTP Header 传递 TraceID 和 SpanID
- **W3C 格式**：`traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`
  - `00`：版本号
  - `4bf92f3577b34da6a3ce929d0e0e4736`：32 位 TraceID
  - `00f067aa0ba902b7`：16 位 SpanID
  - `01`：标志位（是否采样）
- **传播方式**：每个服务在出口请求时注入 traceparent header，在入口请求时提取并创建子 Span
- **Baggage**：额外的键值对上下文，也随请求传递

</details>

**Q6: Head Sampling 和 Tail Sampling 的区别？**

<details>
<summary>参考答案</summary>

| 特性 | Head Sampling | Tail Sampling |
|------|---------------|---------------|
| 决策时机 | 请求开始时 | 请求完成后 |
| 实现位置 | SDK / Agent | Collector |
| 能否保留错误链路 | ❌ 可能错过 | ✅ 可以判断后保留 |
| 资源消耗 | 低 | 高（需缓存完整链路）|
| 延迟影响 | 无 | 有（需等待决策窗口）|

- **生产推荐**：Head 1-10% 采样 + Tail 保留错误/慢请求

</details>

### eBPF

**Q7: eBPF 程序加载流程是什么？**

<details>
<summary>参考答案</summary>

1. **编写**：用 C/Go 编写 eBPF 程序
2. **编译**：编译为 eBPF 字节码（.o 文件）
3. **加载**：用户空间程序通过 `bpf()` 系统调用加载
4. **验证（Verifier）**：内核验证器检查程序安全性（无无限循环、无越界访问、无无效指令）
5. **JIT 编译**：验证通过后，JIT 编译为本地机器码
6. **挂载（Attach）**：挂载到内核 hook 点（kprobe、tracepoint、socket 等）
7. **运行**：触发事件时在内核态执行
8. **通信**：通过 eBPF Maps 与用户空间交换数据

</details>

---

## 二、场景设计类

**Q8: 设计一个支撑 1000 节点 K8s 集群的监控方案。**

<details>
<summary>参考答案</summary>

```
采集层：
- Node Exporter DaemonSet（节点指标）
- kube-state-metrics Deployment（K8s 资源状态）
- cAdvisor（内置在 Kubelet）
- OTel Collector DaemonSet（应用指标/链路/日志）

存储层：
- Prometheus（单实例或分片）+ Thanos Sidecar
- VictoriaMetrics（高性能替代）
- Loki（日志）
- Tempo（链路）

长期存储：
- Thanos Store + S3
- VictoriaMetrics 集群模式

查询层：
- Thanos Querier / VMSelect（全局视图）
- Grafana（统一可视化）

告警层：
- Prometheus Rule + Alertmanager
- 多窗口燃烧率告警

关键优化：
- Prometheus 分片：按 namespace 或 job 分片
- 采集间隔分层：核心 15s，一般 30s，低优先级 60s
- Recording Rules 预聚合
- 高基数控制
```

</details>

**Q9: 如何实现 Metrics / Logs / Traces 的关联下钻？**

<details>
<summary>参考答案</summary>

1. **统一标识符**：所有信号携带相同的 `trace_id` 和 `span_id`
2. **日志注入 TraceID**：在日志框架（Logback/logrus）中从 Span Context 获取 trace_id，输出到每条日志
3. **Metrics Exemplars**：Prometheus Histogram 中附加 Exemplar（包含 trace_id），在 Grafana 中点击跳转到 Trace
4. **Trace 关联日志**：Trace 详情页面展示该 trace 对应时间段的相关日志
5. **告警上下文**：告警消息中附带 trace_id 和日志查询链接

```
Metrics (CPU 高) 
  → 点击 Exemplar (trace_id=abc123)
    → Trace 详情 (看到耗时分布)
      → 点击 "查看日志" (trace_id=abc123)
        → 定位到具体错误日志
```

</details>

**Q10: GPU 集群监控需要关注哪些指标？**

<details>
<summary>参考答案</summary>

**硬件层**：
- GPU 利用率（SM 占用）、显存使用率、温度、功耗
- NVLink 带宽、PCIe 带宽
- ECC 错误（单比特/双比特）

**驱动/框架层**：
- CUDA Kernel 执行时间、Context 数量
- NCCL 通信耗时、集合通信带宽

**应用层（推理）**：
- TTFT（Time To First Token）、TPOT（Time Per Output Token）
- 批处理大小、请求队列长度、KV Cache 使用率
- 吞吐量（tokens/s）

**网络层**：
- RDMA/InfiniBand 带宽、重传率

</details>

---

## 三、故障排查类

**Q11: Prometheus OOM 怎么排查？**

<details>
<summary>参考答案</summary>

1. **检查 TSDB 状态**：`curl localhost:9090/api/v1/status/tsdb`
   - 查看 headStats（chunk count、num series）
2. **检测高基数**：`topk(10, count by (__name__) ({__name__=~".+"}))`
3. **检查 WAL 大小**：`du -sh /prometheus/wal`
4. **优化方向**：
   - 降低 retention time/size
   - 删除高基数标签
   - 增加 scrape interval
   - 增加内存 limit
   - 使用 Thanos/Cortex 联邦分散压力

</details>

**Q12: 某个服务延迟升高，如何从监控定位根因？**

<details>
<summary>参考答案</summary>

1. **Metrics 层**：
   - 查看 RED 指标（Rate/Error/Duration）
   - 对比 P50/P90/P99，确认是整体升高还是尾部异常
   - 检查依赖服务的延迟是否同步升高

2. **Trace 层**：
   - 找出延迟高的 Trace（P99 以上）
   - 分析每个 Span 的耗时，定位最慢的环节
   - 检查是否有网络等待、锁竞争

3. **Logs 层**：
   - 查看该服务对应时间段的 ERROR/WARN 日志
   - 搜索 trace_id 关联日志

4. **Profiling 层**：
   - 查看对应时间段的 CPU/Memory 火焰图
   - 定位热点函数

5. **基础设施层**：
   - 检查节点资源（CPU/内存/磁盘 I/O）
   - 检查网络质量（丢包、重传）
   - 检查是否有 Pod 驱逐、OOM

</details>

**Q13: OTel Collector 数据丢失怎么排查？**

<details>
<summary>参考答案</summary>

1. **检查 Collector 状态**：`curl :13133/health`、`curl :55679/debug/tracez`
2. **查看队列积压**：`otelcol_exporter_queue_size` 指标
3. **检查 Exporter 错误**：`otelcol_exporter_send_failed_metric_points`
4. **查看内存限制**：是否触发了 memory_limiter
5. **检查网络连通性**：Exporter 到后端的网络是否可达
6. **查看日志**：是否有 drop/batch 相关日志
7. **启用 debug exporter**：临时开启 debug 输出验证数据是否到达 Collector

</details>

---

## 四、编程实战类

**Q14: 用 Go 写一个自定义 Prometheus Exporter，暴露 HTTP 请求指标。**

> 参考 `custom-exporter-dev.md` 中的完整示例

**Q15: 实现一个简单的 Tail Sampling 逻辑。**

```go
// 核心思路：缓存一段时间内的 Span，根据条件判断是否采样
type TailSampler struct {
	window      time.Duration
	traces      map[string]*TraceBuffer
	mu          sync.Mutex
}

type TraceBuffer struct {
	spans    []Span
	decided  bool
	sampled  bool
}

func (s *TailSampler) AddSpan(span Span) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	buf, exists := s.traces[span.TraceID]
	if !exists {
		buf = &TraceBuffer{spans: []Span{}}
		s.traces[span.TraceID] = buf
		// 启动定时器，window 后做决策
		time.AfterFunc(s.window, func() { s.decide(span.TraceID) })
	}

	buf.spans = append(buf.spans, span)

	// 如果已经决策，直接返回
	if buf.decided {
		return buf.sampled
	}

	// 提前决策：遇到错误立即采样
	if span.Status == ERROR {
		buf.decided = true
		buf.sampled = true
		return true
	}

	return false // 尚未决策
}

func (s *TailSampler) decide(traceID string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	buf := s.traces[traceID]
	if buf.decided {
		return
	}

	// 检查是否有慢请求
	for _, span := range buf.spans {
		if span.Duration > 500*time.Millisecond {
			buf.sampled = true
			break
		}
	}

	// 否则按概率采样
	if !buf.sampled && rand.Float64() < 0.1 {
		buf.sampled = true
	}

	buf.decided = true
	delete(s.traces, traceID)
}
```

**Q16: 编写一个 eBPF 程序统计 TCP 连接数。**

```c
// tcp_connect.c
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);   // PID
    __type(value, u64); // connect count
} tcp_connect_count SEC(".maps");

SEC("kprobe/tcp_v4_connect")
int BPF_KPROBE(trace_tcp_connect, struct sock *sk) {
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u64 *count = bpf_map_lookup_elem(&tcp_connect_count, &pid);
    
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        u64 init = 1;
        bpf_map_update_elem(&tcp_connect_count, &pid, &init, BPF_ANY);
    }
    
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

---

## 五、行为面试题

**Q17: 描述一次你通过监控发现并解决生产故障的经历。**

> STAR 法则：
> - **S**ituation：系统背景、监控现状
> - **T**ask：你负责什么
> - **A**ction：发现告警 → 查看 Metrics → 下钻 Trace → 查看日志 → 定位根因 → 修复
> - **R**esult：MTTR 缩短了多少、后续改进措施

**Q18: 如何推动研发团队接入可观测性？**

> 参考答案要点：
> - 降低接入成本：提供自动埋点、文档、SDK
> - 收益可视化：展示接入前后的故障定位时间对比
> - 标准化：制定统一的命名规范、日志格式
> - 融入流程：CI/CD 中自动注入、代码 Review 检查
> - 自上而下：管理层支持，纳入绩效考核

---

## 参考资源

- [Prometheus 面试题](https://prometheus.io/docs/introduction/faq/)
- [Google SRE Interview Questions](https://sre.google/interview/)
- [CNCF 可观测性白皮书](https://github.com/cncf/tag-observability/blob/main/whitepaper.md)

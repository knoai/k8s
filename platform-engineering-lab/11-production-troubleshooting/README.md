# 11 - 生产问题排查

生产环境的问题排查是平台工程师的核心技能。本章提供系统化的排查方法论、
实战案例和工具链，帮助工程师快速定位和解决生产问题。

## 学习目标

1. 掌握 7 层排查法（从应用到底层基础设施）
2. 学会使用系统化方法而非"猜"来定位问题
3. 掌握常见生产问题的快速诊断流程
4. 建立问题复盘和知识沉淀机制
5. 掌握常用排查工具和命令

## 核心概念

### 7 层排查法

生产问题可以从 7 个层次逐层排查:

```
Layer 7: 应用层     → 日志、性能、依赖、配置
Layer 6: 服务层     → 服务发现、负载均衡、配置中心
Layer 5: 网络层     → DNS、CNI、Ingress、Service Mesh
Layer 4: 存储层     → PVC、PV、存储类、I/O 性能
Layer 3: 节点层     → 节点状态、资源使用、内核、运行时
Layer 2: 控制面层   → API Server、etcd、Scheduler、Controller Manager
Layer 1: 基础设施层 → 云厂商、网络、硬件、虚拟化
```

**排查原则**: 从上到下，从外到内。先确认应用是否正常，
再逐步深入基础设施。

### 常见症状与排查路径

**症状: Pod 无法启动**
1. `kubectl describe pod <pod-name>` → 查看 Events
2. 常见原因:
   - ImagePullBackOff: 镜像不存在或仓库认证失败
   - CrashLoopBackOff: 应用启动失败，查看日志
   - Pending: 资源不足或节点选择器不匹配
   - FailedMount: PVC 绑定失败
   - CreateContainerConfigError: ConfigMap/Secret 缺失

**症状: 服务无法访问**
1. Pod 是否就绪？`kubectl get pods`
2. Service 是否正确？`kubectl get svc`, `kubectl get endpoints`
3. Ingress 是否正确？`kubectl get ingress`
4. DNS 是否正常？`nslookup <service-name>`
5. 网络策略是否阻止？`kubectl get networkpolicy`
6. 节点网络是否正常？跨节点 ping 测试

**症状: 性能下降**
1. 资源使用: `kubectl top pods/nodes`
2. 日志异常: `kubectl logs --previous`
3. 追踪分析: Jaeger/Tempo 查看调用链
4. 节点状态: `kubectl describe node`
5. 存储 I/O: `iostat`, `iotop`
6. 网络延迟: `ping`, `mtr`, `tcpdump`

### 问题复盘模板

```
## 事故报告

### 基本信息
- 时间: 2024-01-15 10:00 - 10:30 UTC
- 影响: 订单服务不可用，30 分钟
- 严重级别: P1
- 报告人: 平台团队

### 时间线
- 10:00 告警触发（错误率 > 1%）
- 10:05 值班工程师响应
- 10:10 定位到数据库连接池耗尽
- 10:15 扩容连接池
- 10:30 服务恢复

### 根因分析
数据库连接池配置 max_connections=50，但应用连接池配置了 100 个连接，
导致连接耗尽，新请求无法建立连接。

根本原因: 配置变更时未同步更新相关组件。

### 改进措施
1. [ ] 增加数据库连接池监控（完成时间: 2024-01-20）
2. [ ] 调整应用连接池大小（完成时间: 2024-01-16）
3. [ ] 添加连接池耗尽告警（完成时间: 2024-01-22）
4. [ ] 建立配置变更 checklist（完成时间: 2024-01-18）

### 经验教训
- 配置变更需要同步更新相关组件
- 连接池大小需要基于实际负载测试
- 缺少连接池监控导致问题发现延迟
```

## 模块内容

### Pod 问题排查

文件: `pod-troubleshooting.md`

覆盖 ImagePullBackOff、CrashLoopBackOff、Pending、OOMKilled 等常见问题的排查。

### 网络问题排查

文件: `network-troubleshooting.md`

覆盖 DNS 解析、Service 访问、Ingress 配置、NetworkPolicy 等网络问题的排查。

### 存储问题排查

文件: `storage-troubleshooting.md`

覆盖 PVC 绑定、PV 供应、存储性能、数据丢失等存储问题的排查。

### 节点问题排查

文件: `node-troubleshooting.md`

覆盖节点 NotReady、资源不足、内核问题、运行时故障等节点问题的排查。

### 控制面问题排查

文件: `control-plane-troubleshooting.md`

覆盖 API Server 不可用、etcd 故障、Scheduler 异常等控制面问题的排查。

### cgroup 多线程问题

文件: `cgroup-multithread-issues.md`

覆盖 Java 应用在容器中的多线程性能问题（cgroup v1 vs v2 的差异）。

## 常用排查命令速查

```bash
# Pod 状态
kubectl get pods -o wide
kubectl describe pod <pod-name>
kubectl logs <pod-name> --previous
kubectl get events --sort-by='.lastTimestamp'

# 资源使用
kubectl top pods
kubectl top nodes
kubectl describe node <node-name>

# 网络
kubectl get svc,endpoints,ingress
kubectl exec -it <pod> -- nslookup <svc>
kubectl exec -it <pod> -- curl -v <url>

# 存储
kubectl get pvc,pv
kubectl describe pvc <pvc-name>

# 控制面
kubectl get componentstatuses
kubectl get --raw /healthz
kubectl get --raw /metrics
```

## 面试常见问题

**Q: 如何系统性地排查生产问题？**

A: 四步法:
1. **确认**: 确认问题真实存在，排除误报
2. **定位**: 使用 7 层排查法逐层定位
3. **缓解**: 先止血（回滚、扩容、切换），再根治
4. **复盘**: 记录时间线、根因、改进措施

**Q: 如何减少生产事故？**

A: 五个层面:
1. **预防**: 代码审查、自动化测试、混沌工程
2. **发现**: 完善的监控告警（缩短 MTTD）
3. **响应**: 明确的 On-call 流程和 Runbook（缩短 MTTR）
4. **恢复**: 快速回滚、自动 failover
5. **学习**: 复盘、知识库、预防措施

**Q: 值班工程师需要哪些工具？**

A: 核心工具箱:
- `kubectl` + 常用插件（k9s、stern）
- 日志查询（Loki、Kibana）
- 指标查询（Prometheus、Grafana）
- 追踪查询（Jaeger）
- 网络工具（tcpdump、curl、nslookup、mtr）
- 节点工具（top、htop、iostat、vmstat）

**Q: 如何避免"背锅"文化？**

A:
- 聚焦根因而非责任人
- 建立"无责复盘"文化
- 奖励发现问题和报告问题的人
- 将错误视为学习机会
- 系统改进优于个人惩罚

**Q: MTTD 和 MTTR 如何优化？**

A:
- **MTTD（平均发现时间）**: 完善的监控覆盖 + 智能告警
  - 关键指标全覆盖
  - 告警阈值合理（避免漏报和误报）
  - 告警渠道直达值班工程师

- **MTTR（平均恢复时间）**: Runbook + 自动化 + 快速回滚
  - 每个告警有对应的 Runbook
  - 常见故障自动化处理
  - 一键回滚能力
  - 灰度发布，快速切换

目标: MTTD < 5 分钟，MTTR < 30 分钟。

## 参考资源

- [K8s 故障排查指南](https://kubernetes.io/docs/tasks/debug/)
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/)
- [Chaos Engineering](https://principlesofchaos.org/)
- [K8s 调试技巧](https://kubernetes.io/docs/tasks/debug/debug-cluster/)

## 生产排查进阶

### 排查工具链

**kubectl 插件**:
```bash
# k9s: 交互式终端 UI
k9s

# stern: 多 Pod 日志实时查看
stern <pod-name-pattern>

# kube-ps1: 命令行显示当前上下文
source <(kubectl completion bash)

# kubectl-debug: 在目标 Pod 中启动调试容器
kubectl debug <pod> -it --image=nicolaka/netshoot --target=<container>
```

**网络诊断工具**:
```bash
# netshoot 容器（瑞士军刀）
kubectl run netshoot --rm -i --tty --image nicolaka/netshoot -- /bin/bash

# 常用命令
ping <target>
tracert <target>
curl -v <url>
nslookup <domain>
tcpdump -i eth0 port 8080
ss -tlnp  # 查看监听端口
```

**性能分析工具**:
```bash
# 节点级别
top / htop
iostat -x 1
vmstat 1
sar -u 1  # CPU
sar -r 1  # 内存

# 容器级别
cat /sys/fs/cgroup/cpu/cpu.stat
cat /sys/fs/cgroup/memory/memory.stat
```

### 常见故障场景速查

**场景 1: OOMKilled**
```bash
# 确认
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'

# 解决
# 1. 增加内存 Limit
# 2. 优化应用内存使用
# 3. 检查是否有内存泄漏
```

**场景 2: ImagePullBackOff**
```bash
# 查看详细错误
kubectl describe pod <pod> | grep -A 5 "Failed to pull image"

# 常见原因
# 1. 镜像名/标签错误
# 2. 镜像仓库认证失败（imagePullSecrets）
# 3. 网络不通（无法访问外网镜像仓库）
# 4. 镜像不存在
```

**场景 3: 节点 NotReady**
```bash
# 查看节点状态
kubectl describe node <node>

# 检查 kubelet
systemctl status kubelet
journalctl -u kubelet -f

# 检查容器运行时
crictl ps
crictl info

# 常见原因
# 1. kubelet 停止
# 2. 容器运行时故障
# 3. 磁盘空间不足
# 4. 内存不足（系统 OOM）
# 5. 网络分区
```

**场景 4: PVC 无法绑定**
```bash
# 查看 PVC 状态
kubectl describe pvc <pvc>

# 检查 StorageClass
kubectl get sc

# 检查 PV
kubectl get pv

# 常见原因
# 1. StorageClass 不存在
# 2. 存储后端无可用资源
# 3. 访问模式不匹配（ReadWriteOnce vs ReadWriteMany）
# 4. 节点选择器限制
```

### 混沌工程

**混沌工程原则**:
1. 建立稳态假设（系统正常时的指标）
2. 引入真实世界的故障
3. 验证假设是否仍然成立
4. 从最小影响范围开始

**常用混沌实验**:
```bash
# Chaos Mesh
kubectl apply -f https://mirrors.chaos-mesh.org/latest/install.yaml

# Pod 故障（随机删除 Pod）
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-kill
spec:
  action: pod-kill
  mode: one
  selector:
    labelSelectors:
      app: nginx
```

### 排查知识库

**建立 Runbook 模板**:
```markdown
# <告警名称> Runbook

## 告警描述
<描述这个告警的含义>

## 可能原因
1. <原因1>
2. <原因2>
3. <原因3>

## 排查步骤
1. 检查指标: `kubectl top pods -l app=<app>`
2. 查看日志: `kubectl logs -l app=<app> --tail=100`
3. 检查事件: `kubectl get events --field-selector involvedObject.name=<pod>`

## 解决措施
- 措施1: <具体命令>
- 措施2: <具体命令>

## 升级路径
如果 15 分钟内无法解决，联系: <升级联系人>
```

## 面试常见问题补充

**Q: 如何排查 K8s 控制面故障？**

A:
1. **API Server**: `kubectl get --raw /healthz`
   - 检查证书是否过期
   - 检查 etcd 连接
   - 检查负载均衡器

2. **etcd**: `etcdctl endpoint health`
   - 检查磁盘 I/O（WAL fsync 延迟）
   - 检查 DB 大小（> 8GB 需要压缩）
   - 检查 Leader 选举

3. **Scheduler**: `kubectl get events --field-selector reason=FailedScheduling`
   - 检查资源不足
   - 检查节点亲和性
   - 检查污点/容忍

**Q: 如何排查 DNS 问题？**

A:
1. 检查 CoreDNS Pod 状态: `kubectl get pods -n kube-system -l k8s-app=kube-dns`
2. 检查 CoreDNS 日志: `kubectl logs -n kube-system <coredns-pod>`
3. 测试 DNS 解析: `kubectl run -it --rm debug --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default`
4. 检查 resolv.conf: `kubectl run -it --rm debug --image=busybox:1.28 --restart=Never -- cat /etc/resolv.conf`
5. 检查 ndots: 如果 ndots:5，短域名解析会尝试多次

**Q: 生产环境的回滚策略？**

A:
1. **Deployment 回滚**: `kubectl rollout undo deployment/<name>`
2. **StatefulSet 回滚**: 手动更新镜像版本
3. **ConfigMap/Secret 回滚**: 使用版本控制（GitOps）
4. **数据库回滚**: 预先备份，使用迁移工具的 down 命令

原则: 先止血（快速回滚），后根治（找到根因）。


### 生产故障响应流程

**标准响应流程（SRE 最佳实践）**:

```
阶段 1: 发现 (0-2 min)
├── 告警触发（PagerDuty / Slack）
├── 值班工程师确认
└── 创建 War Room（Zoom / Slack Huddle）

阶段 2: 止血 (2-15 min)
├── 快速评估影响范围
├── 尝试自动恢复（如 Pod 重启）
├── 必要时启动降级/熔断
└── 如果无法快速恢复，准备回滚

阶段 3: 根因分析 (15-60 min)
├── 收集日志和指标
├── 复现问题
├── 定位根因
└── 制定修复方案

阶段 4: 修复 (60 min+)
├── 实施修复
├── 验证修复效果
└── 恢复全量流量

阶段 5: 复盘 (24h 内)
├── 编写事后分析文档（Postmortem）
├── 识别改进项
└── 更新 Runbook
```

**事后分析模板**:
```markdown
# 事后分析: <事件名称>

## 时间线
- XX:XX - 告警触发
- XX:XX - 工程师响应
- XX:XX - 止血完成
- XX:XX - 修复完成

## 影响
- 服务: <服务名>
- 持续时间: <X 分钟>
- 用户影响: <描述>

## 根因
<详细描述>

## 经验教训
1. <教训1>
2. <教训2>

## 改进项
- [ ] <改进1> (负责人: @xxx, 截止: YYYY-MM-DD)
- [ ] <改进2> (负责人: @xxx, 截止: YYYY-MM-DD)
```

### 容量问题排查

**磁盘满排查**:
```bash
# 1. 查看磁盘使用率
df -h

# 2. 查看大文件/目录
du -sh /* 2>/dev/null | sort -rh | head -20
du -sh /var/lib/docker/* 2>/dev/null | sort -rh | head -10

# 3. 清理 Docker（谨慎）
docker system prune -a --volumes  # 删除未使用镜像/卷
docker image prune -a             # 删除未使用镜像

# 4. 清理日志
journalctl --vacuum-time=7d       # 保留 7 天日志
find /var/log -name "*.log" -mtime +30 -delete
```

**内存泄漏排查**:
```bash
# 1. 确认泄漏
kubectl top pods -A --sort-by=memory | head -20

# 2. 查看内存趋势（需要 Prometheus）
# increase(container_memory_working_set_bytes[1h])

# 3. 如果是 Java 应用
# 进入 Pod 执行 jmap
kubectl exec -it <pod> -- jmap -histo:live 1 | head -30

# 4. 生成堆 dump
kubectl exec -it <pod> -- jmap -dump:live,format=b,file=/tmp/heap.hprof 1
kubectl cp <pod>:/tmp/heap.hprof ./heap.hprof
```

### 性能退化排查

**服务延迟增加排查**:
```bash
# 1. 确认延迟（按百分位）
# P50: 正常 | P95: 偏高 | P99: 很高

# 2. 检查资源使用
kubectl top pods -l app=<app>

# 3. 检查依赖服务
# 下游服务是否变慢？

# 4. 检查数据库
# 慢查询日志
# 连接池使用率

# 5. 检查网络
# TCP 重传率
# DNS 解析延迟
```

**TCP 连接问题**:
```bash
# 查看连接状态
ss -s
ss -tan | awk '{print $1}' | sort | uniq -c | sort -rn

# 查看 TIME_WAIT
ss -tan state time-wait | wc -l

# 优化内核参数
cat >> /etc/sysctl.conf << 'SYSCTL'
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.core.somaxconn = 65535
SYSCTL
sysctl -p
```

### 跨团队协作排查

**涉及多团队的故障**:
1. **明确 Owner**: 哪个团队的变更导致了问题
2. **信息共享**: 所有团队共享同一日志/指标视图
3. **并行排查**: 各团队同时排查自己的组件
4. **统一指挥**: 指定一个 Incident Commander

**沟通模板（Slack）**:
```
🚨 [INCIDENT-123] 支付服务延迟升高

影响: 支付成功率从 99.9% 降至 95%
时间: 2024-01-15 14:23 UTC
值班: @oncall-platform

当前状态: 排查中

已知信息:
- API Gateway P99 延迟从 50ms 升至 500ms
- 下游订单服务正常
- 数据库连接池使用率 100%

需要协助: @oncall-db 请检查数据库状态
```


### 微服务链路故障排查

**分布式追踪实战**:
```bash
# 1. 通过 Trace ID 定位问题跨度
curl -s "http://jaeger:16686/api/traces?service=order-service&limit=10" | jq

# 2. 找到延迟异常的 Span
# 关注 tags: error=true, http.status_code=5xx

# 3. 分析调用链
# A → B → C → D
# 如果 C → D 耗时 2s（正常 20ms），则 D 有问题

# 4. 查看 Span 日志
event: "connection timeout"
event: "retry attempt 1"
event: "retry attempt 2"
event: "circuit breaker open"
```

**链路故障常见模式**:

| 模式 | 症状 | 根因 | 修复 |
|------|------|------|------|
| 级联超时 | A → B → C，C 慢导致 B 超时，B 超时导致 A 超时 | 下游服务慢，上游超时设置不合理 | 缩短超时，增加熔断 |
| 重试风暴 | 服务故障后大量重试，恢复后被打垮 | 无退避策略 | 指数退避 + jitter |
| 缓存穿透 | 大量请求打到数据库 | 缓存同时失效 | 热点 key 永不过期 + 互斥锁 |
| 连接池耗尽 | 大量请求等待连接 | 连接泄漏或池太小 | 调大池或修复泄漏 |

### 云原生排障工具箱

**kubectl-neat**（清理 YAML 输出）:
```bash
kubectl get pod <pod> -o yaml | kubectl neat
```

**kubectl-who-can**（权限审计）:
```bash
kubectl-who-can create pods -n production
```

**kubectl-sniff**（抓包）:
```bash
kubectl sniff <pod> -p 8080 -f "tcp port 8080"
```

**inspektor-gadget**（eBPF 工具集）:
```bash
# 监控文件访问
gadget trace open -n default

# 监控网络
gadget trace tcp -n default

# 监控 exec
gadget trace exec -n default
```


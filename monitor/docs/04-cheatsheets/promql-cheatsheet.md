# PromQL 速查表

## 基础查询

```promql
# 选择所有序列
metric_name

# 标签过滤
metric_name{label="value"}
metric_name{label=~"regex"}
metric_name{label!="value"}
metric_name{label!~"regex"}

# 范围查询
metric_name[5m]
metric_name[1h]
metric_name[1d]
```

## 聚合操作符

```promql
sum(metric_name)                           # 求和
avg(metric_name)                           # 平均值
min(metric_name)                           # 最小值
max(metric_name)                           # 最大值
count(metric_name)                         # 计数
count_values("label", metric_name)         # 按值统计
topk(10, metric_name)                      # 前 10
bottomk(5, metric_name)                    # 后 5
quantile(0.99, metric_name)                # 0.99 分位

# 分组聚合
sum by (label1, label2) (metric_name)
avg without (label1) (metric_name)
```

## Counter 函数（必须）

```promql
rate(metric_counter[5m])                   # 每秒平均增长率
irate(metric_counter[5m])                  # 瞬时率（最后两个点）
increase(metric_counter[1h])               # 时间范围内总增量
resets(metric_counter[1d])                 # 计数器重置次数
changes(metric_gauge[1h])                  # Gauge 值变化次数
```

## 数学与比较

```promql
# 数学运算
+  -  *  /  %  ^

# 比较运算（返回 0/1）
==  !=  >  <  >=  <=

# 逻辑运算
and  or  unless

# 向量匹配
metric1 == on(label) metric2
metric1 == ignoring(label) metric2
```

## 实用函数

```promql
# 时间函数
time()                                     # 当前时间戳
day_of_week()                              # 星期 (0=周日)
hour()                                     # 小时
minute()                                   # 分钟

# 预测与变化
predict_linear(metric[1h], 3600)           # 线性预测 1 小时后
deriv(metric[1h])                          # 每秒导数
delta(metric[1h])                          # 差值（Gauge）
holt_winters(metric[1d], 0.1, 0.5)         # 趋势预测

# 直方图
histogram_quantile(0.99, sum(rate(http_bucket[5m])) by (le))

# 其他
absent(metric_name)                        # 检查序列是否存在
clamp_min(metric, 0)                       # 限制最小值
clamp_max(metric, 100)                     # 限制最大值
round(metric, 0.5)                         # 四舍五入
scalar(metric)                             # 向量转标量
```

## Kubernetes 常用查询

```promql
# 节点 CPU
100 - avg by(instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100

# 节点内存
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# 节点磁盘
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Pod 重启
increase(kube_pod_container_status_restarts_total[1h])

# Pod CPU
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (pod, namespace)

# Pod 内存
sum(container_memory_working_set_bytes{container!=""}) by (pod, namespace)

# Deployment 就绪率
kube_deployment_status_replicas_ready / kube_deployment_spec_replicas
```

## 应用监控查询

```promql
# QPS
sum(rate(http_requests_total[5m]))

# 错误率
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# P99 延迟
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

# 各状态码占比
sum by (status) (rate(http_requests_total[5m]))
```

## 告警规则模板

```yaml
groups:
  - name: example
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum(rate(http_requests_total[5m])) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate"
          description: "Error rate is {{ $value | humanizePercentage }}"
```

# CoreDNS 静态解析案例及检测脚本

## 目录

- [什么是 CoreDNS 静态解析](#什么是-coredns-静态解析)
- [静态解析常见场景](#静态解析常见场景)
- [配置案例](#配置案例)
- [配置生效方式](#配置生效方式)
- [检测脚本使用说明](#检测脚本使用说明)

---

## 什么是 CoreDNS 静态解析

**静态解析**指不经过上游 DNS 服务器，在 CoreDNS 本地直接指定域名与 IP 的映射关系。类似于 Linux 的 `/etc/hosts` 文件，但作用于整个 Kubernetes 集群。

**适用场景**：
- 内网域名指向内网 IP（避免外网 DNS 解析失败或被劫持）
- 外部域名强制指向内部服务（如镜像仓库、SaaS 网关）
- 本地开发域名（如 `dev.internal.local`）
- DNS 故障时兜底解析

```
Pod 发起 DNS 查询：my-service.internal.local
        │
        ▼
   CoreDNS (hosts 插件)
        │
        ├── hosts 文件/ConfigMap 中有记录？
        │       ├── 是 → 直接返回静态 IP
        │       └── 否 → 转发到上游 DNS
        │
        ▼
   返回解析结果
```

---

## 静态解析常见场景

### 场景 1：内部域名解析

公司有内部服务域名 `api.internal.local`，仅在局域网可用，外网 DNS 无法解析。

### 场景 2：外部域名强制指向内部代理

外部域名 `docker.io` 被防火墙限制，通过静态解析指向内部镜像代理 `10.10.10.10`。

### 场景 3：多环境域名隔离

不同 Namespace 的 Pod 访问同一域名时，解析到不同 IP：
- `dev` 环境 → `10.10.1.10`
- `prod` 环境 → `10.10.2.10`

### 场景 4：DNS 故障兜底

上游 DNS 服务器故障时，对关键域名提供静态解析兜底。

---

## 配置案例

### 案例 1：ConfigMap 方式（推荐）

通过修改 CoreDNS ConfigMap，使用 `hosts` 插件配置静态解析。

```yaml
# coredns-custom.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready

        # ===== 静态解析配置 =====
        # 方式 1：直接 inline 配置
        hosts {
            10.131.1.10    api.internal.local
            10.131.1.11    db.internal.local
            10.131.1.12    redis.internal.local
            10.10.10.10    docker.io
            10.10.10.10    registry-1.docker.io
            fallthrough
        }

        # 方式 2：引用外部 hosts 文件（需要挂载到 Pod）
        # hosts /etc/coredns/custom-hosts {
        #     fallthrough
        # }
        # ========================

        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
```

**关键参数说明**：

| 参数 | 说明 |
|------|------|
| `hosts { ... }` | CoreDNS hosts 插件，定义静态解析 |
| `10.131.1.10 api.internal.local` | 格式：`IP 域名1 域名2 ...` |
| `fallthrough` | 未匹配的域名继续下一个插件处理 |
| `reload` | Corefile 变更后自动重载（约 2 分钟） |

**应用配置**：

```bash
# 修改 CoreDNS ConfigMap
kubectl apply -f coredns-custom.yaml

# 或编辑现有 ConfigMap
kubectl edit configmap coredns -n kube-system

# 强制重启 CoreDNS 使配置生效
kubectl rollout restart deployment coredns -n kube-system
```

### 案例 2：外部 hosts 文件挂载

当静态解析条目很多时，使用外部文件更方便管理。

```yaml
# custom-hosts-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom-hosts
  namespace: kube-system
data:
  hosts: |
    # 内部服务
    10.131.1.10    api.internal.local
    10.131.1.10    api.internal.local.
    10.131.1.11    db.internal.local
    10.131.1.11    db.internal.local.
    10.131.1.12    redis.internal.local
    10.131.1.12    redis.internal.local.

    # 外部域名强制指向内部代理
    10.10.10.10    docker.io
    10.10.10.10    docker.io.
    10.10.10.10    registry-1.docker.io
    10.10.10.10    registry-1.docker.io.

    # 监控告警平台
    10.131.1.20    prometheus.internal.local
    10.131.1.21    grafana.internal.local
    10.131.1.22    alertmanager.internal.local
```

```yaml
# coredns-deployment-patch.yaml
# 使用 patch 将 hosts 文件挂载到 CoreDNS Pod
spec:
  template:
    spec:
      volumes:
      - name: custom-hosts
        configMap:
          name: coredns-custom-hosts
          items:
          - key: hosts
            path: custom-hosts
      containers:
      - name: coredns
        volumeMounts:
        - name: custom-hosts
          mountPath: /etc/coredns/custom-hosts
          subPath: custom-hosts
```

**Corefile 配置**：

```
hosts /etc/coredns/custom-hosts {
    fallthrough
}
```

### 案例 3：分区域静态解析

使用 `template` 插件实现更复杂的解析规则。

```
# 将 *.dev.local 解析到开发环境
template IN A dev.local {
    match "^.*\.dev\.local\.?$"
    answer "{{ .Name }} 60 IN A 10.131.1.10"
    fallthrough
}

# 将 *.prod.local 解析到生产环境
template IN A prod.local {
    match "^.*\.prod\.local\.?$"
    answer "{{ .Name }} 60 IN A 10.131.2.10"
    fallthrough
}
```

### 案例 4：负载均衡静态解析

为同一域名配置多个 IP，CoreDNS 会轮询返回。

```
hosts {
    10.131.1.10    api.internal.local
    10.131.1.11    api.internal.local
    10.131.1.12    api.internal.local
    fallthrough
}
```

**效果**：
```bash
$ nslookup api.internal.local
Address: 10.131.1.10  # 第一次查询

$ nslookup api.internal.local
Address: 10.131.1.11  # 第二次查询

$ nslookup api.internal.local
Address: 10.131.1.12  # 第三次查询
```

### 案例 5：反向解析（PTR 记录）

配置 IP 到域名的反向解析。

```
hosts {
    10.131.1.10    api.internal.local
    fallthrough
}
```

CoreDNS hosts 插件默认同时创建正向和反向解析。

---

## 配置生效方式

### 方式 1：修改 CoreDNS ConfigMap

```bash
# 编辑 ConfigMap
kubectl edit configmap coredns -n kube-system

# 检查配置语法（CoreDNS 会自动验证）
# 如果配置错误，CoreDNS Pod 会 CrashLoopBackOff

# 查看 CoreDNS 日志
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50

# 确认配置已加载
kubectl get configmap coredns -n kube-system -o yaml
```

### 方式 2：热重载

CoreDNS 支持 `reload` 插件，ConfigMap 修改后约 2 分钟自动重载。

```bash
# 手动触发 reload（发送 SIGUSR1）
kubectl exec -n kube-system deployment/coredns -- kill -USR1 1

# 或重启 Pod
kubectl rollout restart deployment coredns -n kube-system
```

### 方式 3：验证配置

```bash
# 进入 CoreDNS Pod 检查配置
kubectl exec -it -n kube-system deployment/coredns -- cat /etc/coredns/Corefile

# 检查 hosts 文件（如果使用外部挂载）
kubectl exec -it -n kube-system deployment/coredns -- cat /etc/coredns/custom-hosts
```

---

## 检测脚本使用说明

检测脚本功能：
1. 检查 CoreDNS Pod 运行状态
2. 检查 CoreDNS ConfigMap 配置
3. 测试 DNS 解析（静态域名 + 集群域名）
4. 检查上游 DNS 转发
5. 检查 DNS 缓存
6. 检查 CoreDNS 日志中的错误

```bash
# 基础检查
bash check-coredns.sh

# 指定要测试的静态域名
bash check-coredns.sh api.internal.local db.internal.local

# 详细模式
bash check-coredns.sh -v

# 输出 JSON 格式（用于自动化）
bash check-coredns.sh --json
```

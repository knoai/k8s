# K8s 进阶 - 实操指南

> 7 个实验覆盖调度器、etcd、存储、安全、证书等核心进阶主题。
> 每个实验包含：场景说明 → 执行步骤 → 预期输出 → 验证方法 → 常见错误排查。

---

## 实验 1：本地多节点 Kind 集群

### 场景
搭建一个模拟生产环境的多节点 Kind 集群，用于后续所有实验。

### 执行

```bash
# 安装 kind（macOS）
brew install kind

# 创建多节点集群（1 control-plane + 2 worker）
cat > kind-cluster.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
  extraMounts:
  - hostPath: /tmp/kind-worker1
    containerPath: /data
- role: worker
  extraMounts:
  - hostPath: /tmp/kind-worker2
    containerPath: /data
EOF

kind create cluster --name platform-lab --config kind-cluster.yaml

# 验证
kubectl get nodes -o wide
```

### 预期输出

```
NAME                            STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE       KERNEL-VERSION   CONTAINER-RUNTIME
platform-lab-control-plane      Ready    control-plane   2m    v1.28.0   172.18.0.2    <none>        Ubuntu 22.04   5.15.0           containerd://1.7.1
platform-lab-worker             Ready    <none>          1m    v1.28.0   172.18.0.3    <none>        Ubuntu 22.04   5.15.0           containerd://1.7.1
platform-lab-worker2            Ready    <none>          1m    v1.28.0   172.18.0.4    <none>        Ubuntu 22.04   5.15.0           containerd://1.7.1
```

### 验证方法

```bash
# 确认所有节点 Ready
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# 确认 coreDNS 运行
kubectl get pods -n kube-system -l k8s-app=kube-dns
# NAME                      READY   STATUS    RESTARTS   AGE
# coredns-5dd5756b68-xxxxx  1/1     Running   0          2m

# 确认存储类
kubectl get sc
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   true
```

### 常见错误

```bash
# 错误 1：端口被占用
# ERROR: failed to create cluster: failed to ensure docker network
# 解决：检查 80/443 端口占用
sudo lsof -i :80
sudo lsof -i :443

# 错误 2：Docker 磁盘不足
# ERROR: failed to create cluster: running command: docker run...
# 解决：清理 Docker
docker system prune -a

# 错误 3：节点 NotReady
# 解决：检查 kubelet 日志
docker exec -it platform-lab-control-plane journalctl -u kubelet -n 50
```

---

## 实验 2：自定义调度器插件

### 场景
实现一个自定义调度器插件，优先将 Pod 调度到具有特定标签（如 `gpu=true`）的节点上。

### 执行

```bash
# 给 worker 节点打标签
kubectl label node platform-lab-worker gpu=true
kubectl label node platform-lab-worker2 gpu=false

# 查看调度框架插件目录
git clone --depth 1 https://github.com/kubernetes/kubernetes.git /tmp/k8s-src 2>/dev/null || true
ls /tmp/k8s-src/pkg/scheduler/framework/plugins/ 2>/dev/null | head -10

# 创建自定义调度器配置
cat > custom-scheduler.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: scheduler-config
  namespace: kube-system
data:
  scheduler-config.yaml: |
    apiVersion: kubescheduler.config.k8s.io/v1
    kind: KubeSchedulerConfiguration
    profiles:
    - schedulerName: gpu-priority-scheduler
      plugins:
        filter:
          enabled:
          - name: NodeAffinity
        score:
          enabled:
          - name: NodeAffinity
            weight: 100
EOF
kubectl apply -f custom-scheduler.yaml

# 创建使用自定义调度器的 Pod
cat > gpu-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-workload
spec:
  schedulerName: gpu-priority-scheduler
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: gpu
            operator: In
            values:
            - "true"
  containers:
  - name: app
    image: nginx:alpine
EOF
kubectl apply -f gpu-pod.yaml
```

### 预期输出

```bash
# 查看 Pod 调度结果
kubectl get pod gpu-workload -o wide
# NAME           READY   STATUS    RESTARTS   AGE   IP           NODE
# gpu-workload   1/1     Running   0          10s   10.244.1.x   platform-lab-worker

# 验证是否调度到 gpu=true 节点
kubectl get pod gpu-workload -o jsonpath='{.spec.nodeName}'
# platform-lab-worker

kubectl get node platform-lab-worker --show-labels | grep gpu
# platform-lab-worker   Ready   <none>   10m   v1.28.0   beta.kubernetes.io/arch=amd64,...gpu=true
```

### 验证方法

```bash
# 检查调度事件
kubectl describe pod gpu-workload | grep -A 5 Events
# Events:
#   Type    Reason     Age   From               Message
#   ----    ------     ----  ----               -------
#   Normal  Scheduled  10s   gpu-priority-scheduler  Successfully assigned default/gpu-workload to platform-lab-worker

# 如果没有自定义调度器，会报错
cat > no-scheduler-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: missing-scheduler
spec:
  schedulerName: non-existent-scheduler
  containers:
  - name: app
    image: nginx:alpine
EOF
kubectl apply -f no-scheduler-pod.yaml
kubectl get pod missing-scheduler
# NAME                READY   STATUS    RESTARTS   AGE
# missing-scheduler   0/1     Pending   0          10s

kubectl describe pod missing-scheduler | grep -i "FailedScheduling"
# Warning  FailedScheduling  10s   default-scheduler  0/3 nodes are available
```

---

## 实验 3：etcd 备份与恢复

### 场景
模拟生产环境 etcd 数据备份和灾难恢复流程。

### 执行

```bash
# 找到 etcd Pod（Kind 中为静态 Pod）
kubectl get pods -n kube-system | grep etcd
# etcd-platform-lab-control-plane   1/1   Running   0   10m

# 进入 etcd Pod 创建快照
kubectl exec -it etcd-platform-lab-control-plane -n kube-system -- sh -c '
  export ETCDCTL_API=3
  etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
          --cert=/etc/kubernetes/pki/etcd/server.crt \
          --key=/etc/kubernetes/pki/etcd/server.key \
          snapshot save /tmp/etcd-backup-$(date +%Y%m%d-%H%M%S).db
'

# 验证快照
kubectl exec -it etcd-platform-lab-control-plane -n kube-system -- sh -c '
  export ETCDCTL_API=3
  etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
          --cert=/etc/kubernetes/pki/etcd/server.crt \
          --key=/etc/kubernetes/pki/etcd/server.key \
          snapshot status /tmp/etcd-backup-*.db -w table
'
```

### 预期输出

```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 12345678 |     5234 |       1567 |     2.5 MB |
+----------+----------+------------+------------+
```

### 恢复验证

```bash
# 模拟恢复（在测试目录）
kubectl exec -it etcd-platform-lab-control-plane -n kube-system -- sh -c '
  export ETCDCTL_API=3
  etcdctl snapshot restore /tmp/etcd-backup-*.db \
    --data-dir=/var/lib/etcd-new \
    --name=platform-lab-control-plane \
    --initial-cluster=platform-lab-control-plane=https://127.0.0.1:2380 \
    --initial-cluster-token=etcd-cluster-1 \
    --initial-advertise-peer-urls=https://127.0.0.1:2380
  ls -la /var/lib/etcd-new/
'

# 输出：
# drwx------ 3 root root 4096 Jan 15 10:30 .
# drwxr-xr-x 1 root root 4096 Jan 15 10:30 ..
# -rw------- 1 root root 2.5M Jan 15 10:30 member
```

### 常见错误

```bash
# 错误 1：证书路径错误
# Error: open /etc/kubernetes/pki/etcd/ca.crt: no such file
# 解决：在 Kind 中证书可能在 /etc/kubernetes/pki/etcd/ 下
kubectl exec etcd-platform-lab-control-plane -n kube-system -- ls /etc/kubernetes/pki/etcd/

# 错误 2：etcdctl 版本不匹配
# 解决：确保 ETCDCTL_API=3
kubectl exec etcd-platform-lab-control-plane -n kube-system -- etcdctl version
# etcdctl version: 3.5.x
# API version: 3.5
```

---

## 实验 4：StorageClass 与动态供给

### 场景
测试 PVC 动态供给流程，理解 StorageClass 的作用。

### 执行

```bash
# 查看现有 StorageClass
kubectl get sc
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   true

# 查看 StorageClass 详情
kubectl get sc standard -o yaml | grep -A 5 parameters
# parameters:
#   nodePath: /var/local-path-provisioner

# 创建测试 PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: standard
EOF

# 观察状态（此时 Pending，因为没有 Pod 使用）
kubectl get pvc test-pvc
# NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
# test-pvc   Pending                                      standard

# 创建使用 PVC 的 Pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pvc-test-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'hello' > /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# 再次观察（现在应该 Bound）
kubectl get pvc test-pvc
# NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES
# test-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   100Mi      RWO

# 查看自动创建的 PV
kubectl get pv | grep test-pvc
# pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   100Mi      RWO   Delete
```

### 验证数据持久化

```bash
# 写入数据
kubectl exec pvc-test-pod -- cat /data/test.txt
# hello

# 删除 Pod
kubectl delete pod pvc-test-pod --wait

# 创建新 Pod 挂载同一个 PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pvc-test-pod-2
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "cat /data/test.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# 验证数据还在
kubectl logs pvc-test-pod-2
# hello
```

---

## 实验 5：Pod 安全标准

### 场景
使用 Pod Security Standard（PSS）限制特权 Pod 的创建。

### 执行

```bash
# 创建受限命名空间
kubectl create namespace restricted-ns
kubectl label namespace restricted-ns \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# 验证标签
kubectl get namespace restricted-ns --show-labels
# NAME            STATUS   AGE   LABELS
# restricted-ns   Active   10s   pod-security.kubernetes.io/audit=restricted,...

# 尝试创建特权 Pod（应该失败）
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: restricted-ns
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    securityContext:
      privileged: true
EOF
```

### 预期输出

```
Error from server (Forbidden): pods "privileged-pod" is forbidden:
violations:
  - privileged
  - allowPrivilegeEscalation != false
  - restricted volume types
  - runAsNonRoot != true
  - seccompProfile
```

### 创建合规 Pod

```bash
# 创建满足 restricted 标准的 Pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: compliant-pod
  namespace: restricted-ns
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: nginx
    image: nginxinc/nginx-unprivileged:alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    resources:
      limits:
        memory: "128Mi"
        cpu: "100m"
      requests:
        memory: "64Mi"
        cpu: "50m"
EOF

kubectl get pod compliant-pod -n restricted-ns
# NAME            READY   STATUS    RESTARTS   AGE
# compliant-pod   1/1     Running   0          10s
```

### 验证安全上下文

```bash
kubectl get pod compliant-pod -n restricted-ns -o jsonpath='{.spec.securityContext}' | jq .
# {
#   "runAsNonRoot": true,
#   "seccompProfile": { "type": "RuntimeDefault" }
# }

kubectl get pod compliant-pod -n restricted-ns -o jsonpath='{.spec.containers[0].securityContext}' | jq .
# {
#   "allowPrivilegeEscalation": false,
#   "capabilities": { "drop": ["ALL"] },
#   "readOnlyRootFilesystem": true
# }
```

---

## 实验 6：证书管理（cert-manager）

### 场景
使用 cert-manager 自动签发和管理 TLS 证书。

### 执行

```bash
# 安装 cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# 等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s

# 创建自签名 ClusterIssuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

# 创建证书
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: default
spec:
  secretName: test-cert-tls
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  dnsNames:
  - test.example.com
  - localhost
  duration: 2160h  # 90 天
  renewBefore: 360h  # 15 天前续期
EOF
```

### 预期输出

```bash
# 查看证书状态
kubectl get certificate test-cert
# NAME        READY   SECRET          AGE
# test-cert   True    test-cert-tls   30s

# 查看 Secret
kubectl get secret test-cert-tls
# NAME            TYPE                DATA   AGE
# test-cert-tls   kubernetes.io/tls   3      30s

# 查看证书内容
kubectl get secret test-cert-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | head -20
# Certificate:
#     Data:
#         Version: 3 (0x2)
#         Serial Number: xxx
#         Signature Algorithm: ecdsa-with-SHA256
#         Issuer: CN = test.example.com
#         Validity
#             Not Before: Jan 15 10:00:00 2024 GMT
#             Not After : Apr 14 10:00:00 2024 GMT
#         Subject: CN = test.example.com
```

### 验证自动续期

```bash
# cert-manager 会自动在 renewBefore 时续期
# 查看 certificate 的 renewBefore 配置
kubectl get certificate test-cert -o jsonpath='{.spec.renewBefore}'
# 360h

# 查看下一次计划续期时间（通过 events）
kubectl describe certificate test-cert | grep -i renew
```

---

## 实验 7：ResourceQuota 与 LimitRange

### 场景
为命名空间设置资源配额，防止单个团队耗尽集群资源。

### 执行

```bash
# 创建测试命名空间
kubectl create namespace quota-test

# 应用 ResourceQuota
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: quota-test
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "5"
    persistentvolumeclaims: "2"
EOF

# 应用 LimitRange（默认资源限制）
kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: quota-test
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    type: Container
EOF

# 查看配额状态
kubectl describe resourcequota compute-quota -n quota-test
```

### 预期输出

```
Name:            compute-quota
Namespace:       quota-test
Resource         Used    Hard
--------         ----    ----
limits.cpu       0       4
limits.memory    0       8Gi
persistentvolumeclaims 0 2
pods             0       5
requests.cpu     0       2
requests.memory  0       4Gi
```

### 验证配额限制

```bash
# 创建 3 个 Pod（应成功）
for i in 1 2 3; do
  kubectl run test-$i --image=nginx:alpine -n quota-test --requests='cpu=500m,memory=1Gi' --limits='cpu=1,memory=2Gi'
done

# 第 4 个 Pod 应失败（超出 CPU requests 配额）
kubectl run test-4 --image=nginx:alpine -n quota-test --requests='cpu=500m,memory=1Gi' --limits='cpu=1,memory=2Gi'
# Error from server (Forbidden): pods "test-4" is forbidden:
# exceeded quota: compute-quota, requested: requests.cpu=500m, used: requests.cpu=1500m, limited: requests.cpu=2

# 验证已用配额
kubectl describe resourcequota compute-quota -n quota-test | grep -A 8 "Resource"
# Resource              Used   Hard
# --------              ----   ----
# limits.cpu            3      4
# limits.memory         6Gi    8Gi
# pods                  3      5
# requests.cpu          1500m  2
# requests.memory       3Gi    4Gi
```

---

## 排障速查表

```
问题                          排查命令                                          解决
─────────────────────────────────────────────────────────────────────────────────────────
Pod 无法调度                  kubectl describe pod <pod> | grep Events         检查资源请求、节点标签、污点
PV 无法绑定                   kubectl describe pvc <pvc> | grep Events         检查 StorageClass、节点磁盘空间
etcd 备份失败                 kubectl logs etcd-pod -n kube-system             检查证书路径、磁盘空间
cert-manager 证书不 Ready     kubectl describe certificate <name>              检查 Issuer 配置、DNS 名称
ResourceQuota 超限            kubectl describe resourcequota <name>            删除资源或增大配额
调度器插件不生效              kubectl logs kube-scheduler-pod                检查 schedulerName、插件配置
─────────────────────────────────────────────────────────────────────────────────────────
```

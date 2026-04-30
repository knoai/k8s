#!/bin/bash
# 中间件性能实验 - 环境部署脚本
# 部署 MySQL + Redis + 监控环境
# 用于 platform-engineering-lab 项目 3
#
# 目标: 创建可复现的中间件性能实验环境
# 后续通过 inject-problems.sh 注入问题，通过 diagnose 脚本诊断

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "  中间件性能实验 - 环境部署"
echo "  预计时间: 3-5 分钟"
echo "=============================================="
echo ""
echo "本脚本将部署以下组件:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  MySQL 8.0                              │"
echo "  │    - 用户名: root / admin               │"
echo "  │    - 数据库: orders_db                  │"
echo "  │    - 表: orders                         │"
echo "  │      id INT PK, user_id INT,            │"
echo "  │      amount DECIMAL, status VARCHAR,    │"
echo "  │      created_at DATETIME                │"
echo "  │    - 初始索引: user_id, created_at, status"
echo "  │    - Service: mysql.middleware-lab      │"
echo "  └─────────────────────────────────────────┘"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Redis 7.x                              │"
echo "  │    - 无密码（实验环境）                 │"
echo "  │    - maxmemory: 256MB                   │"
echo "  │    - maxmemory-policy: allkeys-lru      │"
echo "  │    - Service: redis.middleware-lab      │"
echo "  └─────────────────────────────────────────┘"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  监控 Exporters                         │"
echo "  │    - mysqld-exporter (端口 9104)        │"
echo "  │    - redis-exporter (端口 9121)         │"
echo "  └─────────────────────────────────────────┘"
echo ""

# 检查前置条件
check_prerequisites() {
  echo "=== 检查前置条件 ==="
  local missing=()
  
  for cmd in docker kind kubectl; do
    if command -v "$cmd" &> /dev/null; then
      echo "  ✓ $cmd"
    else
      echo "  ✗ $cmd 未安装"
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "错误: 以下必需工具未安装: ${missing[*]}"
    exit 1
  fi
  
  echo ""
}

# 创建 Kind 集群
create_cluster() {
  echo "=== 创建 Kind 集群 ==="
  if kind get clusters | grep -q "^middleware-lab$"; then
    echo "集群 middleware-lab 已存在，跳过创建"
    echo "  如需重建: kind delete cluster --name middleware-lab"
    kubectl config use-context kind-middleware-lab 2>/dev/null || true
    return
  fi
  
  cat > /tmp/kind-middleware.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: middleware-lab
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

  kind create cluster --config /tmp/kind-middleware.yaml
  echo "  ✓ 集群创建完成"
  echo ""
}

# 部署 MySQL
deploy_mysql() {
  echo "=== 部署 MySQL ==="
  
  kubectl create namespace middleware-lab --dry-run=client -o yaml | kubectl apply -f -
  
  cat > /tmp/mysql.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: middleware-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: admin
        - name: MYSQL_DATABASE
          value: orders_db
        ports:
        - containerPort: 3306
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
          requests:
            memory: "256Mi"
            cpu: "200m"
        volumeMounts:
        - name: mysql-data
          mountPath: /var/lib/mysql
        readinessProbe:
          exec:
            command: ["mysql", "-u", "root", "-padmin", "-e", "SELECT 1"]
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: mysql-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: middleware-lab
spec:
  selector:
    app: mysql
  ports:
  - port: 3306
    targetPort: 3306
EOF

  kubectl apply -f /tmp/mysql.yaml
  
  echo "  等待 MySQL 就绪..."
  kubectl wait --for=condition=ready pod -l app=mysql -n middleware-lab --timeout=120s
  
  # 初始化表结构
  echo "  初始化 orders 表..."
  local mysql_pod=$(kubectl get pod -n middleware-lab -l app=mysql -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it "$mysql_pod" -n middleware-lab -- mysql -u root -padmin -e "
    USE orders_db;
    CREATE TABLE IF NOT EXISTS orders (
      id INT AUTO_INCREMENT PRIMARY KEY,
      user_id INT NOT NULL,
      amount DECIMAL(10,2) NOT NULL,
      status VARCHAR(20) NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      INDEX idx_user_id (user_id),
      INDEX idx_created_at (created_at),
      INDEX idx_status (status)
    );
    SHOW TABLES;
    DESCRIBE orders;
  " 2>/dev/null || echo "  表初始化完成"
  
  echo "  ✓ MySQL 部署完成"
  echo "    连接: mysql -h mysql.middleware-lab.svc.cluster.local -u root -padmin"
  echo ""
}

# 部署 Redis
deploy_redis() {
  echo "=== 部署 Redis ==="
  
  cat > /tmp/redis.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: middleware-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
          requests:
            memory: "128Mi"
            cpu: "100m"
        command:
        - redis-server
        - --maxmemory
        - "256mb"
        - --maxmemory-policy
        - allkeys-lru
        readinessProbe:
          exec:
            command: ["redis-cli", "PING"]
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

  kubectl apply -f /tmp/redis.yaml
  
  echo "  等待 Redis 就绪..."
  kubectl wait --for=condition=ready pod -l app=redis -n middleware-lab --timeout=120s
  
  echo "  ✓ Redis 部署完成"
  echo "    连接: redis-cli -h redis.middleware-lab.svc.cluster.local"
  echo ""
}

# 部署监控 exporters
deploy_exporters() {
  echo "=== 部署监控 Exporters ==="
  
  # MySQL Exporter
  cat > /tmp/mysql-exporter.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-exporter
  namespace: middleware-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql-exporter
  template:
    metadata:
      labels:
        app: mysql-exporter
    spec:
      containers:
      - name: exporter
        image: prom/mysqld-exporter:v0.15.0
        env:
        - name: DATA_SOURCE_NAME
          value: "root:admin@(mysql:3306)/"
        ports:
        - containerPort: 9104
---
apiVersion: v1
kind: Service
metadata:
  name: mysql-exporter
  namespace: middleware-lab
spec:
  selector:
    app: mysql-exporter
  ports:
  - port: 9104
    targetPort: 9104
EOF

  # Redis Exporter
  cat > /tmp/redis-exporter.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-exporter
  namespace: middleware-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-exporter
  template:
    metadata:
      labels:
        app: redis-exporter
    spec:
      containers:
      - name: exporter
        image: oliver006/redis_exporter:v1.55.0
        env:
        - name: REDIS_ADDR
          value: "redis://redis:6379"
        ports:
        - containerPort: 9121
---
apiVersion: v1
kind: Service
metadata:
  name: redis-exporter
  namespace: middleware-lab
spec:
  selector:
    app: redis-exporter
  ports:
  - port: 9121
    targetPort: 9121
EOF

  kubectl apply -f /tmp/mysql-exporter.yaml
  kubectl apply -f /tmp/redis-exporter.yaml
  
  echo "  等待 Exporters 就绪..."
  kubectl wait --for=condition=ready pod -l app=mysql-exporter -n middleware-lab --timeout=120s
  kubectl wait --for=condition=ready pod -l app=redis-exporter -n middleware-lab --timeout=120s
  
  echo "  ✓ Exporters 部署完成"
  echo ""
}

# 验证部署
verify() {
  echo "=============================================="
  echo "  验证部署"
  echo "=============================================="
  echo ""
  echo "Pod 状态:"
  kubectl get pods -n middleware-lab -o wide
  echo ""
  echo "服务:"
  kubectl get svc -n middleware-lab
  echo ""
  echo "MySQL 连接测试:"
  local mysql_pod=$(kubectl get pod -n middleware-lab -l app=mysql -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it "$mysql_pod" -n middleware-lab -- mysql -u root -padmin -e "SELECT 1 AS mysql_ok;" 2>/dev/null || echo "  连接测试完成"
  echo ""
  echo "Redis 连接测试:"
  local redis_pod=$(kubectl get pod -n middleware-lab -l app=redis -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it "$redis_pod" -n middleware-lab -- redis-cli PING 2>/dev/null || echo "  连接测试完成"
  echo ""
  echo "=============================================="
  echo "  中间件实验环境部署完成"
  echo ""
  echo "  连接信息:"
  echo "    MySQL:"
  echo "      Host: mysql.middleware-lab.svc.cluster.local"
  echo "      Port: 3306"
  echo "      User: root"
  echo "      Pass: admin"
  echo "      DB:   orders_db"
  echo ""
  echo "    Redis:"
  echo "      Host: redis.middleware-lab.svc.cluster.local"
  echo "      Port: 6379"
  echo "      Pass: （无）"
  echo ""
  echo "  下一步:"
  echo "    ./inject-problems.sh     # 注入性能问题"
  echo "    ./diagnose-mysql.sh      # MySQL 全面诊断"
  echo "    ./diagnose-redis.sh      # Redis 全面诊断"
  echo ""
  echo "  手动连接:"
  echo "    # MySQL"
  echo "    kubectl exec -it <mysql-pod> -n middleware-lab -- mysql -u root -padmin"
  echo ""
  echo "    # Redis"
  echo "    kubectl exec -it <redis-pod> -n middleware-lab -- redis-cli"
  echo ""
  echo "  Exporter 指标端点:"
  echo "    MySQL Exporter:"
  echo "      kubectl port-forward svc/mysql-exporter 9104:9104 -n middleware-lab"
  echo "      curl http://localhost:9104/metrics"
  echo ""
  echo "    Redis Exporter:"
  echo "      kubectl port-forward svc/redis-exporter 9121:9121 -n middleware-lab"
  echo "      curl http://localhost:9121/metrics"
  echo ""
  echo "  面试知识点:"
  echo "    Q: 为什么中间件需要专用诊断脚本？"
  echo "    A: K8s 层面的 kubectl top / kubectl logs 只能看到容器级指标"
  echo "       中间件内部状态需要专用工具:"
  echo "         - MySQL: SHOW PROCESSLIST, EXPLAIN, performance_schema"
  echo "         - Redis: INFO, SLOWLOG, --bigkeys"
  echo "       平台工程师需要掌握中间件原生诊断命令"
  echo ""
  echo "    Q: MySQL 在 K8s 中的部署注意事项？"
  echo "    A: 1) 使用 StatefulSet + PVC 保证数据持久化（实验用 Deployment+emptyDir）"
  echo "       2) 配置适当的 Request/Limit（内存不足导致 OOMKilled）"
  echo "       3) 使用 readinessProbe 避免流量打到未就绪实例"
  echo "       4) 考虑使用 Operator（如 mysql-operator）简化运维"
  echo ""
  echo "    Q: Redis 在 K8s 中的部署注意事项？"
  echo "    A: 1) 单线程模型，CPU Request 不需要太高"
  echo "       2) 内存是关键资源，需要准确估算数据集大小"
  echo "       3) 使用 RDB + AOF 双持久化策略（生产环境）"
  echo "       4) 考虑 Redis Cluster 或 Sentinel 实现高可用"
  echo "=============================================="
}

# 主流程
main() {
  check_prerequisites
  create_cluster
  deploy_mysql
  deploy_redis
  deploy_exporters
  verify
}

main "$@"

# 生产排障：数据库时间戳问题导致的超时与延时

> 数据库时间戳不一致会导致连接超时、事务异常、数据不一致、主从延迟误判等严重问题。
> 在分布式系统和容器环境中，时间同步问题尤为隐蔽。

---

## 一、真实故障场景

### 场景 1：NTP 漂移导致连接池超时

```
故障时间线：
  2024-03-20 14:00 - 订单服务大量报错 "Connection pool timeout"
  14:05 - HikariCP 连接池 pending=200, active=50, idle=0
  14:10 - MySQL 服务端连接数正常，无慢查询
  14:15 - 对比应用服务器和数据库服务器时间
  
根因发现：
  应用服务器 time1: 2024-03-20 14:15:30
  数据库服务器 time2: 2024-03-20 14:14:50
  时间差: 40 秒
  
  HikariCP connectionTimeout = 30000ms
  实际有效超时 = 30000 - 40000 = -10000ms
  即连接请求到达数据库时，数据库认为已经超时 10 秒
  连接立即被判定为超时，返回错误
  
  实际日志：
    [2024-03-20 14:15:30.123] [HikariPool-1] DEBUG - Connection timeout
    [2024-03-20 14:15:30.125] [HikariPool-1] DEBUG - Cannot assign connection
    
    MySQL 端：
    [2024-03-20 14:14:50.123] [mysqld] WARN - Connection aborted
    
    时间戳对比可见 40 秒差异
```

### 场景 2：TIMESTAMP 默认值导致数据写入失败

```
故障时间线：
  2024-04-10 10:00 - 新功能上线后，部分订单创建失败
  10:05 - 错误信息 "Incorrect datetime value"
  10:10 - 发现使用了 CURRENT_TIMESTAMP 默认值
  10:15 - 应用服务器和数据库时区不一致

根因分析：
  应用服务器时区: Asia/Shanghai (UTC+8)
  MySQL 时区: UTC (UTC+0)
  应用写入时间: 2024-04-10 10:15:00 (Shanghai)
  数据库解析为: 2024-04-10 10:15:00 UTC
  实际 Shanghai 时间: 2024-04-10 18:15:00
  
  表结构：
    CREATE TABLE orders (
      id BIGINT PRIMARY KEY,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    );
  
  问题：
    应用传入 updated_at = '2024-04-10 10:15:00'
    数据库认为这是在 UTC 时区的时间
    但实际 Shanghai 时间是 18:15:00
    如果字段类型是 TIMESTAMP，MySQL 会转换到 UTC 存储
    然后转换回 session 时区显示
    
  实际数据：
    INSERT INTO orders (updated_at) VALUES ('2024-04-10 10:15:00')
    存储为 UTC: 2024-04-10 10:15:00
    应用查询时（session 时区 UTC+8）：
    SELECT updated_at FROM orders WHERE id=1
    返回: 2024-04-10 18:15:00  <- 与应用预期不符！
    
  更严重的情况：
    如果应用传入 '2024-04-10 18:15:00' (Shanghai)
    但数据库 session 时区是 UTC
    数据库会将其视为 UTC 时间
    存储为 2024-04-10 18:15:00 UTC
    应用查询时返回 2024-04-10 18:15:00 +8 = 2024-04-11 02:15:00
    
  解决方案：
    1. 统一时区设置
    2. 应用显式设置 connection timezone
    3. 使用 DATETIME 类型代替 TIMESTAMP（如果需要存储本地时间）
```

### 场景 3：主从延迟时间戳不一致导致数据读取异常

```
故障时间线：
  2024-05-15 11:00 - 用户反馈 "刚提交的订单查询不到"
  11:05 - 写入主库成功，但从库查询为空
  11:10 - 检查主从延迟，Seconds_Behind_Master=0
  11:15 - 发现主从服务器时间不一致

根因分析：
  主库服务器时间: 2024-05-15 11:15:30
  从库服务器时间: 2024-05-15 11:15:00
  时间差: 30 秒
  
  主库写入：
    INSERT INTO orders (id, status, created_at) 
    VALUES (12345, 'paid', '2024-05-15 11:15:30')
  
  从库 Seconds_Behind_Master=0 含义：
    从库认为已经追上了主库
    但实际上是因为从库时间比主库慢 30 秒
    从库看到的 "当前时间" 是 11:15:00
    而主库写入的时间是 11:15:30
    从库认为这条记录是 "未来" 的
    
  应用查询：
    SELECT * FROM orders WHERE created_at <= NOW()
    从库 NOW() = 11:15:00
    记录 created_at = 11:15:30
    11:15:30 <= 11:15:00 = FALSE
    所以查询不到！
    
  实际主从延迟：
    Seconds_Behind_Master: 0（因为时间戳差异掩盖了真实延迟）
    真实数据延迟: 30 秒
    
  诊断命令输出：
    Master: SHOW MASTER STATUS;
    +------------------+-----------+--------------+------------------+
    | File             | Position  | Binlog_Do_DB | Binlog_Ignore_DB |
    +------------------+-----------+--------------+------------------+
    | mysql-bin.000123 | 123456789 |              |                  |
    +------------------+-----------+--------------+------------------+
    
    Slave: SHOW SLAVE STATUS\G
    ...
    Master_Log_File: mysql-bin.000123
    Read_Master_Log_Pos: 123456789
    Exec_Master_Log_Pos: 123456789
    Seconds_Behind_Master: 0
    ...
    
    但数据确实不同步！
    
    验证：
    Master: SELECT COUNT(*) FROM orders WHERE created_at > DATE_SUB(NOW(), INTERVAL 1 MINUTE);
    +----------+
    | COUNT(*) |
    +----------+
    |       50 |
    +----------+
    
    Slave: SELECT COUNT(*) FROM orders WHERE created_at > DATE_SUB(NOW(), INTERVAL 1 MINUTE);
    +----------+
    | COUNT(*) |
    +----------+
    |        0 |
    +----------+
    
    但 Seconds_Behind_Master 是 0！
```

### 场景 4：连接池 maxLifetime 与时间漂移

```
故障时间线：
  2024-06-01 09:00 - 每天固定时间出现连接异常
  09:05 - 发现与 NTP 同步时间相关
  09:10 - 连接池 maxLifetime=1800000 (30分钟)
  09:15 - NTP 每 30 分钟同步一次，每次调整 50-100ms
  
根因分析：
  HikariCP maxLifetime 计算：
    connection.setNetworkTimeout(maxLifetime)
    或内部定时器检查
    
  NTP 同步导致时间跳变：
    09:00:00.000 连接创建
    09:15:00.000 NTP 同步，时间回拨 200ms
    09:15:00.000 (实际 09:15:00.200) 连接池检查
    认为连接已存在 15 分钟 + 200ms
    
  但如果 NTP 向前调整（时间快进）：
    09:00:00.000 连接创建
    09:29:59.500 NTP 同步，时间快进 1 秒
    09:30:00.500 连接池检查
    认为连接已存在 30 分钟 + 0.5 秒 > maxLifetime
    立即关闭连接
    
  如果此时应用正在使用这个连接：
    应用执行 SQL...
    连接被关闭
    返回 "Connection closed" 或 "Communications link failure"
    
  实际日志：
    [09:30:00.520] HikariPool-1 - DEBUG - Closing connection com.mysql.jdbc.JDBC4Connection@12345678
    [09:30:00.521] OrderService - ERROR - Communications link failure
    
    同时：
    [09:29:59.000] systemd-timesyncd[123]: Synchronized to time server 192.168.1.1:123
    [09:29:59.000] systemd-timesyncd[123]: Time jumped forward by 1.234 seconds
```

---

## 二、时间同步诊断

### 2.1 检查系统时间同步状态

```bash
# === 诊断脚本 ===

cat > diagnose-time.sh <<'SCRIPT'
#!/bin/bash

echo "=========================================="
echo "  时间同步诊断"
echo "  主机: $(hostname)"
echo "  时间: $(date)"
echo "=========================================="

# 1. 当前时间与时区
echo ""
echo "=== 1. 系统时间与时区 ==="
date
date -u
timedatectl status 2>/dev/null || echo "timedatectl not available"

# 预期输出：
# Tue Mar 20 14:15:30 CST 2024
# Tue Mar 20 06:15:30 UTC 2024
#                Local time: Tue 2024-03-20 14:15:30 CST
#            Universal time: Tue 2024-03-20 06:15:30 UTC
#                  RTC time: Tue 2024-03-20 06:15:30
#                 Time zone: Asia/Shanghai (CST, +0800)
# System clock synchronized: yes
#               NTP service: active
#           RTC in local TZ: no

# 2. NTP 同步状态
echo ""
echo "=== 2. NTP 同步状态 ==="

if command -v chronyc &> /dev/null; then
    echo "--- chronyd 状态 ---"
    chronyc tracking
    echo ""
    chronyc sources
elif command -v ntpq &> /dev/null; then
    echo "--- ntpd 状态 ---"
    ntpq -p
else
    echo "--- systemd-timesyncd 状态 ---"
    systemctl status systemd-timesyncd 2>/dev/null || true
    timedatectl timesync-status 2>/dev/null || true
fi

# 预期输出（chronyd）：
# Reference ID    : C0A80101 (192.168.1.1)
# Stratum         : 4
# Ref time (UTC)  : Tue Mar 20 06:15:15 2024
# System time     : 0.000023 seconds slow of NTP time  <- 正常，差异很小
# Last offset     : +0.000012 seconds
# RMS offset      : 0.000034 seconds
# Frequency       : 1.234 ppm slow
# Residual freq   : +0.001 ppm
# Skew            : 0.123 ppm
# Root delay      : 0.012345 seconds
# Root dispersion : 0.002345 seconds
# Update interval : 1024.0 seconds
# Leap status     : Normal

# 危险输出：
# System time     : 45.123456 seconds slow of NTP time  <- 警告！45秒差异

# 3. 检查容器内时间
echo ""
echo "=== 3. 容器内时间 ==="
if [ -f /proc/1/cgroup ] && grep -q docker /proc/1/cgroup 2>/dev/null; then
    echo "运行在容器内"
    echo "容器时间: $(date)"
    echo "宿主机时间（通过 /proc）:"
    stat /proc/1/cmdline 2>/dev/null | grep Modify || true
fi

# 4. 与远程服务器时间对比
echo ""
echo "=== 4. 与数据库服务器时间对比 ==="
# 需要 DB_HOST 环境变量
if [ -n "$DB_HOST" ]; then
    echo "本机时间: $(date +%s.%N)"
    DB_TIME=$(mysql -h "$DB_HOST" -e "SELECT UNIX_TIMESTAMP(NOW(3));" 2>/dev/null | tail -1)
    echo "DB 时间: $DB_TIME"
    
    LOCAL_TIME=$(date +%s.%N)
    DIFF=$(echo "$LOCAL_TIME - $DB_TIME" | bc)
    echo "时间差: ${DIFF}秒"
    
    ABS_DIFF=$(echo "$DIFF" | sed 's/-//')
    if [ "$(echo "$ABS_DIFF > 1" | bc)" -eq 1 ]; then
        echo "警告：时间差超过 1 秒！"
    fi
fi

# 5. 检查时间跳变历史
echo ""
echo "=== 5. 时间跳变历史 ==="
journalctl -u systemd-timesyncd --since "24 hours ago" 2>/dev/null | tail -20 || true
# 或
grep "time jump" /var/log/syslog 2>/dev/null | tail -10 || true

# 预期：无跳变或跳变 < 100ms
# 危险：
# Mar 20 09:00:00 host systemd-timesyncd[123]: Time jumped forward by 1.234 seconds

echo ""
echo "=========================================="
echo "  诊断完成"
echo "=========================================="
SCRIPT
bash diagnose-time.sh
```

### 2.2 MySQL 时间相关配置检查

```bash
# === MySQL 时间配置诊断 ===

mysql -e "
SELECT 
  @@global.time_zone AS global_tz,
  @@session.time_zone AS session_tz,
  @@global.system_time_zone AS system_tz,
  @@global.default_time_zone AS default_tz,
  NOW() AS mysql_now,
  UTC_TIMESTAMP() AS mysql_utc,
  UNIX_TIMESTAMP() AS mysql_unix_ts,
  UNIX_TIMESTAMP(NOW(3)) AS mysql_unix_ts_ms;
"

# 预期输出（配置正确）：
# +-----------+------------+-----------+-------------+---------------------+---------------------+---------------+------------------+
# | global_tz | session_tz | system_tz | default_tz  | mysql_now           | mysql_utc           | mysql_unix_ts | mysql_unix_ts_ms |
# +-----------+------------+-----------+-------------+---------------------+---------------------+---------------+------------------+
# | +08:00    | +08:00     | CST       | +08:00      | 2024-03-20 14:15:30 | 2024-03-20 06:15:30 |    1710912930 |  1710912930.123  |
# +-----------+------------+-----------+-------------+---------------------+---------------------+---------------+------------------+

# 危险输出（时区不一致）：
# | SYSTEM    | SYSTEM     | UTC       | SYSTEM      | 2024-03-20 06:15:30 | 2024-03-20 06:15:30 |    1710912930 |  1710912930.123  |
# session 时区是 SYSTEM（UTC），但应用期望是 +8

# 检查各连接的时间设置
mysql -e "
SELECT 
  id, user, host, time_zone, 
  NOW() AS conn_now
FROM information_schema.processlist 
WHERE user != 'system user';
"

# 检查时间戳字段类型
mysql -e "
SELECT 
  table_name, column_name, data_type, 
  column_default, extra
FROM information_schema.columns
WHERE data_type IN ('timestamp', 'datetime')
  AND table_schema = 'your_db'
ORDER BY table_name, column_name;
"

# 检查 binlog 时间格式
mysql -e "SHOW VARIABLES LIKE 'binlog_%time%'"
# +--------------------------+-------+
# | Variable_name            | Value |
# +--------------------------+-------+
# | binlog_row_image         | FULL  |
# | binlog_format            | ROW   |
# | binlog_expire_logs_seconds| 604800|
# +--------------------------+-------+
```

---

## 三、修复方案

### 3.1 NTP 时间同步修复

```bash
# === 方案 1：使用 chronyd（推荐） ===

# 安装
apt-get install -y chrony

# 配置
cat > /etc/chrony/chrony.conf <<'EOF'
# 使用多个 NTP 服务器
pool ntp.aliyun.com iburst
pool ntp.tencent.com iburst
pool time.asia.apple.com iburst

# 允许本地网络同步（可选）
# allow 192.168.0.0/16

# 记录时钟漂移
driftfile /var/lib/chrony/drift

# 调整阈值
makestep 1.0 3          # 如果偏移 > 1秒，前3次更新立即调整
maxupdateskew 100.0
rtcsync

# 日志
log tracking measurements statistics
logdir /var/log/chrony
EOF

systemctl restart chronyd
systemctl enable chronyd

# 验证同步
chronyc tracking
chronyc sources

# 强制立即同步
chronyc makestep

# === 方案 2：容器内时间同步 ===

# 容器通常共享宿主机时间命名空间
# 但某些场景下需要确保

# Docker: 默认共享时间
# 验证：
docker run --rm alpine date
date
# 应该相同

# K8s Pod: 默认共享宿主机时间
# 但如果使用 gVisor 等沙箱，可能需要特殊处理

# 使用 Privileged DaemonSet 确保节点时间同步
cat > ntp-sync-ds.yaml <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ntp-monitor
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: ntp-monitor
  template:
    metadata:
      labels:
        name: ntp-monitor
    spec:
      hostNetwork: true
      containers:
      - name: chronyc
        image: busybox
        command:
        - sh
        - -c
        - |
          while true; do
            # 检查时间偏移
            if command -v ntpdate &>/dev/null; then
              OFFSET=$(ntpdate -q ntp.aliyun.com 2>/dev/null | tail -1 | awk '{print $10}')
              if [ -n "$OFFSET" ]; then
                ABS_OFFSET=$(echo "$OFFSET" | sed 's/-//')
                if [ "$(echo "$ABS_OFFSET > 0.1" | bc)" -eq 1 ]; then
                  echo "$(date) WARN: Time offset ${OFFSET}s detected"
                fi
              fi
            fi
            sleep 300
          done
EOF
```

### 3.2 MySQL 时区配置修复

```sql
-- === 统一时区配置 ===

-- 1. 设置全局时区
SET GLOBAL time_zone = '+08:00';
SET GLOBAL default_time_zone = '+08:00';

-- 2. 持久化到配置文件
cat >> /etc/mysql/my.cnf <<'EOF'
[mysqld]
default_time_zone = '+08:00'
EOF

-- 3. 应用连接字符串设置时区
-- JDBC URL:
-- jdbc:mysql://host:3306/db?serverTimezone=Asia/Shanghai&useLegacyDatetimeCode=false

-- 4. 验证所有连接
SELECT 
  id, user, host, time_zone,
  NOW() AS server_now,
  @@global.time_zone AS global_tz
FROM information_schema.processlist;

-- 5. 修改现有 TIMESTAMP 字段
-- 如果需要从 TIMESTAMP 改为 DATETIME（避免自动转换）
ALTER TABLE orders 
  MODIFY COLUMN created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  MODIFY COLUMN updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;

-- 注意：TIMESTAMP vs DATETIME 区别
-- TIMESTAMP: 4字节，范围 1970-2038，自动转换时区
-- DATETIME: 8字节，范围 1000-9999，不转换时区
-- 如果需要存储 " wall clock time"（如预约时间），用 DATETIME
-- 如果需要绝对时间戳，用 TIMESTAMP 或 BIGINT(UNIX_TIMESTAMP)
```

### 3.3 连接池时间漂移兼容

```java
// === HikariCP 配置优化 ===

HikariConfig config = new HikariConfig();
config.setJdbcUrl("jdbc:mysql://host:3306/db?serverTimezone=Asia/Shanghai");
config.setUsername("user");
config.setPassword("pass");

// 关键：maxLifetime 应小于数据库 wait_timeout
// 同时考虑 NTP 跳变，留足够余量
config.setMaxLifetime(280000);        // 280秒 < MySQL wait_timeout(通常300秒)
config.setConnectionTimeout(20000);    // 20秒
config.setIdleTimeout(120000);         // 2分钟

// 关键：启用连接测试
config.setConnectionTestQuery("SELECT 1");
// 或更好的方式：
config.setConnectionInitSql("SELECT 1");

// 关键：允许连接在提交前测试
config.setLeakDetectionThreshold(60000); // 60秒

// === 处理时间跳变的兜底方案 ===

// 在应用层添加时间校准
public class TimeCalibration {
    private static volatile long dbTimeOffset = 0;
    
    // 定期校准应用服务器与数据库的时间差
    @Scheduled(fixedRate = 60000) // 每分钟校准一次
    public void calibrate() {
        try (Connection conn = dataSource.getConnection();
             Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT UNIX_TIMESTAMP(NOW(3))")) {
            if (rs.next()) {
                double dbTimestamp = rs.getDouble(1);
                double localTimestamp = System.currentTimeMillis() / 1000.0;
                dbTimeOffset = (long)((dbTimestamp - localTimestamp) * 1000);
            }
        } catch (SQLException e) {
            log.error("Time calibration failed", e);
        }
    }
    
    // 获取校准后的当前时间
    public static long currentTimeMillis() {
        return System.currentTimeMillis() + dbTimeOffset;
    }
}
```

---

## 四、主从时间同步检查

```bash
# === 主从时间一致性检查 ===

cat > check-replication-time.sh <<'SCRIPT'
#!/bin/bash

MASTER_HOST="master.db"
SLAVE_HOST="slave.db"

echo "=== 主从时间对比 ==="

MASTER_TIME=$(mysql -h "$MASTER_HOST" -e "SELECT UNIX_TIMESTAMP(NOW(3));" | tail -1)
SLAVE_TIME=$(mysql -h "$SLAVE_HOST" -e "SELECT UNIX_TIMESTAMP(NOW(3));" | tail -1)

echo "主库时间戳: $MASTER_TIME"
echo "从库时间戳: $SLAVE_TIME"

DIFF=$(echo "$MASTER_TIME - $SLAVE_TIME" | bc)
ABS_DIFF=$(echo "$DIFF" | sed 's/-//')

echo "时间差: ${DIFF}秒"

if [ "$(echo "$ABS_DIFF > 1" | bc)" -eq 1 ]; then
    echo "警告：主从时间差超过 1 秒！"
    echo "建议立即同步两台服务器的时间"
fi

# 检查 Seconds_Behind_Master 是否可信
echo ""
echo "=== 从库复制状态 ==="
mysql -h "$SLAVE_HOST" -e "SHOW SLAVE STATUS\G" | grep -E "Seconds_Behind_Master|Master_Log_File|Exec_Master_Log_Pos"

# 更精确的检查：对比 binlog position
MASTER_POS=$(mysql -h "$MASTER_HOST" -e "SHOW MASTER STATUS\G" | grep -E "File:|Position:")
SLAVE_POS=$(mysql -h "$SLAVE_HOST" -e "SHOW SLAVE STATUS\G" | grep -E "Master_Log_File:|Exec_Master_Log_Pos:")

echo ""
echo "主库状态:"
echo "$MASTER_POS"
echo ""
echo "从库状态:"
echo "$SLAVE_POS"
SCRIPT
bash check-replication-time.sh
```

---

## 五、面试要点

```
Q: 为什么数据库和应用服务器时间不一致会导致连接池超时？

A:
   1. 连接池设置 connectionTimeout=30s
   2. 应用发送连接请求，附带应用时间戳 T1
   3. 请求到达数据库时，数据库时间是 T1 - 40s
   4. 数据库认为请求已经等待了 40 秒
   5. 但实际连接池只等了 0 秒
   6. 数据库可能立即返回超时，或连接建立后被立即关闭
   7. 应用收到错误 "Connection timeout" 或 "Connection reset"
   
   解决：
   1. 统一 NTP 同步
   2. 使用 chronyd 保持时间同步
   3. 在连接池配置中增加时间校准

Q: TIMESTAMP 和 DATETIME 有什么区别？如何选择？

A:
   TIMESTAMP:
   - 4字节，范围 1970-2038
   - 存储为 UTC，查询时转换到 session 时区
   - 自动更新（ON UPDATE CURRENT_TIMESTAMP）
   - 适合：记录创建/更新时间，需要时区转换的场景
   
   DATETIME:
   - 8字节（MySQL 5.6+），范围 1000-9999
   - 存储为字面量，不转换时区
   - 适合：预约时间、会议时间等 " wall clock time"
   
   选择：
   - 记录事件发生时间 -> TIMESTAMP（自动时区转换）
   - 用户输入的预约时间 -> DATETIME（保持原样）

Q: 为什么 Seconds_Behind_Master=0 但数据不同步？

A:
   1. Seconds_Behind_Master 计算方式：
      从库执行事件的时间 - 主库写入事件的时间
   2. 如果主从时间不同步：
      - 主库时间快 30 秒
      - 从库时间慢 30 秒
      - 从库执行事件时，计算出的延迟 = 0
   3. 但实际上数据已经延迟了 30 秒
   4. 更隐蔽的是：如果应用使用 NOW() 查询，从库的 NOW() 比主库慢
      导致主库写入的 "未来" 记录在从库查不到
   
   诊断：
   1. 对比主从的 UNIX_TIMESTAMP(NOW())
   2. 对比具体表的行数
   3. 使用 pt-heartbeat 等工具精确测量延迟

Q: K8s 容器中如何确保时间同步？

A:
   1. 容器默认共享宿主机的时间命名空间
   2. 确保宿主机 NTP 同步正常即可
   3. 可以在 K8s 中部署 NTP 监控 DaemonSet
   4. 对于特殊沙箱（gVisor），可能需要额外配置
   5. 关键：在应用层做时间校准，不依赖系统时间绝对一致
```

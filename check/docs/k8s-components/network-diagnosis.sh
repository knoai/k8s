#!/usr/bin/env bash
# network-diagnosis.sh - 网络拨测与网段通信路径诊断工具
# 用途：判断两个 IP/网段之间是局域网通信还是外网通信

set -euo pipefail

# 颜色定义
CLR_INFO='\033[0;34m'
CLR_PASS='\033[0;32m'
CLR_WARN='\033[1;33m'
CLR_FAIL='\033[0;31m'
CLR_RESET='\033[0m'

info()  { echo -e "${CLR_INFO}[INFO]${CLR_RESET}  $*"; }
pass()  { echo -e "${CLR_PASS}[PASS]${CLR_RESET}  $*"; }
warn()  { echo -e "${CLR_WARN}[WARN]${CLR_RESET}  $*"; }
fail()  { echo -e "${CLR_FAIL}[FAIL]${CLR_RESET}  $*"; }

# 获取本机 IP 和网段
get_local_network() {
    info "本机网络接口信息："
    if command -v ip &>/dev/null; then
        ip -4 addr show | grep -E "inet |^[0-9]:" | grep -v "127.0.0.1"
    elif command -v ifconfig &>/dev/null; then
        ifconfig | grep -E "^[a-z]|inet " | grep -v "127.0.0.1"
    fi
}

# 获取子网掩码对应的 CIDR
mask_to_cidr() {
    local mask="$1"
    local cidr=0
    local octet
    for octet in $(echo "$mask" | tr '.' ' '); do
        case $octet in
            255) cidr=$((cidr+8)) ;;
            254) cidr=$((cidr+7)) ;;
            252) cidr=$((cidr+6)) ;;
            248) cidr=$((cidr+5)) ;;
            240) cidr=$((cidr+4)) ;;
            224) cidr=$((cidr+3)) ;;
            192) cidr=$((cidr+2)) ;;
            128) cidr=$((cidr+1)) ;;
            0) cidr=$((cidr+0)) ;;
        esac
    done
    echo "$cidr"
}

# 检查两个 IP 是否在同一个子网
same_subnet() {
    local ip1="$1" ip2="$2" mask="$3"
    local i1 i2 m
    i1=$(echo "$ip1" | awk -F. '{print ($1*256^3)+($2*256^2)+($3*256)+$4}')
    i2=$(echo "$ip2" | awk -F. '{print ($1*256^3)+($2*256^2)+($3*256)+$4}')
    m=$(echo "$mask" | awk -F. '{print ($1*256^3)+($2*256^2)+($3*256)+$4}')
    local net1=$((i1 & m))
    local net2=$((i2 & m))
    if [[ "$net1" == "$net2" ]]; then
        echo "same"
    else
        echo "different"
    fi
}

# 诊断两个 IP 之间的通信路径
diagnose_path() {
    local target="$1"
    info "============================================"
    info "目标: $target"
    info "============================================"

    # 1. 基础连通性测试
    info "--- 1. Ping 连通性测试 ---"
    local ping_result ping_avg ping_loss
    ping_result=$(ping -c 4 -W 2 "$target" 2>/dev/null || true)
    if echo "$ping_result" | grep -q "0.0% packet loss\| 0% packet loss"; then
        ping_avg=$(echo "$ping_result" | tail -1 | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d'/' -f2)
        if [[ -n "$ping_avg" ]]; then
            if awk "BEGIN {exit !($ping_avg < 1.0)}"; then
                pass "Ping 通，平均延迟 ${ping_avg}ms (< 1ms，极可能是局域网)"
            elif awk "BEGIN {exit !($ping_avg < 5.0)}"; then
                warn "Ping 通，平均延迟 ${ping_avg}ms (1-5ms，可能是局域网或近距离外网)"
            else
                warn "Ping 通，平均延迟 ${ping_avg}ms (> 5ms，可能是外网或跨交换机)"
            fi
        else
            pass "Ping 通"
        fi
    else
        fail "Ping 不通或丢包"
    fi

    # 2. TTL 分析
    info "--- 2. TTL (Time To Live) 分析 ---"
    local ttl_line ttl_val
    ttl_line=$(echo "$ping_result" | grep -oE "ttl=[0-9]+" | head -1 || true)
    if [[ -n "$ttl_line" ]]; then
        ttl_val=${ttl_line#ttl=}
        info "TTL = $ttl_val"
        case "$ttl_val" in
            64)  info "TTL 64: 常见于 Linux/macOS 系统" ;;
            128) info "TTL 128: 常见于 Windows 系统" ;;
            255) info "TTL 255: 常见于网络设备" ;;
            *)   info "TTL $ttl_val" ;;
        esac
        if [[ "$ttl_val" -ge 60 && "$ttl_val" -le 65 ]]; then
            info "TTL 接近初始值(64)，说明经过的路由跳数很少"
        elif [[ "$ttl_val" -lt 60 ]]; then
            warn "TTL 明显小于初始值，经过了多个路由跳"
        fi
    else
        warn "无法获取 TTL"
    fi

    # 3. Traceroute 路径跟踪
    info "--- 3. Traceroute 路由跟踪 ---"
    local tr_cmd
    if command -v traceroute &>/dev/null; then
        tr_cmd="traceroute -q 1 -w 2"
    elif command -v tracert &>/dev/null; then
        tr_cmd="tracert -h 10"
    else
        warn "未安装 traceroute，尝试使用 mtr 或 tracepath"
        if command -v mtr &>/dev/null; then
            tr_cmd="mtr -r -c 3"
        elif command -v tracepath &>/dev/null; then
            tr_cmd="tracepath"
        else
            fail "无可用路由跟踪工具"
            tr_cmd=""
        fi
    fi

    if [[ -n "$tr_cmd" ]]; then
        local tr_result
        tr_result=$($tr_cmd "$target" 2>/dev/null | head -20 || true)
        if [[ -n "$tr_result" ]]; then
            echo "$tr_result"
            local hop_count
            hop_count=$(echo "$tr_result" | grep -cE "^[ ]*[0-9]+[ ]+" || true)
            info "检测到约 $hop_count 个路由跳"
            if [[ "$hop_count" -eq 1 ]]; then
                pass "仅 1 跳，极大概率是局域网直连"
            elif [[ "$hop_count" -le 3 ]]; then
                info "1-3 跳，可能是局域网经过交换机或路由器"
            else
                warn "超过 3 跳，可能经过外网或多个网络设备"
            fi
        else
            warn "traceroute 无结果"
        fi
    fi

    # 4. ARP 解析检查
    info "--- 4. ARP 解析检查 ---"
    local arp_entry
    if command -v arp &>/dev/null; then
        arp_entry=$(arp -a | grep "$target" || true)
    elif command -v ip &>/dev/null; then
        arp_entry=$(ip neigh show | grep "$target" || true)
    fi
    if [[ -n "$arp_entry" ]]; then
        pass "ARP 表中有目标记录: $arp_entry"
        info "能直接解析到 MAC 地址，说明在同一二层网络"
    else
        warn "ARP 表中无目标记录"
        info "无法直接解析 MAC，可能不在同一二层网络（或尚未通信）"
    fi

    # 5. 路由表分析
    info "--- 5. 路由表分析 ---"
    local route_info
    if command -v ip &>/dev/null; then
        route_info=$(ip route get "$target" 2>/dev/null || true)
    elif command -v route &>/dev/null; then
        route_info=$(route -n get "$target" 2>/dev/null || true)
    fi
    if [[ -n "$route_info" ]]; then
        echo "$route_info"
        if echo "$route_info" | grep -qE "dev lo|link-local|direct|scope link"; then
            pass "路由显示为直连或本地链路"
        elif echo "$route_info" | grep -qE "via [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
            local gateway
            gateway=$(echo "$route_info" | grep -oE "via [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)
            warn "路由经过网关: $gateway"
            info "如果网关是内网路由器，则仍在局域网内"
            info "如果网关是外网出口，则经过外网"
        fi
    else
        warn "无法获取路由信息"
    fi
}

# 网段分析
analyze_network_segments() {
    local seg1="$1" seg2="$2"
    info ""
    info "============================================"
    info "网段分析: $seg1 vs $seg2"
    info "============================================"

    # 获取本机 IP
    local my_ip
    my_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || \
            ip route get 1.1.1.1 2>/dev/null | grep -oE "src [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}' || \
            ifconfig | grep -oE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}' | head -1 || \
            echo "unknown")
    info "本机 IP: $my_ip"

    # 提取网段
    local net1 net2
    net1=$(echo "$seg1" | grep -oE "^[0-9]+\.[0-9]+")
    net2=$(echo "$seg2" | grep -oE "^[0-9]+\.[0-9]+")

    info "网段 A: $net1.x.x"
    info "网段 B: $net2.x.x"

    if [[ "$net1" == "$net2" ]]; then
        pass "两个 IP 属于同一 B 类网段，极可能在同一局域网"
    else
        warn "两个 IP 属于不同 B 类网段"
    fi

    # 私有地址判断
    info ""
    info "--- 私有地址范围判断 ---"
    for seg in "$seg1" "$seg2"; do
        local ip_prefix
        ip_prefix=$(echo "$seg" | grep -oE "^[0-9]+\.[0-9]+")
        case "$ip_prefix" in
            10.*)      pass "$seg 属于 RFC1918 私有地址 (10.0.0.0/8)" ;;
            172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                       pass "$seg 属于 RFC1918 私有地址 (172.16.0.0/12)" ;;
            192.168.*) pass "$seg 属于 RFC1918 私有地址 (192.168.0.0/16)" ;;
            *)         warn "$seg 不是标准私有地址" ;;
        esac
    done
}

# 主函数
main() {
    echo ""
    info "网络通信路径诊断工具"
    info "============================================"
    echo ""

    # 显示本机网络信息
    get_local_network
    echo ""

    # 参数解析
    local target1="" target2=""
    if [[ $# -ge 1 ]]; then
        target1="$1"
    fi
    if [[ $# -ge 2 ]]; then
        target2="$2"
    fi

    # 如果没有参数，使用示例网段
    if [[ -z "$target1" ]]; then
        info "使用方式: $0 <目标IP1> [目标IP2]"
        info ""
        info "示例: $0 10.131.1.1 10.181.1.1"
        info ""
        info "请输入第一个目标 IP (10.131.x.x 网段): "
        read -r target1
        info "请输入第二个目标 IP (10.181.x.x 网段): "
        read -r target2
    fi

    if [[ -z "$target1" ]]; then
        fail "未提供目标 IP"
        exit 1
    fi

    # 诊断第一个目标
    diagnose_path "$target1"
    echo ""

    # 如果有第二个目标
    if [[ -n "$target2" ]]; then
        diagnose_path "$target2"
        echo ""
        analyze_network_segments "$target1" "$target2"
    fi

    echo ""
    info "============================================"
    info "诊断完成"
    info "============================================"
    echo ""
    info "判断局域网 vs 外网的关键指标:"
    info "  1. Ping 延迟 < 1ms: 大概率局域网"
    info "  2. Traceroute 仅 1 跳: 局域网直连"
    info "  3. ARP 能解析到 MAC: 同一二层网络"
    info "  4. 路由表显示 dev 直连: 局域网"
    info "  5. 路由经过外网网关 (如公网 IP): 外网通信"
    info "  6. TTL 明显衰减 (>5 跳): 可能经过多个路由"
}

main "$@"

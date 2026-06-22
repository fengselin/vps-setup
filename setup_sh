#!/bin/bash

# 新VPS一键设置脚本 (Nftables极速版 + Swap优化 v2)
# 特性：Nftables(分离式规则) + BBR + SSH密钥硬防(含cloud-init覆盖) + Swap(fallocate+swappiness=10)
# 用法: sudo ./setup.sh         # 交互式
#       sudo ./setup.sh --auto  # 自动配置

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局常量
SYSCTL_OPT_FILE="/etc/sysctl.d/99-vps-optimize.conf"
NFTABLES_BASE_FILE="/etc/nftables.d/10-base.conf"
SSH_DROPIN="/etc/ssh/sshd_config.d/60-security.conf"

# Mode selection
AUTO_MODE=false
if [ "$1" = "--auto" ]; then AUTO_MODE=true; fi

# Detect current SSH port
get_ssh_port() {
    local port
    port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}')
    if [ -z "$port" ]; then
        port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    fi
    echo "${port:-22}"
}

SSH_PORT=$(get_ssh_port)

print_banner() {
    echo ""
    echo -e "${GREEN}    新VPS一键设置脚本 v2 (分离式Nftables + fallocate Swap)   ${NC}"
    echo -e "${YELLOW}   Pure Performance. No Bloatware. Just Secure.               ${NC}"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}错误: 必须以root权限运行${NC}"; exit 1; fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}错误: 无法检测操作系统${NC}"; exit 1
    fi
    if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
        echo -e "${RED}错误: 仅支持 Debian/Ubuntu 系统${NC}"; exit 1
    fi
}

wait_for_apt() {
    local timeout=300; local waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -ge $timeout ]; then echo -e "${RED}apt锁超时${NC}"; return 1; fi
        echo "等待 apt 锁释放..."
        sleep 5; waited=$((waited + 5))
    done
}

update_system() {
    wait_for_apt
    echo -e "${CYAN}→ apt update${NC}"
    apt update -qq
    echo -e "${GREEN}✓ 软件包列表已更新${NC}"
}

enable_bbr() {
    echo -e "${CYAN}→ 检查并开启 TCP BBR${NC}"
    # 确保目标文件存在
    [ -f "$SYSCTL_OPT_FILE" ] || touch "$SYSCTL_OPT_FILE"
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" "$SYSCTL_OPT_FILE" 2>/dev/null; then
        cat >> "$SYSCTL_OPT_FILE" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system >/dev/null 2>&1
        echo -e "${GREEN}✓ BBR 已启用${NC}"
    else
        echo -e "${GREEN}✓ BBR 已存在，跳过${NC}"
    fi
}

configure_timezone() {
    local current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$current_tz" = "Asia/Shanghai" ]; then return; fi
    echo -e "${CYAN}→ 设置时区 Asia/Shanghai${NC}"
    timedatectl set-timezone Asia/Shanghai
}

configure_time_sync() {
    echo -e "${CYAN}→ 配置 chrony${NC}"
    if ! command -v chronyd &> /dev/null; then apt install -y chrony >/dev/null 2>&1; fi
    systemctl enable chrony >/dev/null 2>&1
    systemctl start chrony >/dev/null 2>&1
    if command -v chronyc &> /dev/null; then chronyc makestep >/dev/null 2>&1 || true; fi
}

configure_hostname() {
    local h="$1"
    if [ -z "$h" ] || [ "$(hostname)" = "$h" ]; then return; fi
    echo -e "${CYAN}→ 设置主机名: $h${NC}"
    hostnamectl set-hostname "$h"
    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$h/" /etc/hosts
    else
        echo -e "127.0.1.1\t$h" >> /etc/hosts
    fi
}

# --- Nftables 分离式规则 ---
# 主配置只负责 include，自定义规则写入 /etc/nftables.d/10-base.conf
# 用户自定义规则放 /etc/nftables.d/50-custom.conf，脚本不会触碰该文件

apply_nftables_rules() {
    local ssh_port=$1
    echo -e "${CYAN}→ 应用 nftables 规则 (SSH: $ssh_port)${NC}"

    # 主配置：只做 include，不内联任何规则，确保自定义规则不被覆盖
    cat > /etc/nftables.conf <<'NFTMAIN'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.conf"
NFTMAIN

    mkdir -p /etc/nftables.d

    # 只覆写基础规则文件，50-custom.conf 不受影响
    cat > "$NFTABLES_BASE_FILE" <<EOF
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        tcp dport $ssh_port accept
        tcp dport { 80, 443 } accept
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
EOF

    # 提示用户自定义规则文件
    if [ ! -f /etc/nftables.d/50-custom.conf ]; then
        echo -e "${YELLOW}提示: 自定义规则请写入 /etc/nftables.d/50-custom.conf，脚本不会覆盖该文件${NC}"
        touch /etc/nftables.d/50-custom.conf
    fi

    nft -f /etc/nftables.conf
}

configure_firewall() {
    if [ "$AUTO_MODE" = true ] && systemctl is-active --quiet nftables; then return; fi

    echo -e "${CYAN}→ 配置 Nftables 防火墙${NC}"
    wait_for_apt

    if dpkg -l | grep -q ufw; then
        echo "清理 ufw..."
        systemctl stop ufw >/dev/null 2>&1 || true
        apt remove -y ufw >/dev/null 2>&1
    fi
    if dpkg -l | grep -q fail2ban; then
        echo "清理 fail2ban..."
        systemctl stop fail2ban >/dev/null 2>&1 || true
        apt remove -y fail2ban >/dev/null 2>&1
    fi
    if dpkg -l | grep -q iptables-persistent; then
        apt remove -y iptables-persistent >/dev/null 2>&1
    fi

    apt install -y nftables >/dev/null 2>&1
    apply_nftables_rules "$SSH_PORT"
    systemctl enable nftables >/dev/null 2>&1
    systemctl start nftables >/dev/null 2>&1
    echo -e "${GREEN}✓ Nftables 已启用${NC}"
}

change_ssh_port() {
    local new_port=$1
    local old_port=$SSH_PORT

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${RED}无效端口${NC}"; return 1
    fi
    if [ "$new_port" = "$old_port" ]; then return 0; fi

    echo -e "${CYAN}→ 修改 SSH 端口: $old_port -> $new_port${NC}"

    # 临时开放新端口，防止修改过程中断连 (nftables 表不存在时跳过，不崩溃)
    nft add rule inet filter input tcp dport $new_port accept 2>/dev/null || true

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    if grep -q "^Port " /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
    elif grep -q "^#Port " /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port $new_port/" /etc/ssh/sshd_config
    else
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi

    if sshd -t; then
        systemctl restart sshd
        # 仅更新基础规则中的 SSH 端口，不影响自定义规则
        apply_nftables_rules "$new_port"
        SSH_PORT=$new_port
        echo -e "${GREEN}✓ 端口修改成功${NC}"
        echo -e "${RED}!!! 务必在新窗口测试: ssh -p $new_port root@ip !!!${NC}"
    else
        echo -e "${RED}✗ 配置验证失败，已回滚${NC}"
        cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
        apply_nftables_rules "$old_port"
    fi
}

check_ssh_key() {
    local user_home
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
    else
        user_home="$HOME"
    fi
    if [ ! -s "$user_home/.ssh/authorized_keys" ] && [ ! -s /root/.ssh/authorized_keys ]; then
        echo -e "${RED}✗ 未发现有效的 SSH authorized_keys${NC}"
        echo -e "${YELLOW}请先配置SSH公钥，否则无法登录！${NC}"
        return 1
    fi
    return 0
}

configure_ssh() {
    echo -e "${CYAN}→ SSH 安全加固 (无Fail2ban)${NC}"

    if [ "$AUTO_MODE" != true ]; then
        if ask_yes_no "是否修改 SSH 端口？" "N"; then
            read -p "$(echo -e "${YELLOW}?${NC}" "输入新端口: ")" new_port
            change_ssh_port "$new_port"
        fi
    fi

    if ! check_ssh_key; then return 1; fi

    # 同时修改主配置（兼容旧系统）
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    # 写入高优先级 drop-in 文件，覆盖云服务商 50-cloud-init.conf 的 PasswordAuthentication yes
    mkdir -p /etc/ssh/sshd_config.d
    cat > "$SSH_DROPIN" <<'SSHDROPIN'
# 由 setup.sh 写入，优先级高于 50-cloud-init.conf
# 禁用密码登录，强制公钥认证
PasswordAuthentication no
PubkeyAuthentication yes
SSHDROPIN
    echo -e "${CYAN}→ 已写入 $SSH_DROPIN (覆盖云服务商配置)${NC}"

    if sshd -t; then
        systemctl restart sshd
        echo -e "${GREEN}✓ SSH 加固完成 (仅密钥登录)${NC}"
    else
        echo -e "${RED}✗ SSH 配置错误，已还原${NC}"
        cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
        rm -f "$SSH_DROPIN"
    fi
}

create_swap() {
    local size=$1
    if [ -f /swapfile ]; then echo -e "${GREEN}✓ Swap 已存在${NC}"; return; fi

    echo -e "${CYAN}→ 创建 Swap ($size)${NC}"
    local byte_size
    [[ "$size" =~ G ]] && byte_size=$(echo "$size" | tr -d 'G')G
    [[ "$size" =~ M ]] && byte_size=$(echo "$size" | tr -d 'M')M
    byte_size=${byte_size:-1G}

    # 优先使用 fallocate（NVMe 秒级完成，无 I/O 写入压力）
    # btrfs/zfs 不支持 fallocate，自动降级为 dd
    if fallocate -l "$byte_size" /swapfile 2>/dev/null; then
        echo -e "${GREEN}✓ 使用 fallocate 创建 Swap${NC}"
    else
        echo -e "${YELLOW}fallocate 不可用，降级使用 dd（可能较慢）${NC}"
        local count_mb
        [[ "$size" =~ G ]] && count_mb=$(( $(echo "$size" | tr -d 'G') * 1024 ))
        [[ "$size" =~ M ]] && count_mb=$(echo "$size" | tr -d 'M')
        dd if=/dev/zero of=/swapfile bs=1M count=${count_mb:-1024} status=progress
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    # 优化 swappiness，写入独立 sysctl.d 文件（Debian 12/13 均兼容）
    echo -e "${CYAN}→ 优化 Swap 策略 (swappiness=10)${NC}"
    [ -f "$SYSCTL_OPT_FILE" ] || touch "$SYSCTL_OPT_FILE"
    if ! grep -q "vm.swappiness" "$SYSCTL_OPT_FILE" 2>/dev/null; then
        echo "vm.swappiness=10" >> "$SYSCTL_OPT_FILE"
    else
        sed -i 's/^vm.swappiness.*/vm.swappiness=10/' "$SYSCTL_OPT_FILE"
    fi
    sysctl --system >/dev/null 2>&1

    echo -e "${GREEN}✓ Swap 创建成功并已优化${NC}"
}

ask_yes_no() {
    local prompt="$1"; local default="$2"; local response
    read -p "$(echo -e "${YELLOW}?${NC}" "$prompt [${default}]: ")" response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy] ]]
}

run_auto_mode() {
    echo -e "${CYAN}=== 自动配置模式 ===${NC}"
    read -p "请输入新主机名 (回车跳过): " hostname_input
    update_system
    configure_timezone
    configure_time_sync
    [ -n "$hostname_input" ] && configure_hostname "$hostname_input"
    configure_firewall
    enable_bbr
    if check_ssh_key; then configure_ssh; else echo -e "${YELLOW}跳过 SSH 加固${NC}"; fi
    echo -e "${GREEN}=== 配置完成 ===${NC}"
}

run_interactive_mode() {
    while true; do
        echo -e "\n${CYAN}--- 菜单 (v2) ---${NC}"
        echo "1) 查看状态 (Nftables)"
        echo "2) 修改主机名"
        echo "3) 基础设置 (更新/时区/时间)"
        echo "4) SSH 安全 (端口/密钥)"
        echo "5) 防火墙 (Nftables)"
        echo "6) 虚拟内存 (Swap)"
        echo "7) 开启 BBR"
        echo "8) 退出"
        read -p "选择: " choice
        case "$choice" in
            1)  echo "Host: $(hostname)"; nft list ruleset | head -n 20; ;;
            2)  read -p "新主机名: " h; configure_hostname "$h"; ;;
            3)  update_system; configure_timezone; configure_time_sync; ;;
            4)  configure_ssh; ;;
            5)  configure_firewall; ;;
            6)  read -p "大小 (如 1G): " s; create_swap "$s"; ;;
            7)  enable_bbr; ;;
            8)  exit 0; ;;
            *)  echo "无效选项"; ;;
        esac
    done
}

main() {
    print_banner
    check_root
    detect_os
    if [ "$AUTO_MODE" = true ]; then run_auto_mode; else run_interactive_mode; fi
}

main

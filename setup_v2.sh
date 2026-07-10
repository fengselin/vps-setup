#!/usr/bin/env bash
#
# 新 VPS 一键设置脚本 v4
# 支持：Debian 12 / Debian 13 / Ubuntu
# 功能：Nftables + BBR + Chrony + SSH 公钥硬化 + Swap
#
# 用法：
#   sudo ./setup.sh
#   sudo ./setup.sh --auto
#

set -Eeuo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SYSCTL_OPT_FILE="/etc/sysctl.d/99-vps-optimize.conf"
NFTABLES_DIR="/etc/nftables.d"
NFTABLES_BASE_FILE="${NFTABLES_DIR}/10-base.conf"

# 低编号文件优先被 sshd_config Include 读取
SSH_DROPIN="/etc/ssh/sshd_config.d/00-security.conf"
SSH_OLD_DROPIN="/etc/ssh/sshd_config.d/60-security.conf"

AUTO_MODE=false
SSH_SERVICE=""
SSH_PORT="22"
OS=""
OS_VERSION=""

if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
fi

print_banner() {
    echo
    echo -e "${GREEN}  VPS Setup v4 | Debian 12/13 + Ubuntu${NC}"
    echo -e "${YELLOW}  Nftables + BBR + Chrony + SSH Key Only + Swap${NC}"
    echo
}

die() {
    echo -e "${RED}错误: $*${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}提示: $*${NC}"
}

info() {
    echo -e "${CYAN}→ $*${NC}"
}

success() {
    echo -e "${GREEN}✓ $*${NC}"
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "必须以 root 权限运行"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"

    . /etc/os-release
    OS="${ID:-}"
    OS_VERSION="${VERSION_ID:-}"

    case "$OS" in
        debian|ubuntu)
            success "检测到系统: ${PRETTY_NAME:-$OS}"
            ;;
        *)
            die "仅支持 Debian / Ubuntu，当前为: ${PRETTY_NAME:-unknown}"
            ;;
    esac
}

wait_for_apt() {
    local timeout=300
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do

        if (( waited >= timeout )); then
            die "等待 apt/dpkg 锁超时"
        fi

        warn "等待 apt/dpkg 锁释放..."
        sleep 5
        ((waited += 5))
    done
}

apt_update() {
    wait_for_apt
    info "更新软件包索引"
    apt-get update -qq
    success "软件包索引已更新"
}

ensure_ssh_server() {
    if ! dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | \
        grep -qx 'install ok installed'; then
        info "安装 openssh-server"
        apt_update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
    fi

    # 修复：sshd: no hostkeys available -- exiting
    if ! compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null; then
        warn "未找到 SSH HostKey，正在生成"
        ssh-keygen -A
    fi

    if systemctl cat ssh.service >/dev/null 2>&1; then
        SSH_SERVICE="ssh"
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        SSH_SERVICE="sshd"
    else
        die "未找到 ssh.service 或 sshd.service"
    fi

    systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
    success "SSH 服务: ${SSH_SERVICE}.service"
}

get_ssh_port() {
    local port=""

    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)

    if [[ -z "$port" ]]; then
        port=$(
            grep -RhsE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
                /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null \
            | awk '{print $2; exit}' || true
        )
    fi

    echo "${port:-22}"
}

configure_timezone() {
    local current_tz=""

    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)

    if [[ "$current_tz" == "Asia/Shanghai" ]]; then
        success "时区已是 Asia/Shanghai"
        return
    fi

    info "设置时区 Asia/Shanghai"
    timedatectl set-timezone Asia/Shanghai
    success "时区已设置"
}

configure_time_sync() {
    info "配置 Chrony 时间同步"

    if ! command -v chronyd >/dev/null 2>&1; then
        wait_for_apt
        DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
    fi

    systemctl enable --now chrony >/dev/null 2>&1 || true

    if command -v chronyc >/dev/null 2>&1; then
        chronyc makestep >/dev/null 2>&1 || true
    fi

    success "Chrony 已配置"
}

configure_hostname() {
    local new_hostname="${1:-}"

    [[ -n "$new_hostname" ]] || return 0

    if [[ "$new_hostname" == "$(hostname)" ]]; then
        success "主机名未变化: $new_hostname"
        return 0
    fi

    info "设置主机名: $new_hostname"
    hostnamectl set-hostname "$new_hostname"

    if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_hostname}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$new_hostname" >> /etc/hosts
    fi

    success "主机名已设置"
}

enable_bbr() {
    info "启用 TCP BBR"

    touch "$SYSCTL_OPT_FILE"

    sed -i \
        -e '/^net\.core\.default_qdisc=/d' \
        -e '/^net\.ipv4\.tcp_congestion_control=/d' \
        "$SYSCTL_OPT_FILE"

    cat >> "$SYSCTL_OPT_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || warn "sysctl 加载失败，可能是容器限制"

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
        success "BBR 已启用"
    else
        warn "BBR 未确认生效，可能被 VPS 宿主机/容器限制"
    fi
}

apply_nftables_rules() {
    local ssh_port="$1"

    [[ "$ssh_port" =~ ^[0-9]+$ ]] || die "SSH 端口无效: $ssh_port"

    info "应用 Nftables 规则（SSH: $ssh_port）"

    mkdir -p "$NFTABLES_DIR"

    cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset
include "/etc/nftables.d/*.conf"
EOF

    cat > "$NFTABLES_BASE_FILE" <<EOF
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state established,related accept

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        tcp dport ${ssh_port} accept
        tcp dport { 80, 443 } accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    if [[ ! -f "${NFTABLES_DIR}/50-custom.conf" ]]; then
        touch "${NFTABLES_DIR}/50-custom.conf"
        warn "自定义防火墙规则请写入 ${NFTABLES_DIR}/50-custom.conf"
    fi

    nft -c -f /etc/nftables.conf
    nft -f /etc/nftables.conf
}

configure_firewall() {
    info "配置 Nftables 防火墙"

    wait_for_apt

    if dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -qx 'install ok installed'; then
        warn "检测到 UFW，正在移除以避免与 nftables 规则冲突"
        systemctl disable --now ufw >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y ufw
    fi

    if dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | \
        grep -qx 'install ok installed'; then
        warn "检测到 iptables-persistent，正在移除"
        DEBIAN_FRONTEND=noninteractive apt-get remove -y iptables-persistent
    fi

    if ! dpkg-query -W -f='${Status}' nftables 2>/dev/null | \
        grep -qx 'install ok installed'; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
    fi

    apply_nftables_rules "$SSH_PORT"
    systemctl enable nftables >/dev/null 2>&1
    systemctl restart nftables

    success "Nftables 已启用"
}

check_ssh_key() {
    local user_home="/root"

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    fi

    if [[ -s "${user_home}/.ssh/authorized_keys" ]] || \
       [[ -s "/root/.ssh/authorized_keys" ]]; then
        return 0
    fi

    warn "未发现 ${user_home}/.ssh/authorized_keys 或 /root/.ssh/authorized_keys"
    warn "请先确认服务器已有可用 SSH 公钥，防止禁用密码后失联"
    return 1
}

show_ssh_effective_config() {
    sshd -T | grep -Ei \
        '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin) ' || true
}

restore_ssh_dropin() {
    local backup_file="${1:-}"

    if [[ -n "$backup_file" && -f "$backup_file" ]]; then
        mv -f "$backup_file" "$SSH_DROPIN"
    else
        rm -f "$SSH_DROPIN"
    fi
}

configure_ssh() {
    info "SSH 安全加固（仅公钥认证）"

    if ! check_ssh_key; then
        warn "跳过 SSH 加固"
        return 1
    fi

    mkdir -p /etc/ssh/sshd_config.d

    # 删除旧脚本遗留规则，避免多文件冲突
    rm -f "$SSH_OLD_DROPIN"

    local backup_dropin=""
    if [[ -f "$SSH_DROPIN" ]]; then
        backup_dropin="${SSH_DROPIN}.backup.$(date +%Y%m%d_%H%M%S)"
        cp -a "$SSH_DROPIN" "$backup_dropin"
    fi

    cat > "$SSH_DROPIN" <<'EOF'
# Managed by setup.sh
# 00- 前缀确保优先于 cloud-init 等高编号 drop-in 文件读取。
# root 仅可通过 SSH 公钥认证登录。

PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF

    if ! sshd -t; then
        restore_ssh_dropin "$backup_dropin"
        die "SSH 配置语法错误，已恢复原配置"
    fi

    echo
    info "SSH 实际生效配置："
    show_ssh_effective_config
    echo

    if ! sshd -T | grep -qx 'passwordauthentication no' || \
       ! sshd -T | grep -qx 'kbdinteractiveauthentication no' || \
       ! sshd -T | grep -qx 'pubkeyauthentication yes' || \
       ! sshd -T | grep -qx 'permitrootlogin prohibit-password'; then

        restore_ssh_dropin "$backup_dropin"
        die "SSH 配置未按预期生效，已恢复原配置"
    fi

    systemctl reload "$SSH_SERVICE"

    success "SSH 加固完成：密码/PAM交互认证已禁用，root 仅允许公钥"
    warn "请保持当前 SSH 会话，并另开终端测试登录成功后再退出"
}

change_ssh_port() {
    local new_port="${1:-}"
    local old_port="$SSH_PORT"
    local config_backup=""

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || \
       (( new_port < 1024 || new_port > 65535 )); then
        warn "端口无效，请使用 1024-65535"
        return 1
    fi

    if [[ "$new_port" == "$old_port" ]]; then
        success "SSH 端口未改变: $old_port"
        return 0
    fi

    info "修改 SSH 端口: $old_port -> $new_port"

    config_backup="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
    cp -a /etc/ssh/sshd_config "$config_backup"

    # 端口统一由单独的 01-port.conf 管理，避免反复 sed 主配置
    cat > /etc/ssh/sshd_config.d/01-port.conf <<EOF
# Managed by setup.sh
Port ${new_port}
EOF

    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/01-port.conf
        warn "SSH 端口配置验证失败，已取消"
        return 1
    fi

    # 先装载允许新端口的规则，再 reload SSH
    apply_nftables_rules "$new_port"
    systemctl reload "$SSH_SERVICE"

    SSH_PORT="$new_port"

    success "SSH 端口已修改为: $new_port"
    warn "务必另开窗口测试：ssh -p $new_port root@你的服务器IP"
}

create_swap() {
    local size="${1:-}"

    if [[ -f /swapfile ]]; then
        success "Swap 已存在"
        swapon --show || true
        return 0
    fi

    if ! [[ "$size" =~ ^[1-9][0-9]*[MG]$ ]]; then
        warn "Swap 大小无效，应为如 512M、1G、2G"
        return 1
    fi

    info "创建 Swap: $size"

    if ! fallocate -l "$size" /swapfile 2>/dev/null; then
        warn "fallocate 不可用，使用 dd 创建"

        local count_mb
        if [[ "$size" =~ G$ ]]; then
            count_mb=$(( ${size%G} * 1024 ))
        else
            count_mb="${size%M}"
        fi

        dd if=/dev/zero of=/swapfile bs=1M count="$count_mb" status=progress
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    touch "$SYSCTL_OPT_FILE"

    if grep -q '^vm.swappiness=' "$SYSCTL_OPT_FILE"; then
        sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' "$SYSCTL_OPT_FILE"
    else
        echo 'vm.swappiness=10' >> "$SYSCTL_OPT_FILE"
    fi

    sysctl --system >/dev/null 2>&1 || true

    success "Swap 创建完成，swappiness=10"
    swapon --show
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local answer=""

    read -r -p "$(echo -e "${YELLOW}?${NC} ${prompt} [${default}]: ")" answer
    answer="${answer:-$default}"

    [[ "$answer" =~ ^[Yy]$ ]]
}

show_status() {
    echo
    echo -e "${CYAN}--- 系统 ---${NC}"
    echo "系统: $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "主机名: $(hostname)"
    echo "SSH 服务: ${SSH_SERVICE}.service"
    echo "SSH 端口: ${SSH_PORT}"

    echo
    echo -e "${CYAN}--- SSH 实际配置 ---${NC}"
    show_ssh_effective_config

    echo
    echo -e "${CYAN}--- SSH HostKey ---${NC}"
    ls -lh /etc/ssh/ssh_host_*_key 2>/dev/null || true

    echo
    echo -e "${CYAN}--- BBR ---${NC}"
    sysctl net.core.default_qdisc 2>/dev/null || true
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

    echo
    echo -e "${CYAN}--- Swap ---${NC}"
    swapon --show || true

    echo
    echo -e "${CYAN}--- Nftables ---${NC}"
    nft list ruleset 2>/dev/null | head -n 60 || true
}

run_auto_mode() {
    local hostname_input=""

    echo -e "${CYAN}=== 自动配置模式 ===${NC}"
    read -r -p "请输入新主机名（回车跳过）: " hostname_input

    apt_update
    configure_timezone
    configure_time_sync

    if [[ -n "$hostname_input" ]]; then
        configure_hostname "$hostname_input"
    fi

    configure_firewall
    enable_bbr
    configure_ssh || true

    success "=== 自动配置完成 ==="
}

run_interactive_mode() {
    local choice=""
    local h=""
    local s=""
    local new_port=""

    while true; do
        echo
        echo -e "${CYAN}--- VPS Setup 菜单 ---${NC}"
        echo "1) 查看状态"
        echo "2) 修改主机名"
        echo "3) 基础设置（apt / 时区 / Chrony）"
        echo "4) SSH 安全（仅公钥认证）"
        echo "5) 修改 SSH 端口"
        echo "6) 防火墙（Nftables）"
        echo "7) 虚拟内存（Swap）"
        echo "8) 开启 BBR"
        echo "9) 退出"

        read -r -p "选择: " choice

        case "$choice" in
            1)
                show_status
                ;;
            2)
                read -r -p "新主机名: " h
                configure_hostname "$h"
                ;;
            3)
                apt_update
                configure_timezone
                configure_time_sync
                ;;
            4)
                configure_ssh
                ;;
            5)
                read -r -p "新 SSH 端口（1024-65535）: " new_port
                change_ssh_port "$new_port"
                ;;
            6)
                configure_firewall
                ;;
            7)
                read -r -p "Swap 大小（如 1G、2G、512M）: " s
                create_swap "$s"
                ;;
            8)
                enable_bbr
                ;;
            9)
                exit 0
                ;;
            *)
                warn "无效选项"
                ;;
        esac
    done
}

main() {
    print_banner
    check_root
    detect_os
    ensure_ssh_server

    SSH_PORT=$(get_ssh_port)
    success "检测到 SSH 端口: $SSH_PORT"

    if [[ "$AUTO_MODE" == true ]]; then
        run_auto_mode
    else
        run_interactive_mode
    fi
}

main
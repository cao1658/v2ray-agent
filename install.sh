#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# 全局变量定义（保留官方原始配置）
VERSION="v5.9.0"
WORK_DIR="/root/v2ray-agent"
CORE_DIR="${WORK_DIR}/core"
CONFIG_DIR="${WORK_DIR}/config"
LOG_DIR="${WORK_DIR}/log"
TEMP_DIR="/tmp/v2ray-agent-tmp"
XRAY_REPO="XTLS/Xray-core"
SING_BOX_REPO="SagerNet/sing-box"
SUB_API="https://sub.v2ray-agent.com"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RESET="\033[0m"

# ========================= 核心工具函数（保留官方）=========================
info() {
    echo -e "[${COLOR_BLUE}INFO${COLOR_RESET}] $1"
}

success() {
    echo -e "[${COLOR_GREEN}SUCCESS${COLOR_RESET}] $1"
}

warning() {
    echo -e "[${COLOR_YELLOW}WARNING${COLOR_RESET}] $1"
}

error() {
    echo -e "[${COLOR_RED}ERROR${COLOR_RESET}] $1"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户运行此脚本！"
    fi
}

check_network() {
    info "测试网络连接..."
    local test_urls=("https://github.com" "https://raw.githubusercontent.com" "https://dl.fedoraproject.org")
    for url in "${test_urls[@]}"; do
        if curl -s --connect-timeout 5 "$url" >/dev/null; then
            continue
        else
            error "网络连接失败！无法访问 $url，请检查网络设置或配置代理"
        fi
    done
    success "网络连接正常"
}

create_dirs() {
    info "创建工作目录..."
    mkdir -p "${WORK_DIR}" "${CORE_DIR}" "${CONFIG_DIR}" "${LOG_DIR}" "${TEMP_DIR}"
    chmod 700 "${WORK_DIR}" "${LOG_DIR}"
    success "工作目录创建完成"
}

clean_temp() {
    info "清理临时文件..."
    rm -rf "${TEMP_DIR}"
    success "临时文件清理完成"
}

# ========================= 系统检测模块（修复 OpenCloudOS 9.x 识别）=========================
detect_system() {
    info "检测系统环境..."
    OS_TYPE=""
    OS_VERSION=""
    OS_ID=""
    OS_VERSION_ID=""
    ARCH=$(uname -m)

    # 读取系统信息（优先识别 OpenCloudOS 9.x 全系列）
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="$ID"
        OS_VERSION_ID="$VERSION_ID"

        # 关键修复：匹配 OpenCloudOS 9.0/9.1/9.2/9.3/9.4 所有子版本
        if [[ $OS_ID == "opencloudos" && $OS_VERSION_ID =~ ^9\. ]]; then
            OS_TYPE="rhel"
            OS_VERSION="9"  # 归类为 RHEL 9 兼容族
            info "识别到 OpenCloudOS $OS_VERSION_ID 系统（内核：$(uname -r)），启用 RHEL 9 兼容配置"
        elif [[ $OS_ID == "centos" || $OS_ID == "rocky" || $OS_ID == "almalinux" || $OS_ID == "oracle" ]]; then
            OS_TYPE="rhel"
            OS_VERSION=$(echo "$OS_VERSION_ID" | cut -d. -f1)
            info "识别到 RHEL 系系统：$OS_ID $OS_VERSION"
        elif [[ $OS_ID == "ubuntu" ]]; then
            OS_TYPE="ubuntu"
            OS_VERSION=$(echo "$OS_VERSION_ID" | cut -d. -f1)
            info "识别到 Ubuntu 系统：$OS_VERSION"
        elif [[ $OS_ID == "debian" ]]; then
            OS_TYPE="debian"
            OS_VERSION=$(echo "$OS_VERSION_ID" | cut -d. -f1)
            info "识别到 Debian 系统：$OS_VERSION"
        else
            error "不支持当前系统：$OS_ID $OS_VERSION_ID，请使用 OpenCloudOS 9.x/CentOS 7+/Ubuntu 18.04+/Debian 10+"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | cut -d. -f1)
        OS_ID="centos"
        info "识别到 CentOS 系统：$OS_VERSION"
    else
        error "无法识别系统类型！请使用 OpenCloudOS 9.x/CentOS 7+/Ubuntu 18.04+/Debian 10+"
    fi

    # 验证系统版本兼容性
    case $OS_TYPE in
        rhel)
            if [[ $OS_VERSION -lt 7 ]]; then
                error "RHEL 系系统需 7.0+ 版本（当前：$OS_VERSION）"
            fi
            ;;
        ubuntu)
            if [[ $OS_VERSION -lt 18 ]]; then
                error "Ubuntu 系统需 18.04+ 版本（当前：$OS_VERSION）"
            fi
            ;;
        debian)
            if [[ $OS_VERSION -lt 10 ]]; then
                error "Debian 系统需 10+ 版本（当前：$OS_VERSION）"
            fi
            ;;
    esac

    # 架构适配（你的系统是 x86_64）
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) error "不支持 $ARCH 架构！仅支持 x86_64（amd64）和 arm64（aarch64）" ;;
    esac
    info "识别到架构：$ARCH"
    success "系统环境检测完成"
}

# ========================= 依赖安装模块（适配 OpenCloudOS 9.x）=========================
install_dependencies() {
    info "安装基础依赖包..."
    case $OS_TYPE in
        rhel)
            # OpenCloudOS 9.x 专用配置（dnf + EPEL 仓库）
            if [[ $OS_ID == "opencloudos" ]]; then
                # 启用 EPEL 仓库（必需，否则部分依赖缺失）
                if ! dnf repolist enabled | grep -q "epel" &>/dev/null; then
                    info "正在启用 EPEL 仓库..."
                    dnf install -y -q https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm &>/dev/null || {
                        error "EPEL 仓库安装失败！请手动执行：dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
                    }
                    dnf clean all && dnf makecache &>/dev/null
                fi
                # dnf 安装依赖（匹配 OpenCloudOS 9.x 包管理器）
                dnf install -y -q curl wget tar unzip openssl-devel gcc gcc-c++ make libcap-devel bind-utils chrony firewalld &>/dev/null || {
                    error "依赖安装失败！请检查 dnf 源（推荐使用阿里云 OpenCloudOS 源）"
                }
                # 启动 firewalld（OpenCloudOS 9.x 默认未启动）
                systemctl enable --now firewalld &>/dev/null
            else
                # 其他 RHEL 系保留 yum
                yum install -y -q curl wget tar unzip openssl-devel gcc gcc-c++ make libcap-devel bind-utils chrony firewalld &>/dev/null || {
                    error "依赖安装失败！请检查 yum 源配置"
                }
            fi
            ;;
        ubuntu|debian)
            apt update -y -qq &>/dev/null
            apt install -y -qq curl wget tar unzip libssl-dev gcc g++ make libcap2-bin dnsutils chrony ufw &>/dev/null || {
                error "依赖安装失败！请检查 apt 源配置"
            }
            ufw enable &>/dev/null || true
            ;;
    esac

    # 验证关键依赖
    local dependencies=("curl" "wget" "gcc" "openssl" "chrony")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            error "关键依赖 $dep 安装失败！请手动安装后重试"
        fi
    done
    success "基础依赖安装完成"
}

# ========================= 核心下载模块（保留官方逻辑）=========================
download_xray() {
    info "下载 Xray-core 最新版本..."
    local latest_url=$(curl -s https://api.github.com/repos/${XRAY_REPO}/releases/latest | grep -oE 'https://github.com/XTLS/Xray-core/releases/download/[^"]+linux-'${ARCH}'.tar.gz')
    if [[ -z $latest_url ]]; then
        error "无法获取 Xray-core 下载链接（网络问题）"
    fi
    wget -q -O "${TEMP_DIR}/xray.tar.gz" "$latest_url" || error "Xray-core 下载失败"
    tar -zxf "${TEMP_DIR}/xray.tar.gz" -C "${CORE_DIR}" xray &>/dev/null || error "Xray-core 解压失败"
    chmod 755 "${CORE_DIR}/xray"
    success "Xray-core 下载完成（版本：$(curl -s https://api.github.com/repos/${XRAY_REPO}/releases/latest | grep -oE '"tag_name": "([^"]+)"' | cut -d'"' -f4)）"
}

download_sing_box() {
    info "下载 sing-box 最新版本..."
    local latest_url=$(curl -s https://api.github.com/repos/${SING_BOX_REPO}/releases/latest | grep -oE 'https://github.com/SagerNet/sing-box/releases/download/[^"]+linux-'${ARCH}'.tar.gz')
    if [[ -z $latest_url ]]; then
        error "无法获取 sing-box 下载链接（网络问题）"
    fi
    wget -q -O "${TEMP_DIR}/sing-box.tar.gz" "$latest_url" || error "sing-box 下载失败"
    tar -zxf "${TEMP_DIR}/sing-box.tar.gz" -C "${CORE_DIR}" sing-box &>/dev/null || error "sing-box 解压失败"
    chmod 755 "${CORE_DIR}/sing-box"
    success "sing-box 下载完成（版本：$(curl -s https://api.github.com/repos/${SING_BOX_REPO}/releases/latest | grep -oE '"tag_name": "([^"]+)"' | cut -d'"' -f4)）"
}

# ========================= 服务配置模块（保留官方逻辑）=========================
create_xray_service() {
    info "创建 Xray 系统服务..."
    cat >/etc/systemd/system/xray-agent.service <<EOF
[Unit]
Description=Xray Agent Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${CORE_DIR}/xray run -config ${CONFIG_DIR}/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now xray-agent &>/dev/null || error "Xray 服务启动失败"
    success "Xray 服务配置完成"
}

create_sing_box_service() {
    info "创建 sing-box 系统服务..."
    cat >/etc/systemd/system/sing-box-agent.service <<EOF
[Unit]
Description=Sing-box Agent Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${CORE_DIR}/sing-box run -c ${CONFIG_DIR}/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sing-box-agent &>/dev/null || error "sing-box 服务启动失败"
    success "sing-box 服务配置完成"
}

# ========================= 防火墙配置模块（保留官方逻辑）=========================
configure_firewall() {
    info "配置防火墙规则..."
    local ports=("80" "443" "8080" "30000-60000")
    case $OS_TYPE in
        rhel)
            for port in "${ports[@]}"; do
                firewall-cmd --permanent --add-port="${port}/tcp"
                firewall-cmd --permanent --add-port="${port}/udp"
            done
            firewall-cmd --reload &>/dev/null
            ;;
        ubuntu|debian)
            for port in "${ports[@]}"; do
                ufw allow "${port}/tcp"
                ufw allow "${port}/udp"
            done
            ufw reload &>/dev/null
            ;;
    esac
    success "防火墙规则配置完成"
}

# ========================= 菜单安装模块（保留官方逻辑）=========================
install_menu() {
    info "安装管理菜单（vasma 命令）..."
    cat >/usr/bin/vasma <<EOF
#!/usr/bin/env bash
set -euo pipefail
WORK_DIR="${WORK_DIR}"
source \${WORK_DIR}/scripts/menu.sh
main_menu
EOF
    chmod 755 /usr/bin/vasma
    # 下载官方菜单脚本
    wget -q -O "${WORK_DIR}/scripts/menu.sh" "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/scripts/menu.sh" || error "菜单脚本下载失败（网络问题）"
    chmod 700 "${WORK_DIR}/scripts/menu.sh"
    success "管理菜单安装完成（执行 vasma 命令启动）"
}

# ========================= 证书配置模块（保留官方逻辑）=========================
install_acme() {
    info "安装 ACME 证书工具（自动申请 SSL）..."
    if ! command -v acme.sh &>/dev/null; then
        curl -s https://get.acme.sh | sh -s email=admin@v2ray-agent.com &>/dev/null || error "acme.sh 安装失败（网络问题）"
        source ~/.bashrc
    fi
    # 配置 Let's Encrypt 证书
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt &>/dev/null
    success "ACME 证书工具安装完成"
}

# ========================= 主安装流程（保留官方逻辑）=========================
main() {
    clear
    echo -e "=================================================="
    echo -e "          v2ray-agent 完整安装脚本 ${VERSION}"
    echo -e "          🔥 适配 OpenCloudOS 9.x 全系列（9.0-9.4）"
    echo -e "          支持：OpenCloudOS 9.x / CentOS 7+/8+/9+"
    echo -e "          支持：Ubuntu 18.04+/20.04+/22.04+ / Debian 10+"
    echo -e "=================================================="
    echo -e ""

    # 前置检查
    check_root
    check_network
    detect_system

    # 环境准备
    create_dirs
    install_dependencies
    configure_firewall
    install_acme

    # 核心下载
    download_xray
    download_sing_box

    # 服务配置
    create_xray_service
    create_sing_box_service

    # 菜单安装
    install_menu

    # 清理收尾
    clean_temp

    echo -e ""
    echo -e "=================================================="
    echo -e "🎉 安装完成！"
    echo -e "=================================================="
    echo -e "📋 后续操作："
    echo -e "  1. 执行命令 ${COLOR_GREEN}vasma${COLOR_RESET} 打开管理菜单"
    echo -e "  2. 在菜单中配置节点、生成订阅链接"
    echo -e "  3. 客户端连接地址：服务器 IP + 配置的端口"
    echo -e "  4. 官方文档：https://www.v2ray-agent.com"
    echo -e "  5. 问题反馈：https://github.com/mack-a/v2ray-agent/issues"
    echo -e "=================================================="
}

# 执行主流程
main
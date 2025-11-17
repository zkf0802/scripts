#!/bin/bash
# -------------------------------  
# EasyTier 一键安装/更新/卸载脚本  
# 增加：若 /tmp/easytier.zip 已存在则跳过下载  
# -------------------------------  

# 检查 unzip 是否安装
if ! command -v unzip &>/dev/null; then
    echo "未检测到 unzip，正在安装..."
    if [ -f /etc/debian_version ]; then
         apt-get update -y && apt-get install -y unzip
    elif [ -f /etc/redhat-release ]; then
         yum install -y unzip
    elif [ -f /etc/alpine-release ]; then
        apk add unzip
    else
        echo "无法自动安装 unzip，请手动安装后重试。"
        exit 1
    fi
else
    echo "unzip 已安装"
fi

# 定义帮助信息
usage() {
    echo "用法: $0 [install|modify|uninstall|update] [username] [hostname]"
    echo "  install   - 全新安装EasyTier服务"
    echo "  modify    - 修改现有配置并重启服务"
    echo "  uninstall - 卸载EasyTier服务并删除文件"
    echo "  update    - 更新EasyTier服务程序文件"
    echo "示例:"
    echo "  $0 install username hostname"
    echo "  $0 modify username hostname"
    echo "  $0 uninstall"
    echo "  $0 update"
    exit 1
}

# 获取CPU架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l) echo "armv7" ;;
        *) echo "unknown" ;;
    esac
}

# 检查参数数量
if [ $# -lt 1 ]; then
    usage
fi

ACTION=$1
USERNAME=$2
HOSTNAME=$3
ARCH=$(get_arch)

# 从远程HTTP地址获取EasyTier版本号
EASYTIER_VERSION=$(curl -fsSL http://etsh2.442230.xyz/etver)
if [ -z "$EASYTIER_VERSION" ]; then
    echo "错误: 无法从 http://etsh2.442230.xyz/etver 获取EasyTier版本号"
    exit 1
fi
echo "检测到 EasyTier 版本: $EASYTIER_VERSION"

# 下载并解压EasyTier文件
download_and_extract() {
    local arch_name=$1
    local download_url=""
    local extracted_dir_name=""

    case $arch_name in
        x86_64)
            download_url="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-x86_64-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-x86_64"
            ;;
        aarch64)
            download_url="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-aarch64-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-aarch64"
            ;;
        armv7)
            download_url="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-armv7-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-armv7"
            ;;
        *)
            echo "错误: 不支持的CPU架构 $(uname -m)"
            exit 1
            ;;
    esac

    # ------ 新增：本地文件复用逻辑 ------
    if [ -s "/tmp/easytier.zip" ]; then
        echo "检测到 /tmp/easytier.zip 已存在，跳过下载，直接使用本地文件..."
    else
        echo "正在下载 EasyTier (${arch_name}) 到 /tmp/easytier.zip..."
        wget -O /tmp/easytier.zip "$download_url" || {
            echo "错误: 下载EasyTier失败."
            exit 1
        }
    fi
    # -------------------------------------

    echo "正在解压文件到 /root/easytier/..."
    unzip -o /tmp/easytier.zip -d /root/easytier/ || {
        echo "错误: 解压EasyTier文件失败."
        rm -f /tmp/easytier.zip
        exit 1
    }

    if [ -d "/root/easytier/${extracted_dir_name}" ]; then
        echo "正在将文件从 /root/easytier/${extracted_dir_name} 移动到 /root/easytier/..."
        mv /root/easytier/"${extracted_dir_name}"/* /root/easytier/ 2>/dev/null
        rmdir /root/easytier/"${extracted_dir_name}" 2>/dev/null
    else
        echo "警告: 未找到预期的二级目录 /root/easytier/${extracted_dir_name}。请手动检查解压结果。"
    fi

    rm -f /tmp/easytier.zip
    chmod +x /root/easytier/easytier-core
    chmod +x /root/easytier/easytier-cli
    echo "EasyTier文件下载并解压完成."
}

# 安装流程
install_service() {
    if [ -d "/root/easytier" ]; then
        rm -rf /root/easytier
    fi
    mkdir -p /root/easytier

    download_and_extract "$ARCH"

    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=/root/easytier/easytier-core -w $USERNAME --hostname $HOSTNAME
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service

    # 配置网关转发（仅作示例，接口名按需调整）
    export tun_IF=tun0 && export WAN_IF=eth0
    iptables -I FORWARD -i $WAN_IF -j ACCEPT
    iptables -I FORWARD -o $WAN_IF -j ACCEPT
    iptables -t nat -I POSTROUTING -o $WAN_IF -j MASQUERADE
    iptables -I FORWARD -i $tun_IF -j ACCEPT
    iptables -I FORWARD -o $tun_IF -j ACCEPT
    iptables -t nat -I POSTROUTING -o $tun_IF -j MASQUERADE
    if command -v apt-get &>/dev/null; then
        apt-get install -y iptables-persistent
        netfilter-persistent save
    fi

    systemctl daemon-reload
    systemctl enable easytier
    systemctl restart easytier
    echo "EasyTier服务已安装并启动。查看日志:"
    journalctl -f -u easytier.service
}

# 修改配置流程
modify_config() {
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=/root/easytier/easytier-core -w $USERNAME --hostname $HOSTNAME
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service
    systemctl daemon-reload
    systemctl restart easytier
    echo "EasyTier服务配置已更新并重启。查看日志:"
    journalctl -f -u easytier.service
}

# 卸载流程
uninstall_service() {
    systemctl stop easytier 2>/dev/null
    systemctl disable easytier 2>/dev/null
    systemctl daemon-reload
    systemctl reset-failed
    rm -f /etc/systemd/system/easytier.service
    rm -rf /root/easytier
    rm -f /root/easytier.sh
    echo "EasyTier服务已卸载，相关文件已删除"
}

# 更新流程
update_service() {
    systemctl stop easytier 2>/dev/null
    rm -rf /root/easytier
    mkdir -p /root/easytier
    download_and_extract "$ARCH"
    systemctl daemon-reload
    systemctl enable easytier
    systemctl restart easytier
    echo "EasyTier服务已更新并重启。查看日志:"
    journalctl -f -u easytier.service
}

# 主入口
case $ACTION in
    install)
        [ $# -ne 3 ] && { echo "错误: install操作需要用户名和主机名参数"; usage; }
        install_service
        ;;
    modify)
        [ $# -ne 3 ] && { echo "错误: modify操作需要用户名和主机名参数"; usage; }
        modify_config
        ;;
    uninstall)
        uninstall_service
        ;;
    update)
        update_service
        ;;
    *)
        echo "错误: 未知操作 '$ACTION'"
        usage
        ;;
esac

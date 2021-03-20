#!/bin/bash
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

initialize(){
    [[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] This script must be run as root!" && exit 1
    #关闭防火墙和SELINUX
    systemctl stop firewalld
    systemctl disable firewalld
    CHECK=$(grep SELINUX= /etc/selinux/config | grep -v "#")
    if [ "$CHECK" == "SELINUX=enforcing" ]; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
    if [ "$CHECK" == "SELINUX=permissive" ]; then
        sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
    yum -y install bind-utils wget unzip zip curl tar
    #开启BBR加速
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    sysctl -n net.ipv4.tcp_congestion_control
    lsmod | grep bbr
}

cert(){
    green "=================================="
    yellow "Enter the domain name of you VPS:"
    green "=================================="
    read your_domain
    real_addr=`ping ${your_domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}'`
    local_addr=`curl ipv4.icanhazip.com`
    if [ $real_addr == $local_addr ] ; then
        green "==============================="
        green "Domain name resolves correctly."
        green "==============================="
        rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
            yum install -y nginx
        systemctl enable nginx.service
        #设置伪装站
        rm -rf /usr/share/nginx/html/*
        cd /usr/share/nginx/html/
        wget https://github.com/atrandys/v2ray-ws-tls/raw/master/web.zip
            unzip web.zip
        systemctl restart nginx.service
        #申请https证书
        mkdir /usr/src/cert
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh  --issue  -d $your_domain  --webroot /usr/share/nginx/html/
            ~/.acme.sh/acme.sh  --installcert  -d  $your_domain   \
            --key-file   /usr/src/cert/private.key \
            --fullchain-file /usr/src/cert/fullchain.cer \
            --reloadcmd  "systemctl force-reload  nginx.service"
        if test -s /usr/src/cert/fullchain.cer; then
            green "================================================"
            green "SSL Certificate has been Successfully installed."
            yellow "Initializing docker installation..."
            green "================================================"
            install_docker
        else
            red "=================================="
            red "Failed to install SSL Certificate."
            red "=================================="
        fi
	
    else
        red "======================="
        red "Domain resolving error."
        red "======================="
    fi
}

protocol_config(){
    randompasswd=$(cat /dev/urandom | head -1 | md5sum | head -c 12)
    randomssport=$(shuf -i 10000-14999 -n 1)
    randomsnellport=$(shuf -i 15000-19999 -n 1)

    green "======================================================"
    echo
    yellow "Enter the PASSWORD for Trojan, Shadowsocks and Snell:"
    yellow "Default PASSWORD:${randompasswd}"
    read -p "\033[44;37mPlease enter:\033[0m" mainpasswd
    [ -z "${mainpasswd}" ] && mainpasswd=${randompasswd}
    echo

    yellow "Enter the port for Shadowsocks [1-65535]:"
    yellow "Default SS Port:${randomssport}"
    read -p "\033[44;37mPlease enter:\033[0m" ssport
    [ -z "${ssport}" ] && ssport=${randomssport}
    echo

    yellow "Enter the port for Snell [1-65535]:"
    yellow "Default Snell Port:${randomsnellport}"
    read -p "\033[44;37mPlease enter:\033[0m" snellport
    [ -z "${snellport}" ] && snellport=${randomsnellport}
    echo
    green "======================================================"
    echo

}

install_docker(){
    protocol_config
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl start docker
    systemctl enable docker
    systemctl enable containerd
    docker pull portainer/portainer:latest
    docker volume create portainer_data
    docker run -d -p 9000:9000 --name=portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer
    docker pull v2fly/v2fly-core
    docker volume create v2fly_config
	  cat > /var/lib/docker/volumes/v2fly_config/config.json <<-EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443, 
      "protocol": "trojan",
      "settings": {
        "clients":[{"password": "$mainpasswd"}],
        "fallbacks": [{"dest": 9000}]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [{
            "certificateFile": "/cert/fullchain.cer",
            "keyFile": "/cert/private.key"
          }]
        }
      }
    },
    {
      "listen": "0.0.0.0",
      "port": $ssport, 
      "protocol": "shadowsocks",
      "settings":{
          "method": "chacha20-ietf-poly1305",
          "ota": false, 
          "password": "$mainpasswd"
      }
    }
  ],
  "outbounds": [{ 
    "protocol": "freedom"
  }]
}
EOF
    docker run -d --network=host --name=v2fly --restart=always -v /var/lib/docker/volumes/v2fly_config/config.json:/etc/v2ray/config.json -v /usr/src/cert:/cert v2fly/v2fly-core
    docker pull primovist/snell-docker
    docker volume create snell_config
    cat > /var/lib/docker/volumes/snell_config/snell-server.conf <<-EOF
[Snell Server]
interface = 0.0.0.0:$snellport
psk = $mainpasswd
obfs = off
EOF
    docker run -d --network=host --name=snell --restart=always -v /var/lib/docker/volumes/snell_config/:/etc/snell/ primovist/snell-docker
}

ssh_update_config(){

    randomsshport=$(shuf -i 20000-29999 -n 1)
    randomsshpasswd=$(cat /dev/urandom | head -1 | md5sum | head -c 16)

    green "======================================================"
    echo
    yellow "Enter a new SSH port [1-65535]:"
    yellow "Default new SSH port:${randomsshport}"
    read -p "\033[44;37mPlease enter:\033[0m" sshport
    [ -z "${sshport}" ] && sshport=${randomsshport}
    echo

    yellow "Enter a USERNAME for new admin account:"
    yellow "Default USERNAME:TempAdmin"
    read -p "\033[44;37mPlease enter:\033[0m" newusername
    [ -z "${newusername}" ] && newusername="TempAdmin"
    echo

    yellow "Enter a PASSWORD for ${newusername}:"
    yellow "Default PASSWORD:${randomsshpasswd}"
    read -p "\033[44;37mPlease enter:\033[0m" sshpasswd
    [ -z "${sshpasswd}" ] && sshpasswd=${randomsshpasswd}
    echo
    green "======================================================"
    echo

}

ssh_update(){
  ssh_update_config
  adduser ${newusername}
  echo ${sshpasswd} | passwd ${newusername} --stdin
  chmod 777 /etc/sudoers
  cat > /etc/sudoers <<-EOF
Defaults   !visiblepw
Defaults    always_set_home
Defaults    match_group_by_gid
Defaults    always_query_group_plugin
Defaults    env_reset
Defaults    env_keep =  "COLORS DISPLAY HOSTNAME HISTSIZE KDEDIR LS_COLORS"
Defaults    env_keep += "MAIL PS1 PS2 QTDIR USERNAME LANG LC_ADDRESS LC_CTYPE"
Defaults    env_keep += "LC_COLLATE LC_IDENTIFICATION LC_MEASUREMENT LC_MESSAGES"
Defaults    env_keep += "LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER LC_TELEPHONE"
Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"
Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin
root	ALL=(ALL) 	ALL
${newusername} ALL=(ALL) ALL
${newusername} ALL=NOPASSWD: /usr/libexec/openssh/sftp-server
Defaults:${newusername} !requiretty
%wheel	ALL=(ALL)	ALL
EOF
  chmod 440 /etc/sudoers
  cat > /etc/ssh/sshd_config <<-EOF
Port ${sshport}
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
SyslogFacility AUTHPRIV
PermitRootLogin no
AuthorizedKeysFile	.ssh/authorized_keys
PasswordAuthentication yes
ChallengeResponseAuthentication no
GSSAPIAuthentication yes
GSSAPICleanupCredentials no
UsePAM yes
X11Forwarding yes
PrintMotd no
ClientAliveInterval 420
AcceptEnv LANG LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES
AcceptEnv LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT
AcceptEnv LC_IDENTIFICATION LC_ALL LANGUAGE
AcceptEnv XMODIFIERS
Subsystem	sftp	/usr/libexec/openssh/sftp-server
EOF
  echo y | dnf install policycoreutils-python-utils
  semanage port -a -t ssh_port_t -p tcp ${sshport}
  semanage port -l | grep ssh
  systemctl restart sshd

}

start_menu(){
    initialize
    clear
    green " ===================================="
    green " ===================================="
    echo
    green " 1. Install/Renew SSL Certificate"
    red " 2. VPS Security Update"
    yellow " 0. Exit Script"
    echo
    read -p "Enter a number:" num
    case "$num" in
    1)
    cert
    ;;
    2)
    ssh_update
    ;;
    0)
    exit 1
    ;;
    *)
    clear
    red "Please enter a correct number"
    sleep 1s
    start_menu
    ;;
    esac
}

start_menu
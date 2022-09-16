#!/usr/bin/env bash

set -e -o pipefail

# Usage:
# ./install.sh

# Get the latest release version number
if [[ -z "${VERSION}" ]]; then
    VERSION=$(curl -s https://api.github.com/repos/openshift/microshift/releases | grep tag_name | grep -v nightly | head -n 1 | cut -d '"' -f 4)
fi
echo "Install MicroShift version: ${VERSION}"

# Function to get Linux distribution
get_distro() {
    DISTRO=$(grep -E '^(ID)=' /etc/os-release| sed 's/"//g' | cut -f2 -d"=")
    if [[ $DISTRO != @(ubuntu) ]]; then
        echo "This Linux distro is not supported by the install script: ${DISTRO}"
        exit 1
    fi
}

# Function to get system architecture
get_arch() {
    ARCH=$(uname -m | sed "s/x86_64/amd64/" | sed "s/aarch64/arm64/")
    if [[ $ARCH != @(amd64|arm64) ]]; then
        printf "arch %s unsupported" "$ARCH" >&2
        exit 1
    fi
}

# Function to get OS version
get_os_version() {
    OS_VERSION=$(grep -E '^(VERSION_ID)=' /etc/os-release | sed 's/"//g' | cut -f2 -d"=")
}

# Install dependencies
install_dependencies() {
    case $DISTRO in
        "ubuntu")
            sudo apt-get install -y \
                policycoreutils-python-utils \
                conntrack \
                firewalld
            ;;
    esac
}

# Establish Iptables rules
establish_firewall () {
    sudo systemctl enable firewalld --now
    sudo firewall-cmd --zone=public --permanent --add-port=6443/tcp
    sudo firewall-cmd --zone=public --permanent --add-port=30000-32767/tcp
    sudo firewall-cmd --zone=public --permanent --add-port=2379-2380/tcp
    sudo firewall-cmd --zone=public --add-masquerade --permanent
    sudo firewall-cmd --zone=public --add-port=10250/tcp --permanent
    sudo firewall-cmd --zone=public --add-port=10251/tcp --permanent
    sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
    sudo firewall-cmd --reload
}

# Install CRI-O depending on the distro
install_crio() {
    case $DISTRO in
        "ubuntu")
            CRIOVERSION=1.21
            OS=xUbuntu_$OS_VERSION
            KEYRINGS_DIR=/usr/share/keyrings

            sudo apt-get update -y
            sudo apt-get install -y ca-certificates curl gnupg

            echo "deb [signed-by=$KEYRINGS_DIR/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list > /dev/null
            echo "deb [signed-by=$KEYRINGS_DIR/libcontainers-crio-archive-keyring.gpg] http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIOVERSION/$OS/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIOVERSION.list > /dev/null

            sudo mkdir -p $KEYRINGS_DIR
            curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | sudo gpg --batch --yes --dearmor -o $KEYRINGS_DIR/libcontainers-archive-keyring.gpg
            curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIOVERSION/$OS/Release.key | sudo gpg --batch --yes --dearmor -o $KEYRINGS_DIR/libcontainers-crio-archive-keyring.gpg

            sudo apt-get update -y
            # Vagrant Ubuntu VMs don't provide containernetworking-plugins by default
            sudo apt-get install -y \
                cri-o cri-o-runc cri-tools \
                containernetworking-plugins
            ;;
    esac
}


# CRI-O config to match MicroShift networking values
crio_conf() {
    sudo sh -c 'cat << EOF > /etc/cni/net.d/100-crio-bridge.conf
{
    "cniVersion": "0.4.0",
    "name": "crio",
    "type": "bridge",
    "bridge": "cni0",
    "isGateway": true,
    "ipMasq": true,
    "hairpinMode": true,
    "ipam": {
        "type": "host-local",
        "routes": [
            { "dst": "0.0.0.0/0" }
        ],
        "ranges": [
            [{ "subnet": "10.42.0.0/24" }]
        ]
    }
}
EOF'
    
     if [ "$DISTRO" == "rhel" ]; then
        sudo sed -i 's|/usr/libexec/crio/conmon|/usr/bin/conmon|' /etc/crio/crio.conf 
     fi
}

# Start CRI-O
verify_crio() {
    sudo systemctl enable crio
    sudo systemctl restart crio
}

# Download and install oc/kubectl
get_oc_kubectl() {
    curl -O https://mirror.openshift.com/pub/openshift-v4/$ARCH/clients/ocp/stable/openshift-client-linux.tar.gz
    sudo tar -xf openshift-client-linux.tar.gz -C /usr/local/bin oc kubectl
}

# Download and install microshift
get_microshift() {
    curl -LO https://github.com/openshift/microshift/releases/download/$VERSION/microshift-linux-$ARCH
    curl -LO https://github.com/openshift/microshift/releases/download/$VERSION/release.sha256

    BIN_SHA="$(sha256sum microshift-linux-$ARCH | awk '{print $1}')"
    KNOWN_SHA="$(grep "microshift-linux-$ARCH" release.sha256 | awk '{print $1}')"

    if [[ "$BIN_SHA" != "$KNOWN_SHA" ]]; then 
        echo "SHA256 checksum failed"
        exit 1
    fi

    sudo chmod +x microshift-linux-$ARCH
    sudo mv microshift-linux-$ARCH /usr/local/bin/microshift

    cat << EOF | sudo tee /usr/lib/systemd/system/microshift.service
[Unit]
Description=Microshift
After=crio.service

[Service]
WorkingDirectory=/usr/local/bin/
ExecStart=microshift run
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    if [[ "$DISTRO" == "ubuntu" ]] && [[ "$OS_VERSION" == "18.04" ]]; then
        sudo sed -i 's|^ExecStart=microshift|ExecStart=/usr/local/bin/microshift|' /usr/lib/systemd/system/microshift.service
    fi

    sudo systemctl enable microshift.service --now
}

# Locate kubeadmin configuration to default kubeconfig location
prepare_kubeconfig() {
    mkdir -p $HOME/.kube
    if [[ -f $HOME/.kube/config ]]; then
        mv $HOME/.kube/config $HOME/.kube/config.orig
    fi
    sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig:$HOME/.kube/config.orig /usr/local/bin/kubectl config view --flatten | sudo tee $HOME/.kube/config > /dev/null
}

# Script execution
get_distro
get_arch
get_os_version
install_dependencies
#establish_firewall
install_crio
crio_conf
verify_crio
get_oc_kubectl
get_microshift

until sudo test -f /var/lib/microshift/resources/kubeadmin/kubeconfig; do
    sleep 2
done
prepare_kubeconfig

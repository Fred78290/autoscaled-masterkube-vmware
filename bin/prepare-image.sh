echo "==============================================================================================================================="
echo "= Upgrade ubuntu distro"
echo "==============================================================================================================================="
apt update
apt upgrade -y
echo

mkdir -p /etc/kubernetes

echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.conf
echo "net.bridge.bridge-nf-call-arptables = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

echo "overlay" >> /etc/modules
echo "br_netfilter" >> /etc/modules

modprobe overlay
modprobe br_netfilter

echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables

sysctl --system

mkdir -p $(dirname ${CREDENTIALS_CONFIG})
mkdir -p ${CREDENTIALS_BIN}

echo "kubernetes ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/kubernetes

if [ -n "${AWS_ACCESS_KEY_ID}" ] && [ -n "${AWS_SECRET_ACCESS_KEY}" ]; then

    if [ ${KUBERNETES_MINOR_RELEASE} -gt 28 ]; then
        ECR_CREDS_VERSION=v1.29.0
        KUBELET_CREDS_VERSION=v1
    elif [ ${KUBERNETES_MINOR_RELEASE} -gt 27 ]; then
        ECR_CREDS_VERSION=v1.28.5
        KUBELET_CREDS_VERSION=v1
    elif [ ${KUBERNETES_MINOR_RELEASE} -gt 26 ]; then
        ECR_CREDS_VERSION=v1.27.1
        KUBELET_CREDS_VERSION=v1
    elif [ ${KUBERNETES_MINOR_RELEASE} -gt 25 ]; then
        ECR_CREDS_VERSION=v1.26.1
        KUBELET_CREDS_VERSION=v1alpha1
    else
        ECR_CREDS_VERSION=v1.0.0
        KUBELET_CREDS_VERSION=v1alpha1
    fi
    
    curl -sL https://github.com/Fred78290/aws-ecr-credential-provider/releases/download/${ECR_CREDS_VERSION}/ecr-credential-provider-${SEED_ARCH} -o ${CREDENTIALS_BIN}/ecr-credential-provider
    chmod +x ${CREDENTIALS_BIN}/ecr-credential-provider

    mkdir -p /root/.aws

    cat > /root/.aws/config <<EOF
[default]
output = json
region = us-east-1
cli_binary_format=raw-in-base64-out
EOF

    cat > /root/.aws/credentials <<EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF

    cat > ${CREDENTIALS_CONFIG} <<EOF
apiVersion: kubelet.config.k8s.io/${KUBELET_CREDS_VERSION}
kind: CredentialProviderConfig
providers:
  - name: ecr-credential-provider
    matchImages:
      - "*.dkr.ecr.*.amazonaws.com"
      - "*.dkr.ecr.*.amazonaws.cn"
      - "*.dkr.ecr-fips.*.amazonaws.com"
      - "*.dkr.ecr.us-iso-east-1.c2s.ic.gov"
      - "*.dkr.ecr.us-isob-east-1.sc2s.sgov.gov"
    defaultCacheDuration: "12h"
    apiVersion: credentialprovider.kubelet.k8s.io/${KUBELET_CREDS_VERSION}
    args:
      - get-credentials
    env:
      - name: AWS_ACCESS_KEY_ID 
        value: ${AWS_ACCESS_KEY_ID}
      - name: AWS_SECRET_ACCESS_KEY
        value: ${AWS_SECRET_ACCESS_KEY}
EOF
fi

if [ "${KUBERNETES_DISTRO}" == "rke2" ]; then
    echo "prepare rke2 image"

    curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="${KUBERNETES_VERSION}" sh -

    pushd /usr/local/bin
    curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION%%+*}/bin/linux/${SEED_ARCH}/{kubectl,kube-proxy}
    chmod +x /usr/local/bin/kube*
    popd

    mkdir -p /etc/rancher/rke2
    mkdir -p /etc/NetworkManager/conf.d

    cat > /etc/NetworkManager/conf.d/rke2-canal.conf <<"EOF"
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*
EOF
    cat > /etc/rancher/rke2/config.yaml <<"EOF"
kubelet-arg:
  - cloud-provider=external
  - fail-swap-on=false
EOF

elif [ "${KUBERNETES_DISTRO}" == "k3s" ]; then
    echo "prepare k3s image"

    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${KUBERNETES_VERSION}" INSTALL_K3S_SKIP_ENABLE=true sh -

    mkdir -p /etc/systemd/system/k3s.service.d
    echo "K3S_MODE=agent" > /etc/default/k3s
    echo "K3S_ARGS=" > /etc/systemd/system/k3s.service.env
    echo "K3S_SERVER_ARGS=" > /etc/systemd/system/k3s.server.env
    echo "K3S_AGENT_ARGS=" > /etc/systemd/system/k3s.agent.env
    echo "K3S_DISABLE_ARGS=" > /etc/systemd/system/k3s.disabled.env

    cat > /etc/systemd/system/k3s.service.d/10-k3s.conf <<"EOF"
[Service]
Environment="KUBELET_ARGS=--kubelet-arg=cloud-provider=external --kubelet-arg=fail-swap-on=false"
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
EnvironmentFile=-/etc/systemd/system/k3s.service.env
EnvironmentFile=-/etc/systemd/system/k3s.server.env
EnvironmentFile=-/etc/systemd/system/k3s.agent.env
EnvironmentFile=-/etc/systemd/system/k3s.disabled.env
ExecStart=
ExecStart=/usr/local/bin/k3s $K3S_MODE $K3S_ARGS $K3S_SERVER_ARGS $K3S_AGENT_ARGS $K3S_DISABLE_ARGS $KUBELET_ARGS \

EOF

else
    echo "prepare kubeadm image"

    function pull_image() {
        DOCKER_IMAGES=$(curl -s $1 | grep -E "\simage: " | sed -E 's/.+image: (.+)/\1/g')
        
        for DOCKER_IMAGE in $DOCKER_IMAGES
        do
            echo "Pull image $DOCKER_IMAGE"
            ${CONTAINER_CTL} pull $DOCKER_IMAGE
        done
    }

    mkdir -p /etc/systemd/system/kubelet.service.d
    mkdir -p /var/lib/kubelet
    mkdir -p /opt/cni/bin

    . /etc/os-release

    OS=x${NAME}_${VERSION_ID}

    systemctl disable apparmor

    echo "Prepare to install CNI plugins"

    echo "==============================================================================================================================="
    echo "= Install CNI plugins"
    echo "==============================================================================================================================="

    curl -sL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-${SEED_ARCH}-${CNI_PLUGIN_VERSION}.tgz" | tar -C /opt/cni/bin -xz

    ls -l /opt/cni/bin

    echo

    if [ "${CONTAINER_ENGINE}" = "docker" ]; then

        echo "==============================================================================================================================="
        echo "Install Docker"
        echo "==============================================================================================================================="

        mkdir -p /etc/docker
        mkdir -p /etc/systemd/system/docker.service.d

        curl -s https://get.docker.com | bash

        cat > /etc/docker/daemon.json <<EOF
{
    "exec-opts": [
        "native.cgroupdriver=systemd"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2"
}
EOF

        # Restart docker.
        systemctl daemon-reload
        systemctl restart docker

        usermod -aG docker ubuntu

    elif [ "${CONTAINER_ENGINE}" == "containerd" ]; then

        echo "==============================================================================================================================="
        echo "Install Containerd"
        echo "==============================================================================================================================="

        curl -sL https://github.com/containerd/containerd/releases/download/v1.7.11/cri-containerd-cni-1.7.11-linux-${SEED_ARCH}.tar.gz | tar -C / -xz

        mkdir -p /etc/containerd
        containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g' | tee /etc/containerd/config.toml

        systemctl enable containerd.service
        systemctl restart containerd

        curl -sL https://github.com/containerd/nerdctl/releases/download/v1.7.2/nerdctl-1.7.2-linux-${SEED_ARCH}.tar.gz | tar -C /usr/local/bin -xz
    else

        echo "==============================================================================================================================="
        echo "Install CRI-O repositories"
        echo "==============================================================================================================================="

        echo "deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIO_VERSION/$OS/ /" > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION.list
        curl -sL https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$CRIO_VERSION/$OS/Release.key | sudo apt-key --keyring /etc/apt/trusted.gpg.d/libcontainers-cri-o.gpg add -

        apt update
        apt install cri-o cri-o-runc -y
        echo

        mkdir -p /etc/crio/crio.conf.d/

        systemctl daemon-reload
        systemctl enable crio
        systemctl restart crio
    fi

    echo "==============================================================================================================================="
    echo "= Install crictl"
    echo "==============================================================================================================================="
    curl -sL https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRIO_VERSION}.0/crictl-v${CRIO_VERSION}.0-linux-${SEED_ARCH}.tar.gz | tar -C /usr/local/bin -xz
    chmod +x /usr/local/bin/crictl

    echo "==============================================================================================================================="
    echo "= Clean ubuntu distro"
    echo "==============================================================================================================================="
    apt-get autoremove -y
    apt-get autoclean -y
    echo

    echo "==============================================================================================================================="
    echo "= Install kubernetes binaries"
    echo "==============================================================================================================================="

    cd /usr/local/bin
    curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${SEED_ARCH}/{kubeadm,kubelet,kubectl,kube-proxy}
    chmod +x /usr/local/bin/kube*

    echo

    echo "==============================================================================================================================="
    echo "= Configure kubelet"
    echo "==============================================================================================================================="

    cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/systemd/system/kubelet.service.d

    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<"EOF"
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generate at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

    if [ -z "${AWS_ACCESS_KEY_ID}" ] && [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
        echo "KUBELET_EXTRA_ARGS='--cloud-provider=external --fail-swap-on=false --read-only-port=10255'" > /etc/default/kubelet
    else
        echo "KUBELET_EXTRA_ARGS='--image-credential-provider-config=${CREDENTIALS_CONFIG} --image-credential-provider-bin-dir=${CREDENTIALS_BIN} --cloud-provider=external --fail-swap-on=false --read-only-port=10255'" > /etc/default/kubelet
    fi

    echo 'export PATH=/opt/cni/bin:$PATH' >> /etc/profile.d/apps-bin-path.sh

    echo "==============================================================================================================================="
    echo "= Restart kubelet"
    echo "==============================================================================================================================="

    systemctl enable kubelet
    systemctl restart kubelet

    echo "==============================================================================================================================="
    echo "= Pull kube images"
    echo "==============================================================================================================================="

    /usr/local/bin/kubeadm config images pull --kubernetes-version=${KUBERNETES_VERSION}

    echo "==============================================================================================================================="
    echo "= Pull cni image"
    echo "==============================================================================================================================="

    if [ "$CNI_PLUGIN" = "calico" ]; then
        curl -s -O -L "https://github.com/projectcalico/calico/releases/download/v3.27.0/calicoctl-linux-${SEED_ARCH}"
        chmod +x calicoctl-linux-${SEED_ARCH}
        mv calicoctl-linux-${SEED_ARCH} /usr/local/bin/calicoctl
        pull_image https://docs.projectcalico.org/manifests/calico-vxlan.yaml
    elif [ "$CNI_PLUGIN" = "flannel" ]; then
        pull_image https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    elif [ "$CNI_PLUGIN" = "weave" ]; then
        pull_image "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
    elif [ "$CNI_PLUGIN" = "canal" ]; then
        pull_image https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/canal.yaml
    elif [ "$CNI_PLUGIN" = "kube" ]; then
        pull_image https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml
        pull_image https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter-all-features.yaml
    elif [ "$CNI_PLUGIN" = "romana" ]; then
        pull_image https://raw.githubusercontent.com/romana/romana/master/containerize/specs/romana-kubeadm.yml
    fi
fi

apt upgrade -y
apt autoremove -y

cat >> /etc/vmware-tools/tools.conf <<EOF
[guestinfo]
exclude-nics=docker*,veth*,vEthernet*,flannel*,cni*,calico*
primary-nics=eth0
low-priority-nics=eth1,eth2,eth3
EOF

echo "==============================================================================================================================="
echo "= Cleanup"
echo "==============================================================================================================================="

# Delete default cni config from containerd
rm -rf /etc/cni/net.d/*

[ -f /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg ] && rm /etc/cloud/cloud.cfg.d/50-curtin-networking.cfg
rm /etc/netplan/*
cloud-init clean
cloud-init clean -l

rm -rf /etc/apparmor.d/cache/* /etc/apparmor.d/cache/.features
/usr/bin/truncate --size 0 /etc/machine-id
rm -f /snap/README
find /usr/share/netplan -name __pycache__ -exec rm -r {} +
rm -rf /var/cache/pollinate/seeded /var/cache/snapd/* /var/cache/motd-news
rm -rf /var/lib/cloud /var/lib/dbus/machine-id /var/lib/private /var/lib/systemd/timers /var/lib/systemd/timesync /var/lib/systemd/random-seed
rm -f /var/lib/ubuntu-release-upgrader/release-upgrade-available
rm -f /var/lib/update-notifier/fsck-at-reboot /var/lib/update-notifier/hwe-eol
find /var/log -type f -exec rm -f {} +
rm -r /tmp/* /tmp/.*-unix /var/tmp/*
/bin/sync


#/bin/bash

#set -e

# This script will create 2 VM used as template
# The first one is the seed VM customized to use vmware guestinfos cloud-init datasource instead ovf datasource.
# This step is done by importing https://cloud-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-amd64.ova
# If don't have the right to import OVA with govc to your vpshere you can try with ovftool import method else you must build manually this seed
# Jump to Prepare seed VM comment.
# Very important, shutdown the seed VM by using shutdown guest or shutdown -P now. Never use PowerOff vsphere command
# This VM will be used to create the kubernetes template VM 

# The second VM will contains everything to run kubernetes

CURDIR=$(dirname $0)
DISTRO=jammy
KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
CNI_PLUGIN_VERSION=v1.2.0
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
CACHE=~/.local/vmware/cache
TARGET_IMAGE=${DISTRO}-kubernetes-$KUBERNETES_VERSION
PASSWORD=$(uuidgen)
OSDISTRO=$(uname -s)
SEEDIMAGE=${DISTRO}-server-cloudimg-seed
IMPORTMODE="govc"
CURDIR=$(dirname $0)
USER=ubuntu
PRIMARY_NETWORK_ADAPTER=vmxnet3
PRIMARY_NETWORK_NAME="$GOVC_NETWORK"
SECOND_NETWORK_ADAPTER=vmxnet3
SECOND_NETWORK_NAME=
SEED_ARCH=$([ "$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
CONTAINER_ENGINE=docker
CONTAINER_CTL=docker
KUBERNETES_DISTRO=kubedm

source $CURDIR/common.sh

mkdir -p $ISODIR
mkdir -p $CACHE

TEMP=`getopt -o d:a:i:k:n:op:s:u:v: --long k8s-distribution:,aws-access-key:,aws-secret-key:,distribution:,arch:,container-runtime:,user:,adapter:,primary-adapter:,primary-network:,second-adapter:,second-network:,ovftool,seed:,custom-image:,ssh-key:,cni-version:,password:,kubernetes-version: -n "$0" -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true ; do
    #echo "1:$1"
    case "$1" in
        -d|--distribution)
            DISTRO="$2"
            TARGET_IMAGE=${DISTRO}-kubernetes-$KUBERNETES_VERSION
            SEEDIMAGE=${DISTRO}-server-cloudimg-seed
            shift 2
            ;;
        -i|--custom-image) TARGET_IMAGE="$2" ; shift 2;;
        -k|--ssh-key) SSH_KEY=$2 ; shift 2;;
        -n|--cni-version) CNI_PLUGIN_VERSION=$2 ; shift 2;;
        -o|--ovftool) IMPORTMODE=ovftool ; shift 2;;
        -p|--password) PASSWORD=$2 ; shift 2;;
        -s|--seed) SEEDIMAGE=$2 ; shift 2;;
        -a|--arch) SEED_ARCH=$2 ; shift 2;;
        -u|--user) USER=$2 ; shift 2;;
        -v|--kubernetes-version) KUBERNETES_VERSION=$2 ; shift 2;;
        --primary-adapter) PRIMARY_NETWORK_ADAPTER=$2 ; shift 2;;
        --primary-network) PRIMARY_NETWORK_NAME=$2 ; shift 2;;
        --second-adapter) SECOND_NETWORK_ADAPTER=$2 ; shift 2;;
        --second-network) SECOND_NETWORK_NAME=$2 ; shift 2;;
        --k8s-distribution) 
            case "$2" in
                kubeadm|k3s|rke2)
                KUBERNETES_DISTRO=$2
                ;;
            *)
                echo "Unsupported kubernetes distribution: $2"
                exit 1
                ;;
            esac
            shift 2
            ;;
        --container-runtime)
            case "$2" in
                "docker")
                    CONTAINER_ENGINE="$2"
                    CONTAINER_CTL=docker
                    ;;
                "cri-o"|"containerd")
                    CONTAINER_ENGINE="$2"
                    CONTAINER_CTL=crictl
                    ;;
                *)
                    echo_red_bold "Unsupported container runtime: $2"
                    exit 1
                    ;;
            esac
            shift 2;;
        
        --aws-access-key)
            AWS_ACCESS_KEY_ID=$2
            shift 2
            ;;
        --aws-secret-key)
            AWS_SECRET_ACCESS_KEY=$2
            shift 2
            ;;

        --) shift ; break ;;
        *) echo_red_bold "$1 - Internal error!" ; exit 1 ;;
    esac
done

if [ -n "$(govc vm.info $TARGET_IMAGE 2>&1)" ]; then
    echo_blue_bold "$TARGET_IMAGE already exists!"
    exit 0
fi

echo_blue_bold "Ubuntu password:$PASSWORD"

BOOTSTRAP_PASSWORD=$(uuidgen)
read -a VCENTER <<<"$(echo $GOVC_URL | awk -F/ '{print $3}' | tr '@' ' ')"
VCENTER=${VCENTER[${#VCENTER[@]} - 1]}

USERDATA=$(base64 <<EOF
#cloud-config
password: $BOOTSTRAP_PASSWORD
chpasswd: 
  expire: false
  users:
    - name: ubuntu
      password: $PASSWORD
      type: text
ssh_pwauth: true
EOF
)

# If your seed image isn't present create one by import ${DISTRO} cloud ova.
# If you don't have the access right to import with govc (firewall rules blocking https traffic to esxi),
# you can try with ovftool to import the ova.
# If you have the bug "unsupported server", you must do it manually!
if [ -z "$(govc vm.info $SEEDIMAGE 2>&1)" ]; then
    [ -f ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.ova ] || curl -Ls https://cloud-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-${SEED_ARCH}.ova -o ${CACHE}/${DISTRO}-server-cloudimg-amd64.ova

    if [ "${IMPORTMODE}" == "govc" ]; then
        govc import.spec ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.ova \
            | jq \
                --arg GOVC_NETWORK "${PRIMARY_NETWORK_NAME}" \
                '.NetworkMapping = [ { Name: $GOVC_NETWORK, Network: $GOVC_NETWORK } ]' \
            > ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.spec
        
        cat ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.spec \
            | jq --arg SSH_KEY "${SSH_KEY}" \
                --arg SSH_KEY "${SSH_KEY}" \
                --arg USERDATA "${USERDATA}" \
                --arg PASSWORD "${BOOTSTRAP_PASSWORD}" \
                --arg NAME "${SEEDIMAGE}" \
                --arg INSTANCEID $(uuidgen) \
                --arg TARGET_IMAGE "$TARGET_IMAGE" \
                '.Name = $NAME | .PropertyMapping |= [ { Key: "instance-id", Value: $INSTANCEID }, { Key: "hostname", Value: $TARGET_IMAGE }, { Key: "public-keys", Value: $SSH_KEY }, { Key: "user-data", Value: $USERDATA }, { Key: "password", Value: $PASSWORD } ]' \
                > ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.txt

        DATASTORE="/${GOVC_DATACENTER}/datastore/${GOVC_DATASTORE}"
        FOLDER="/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"

        echo_blue_bold "Import ${DISTRO}-server-cloudimg-${SEED_ARCH}.ova to ${SEEDIMAGE} with govc"
        govc import.ova \
            -options=${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.txt \
            -folder="${FOLDER}" \
            -ds="${DATASTORE}" \
            -name="${SEEDIMAGE}" \
            ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.ova
    else
        echo_blue_bold "Import ${DISTRO}-server-cloudimg-${SEED_ARCH}.ova to ${SEEDIMAGE} with ovftool"

        MAPPED_NETWORK=$(govc import.spec ${CACHE}/${DISTRO}-server-cloudimg-${SEED_ARCH}.ova | jq -r '.NetworkMapping[0].Name//""')

        ovftool \
            --acceptAllEulas \
            --name="${SEEDIMAGE}" \
            --datastore="${GOVC_DATASTORE}" \
            --vmFolder="${GOVC_FOLDER}" \
            --diskMode=thin \
            --prop:instance-id="$(uuidgen)" \
            --prop:hostname="${SEEDIMAGE}" \
            --prop:public-keys="${SSH_KEY}" \
            --prop:user-data="${USERDATA}" \
            --prop:password="${BOOTSTRAP_PASSWORD}" \
            --net:"${MAPPED_NETWORK}"="${PRIMARY_NETWORK_NAME}" \
            https://cloud-images.ubuntu.com/${DISTRO}/current/${DISTRO}-server-cloudimg-${SEED_ARCH}.ova \
            "vi://${GOVC_USERNAME}:${GOVC_PASSWORD}@${VCENTER}/${GOVC_RESOURCE_POOL}/"
    fi

    if [ $? -eq 0 ]; then

        if [ -n "${PRIMARY_NETWORK_ADAPTER}" ];then
            echo_blue_bold "Change primary network card ${PRIMARY_NETWORK_NAME} to ${PRIMARY_NETWORK_ADAPTER} on ${SEEDIMAGE}"

            govc vm.network.change -vm "${SEEDIMAGE}" -net="${PRIMARY_NETWORK_NAME}" -net.adapter="${PRIMARY_NETWORK_ADAPTER}"
        fi

        if [ -n "${SECOND_NETWORK_NAME}" ]; then
            echo_blue_bold "Add second network card ${SECOND_NETWORK_NAME} on ${SEEDIMAGE}"

            govc vm.network.add -vm "${SEEDIMAGE}" -net="${SECOND_NETWORK_NAME}" -net.adapter="${SECOND_NETWORK_ADAPTER}"
        fi

        echo_blue_bold "Power On ${SEEDIMAGE}"
        govc vm.upgrade -version=17 -vm ${SEEDIMAGE}
        govc vm.power -on "${SEEDIMAGE}"

        echo_blue_bold "Wait for IP from $SEEDIMAGE"
        IPADDR=$(govc vm.ip -wait 5m "${SEEDIMAGE}")

        if [ -z "${IPADDR}" ]; then
            echo_red_bold "Can't get IP!"
            exit -1
        fi

        # Prepare seed VM
        echo_blue_bold "Install cloud-init VMWareGuestInfo datasource"

        ssh -t "${USER}@${IPADDR}" sudo "sh -c 'echo datasource_list: [ NoCloud, VMware, OVF ] > /etc/cloud/cloud.cfg.d/99-VMWare-Only.cfg'"

        echo_blue_bold "clean cloud-init"
        ssh -t "${USER}@${IPADDR}" sudo cloud-init clean
        ssh -t "${USER}@${IPADDR}" sudo cloud-init clean -l
        ssh -t "${USER}@${IPADDR}" sudo shutdown -h now
        
        # Shutdown the guest
        govc vm.power -persist-session=false -s "${SEEDIMAGE}"

        echo_blue_bold "Wait ${SEEDIMAGE} to shutdown"
        while [ $(govc vm.info -json "${SEEDIMAGE}" | jq .VirtualMachines[0].Runtime.PowerState | tr -d '"') == "poweredOn" ]
        do
            echo_blue_dot
            sleep 1
        done
        echo

        sleep 5

        echo_blue_bold "${SEEDIMAGE} is ready"
    else
        echo_red_bold "Import failed!"
        exit -1
    fi 
else
    echo_blue_bold "${SEEDIMAGE} already exists, nothing to do!"
fi

case "${KUBERNETES_DISTRO}" in
    k3s|rke2)
        CREDENTIALS_CONFIG=/var/lib/rancher/credentialprovider/config.yaml
        CREDENTIALS_BIN=/var/lib/rancher/credentialprovider/bin
        ;;
    kubeadm)
        CREDENTIALS_CONFIG=/etc/kubernetes/credential.yaml
        CREDENTIALS_BIN=/usr/local/bin
        ;;
esac

KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')
CRIO_VERSION=$(echo -n $KUBERNETES_VERSION | tr -d 'v' | tr '.' ' ' | awk '{ print $1"."$2 }')

echo_blue_bold "Prepare ${TARGET_IMAGE} image with cri-o version: $CRIO_VERSION and kubernetes: $KUBERNETES_VERSION"

cat > "${ISODIR}/user-data" <<EOF
#cloud-config
EOF

cat > "${ISODIR}/network.yaml" <<EOF
#cloud-config
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: true
EOF

cat > "${ISODIR}/vendor-data" <<EOF
#cloud-config
timezone: $TZ
ssh_authorized_keys:
    - $SSH_KEY
users:
    - default
system_info:
    default_user:
        name: kubernetes
EOF

cat > "${ISODIR}/meta-data" <<EOF
{
    "local-hostname": "$TARGET_IMAGE",
    "instance-id": "$(uuidgen)"
}
EOF

cat > "${ISODIR}/prepare-image.sh" << EOF
#!/bin/bash
SEED_ARCH=${SEED_ARCH}
CNI_PLUGIN=${CNI_PLUGIN}
CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION}
KUBERNETES_VERSION=${KUBERNETES_VERSION}
KUBERNETES_MINOR_RELEASE=${KUBERNETES_MINOR_RELEASE}
CRIO_VERSION=${CRIO_VERSION}
CONTAINER_ENGINE=${CONTAINER_ENGINE}
CONTAINER_CTL=${CONTAINER_CTL}
KUBERNETES_DISTRO=${KUBERNETES_DISTRO}
CREDENTIALS_CONFIG=$CREDENTIALS_CONFIG
CREDENTIALS_BIN=$CREDENTIALS_BIN
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}

sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/' /etc/default/grub
update-grub

echo "==============================================================================================================================="
echo "= Upgrade ubuntu distro"
echo "==============================================================================================================================="
apt update
apt dist-upgrade -y
echo

apt update

echo "==============================================================================================================================="
echo "= Install mandatories packages"
echo "==============================================================================================================================="
apt install jq socat conntrack net-tools traceroute nfs-common unzip -y
echo

mkdir -p /etc/kubernetes

EOF

cat >> "${ISODIR}/prepare-image.sh" <<"EOF"
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

if [ -n "${AWS_ACCESS_KEY_ID}" ] && [ -n "${AWS_SECRET_ACCESS_KEY}" ]; then

    if [ ${KUBERNETES_MINOR_RELEASE} -gt 26 ]; then
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

    cat > /root/.aws/config <<SHELL
[default]
output = json
region = us-east-1
cli_binary_format=raw-in-base64-out
SHELL

    cat > /root/.aws/credentials <<SHELL
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
SHELL

    cat > ${CREDENTIALS_CONFIG} <<SHELL
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
SHELL
fi
EOF

if [ "${KUBERNETES_DISTRO}" == "rke2" ]; then
    echo "prepare rke2 image"

    cat >> "${ISODIR}/prepare-image.sh" <<"EOF"
    curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL="${KUBERNETES_VERSION}" sh -

    pushd /usr/local/bin
    curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION%%+*}/bin/linux/${SEED_ARCH}/{kubectl,kube-proxy}
    chmod +x /usr/local/bin/kube*
    popd

    mkdir -p /etc/rancher/rke2
    mkdir -p /etc/NetworkManager/conf.d

    cat > /etc/NetworkManager/conf.d/rke2-canal.conf <<"SHELL"
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:flannel*
SHELL
    cat > /etc/rancher/rke2/config.yaml <<"SHELL"
kubelet-arg:
  - cloud-provider=external
  - fail-swap-on=false
SHELL
EOF

elif [ "${KUBERNETES_DISTRO}" == "k3s" ]; then
    echo "prepare k3s image"

    cat >> "${ISODIR}/prepare-image.sh" <<"EOF"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${KUBERNETES_VERSION}" INSTALL_K3S_SKIP_ENABLE=true sh -

    mkdir -p /etc/systemd/system/k3s.service.d
    echo "K3S_MODE=agent" > /etc/default/k3s
    echo "K3S_ARGS=" > /etc/systemd/system/k3s.service.env
    echo "K3S_SERVER_ARGS=" > /etc/systemd/system/k3s.server.env
    echo "K3S_AGENT_ARGS=" > /etc/systemd/system/k3s.agent.env
    echo "K3S_DISABLE_ARGS=" > /etc/systemd/system/k3s.disabled.env

    cat > /etc/systemd/system/k3s.service.d/10-k3s.conf <<"SHELL"
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

SHELL
EOF

else
    echo "prepare kubeadm image"

    cat >> "${ISODIR}/prepare-image.sh" <<"EOF"
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

        cat > /etc/docker/daemon.json <<SHELL
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
SHELL

        # Restart docker.
        systemctl daemon-reload
        systemctl restart docker

        usermod -aG docker ubuntu

    elif [ "${CONTAINER_ENGINE}" == "containerd" ]; then

        echo "==============================================================================================================================="
        echo "Install Containerd"
        echo "==============================================================================================================================="

        curl -sL https://github.com/containerd/containerd/releases/download/v1.7.0/cri-containerd-cni-1.7.0-linux-${SEED_ARCH}.tar.gz | tar -C / -xz

        mkdir -p /etc/containerd
        containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g' | tee /etc/containerd/config.toml

        systemctl enable containerd.service
        systemctl restart containerd

        curl -sL https://github.com/containerd/nerdctl/releases/download/v1.3.1/nerdctl-1.3.1-linux-${SEED_ARCH}.tar.gz | tar -C /usr/local/bin -xz
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

    cat > /etc/systemd/system/kubelet.service <<SHELL
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
SHELL

    mkdir -p /etc/systemd/system/kubelet.service.d

    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<"SHELL"
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
SHELL

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
        curl -s -O -L "https://github.com/projectcalico/calicoctl/releases/download/v3.18.2/calicoctl-linux-${SEED_ARCH}"
        chmod +x calicoctl-linux-${SEED_ARCH}
        mv calicoctl-linux-${SEED_ARCH} /usr/local/bin/calicoctl
        pull_image https://docs.projectcalico.org/manifests/calico-vxlan.yaml
    elif [ "$CNI_PLUGIN" = "flannel" ]; then
        pull_image https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    elif [ "$CNI_PLUGIN" = "weave" ]; then
        pull_image "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
    elif [ "$CNI_PLUGIN" = "canal" ]; then
        pull_image https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml
        pull_image https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
    elif [ "$CNI_PLUGIN" = "kube" ]; then
        pull_image https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml
        pull_image https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter-all-features.yaml
    elif [ "$CNI_PLUGIN" = "romana" ]; then
        pull_image https://raw.githubusercontent.com/romana/romana/master/containerize/specs/romana-kubeadm.yml
    fi
EOF

fi

cat >> "${ISODIR}/prepare-image.sh" <<"EOF"
apt dist-upgrade -y
apt autoremove -y

cat >> /etc/vmware-tools/tools.conf <<SHELL
[guestinfo]
exclude-nics=docker*,veth*,vEthernet*,flannel*,cni*,calico*
primary-nics=eth0
low-priority-nics=eth1,eth2,eth3
SHELL

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
EOF

chmod +x "${ISODIR}/prepare-image.sh"

gzip -c9 < "${ISODIR}/meta-data" | base64 -w 0 > ${CACHE}/metadata.base64
gzip -c9 < "${ISODIR}/user-data" | base64 -w 0 > ${CACHE}/userdata.base64
gzip -c9 < "${ISODIR}/vendor-data" | base64 -w 0 > ${CACHE}/vendordata.base64

# Due to my vsphere center the folder name refer more path, so I need to precise the path instead
if [ "${GOVC_FOLDER}" ]; then
    FOLDERS=$(govc folder.info ${GOVC_FOLDER}|grep Path|wc -l)
    if [ "${FOLDERS}" != "1" ]; then
        FOLDER_OPTIONS="-folder=/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
    fi
fi

govc vm.clone -on=false ${FOLDER_OPTIONS} -c=2 -m=4096 -vm=${SEEDIMAGE} ${TARGET_IMAGE}

govc vm.change -vm "${TARGET_IMAGE}" \
    -e disk.enableUUID=1 \
    -e guestinfo.metadata="$(cat ${CACHE}/metadata.base64)" \
    -e guestinfo.metadata.encoding="gzip+base64" \
    -e guestinfo.userdata="$(cat ${CACHE}/userdata.base64)" \
    -e guestinfo.userdata.encoding="gzip+base64" \
    -e guestinfo.vendordata="$(cat ${CACHE}/vendordata.base64)" \
    -e guestinfo.vendordata.encoding="gzip+base64"

echo_blue_bold "Power On ${TARGET_IMAGE}"
govc vm.power -on "${TARGET_IMAGE}"

echo_blue_bold "Wait for IP from ${TARGET_IMAGE}"
IPADDR=$(govc vm.ip -wait 5m "${TARGET_IMAGE}")

scp "${ISODIR}/prepare-image.sh" "${USER}@${IPADDR}:~"

ssh -t "${USER}@${IPADDR}" sudo ./prepare-image.sh

govc vm.power -persist-session=false -s=true "${TARGET_IMAGE}"

echo_blue_dot_title "Wait ${TARGET_IMAGE} to shutdown"
while [ $(govc vm.info -json "${TARGET_IMAGE}" | jq .VirtualMachines[0].Runtime.PowerState | tr -d '"') == "poweredOn" ]
do
    echo_blue_dot
    sleep 1
done
echo

sleep 10

echo_blue_bold "Created image ${TARGET_IMAGE} with kubernetes version ${KUBERNETES_VERSION}"

exit 0

#/bin/bash

#set -e

# This script will create 2 VM used as template
# The first one is the seed VM customized to use vmware guestinfos cloud-init datasource instead ovf datasource.
# This step is done by importing https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.ova
# If don't have the right to import OVA with govc to your vpshere you can try with ovftool import method else you must build manually this seed
# Jump to Prepare seed VM comment.
# Very important, shutdown the seed VM by using shutdown guest or shutdown -P now. Never use PowerOff vsphere command
# This VM will be used to create the kubernetes template VM 

# The second VM will contains everything to run kubernetes

KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
CNI_PLUGIN_VERSION=v1.0.1
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
CACHE=~/.local/vmware/cache
TARGET_IMAGE=focal-kubernetes-$KUBERNETES_VERSION
PASSWORD=$(uuidgen)
OSDISTRO=$(uname -s)
SEEDIMAGE=focal-server-cloudimg-seed
IMPORTMODE="govc"
CURDIR=$(dirname $0)
USER=ubuntu
PRIMARY_NETWORK_ADAPTER=vmxnet3
PRIMARY_NETWORK_NAME=$GOVC_NETWORK
SECOND_NETWORK_ADAPTER=vmxnet3
SECOND_NETWORK_NAME=
SEED_ARCH=$([ "$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
CONTAINER_ENGINE=docker
CONTAINER_CTL=docker

if [ "$OSDISTRO" == "Linux" ]; then
    TZ=$(cat /etc/timezone)
    BASE64='base64 -w 0'
    ISODIR=~/.local/vmware/cache
else
    TZ=$(sudo systemsetup -gettimezone | awk '{print $2}')
    BASE64=base64
    ISODIR=~/.local/vmware/cache/iso
fi

mkdir -p $ISODIR
mkdir -p $CACHE

TEMP=`getopt -o a:i:k:n:op:s:u:v: --long arch:,container-runtime:,user:,adapter:,primary-adapter:,primary-network:,second-adapter:,second-network:,ovftool,seed:,custom-image:,ssh-key:,cni-version:,password:,kubernetes-version: -n "$0" -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true ; do
	#echo "1:$1"
    case "$1" in
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
                    echo "Unsupported container runtime: $2"
                    exit 1
                    ;;
            esac
            shift 2;;
        --) shift ; break ;;
        *) echo "$1 - Internal error!" ; exit 1 ;;
    esac
done

if [ ! -z "$(govc vm.info $TARGET_IMAGE 2>&1)" ]; then
    echo "$TARGET_IMAGE already exists!"
    exit 0
fi

echo "Ubuntu password:$PASSWORD"

USERDATA=$(base64 <<EOF
#cloud-config
password: $PASSWORD
chpasswd: { expire: false }
ssh_pwauth: true
EOF
)

# If your seed image isn't present create one by import focal cloud ova.
# If you don't have the access right to import with govc (firewall rules blocking https traffic to esxi),
# you can try with ovftool to import the ova.
# If you have the bug "unsupported server", you must do it manually!
if [ -z "$(govc vm.info $SEEDIMAGE 2>&1)" ]; then
    [ -f ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.ova ] || wget https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-${SEED_ARCH}.ova -O ${CACHE}/focal-server-cloudimg-amd64.ova
        
    MAPPED_NETWORK=$(govc import.spec ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.ova | jq .NetworkMapping[0].Name | tr -d '"')

    if [ "${IMPORTMODE}" == "govc" ]; then

        govc import.spec ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.ova \
            | jq --arg GOVC_NETWORK "${PRIMARY_NETWORK_NAME}" --arg MAPPED_NETWORK "${MAPPED_NETWORK}" '.NetworkMapping |= [ { Name: $MAPPED_NETWORK, Network: $GOVC_NETWORK } ]' \
            > ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.spec
        
        cat ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.spec \
            | jq --arg SSH_KEY "${SSH_KEY}" \
                --arg SSH_KEY "${SSH_KEY}" \
                --arg USERDATA "${USERDATA}" \
                --arg PASSWORD "${PASSWORD}" \
                --arg NAME "${SEEDIMAGE}" \
                --arg INSTANCEID $(uuidgen) \
                --arg TARGET_IMAGE "$TARGET_IMAGE" \
                '.Name = $NAME | .PropertyMapping |= [ { Key: "instance-id", Value: $INSTANCEID }, { Key: "hostname", Value: $TARGET_IMAGE }, { Key: "public-keys", Value: $SSH_KEY }, { Key: "user-data", Value: $USERDATA }, { Key: "password", Value: $PASSWORD } ]' \
                > ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.txt

        if [ -z "${GOVC_CLUSTER}" ]; then
            DATASTORE="/${GOVC_DATACENTER}/datastore/${GOVC_DATASTORE}"
            FOLDER="/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
        else
            DATASTORE="/${GOVC_DATACENTER}/datastore/${GOVC_CLUSTER}/CUSTOMER/${GOVC_FOLDER}/${GOVC_DATASTORE}"
            FOLDER="/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
        fi

        echo "Import focal-server-cloudimg-${SEED_ARCH}.ova to ${SEEDIMAGE} with govc"
        govc import.ova \
            -options=${CACHE}/focal-server-cloudimg-${SEED_ARCH}.txt \
            -folder="${FOLDER}" \
            -ds="${DATASTORE}" \
            -name="${SEEDIMAGE}" \
            ${CACHE}/focal-server-cloudimg-${SEED_ARCH}.ova
    else
        echo "Import focal-server-cloudimg-${SEED_ARCH}.ova to ${SEEDIMAGE} with ovftool"

        ovftool \
            --acceptAllEulas \
            --name="${SEEDIMAGE}" \
            --datastore="${GOVC_DATASTORE}" \
            --vmFolder="${GOVC_FOLDER}" \
            --diskMode=thin \
            --prop:instance-id="$(uuidgen)" \
            --prop:hostname="${SEEDIMAGE}" \
            --prop:public-keys="${SSH_KEY}" \
            --prop:user-data="" \
            --prop:password="${PASSWORD}" \
            --net:"${MAPPED_NETWORK}"="${PRIMARY_NETWORK_NAME}" \
            https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-${SEED_ARCH}.ova \
            "vi://${GOVC_USERNAME}:${GOVC_PASSWORD}@${GOVC_HOST}/${GOVC_RESOURCE_POOL}/"
    fi

    if [ $? -eq 0 ]; then
    
        if [ ! -z "${PRIMARY_NETWORK_ADAPTER}" ];then
            echo "Change primary network card ${PRIMARY_NETWORK_NAME} to ${PRIMARY_NETWORK_ADAPTER} on ${SEEDIMAGE}"

            govc vm.network.change -vm "${SEEDIMAGE}" -net="${PRIMARY_NETWORK_NAME}" -net.adapter="${PRIMARY_NETWORK_ADAPTER}"
        fi

        if [ ! -z "${SECOND_NETWORK_NAME}" ]; then
            echo "Add second network card ${SECOND_NETWORK_NAME} on ${SEEDIMAGE}"

            govc vm.network.add -vm "${SEEDIMAGE}" -net="${SECOND_NETWORK_NAME}" -net.adapter="${SECOND_NETWORK_ADAPTER}"
        fi

        echo "Power On ${SEEDIMAGE}"
        govc vm.power -on "${SEEDIMAGE}"

        echo "Wait for IP from $SEEDIMAGE"
        IPADDR=$(govc vm.ip -wait 5m "${SEEDIMAGE}")

        if [ -z "${IPADDR}" ]; then
            echo "Can't get IP!"
            exit -1
        fi

        # Prepare seed VM
        echo "Install cloud-init VMWareGuestInfo datasource"
        scp "${CURDIR}/../guestinfos/install-guestinfo-datasource.sh" "${CURDIR}/../guestinfos/cloud-init-clean.sh" "${USER}@${IPADDR}:/tmp"
        ssh -t "${USER}@${IPADDR}" sudo mv /tmp/cloud-init-clean.sh /tmp/install-guestinfo-datasource.sh /usr/local/bin
        ssh -t "${USER}@${IPADDR}" sudo /usr/local/bin/install-guestinfo-datasource.sh

        # Shutdown the guest
        govc vm.power -persist-session=false -s "${SEEDIMAGE}"

        sleep 10

        echo "${SEEDIMAGE} is ready"
    else
        echo "Import failed!"
        exit -1
    fi 
else
    echo "${SEEDIMAGE} already exists, nothing to do!"
fi

KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | tr '.' ' ' | awk '{ print $2 }')
CRIO_VERSION=$(echo -n $KUBERNETES_VERSION | tr -d 'v' | tr '.' ' ' | awk '{ print $1"."$2 }')

echo "Prepare ${TARGET_IMAGE} image with cri-o version: $CRIO_VERSION and kubernetes: $KUBERNETES_VERSION"

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

if [ ! -z "${SECOND_NETWORK_NAME}" ]; then
cat > "${ISODIR}/network.yaml" <<EOF
        eth1:
            dhcp4: true
EOF
fi

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

cat > "${CACHE}/prepare-image.sh" << EOF
#!/bin/bash
SEED_ARCH=${SEED_ARCH}
CNI_PLUGIN=${CNI_PLUGIN}
CNI_PLUGIN_VERSION=${CNI_PLUGIN_VERSION}
KUBERNETES_VERSION=${KUBERNETES_VERSION}
KUBERNETES_MINOR_RELEASE=${KUBERNETES_MINOR_RELEASE}
CRIO_VERSION=${CRIO_VERSION}
CONTAINER_ENGINE=${CONTAINER_ENGINE}
CONTAINER_CTL=${CONTAINER_CTL}

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
apt install jq socat conntrack awscli net-tools traceroute -y
echo

EOF

cat >> "${ISODIR}/prepare-image.sh" <<"EOF"
function pull_image() {
    DOCKER_IMAGES=$(curl -s $1 | grep "image: " | sed -E 's/.+image: (.+)/\1/g')
    
    for DOCKER_IMAGE in $DOCKER_IMAGES
    do
        echo "Pull image $DOCKER_IMAGE"
        ${CONTAINER_CTL} pull $DOCKER_IMAGE
    done
}

mkdir -p /opt/cni/bin
mkdir -p /usr/local/bin

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

    apt-get update

    curl -sL  https://github.com/containerd/containerd/releases/download/v1.5.8/cri-containerd-cni-1.5.8-linux-amd64.tar.gz | tar -C / -xz

    mkdir -p /etc/containerd
    containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/g' | tee /etc/containerd/config.toml

    systemctl enable containerd.service
    systemctl restart containerd
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

#    cat > /etc/crio/crio.conf.d/02-cgroup-manager.conf <<SHELL
#conmon_cgroup = "pod"
#cgroup_manager = "cgroupfs"
#SHELL

    systemctl daemon-reload
    systemctl enable crio
    systemctl restart crio
fi

if [ ! -f /usr/local/bin/crictl ]; then
    echo "==============================================================================================================================="
    echo "= Install crictl"
    echo "==============================================================================================================================="
    curl -sL https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRIO_VERSION}.0/crictl-v${CRIO_VERSION}.0-linux-${SEED_ARCH}.tar.gz  | tar -C /usr/local/bin -xz
    chmod +x /usr/local/bin/crictl
fi

echo "==============================================================================================================================="
echo "= Clean ubuntu distro"
echo "==============================================================================================================================="
apt-get autoremove -y
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

mkdir -p /etc/systemd/system/kubelet.service.d
mkdir -p /var/lib/kubelet

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

echo 'KUBELET_EXTRA_ARGS="--fail-swap-on=false --read-only-port=10255"' > /etc/default/kubelet

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
    pull_image https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
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

gzip -c9 < "${ISODIR}/meta-data" | $BASE64 > ${CACHE}/metadata.base64
gzip -c9 < "${ISODIR}/user-data" | $BASE64 > ${CACHE}/userdata.base64
gzip -c9 < "${ISODIR}/vendor-data" | $BASE64 > ${CACHE}/vendordata.base64

# Due to my vsphere center the folder name refer more path, so I need to precise the path instead
if [ "${GOVC_FOLDER}" ]; then
    FOLDERS=$(govc folder.info ${GOVC_FOLDER}|grep Path|wc -l)
    if [ "${FOLDERS}" != "1" ]; then
        FOLDER_OPTIONS="-folder=/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
    fi
fi

govc vm.clone -on=false ${FOLDER_OPTIONS} -c=2 -m=4096 -vm=${SEEDIMAGE} ${TARGET_IMAGE}

govc vm.change -vm "${TARGET_IMAGE}" \
    -e guestinfo.metadata="$(cat ${CACHE}/metadata.base64)" \
    -e guestinfo.metadata.encoding="gzip+base64" \
    -e guestinfo.userdata="$(cat ${CACHE}/userdata.base64)" \
    -e guestinfo.userdata.encoding="gzip+base64" \
    -e guestinfo.vendordata="$(cat ${CACHE}/vendordata.base64)" \
    -e guestinfo.vendordata.encoding="gzip+base64"

echo "Power On ${TARGET_IMAGE}"
govc vm.power -on "${TARGET_IMAGE}"

echo "Wait for IP from ${TARGET_IMAGE}"
IPADDR=$(govc vm.ip -wait 5m "${TARGET_IMAGE}")

scp "${ISODIR}/prepare-image.sh" "${USER}@${IPADDR}:~"

ssh -t "${USER}@${IPADDR}" sudo ./prepare-image.sh

govc vm.power -persist-session=false -s=true "${TARGET_IMAGE}"

echo "Wait ${TARGET_IMAGE} to shutdown"
while [ $(govc vm.info -json "${TARGET_IMAGE}" | jq .VirtualMachines[0].Runtime.PowerState | tr -d '"') == "poweredOn" ]
do
    echo -n "."
    sleep 1
done
echo

echo "Created image ${TARGET_IMAGE} with kubernetes version ${KUBERNETES_VERSION}"

exit 0

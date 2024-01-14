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
CNI_PLUGIN_VERSION=v1.4.0
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
CACHE=~/.local/vmware/cache
TARGET_IMAGE=${DISTRO}-kubernetes-$KUBERNETES_VERSION
KUBERNETES_PASSWORD=$(uuidgen)
OSDISTRO=$(uname -s)
SEEDIMAGE=${DISTRO}-server-cloudimg-seed
IMPORTMODE="govc"
CURDIR=$(dirname $0)
USER=ubuntu
PRIMARY_NETWORK_ADAPTER=vmxnet3
PRIMARY_NETWORK_NAME="$GOVC_NETWORK"
SECOND_NETWORK_ADAPTER=vmxnet3
SECOND_NETWORK_NAME=
SEED_ARCH=$([[ "$(uname -m)" =~ arm64|aarch64 ]] && echo -n arm64 || echo -n amd64)
CONTAINER_ENGINE=docker
CONTAINER_CTL=docker
KUBERNETES_DISTRO=kubeadm

source $CURDIR/common.sh

mkdir -p $CACHE

TEMP=`getopt -o d:a:i:k:n:op:s:u:v: --long k8s-distribution:,aws-access-key:,aws-secret-key:,distribution:,arch:,container-runtime:,user:,adapter:,primary-adapter:,primary-network:,second-adapter:,second-network:,ovftool,seed:,custom-image:,ssh-key:,cni-version:,password:,kubernetes-version: -n "$0" -- "$@"`
eval set -- "$TEMP"

# extract options and their arguments into variables.
while true ; do
    #echo "1:$1"
    case "$1" in
        -d|--distribution)
            DISTRO="$2"
            TARGET_IMAGE=${DISTRO}-${KUBERNETES_DISTRO}-${KUBERNETES_VERSION}-${SEED_ARCH}.img
            SEEDIMAGE=${DISTRO}-server-cloudimg-seed
            shift 2
            ;;
        -i|--custom-image) TARGET_IMAGE="$2" ; shift 2;;
        -k|--ssh-key) SSH_KEY=$2 ; shift 2;;
        -n|--cni-version) CNI_PLUGIN_VERSION=$2 ; shift 2;;
        -o|--ovftool) IMPORTMODE=ovftool ; shift 2;;
        -p|--password) KUBERNETES_PASSWORD=$2 ; shift 2;;
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

echo_blue_bold "Ubuntu password:$KUBERNETES_PASSWORD"

BOOTSTRAP_PASSWORD=$(uuidgen)
read -a VCENTER <<< "$(echo $GOVC_URL | awk -F/ '{print $3}' | tr '@' ' ')"
VCENTER=${VCENTER[${#VCENTER[@]} - 1]}

USERDATA=$(base64 <<EOF
#cloud-config
password: $BOOTSTRAP_PASSWORD
chpasswd: 
  expire: false
  users:
    - name: ubuntu
      password: $KUBERNETES_PASSWORD
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
                --arg KUBERNETES_PASSWORD "${BOOTSTRAP_PASSWORD}" \
                --arg NAME "${SEEDIMAGE}" \
                --arg INSTANCEID $(uuidgen) \
                --arg TARGET_IMAGE "$TARGET_IMAGE" \
                '.Name = $NAME | .PropertyMapping |= [ { Key: "instance-id", Value: $INSTANCEID }, { Key: "hostname", Value: $TARGET_IMAGE }, { Key: "public-keys", Value: $SSH_KEY }, { Key: "user-data", Value: $USERDATA }, { Key: "password", Value: $KUBERNETES_PASSWORD } ]' \
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

        ssh -t "${USER}@${IPADDR}" <<EOF
        sudo sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"/' /etc/default/grub
        sudo update-grub
        sudo apt update
        sudo apt dist-upgrade -y
        sudo apt install jq socat conntrack net-tools traceroute nfs-common unzip -y
        sudo sh -c 'echo datasource_list: [ NoCloud, VMware, OVF ] > /etc/cloud/cloud.cfg.d/99-VMWare-Only.cfg'
        exit 
EOF

        echo_blue_bold "clean cloud-init"
        ssh -t "${USER}@${IPADDR}" <<EOF
        sudo cloud-init clean
        cloud-init clean -l
        sudo shutdown -h now
EOF

        # Shutdown the guest
        govc vm.power -persist-session=false -s "${SEEDIMAGE}"

        echo_blue_bold "Wait ${SEEDIMAGE} to shutdown"
        while [ $(govc vm.info -json "${SEEDIMAGE}" | jq .virtualMachines[0].runtime.powerState | tr -d '"') == "poweredOn" ]
        do
            echo_blue_dot
            sleep 1
        done
        echo

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

cat > "${CACHE}/user-data" <<EOF
#cloud-config
EOF

cat > "${CACHE}/network.yaml" <<EOF
#cloud-config
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: true
EOF

cat > "${CACHE}/vendor-data" <<EOF
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

cat > "${CACHE}/meta-data" <<EOF
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
KUBERNETES_DISTRO=${KUBERNETES_DISTRO}
CREDENTIALS_CONFIG=$CREDENTIALS_CONFIG
CREDENTIALS_BIN=$CREDENTIALS_BIN
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF

cat ${CURDIR}/prepare-image.sh >> "${CACHE}/prepare-image.sh"

chmod +x "${CACHE}/prepare-image.sh"

gzip -c9 < "${CACHE}/meta-data" | base64 -w 0 > ${CACHE}/metadata.base64
gzip -c9 < "${CACHE}/user-data" | base64 -w 0 > ${CACHE}/userdata.base64
gzip -c9 < "${CACHE}/vendor-data" | base64 -w 0 > ${CACHE}/vendordata.base64

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

scp "${CACHE}/prepare-image.sh" "${USER}@${IPADDR}:~"

ssh -t "${USER}@${IPADDR}" sudo ./prepare-image.sh

govc vm.power -persist-session=false -s=true "${TARGET_IMAGE}"

echo_blue_dot_title "Wait ${TARGET_IMAGE} to shutdown"
while [ $(govc vm.info -json "${TARGET_IMAGE}" | jq .virtualMachines[0].runtime.powerState | tr -d '"') == "poweredOn" ]
do
    echo_blue_dot
    sleep 1
done
echo

echo_blue_bold "Created image ${TARGET_IMAGE} with kubernetes version ${KUBERNETES_VERSION}"

exit 0

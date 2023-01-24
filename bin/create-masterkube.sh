#/bin/bash

# This script create every thing to deploy a simple kubernetes autoscaled cluster with vmware.
# It will generate:
# Custom vmware image with every thing for kubernetes
# Config file to deploy the cluster autoscaler.
# kubectl run busybox --rm -ti --image=busybox -n kube-public /bin/sh

set -e

CURDIR=$(dirname $0)

pushd ${CURDIR}/../

export PATH=${PWD}/bin:${PATH}
export DISTRO=jammy
export SCHEME="vmware"
export NODEGROUP_NAME="vmware-ca-k8s"
export MASTERKUBE="${NODEGROUP_NAME}-masterkube"
export DASHBOARD_HOSTNAME=masterkube-vmware-dashboard
export SSH_PRIVATE_KEY="$HOME/.ssh/id_rsa"
export SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"
export KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
export KUBERNETES_USER=kubernetes
export KUBERNETES_PASSWORD=
export KUBECONFIG=$HOME/.kube/config
export SEED_ARCH=amd64
export SEED_USER=ubuntu
export SEED_IMAGE="${DISTRO}-server-cloudimg-seed"
export ROOT_IMG_NAME=${DISTRO}-kubernetes
export CNI_PLUGIN=flannel
export CNI_VERSION="v1.1.1"
export USE_ZEROSSL=YES
export USE_KEEPALIVED=NO
export HA_CLUSTER=false
export USE_K3S=false
export FIRSTNODE=0
export CONTROLNODES=1
export WORKERNODES=0
export MINNODES=0
export MAXNODES=9
export MAXTOTALNODES=$MAXNODES
export GRPC_PROVIDER=externalgrpc
export CORESTOTAL="0:16"
export MEMORYTOTAL="0:48"
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT="1"
export SCALEDOWNENABLED="true"
export SCALEDOWNDELAYAFTERADD="1m"
export SCALEDOWNDELAYAFTERDELETE="1m"
export SCALEDOWNDELAYAFTERFAILURE="1m"
export SCALEDOWNUNEEDEDTIME="1m"
export SCALEDOWNUNREADYTIME="1m"
export DEFAULT_MACHINE="medium"
export NGINX_MACHINE="tiny"
export CONTROL_PLANE_MACHINE="small"
export WORKER_NODE_MACHINE="medium"
export UNREMOVABLENODERECHECKTIMEOUT="1m"
export OSDISTRO=$(uname -s)
export TRANSPORT="tcp"
export NET_DOMAIN=home
export NET_IP=192.168.1.20
export NET_IF=eth1
export NET_GATEWAY=10.0.0.1
export NET_DNS=10.0.0.1
export NET_MASK=255.255.255.0
export NET_MASK_CIDR=24
export VC_NETWORK_PRIVATE="Private Network"
export VC_NETWORK_PUBLIC="Public Network"
export USE_DHCP_ROUTES_PRIVATE=true
export USE_DHCP_ROUTES_PUBLIC=true
export NETWORK_PUBLIC_ROUTES=()
export NETWORK_PRIVATE_ROUTES=()
export METALLB_IP_RANGE=10.0.0.100-10.0.0.127
export REGISTRY=fred78290
export LAUNCH_CA=YES
export PUBLIC_IP=DHCP
export SCALEDNODES_DHCP=true
export RESUME=NO
export CONTAINER_ENGINE=containerd
export EXTERNAL_ETCD=false
export TARGET_IMAGE="${ROOT_IMG_NAME}-cni-${CNI_PLUGIN}-${KUBERNETES_VERSION}-${SEED_ARCH}-${CONTAINER_ENGINE}"
export MAX_PODS=110
export SILENT="&> /dev/null"
export NFS_SERVER_ADDRESS=
export NFS_SERVER_PATH=
export NFS_STORAGE_CLASS=nfs-client
export CONFIGURATION_LOCATION=${PWD}
export SSL_LOCATION=${CONFIGURATION_LOCATION}/etc/ssl
export GOVCDEFS=${CONFIGURATION_LOCATION}/bin/govc.defs
export AWS_ROUTE53_PUBLIC_ZONE_ID=
export AWS_ROUTE53_ACCESSKEY=
export AWS_ROUTE53_SECRETKEY=

# defined in private govc.defs
export CERT_EMAIL=
export PUBLIC_DOMAIN_NAME=
export GOVC_DATACENTER=
export GOVC_DATASTORE=
export GOVC_FOLDER=
export GOVC_HOST=
export GOVC_INSECURE=
export GOVC_NETWORK=
export GOVC_USERNAME=
export GOVC_PASSWORD=
export GOVC_RESOURCE_POOL=
export GOVC_URL=
export GOVC_VIM_VERSION="6.0"
export GOVC_REGION=home
export GOVC_ZONE=office

# Sample machine definition
MACHINE_DEFS=$(cat ${PWD}/templates/machines.json)

SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
SCP_OPTIONS="${SSH_OPTIONS} -p -r"
DELETE_CLUSTER=NO

source $PWD/bin/common.sh

# import govc hidden definitions
if [ -f ${GOVCDEFS} ]; then
    source ${GOVCDEFS}
fi

function nextip()
{
    IP=$1
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | tr '.' ' '`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1\ /g'`)
    echo "$NEXT_IP"
}

function build_routes() {
    local ROUTES="[]"
    local ROUTE=

    for ROUTE in $@
    do
        local TO=
        local VIA=
        local METRIC=500

        IFS=, read -a DEFS <<<$ROUTE

        for DEF in ${DEFS[@]}
        do
            IFS== read KEY VALUE <<<$DEF
            case $KEY in
                to)
                    TO=$VALUE
                    ;;
                via)
                    VIA=$VALUE
                    ;;
                metric)
                    METRIC=$VALUE
                    ;;
            esac
        done

        if [ ! -z "$TO" ] && [ ! -z "$VIA" ]; then
            ROUTES=$(echo $ROUTES | jq --arg TO $TO --arg VIA $VIA --argjson METRIC $METRIC '. += [{ "to": $TO, "via": $VIA, "metric": $METRIC }]')
        fi
    done

    echo -n $ROUTES
}

function usage() {
cat <<EOF
$0 create a kubernetes simple cluster or HA cluster with 3 control planes
Options are:
--help | -h                                    # Display usage
--verbose | -v                                 # Verbose
--trace | -x                                   # Trace execution
--resume | -r                                  # Allow to resume interrupted creation of cluster kubernetes
--delete                                       # Delete cluster and exit
--distribution                                 # Ubuntu distribution to use ${DISTRO}
--create-image-only                            # Create image only

### Flags to set some location informations

--configuration-location                       # Specify where configuration will be stored, default ${CONFIGURATION_LOCATION}
--ssl-location                                 # Specify where the etc/ssl dir is stored, default ${SSL_LOCATION}
--govc-defs                                    # Override the GOVC definitions, default ${GOVCDEFS}

### Design domain

--public-domain                                # Specify the public domain to use, default ${PUBLIC_DOMAIN_NAME}
--dashboard-hostname                           # Specify the hostname for kubernetes dashboard, default ${DASHBOARD_HOSTNAME}

### Cert Manager

--cert-email=<value>                           # Specify the mail for lets encrypt, default ${CERT_EMAIL}
--use-zerossl                                  # Specify cert-manager to use zerossl, default ${USE_ZEROSSL}
--dont-use-zerossl                             # Specify cert-manager to use letsencrypt, default ${USE_ZEROSSL}
--zerossl-eab-kid=<value>                      # Specify zerossl eab kid, default ${ZEROSSL_EAB_KID}
--zerossl-eab-hmac-secret=<value>              # Specify zerossl eab hmac secret, default ${ZEROSSL_EAB_HMAC_SECRET}
--godaddy-key                                  # Specify godaddy api key
--godaddy-secret                               # Specify godaddy api secret

### Route53

--route53-zone-id                              # Specify the route53 zone id, default ${AWS_ROUTE53_PUBLIC_ZONE_ID}
--route53-access-key                           # Specify the route53 aws access key, default ${AWS_ROUTE53_ACCESSKEY}
--route53-secret-key                           # Specify the route53 aws secret key, default ${AWS_ROUTE53_SECRETKEY}

### Design the kubernetes cluster

--use-k3s                                      # Use k3s in place of kubeadm, default ${USE_K3S}
--ha-cluster | -c                              # Allow to create an HA cluster, default ${HA_CLUSTER}
--worker-nodes=<value>                         # Specify the number of worker node created in HA cluster, default $WORKERNODES
--container-runtime=<docker|containerd|cri-o>  # Specify which OCI runtime to use, default ${CONTAINER_ENGINE}
--max-pods                                     # Specify the max pods per created VM, default ${MAX_PODS}
--default-machine | -d=<value>                 # Override machine type used for auto scaling, default $DEFAULT_MACHINE
--nginx-machine                                # Override machine type used for nginx as ELB, default $NGINX_MACHINE
--control-plane-machine                        # Override machine type used for control plane, default $CONTROL_PLANE_MACHINE
--worker-node-machine                          # Override machine type used for worker node, default $WORKER_NODE_MACHINE
--ssh-private-key | -s=<value>                 # Override ssh key is used, default $SSH_PRIVATE_KEY
--transport | -t=<value>                       # Override the transport to be used between autoscaler and vmware-autoscaler, default $TRANSPORT
--node-group=<value>                           # Override the node group name, default $NODEGROUP_NAME
--cni-plugin=<value>                           # Override CNI plugin, default: ${CNI_PLUGIN}
--cni-version | -n=<value>                     # Override CNI plugin version, default: $CNI_VERSION
--kubernetes-version | -k=<value>              # Override the kubernetes version, default $KUBERNETES_VERSION

### Flags in ha mode only

--create-external-etcd | -e                    # Allow to create an external HA etcd cluster, default $EXTERNAL_ETCD
--use-keepalived | -u                          # Allow to use keepalived as load balancer else NGINX is used

### Flags to set the template vm

--target-image=<value>                         # Override the prefix template VM image used for created VM, default $ROOT_IMG_NAME
--seed-image=<value>                           # Override the seed image name used to create template, default $SEED_IMAGE
--seed-user=<value>                            # Override the seed user in template, default $SEED_USER
--password | -p=<value>                        # Override the password to ssh the cluster VM, default random word

### Flags to configure network in vsphere

--public-address=<value>                       # The public address to expose kubernetes endpoint, default $PUBLIC_IP
--no-dhcp-autoscaled-node                      # Autoscaled node don't use DHCP, default $SCALEDNODES_DHCP
--vm-private-network=<value>                   # Override the name of the private network in vsphere, default $VC_NETWORK_PRIVATE
--vm-public-network=<value>                    # Override the name of the public network in vsphere, default $VC_NETWORK_PUBLIC
--net-address=<value>                          # Override the IP of the kubernetes control plane node, default $NET_IP
--net-gateway=<value>                          # Override the IP gateway, default $NET_GATEWAY
--net-dns=<value>                              # Override the IP DNS, default $NET_DNS
--net-domain=<value>                           # Override the domain name, default $NET_DOMAIN
--metallb-ip-range                             # Override the metalb ip range, default $METALLB_IP_RANGE
--dont-use-dhcp-routes-private                 # Tell if we don't use DHCP routes in private network, default $USE_DHCP_ROUTES_PRIVATE
--dont-use-dhcp-routes-public                  # Tell if we don't use DHCP routes in public network, default $USE_DHCP_ROUTES_PUBLIC
--add-route-private                            # Add route to private network syntax is --add-route-private=to=X.X.X.X/YY,via=X.X.X.X,metric=100 --add-route-private=to=Y.Y.Y.Y/ZZ,via=X.X.X.X,metric=100, default ${NETWORK_PRIVATE_ROUTES[@]}
--add-route-public                             # Add route to public network syntax is --add-route-public=to=X.X.X.X/YY,via=X.X.X.X,metric=100 --add-route-public=to=Y.Y.Y.Y/ZZ,via=X.X.X.X,metric=100, default ${NETWORK_PUBLIC_ROUTES[@]}

### Flags to configure nfs client provisionner

--nfs-server-adress                            # The NFS server address, default $NFS_SERVER_ADDRESS
--nfs-server-mount                             # The NFS server mount path, default $NFS_SERVER_PATH
--nfs-storage-class                            # The storage class name to use, default $NFS_STORAGE_CLASS

### Flags for autoscaler
--cloudprovider=<value>                        # autoscaler flag <grpc|externalgrpc>, default: $GRPC_PROVIDER
--max-nodes-total=<value>                      # autoscaler flag, default: $MAXTOTALNODES
--cores-total=<value>                          # autoscaler flag, default: $CORESTOTAL
--memory-total=<value>                         # autoscaler flag, default: $MEMORYTOTAL
--max-autoprovisioned-node-group-count=<value> # autoscaler flag, default: $MAXAUTOPROVISIONNEDNODEGROUPCOUNT
--scale-down-enabled=<value>                   # autoscaler flag, default: $SCALEDOWNENABLED
--scale-down-delay-after-add=<value>           # autoscaler flag, default: $SCALEDOWNDELAYAFTERADD
--scale-down-delay-after-delete=<value>        # autoscaler flag, default: $SCALEDOWNDELAYAFTERDELETE
--scale-down-delay-after-failure=<value>       # autoscaler flag, default: $SCALEDOWNDELAYAFTERFAILURE
--scale-down-unneeded-time=<value>             # autoscaler flag, default: $SCALEDOWNUNEEDEDTIME
--scale-down-unready-time=<value>              # autoscaler flag, default: $SCALEDOWNUNREADYTIME
--unremovable-node-recheck-timeout=<value>     # autoscaler flag, default: $UNREMOVABLENODERECHECKTIMEOUT
EOF
}

TEMP=$(getopt -o xvheucrk:n:p:s:t: --long use-k3s,cloudprovider:,route53-zone-id:,route53-access-key:,route53-secret-key:,use-zerossl,dont-use-zerossl,zerossl-eab-kid:,zerossl-eab-hmac-secret:,godaddy-key:,godaddy-secret:,nfs-server-adress:,nfs-server-mount:,nfs-storage-class:,add-route-private:,add-route-public:,dont-use-dhcp-routes-private,dont-use-dhcp-routes-public,nginx-machine:,control-plane-machine:,worker-node-machine:,delete,configuration-location:,ssl-location:,cert-email:,public-domain:,dashboard-hostname:,create-image-only,no-dhcp-autoscaled-node,metallb-ip-range:,trace,container-runtime:,verbose,help,create-external-etcd,use-keepalived,govc-defs:,worker-nodes:,ha-cluster,public-address:,resume,node-group:,target-image:,seed-image:,seed-user:,vm-public-network:,vm-private-network:,net-address:,net-gateway:,net-dns:,net-domain:,transport:,ssh-private-key:,cni-version:,password:,kubernetes-version:,max-nodes-total:,cores-total:,memory-total:,max-autoprovisioned-node-group-count:,scale-down-enabled:,scale-down-delay-after-add:,scale-down-delay-after-delete:,scale-down-delay-after-failure:,scale-down-unneeded-time:,scale-down-unready-time:,unremovable-node-recheck-timeout: -n "$0" -- "$@")

eval set -- "$TEMP"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    --distribution)
        DISTRO=$2
        SEED_IMAGE="${DISTRO}-server-cloudimg-seed"
        ROOT_IMG_NAME=${DISTRO}-kubernetes
        shift 2
        ;;
    -v|--verbose)
        SILENT=
        shift 1
        ;;
    --no-dhcp-autoscaled-node)
        SCALEDNODES_DHCP=false
        shift 1
        ;;
    --public-address)
        PUBLIC_IP="$2"
        shift 2
        ;;
    --metallb-ip-range)
        METALLB_IP_RANGE="$2"
        shift 2
        ;;
    -x|--trace)
        set -x
        shift 1
        ;;
    -r|--resume)
        RESUME=YES
        shift 1
        ;;
    --delete)
        DELETE_CLUSTER=YES
        shift 1
        ;;
    --configuration-location)
        CONFIGURATION_LOCATION=$2
        mkdir -p ${CONFIGURATION_LOCATION}
        if [ ! -d ${CONFIGURATION_LOCATION} ]; then
            echo_red "kubernetes output : ${CONFIGURATION_LOCATION} not found"
            exit 1
        fi
        shift 2
        ;;
    --ssl-location)
        SSL_LOCATION=$2
        if [ ! -d ${SSL_LOCATION} ]; then
            echo_red "etc dir: ${SSL_LOCATION} not found"
            exit 1
        fi
        shift 2
        ;;
    --cert-email)
        CERT_EMAIL=$2
        shift 2
        ;;
    --use-zerossl)
        USE_ZEROSSL=YES
        shift 1
        ;;
    --dont-use-zerossl)
        USE_ZEROSSL=NO
        shift 1
        ;;
    --zerossl-eab-kid)
        ZEROSSL_EAB_KID=$2
        shift 2
        ;;
    --zerossl-eab-hmac-secret)
        ZEROSSL_EAB_HMAC_SECRET=$2
        shift 2
        ;;
    --godaddy-key)
        GODADDY_API_KEY=$2
        shift 2
        ;;
    --godaddy-secret)
        GODADDY_API_SECRET=$2
        shift 2
        ;;
    --route53-zone-id)
        AWS_ROUTE53_PUBLIC_ZONE_ID=$2
        shift 2
        ;;
    --route53-access-key)
        AWS_ROUTE53_ACCESSKEY=$2
        shift 2
        ;;
    --route53-secret-key)
        AWS_ROUTE53_SECRETKEY=$2
        shift 2
        ;;
    --dashboard-hostname)
        DASHBOARD_HOSTNAME=$2
        shift 2
        ;;
    --public-domain)
        PUBLIC_DOMAIN_NAME=$2
        shift 2
        ;;
    --govc-defs)
        GOVCDEFS=$2
        if [ -f ${GOVCDEFS} ]; then
            source ${GOVCDEFS}
        else
            echo_red "GOVC definitions: ${GOVCDEFS} not found"
            exit 1
        fi
        shift 2
        ;;
    --create-image-only)
        CREATE_IMAGE_ONLY=YES
        shift 1
        ;;
    --max-pods)
        MAX_PODS=$2
        shift 2
        ;;
    --use-k3s)
        USE_K3S=true
        shift 1
        ;;
    -c|--ha-cluster)
        HA_CLUSTER=true
        CONTROLNODES=3
        shift 1
        ;;
    -e|--create-external-etcd)
        EXTERNAL_ETCD=true
        shift 1
        ;;
    -u|--use-keepalived)
        USE_KEEPALIVED=YES
        shift 1
        ;;
    --node-group)
        NODEGROUP_NAME="$2"
        MASTERKUBE="${NODEGROUP_NAME}-masterkube"
        shift 2
        ;;

    --container-runtime)
        case "$2" in
            "docker"|"cri-o"|"containerd")
                CONTAINER_ENGINE="$2"
                ;;
            *)
                echo_red_bold "Unsupported container runtime: $2"
                exit 1
                ;;
        esac
        shift 2;;

    --target-image)
        ROOT_IMG_NAME="$2"
        shift 2
        ;;

    --seed-image)
        SEED_IMAGE="$2"
        shift 2
        ;;

    --seed-user)
        SEED_USER="$2"
        shift 2
        ;;

    --vm-private-network)
        VC_NETWORK_PRIVATE="$2"
        shift 2
        ;;

    --vm-public-network)
        VC_NETWORK_PUBLIC="$2"
        shift 2
        ;;

    --dont-use-dhcp-routes-private)
        USE_DHCP_ROUTES_PRIVATE=false
        shift 1
        ;;

    --dont-use-dhcp-routes-public)
        USE_DHCP_ROUTES_PUBLIC=false
        shift 2
        ;;

    --add-route-private)
        NETWORK_PRIVATE_ROUTES+=($2)
        shift 2
        ;;

    --add-route-public)
        NETWORK_PUBLIC_ROUTES+=($2)
        shift 2
        ;;

    --net-address)
        NET_IP="$2"
        shift 2
        ;;

    --net-gateway)
        NET_GATEWAY="$2"
        shift 2
        ;;

    --net-dns)
        NET_DNS="$2"
        shift 2
        ;;

    --net-domain)
        NET_DOMAIN="$2"
        shift 2
        ;;

    --nfs-server-adress)
        NFS_SERVER_ADDRESS="$2"
        shift 2
        ;;
    --nfs-server-mount)
        NFS_SERVER_PATH="$2"
        shift 2
        ;;
    --nfs-storage-class)
        NFS_STORAGE_CLASS="$2"
        shift 2
        ;;

    -d | --default-machine)
        DEFAULT_MACHINE="$2"
        shift 2
        ;;
    --nginx-machine)
        NGINX_MACHINE="$2"
        shift 2
        ;;
    --control-plane-machine)
        CONTROL_PLANE_MACHINE="$2"
        shift 2
        ;;
    --worker-node-machine)
        WORKER_NODE_MACHINE="$2"
        shift 2
        ;;
    -s | --ssh-private-key)
        SSH_PRIVATE_KEY=$2
        shift 2
        ;;
    --cni-plugin)
        CNI_PLUGIN="$2"
        shift 2
        ;;
    -n | --cni-version)
        CNI_VERSION="$2"
        shift 2
        ;;
    -p | --password)
        KUBERNETES_PASSWORD="$2"
        shift 2
        ;;
    -t | --transport)
        TRANSPORT="$2"
        shift 2
        ;;
    -k | --kubernetes-version)
        KUBERNETES_VERSION="$2"
        shift 2
        ;;
    --worker-nodes)
        WORKERNODES=$2
        shift 2
        ;;

    # Same argument as cluster-autoscaler
    --cloudprovider)
        GRPC_PROVIDER="$2"
        shift 2
        ;;
    --max-nodes-total)
        MAXTOTALNODES="$2"
        shift 2
        ;;
    --cores-total)
        CORESTOTAL="$2"
        shift 2
        ;;
    --memory-total)
        MEMORYTOTAL="$2"
        shift 2
        ;;
    --max-autoprovisioned-node-group-count)
        MAXAUTOPROVISIONNEDNODEGROUPCOUNT="$2"
        shift 2
        ;;
    --scale-down-enabled)
        SCALEDOWNENABLED="$2"
        shift 2
        ;;
    --scale-down-delay-after-add)
        SCALEDOWNDELAYAFTERADD="$2"
        shift 2
        ;;
    --scale-down-delay-after-delete)
        SCALEDOWNDELAYAFTERDELETE="$2"
        shift 2
        ;;
    --scale-down-delay-after-failure)
        SCALEDOWNDELAYAFTERFAILURE="$2"
        shift 2
        ;;
    --scale-down-unneeded-time)
        SCALEDOWNUNEEDEDTIME="$2"
        shift 2
        ;;
    --scale-down-unready-time)
        SCALEDOWNUNREADYTIME="$2"
        shift 2
        ;;
    --unremovable-node-recheck-timeout)
        UNREMOVABLENODERECHECKTIMEOUT="$2"
        shift 2
        ;;
    --)
        shift
        break
        ;;
    *)
        echo_red "$1 - Internal error!"
        exit 1
        ;;
    esac
done

if [ "${GRPC_PROVIDER}" != "grpc" ] && [ "${GRPC_PROVIDER}" != "externalgrpc" ]; then
    echo_red_bold "Unsupported cloud provider: ${GRPC_PROVIDER}, only grpc|externalgrpc, exit"
    exit
fi

if [ ${USE_K3S} ]; then
    K3S_CHANNEL=$(curl -s https://update.k3s.io/v1-release/channels)
    IFS=. read K8S_VERSION K8S_MAJOR K8S_MINOR <<< "${KUBERNETES_VERSION}"
    KUBERNETES_VERSION=$(curl -s https://update.k3s.io/v1-release/channels | jq -r --arg KUBERNETES_VERSION "${K8S_VERSION}.${K8S_MAJOR}" '.data[]|select(.id == $KUBERNETES_VERSION)|.latest')
fi

if [ ${USE_K3S} ]; then
    TARGET_IMAGE="${ROOT_IMG_NAME}-k3s-${KUBERNETES_VERSION}-${SEED_ARCH}"
else
    TARGET_IMAGE="${ROOT_IMG_NAME}-cni-${CNI_PLUGIN}-${KUBERNETES_VERSION}-${CONTAINER_ENGINE}-${SEED_ARCH}"
fi

export SSH_KEY_FNAME="$(basename $SSH_PRIVATE_KEY)"
export SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"

export TARGET_CONFIG_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/config
export TARGET_DEPLOY_LOCATION=${CONFIGURATION_LOCATION}/config/${NODEGROUP_NAME}/deployment
export TARGET_CLUSTER_LOCATION=${CONFIGURATION_LOCATION}/cluster/${NODEGROUP_NAME}

# Check if we can resume the creation process
if [ "${DELETE_CLUSTER}" = "YES" ]; then
    delete-masterkube.sh --configuration-location=${CONFIGURATION_LOCATION} --govc-defs=${GOVCDEFS} --node-group=${NODEGROUP_NAME}
    exit
elif [ ! -f ${TARGET_CONFIG_LOCATION}/buildenv ] && [ "$RESUME" = "YES" ]; then
    echo_red "Unable to resume, building env is not found"
    exit -1
fi

# Check if ssh private key exists
if [ ! -f $SSH_PRIVATE_KEY ]; then
    echo_red "The private ssh key: $SSH_PRIVATE_KEY is not found"
    exit -1
fi

# Check if ssh public key exists
if [ ! -f $SSH_PUBLIC_KEY ]; then
    echo_red "The private ssh key: $SSH_PUBLIC_KEY is not found"
    exit -1
fi

# Check variables coherence
if [ "$HA_CLUSTER" = "true" ]; then
    if [ $USE_KEEPALIVED = "YES" ]; then
        FIRSTNODE=1
    fi
else
    USE_KEEPALIVED=NO
    EXTERNAL_ETCD=false
fi

# Check if passord is defined
if [ -z $KUBERNETES_PASSWORD ]; then
    if [ -f ~/.kubernetes_pwd ]; then
        KUBERNETES_PASSWORD=$(cat ~/.kubernetes_pwd)
    else
        KUBERNETES_PASSWORD=$(uuidgen)
        echo $n "$KUBERNETES_PASSWORD" > ~/.kubernetes_pwd
    fi
fi

export SSH_KEY="$(cat ${SSH_PUBLIC_KEY})"

# GRPC network endpoint
if [ "$LAUNCH_CA" != "YES" ]; then
    SSH_PRIVATE_KEY_LOCAL="$SSH_PRIVATE_KEY"

    if [ "${TRANSPORT}" == "unix" ]; then
        LISTEN="/var/run/cluster-autoscaler/vmware.sock"
        CONNECTTO="unix:/var/run/cluster-autoscaler/vmware.sock"
    elif [ "${TRANSPORT}" == "tcp" ]; then
        if [ "${OSDISTRO}" == "Linux" ]; then
            TRANSPORT_IF=$(ip route get 1 | awk '{print $5;exit}')
            IPADDR=$(ip addr show ${NETRANSPORT_IFT_IF} | grep -m 1 "inet\s" | tr '/' ' ' | awk '{print $2}')
        else
            TRANSPORT_IF=$(route get 1 | grep -m 1 interface | awk '{print $2}')
            IPADDR=$(ifconfig ${TRANSPORT_IF} | grep -m 1 "inet\s" | sed -n 1p | awk '{print $2}')
        fi

        LISTEN="${IPADDR}:5200"
        CONNECTTO="${IPADDR}:5200"
    else
        echo_red "Unknown transport: ${TRANSPORT}, should be unix or tcp"
        exit -1
    fi
else
    SSH_PRIVATE_KEY_LOCAL="/etc/ssh/id_rsa"
    TRANSPORT=unix
    LISTEN="/var/run/cluster-autoscaler/vmware.sock"
    CONNECTTO="unix:/var/run/cluster-autoscaler/vmware.sock"
fi

eval echo_grey "Transport set to:${TRANSPORT}, listen endpoint at ${LISTEN}" $SILENT

export PATH=$PWD/bin:$PATH

# If CERT doesn't exist, create one autosigned
if [ ! -f ${SSL_LOCATION}/privkey.pem ]; then
    if [ -z "${PUBLIC_DOMAIN_NAME}" ]; then
        echo_red_bold "Public domaine is not defined, unable to create auto signed cert, exit"
        exit 1
    fi

    echo_blue_bold "Create autosigned certificat for domain: ${PUBLIC_DOMAIN_NAME}"
    ${CURDIR}/create-cert.sh --domain ${PUBLIC_DOMAIN_NAME} --ssl-location ${SSL_LOCATION} --cert-email ${CERT_EMAIL}
fi

if [ ! -f ${SSL_LOCATION}/cert.pem ]; then
    echo_red "${SSL_LOCATION}/cert.pem not found, exit"
    exit 1
fi

if [ ! -f ${SSL_LOCATION}/fullchain.pem ]; then
    echo_red "${SSL_LOCATION}/fullchain.pem not found, exit"
    exit 1
fi

# If the VM template doesn't exists, build it from scrash
if [ -z "$(govc vm.info ${TARGET_IMAGE} 2>&1)" ]; then
    echo_title "Create vmware preconfigured image ${TARGET_IMAGE}"

    ./bin/create-image.sh \
        --use-k3s=${USE_K3S} \
        --aws-access-key=${AWS_ACCESSKEY} \
        --aws-secret-key=${AWS_SECRETKEY} \
        --password="${KUBERNETES_PASSWORD}" \
        --distribution="${DISTRO}" \
        --cni-version="${CNI_VERSION}" \
        --custom-image="${TARGET_IMAGE}" \
        --kubernetes-version="${KUBERNETES_VERSION}" \
        --container-runtime=${CONTAINER_ENGINE} \
        --arch="${SEED_ARCH}" \
        --seed="${SEED_IMAGE}-${SEED_ARCH}" \
        --user="${SEED_USER}" \
        --ssh-key="${SSH_KEY}" \
        --primary-network="${VC_NETWORK_PUBLIC}" \
        --second-network="${VC_NETWORK_PRIVATE}"
fi

if [ "${CREATE_IMAGE_ONLY}" = "YES" ]; then
    exit 0
fi

# Extract the domain name from CERT
export DOMAIN_NAME=$(openssl x509 -noout -subject -in ${SSL_LOCATION}/cert.pem -nameopt sep_multiline | grep 'CN=' | awk -F= '{print $2}' | sed -e 's/^[\s\t]*//')

# Delete previous exixting version
if [ "$RESUME" = "NO" ]; then
    echo_title "Launch custom ${MASTERKUBE} instance with ${TARGET_IMAGE}"
    delete-masterkube.sh --configuration-location=${CONFIGURATION_LOCATION} --govc-defs=${GOVCDEFS} --node-group=${NODEGROUP_NAME}
else
    echo_title "Resume custom ${MASTERKUBE} instance with ${TARGET_IMAGE}"
fi

mkdir -p ${TARGET_CONFIG_LOCATION}
mkdir -p ${TARGET_CLUSTER_LOCATION}

if [ "$RESUME" = "NO" ]; then
    cat ${GOVCDEFS} > ${TARGET_CONFIG_LOCATION}/buildenv
    cat > ${TARGET_CONFIG_LOCATION}/buildenv <<EOF
export TARGET_CONFIG_LOCATION=${TARGET_CONFIG_LOCATION}
export TARGET_DEPLOY_LOCATION=${TARGET_DEPLOY_LOCATION}
export TARGET_CLUSTER_LOCATION=${TARGET_CLUSTER_LOCATION}
export SSL_LOCATION=${SSL_LOCATION}
export PUBLIC_DOMAIN_NAME=${PUBLIC_DOMAIN_NAME}
export PUBLIC_IP="$PUBLIC_IP"
export SCHEME="$SCHEME"
export NODEGROUP_NAME="$NODEGROUP_NAME"
export MASTERKUBE="$MASTERKUBE"
export SSH_PRIVATE_KEY=$SSH_PRIVATE_KEY
export SSH_PUBLIC_KEY=$SSH_PUBLIC_KEY
export SSH_KEY="$SSH_KEY"
export SSH_KEY_FNAME=$SSH_KEY_FNAME
export KUBERNETES_VERSION=$KUBERNETES_VERSION
export KUBERNETES_USER=${KUBERNETES_USER}
export KUBERNETES_PASSWORD=$KUBERNETES_PASSWORD
export KUBECONFIG=$KUBECONFIG
export SEED_USER=$SEED_USER
export SEED_IMAGE="$SEED_IMAGE"
export ROOT_IMG_NAME=$ROOT_IMG_NAME
export TARGET_IMAGE=$TARGET_IMAGE
export CNI_PLUGIN=$CNI_PLUGIN
export CNI_VERSION=$CNI_VERSION
export HA_CLUSTER=$HA_CLUSTER
export CONTROLNODES=$CONTROLNODES
export WORKERNODES=$WORKERNODES
export MINNODES=$MINNODES
export MAXNODES=$MAXNODES
export MAXTOTALNODES=$MAXTOTALNODES
export CORESTOTAL="$CORESTOTAL"
export MEMORYTOTAL="$MEMORYTOTAL"
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT=$MAXAUTOPROVISIONNEDNODEGROUPCOUNT
export SCALEDOWNENABLED=$SCALEDOWNENABLED
export SCALEDOWNDELAYAFTERADD=$SCALEDOWNDELAYAFTERADD
export SCALEDOWNDELAYAFTERDELETE=$SCALEDOWNDELAYAFTERDELETE
export SCALEDOWNDELAYAFTERFAILURE=$SCALEDOWNDELAYAFTERFAILURE
export SCALEDOWNUNEEDEDTIME=$SCALEDOWNUNEEDEDTIME
export SCALEDOWNUNREADYTIME=$SCALEDOWNUNREADYTIME
export DEFAULT_MACHINE=$DEFAULT_MACHINE
export UNREMOVABLENODERECHECKTIMEOUT=$UNREMOVABLENODERECHECKTIMEOUT
export OSDISTRO=$OSDISTRO
export TRANSPORT=$TRANSPORT
export NET_DOMAIN=$NET_DOMAIN
export NET_IP=$NET_IP
export NET_GATEWAY=$NET_GATEWAY
export NET_DNS=$NET_DNS
export NET_MASK=$NET_MASK
export NET_MASK_CIDR=$NET_MASK_CIDR
export VC_NETWORK_PRIVATE=$VC_NETWORK_PRIVATE
export USE_DHCP_ROUTES_PRIVATE=$USE_DHCP_ROUTES_PRIVATE
export VC_NETWORK_PUBLIC=$VC_NETWORK_PUBLIC
export USE_DHCP_ROUTES_PUBLIC=$USE_DHCP_ROUTES_PUBLIC
export REGISTRY=$REGISTRY
export LAUNCH_CA=$LAUNCH_CA
export CLUSTER_LB=$CLUSTER_LB
export USE_KEEPALIVED=$USE_KEEPALIVED
export EXTERNAL_ETCD=$EXTERNAL_ETCD
export FIRSTNODE=$FIRSTNODE
export NFS_SERVER_ADDRESS=$NFS_SERVER_ADDRESS
export NFS_SERVER_PATH=$NFS_SERVER_PATH
export NFS_STORAGE_CLASS=$NFS_STORAGE_CLASS
export USE_ZEROSSL=${USE_ZEROSSL}
export ZEROSSL_EAB_KID=${ZEROSSL_EAB_KID}
export ZEROSSL_EAB_HMAC_SECRET=${ZEROSSL_EAB_HMAC_SECRET}
export GODADDY_API_KEY=${GODADDY_API_KEY}
export GODADDY_API_SECRET=${GODADDY_API_SECRET}
export AWS_ROUTE53_PUBLIC_ZONE_ID=${AWS_ROUTE53_PUBLIC_ZONE_ID}
export AWS_ROUTE53_ACCESSKEY=${AWS_ROUTE53_ACCESSKEY}
export AWS_ROUTE53_SECRETKEY=${AWS_ROUTE53_SECRETKEY}
export GRPC_PROVIDER=${GRPC_PROVIDER}
export USE_K3S=${USE_K3S}
EOF
else
    source ${TARGET_CONFIG_LOCATION}/buildenv
fi

echo "${KUBERNETES_PASSWORD}" >${TARGET_CONFIG_LOCATION}/kubernetes-password.txt

# Due to my vsphere center the folder name refer more path, so I need to precise the path instead
FOLDER_OPTIONS=
if [ "${GOVC_FOLDER}" ]; then
    if [ ! $(govc folder.info ${GOVC_FOLDER} | grep -m 1 Path | wc -l) -eq 1 ]; then
        FOLDER_OPTIONS="-folder=/${GOVC_DATACENTER}/vm/${GOVC_FOLDER}"
    fi
fi


# Cloud init vendor-data
cat >${TARGET_CONFIG_LOCATION}/vendordata.yaml <<EOF
#cloud-config
package_update: true
package_upgrade: true
timezone: ${TZ}
ssh_authorized_keys:
    - ${SSH_KEY}
users:
    - default
system_info:
    default_user:
        name: ${KUBERNETES_USER}
EOF

gzip -c9 <${TARGET_CONFIG_LOCATION}/vendordata.yaml | base64 -w 0 | tee > ${TARGET_CONFIG_LOCATION}/vendordata.base64

IPADDRS=()
NODE_IP=$NET_IP

if [ "$PUBLIC_IP" != "DHCP" ]; then
    IFS=/ read PUBLIC_NODE_IP PUBLIC_MASK_CIDR <<< $PUBLIC_IP
else
    PUBLIC_NODE_IP=DHCP
fi

# No external elb, use keep alived
if [[ $FIRSTNODE > 0 ]]; then
    sudo sed -i -e "/${MASTERKUBE}/d" /etc/hosts
    sudo bash -c "echo '${NODE_IP} ${MASTERKUBE} ${MASTERKUBE}.${DOMAIN_NAME}' >> /etc/hosts"

    IPADDRS+=($NODE_IP)
    NODE_IP=$(nextip $NODE_IP)

    if [ "$PUBLIC_IP" != "DHCP" ]; then
        PUBLIC_NODE_IP=$(nextip $PUBLIC_NODE_IP)
    fi
fi

if [ $HA_CLUSTER = "true" ]; then
    TOTALNODES=$((WORKERNODES + $CONTROLNODES))
else
    CONTROLNODES=0
    TOTALNODES=$WORKERNODES
fi

PUBLIC_ROUTES_DEFS=$(build_routes ${NETWORK_PUBLIC_ROUTES[@]})
PRIVATE_ROUTES_DEFS=$(build_routes ${NETWORK_PRIVATE_ROUTES[@]})

function create_vm() {
    local INDEX=$1
    local PUBLIC_NODE_IP=$2
    local NODE_IP=$3
    local MACHINE_TYPE=$CONTROL_PLANE_MACHINE
    local NODEINDEX=$INDEX
    local MASTERKUBE_NODE=
    local IPADDR=
    local VMHOST=
    local DISK_SIZE=
    local NUM_VCPUS=
    local MEMSIZE=

    if [ $NODEINDEX = 0 ]; then
        # node 0 is ELB on HA mode
        if [ $HA_CLUSTER = "true" ]; then
            MACHINE_TYPE=$NGINX_MACHINE
        fi

        MASTERKUBE_NODE="${MASTERKUBE}"
    elif [[ $NODEINDEX > $CONTROLNODES ]]; then
        NODEINDEX=$((INDEX - $CONTROLNODES))
        MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
        MACHINE_TYPE=$WORKER_NODE_MACHINE
    else
        MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
    fi

    if [ -z "$(govc vm.info ${MASTERKUBE_NODE} 2>&1)" ]; then
        if [ "$PUBLIC_NODE_IP" = "DHCP" ]; then
            NETWORK_DEFS=$(cat <<EOF
            {
                "instance-id": "$(uuidgen)",
                "local-hostname": "${MASTERKUBE_NODE}",
                "hostname": "${MASTERKUBE_NODE}.${NET_DOMAIN}",
                "network": {
                    "version": 2,
                    "ethernets": {
                        "eth0": {
                            "dhcp4": true,
                            "dhcp4-overrides": {
                                "use-routes": $USE_DHCP_ROUTES_PUBLIC
                            }
                        },
                        "eth1": {
                            "gateway4": "$NET_GATEWAY",
                            "addresses": [
                                "$NODE_IP/$NET_MASK_CIDR"
                            ]
                        }
                    }
                }
            }
EOF
)
        else
            NETWORK_DEFS=$(cat <<EOF
            {
                "instance-id": "$(uuidgen)",
                "local-hostname": "${MASTERKUBE_NODE}",
                "hostname": "${MASTERKUBE_NODE}.${NET_DOMAIN}",
                "network": {
                    "version": 2,
                    "ethernets": {
                        "eth0": {
                            "gateway4": "$NET_GATEWAY",
                            "addresses": [
                                "$PUBLIC_NODE_IP/$PUBLIC_MASK_CIDR"
                            ],
                            "nameservers": {
                                "addresses": [
                                    "$NET_DNS"
                                ]
                            }
                        },
                        "eth1": {
                            "addresses": [
                                "$NODE_IP/$NET_MASK_CIDR"
                            ]
                        }
                    }
                }
            }
EOF
)
        fi

        if [ ${#NETWORK_PUBLIC_ROUTES[@]} -gt 0 ]; then
            NETWORK_DEFS=$(echo ${NETWORK_DEFS} | jq --argjson ROUTES "$PUBLIC_ROUTES_DEFS" '.network.ethernets.eth0.routes = $ROUTES')
        fi

        if [ ${#NETWORK_PRIVATE_ROUTES[@]} -gt 0 ]; then
            NETWORK_DEFS=$(echo ${NETWORK_DEFS} | jq --argjson ROUTES "$PRIVATE_ROUTES_DEFS" '.network.ethernets.eth1.routes = $ROUTES')
        fi

        echo ${NETWORK_DEFS} | jq . > ${TARGET_CONFIG_LOCATION}/metadata-$INDEX.json

        # Cloud init meta-data
        echo ${NETWORK_DEFS} | yq -P - | tee > /dev/null > ${TARGET_CONFIG_LOCATION}/metadata-$INDEX.yaml

        # Cloud init user-data
        cat > ${TARGET_CONFIG_LOCATION}/userdata-${INDEX}.yaml <<EOF
#cloud-config
runcmd:
- 'echo 1 > /sys/block/sda/device/rescan'
- growpart /dev/sda 1
- resize2fs /dev/sda1
- echo "Create ${MASTERKUBE_NODE}" > /var/log/masterkube.log
EOF

        gzip -c9 <${TARGET_CONFIG_LOCATION}/metadata-${INDEX}.json | base64 -w 0 | tee > ${TARGET_CONFIG_LOCATION}/metadata-${INDEX}.base64
        gzip -c9 <${TARGET_CONFIG_LOCATION}/userdata-${INDEX}.yaml | base64 -w 0 | tee > ${TARGET_CONFIG_LOCATION}/userdata-${INDEX}.base64

        MACHINE_TYPE=$(echo $MACHINE_DEFS | jq --arg MACHINE $MACHINE_TYPE 'to_entries[]|select(.key == $MACHINE)|.value')
        DISK_SIZE=$(echo $MACHINE_TYPE | jq -r .disksize)
        NUM_VCPUS=$(echo $MACHINE_TYPE | jq -r .vcpus)
        MEMSIZE=$(echo $MACHINE_TYPE | jq -r .memsize)
        DISK_SIZE=$(echo "${DISK_SIZE} / 1024" | bc)

        echo_line
        echo_blue_bold "Clone ${TARGET_IMAGE} to ${MASTERKUBE_NODE} TARGET_IMAGE=${TARGET_IMAGE} MASTERKUBE_NODE=${MASTERKUBE_NODE} MEMSIZE=${MEMSIZE} NUM_VCPUS=${NUM_VCPUS} DISK_SIZE=${DISK_SIZE}G"
        echo_line

        # Clone my template
        govc vm.clone -link=false -on=false ${FOLDER_OPTIONS} -c=${NUM_VCPUS} -m=${MEMSIZE} -vm=${TARGET_IMAGE} ${MASTERKUBE_NODE} > /dev/null
        govc vm.disk.change ${FOLDER_OPTIONS} -vm ${MASTERKUBE_NODE} -size="${DISK_SIZE}G" > /dev/null

        echo_title "Set cloud-init settings for ${MASTERKUBE_NODE}"

        # Inject cloud-init elements
        eval govc vm.change -vm "${MASTERKUBE_NODE}" \
            -e guestinfo.metadata="$(cat ${TARGET_CONFIG_LOCATION}/metadata-${INDEX}.base64)" \
            -e guestinfo.metadata.encoding="gzip+base64" \
            -e guestinfo.userdata="$(cat ${TARGET_CONFIG_LOCATION}/userdata-${INDEX}.base64)" \
            -e guestinfo.userdata.encoding="gzip+base64" \
            -e guestinfo.vendordata="$(cat ${TARGET_CONFIG_LOCATION}/vendordata.base64)" \
            -e guestinfo.vendordata.encoding="gzip+base64" $SILENT

        echo_title "Power On ${MASTERKUBE_NODE}"

        eval govc vm.power -on "${MASTERKUBE_NODE}" $SILENT

        echo_title "Wait for IP from ${MASTERKUBE_NODE}"

        IPADDR=$(govc vm.ip -wait 5m "${MASTERKUBE_NODE}")
        VMHOST=$(govc vm.info "${MASTERKUBE_NODE}" | grep 'Host:' | awk '{print $2}')

        echo_title "Prepare ${MASTERKUBE_NODE} instance with IP:${IPADDR}"
        eval govc host.autostart.add -host="${VMHOST}" "${MASTERKUBE_NODE}" $SILENT
        eval scp ${SCP_OPTIONS} bin ${KUBERNETES_USER}@${IPADDR}:~ $SILENT
        eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} mkdir -p /home/${KUBERNETES_USER}/cluster $SILENT
        eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo cp /home/${KUBERNETES_USER}/bin/* /usr/local/bin $SILENT

        # Update /etc/hosts
        sudo sed -i -e "/${MASTERKUBE_NODE}/d" /etc/hosts
        sudo bash -c "echo '${NODE_IP} ${MASTERKUBE_NODE} ${MASTERKUBE_NODE}.${DOMAIN_NAME}' >> /etc/hosts"
    else
        echo_title "Already running ${MASTERKUBE_NODE} instance"
    fi

    #echo_separator
}

for INDEX in $(seq $FIRSTNODE $TOTALNODES)
do
    create_vm $INDEX $PUBLIC_NODE_IP $NODE_IP &

    IPADDRS+=($NODE_IP)

        # Reserve 2 ip for potentiel HA cluster
    if [[ "$HA_CLUSTER" == "false" ]] && [[ $INDEX = 0 ]]; then
        NODE_IP=$(nextip $NODE_IP)
        NODE_IP=$(nextip $NODE_IP)
        if [ "$PUBLIC_IP" != "DHCP" ]; then
            PUBLIC_NODE_IP=$(nextip $PUBLIC_NODE_IP)
            PUBLIC_NODE_IP=$(nextip $PUBLIC_NODE_IP)
        fi
    fi

    NODE_IP=$(nextip $NODE_IP)

    if [ "$PUBLIC_IP" != "DHCP" ]; then
        PUBLIC_NODE_IP=$(nextip $PUBLIC_NODE_IP)
    fi
done

wait_jobs_finish

CLUSTER_NODES=

if [ "$HA_CLUSTER" = "true" ]; then
    for INDEX in $(seq 1 $CONTROLNODES)
    do
        MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${INDEX}"
        IPADDR="${IPADDRS[$INDEX]}"
        NODE_DNS="${MASTERKUBE_NODE}.${DOMAIN_NAME}:${IPADDR}"

        if [ -z "$CLUSTER_NODES" ]; then
            CLUSTER_NODES="${NODE_DNS}"
        else
            CLUSTER_NODES="${CLUSTER_NODES},${NODE_DNS}"
        fi
    done

    echo "export CLUSTER_NODES=$CLUSTER_NODES" >> ${TARGET_CONFIG_LOCATION}/buildenv

    if [ "$EXTERNAL_ETCD" = "true" ]; then
        echo_title "Created etcd cluster: ${CLUSTER_NODES}"

        prepare-etcd.sh --node-group=${NODEGROUP_NAME} --cluster-nodes="${CLUSTER_NODES}"

        for INDEX in $(seq 1 $CONTROLNODES)
        do
            if [ ! -f ${TARGET_CONFIG_LOCATION}/etdc-0${INDEX}-prepared ]; then
                IPADDR="${IPADDRS[$INDEX]}"

                echo_title "Start etcd node: ${IPADDR}"
                
                eval scp ${SCP_OPTIONS} bin ${KUBERNETES_USER}@${IPADDR}:~ $SILENT
                eval scp ${SCP_OPTIONS} ${TARGET_CLUSTER_LOCATION}/* ${KUBERNETES_USER}@${IPADDR}:~/cluster ${SILENT}
                eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo cp /home/${KUBERNETES_USER}/bin/* /usr/local/bin $SILENT

                eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo install-etcd.sh --user=${KUBERNETES_USER} --cluster-nodes="${CLUSTER_NODES}" --node-index="$INDEX" $SILENT

                touch ${TARGET_CONFIG_LOCATION}/etdc-0${INDEX}-prepared
            fi
        done
    fi

    if [ "$USE_KEEPALIVED" = "YES" ]; then
        echo_title "Created keepalived cluster: ${CLUSTER_NODES}"

        for INDEX in $(seq 1 $CONTROLNODES)
        do
            if [ ! -f ${TARGET_CONFIG_LOCATION}/keepalived-0${INDEX}-prepared ]; then
                IPADDR="${IPADDRS[$INDEX]}"

                echo_title "Start keepalived node: ${IPADDR}"

                case "$INDEX" in
                    1)
                        KEEPALIVED_PEER1=${IPADDRS[2]}
                        KEEPALIVED_PEER2=${IPADDRS[3]}
                        KEEPALIVED_STATUS=MASTER
                        ;;
                    2)
                        KEEPALIVED_PEER1=${IPADDRS[1]}
                        KEEPALIVED_PEER2=${IPADDRS[3]}
                        KEEPALIVED_STATUS=BACKUP
                        ;;
                    3)
                        KEEPALIVED_PEER1=${IPADDRS[1]}
                        KEEPALIVED_PEER2=${IPADDRS[2]}
                        KEEPALIVED_STATUS=BACKUP
                        ;;
                esac

                eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo /usr/local/bin/install-keepalived.sh \
                    "${IPADDRS[0]}" \
                    "$KUBERNETES_PASSWORD" \
                    "$((80-INDEX))" \
                    ${IPADDRS[$INDEX]} \
                    ${KEEPALIVED_PEER1} \
                    ${KEEPALIVED_PEER2} \
                    ${KEEPALIVED_STATUS} $SILENT

                touch ${TARGET_CONFIG_LOCATION}/keepalived-0${INDEX}-prepared
            fi
        done
    fi
else
    IPADDR="${IPADDRS[0]}"
    IPRESERVED1=$(nextip $IPADDR)
    IPRESERVED2=$(nextip $IPRESERVED1)
    CLUSTER_NODES="${MASTERKUBE}.${DOMAIN_NAME}:${IPADDR},${NODEGROUP_NAME}-master-02.${DOMAIN_NAME}:${IPRESERVED1},${NODEGROUP_NAME}-master-03.${DOMAIN_NAME}:${IPRESERVED2}"

    echo "export CLUSTER_NODES=$CLUSTER_NODES" >> ${TARGET_CONFIG_LOCATION}/buildenv
fi

for INDEX in $(seq $FIRSTNODE $TOTALNODES)
do
    NODEINDEX=$INDEX
    if [ $NODEINDEX = 0 ]; then
        MASTERKUBE_NODE="${MASTERKUBE}"
    elif [[ $NODEINDEX > $CONTROLNODES ]]; then
        NODEINDEX=$((INDEX - $CONTROLNODES))
        MASTERKUBE_NODE="${NODEGROUP_NAME}-worker-0${NODEINDEX}"
    else
        MASTERKUBE_NODE="${NODEGROUP_NAME}-master-0${NODEINDEX}"
    fi

    if [ -f ${TARGET_CONFIG_LOCATION}/kubeadm-0${INDEX}-prepared ]; then
        echo_title "Already prepared VM $MASTERKUBE_NODE"
    else
        IPADDR="${IPADDRS[$INDEX]}"
        VMUUID=$(govc vm.info -json ${MASTERKUBE_NODE} | jq -r '.VirtualMachines[0].Config.Uuid//""')

        echo_title "Prepare VM ${MASTERKUBE_NODE}, UUID=${VMUUID} with IP:${IPADDR}"

        eval scp ${SCP_OPTIONS} bin ${KUBERNETES_USER}@${IPADDR}:~ $SILENT
        eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo cp /home/${KUBERNETES_USER}/bin/* /usr/local/bin $SILENT

        if [ $INDEX = 0 ]; then
            if [ "$HA_CLUSTER" = "true" ]; then
                echo_blue_bold "Start load balancer ${MASTERKUBE_NODE} instance"

                eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo install-load-balancer.sh \
                    --cluster-nodes="${CLUSTER_NODES}" \
                    --control-plane-endpoint=${MASTERKUBE}.${DOMAIN_NAME} \
                    --listen-ip=$NET_IP $SILENT
            else
                echo_blue_bold "Start kubernetes ${MASTERKUBE_NODE} single instance master node, kubernetes version=${KUBERNETES_VERSION}"

                eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo create-cluster.sh \
                    --use-k3s=${USE_K3S} \
                    --vm-uuid=${VMUUID} \
                    --csi-region=${GOVC_REGION} \
                    --csi-zone=${GOVC_ZONE} \
                    --max-pods=${MAX_PODS} \
                    --allow-deployment=${MASTER_NODE_ALLOW_DEPLOYMENT} \
                    --control-plane-endpoint="${MASTERKUBE}.${DOMAIN_NAME}:${IPADDRS[0]}" \
                    --container-runtime=${CONTAINER_ENGINE} \
                    --cert-extra-sans="${MASTERKUBE}.${DOMAIN_NAME}" \
                    --cluster-nodes="${CLUSTER_NODES}" \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} \
                    --cni=${CNI_PLUGIN} \
                    --net-if=$NET_IF \
                    --kubernetes-version="${KUBERNETES_VERSION}" $SILENT

                eval scp ${SCP_OPTIONS} ${KUBERNETES_USER}@${IPADDR}:/etc/cluster/* ${TARGET_CLUSTER_LOCATION}/ $SILENT
            fi
        else
            if [ "$HA_CLUSTER" = "true" ]; then
                NODEINDEX=$((INDEX-1))
            else
                NODEINDEX=$INDEX
            fi

            if [ $NODEINDEX = 0 ]; then
                echo_blue_bold "Start kubernetes ${MASTERKUBE_NODE} instance master node number ${INDEX}, kubernetes version=${KUBERNETES_VERSION}"

                ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo create-cluster.sh \
                    --use-k3s=${USE_K3S} \
                    --vm-uuid=${VMUUID} \
                    --csi-region=${GOVC_REGION} \
                    --csi-zone=${GOVC_ZONE} \
                    --max-pods=${MAX_PODS} \
                    --allow-deployment=${MASTER_NODE_ALLOW_DEPLOYMENT} \
                    --container-runtime=${CONTAINER_ENGINE} \
                    --use-external-etcd=${EXTERNAL_ETCD} \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} \
                    --load-balancer-ip=${IPADDRS[0]} \
                    --cluster-nodes="${CLUSTER_NODES}" \
                    --control-plane-endpoint="${MASTERKUBE}.${DOMAIN_NAME}:${IPADDRS[1]}" \
                    --ha-cluster=true \
                    --cni=${CNI_PLUGIN} \
                    --net-if=$NET_IF \
                    --kubernetes-version="${KUBERNETES_VERSION}" $SILENT

                eval scp ${SCP_OPTIONS} ${KUBERNETES_USER}@${IPADDR}:/etc/cluster/* ${TARGET_CLUSTER_LOCATION}/ $SILENT

                echo_blue_dot_title "Wait for ELB start on IP: ${IPADDRS[0]}"

                while :
                do
                    echo_blue_dot
                    curl -s -k "https://${IPADDRS[0]}:6443" &> /dev/null && break
                    sleep 1
                done
                echo

                echo -n ${IPADDRS[0]}:6443 > ${TARGET_CLUSTER_LOCATION}/manager-ip
            elif [[ $INDEX > $CONTROLNODES ]] || [ "$HA_CLUSTER" = "false" ]; then
                    echo_blue_bold "Join node ${MASTERKUBE_NODE} instance worker node, kubernetes version=${KUBERNETES_VERSION}"

                    eval scp ${SCP_OPTIONS} ${TARGET_CLUSTER_LOCATION}/* ${KUBERNETES_USER}@${IPADDR}:~/cluster $SILENT

                    eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo join-cluster.sh \
                        --use-k3s=${USE_K3S} \
                        --vm-uuid=${VMUUID} \
                        --csi-region=${GOVC_REGION} \
                        --csi-zone=${GOVC_ZONE} \
                        --use-external-etcd=${EXTERNAL_ETCD} \
                        --node-group=${NODEGROUP_NAME} \
                        --node-index=${NODEINDEX} \
                        --control-plane-endpoint="${MASTERKUBE}.${DOMAIN_NAME}:${IPADDRS[0]}" \
                        --net-if=$NET_IF \
                        --cluster-nodes="${CLUSTER_NODES}" $SILENT
            else
                echo_blue_bold "Join node ${MASTERKUBE_NODE} instance master node, kubernetes version=${KUBERNETES_VERSION}"

                eval scp ${SCP_OPTIONS} ${TARGET_CLUSTER_LOCATION}/* ${KUBERNETES_USER}@${IPADDR}:~/cluster $SILENT

                eval ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${IPADDR} sudo join-cluster.sh \
                    --use-k3s=${USE_K3S} \
                    --vm-uuid=${VMUUID} \
                    --csi-region=${GOVC_REGION} \
                    --csi-zone=${GOVC_ZONE} \
                    --allow-deployment=${MASTER_NODE_ALLOW_DEPLOYMENT} \
                    --use-external-etcd=${EXTERNAL_ETCD} \
                    --node-group=${NODEGROUP_NAME} \
                    --node-index=${NODEINDEX} \
                    --control-plane-endpoint="${MASTERKUBE}.${DOMAIN_NAME}:${IPADDRS[0]}" \
                    --cluster-nodes="${CLUSTER_NODES}" \
                    --net-if=$NET_IF \
                    --control-plane=true $SILENT
            fi
        fi

        echo $MASTERKUBE_NODE > ${TARGET_CONFIG_LOCATION}/kubeadm-0${INDEX}-prepared
    fi

    echo_separator
done

echo_blue_bold "create cluster done"

MASTER_IP=$(cat ${TARGET_CLUSTER_LOCATION}/manager-ip)
TOKEN=$(cat ${TARGET_CLUSTER_LOCATION}/token)
CACERT=$(cat ${TARGET_CLUSTER_LOCATION}/ca.cert)

kubectl create secret generic autoscaler-ssh-keys -n kube-system --from-file=id_rsa="${SSH_PRIVATE_KEY}" --from-file=id_rsa.pub="${SSH_PUBLIC_KEY}" --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

kubeconfig-merge.sh ${MASTERKUBE} ${TARGET_CLUSTER_LOCATION}/config

echo_title "Write vsphere autoscaler provider config"

if [ ${GRPC_PROVIDER} = "grpc" ]; then
    CLOUDPROVIDER_CONFIG=${TARGET_CONFIG_LOCATION}/grpc-config.json
    cat > ${CLOUDPROVIDER_CONFIG} <<EOF
    {
        "address": "$CONNECTTO",
        "secret": "vmware",
        "timeout": 300
    }
EOF
else
    CLOUDPROVIDER_CONFIG=${TARGET_CONFIG_LOCATION}/grpc-config.yaml
    echo "address: $CONNECTTO" > ${CLOUDPROVIDER_CONFIG}
fi

if [ "${GOVC_INSECURE}" == "1" ]; then
    INSECURE=true
else
    INSECURE=false
fi

# For vmware autoscaler
if [ "$EXTERNAL_ETCD" = "true" ]; then
    export EXTERNAL_ETCD_ARGS="--use-external-etcd"
    ETCD_DST_DIR="/etc/etcd/ssl"
else
    export EXTERNAL_ETCD_ARGS="--no-use-external-etcd"
    ETCD_DST_DIR="/etc/kubernetes/pki/etcd"
fi

AUTOSCALER_CONFIG=$(cat <<EOF
{
    "use-external-etcd": ${EXTERNAL_ETCD},
    "src-etcd-ssl-dir": "/etc/etcd/ssl",
    "dst-etcd-ssl-dir": "${ETCD_DST_DIR}",
    "kubernetes-pki-srcdir": "/etc/kubernetes/pki",
    "kubernetes-pki-dstdir": "/etc/kubernetes/pki",
    "network": "${TRANSPORT}",
    "listen": "${LISTEN}",
    "secret": "${SCHEME}",
    "minNode": ${MINNODES},
    "maxNode": ${MAXNODES},
    "maxNode-per-cycle": 2,
    "node-name-prefix": "autoscaled",
    "managed-name-prefix": "managed",
    "controlplane-name-prefix": "master",
    "nodePrice": 0.0,
    "podPrice": 0.0,
    "image": "${TARGET_IMAGE}",
    "optionals": {
        "pricing": false,
        "getAvailableMachineTypes": false,
        "newNodeGroup": false,
        "templateNodeInfo": false,
        "createNodeGroup": false,
        "deleteNodeGroup": false
    },
    "kubeadm": {
        "use-k3s": ${USE_K3S},
        "address": "${MASTER_IP}",
        "token": "${TOKEN}",
        "ca": "sha256:${CACERT}",
        "extras-args": [
            "--ignore-preflight-errors=All"
        ]
    },
    "default-machine": "${DEFAULT_MACHINE}",
    "machines": ${MACHINE_DEFS},
    "node-labels": [
        "topology.kubernetes.io/region=${GOVC_REGION}",
        "topology.kubernetes.io/zone=${GOVC_ZONE}",
        "topology.csi.vmware.com/k8s-region=${GOVC_REGION}",
        "topology.csi.vmware.com/k8s-zone=${GOVC_ZONE}"
    ],
    "cloud-init": {
        "package_update": false,
        "package_upgrade": false,
        "runcmd": [
            "echo 1 > /sys/block/sda/device/rescan",
            "growpart /dev/sda 1",
            "resize2fs /dev/sda1",
            "echo '${IPADDRS[0]} ${MASTERKUBE} ${MASTERKUBE}.${DOMAIN_NAME}' >> /etc/hosts"
        ]
    },
    "ssh-infos" : {
        "wait-ssh-ready-seconds": 180,
        "user": "${KUBERNETES_USER}",
        "ssh-private-key": "${SSH_PRIVATE_KEY_LOCAL}"
    },
    "vmware": {
        "${NODEGROUP_NAME}": {
            "url": "${GOVC_URL}",
            "uid": "${GOVC_USERNAME}",
            "password": "${GOVC_PASSWORD}",
            "insecure": ${INSECURE},
            "dc" : "${GOVC_DATACENTER}",
            "datastore": "${GOVC_DATASTORE}",
            "resource-pool": "${GOVC_RESOURCE_POOL}",
            "vmFolder": "${GOVC_FOLDER}",
            "timeout": 300,
            "template-name": "${TARGET_IMAGE}",
            "template": false,
            "linked": false,
            "customization": "${GOVC_CUSTOMIZATION}",
            "network": {
                "domain": "${NET_DOMAIN}",
                "dns": {
                    "search": [
                        "${NET_DOMAIN}"
                    ],
                    "nameserver": [
                        "${NET_DNS}"
                    ]
                },
                "interfaces": [
                    {
                        "primary": false,
                        "exists": true,
                        "network": "${VC_NETWORK_PUBLIC}",
                        "adapter": "vmxnet3",
                        "mac-address": "generate",
                        "nic": "eth0",
                        "dhcp": true,
                        "use-dhcp-routes": ${USE_DHCP_ROUTES_PUBLIC},
                        "routes": ${PUBLIC_ROUTES_DEFS}
                    },
                    {
                        "primary": true,
                        "exists": true,
                        "network": "${VC_NETWORK_PRIVATE}",
                        "adapter": "vmxnet3",
                        "mac-address": "generate",
                        "nic": "eth1",
                        "dhcp": ${SCALEDNODES_DHCP},
                        "use-dhcp-routes": ${USE_DHCP_ROUTES_PRIVATE},
                        "address": "${NODE_IP}",
                        "gateway": "${NET_GATEWAY}",
                        "netmask": "${NET_MASK}",
                        "routes": ${PRIVATE_ROUTES_DEFS}
                    }
                ]
            }
        }
    }
}
EOF
)

echo "$AUTOSCALER_CONFIG" | jq . > ${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json

# Recopy config file on master node
kubectl create configmap config-cluster-autoscaler --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n kube-system \
	--from-file ${CLOUDPROVIDER_CONFIG} \
	--from-file ${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json

kubectl create configmap kubernetes-pki --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n kube-system \
	--from-file ${TARGET_CLUSTER_LOCATION}/kubernetes/pki

if [ "${EXTERNAL_ETCD}" = "true" ]; then
    kubectl create secret generic etcd-ssl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n kube-system \
        --from-file ${TARGET_CLUSTER_LOCATION}/etcd/ssl
else
    kubectl create secret generic etcd-ssl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n kube-system \
        --from-file ${TARGET_CLUSTER_LOCATION}/kubernetes/pki/etcd
fi

exit

# Create Pods
echo_title "= Create VSphere CSI provisionner"
create-vsphere-provisionner.sh

echo_title "= Create MetalLB"
create-metallb.sh

echo_title "= Create CERT Manager"
create-cert-manager.sh

echo_title "= Create NFS provisionner"
create-nfs-provisionner.sh

echo_title "= Create Ingress Controller"
create-ingress-controller.sh

echo_title "= Create Kubernetes dashboard"
create-dashboard.sh

echo_title "= Create Kubernetes metric scraper"
create-metrics.sh

echo_title "= Create Sample hello"
create-helloworld.sh

echo_title "= Create External DNS"
create-external-dns.sh

if [ "$LAUNCH_CA" != "NO" ]; then
    create-autoscaler.sh $LAUNCH_CA
fi

NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

sudo sed -i -e "/masterkube-vmware/d" /etc/hosts
sudo bash -c "echo '${NGINX_IP} masterkube-vmware.${DOMAIN_NAME} ${DASHBOARD_HOSTNAME}.${DOMAIN_NAME}' >> /etc/hosts"

# Add cluster config in configmap
kubectl create configmap masterkube-config --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n kube-system \
	--from-file ${TARGET_CLUSTER_LOCATION}/ca.cert \
    --from-file ${TARGET_CLUSTER_LOCATION}/dashboard-token \
    --from-file ${TARGET_CLUSTER_LOCATION}/token


popd

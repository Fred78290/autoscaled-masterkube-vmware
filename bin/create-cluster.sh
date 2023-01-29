#!/bin/bash

set -e

NODEGROUP_NAME="vmware-ca-k8s"
CNI_PLUGIN=flannel
NET_IF=$(ip route get 1|awk '{print $5;exit}')
export KUBERNETES_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
CLUSTER_DIR=/etc/cluster
KUBEADM_CONFIG=/etc/kubernetes/kubeadm-config.yaml
HA_CLUSTER=false
CONTROL_PLANE_ENDPOINT=
CONTROL_PLANE_ENDPOINT_HOST=
CONTROL_PLANE_ENDPOINT_ADDR=
CLUSTER_NODES=()
MAX_PODS=110
TOKEN_TLL="0s"
APISERVER_ADVERTISE_PORT=6443
CLUSTER_DNS="10.96.0.10"
CERT_EXTRA_SANS=()
POD_NETWORK_CIDR="10.244.0.0/16"
SERVICE_NETWORK_CIDR="10.96.0.0/12"
LOAD_BALANCER_IP=
EXTERNAL_ETCD=false
NODEINDEX=0
CONTAINER_ENGINE=docker
CONTAINER_RUNTIME=docker
CONTAINER_CTL=/var/run/dockershim.sock
K8_OPTIONS="--ignore-preflight-errors=All --config=${KUBEADM_CONFIG}"
VMUUID=
CSI_REGION=home
CSI_ZONE=office
USE_K3S=false
ETCD_ENDPOINT=

if [ "$(uname -p)" == "aarch64" ];  then
	ARCH="arm64"
else
	ARCH="amd64"
fi

TEMP=$(getopt -o xm:g:r:i:c:n:k: --long etcd-endpoint:,use-k3s:,csi-region:,csi-zone:,vm-uuid:,allow-deployment:,max-pods:,trace:,container-runtime:,node-index:,use-external-etcd:,load-balancer-ip:,node-group:,cluster-nodes:,control-plane-endpoint:,ha-cluster:,net-if:,cert-extra-sans:,cni:,kubernetes-version: -n "$0" -- "$@")

eval set -- "${TEMP}"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -x|--trace)
        set -x
        shift 1
        ;;
    -m|--max-pods)
        MAX_PODS=$2
        shift 2
        ;;
    -g|--node-group)
        NODEGROUP_NAME="$2"
        shift 2
        ;;
    --vm-uuid)
        VMUUID=$2
        shift 2
        ;;
    --allow-deployment)
        MASTER_NODE_ALLOW_DEPLOYMENT=$2
        shift 2
        ;;
    --use-k3s)
        USE_K3S=$2
        shift 2
        ;;
    -r|--container-runtime)
        case "$2" in
            "docker")
                CONTAINER_ENGINE="docker"
                CONTAINER_RUNTIME=docker
                CONTAINER_CTL=/var/run/dockershim.sock
                ;;
            "containerd")
                CONTAINER_ENGINE="$2"
                CONTAINER_RUNTIME=remote
                CONTAINER_CTL=/var/run/containerd/containerd.sock
                ;;
            "cri-o")
                CONTAINER_ENGINE="$2"
                CONTAINER_RUNTIME=remote
                CONTAINER_CTL=/var/run/crio/crio.sock
                ;;
            *)
                echo "Unsupported container runtime: $2"
                exit 1
                ;;
        esac
        shift 2;;
    -i|--node-index)
        NODEINDEX="$2"
        shift 2
        ;;
    --cni)
        CNI_PLUGIN=$2
        shift 2
        ;;
    --ha-cluster)
        HA_CLUSTER=$2
        shift 2
        ;;
    --load-balancer-ip)
        LOAD_BALANCER_IP="$2"
        shift 2
        ;;
    -c|--control-plane-endpoint)
        CONTROL_PLANE_ENDPOINT="$2"
        IFS=: read CONTROL_PLANE_ENDPOINT_HOST CONTROL_PLANE_ENDPOINT_ADDR <<< $CONTROL_PLANE_ENDPOINT
        shift 2
        ;;
    -n|--cluster-nodes)
        IFS=, read -a CLUSTER_NODES<<<$2
        shift 2
        ;;
    -k|--kubernetes-version)
        KUBERNETES_VERSION="$2"
        shift 2
        ;;
    --net-if)
        NET_IF=$2
        shift 2
        ;;
    --cert-extra-sans)
        IFS=, read -a CERT_EXTRA_SANS<<<$2
        shift 2
        ;;

    --use-external-etcd)
        EXTERNAL_ETCD=$2
        shift 2
        ;;
    --etcd-endpoint)
        ETCD_ENDPOINT="$2"
        shift 2
        ;;

    --csi-region)
        CSI_REGION=$2
        shift 2
        ;;
    --csi-zone)
        CSI_ZONE=$2
        shift 2
        ;;
    --)
        shift
        break
        ;;

    *)
        echo "$1 - Internal error!"
        exit 1
        ;;
    esac
done

# Check if interface exists, else take inet default gateway
ifconfig $NET_IF &> /dev/null || NET_IF=$(ip route get 1|awk '{print $5;exit}')
APISERVER_ADVERTISE_ADDRESS=$(ip addr show $NET_IF | grep "inet\s" | tr '/' ' ' | awk '{print $2}')
APISERVER_ADVERTISE_ADDRESS=$(echo $APISERVER_ADVERTISE_ADDRESS | awk '{print $1}')

if [ -z "$LOAD_BALANCER_IP" ]; then
    LOAD_BALANCER_IP=$APISERVER_ADVERTISE_ADDRESS
fi

mkdir -p /etc/kubernetes
mkdir -p $CLUSTER_DIR/etcd

echo -n "$LOAD_BALANCER_IP:6443" > $CLUSTER_DIR/manager-ip

#sed -i "2i${APISERVER_ADVERTISE_ADDRESS} $(hostname) ${CONTROL_PLANE_ENDPOINT_HOST}" /etc/hosts
echo "${APISERVER_ADVERTISE_ADDRESS} $(hostname) ${CONTROL_PLANE_ENDPOINT_HOST}" >> /etc/hosts

if [ "$HA_CLUSTER" = "true" ]; then
    for CLUSTER_NODE in ${CLUSTER_NODES[*]}
    do
        IFS=: read HOST IP <<< $CLUSTER_NODE
        sed -i "/$HOST/d" /etc/hosts
        echo "${IP}   ${HOST} ${HOST%%.*}" >> /etc/hosts
    done
fi

if [ ${USE_K3S} == "true" ]; then
    ANNOTE_MASTER=true
    CERT_SANS="${LOAD_BALANCER_IP},${CONTROL_PLANE_ENDPOINT_HOST},${CONTROL_PLANE_ENDPOINT_HOST%%.*}"

    for CERT_EXTRA in ${CERT_EXTRA_SANS[*]} 
    do
        CERT_SANS="${CERT_SANS},${CERT_EXTRA}"
    done

    for CLUSTER_NODE in ${CLUSTER_NODES[*]}
    do
        IFS=: read HOST IP <<< $CLUSTER_NODE
        [ -n ${IP} ] && CERT_SANS="${CERT_SANS},${IP}"
        [ -n ${HOST} ] && CERT_SANS="${CERT_SANS},${HOST}"
        [ -n ${HOST} ] && CERT_SANS="${CERT_SANS},${HOST%%.*}"
    done

    echo "K3S_MODE=server" > /etc/default/k3s
    echo "K3S_ARGS='--kubelet-arg=provider-id=vsphere://${VMUUID} --node-name=${HOSTNAME} --advertise-address=${APISERVER_ADVERTISE_ADDRESS} --advertise-port=${APISERVER_ADVERTISE_PORT} --tls-san=${CERT_SANS}'" > /etc/systemd/system/k3s.service.env
    echo "K3S_DISABLE_ARGS='--disable-cloud-controller --disable=servicelb --disable=traefik --disable=metrics-server'" > /etc/systemd/system/k3s.disabled.env

    if [ "$HA_CLUSTER" = "true" ]; then
        if [ "${EXTERNAL_ETCD}" == "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
            echo "K3S_SERVER_ARGS='--datastore-endpoint=${ETCD_ENDPOINT} --datastore-cafile /etc/etcd/ssl/ca.pem --datastore-certfile /etc/etcd/ssl/etcd.pem --datastore-keyfile /etc/etcd/ssl/etcd-key.pem'" > /etc/systemd/system/k3s.server.env
        else
            echo "K3S_SERVER_ARGS=--cluster-init" > /etc/systemd/system/k3s.server.env
        fi
    fi

    echo -n "Start k3s service"

    systemctl enable k3s.service
    systemctl start k3s.service

    while [ ! -f /etc/rancher/k3s/k3s.yaml ];
    do
        echo -n "."
        sleep 1
    done

    echo

    mkdir -p $CLUSTER_DIR/kubernetes/pki

    mkdir -p $HOME/.kube
    cp -i /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    cp /etc/rancher/k3s/k3s.yaml $CLUSTER_DIR/config
    cp /var/lib/rancher/k3s/server/token $CLUSTER_DIR/token
    cp -r /var/lib/rancher/k3s/server/tls/* $CLUSTER_DIR/kubernetes/pki/

    openssl x509 -pubkey -in /var/lib/rancher/k3s/server/tls/server-ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //' | tr -d '\n' > $CLUSTER_DIR/ca.cert

    sed -i -e "s/127.0.0.1/${CONTROL_PLANE_ENDPOINT_HOST}/g" -e "s/default/k8s-${HOSTNAME}-admin@${NODEGROUP_NAME}/g" $CLUSTER_DIR/config

    rm -rf $CLUSTER_DIR/kubernetes/pki/temporary-certs

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    echo -n "Wait node ${HOSTNAME} to be ready"

    while [ -z "$(kubectl get no ${HOSTNAME} 2>/dev/null | grep -v NAME)" ];
    do
        echo -n "."
        sleep 1
    done

    echo

else
    case "$CNI_PLUGIN" in
        calico)
            SERVICE_NETWORK_CIDR="10.96.0.0/12"
            POD_NETWORK_CIDR="192.168.0.0/16"
            ;;

        flannel)
            SERVICE_NETWORK_CIDR="10.96.0.0/12"
            POD_NETWORK_CIDR="10.244.0.0/16"
            ;;

        weave|canal|kube|romana)
            SERVICE_NETWORK_CIDR="10.96.0.0/12"
            POD_NETWORK_CIDR="10.244.0.0/16"
            ;;

        *)
            echo "CNI $CNI_PLUGIN is not supported"
            exit -1
    esac

    IFS=. read VERSION MAJOR MINOR <<<$KUBERNETES_VERSION

    cat > ${KUBEADM_CONFIG} <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- groups:
- system:bootstrappers:kubeadm:default-node-token
token: $(kubeadm token generate)
ttl: ${TOKEN_TLL}
usages:
- signing
- authentication
localAPIEndpoint:
advertiseAddress: ${APISERVER_ADVERTISE_ADDRESS}
bindPort: ${APISERVER_ADVERTISE_PORT}
nodeRegistration:
criSocket: unix://${CONTAINER_CTL}
name: ${NODENAME}
taints:
- effect: NoSchedule
    key: node-role.kubernetes.io/master
- effect: NoSchedule
    key: node-role.kubernetes.io/control-plane
kubeletExtraArgs:
    cloud-provider: external
    container-runtime: ${CONTAINER_RUNTIME}
    container-runtime-endpoint: ${CONTAINER_CTL}
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
anonymous:
    enabled: false
webhook:
    cacheTTL: 0s
    enabled: true
x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
mode: Webhook
webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
clusterDNS:
- ${CLUSTER_DNS}
cgroupDriver: systemd
failSwapOn: false
hairpinMode: hairpin-veth
readOnlyPort: 10255
clusterDomain: cluster.local
cpuManagerReconcilePeriod: 0s
evictionPressureTransitionPeriod: 0s
fileCheckFrequency: 0s
healthzBindAddress: 127.0.0.1
healthzPort: 10248
httpCheckFrequency: 0s
imageMinimumGCAge: 0s
nodeStatusReportFrequency: 0s
nodeStatusUpdateFrequency: 0s
rotateCertificates: true
runtimeRequestTimeout: 0s
staticPodPath: /etc/kubernetes/manifests
streamingConnectionIdleTimeout: 0s
syncFrequency: 0s
volumeStatsAggPeriod: 0s
maxPods: ${MAX_PODS}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
certificatesDir: /etc/kubernetes/pki
clusterName: ${NODEGROUP_NAME}
imageRepository: k8s.gcr.io
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
dnsDomain: cluster.local
serviceSubnet: ${SERVICE_NETWORK_CIDR}
podSubnet: ${POD_NETWORK_CIDR}
scheduler: {}
controllerManager:
extraArgs:
    cloud-provider: external
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT_HOST}:${APISERVER_ADVERTISE_PORT}
dns:
imageRepository: k8s.gcr.io/coredns
imageTag: v1.9.3
apiServer:
extraArgs:
    cloud-provider: external
    authorization-mode: Node,RBAC
timeoutForControlPlane: 4m0s
certSANs:
- ${LOAD_BALANCER_IP}
- ${CONTROL_PLANE_ENDPOINT_HOST}
- ${CONTROL_PLANE_ENDPOINT_HOST%%.*}
EOF

    for CERT_EXTRA in ${CERT_EXTRA_SANS[*]} 
    do
        echo "  - $CERT_EXTRA" >> ${KUBEADM_CONFIG}
    done

    for CLUSTER_NODE in ${CLUSTER_NODES[*]}
    do
        IFS=: read HOST IP <<< $CLUSTER_NODE
        [ -z ${IP} ] || echo "  - ${IP}" >> ${KUBEADM_CONFIG}
        [ -z ${HOST} ] || echo "  - ${HOST}" >> ${KUBEADM_CONFIG}
        [ -z ${HOST} ] || echo "  - ${HOST%%.*}" >> ${KUBEADM_CONFIG}
    done

    # External ETCD
    if [ "$EXTERNAL_ETCD" = "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
        cat >> ${KUBEADM_CONFIG} <<EOF
etcd:
external:
    caFile: /etc/etcd/ssl/ca.pem
    certFile: /etc/etcd/ssl/etcd.pem
    keyFile: /etc/etcd/ssl/etcd-key.pem
    endpoints:
EOF

        for ENDPOINT in $(echo -n ${ETCD_ENDPOINT} | tr ',' ' ')
        do
            echo "    - ${ENDPOINT}" >> ${KUBEADM_CONFIG}
        done
    fi

    echo "Init K8 cluster with options:$K8_OPTIONS"

    cat ${KUBEADM_CONFIG}

    kubeadm init $K8_OPTIONS 2>&1

    echo "Retrieve token infos"

    openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //' | tr -d '\n' > $CLUSTER_DIR/ca.cert
    kubeadm token list 2>&1 | grep "authentication,signing" | awk '{print $1}'  | tr -d '\n' > $CLUSTER_DIR/token 

    echo "Get token:$(cat $CLUSTER_DIR/token)"
    echo "Get cacert:$(cat $CLUSTER_DIR/ca.cert)"
    echo "Set local K8 environement"

    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config

    cp /etc/kubernetes/admin.conf $CLUSTER_DIR/config

    export KUBECONFIG=/etc/kubernetes/admin.conf

    mkdir -p $CLUSTER_DIR/kubernetes/pki

    cp /etc/kubernetes/pki/ca.crt $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/ca.key $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/sa.key $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/sa.pub $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/front-proxy-ca.crt $CLUSTER_DIR/kubernetes/pki
    cp /etc/kubernetes/pki/front-proxy-ca.key $CLUSTER_DIR/kubernetes/pki

    if [ "$EXTERNAL_ETCD" != "true" ]; then
        mkdir -p $CLUSTER_DIR/kubernetes/pki/etcd
        cp /etc/kubernetes/pki/etcd/ca.crt $CLUSTER_DIR/kubernetes/pki/etcd/ca.crt
        cp /etc/kubernetes/pki/etcd/ca.key $CLUSTER_DIR/kubernetes/pki/etcd/ca.key
    fi

    if [ "$CNI_PLUGIN" = "calico" ]; then

        echo "Install calico network"

        kubectl apply -f "https://docs.projectcalico.org/manifests/calico-vxlan.yaml" 2>&1

    elif [ "$CNI_PLUGIN" = "flannel" ]; then

        echo "Install flannel network"

        kubectl apply -f "https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" 2>&1

    elif [ "$CNI_PLUGIN" = "weave" ]; then

        echo "Install weave network for K8"

        kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" 2>&1

    elif [ "$CNI_PLUGIN" = "canal" ]; then

        echo "Install canal network"

        kubectl apply -f "https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml" 2>&1
        kubectl apply -f "https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml" 2>&1

    elif [ "$CNI_PLUGIN" = "kube" ]; then

        echo "Install kube network"

        kubectl apply -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml" 2>&1
        kubectl apply -f "https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter-all-features.yaml" 2>&1

    elif [ "$CNI_PLUGIN" = "romana" ]; then

        echo "Install romana network"

        kubectl apply -f https://raw.githubusercontent.com/romana/romana/master/containerize/specs/romana-kubeadm.yml 2>&1

    fi

    cat > patch.yaml <<EOF
spec:
    providerID: 'vsphere://${VMUUID}'
EOF

    kubectl patch node ${HOSTNAME} --patch-file patch.yaml
fi

chmod -R uog+r $CLUSTER_DIR/*

kubectl label nodes ${HOSTNAME} \
    "node-role.kubernetes.io/master=${ANNOTE_MASTER}" \
    "topology.kubernetes.io/region=${CSI_REGION}" \
    "topology.kubernetes.io/zone=${CSI_ZONE}" \
    "topology.csi.vmware.com/k8s-region=${CSI_REGION}" \
    "topology.csi.vmware.com/k8s-zone=${CSI_ZONE}" \
    "master=true" --overwrite

kubectl annotate node ${HOSTNAME} \
    "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
    "cluster.autoscaler.nodegroup/node-index=${NODEINDEX}" \
    "cluster.autoscaler.nodegroup/instance-id=${VMUUID}" \
    "cluster.autoscaler.nodegroup/autoprovision=false" \
    "cluster-autoscaler.kubernetes.io/scale-down-disabled=true" \
    --overwrite

if [ "${MASTER_NODE_ALLOW_DEPLOYMENT}" = "YES" ];then
  kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule-
elif [ "${USE_K3S}" == "true" ]; then
  kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule node-role.kubernetes.io/control-plane:NoSchedule
fi

sed -i -e "/${CONTROL_PLANE_ENDPOINT%%.}/d" /etc/hosts

echo "Done k8s master node"

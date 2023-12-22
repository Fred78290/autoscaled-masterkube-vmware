#!/bin/bash
NODEGROUP_NAME="vmware-ca-k8s"
MASTERKUBE="${NODEGROUP_NAME}-masterkube"
CNI=flannel
CLUSTER_DIR=/etc/cluster
CONTROL_PLANE_ENDPOINT=
CONTROL_PLANE_ENDPOINT_HOST=
CONTROL_PLANE_ENDPOINT_ADDR=
CLUSTER_NODES=
CERT_SANS=
HA_CLUSTER=false
EXTERNAL_ETCD=NO
NODEINDEX=0
MASTER_NODE_ALLOW_DEPLOYMENT=NO
NET_IF=$(ip route get 1|awk '{print $5;exit}')
MAX_PODS=110

MASTER_IP=$(cat ./cluster/manager-ip)
TOKEN=$(cat ./cluster/token)
VMUUID=
CSI_REGION=home
CSI_ZONE=office
KUBERNETES_DISTRO=kubeadm
ETCD_ENDPOINT=
DELETE_CREDENTIALS_CONFIG=NO

TEMP=$(getopt -o i:g:c:n: --long tls-san:,delete-credentials-provider:,max-pods:,etcd-endpoint:,k8s-distribution:,csi-region:,csi-zone:,vm-uuid:,net-if:,allow-deployment:,join-master:,node-index:,use-external-etcd:,control-plane:,node-group:,cluster-nodes:,control-plane-endpoint: -n "$0" -- "$@")

eval set -- "${TEMP}"

# extract options and their arguments into variables.
while true; do
    case "$1" in
    -g|--node-group)
        NODEGROUP_NAME="$2"
        shift 2
        ;;
    -i|--node-index)
        NODEINDEX="$2"
        shift 2
        ;;
    -c|--control-plane-endpoint)
        CONTROL_PLANE_ENDPOINT="$2"
        IFS=: read CONTROL_PLANE_ENDPOINT_HOST CONTROL_PLANE_ENDPOINT_ADDR <<< "$CONTROL_PLANE_ENDPOINT"
        shift 2
        ;;
    --tls-san)
        CERT_SANS=$2
        shift 2
        ;;
    -n|--cluster-nodes)
        CLUSTER_NODES="$2"
        shift 2
        ;;
    --vm-uuid)
        VMUUID=$2
        shift 2
        ;;
    --control-plane)
        HA_CLUSTER=$2
        shift 2
        ;;
    --use-external-etcd)
        EXTERNAL_ETCD=$2
        shift 2
        ;;
    --max-pods)
        MAX_PODS="$2"
        shift 2
        ;;
    --etcd-endpoint)
        ETCD_ENDPOINT="$2"
        shift 2
        ;;
    --join-master)
        MASTER_IP=$2
        shift 2
        ;;
    --allow-deployment)
        MASTER_NODE_ALLOW_DEPLOYMENT=$2 
        shift 2
        ;;
    --net-if)
        NET_IF=$2
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
    --delete-credentials-provider)
        DELETE_CREDENTIALS_CONFIG=$2
        shift 2
        ;;
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

# Hack because k3s and rke2 1.28.4 don't set the good feature gates
if [ "${DELETE_CREDENTIALS_CONFIG}" == "YES" ]; then
    case "${KUBERNETES_DISTRO}" in
        k3s|rke2)
            rm -rf /var/lib/rancher/credentialprovider
            ;;
    esac
fi

ifconfig $NET_IF &> /dev/null || NET_IF=$(ip route get 1|awk '{print $5;exit}')
APISERVER_ADVERTISE_ADDRESS=$(ip addr show $NET_IF | grep "inet\s" | tr '/' ' ' | awk '{print $2}')
APISERVER_ADVERTISE_ADDRESS=$(echo $APISERVER_ADVERTISE_ADDRESS | awk '{print $1}')

sed -i "/$CONTROL_PLANE_ENDPOINT_HOST/d" /etc/hosts
echo "$CONTROL_PLANE_ENDPOINT_ADDR   $CONTROL_PLANE_ENDPOINT_HOST" >> /etc/hosts

for CLUSTER_NODE in $(echo -n $CLUSTER_NODES | tr ',' ' ')
do
    IFS=: read HOST IP <<< "$CLUSTER_NODE"
    sed -i "/$HOST/d" /etc/hosts
    echo "$IP   $HOST" >> /etc/hosts
done

mkdir -p /etc/kubernetes/pki/etcd

cp cluster/config /etc/kubernetes/admin.conf

export KUBECONFIG=/etc/kubernetes/admin.conf

if [ ${KUBERNETES_DISTRO} == "rke2" ]; then
    ANNOTE_MASTER=true
    RKE2_SERVICE=rke2-agent

    cat > /etc/rancher/rke2/config.yaml <<EOF
kubelet-arg:
  - cloud-provider=external
  - fail-swap-on=false
  - provider-id=vsphere://${VMUUID}
  - max-pods=${MAX_PODS}
node-name: ${HOSTNAME}
server: https://${MASTER_IP%%:*}:9345
advertise-address: ${APISERVER_ADVERTISE_ADDRESS}
token: ${TOKEN}
EOF

    if [ "$HA_CLUSTER" = "true" ]; then
        RKE2_SERVICE=rke2-server
    
        echo "disable-cloud-controller: true" >> /etc/rancher/rke2/config.yaml
        echo "cloud-provider-name: external" >> /etc/rancher/rke2/config.yaml
        echo "disable:" >> /etc/rancher/rke2/config.yaml
        echo "  - servicelb" >> /etc/rancher/rke2/config.yaml
        echo "  - rke2-ingress-nginx" >> /etc/rancher/rke2/config.yaml
        echo "  - rke2-metrics-server" >> /etc/rancher/rke2/config.yaml
        echo "tls-san:" >> /etc/rancher/rke2/config.yaml

        for CERT_SAN in $(echo -n ${CERT_SANS} | tr ',' ' ')
        do
            echo "  - ${CERT_SAN}" >> /etc/rancher/rke2/config.yaml
        done
    fi

    echo -n "Start ${RKE2_SERVICE} service"

    systemctl enable ${RKE2_SERVICE}.service
    systemctl start ${RKE2_SERVICE}.service

    echo -n "Wait node ${HOSTNAME} to be ready"

    while [ -z "$(kubectl get no ${HOSTNAME} 2>/dev/null | grep -v NAME)" ];
    do
        echo -n "."
        sleep 1
    done

    echo

elif [ ${KUBERNETES_DISTRO} == "k3s" ]; then
    ANNOTE_MASTER=true
    echo "K3S_ARGS='--kubelet-arg=provider-id=vsphere://${VMUUID} --kubelet-arg=max-pods=${MAX_PODS} --node-name=${HOSTNAME} --server=https://${MASTER_IP} --token=${TOKEN}'" > /etc/systemd/system/k3s.service.env

    if [ "$HA_CLUSTER" = "true" ]; then
        echo "K3S_MODE=server" > /etc/default/k3s
        echo "K3S_DISABLE_ARGS='--disable-cloud-controller --disable=servicelb --disable=traefik --disable=metrics-server'" > /etc/systemd/system/k3s.disabled.env

        if [ "${EXTERNAL_ETCD}" == "true" ] && [ -n "${ETCD_ENDPOINT}" ]; then
            echo "K3S_SERVER_ARGS='--datastore-endpoint=${ETCD_ENDPOINT} --datastore-cafile /etc/etcd/ssl/ca.pem --datastore-certfile /etc/etcd/ssl/etcd.pem --datastore-keyfile /etc/etcd/ssl/etcd-key.pem'" > /etc/systemd/system/k3s.server.env
        fi
    fi

    echo -n "Start k3s service"

    systemctl enable k3s.service
    systemctl start k3s.service

    echo -n "Wait node ${HOSTNAME} to be ready"

    while [ -z "$(kubectl get no ${HOSTNAME} 2>/dev/null | grep -v NAME)" ];
    do
        echo -n "."
        sleep 1
    done

    echo

else
    CACERT=$(cat ./cluster/ca.cert)

    if [ "$HA_CLUSTER" = "true" ]; then
        cp cluster/kubernetes/pki/ca.crt /etc/kubernetes/pki
        cp cluster/kubernetes/pki/ca.key /etc/kubernetes/pki
        cp cluster/kubernetes/pki/sa.key /etc/kubernetes/pki
        cp cluster/kubernetes/pki/sa.pub /etc/kubernetes/pki
        cp cluster/kubernetes/pki/front-proxy-ca.key /etc/kubernetes/pki
        cp cluster/kubernetes/pki/front-proxy-ca.crt /etc/kubernetes/pki

        chown -R root:root /etc/kubernetes/pki

        chmod 600 /etc/kubernetes/pki/ca.crt
        chmod 600 /etc/kubernetes/pki/ca.key
        chmod 600 /etc/kubernetes/pki/sa.key
        chmod 600 /etc/kubernetes/pki/sa.pub
        chmod 600 /etc/kubernetes/pki/front-proxy-ca.key
        chmod 600 /etc/kubernetes/pki/front-proxy-ca.crt

        if [ -f cluster/kubernetes/pki/etcd/ca.crt ]; then
            cp cluster/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd
            cp cluster/kubernetes/pki/etcd/ca.key /etc/kubernetes/pki/etcd

            chmod 600 /etc/kubernetes/pki/etcd/ca.crt
            chmod 600 /etc/kubernetes/pki/etcd/ca.key
        fi

        kubeadm join ${MASTER_IP} \
            --node-name "${HOSTNAME}" \
            --token "${TOKEN}" \
            --discovery-token-ca-cert-hash "sha256:${CACERT}" \
            --apiserver-advertise-address ${APISERVER_ADVERTISE_ADDRESS} \
            --control-plane
    else
        kubeadm join ${MASTER_IP} \
            --node-name "${HOSTNAME}" \
            --token "${TOKEN}" \
            --discovery-token-ca-cert-hash "sha256:${CACERT}" \
            --apiserver-advertise-address ${APISERVER_ADVERTISE_ADDRESS}
    fi
fi

if [ "${KUBERNETES_DISTRO}" == "kubeadm" ]; then
    cat > patch.yaml <<EOF
spec:
    providerID: 'vsphere://${VMUUID}'
EOF

    kubectl patch node ${HOSTNAME} --patch-file patch.yaml
fi

if [ "$HA_CLUSTER" = "true" ]; then
    kubectl label nodes ${HOSTNAME} \
        "node-role.kubernetes.io/master=${ANNOTE_MASTER}" \
        "topology.kubernetes.io/region=${CSI_REGION}" \
        "topology.kubernetes.io/zone=${CSI_ZONE}" \
        "topology.csi.vmware.com/k8s-region=${CSI_REGION}" \
        "topology.csi.vmware.com/k8s-zone=${CSI_ZONE}" \
        "master=true" \
        --overwrite

    if [ "${MASTER_NODE_ALLOW_DEPLOYMENT}" = "YES" ];then
        kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule- node-role.kubernetes.io/control-plane:NoSchedule-
    elif [ "${KUBERNETES_DISTRO}" == "k3s" ]; then
        kubectl taint node ${HOSTNAME} node-role.kubernetes.io/master:NoSchedule node-role.kubernetes.io/control-plane:NoSchedule
    fi
else
    kubectl label nodes ${HOSTNAME} \
        "node-role.kubernetes.io/worker=${ANNOTE_MASTER}" \
        "topology.kubernetes.io/region=${CSI_REGION}" \
        "topology.kubernetes.io/zone=${CSI_ZONE}" \
        "topology.csi.vmware.com/k8s-region=${CSI_REGION}" \
        "topology.csi.vmware.com/k8s-zone=${CSI_ZONE}" \
        "worker=true" \
        --overwrite
fi

kubectl annotate node ${HOSTNAME} \
    "cluster.autoscaler.nodegroup/name=${NODEGROUP_NAME}" \
    "cluster.autoscaler.nodegroup/node-index=${NODEINDEX}" \
    "cluster.autoscaler.nodegroup/autoprovision=false" \
    "cluster.autoscaler.nodegroup/instance-id=${VMUUID}" \
    "cluster-autoscaler.kubernetes.io/scale-down-disabled=true" \
    --overwrite

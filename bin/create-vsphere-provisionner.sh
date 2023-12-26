#!/bin/bash

# Following from: https://cloud-provider-vsphere.sigs.k8s.io/tutorials/kubernetes-on-vsphere-with-kubeadm.html
function echo_red_bold() {
    # echo message in blue and bold
    >&2 echo -e "\x1B[90m= $(date '+%Y-%m-%d %T') \x1B[31m\x1B[1m\x1B[31m$1\x1B[0m\x1B[39m"
}

CURDIR=$(dirname $0)

pushd $CURDIR/../ &>/dev/null

export KUBERNETES_TEMPLATE=./templates/vsphere-storage
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/vsphere-storage

if [ "${KUBERNETES_DISTRO}" == "k3s" ] || [ "${KUBERNETES_DISTRO}" == "rke2" ]; then
  ANNOTE_MASTER=true
fi

IFS=. read VERSION MAJOR MINOR <<<"${KUBERNETES_VERSION%%+*}"
VSPHERE_CLOUD_RELEASE="${VERSION}.${MAJOR}.0"

if [ "${VSPHERE_CLOUD_RELEASE}" == "v1.29.0" ]; then
  echo_red_bold "Temp hack, Kubernetes vSphere Cloud Provider ${VSPHERE_CLOUD_RELEASE} not yet released, use 1.28.0"
  VSPHERE_CLOUD_RELEASE="v1.28.0"
fi

if [ -z "$(govc role.ls CNS-DATASTORE | grep 'Datastore.FileManagement')" ]; then
    ROLES="CNS-DATASTORE:Datastore.FileManagement,System.Anonymous,System.Read,System.View
    CNS-HOST-CONFIG-STORAGE:Host.Config.Storage,System.Anonymous,System.Read,System.View
    CNS-VM:VirtualMachine.Config.AddExistingDisk,VirtualMachine.Config.AddRemoveDevice,System.Anonymous,System.Read,System.View
    CNS-SEARCH-AND-SPBM:Cns.Searchable,StorageProfile.View,System.Anonymous,System.Read,System.View"

    for ROLEDEF in $ROLES
    do
        IFS=: read ROLE PERMISSIONS <<<"$ROLEDEF"
        IFS=, read -a PERMS <<<"$PERMISSIONS"

        govc role.ls $ROLE > /dev/null 2>&1 && govc role.update $ROLE ${PERMS[@]} || govc role.create $ROLE ${PERMS[@]}
    done
fi

read -a VCENTER <<<"$(echo $GOVC_URL | awk -F/ '{print $3}' | tr '@' ' ')"
VCENTER=${VCENTER[${#VCENTER[@]} - 1]}

DATASTORE_URL=$(govc datastore.info -json | jq -r .datastores[0].info.url)

[ $HA_CLUSTER = "true" ] && REPLICAS=3 || REPLICAS=1

mkdir -p ${ETC_DIR}

#helm repo add vsphere-cpi https://kubernetes.github.io/cloud-provider-vsphere
#helm repo update

#helm upgrade --install vsphere-cpi vsphere-cpi/vsphere-cpi \
#  --namespace kube-system \
#  --set config.enabled=true \
#  --set config.vcenter=${VCENTER} \
#  --set config.username=$GOVC_USERNAME \
#  --set config.password=$GOVC_PASSWORD \
#  --set config.datacenter=$GOVC_DATACENTER

if [ -z "$(govc tags.category.ls | grep 'cns.vmware.topology-preferred-datastores')" ]; then
    govc tags.category.create -d "VMWare Topology" cns.vmware.topology-preferred-datastores
fi

if [ -z "$(govc tags.ls | grep $VCENTER)" ]; then
    govc tags.create -d "Topology $VCENTER" -c cns.vmware.topology-preferred-datastores $VCENTER
    govc tags.attach $VCENTER /${GOVC_DATACENTER}/datastore/${GOVC_DATASTORE}
fi

if [ -z "$(govc tags.category.ls | grep 'k8s-region')" ]; then
    govc tags.category.create -d "Kubernetes region" -t Datacenter k8s-region
fi

if [ -z "$(govc tags.ls | grep ${GOVC_REGION})" ]; then
    govc tags.create -c k8s-region ${GOVC_REGION}
    govc tags.attach -c k8s-region ${GOVC_REGION} /${GOVC_DATACENTER}
fi

if [ -z "$(govc tags.category.ls | grep 'k8s-zone')" ]; then
    govc tags.category.create -d "Kubernetes zone" k8s-zone
fi

if [ -z "$(govc tags.ls | grep ${GOVC_ZONE})" ]; then
    govc tags.create -c k8s-zone ${GOVC_ZONE}
    govc tags.attach -c k8s-zone ${GOVC_ZONE} /${GOVC_DATACENTER}/host/${GOVC_CLUSTER}
fi

cat > ${ETC_DIR}/vsphere-csi-storage-class.yaml <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: vsphere-csi-storage-class
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: csi.vsphere.vmware.com
reclaimPolicy: Delete
allowVolumeExpansion: true
parameters:
#  storagepolicyname: "vSAN Default Storage Policy"  #Optional Parameter
#  datastoreurl: "${DATASTORE_URL}"
  csi.storage.k8s.io/fstype: "xfs"
EOF

cat > ${ETC_DIR}/csi-vsphere.conf <<EOF
[Global]
cluster-id = "${NODEGROUP_NAME}"

[VirtualCenter "$VCENTER"]
insecure-flag = true
user = "$GOVC_USERNAME"
password = "$GOVC_PASSWORD"
port = 443
datacenters = "$GOVC_DATACENTER"

[Labels]
topology-categories = "k8s-region,k8s-zone"
EOF

cat > ${ETC_DIR}/vsphere.conf <<EOF
# Global properties in this section will be used for all specified vCenters unless overriden in VirtualCenter section.
global:
  port: 443
  # set insecureFlag to true if the vCenter uses a self-signed cert
  insecureFlag: true
  # settings for using k8s secret
  secretName: cpi-${NODEGROUP_NAME}-secret
  secretNamespace: kube-system

# vcenter section
vcenter:
  ${NODEGROUP_NAME}:
    server: $VCENTER
    username: $GOVC_USERNAME
    password: $GOVC_PASSWORD
    datacenters:
      - $GOVC_DATACENTER

# labels for regions and zones
labels:
  region: k8s-region
  zone: k8s-zone
EOF

cat > ${ETC_DIR}/cpi-${NODEGROUP_NAME}-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cpi-${NODEGROUP_NAME}-secret
  namespace: kube-system
stringData:
  $VCENTER.username: $GOVC_USERNAME
  $VCENTER.password: $GOVC_PASSWORD
EOF

sed -e "s/__REPLICAS__/$REPLICAS/g" -e "s/__ANNOTE_MASTER__/${ANNOTE_MASTER}/g" ${KUBERNETES_TEMPLATE}/vsphere-csi-driver.yaml > ${ETC_DIR}/vsphere-csi-driver.yaml
sed -e "s/__VSPHERE_CLOUD_RELEASE__/${VSPHERE_CLOUD_RELEASE}/g" -e "s/__ANNOTE_MASTER__/${ANNOTE_MASTER}/g" ${KUBERNETES_TEMPLATE}/vsphere-cloud-controller-manager-ds.yaml > ${ETC_DIR}/vsphere-cloud-controller-manager-ds.yaml

kubectl create ns vmware-system-csi --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f ${ETC_DIR}/cpi-${NODEGROUP_NAME}-secret.yaml

kubectl create configmap cloud-config -n=kube-system --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    --from-file=${ETC_DIR}/vsphere.conf | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    -f ${KUBERNETES_TEMPLATE}/cloud-controller-manager-roles.yaml

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    -f ${KUBERNETES_TEMPLATE}/cloud-controller-manager-role-bindings.yaml

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    -f ${ETC_DIR}/vsphere-cloud-controller-manager-ds.yaml

kubectl create secret generic vsphere-config-secret -n vmware-system-csi --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
  --from-file=${ETC_DIR}/csi-vsphere.conf | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f ${ETC_DIR}/vsphere-csi-driver.yaml

kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f ${ETC_DIR}/vsphere-csi-storage-class.yaml

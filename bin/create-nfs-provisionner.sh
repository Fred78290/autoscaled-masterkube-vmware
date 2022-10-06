#!/bin/bash
if [ -z "${NFS_SERVER_ADDRESS}" ] && [ -z "${NFS_SERVER_PATH}" ]; then
    echo "Ignore nfs provisionner"
else
    helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
    helm repo update

    helm upgrade -i --kubeconfig=${TARGET_CLUSTER_LOCATION}/config  -n kube-system \
        nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        --set storageClass.name=${NFS_STORAGE_CLASS} \
        --set storageClass.archiveOnDelete=false \
        --set storageClass.onDelete=true \
        --set nfs.server=${NFS_SERVER_ADDRESS} \
        --set nfs.path=${NFS_SERVER_PATH}
fi
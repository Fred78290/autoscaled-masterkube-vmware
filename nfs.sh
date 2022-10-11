#!/bin/bash

source /home/fboltz/Projects/autoscaled-masterkube-vmware/config/vmware-ca-k8s/config/buildenv

helm upgrade -i -n kube-system \
    nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set storageClass.name=${NFS_STORAGE_CLASS} \
    --set storageClass.archiveOnDelete=false \
    --set storageClass.onDelete=true \
    --set nfs.server=${NFS_SERVER_ADDRESS} \
    --set nfs.path=${NFS_SERVER_PATH}

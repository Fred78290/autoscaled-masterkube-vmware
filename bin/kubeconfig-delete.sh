#!/bin/sh

if [ "$#" -eq "2" ]; then
    kubectl config delete-context k8s-$1-admin@$2
    kubectl config delete-cluster $2
    kubectl config delete-user k8s-$1-admin
    kubectl config delete-user k8s-$1-admin@$2
else
    kubectl config delete-context k8s-$1-admin@k8s-$1
    kubectl config delete-cluster k8s-$1
    kubectl config delete-user k8s-$1-admin
    kubectl config delete-user k8s-$1-admin@k8s-$1
fi

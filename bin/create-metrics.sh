#!/bin/bash
CURDIR=$(dirname $0)

pushd $CURDIR/../ &>/dev/null

export K8NAMESPACE=kube-system
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/metrics-server
export KUBERNETES_TEMPLATE=./templates/metrics-server

mkdir -p $ETC_DIR

function deploy {
    echo "Create $ETC_DIR/$1.json"
    mkdir -p $(dirname $ETC_DIR/$1.json)
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . | tee $ETC_DIR/$1.json | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f $ETC_DIR/$1.json
}

deploy serviceaccount
deploy clusterrole
deploy clusterrolebinding
deploy rolebinding
deploy system-clusterrole
deploy system-clusterrolebinding
deploy apiservice
deploy deployment
deploy service

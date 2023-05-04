#!/bin/bash
CURDIR=$(dirname $0)

source $CURDIR/common.sh

echo_blue_bold "Deploy kubernetes dashboard"

# This file is intent to deploy dashboard inside the masterkube
CURDIR=$(dirname $0)

pushd $CURDIR/../ &>/dev/null

export K8NAMESPACE=kubernetes-dashboard
export ETC_DIR=${TARGET_DEPLOY_LOCATION}/dashboard
export KUBERNETES_TEMPLATE=./templates/dashboard
export SUBPATH_POD_NAME='$(POD_NAME)'
export REWRITE_TARGET='/$1'

mkdir -p $ETC_DIR

function deploy {
    echo "Create $ETC_DIR/$1.json"
echo $(eval "cat <<EOF
$(<$KUBERNETES_TEMPLATE/$1.json)
EOF") | jq . | tee $ETC_DIR/$1.json | kubectl apply -f $ETC_DIR/$1.json --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
}

deploy namespace
deploy serviceaccount
deploy service

kubectl create secret generic kubernetes-dashboard-certs -n $K8NAMESPACE --dry-run=client -o yaml \
    --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    --from-file=dashboard.key=${SSL_LOCATION}/privkey.pem \
    --from-file=dashboard.crt=${SSL_LOCATION}/fullchain.pem | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

deploy csrf
deploy keyholder
deploy settings

deploy role
deploy clusterrole
deploy rolebinding
deploy clusterrolebinding
deploy deployment
deploy ingress
deploy scrapersvc
deploy scraper

# Create the service account in the current namespace 
# (we assume default)
kubectl create serviceaccount my-dashboard-sa -n $K8NAMESPACE --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -
# Give that service account root on the cluster
kubectl create clusterrolebinding my-dashboard-sa --clusterrole=cluster-admin --serviceaccount=$K8NAMESPACE:my-dashboard-sa \
	--dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -
# Find the secret that was created to hold the token for the SA
kubectl get secrets -n $K8NAMESPACE --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
IFS=. read VERSION MAJOR MINOR <<< "$KUBERNETES_VERSION"

if [ $MAJOR -gt 23 ]; then
    DASHBOARD_TOKEN=$(kubectl create token my-dashboard-sa --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n $K8NAMESPACE --duration 86400h)
else
    DASHBOARD_TOKEN=$(kubectl --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n $K8NAMESPACE describe secret $(kubectl get secret -n $K8NAMESPACE --kubeconfig=${TARGET_CLUSTER_LOCATION}/config | awk '/^my-dashboard-sa-token-/{print $1}') | awk '$1=="token:"{print $2}')
fi

echo_blue_bold "Dashboard token:$DASHBOARD_TOKEN"

echo $DASHBOARD_TOKEN > ${TARGET_CLUSTER_LOCATION}/dashboard-token
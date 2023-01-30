#!/bin/bash
CURDIR=$(dirname $0)
KUBERNETES_MINOR_RELEASE=$(echo -n $KUBERNETES_VERSION | awk -F. '{ print $2 }')

source ${CURDIR}/common.sh

mkdir -p ${TARGET_DEPLOY_LOCATION}/rancher
pushd ${TARGET_DEPLOY_LOCATION}

export K8NAMESPACE=cattle-system

kubectl create ns ${K8NAMESPACE} --dry-run=client --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o yaml | kubectl apply -f -

if [ ${KUBERNETES_MINOR_RELEASE} -lt 26 ]; then
    REPO=rancher-latest/rancher

    helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
    helm repo update
else
    REPO=./rancher/

    curl -sL https://releases.rancher.com/server-charts/latest/rancher-2.7.2-rc1.tgz | tar zxvf -

    sed -i -e 's/1.26.0-0/1.26.9-0/' rancher/Chart.yaml
fi

cat > ${TARGET_DEPLOY_LOCATION}/rancher/rancher.yaml <<EOF
hostname: rancher-vmware.$DOMAIN_NAME
ingress:
    ingressClassName: nginx
    extraAnnotations:
        "cert-manager.io/cluster-issuer": cert-issuer-prod
        "external-dns.alpha.kubernetes.io/register": 'true'
    tls:
        source: secret
        secretName: tls-rancher-ingress
tls: ingress
replicas: 1
EOF

helm upgrade -i rancher "${REPO}" \
    --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
    --namespace ${K8NAMESPACE} \
    --values ${TARGET_DEPLOY_LOCATION}/rancher/rancher.yaml

echo_blue_dot_title "Wait Rancher bootstrap"

while [ -z ${BOOTSTRAP_SECRET} ];
do
    BOOTSTRAP_SECRET=$(kubectl get secret --namespace ${K8NAMESPACE} bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}' 2>/dev/null)
    sleep 1
    echo_blue_dot
done

echo

echo_title "Rancher setup URL"
echo_blue_bold "https://rancher-vmware.$DOMAIN_NAME/dashboard/?setup=${BOOTSTRAP_SECRET}"
echo_line
echo

popd
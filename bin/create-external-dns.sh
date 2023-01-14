#!/bin/bash
CURDIR=$(dirname $0)

pushd $CURDIR/../

export ETC_DIR=${TARGET_DEPLOY_LOCATION}/external-dns
export KUBERNETES_TEMPLATE=./templates/external-dns

mkdir -p $ETC_DIR

if [ ! -z "${AWS_ROUTE53_PUBLIC_ZONE_ID}" ]; then
    cat > ${ETC_DIR}/credentials <<EOF
[default]
aws_access_key_id =  $AWS_ROUTE53_ACCESSKEY 
aws_secret_access_key = $AWS_ROUTE53_SECRETKEY
EOF

    kubectl create ns external-dns --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

    kubectl create configmap config-external-dns --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n external-dns \
        "--from-literal=DOMAIN_NAME=$DOMAIN_NAME" \
        "--from-literal=AWS_REGION=$AWS_REGION"

    kubectl create secret generic aws-external-dns --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -n external-dns \
            --from-file ${ETC_DIR}/credentials

    [ "${DOMAIN_NAME}" = "${PRIVATE_DOMAIN_NAME}" ] && ZONE_TYPE=private || ZONE_TYPE=public

    sed -e "s/__ZONE_TYPE__/${ZONE_TYPE}/g" \
        -e "s/__AWS_REGION__/${AWS_REGION}/g" \
        -e "s/__DOMAIN_NAME__/${DOMAIN_NAME}/g" \
        $KUBERNETES_TEMPLATE/deploy-route53.yaml | tee $ETC_DIR/deploy.yaml | kubectl apply -f - --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

elif [ ! -z "${PUBLIC_DOMAIN_NAME}" ]; then

    sed -e "s/__DOMAIN_NAME__/$DOMAIN_NAME/g" \
        -e "s/__GODADDY_API_KEY__/$GODADDY_API_KEY/g" \
        -e "s/__GODADDY_API_SECRET__/$GODADDY_API_SECRET/g" \
        -e "s/__NODEGROUP_NAME__/$NODEGROUP_NAME/g" \
        $KUBERNETES_TEMPLATE/deploy-godaddy.yaml | tee $ETC_DIR/deploy.yaml | kubectl apply -f - --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

fi
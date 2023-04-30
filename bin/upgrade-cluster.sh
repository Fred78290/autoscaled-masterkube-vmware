#!/bin/bash
set -e

CURDIR=$(dirname $0)
SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
SCP_OPTIONS="${SSH_OPTIONS} -p -r"

pushd ${CURDIR}/../

source $PWD/bin/common.sh

if [ -f "${TARGET_CONFIG_LOCATION}/buildenv" ]; then
	source ${TARGET_CONFIG_LOCATION}/buildenv
else
    cat > ${TARGET_CONFIG_LOCATION}/buildenv <<EOF
export TARGET_CONFIG_LOCATION=${TARGET_CONFIG_LOCATION}
export TARGET_DEPLOY_LOCATION=${TARGET_DEPLOY_LOCATION}
export TARGET_CLUSTER_LOCATION=${TARGET_CLUSTER_LOCATION}
export SSL_LOCATION=${SSL_LOCATION}
export PUBLIC_DOMAIN_NAME=${PUBLIC_DOMAIN_NAME}
export PUBLIC_IP="$PUBLIC_IP"
export SCHEME="$SCHEME"
export NODEGROUP_NAME="$NODEGROUP_NAME"
export MASTERKUBE="$MASTERKUBE"
export SSH_PRIVATE_KEY=$SSH_PRIVATE_KEY
export SSH_PUBLIC_KEY=$SSH_PUBLIC_KEY
export SSH_KEY="$SSH_KEY"
export SSH_KEY_FNAME=$SSH_KEY_FNAME
export KUBERNETES_VERSION=$KUBERNETES_VERSION
export KUBERNETES_USER=${KUBERNETES_USER}
export KUBERNETES_PASSWORD=$KUBERNETES_PASSWORD
export KUBECONFIG=$KUBECONFIG
export SEED_USER=$SEED_USER
export SEED_IMAGE="$SEED_IMAGE"
export ROOT_IMG_NAME=$ROOT_IMG_NAME
export TARGET_IMAGE=$TARGET_IMAGE
export CNI_PLUGIN=$CNI_PLUGIN
export CNI_VERSION=$CNI_VERSION
export HA_CLUSTER=$HA_CLUSTER
export CONTROLNODES=$CONTROLNODES
export WORKERNODES=$WORKERNODES
export MINNODES=$MINNODES
export MAXNODES=$MAXNODES
export MAXTOTALNODES=$MAXTOTALNODES
export CORESTOTAL="$CORESTOTAL"
export MEMORYTOTAL="$MEMORYTOTAL"
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT=$MAXAUTOPROVISIONNEDNODEGROUPCOUNT
export SCALEDOWNENABLED=$SCALEDOWNENABLED
export SCALEDOWNDELAYAFTERADD=$SCALEDOWNDELAYAFTERADD
export SCALEDOWNDELAYAFTERDELETE=$SCALEDOWNDELAYAFTERDELETE
export SCALEDOWNDELAYAFTERFAILURE=$SCALEDOWNDELAYAFTERFAILURE
export SCALEDOWNUNEEDEDTIME=$SCALEDOWNUNEEDEDTIME
export SCALEDOWNUNREADYTIME=$SCALEDOWNUNREADYTIME
export DEFAULT_MACHINE=$DEFAULT_MACHINE
export UNREMOVABLENODERECHECKTIMEOUT=$UNREMOVABLENODERECHECKTIMEOUT
export OSDISTRO=$OSDISTRO
export TRANSPORT=$TRANSPORT
export NET_DOMAIN=$NET_DOMAIN
export NET_IP=$NET_IP
export NET_GATEWAY=$NET_GATEWAY
export NET_DNS=$NET_DNS
export NET_MASK=$NET_MASK
export NET_MASK_CIDR=$NET_MASK_CIDR
export VC_NETWORK_PRIVATE=$VC_NETWORK_PRIVATE
export USE_DHCP_ROUTES_PRIVATE=$USE_DHCP_ROUTES_PRIVATE
export VC_NETWORK_PUBLIC=$VC_NETWORK_PUBLIC
export USE_DHCP_ROUTES_PUBLIC=$USE_DHCP_ROUTES_PUBLIC
export REGISTRY=$REGISTRY
export LAUNCH_CA=$LAUNCH_CA
export USE_KEEPALIVED=$USE_KEEPALIVED
export EXTERNAL_ETCD=$EXTERNAL_ETCD
export FIRSTNODE=$FIRSTNODE
export NFS_SERVER_ADDRESS=$NFS_SERVER_ADDRESS
export NFS_SERVER_PATH=$NFS_SERVER_PATH
export NFS_STORAGE_CLASS=$NFS_STORAGE_CLASS
export USE_ZEROSSL=${USE_ZEROSSL}
export ZEROSSL_EAB_KID=${ZEROSSL_EAB_KID}
export ZEROSSL_EAB_HMAC_SECRET=${ZEROSSL_EAB_HMAC_SECRET}
export GODADDY_API_KEY=${GODADDY_API_KEY}
export GODADDY_API_SECRET=${GODADDY_API_SECRET}
export AWS_ROUTE53_PUBLIC_ZONE_ID=${AWS_ROUTE53_PUBLIC_ZONE_ID}
export AWS_ROUTE53_ACCESSKEY=${AWS_ROUTE53_ACCESSKEY}
export AWS_ROUTE53_SECRETKEY=${AWS_ROUTE53_SECRETKEY}
export GRPC_PROVIDER=${GRPC_PROVIDER}
export USE_K3S=${USE_K3S}
EOF
fi

if [ ! -f ${TARGET_CLUSTER_LOCATION}/config ]; then
	cp $HOME/.kube/config ${TARGET_CLUSTER_LOCATION}/config
fi

KUBECONFIG_CONTEXT=k8s-${MASTERKUBE}-admin@${NODEGROUP_NAME}

kubectl config get-contexts ${KUBECONFIG_CONTEXT} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config &>/dev/null || (echo_red_bold "Cluster ${KUBECONFIG_CONTEXT} not found in kubeconfig" ; exit 1)
kubectl config set-context ${KUBECONFIG_CONTEXT} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config &>/dev/null

USE_K3S="$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[0].metadata.labels."egress.k3s.io/cluster"//"false"')"

if [ ${USE_K3S} == true ]; then
	mkdir -p ${TARGET_CONFIG_LOCATION}/system-upgrade

	IFS=+ read KUBEVERSION TAILK3S <<< "${KUBERNETES_VERSION}"

	kubectl delete ns system-upgrade --kubeconfig=${TARGET_CLUSTER_LOCATION}/config &>/dev/null || true

	sed -e "s/__KUBEVERSION__/${KUBEVERSION}/g" templates/system-upgrade/system-upgrade-controller.yaml \
		| tee ${TARGET_CONFIG_LOCATION}/system-upgrade/system-upgrade-controller.yaml \
		| kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

	kubectl wait --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --namespace system-upgrade --for=condition=ready pod \
		--selector=upgrade.cattle.io/controller=system-upgrade-controller --timeout=240s

	sed -e "s/__KUBERNETES_VERSION__/${KUBERNETES_VERSION}/g" templates/system-upgrade/system-upgrade-plan.yaml \
		| tee ${TARGET_CONFIG_LOCATION}/system-upgrade/system-upgrade-plan.yaml \
		| kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

else

	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[].status.addresses[]|select(.type == "ExternalIP")|.address')

	for ADDR in $ADDRESSES
	do
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@$ADDR <<EOF
			SEED_ARCH=\$([ "\$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
			cd /usr/local/bin
			sudo curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/\${SEED_ARCH}/{kubeadm,kubectl,kube-proxy}
			sudo chmod +x /usr/local/bin/kube*
EOF
	done

	# Upgrade control plane
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[]|select(.metadata.labels.master == "true")|.status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in $ADDRESSES
	do
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@$ADDR <<EOF
			sudo kubeadm upgrade apply ${KUBERNETES_VERSION} --certificate-renewal=false
EOF
	done

	# Upgrade worker
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[]|select(.metadata.labels.worker == "true")|.status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in $ADDRESSES
	do
		sudo kubeadm upgrade node --certificate-renewal=false
	done

	#Upgrade kubelet
	NODES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json)
	COUNT=$(echo $NODES | jq '.items|length')

	for INDEX in $(seq 1 $COUNT)
	do
		NODE=$(echo $NODES | jq ".items[$((INDEX-1))]")
		NODENAME=$(echo $NODE | jq -r .name)
		ADDR=$(echo $NODE | jq -r '.status.addresses[]|select(.type == "ExternalIP")|.address')

		kubectl drain ${NODENAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --ignore-daemonsets

		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@$ADDR <<EOF
			SEED_ARCH=\$([ "\$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
			cd /usr/local/bin
			sudo curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/\${SEED_ARCH}/kubelet
			sudo chmod +x /usr/local/bin/kubelet
			sudo kubectl restart kubelet
EOF

		kubectl uncordon ${NODENAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --ignore-daemonsets
	done

fi

popd
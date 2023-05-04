#!/bin/bash
set -e

CURDIR=$(dirname $0)
SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
SCP_OPTIONS="${SSH_OPTIONS} -p -r"

KUBECONFIG_CONTEXT=k8s-${MASTERKUBE}-admin@${NODEGROUP_NAME}

mkdir -p ${TARGET_CONFIG_LOCATION}
mkdir -p ${TARGET_CLUSTER_LOCATION}

kubectl config get-contexts ${KUBECONFIG_CONTEXT} &>/dev/null || (echo_red_bold "Cluster ${KUBECONFIG_CONTEXT} not found in kubeconfig" ; exit 1)
kubectl config set-context ${KUBECONFIG_CONTEXT} &>/dev/null

pushd ${CURDIR}/../ &>/dev/null

source ${PWD}/bin/common.sh

# Keep directory location
KEEP_TARGET_CONFIG_LOCATION=${TARGET_CONFIG_LOCATION}
KEEP_TARGET_DEPLOY_LOCATION=${TARGET_DEPLOY_LOCATION}
KEEP_TARGET_CLUSTER_LOCATION=${TARGET_CLUSTER_LOCATION}
KEEP_SSL_LOCATION=${SSL_LOCATION}
KEEP_SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY}
KEEP_SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}
KEEP_TARGET_IMAGE=${TARGET_IMAGE}
KEEP_KUBERNETES_VERSION=${KUBERNETES_VERSION}

function extract_configmap() {
	local NAMESPACE=$2
	local NAME=$1
	local DSTDIR=$3

	local CONFIGMAP=$(kubectl get cm ${NAME} -n ${NAMESPACE} -o json)
	local FILES=$(echo ${CONFIGMAP} | jq -r '.data | keys_unsorted|.[]')
	local CONTENT=

	mkdir -p ${DSTDIR}
	pushd ${DSTDIR} &>/dev/null

	for FILE in ${FILES}
	do
		JQPATH='.data."'${FILE}'"'
		CONTENT=$(echo ${CONFIGMAP} | jq -r "${JQPATH}")
		echo -n "${CONTENT}" > ${FILE}
	done

	popd &>/dev/null
}

function extract_deployment() {
	local NAMESPACE=$1
	local CM=

	for CM in $(kubectl get cm -n ${NODEGROUP_NAME} -o json | jq -r '.items[]|.metadata.name')
	do
		extract_configmap ${CM} ${NODEGROUP_NAME} "${TARGET_CONFIG_LOCATION}/../deployment/${CM}"
	done
}

if [ ! -f "${TARGET_CONFIG_LOCATION}/buildenv" ]; then
	echo_title "Restore config files"

	extract_configmap kubernetes-pki kube-system ${TARGET_CLUSTER_LOCATION}/kubernetes/pki
	extract_configmap cluster ${NODEGROUP_NAME} ${TARGET_CLUSTER_LOCATION}
	extract_configmap config ${NODEGROUP_NAME} ${TARGET_CONFIG_LOCATION}
	extract_deployment ${NODEGROUP_NAME}
fi

if [ ! -f "${TARGET_CONFIG_LOCATION}/buildenv" ]; then
	echo_red_bold "${TARGET_CONFIG_LOCATION}/buildenv not found, exit"
	exit 1
fi

source ${TARGET_CONFIG_LOCATION}/buildenv

# Restore directory location
TARGET_CONFIG_LOCATION=${KEEP_TARGET_CONFIG_LOCATION}
TARGET_DEPLOY_LOCATION=${KEEP_TARGET_DEPLOY_LOCATION}
TARGET_CLUSTER_LOCATION=${KEEP_TARGET_CLUSTER_LOCATION}
SSL_LOCATION=${KEEP_SSL_LOCATION}
SSH_PRIVATE_KEY=${KEEP_SSH_PRIVATE_KEY}
SSH_PUBLIC_KEY=${KEEP_SSH_PUBLIC_KEY}
TARGET_IMAGE=${KEEP_TARGET_IMAGE}
KUBERNETES_VERSION=${KEEP_KUBERNETES_VERSION}

if [ ! -f ${TARGET_CLUSTER_LOCATION}/config ]; then
	cp ${HOME}/.kube/config ${TARGET_CLUSTER_LOCATION}/config
fi

cat ${GOVCDEFS} > ${TARGET_CONFIG_LOCATION}/buildenv

cat > ${TARGET_CONFIG_LOCATION}/buildenv <<EOF
export AWS_ROUTE53_ACCESSKEY=${AWS_ROUTE53_ACCESSKEY}
export AWS_ROUTE53_PUBLIC_ZONE_ID=${AWS_ROUTE53_PUBLIC_ZONE_ID}
export AWS_ROUTE53_SECRETKEY=${AWS_ROUTE53_SECRETKEY}
export CLOUDPROVIDER_CONFIG=${CLOUDPROVIDER_CONFIG}
export CNI_PLUGIN=${CNI_PLUGIN}
export CNI_VERSION=${CNI_VERSION}
export CONTROLNODES=${CONTROLNODES}
export CORESTOTAL="${CORESTOTAL}"
export DEFAULT_MACHINE=${DEFAULT_MACHINE}
export EXTERNAL_ETCD=${EXTERNAL_ETCD}
export FIRSTNODE=${FIRSTNODE}
export GODADDY_API_KEY=${GODADDY_API_KEY}
export GODADDY_API_SECRET=${GODADDY_API_SECRET}
export GRPC_PROVIDER=${GRPC_PROVIDER}
export HA_CLUSTER=${HA_CLUSTER}
export KUBECONFIG=${KUBECONFIG}
export KUBERNETES_PASSWORD=${KUBERNETES_PASSWORD}
export KUBERNETES_USER=${KUBERNETES_USER}
export KUBERNETES_VERSION=${KUBERNETES_VERSION}
export LAUNCH_CA=${LAUNCH_CA}
export MASTERKUBE="${MASTERKUBE}"
export MAXAUTOPROVISIONNEDNODEGROUPCOUNT=${MAXAUTOPROVISIONNEDNODEGROUPCOUNT}
export MAXNODES=${MAXNODES}
export MAXTOTALNODES=${MAXTOTALNODES}
export MEMORYTOTAL="${MEMORYTOTAL}"
export MINNODES=${MINNODES}
export NET_DNS=${NET_DNS}
export NET_DOMAIN=${NET_DOMAIN}
export NET_GATEWAY=${NET_GATEWAY}
export NET_IP=${NET_IP}
export NET_MASK_CIDR=${NET_MASK_CIDR}
export NET_MASK=${NET_MASK}
export NFS_SERVER_ADDRESS=${NFS_SERVER_ADDRESS}
export NFS_SERVER_PATH=${NFS_SERVER_PATH}
export NFS_STORAGE_CLASS=${NFS_STORAGE_CLASS}
export NODEGROUP_NAME="${NODEGROUP_NAME}"
export OSDISTRO=${OSDISTRO}
export PUBLIC_DOMAIN_NAME=${PUBLIC_DOMAIN_NAME}
export PUBLIC_IP="${PUBLIC_IP}"
export REGISTRY=${REGISTRY}
export ROOT_IMG_NAME=${ROOT_IMG_NAME}
export SCALEDOWNDELAYAFTERADD=${SCALEDOWNDELAYAFTERADD}
export SCALEDOWNDELAYAFTERDELETE=${SCALEDOWNDELAYAFTERDELETE}
export SCALEDOWNDELAYAFTERFAILURE=${SCALEDOWNDELAYAFTERFAILURE}
export SCALEDOWNENABLED=${SCALEDOWNENABLED}
export SCALEDOWNUNEEDEDTIME=${SCALEDOWNUNEEDEDTIME}
export SCALEDOWNUNREADYTIME=${SCALEDOWNUNREADYTIME}
export SCHEME="${SCHEME}"
export SEED_IMAGE="${SEED_IMAGE}"
export SEED_USER=${SEED_USER}
export SSH_KEY_FNAME=${SSH_KEY_FNAME}
export SSH_KEY="${SSH_KEY}"
export SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY}
export SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY}
export SSL_LOCATION=${SSL_LOCATION}
export TARGET_CLUSTER_LOCATION=${TARGET_CLUSTER_LOCATION}
export TARGET_CONFIG_LOCATION=${TARGET_CONFIG_LOCATION}
export TARGET_DEPLOY_LOCATION=${TARGET_DEPLOY_LOCATION}
export TARGET_IMAGE=${TARGET_IMAGE}
export TRANSPORT=${TRANSPORT}
export UNREMOVABLENODERECHECKTIMEOUT=${UNREMOVABLENODERECHECKTIMEOUT}
export USE_DHCP_ROUTES_PRIVATE=${USE_DHCP_ROUTES_PRIVATE}
export USE_DHCP_ROUTES_PUBLIC=${USE_DHCP_ROUTES_PUBLIC}
export USE_K3S=${USE_K3S}
export USE_KEEPALIVED=${USE_KEEPALIVED}
export USE_ZEROSSL=${USE_ZEROSSL}
export VC_NETWORK_PRIVATE=${VC_NETWORK_PRIVATE}
export VC_NETWORK_PUBLIC=${VC_NETWORK_PUBLIC}
export WORKERNODES=${WORKERNODES}
export ZEROSSL_EAB_HMAC_SECRET=${ZEROSSL_EAB_HMAC_SECRET}
export ZEROSSL_EAB_KID=${ZEROSSL_EAB_KID}
export CLUSTER_NODES=${CLUSTER_NODES}
EOF

VMWARE_AUTOSCALER_CONFIG=$(cat ${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json)

echo -n ${VMWARE_AUTOSCALER_CONFIG} | jq ".image = \"${TARGET_IMAGE}\" | .vmware.\"${NODEGROUP_NAME}\".\"template-name\" = \"${TARGET_IMAGE}\"" > ${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json

source ${PWD}/bin/create-deployment.sh

if [ "${KUBERNETES_VERSION}" == "$(kubectl version --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r .serverVersion.gitVersion)" ]; then
	echo_blue_bold "Same kubernetes version, upgrade not necessary"
	exit
fi

if [ "$LAUNCH_CA" == YES ]; then
	kubectl delete po -l k8s-app=cluster-autoscaler -n kube-system --kubeconfig=${TARGET_CLUSTER_LOCATION}/config
fi

if [ ${USE_K3S} == true ]; then
	mkdir -p ${TARGET_DEPLOY_LOCATION}/system-upgrade

	IFS=+ read KUBEVERSION TAILK3S <<< "${KUBERNETES_VERSION}"

	kubectl delete ns system-upgrade --kubeconfig=${TARGET_CLUSTER_LOCATION}/config &>/dev/null || true

	sed -e "s/__KUBEVERSION__/${KUBEVERSION}/g" templates/system-upgrade/system-upgrade-controller.yaml \
		| tee ${TARGET_DEPLOY_LOCATION}/system-upgrade/system-upgrade-controller.yaml \
		| kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

	kubectl wait --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --namespace system-upgrade --for=condition=ready pod \
		--selector=upgrade.cattle.io/controller=system-upgrade-controller --timeout=240s

	sed -e "s/__KUBERNETES_VERSION__/${KUBERNETES_VERSION}/g" templates/system-upgrade/system-upgrade-plan.yaml \
		| tee ${TARGET_DEPLOY_LOCATION}/system-upgrade/system-upgrade-plan.yaml \
		| kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

else
	IFS=. read VERSION MAJOR MINOR <<< "$KUBERNETES_VERSION"

	# Update tools
	echo_title "Update kubernetes binaries"
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[].status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in ${ADDRESSES}
	do
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
			SEED_ARCH=\$([ "\$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
			cd /usr/local/bin
			sudo curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/\${SEED_ARCH}/{kubeadm,kubectl,kube-proxy}
			sudo chmod +x /usr/local/bin/kube*
EOF
	done

	# Upgrade control plane
	echo_title "Update control plane nodes"
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[]|select(.metadata.labels.master == "true")|.status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in ${ADDRESSES}
	do
		echo_blue_bold "Update node: ${ADDR}"
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
			if [ ${MAJOR} -ge 27 ] && [ -f /etc/kubernetes/kubeadm-config.yaml ]; then
				sudo sed -i '/container-runtime:/d' /etc/kubernetes/kubeadm-config.yaml
			fi

			sudo kubeadm upgrade apply ${KUBERNETES_VERSION} --yes --certificate-renewal=false
EOF
	done

	# Upgrade worker
	echo_title "Update worker nodes"
	ADDRESSES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.items[]|select(.metadata.labels.worker == "true")|.status.addresses[]|select(.type == "ExternalIP")|.address')
	for ADDR in ${ADDRESSES}
	do
		echo_blue_bold "Update node: ${ADDR}"
		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
		sudo kubeadm upgrade node
EOF
	done

	# Upgrade kubelet
	echo_title "Update kubelet"
	NODES=$(kubectl get no --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json)
	COUNT=$(echo ${NODES} | jq '.items|length')

	for INDEX in $(seq 1 ${COUNT})
	do
		NODE=$(echo ${NODES} | jq ".items[$((INDEX-1))]")
		NODENAME=$(echo ${NODE} | jq -r .metadata.name)
		ADDR=$(echo ${NODE} | jq -r '.status.addresses[]|select(.type == "ExternalIP")|.address')

		echo_blue_bold "Update kubelet for node: ${NODENAME}"

		kubectl cordon ${NODENAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

		ssh ${SSH_OPTIONS} ${KUBERNETES_USER}@${ADDR} <<EOF
			if [ ${MAJOR} -ge 27 ] && [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
				sudo sed -i -E 's/--container-runtime=\w+//' /var/lib/kubelet/kubeadm-flags.env
			fi 

			SEED_ARCH=\$([ "\$(uname -m)" == "aarch64" ] && echo -n arm64 || echo -n amd64)
			sudo systemctl stop kubelet
			cd /usr/local/bin
			sudo curl -sL --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/\${SEED_ARCH}/kubelet
			sudo chmod +x /usr/local/bin/kubelet
			sudo systemctl start kubelet
EOF

		kubectl uncordon ${NODENAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config

		echo_blue_bold "Kubelet upgraded for node: ${NODENAME}"
	done

fi

popd &>/dev/null
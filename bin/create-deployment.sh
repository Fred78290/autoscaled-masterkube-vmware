# Recopy config file on master node
kubectl create configmap config-cluster-autoscaler -n kube-system --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
	--from-file ${TARGET_CONFIG_LOCATION}/${CLOUDPROVIDER_CONFIG} \
	--from-file ${TARGET_CONFIG_LOCATION}/kubernetes-vmware-autoscaler.json | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

kubectl create configmap kubernetes-pki -n kube-system --dry-run=client -o yaml \
	--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
	--from-file ${TARGET_CLUSTER_LOCATION}/kubernetes/pki | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

if [ "${EXTERNAL_ETCD}" = "true" ]; then
    kubectl create secret generic etcd-ssl -n kube-system --dry-run=client -o yaml \
		--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
        --from-file ${TARGET_CLUSTER_LOCATION}/etcd/ssl | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -
else
    kubectl create secret generic etcd-ssl -n kube-system --dry-run=client -o yaml \
		--kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
        --from-file ${TARGET_CLUSTER_LOCATION}/kubernetes/pki/etcd | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -
fi

# Create Pods
echo_title "Create VSphere CSI provisionner"
create-vsphere-provisionner.sh

echo_title "Create autoscaler"
create-autoscaler.sh $LAUNCH_CA
echo_title "Create MetalLB"
create-metallb.sh

echo_title "Create CERT Manager"
create-cert-manager.sh

echo_title "Create NFS provisionner"
create-nfs-provisionner.sh

echo_title "Create Ingress Controller"
create-ingress-controller.sh

echo_title "Create Kubernetes dashboard"
create-dashboard.sh

echo_title "Create Kubernetes metric scraper"
create-metrics.sh

echo_title "Create Rancher"
create-rancher.sh

echo_title "Create Sample hello"
create-helloworld.sh

echo_title "Create External DNS"
create-external-dns.sh

NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -o json | jq -r '.status.loadBalancer.ingress[0].ip//""')

sudo sed -i '' -e "/masterkube-vmware/d" /etc/hosts
sudo bash -c "echo '${NGINX_IP} masterkube-vmware.${DOMAIN_NAME} ${DASHBOARD_HOSTNAME}.${DOMAIN_NAME}' >> /etc/hosts"

echo_title "Save templates into cluster"

# Save template
kubectl create ns ${NODEGROUP_NAME} --kubeconfig=${TARGET_CLUSTER_LOCATION}/config --dry-run=client -o yaml | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

# Add cluster config in configmap
kubectl create configmap cluster -n ${NODEGROUP_NAME} --dry-run=client -o yaml \
    --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
	--from-file ${TARGET_CLUSTER_LOCATION}/ | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

kubectl create configmap config -n ${NODEGROUP_NAME} --dry-run=client -o yaml \
    --kubeconfig=${TARGET_CLUSTER_LOCATION}/config \
	--from-file ${TARGET_CONFIG_LOCATION} | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -

# Save deployment template
pushd ${TARGET_DEPLOY_LOCATION} &>/dev/null
	for DIR in $(ls -1 -d */ | tr -d '/')
	do
		kubectl create configmap ${DIR} -n ${NODEGROUP_NAME} --dry-run=client -o yaml \
			--kubeconfig=${TARGET_CLUSTER_LOCATION}/config --from-file ${DIR} | kubectl apply --kubeconfig=${TARGET_CLUSTER_LOCATION}/config -f -
	done
popd &>/dev/null

export GLOO_MESH_VERSION=2.0.0-beta9
export MGMT_CLUSTER=mgmt
export REMOTE_CLUSTER1=cloud
export REMOTE_CLUSTER2=eksa
export MGMT_CONTEXT=mgmt
export REMOTE_CONTEXT1=cloud
export REMOTE_CONTEXT2=eksa
export EKSA_CLUSTER_NAME=eksa

# create management cluster in eks
# eksctl create cluster --name=mgmt-cluster --tags eks-cluster=solocon --nodes=3 --region=us-west-1

# create workload cluster in eks
# eksctl create cluster --name=cloud --tags eks-cluster=solocon --nodes=4 --region=us-west-1

# check clusters
echo "\nkubeconfig contexts..."
kubectl config get-contexts
echo "\ndeployments on mgmt cluster..."
kubectl get deploy -A --context $MGMT_CONTEXT
echo "\ndeployments on cloud cluster..."
kubectl get deploy -A --context $REMOTE_CONTEXT1

# create eks-a cluster
# docs: https://anywhere.eks.amazonaws.com/docs/overview/
eksctl anywhere generate clusterconfig $EKSA_CLUSTER_NAME \
   --provider docker > $EKSA_CLUSTER_NAME.yaml
eksctl anywhere create cluster -f $EKSA_CLUSTER_NAME.yaml

## use kubeconfig file for eks-a
export KUBECONFIG=~/.kube/config:~/codebase/solocon/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig
kubectl config rename-context ${EKSA_CLUSTER_NAME}-admin@${EKSA_CLUSTER_NAME} $REMOTE_CONTEXT2

echo "\ndeployments on eks-a cluster..."
kubectl get deploy -A --context $REMOTE_CONTEXT2

# install istio on `eksa` and `cloud` cluster
export PATH="$PATH:~/istio/istio-1.12.3/bin"

cat istio-operator.yaml | CLUSTER_NAME=$REMOTE_CLUSTER1 envsubst | istioctl install -y --context $REMOTE_CONTEXT1 -f -
cat istio-operator-eksa.yaml | CLUSTER_NAME=$REMOTE_CLUSTER2 envsubst | istioctl install -y --context $REMOTE_CONTEXT2 -f -

echo "\nistio-system pods on cloud cluster..."
kubectl get po -n istio-system --context $REMOTE_CONTEXT1
echo "\nistio-system pods on eksa cluster..."
kubectl get po -n istio-system --context $REMOTE_CONTEXT2

# install ratings microservice only on 'cloud'
kubectl label namespace default istio-injection=enabled --context $REMOTE_CONTEXT1
kubectl apply -f ~/istio/istio-1.11.4/samples/bookinfo/platform/kube/bookinfo.yaml --context $REMOTE_CONTEXT1 -l 'account in (ratings)'
kubectl apply -f ~/istio/istio-1.11.4/samples/bookinfo/platform/kube/bookinfo.yaml --context $REMOTE_CONTEXT1 -l 'app in (ratings)'

# install all of bookinfo except ratings on 'eksa'
kubectl label namespace default istio-injection=enabled --context $REMOTE_CONTEXT2
kubectl apply -f ~/istio/istio-1.11.4/samples/bookinfo/platform/kube/bookinfo.yaml --context $REMOTE_CONTEXT2 -l 'app notin (ratings)'

echo "\ndefault namespace pods on cloud cluster..."
kubectl get po --context $REMOTE_CONTEXT1
echo "\ndefault namespace pods on eksa cluster..."
kubectl get po --context $REMOTE_CONTEXT2

# install management plane on mgmt cluster
helm install gloo-mesh-enterprise gloo-mesh-enterprise/gloo-mesh-enterprise \
  --namespace gloo-mesh \
  --set licenseKey=${GLOO_MESH_LICENSE_KEY} \
  --set global.mgmtServerClusterName=mgmt \
  --kube-context=${MGMT_CONTEXT} \
  --version ${GLOO_MESH_VERSION} \
  --create-namespace

echo "\ngloo-mesh pods on mgmt cluster (management-plane) ..."
kubectl get po -n gloo-mesh --context $MGMT_CONTEXT

# register workload clusters
kubectl apply --context=$MGMT_CONTEXT -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: $REMOTE_CLUSTER1
  namespace: gloo-mesh
  labels:
    env: test
spec:
  clusterDomain: cluster.local
EOF
kubectl apply --context=$MGMT_CONTEXT -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: $REMOTE_CLUSTER2
  namespace: gloo-mesh
  labels:
    env: test
spec:
  clusterDomain: cluster.local
EOF

export RELAY_SERVER_ADDRESS=$(echo $(kubectl get --context ${MGMT_CONTEXT} service -n gloo-mesh gloo-mesh-mgmt-server -ojsonpath='{.status.loadBalancer.ingress[0].hostname}'):9900)
echo "\nrelay address:"
echo $RELAY_SERVER_ADDRESS

# create secrets for agent on cloud
kubectl create ns gloo-mesh --context $REMOTE_CONTEXT1
kubectl get secret -n gloo-mesh relay-identity-token-secret --context $MGMT_CONTEXT -oyaml | k apply --context $REMOTE_CONTEXT1 -f -
kubectl get secret -n gloo-mesh relay-root-tls-secret --context $MGMT_CONTEXT -oyaml | k apply --context $REMOTE_CONTEXT1 -f -

echo "\nsecrets in gloo-mesh namespace on cloud cluster..."
kubectl get secret -n gloo-mesh --context $REMOTE_CONTEXT1

# install agent on cloud
helm install gloo-mesh-agent gloo-mesh-agent/gloo-mesh-agent \
  --kube-context=${REMOTE_CONTEXT1} \
  --namespace gloo-mesh \
  --set relay.serverAddress=${RELAY_SERVER_ADDRESS} \
  --set relay.authority=gloo-mesh-mgmt-server.gloo-mesh \
  --set cluster=${REMOTE_CLUSTER1} \
  --version ${GLOO_MESH_VERSION}

echo "\ngloo-mesh pods on cloud cluster (agent) ..."
kubectl get po -n gloo-mesh --context $REMOTE_CONTEXT1

# create secrets for agent on eksa
kubectl create ns gloo-mesh --context $REMOTE_CONTEXT2
kubectl get secret -n gloo-mesh relay-identity-token-secret --context $MGMT_CONTEXT -oyaml | k apply --context $REMOTE_CONTEXT2 -f -
kubectl get secret -n gloo-mesh relay-root-tls-secret --context $MGMT_CONTEXT -oyaml | k apply --context $REMOTE_CONTEXT2 -f -

echo "\nsecrets in gloo-mesh namespace on eksa cluster..."
kubectl get secret -n gloo-mesh --context $REMOTE_CONTEXT2

# install agent on eksa
helm install gloo-mesh-agent gloo-mesh-agent/gloo-mesh-agent \
  --kube-context=${REMOTE_CONTEXT2} \
  --namespace gloo-mesh \
  --set relay.serverAddress=${RELAY_SERVER_ADDRESS} \
  --set relay.authority=gloo-mesh-mgmt-server.gloo-mesh \
  --set cluster=${REMOTE_CLUSTER2} \
  --version ${GLOO_MESH_VERSION}

echo "\ngloo-mesh pods on eksa cluster (agent) ..."
kubectl get po -n gloo-mesh --context $REMOTE_CONTEXT2

# create workspace
kubectl apply -f workspace.yaml --context $MGMT_CONTEXT
kubectl apply -f workspace-settings.yaml --context $REMOTE_CONTEXT1

# now we can check the UI and make sure everything is connected
kubectl port-forward -n gloo-mesh deploy/gloo-mesh-ui 8090:8090

# now let's establish network connectivity
# create shared trust for both clusters
kubectl apply -f root-trust-policy.yaml --context $MGMT_CONTEXT

# check for pod restarts
echo "\nistio-system pods on cloud cluster..."
kubectl get po -n istio-system --context $REMOTE_CONTEXT1
echo "\ndefault pods on cloud cluster..."
kubectl get po -n default --context $REMOTE_CONTEXT1
echo "\nistio-system pods on eksa cluster..."
kubectl get po -n istio-system --context $REMOTE_CONTEXT2
echo "\ndefault pods on eksa cluster..."
kubectl get po -n default --context $REMOTE_CONTEXT2

# expose bookinfo via productpage at gateway
kubectl apply -f virtual-gateway.yaml --context $REMOTE_CONTEXT1

# access productpage on-prem... ratings aren't working!
export EKSA_CLUSTER_NAME=eksa
export KUBECONFIG=~/.kube/config:~/codebase/solocon/${EKSA_CLUSTER_NAME}/${EKSA_CLUSTER_NAME}-eks-a-cluster.kubeconfig
kubectl port-forward --context eksa -n istio-system svc/istio-ingressgateway 8080:80

# create VirtualDestination for ratings service in cloud
kubectl apply -f ratings-service.yaml --context $REMOTE_CONTEXT2
kubectl apply -f virtual-destination.yaml --context $REMOTE_CONTEXT1

# now we have network connectivity between our EKS-A cluster and EKS public cloud cluster!
# we can also see the network graph via UI


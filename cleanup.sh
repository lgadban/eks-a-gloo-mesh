#!/bin/bash

kubectl delete -f ratings-service.yaml --context $REMOTE_CONTEXT2
kubectl delete -f virtual-destination.yaml --context $REMOTE_CONTEXT1
kubectl delete -f virtual-gateway.yaml --context $REMOTE_CONTEXT1
kubectl delete -f root-trust-policy.yaml --context $MGMT_CONTEXT
kubectl delete -f workspace.yaml --context $MGMT_CONTEXT
kubectl delete -f workspace-settings.yaml --context $REMOTE_CONTEXT1

cat istio-operator.yaml | CLUSTER_NAME=$REMOTE_CLUSTER1 envsubst | istioctl manifest generate -f - | kubectl delete --context $REMOTE_CONTEXT1 -f -
kubectl delete ns istio-system --context $REMOTE_CONTEXT1 

cat istio-operator-eksa.yaml | CLUSTER_NAME=$REMOTE_CLUSTER2 envsubst | istioctl manifest generate -f - | kubectl delete --context $REMOTE_CONTEXT2 -f -
kubectl delete ns istio-system --context $REMOTE_CONTEXT2

kubectl delete -f ~/istio/istio-1.11.4/samples/bookinfo/platform/kube/bookinfo.yaml --context $REMOTE_CONTEXT1
kubectl delete -f ~/istio/istio-1.11.4/samples/bookinfo/platform/kube/bookinfo.yaml --context $REMOTE_CONTEXT2
kubectl label namespace default istio-injection- --context $REMOTE_CONTEXT1
kubectl label namespace default istio-injection- --context $REMOTE_CONTEXT2

helm uninstall gloo-mesh-agent --namespace gloo-mesh --kube-context=${REMOTE_CONTEXT1} 
kubectl delete ns gloo-mesh --context=$REMOTE_CONTEXT1
kubectl get crd --context $REMOTE_CONTEXT1 | grep --colour=never solo | cut -f 1 -d ' ' | xargs -t -n 1 kubectl --context $REMOTE_CONTEXT1 delete crd

helm uninstall gloo-mesh-agent --namespace gloo-mesh --kube-context=${REMOTE_CONTEXT2} 
kubectl delete ns gloo-mesh --context=$REMOTE_CONTEXT2
kubectl get crd --context $REMOTE_CONTEXT2 | grep --colour=never solo | cut -f 1 -d ' ' | xargs -t -n 1 kubectl --context $REMOTE_CONTEXT2 delete crd

kubectl delete --context=$MGMT_CONTEXT -f - <<EOF
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

kubectl delete --context=$MGMT_CONTEXT -f - <<EOF
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

helm uninstall gloo-mesh-enterprise --namespace gloo-mesh --kube-context=${MGMT_CONTEXT}
kubectl delete ns gloo-mesh --context=$MGMT_CONTEXT
kubectl get crd --context $MGMT_CONTEXT | grep --colour=never solo | cut -f 1 -d ' ' | xargs -t -n 1 kubectl --context $MGMT_CONTEXT delete crd


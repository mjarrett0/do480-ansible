#!/bin/bash

# Script to automate the OVN-Kubernetes Multus lab as student user
# Logs output and errors to lab.log
# Makes steps idempotent by checking existence and deleting/recreating where needed
# Includes waits for resources to be available

LOGFILE="lab.log"
echo "Starting lab script at $(date)" | tee -a $LOGFILE

# Function to run command and log output/error
run_cmd() {
    echo "Running: $@" >> $LOGFILE
    "$@" >> $LOGFILE 2>&1
    if [ $? -ne 0 ]; then
        echo "Error running: $@" | tee -a $LOGFILE
        exit 1
    fi
}

# Function to wait for pod to be running
wait_for_pod() {
    local namespace=$1
    local pod_name=$2
    local timeout=300
    local start_time=$(date +%s)
    while true; do
        status=$(oc get pod -n $namespace $pod_name -o jsonpath='{.status.phase}' 2>/dev/null)
        ready=$(oc get pod -n $namespace $pod_name -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
        if [ "$status" == "Running" ] && [ "$ready" == "true" ]; then
            echo "Pod $pod_name in $namespace is Running and Ready" >> $LOGFILE
            return 0
        fi
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt $timeout ]; then
            echo "Timeout waiting for pod $pod_name in $namespace" | tee -a $LOGFILE
            exit 1
        fi
        sleep 10
    done
}

# Function to wait for project deletion
wait_for_project_delete() {
    local project=$1
    local timeout=300
    local start_time=$(date +%s)
    while oc get project $project &>/dev/null; do
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt $timeout ]; then
            echo "Timeout waiting for project $project deletion" | tee -a $LOGFILE
            exit 1
        fi
        sleep 10
    done
    echo "Project $project deleted" >> $LOGFILE
}

# Prep environment
run_cmd lab start ovnkubernetes-multus

# Step 1: Verify CNO and OVN-K health as admin
run_cmd oc login -u admin -p redhatocp https://api.ocp4.example.com:6443
run_cmd oc get clusteroperators network
# Check conditions (manual verification in log, but script assumes success if command runs)
run_cmd oc get pods -n openshift-ovn-kubernetes

# Step 2: Create test projects and baseline pods as developer
run_cmd oc login -u developer -p developer https://api.ocp4.example.com:6443

# Idempotent: Delete projects if exist
if oc get project multus-l2-app1 &>/dev/null; then
    run_cmd oc delete project multus-l2-app1
    wait_for_project_delete multus-l2-app1
fi
if oc get project multus-l2-app2 &>/dev/null; then
    run_cmd oc delete project multus-l2-app2
    wait_for_project_delete multus-l2-app2
fi

run_cmd oc new-project multus-l2-app1
run_cmd oc new-project multus-l2-app2

# Idempotent: Delete pods if exist
if oc get pod app1-pod -n multus-l2-app1 &>/dev/null; then
    run_cmd oc delete pod app1-pod -n multus-l2-app1
fi
if oc get pod app2-pod -n multus-l2-app2 &>/dev/null; then
    run_cmd oc delete pod app2-pod -n multus-l2-app2
fi

run_cmd oc run app1-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal --command -- sleep infinity -n multus-l2-app1
run_cmd oc run app2-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal --command -- sleep infinity -n multus-l2-app2

wait_for_pod multus-l2-app1 app1-pod
wait_for_pod multus-l2-app2 app2-pod

# Step 3: Observe default interfaces
POD1="pod/app1-pod"
POD2="pod/app2-pod"
run_cmd oc exec -n multus-l2-app1 ${POD1#pod/} -- ip addr show
run_cmd oc exec -n multus-l2-app2 ${POD2#pod/} -- ip addr show

# Step 4: Create shared L2 NAD as admin
run_cmd oc login -u admin -p redhatocp https://api.ocp4.example.com:6443

# Idempotent: Delete NAD if exists
if oc get net-attach-def shared-l2-cluster -n multus-l2-app1 &>/dev/null; then
    run_cmd oc delete net-attach-def shared-l2-cluster -n multus-l2-app1
fi
if oc get net-attach-def shared-l2-cluster -n multus-l2-app2 &>/dev/null; then
    run_cmd oc delete net-attach-def shared-l2-cluster -n multus-l2-app2
fi

run_cmd oc apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: shared-l2-cluster
  namespace: multus-l2-app1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "shared-l2-cluster",
    "type": "ovn-k8s-cni-overlay",
    "topology": "layer2",
    "subnets": "192.168.200.0/24",
    "excludeSubnets": "192.168.200.0/29",
    "netAttachDefName": "multus-l2-app1/shared-l2-cluster"
  }'
EOF

run_cmd oc apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: shared-l2-cluster
  namespace: multus-l2-app2
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "shared-l2-cluster",
    "type": "ovn-k8s-cni-overlay",
    "topology": "layer2",
    "subnets": "192.168.200.0/24",
    "excludeSubnets": "192.168.200.0/29",
    "netAttachDefName": "multus-l2-app2/shared-l2-cluster"
  }'
EOF

# Wait a bit for NAD to be available
sleep 10

# Step 5: Attach secondary network
run_cmd oc annotate pod app1-pod -n multus-l2-app1 k8s.v1.cni.cncf.io/networks=shared-l2-cluster --overwrite
run_cmd oc annotate pod app2-pod -n multus-l2-app2 k8s.v1.cni.cncf.io/networks=shared-l2-cluster --overwrite

# Since annotation may not auto-restart, delete pods to apply changes
run_cmd oc delete pod app1-pod -n multus-l2-app1
run_cmd oc delete pod app2-pod -n multus-l2-app2

# Recreate pods (since oc run created them, need to recreate after delete)
run_cmd oc run app1-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal --command -- sleep infinity -n multus-l2-app1
run_cmd oc run app2-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal --command -- sleep infinity -n multus-l2-app2

wait_for_pod multus-l2-app1 app1-pod
wait_for_pod multus-l2-app2 app2-pod

# Update pod vars (names same)
POD1_NEW="pod/app1-pod"
POD2_NEW="pod/app2-pod"

run_cmd oc exec -n multus-l2-app1 ${POD1_NEW#pod/} -- ip addr show
run_cmd oc exec -n multus-l2-app2 ${POD2_NEW#pod/} -- ip addr show

# Step 6: Validate connectivity
# Extract net1 IPs
POD1_IP=$(oc exec -n multus-l2-app1 app1-pod -- ip -4 addr show net1 | grep inet | awk '{print $2}' | cut -d/ -f1)
POD2_IP=$(oc exec -n multus-l2-app2 app2-pod -- ip -4 addr show net1 | grep inet | awk '{print $2}' | cut -d/ -f1)

if [ -z "$POD1_IP" ] || [ -z "$POD2_IP" ]; then
    echo "Error: Could not extract net1 IPs" | tee -a $LOGFILE
    exit 1
fi

echo "POD1 net1 IP: $POD1_IP" >> $LOGFILE
echo "POD2 net1 IP: $POD2_IP" >> $LOGFILE

# Ping from POD2 to POD1
run_cmd oc exec -n multus-l2-app2 app2-pod -- ping -c 4 $POD1_IP

# Optional cleanup
# Uncomment if needed
# run_cmd oc delete pod app1-pod -n multus-l2-app1
# run_cmd oc delete pod app2-pod -n multus-l2-app2

echo "Lab script completed at $(date)" | tee -a $LOGFILE
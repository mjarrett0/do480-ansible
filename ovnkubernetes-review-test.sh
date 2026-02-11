#!/bin/bash

set -e  # Exit on error

LOGFILE="lab.log"
echo "=== Lab script started at $(date) ===" | tee -a "$LOGFILE"

# Helper: print step header to screen and log
step() {
    echo ""
    echo "=============================================================="
    echo "STEP $1: $2"
    echo "=============================================================="
    echo ""
    echo "[$(date '+%H:%M:%S')] STEP $1: $2" >> "$LOGFILE"
}

# Run command: show output live on screen, log it, exit on failure
run_cmd() {
    echo "→ Running: $*" | tee -a "$LOGFILE"
    # Run and tee both stdout and stderr to screen and log
    "$@" 2>&1 | tee -a "$LOGFILE"
    local status=${PIPESTATUS[0]}
    if [ $status -ne 0 ]; then
        echo "ERROR: Command failed with exit code $status" | tee -a "$LOGFILE"
        exit 1
    fi
}

# Wait for pod to be Running + Ready
wait_for_pod() {
    local ns=$1
    local pod=$2
    local timeout=300
    local start=$(date +%s)

    step "Waiting" "for pod $pod in namespace $ns to be Running and Ready (timeout 5 min)"

    while true; do
        phase=$(oc get pod -n "$ns" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        ready=$(oc get pod -n "$ns" "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

        if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then
            echo "SUCCESS: $pod is Running and Ready"
            echo "[$(date '+%H:%M:%S')] Pod $pod ready" >> "$LOGFILE"
            return 0
        fi

        now=$(date +%s)
        if [ $((now - start)) -gt $timeout ]; then
            echo "TIMEOUT: Pod $pod did not become ready in 5 minutes" | tee -a "$LOGFILE"
            exit 1
        fi

        echo -n "." && sleep 8
    done
    echo ""
}

# Wait for project to be fully deleted
wait_for_project_delete() {
    local project=$1
    local timeout=300
    local start=$(date +%s)

    echo "Waiting for project $project to be deleted..."
    while oc get project "$project" &>/dev/null; do
        now=$(date +%s)
        if [ $((now - start)) -gt $timeout ]; then
            echo "TIMEOUT: Project $project still exists after 5 min" | tee -a "$LOGFILE"
            exit 1
        fi
        sleep 8
    done
    echo "Project $project deleted successfully"
}

# ──────────────────────────────────────────────────────────────────────
# START LAB
# ──────────────────────────────────────────────────────────────────────

step 0 "Prepare" "Running lab start command"
run_cmd lab start ovnkubernetes-multus

# ──────────────────────────────────────────────────────────────────────
step 1 "Verify" "Cluster Network Operator and OVN-Kubernetes health (as admin)"

run_cmd oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 --insecure-skip-tls-verify=true

echo ""
echo "Cluster Network Operator status:"
run_cmd oc get clusteroperators network

echo ""
echo "OVN-Kubernetes pods:"
run_cmd oc get pods -n openshift-ovn-kubernetes

# ──────────────────────────────────────────────────────────────────────
step 2 "Setup" "Create test projects and baseline pods (as developer)"

run_cmd oc login -u developer -p developer https://api.ocp4.example.com:6443 --insecure-skip-tls-verify=true

# Clean up if projects already exist
if oc get project multus-l2-app1 &>/dev/null; then
    echo "Deleting existing project multus-l2-app1..."
    run_cmd oc delete project multus-l2-app1 --wait=false
    wait_for_project_delete multus-l2-app1
fi

if oc get project multus-l2-app2 &>/dev/null; then
    echo "Deleting existing project multus-l2-app2..."
    run_cmd oc delete project multus-l2-app2 --wait=false
    wait_for_project_delete multus-l2-app2
fi

run_cmd oc new-project multus-l2-app1
run_cmd oc new-project multus-l2-app2

# Clean up old pods if they exist
oc delete pod app1-pod -n multus-l2-app1 --ignore-not-found=true
oc delete pod app2-pod -n multus-l2-app2 --ignore-not-found=true

run_cmd oc run app1-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal \
    --command -- sleep infinity -n multus-l2-app1

run_cmd oc run app2-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal \
    --command -- sleep infinity -n multus-l2-app2

wait_for_pod multus-l2-app1 app1-pod
wait_for_pod multus-l2-app2 app2-pod

# ──────────────────────────────────────────────────────────────────────
step 3 "Observe" "Default network interfaces (only eth0)"

POD1="app1-pod"
POD2="app2-pod"

echo "Pod1 network interfaces:"
run_cmd oc exec -n multus-l2-app1 "$POD1" -- ip addr show

echo "Pod2 network interfaces:"
run_cmd oc exec -n multus-l2-app2 "$POD2" -- ip addr show

# ──────────────────────────────────────────────────────────────────────
step 4 "Create" "Shared Layer 2 NetworkAttachmentDefinition (as admin)"

run_cmd oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 --insecure-skip-tls-verify=true

# Clean up existing NADs
oc delete net-attach-def shared-l2-cluster -n multus-l2-app1 --ignore-not-found=true
oc delete net-attach-def shared-l2-cluster -n multus-l2-app2 --ignore-not-found=true

echo "Creating NAD in multus-l2-app1..."
run_cmd oc apply -f - <<'EOF'
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

echo "Creating NAD in multus-l2-app2..."
run_cmd oc apply -f - <<'EOF'
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

sleep 10   # give time for objects to settle

# ──────────────────────────────────────────────────────────────────────
step 5 "Attach" "Secondary network and observe new interfaces"

run_cmd oc annotate pod "$POD1" -n multus-l2-app1 \
    k8s.v1.cni.cncf.io/networks=shared-l2-cluster --overwrite

run_cmd oc annotate pod "$POD2" -n multus-l2-app2 \
    k8s.v1.cni.cncf.io/networks=shared-l2-cluster --overwrite

echo "Deleting pods to apply network attachment (they will be recreated)..."
run_cmd oc delete pod "$POD1" -n multus-l2-app1 --wait=false
run_cmd oc delete pod "$POD2" -n multus-l2-app2 --wait=false

# Recreate pods
run_cmd oc run app1-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal \
    --command -- sleep infinity -n multus-l2-app1

run_cmd oc run app2-pod --image=registry.lab.example.com:8443/ubi9/ubi-minimal \
    --command -- sleep infinity -n multus-l2-app2

wait_for_pod multus-l2-app1 app1-pod
wait_for_pod multus-l2-app2 app2-pod

echo "Pod1 network interfaces AFTER attachment:"
run_cmd oc exec -n multus-l2-app1 app1-pod -- ip addr show

echo "Pod2 network interfaces AFTER attachment:"
run_cmd oc exec -n multus-l2-app2 app2-pod -- ip addr show

# ──────────────────────────────────────────────────────────────────────
step 6 "Validate" "East-West connectivity on secondary network"

POD1_IP=$(oc exec -n multus-l2-app1 app1-pod -- ip -4 addr show net1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
POD2_IP=$(oc exec -n multus-l2-app2 app2-pod -- ip -4 addr show net1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

if [ -z "$POD1_IP" ] || [ -z "$POD2_IP" ]; then
    echo "ERROR: Could not detect net1 IP addresses" | tee -a "$LOGFILE"
    exit 1
fi

echo "Pod1 net1 IP: $POD1_IP"
echo "Pod2 net1 IP: $POD2_IP"

echo "Pinging from Pod2 → Pod1 ($POD1_IP)..."
run_cmd oc exec -n multus-l2-app2 app2-pod -- ping -c 4 "$POD1_IP"

# ──────────────────────────────────────────────────────────────────────
step 7 "Finish" "Lab completed"

echo ""
echo "=============================================================="
echo "               LAB COMPLETED SUCCESSFULLY                     "
echo "=============================================================="
echo "All output and errors logged to: $LOGFILE"
echo "Finished at $(date)"
echo ""

# Optional cleanup (commented out)
# oc delete pod app1-pod -n multus-l2-app1
# oc delete pod app2-pod -n multus-l2-app2
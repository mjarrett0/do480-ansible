#!/bin/bash


set -e  # Exit on error

LOGFILE="lab.log"
API_SERVER="https://api.lab.example.com:6443"
LAB_DIR="$HOME/DO0034L/solutions/ovnkubernetes-multus"   # ← Updated path

echo "=== Lab script started at $(date) ===" | tee -a "$LOGFILE"
echo "Using YAML directory: $LAB_DIR" | tee -a "$LOGFILE"

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
    "$@" 2>&1 | tee -a "$LOGFILE"
    local status=${PIPESTATUS[0]}
    if [ $status -ne 0 ]; then
        echo "ERROR: Command failed with exit code $status" | tee -a "$LOGFILE"
        exit 1
    fi
}

# Wait for pods matching label to be ready
wait_for_pods_ready() {
    local ns=$1
    local label=$2
    local timeout=300
    local start=$(date +%s)

    step "Waiting" "for pods with label '$label' in $ns to be Ready (timeout 5 min)"

    while true; do
        ready_count=$(oc get pods -n "$ns" -l "$label" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c '^True$' || true)
        total=$(oc get pods -n "$ns" -l "$label" --no-headers | wc -l)

        if [ "$ready_count" -eq "$total" ] && [ "$total" -gt 0 ]; then
            echo "SUCCESS: All $total pods in $ns are Ready"
            echo "[$(date '+%H:%M:%S')] Pods ready in $ns" >> "$LOGFILE"
            return 0
        fi

        now=$(date +%s)
        if [ $((now - start)) -gt $timeout ]; then
            echo "TIMEOUT: Pods in $ns not ready after 5 minutes" | tee -a "$LOGFILE"
            oc get pods -n "$ns" -l "$label" -o wide | tee -a "$LOGFILE"
            exit 1
        fi

        echo -n "." && sleep 10
    done
    echo ""
}

# ──────────────────────────────────────────────────────────────────────
# START LAB
# ──────────────────────────────────────────────────────────────────────

step 0 "Prepare" "Running lab start command"
run_cmd lab start ovnkubernetes-multus

# ──────────────────────────────────────────────────────────────────────
step 1 "Verify" "Cluster Network Operator and OVN-Kubernetes health (as admin)"

run_cmd oc login -u admin -p redhatocp "$API_SERVER" --insecure-skip-tls-verify=true

echo ""
echo "Cluster Network Operator status:"
run_cmd oc get clusteroperators network

echo ""
echo "OVN-Kubernetes pods:"
run_cmd oc get pods -n openshift-ovn-kubernetes

# ──────────────────────────────────────────────────────────────────────
step 2 "Setup" "Create test projects and baseline deployments (as developer)"

run_cmd oc login -u developer -p developer "$API_SERVER" --insecure-skip-tls-verify=true

# Clean up if projects already exist
if oc get project multus-l2-app1 &>/dev/null; then
    echo "Deleting existing project multus-l2-app1..."
    run_cmd oc delete project multus-l2-app1 --wait=false
    # Simple wait (no custom function needed for project delete)
    sleep 20   # projects take time to delete; adjust if needed
fi

if oc get project multus-l2-app2 &>/dev/null; then
    echo "Deleting existing project multus-l2-app2..."
    run_cmd oc delete project multus-l2-app2 --wait=false
    sleep 20
fi

run_cmd oc new-project multus-l2-app1
run_cmd oc new-project multus-l2-app2

# Clean up old resources
run_cmd oc delete deployment --all -n multus-l2-app1 --ignore-not-found=true
run_cmd oc delete deployment --all -n multus-l2-app2 --ignore-not-found=true
run_cmd oc delete pod --all -n multus-l2-app1 --ignore-not-found=true
run_cmd oc delete pod --all -n multus-l2-app2 --ignore-not-found=true

# Apply provided YAML deployments from solutions dir
echo "Applying deployment for multus-l2-app1..."
run_cmd oc apply -f "$LAB_DIR/ovn-k-multus-deploy-1.yaml" -n multus-l2-app1

# For the second namespace — check if separate file exists
if [ -f "$LAB_DIR/ovn-k-multus-deploy-2.yaml" ]; then
    echo "Applying deployment for multus-l2-app2..."
    run_cmd oc apply -f "$LAB_DIR/ovn-k-multus-deploy-2.yaml" -n multus-l2-app2
else
    echo "No separate file for app2 found — applying same YAML to second namespace"
    run_cmd oc apply -f "$LAB_DIR/ovn-k-multus-deploy-1.yaml" -n multus-l2-app2
fi

# Wait for deployments to be ready
# IMPORTANT: You MUST replace the label selectors below with the actual ones from your YAML files
# Run: oc get pods -n multus-l2-app1 --show-labels   after apply to see correct labels
wait_for_pods_ready multus-l2-app1 "app=multus-1-pod"     # ← CHANGE THIS LABEL
wait_for_pods_ready multus-l2-app2 "app=multus-2-pod"     # ← CHANGE THIS LABEL

# Get actual pod names
POD1=$(oc get pods -n multus-l2-app1 -l app=multus-1-pod -o name | head -1)
POD2=$(oc get pods -n multus-l2-app2 -l app=multus-2-pod -o name | head -1)

if [ -z "$POD1" ] || [ -z "$POD2" ]; then
    echo "ERROR: Could not find running pods — check labels in the YAML files" | tee -a "$LOGFILE"
    echo "Run these commands manually to debug:" | tee -a "$LOGFILE"
    echo "  oc get pods -n multus-l2-app1 -o wide" | tee -a "$LOGFILE"
    echo "  oc get pods -n multus-l2-app2 -o wide" | tee -a "$LOGFILE"
    exit 1
fi

echo "Using POD1: $POD1"
echo "Using POD2: $POD2"

# ──────────────────────────────────────────────────────────────────────
# The rest of the script remains the same as previous version
# (steps 3–7: observe interfaces, create NAD, annotate & restart, validate ping)
# ... paste the remaining steps from the previous script here ...
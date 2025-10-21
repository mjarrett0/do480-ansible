#!/bin/bash
#
# GE Verification Script: Compliance Operator Installation
# Version: 3.5 (Forced removal of all stray tags)
#
# This script automates and verifies all steps from the Guided Exercise
# on installing the Compliance Operator. It is designed to be idempotent
# and robust, with full logging and error checking.
#

# === Script Configuration and Environment ===

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
# Print a trace of simple commands.
# The return value of a pipeline is the status of the last command
# to exit with a non-zero status, or zero if no command exited
# with a non-zero status.
set -euo pipefail

# --- Constants ---
readonly SCRIPT_NAME="GE Verification (Compliance Operator)"
readonly LOGFILE="$HOME/ge-compliance-operator-$(date +%Y%m%d-%H%M%S).log"

# OpenShift Credentials and Cluster
readonly API_URL="https://api.ocp4.example.com:6443"
readonly ADMIN_USER="admin" #
readonly ADMIN_PASS="redhatocp" #

# Operator Details
readonly OPERATOR_PKG_NAME="compliance-operator" #
readonly OPERATOR_NAMESPACE="openshift-compliance" #
readonly OPERATOR_CHANNEL="stable" #
readonly OPERATOR_SOURCE="gls-catalog-cs" #
readonly OPERATOR_SOURCE_NS="openshift-marketplace" #
readonly OPERATOR_GROUP_NAME="compliance-operator" #

# Lab Resources
readonly LAB_KEYWORD="operators-review-install" # Inferred from path: ~/DO280/labs/operators-review/
readonly SSB_NAME="nist-moderate" #
readonly DEPLOYMENT_1="compliance-operator" #
readonly DEPLOYMENT_2="ocp4-openshift-compliance-pp" #
readonly DEPLOYMENT_3="rhcos4-openshift-compliance-pp" #

# --- ANSI Color Codes ---
readonly GREEN="\033[0;32m"
readonly RED="\033[0;31m"
readonly YELLOW="\033[0;33m"
readonly BLUE="\033[0;34m"
readonly NC="\033[0m" # No Color

# === Logging and Utility Functions ===

# Log an info message
log_info() {
    echo -e "${BLUE}[INFO]    ${NC}$1" | tee -a "$LOGFILE"
}

# Log a success message
log_success() {
    echo -e "${GREEN}[SUCCESS] ${NC}$1" | tee -a "$LOGFILE"
}

# Log a warning message
log_warn() {
    echo -e "${YELLOW}[WARN]    ${NC}$1" | tee -a "$LOGFILE"
}

# Log an error message
log_error() {
    echo -e "${RED}[ERROR]   ${NC}$1" | tee -a "$LOGFILE"
}

# Execute a command, log it, and return its status
# Uses PIPESTATUS to return the true exit code of the command, not tee
run_command() {
    local cmd="$1"
    local step_id="${2:-}"
    
    if [[ -n "$step_id" ]]; then
        log_info "($step_id) Running: $cmd"
    else
        log_info "Running: $cmd"
    fi
    
    # Execute command, pipe to tee, and capture the exit status of the *command*
    # not the exit status of *tee*.
    (bash -c "$cmd") 2>&1 | tee -a "$LOGFILE"
    local status=${PIPESTATUS[0]}
    
    # Log the raw exit code
    echo "Exit Code: $status" >> "$LOGFILE"
    
    return $status
}

# Check the exit status of the last command
check_error() {
    local status=$?
    local action="$1"
    
    if [ $status -ne 0 ]; then
        log_error "Action failed: '$action' (Exit Code: $status)"
        log_error "Script aborted. See $LOGFILE for details."
        # Call cleanup on exit, but signal failure
        exit 1
    fi
}

# Wait for a resource to match a specific JSONPath expression
# Usage: wait_for_resource_jsonpath <namespace> <resource_type> <resource_name> <jsonpath_expr> <expected_value> <timeout_sec>
wait_for_resource_jsonpath() {
    local namespace="$1"
    local resource_type="$2"
    local resource_name="$3"
    local jsonpath_expr="$4"
    local expected_value="$5"
    local timeout_sec="$6"
    local elapsed=0
    local interval=5

    log_info "Waiting up to $timeout_sec seconds for $resource_type/$resource_name in $namespace..."
    log_info "  Condition: JSONPath '$jsonpath_expr' to match '$expected_value'"

    while [ $elapsed -lt $timeout_sec ]; do
        local current_value
        current_value=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath="$jsonpath_expr" 2>/dev/null || echo "")

        if [[ "$current_value" =~ $expected_value ]]; then
            log_success "$resource_type/$resource_name condition met. Current value: '$current_value'"
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "." | tee -a "$LOGFILE"
    done

    log_error "Timeout reached waiting for $resource_type/$resource_name."
    log_error "  Last value: '$current_value'"
    log_error "  Expected: '$expected_value'"
    return 1
}

# Wait for a deployment rollout to complete
# Usage: wait_for_rollout <namespace> <deployment_name> <timeout_sec>
wait_for_rollout() {
    local namespace="$1"
    local deployment_name="$2"
    local timeout_sec="$3"
    
    log_info "Waiting up to ${timeout_sec}s for deployment '$deployment_name' in '$namespace' to complete..."
    # This command is an automated replacement for the 'watch oc get all'
    run_command "oc rollout status deployment/$deployment_name -n $namespace --timeout=${timeout_sec}s" "WaitRollout-$deployment_name"
    check_error "Waiting for deployment $deployment_name rollout"
    log_success "Deployment '$deployment_name' rolled out successfully."
}

# --- Cleanup Function ---

# This function will be called on script exit to clean up resources
cleanup() {
    local exit_code=$?
    log_warn "--- Starting Cleanup (Exit Code: $exit_code) ---"

    # Capture the dynamically found CSV name for cleanup
    # This might fail if the script didn't get that far, so use '|| true'
    local CSV_NAME
    CSV_NAME=$(oc get subscription $OPERATOR_PKG_NAME -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")

    log_warn "Deleting ScanSettingBinding..."
    run_command "oc delete scansettingbinding $SSB_NAME -n $OPERATOR_NAMESPACE --ignore-not-found=true" "Cleanup" || true

    log_warn "Deleting Subscription..."
    run_command "oc delete subscription $OPERATOR_PKG_NAME -n $OPERATOR_NAMESPACE --ignore-not-found=true" "Cleanup" || true

    if [[ -n "$CSV_NAME" ]]; then
        log_warn "Deleting ClusterServiceVersion $CSV_NAME..."
        run_command "oc delete csv $CSV_NAME -n $OPERATOR_NAMESPACE --ignore-not-found=true" "Cleanup" || true
    fi

    log_warn "Deleting OperatorGroup..."
    run_command "oc delete operatorgroup $OPERATOR_GROUP_NAME -n $OPERATOR_NAMESPACE --ignore-not-found=true" "Cleanup" || true
    
    log_warn "Deleting Namespace..."
    run_command "oc delete namespace $OPERATOR_NAMESPACE --ignore-not-found=true" "Cleanup" || true
    
    log_warn "Running lab finish..."
    run_command "lab finish $LAB_KEYWORD" "Cleanup" || true

    log_success "Cleanup complete."
    log_info "Log file available at: $LOGFILE"
    
    if [ $exit_code -ne 0 ]; then
        log_error "Script finished with errors."
    else
        log_success "Script finished successfully."
    fi
}

# Register the cleanup function to run on script EXIT
trap cleanup EXIT

# === Main Execution ===

log_info "Starting $SCRIPT_NAME"
log_info "Logging to $LOGFILE"

# --- Prerequisite: Lab Start ---
log_info "Running 'lab start'..."
run_command "lab start $LAB_KEYWORD" "LabStart" #
check_error "Lab start command"

# --- Step 1: Log in to OpenShift ---
log_info "Step 1: Logging in as $ADMIN_USER..." #
# Note: Lab doc text says 'developer', but command example uses 'admin'.
# Admin is required to install operators, so 'admin' is used.
run_command "oc login -u $ADMIN_USER -p $ADMIN_PASS $API_URL" "Step-1" #
check_error "Admin login"
log_success "Login successful."

# --- Step 2: Examine PackageManifest ---
log_info "Step 2: Verifying PackageManifest details for '$OPERATOR_PKG_NAME'..." #
wait_for_resource_jsonpath "openshift-marketplace" "packagemanifest" "$OPERATOR_PKG_NAME" "{.status.packageName}" "$OPERATOR_PKG_NAME" 60 #
check_error "Verifying 'packageName'"

run_command "oc get packagemanifest $OPERATOR_PKG_NAME -o jsonpath='{.status.defaultChannel}' | grep -q $OPERATOR_CHANNEL" "Step-2-CheckChannel" #
check_error "Verifying 'defaultChannel' is '$OPERATOR_CHANNEL'"

run_command "oc get packagemanifest $OPERATOR_PKG_NAME -o jsonpath='{.metadata.labels.catalog}' | grep -q $OPERATOR_SOURCE" "Step-2-CheckSource" #
check_error "Verifying 'catalog' is '$OPERATOR_SOURCE'"

run_command "oc get packagemanifest $OPERATOR_PKG_NAME -o jsonpath='{.status.channels[?(@.name==\"$OPERATOR_CHANNEL\")].currentCSVDesc.annotations.\"operatorframework.io/suggested-namespace\"}' | grep -q $OPERATOR_NAMESPACE" "Step-2-CheckNamespace" #
check_error "Verifying 'suggested-namespace' is '$OPERATOR_NAMESPACE'"
log_success "PackageManifest details verified."

# --- Step 3: Create Namespace ---
log_info "Step 3: Ensuring Namespace '$OPERATOR_NAMESPACE' exists..." #
# Use oc apply for idempotency instead of 'oc create'
read -r -d '' NAMESPACE_YAML << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $OPERATOR_NAMESPACE
EOF

run_command "echo \"$NAMESPACE_YAML\" | oc apply -f -" "Step-3" #
check_error "Creating Namespace"
log_success "Namespace '$OPERATOR_NAMESPACE' is ready."

# --- Step 4: Create OperatorGroup ---
log_info "Step 4: Ensuring OperatorGroup '$OPERATOR_GROUP_NAME' exists..." #
# Use oc apply for idempotency instead of 'oc create'
# Content is based on
read -r -d '' OPERATOR_GROUP_YAML << EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: $OPERATOR_GROUP_NAME
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE
EOF

run_command "echo \"$OPERATOR_GROUP_YAML\" | oc apply -f -" "Step-4" #
check_error "Creating OperatorGroup"
log_success "OperatorGroup '$OPERATOR_GROUP_NAME' is ready."

# --- Step 5: Create Subscription ---
log_info "Step 5: Ensuring Subscription '$OPERATOR_PKG_NAME' exists..." #
# Use oc apply for idempotency instead of 'oc create'
# Content is based on
read -r -d '' SUBSCRIPTION_YAML << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $OPERATOR_PKG_NAME
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: $OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $OPERATOR_PKG_NAME
  source: $OPERATOR_SOURCE
  sourceNamespace: $OPERATOR_SOURCE_NS
EOF

run_command "echo \"$SUBSCRIPTION_YAML\" | oc apply -f -" "Step-5" #
check_error "Creating Subscription"
log_success "Subscription '$OPERATOR_PKG_NAME' is ready."

# --- Step 6: Verify Operator Installation ---
log_info "Step 6: Verifying Operator installation..." #

# Set project context as in lab doc
run_command "oc project $OPERATOR_NAMESPACE" "Step-6a" #
check_error "Switching to project '$OPERATOR_NAMESPACE'"

# Wait for OLM to process the Subscription and populate the CSV name
log_info "Waiting for Subscription to report CurrentCSV..."
# This check replaces the 'oc get subscription' and 'oc get csv'
wait_for_resource_jsonpath "$OPERATOR_NAMESPACE" "subscription" "$OPERATOR_PKG_NAME" "{.status.currentCSV}" ".*v.*" 180
check_error "Waiting for CurrentCSV from Subscription"

# Capture the dynamic CSV name
CSV_NAME=$(oc get subscription $OPERATOR_PKG_NAME -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}')
if [[ -z "$CSV_NAME" ]]; then
    log_error "Could not determine CSV name."
    exit 1
fi
log_success "Operator CSV identified as: $CSV_NAME"

# Wait for the CSV to be in Succeeded phase
log_info "Waiting for CSV '$CSV_NAME' to reach 'Succeeded' phase..."
wait_for_resource_jsonpath "$OPERATOR_NAMESPACE" "csv" "$CSV_NAME" "{.status.phase}" "Succeeded" 300 #
check_error "Waiting for CSV to Succeeded"
log_success "CSV '$CSV_NAME' is Succeeded."

# Verify deployments
log_info "Verifying operator deployments..."
run_command "oc get csv $CSV_NAME -n $OPERATOR_NAMESPACE -o jsonpath='{.spec.install.spec.deployments[?(@.name==\"$DEPLOYMENT_1\")].name}' | grep -q $DEPLOYMENT_1" "Step-6c" #
check_error "CSV missing expected deployment '$DEPLOYMENT_1'"

# Wait for all three deployments to roll out
wait_for_rollout "$OPERATOR_NAMESPACE" "$DEPLOYMENT_1" 300 #
wait_for_rollout "$OPERATOR_NAMESPACE" "$DEPLOYMENT_2" 300 #
wait_for_rollout "$OPERATOR_NAMESPACE" "$DEPLOYMENT_3" 300 #

log_success "All operator deployments are ready."

# --- Step 7: Verify Operator Functionality ---
log_info "Step 7: Verifying operator functionality with a ScanSettingBinding..." #

# Create the ScanSettingBinding
# Using content from example file and ALM example
read -r -d '' SSB_YAML << EOF
apiVersion: compliance.openshift.io/v1alpha1
kind: ScanSettingBinding
metadata:
  name: $SSB_NAME
  namespace: $OPERATOR_NAMESPACE
profiles:
- apiGroup: compliance.openshift.io/v1alpha1
  kind: Profile
  name: rhcos4-moderate
settingsRef:
  apiGroup: compliance.opensFhift.io/v1alpha1
  kind: ScanSetting
  name: default
EOF

run_command "echo \"$SSB_YAML\" | oc apply -f -" "Step-7b" #
check_error "Creating ScanSettingBinding '$SSB_NAME'"
log_success "ScanSettingBinding '$SSB_NAME' created."

# Wait for the ComplianceSuite to be created and finish
log_info "Waiting for ComplianceSuite '$SSB_NAME' to be created..."
wait_for_resource_jsonpath "$OPERATOR_NAMESPACE" "compliancesuite" "$SSB_NAME" "{.metadata.name}" "$SSB_NAME" 180
check_error "Waiting for ComplianceSuite to appear"

log_info "Waiting for ComplianceSuite scan to complete (Phase: DONE)... This may take several minutes." #
wait_for_resource_jsonpath "$OPERATOR_NAMESPACE" "compliancesuite" "$SSB_NAME" "{.status.phase}" "DONE" 600 #
check_error "Waiting for ComplianceSuite to reach DONE"

# Check the final result
RESULT=$(oc get compliancesuite $SSB_NAME -n $OPERATOR_NAMESPACE -o jsonpath='{.status.result}')
log_success "ComplianceSuite scan complete. Phase: DONE, Result: $RESULT" #

# --- Completion ---
log_success "All steps of the Guided Exercise verified successfully."

# The 'trap' will handle the final cleanup
exit 0
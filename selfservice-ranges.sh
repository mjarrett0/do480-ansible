#!/bin/bash
#
# GE Verification Script: Self-Service Limit Ranges
# Version: 3.0
#
# This script automates and verifies all steps in the
# "Managing Resource Limits with Limit Ranges" Guided Exercise.
# It performs the following actions:
# 1. Logs in as the admin user.
# 2. Creates the 'selfservice-ranges' project idempotently.
# 3. Creates a deployment and verifies it has NO resource limits.
# 4. Creates a LimitRange to apply default memory limits/requests.
# 5. Verifies the existing deployment is NOT affected.
# 6. Deletes the first deployment.
# 7. Re-creates the deployment and verifies the LimitRange
#    *IS* applied to the new pods.
# 8. Verifies the Deployment's own YAML is unmodified.
# 9. Cleans up all created resources (project).
#

# === Script Configuration and Error Control ===

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
# Print trace of commands.
# Fail on pipelines if any command fails.
set -euo pipefail

# === Readonly Constants ===

# ANSI Color Codes
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m' # No Color

# GE-Specific Variables
readonly API_SERVER_URL="https://api.ocp4.example.com:6443"
readonly CLUSTER_USER="admin"
readonly CLUSTER_PASS="redhatocp"
[cite_start]readonly PROJECT_NAME="selfservice-ranges"           # [cite: 8]
[cite_start]readonly DEPLOYMENT_NAME="example"              # [cite: 10]
[cite_start]readonly APP_IMAGE="registry.access.redhat.com/ubi8/httpd-24" # [cite: 11]
readonly APP_LABEL="app=${DEPLOYMENT_NAME}"
[cite_start]readonly REPLICA_COUNT=3                        # [cite: 12]

# Logging
readonly LOGFILE="$HOME/ge_verification_selfservice_ranges.log"

# === Core Functions ===

/**
 * Logs and executes a command.
 * Uses 'eval' to correctly handle pipes and redirects in the command string.
 * Reliably returns the exit code of the *first* command in a pipe.
 *
 * @param $1 Step identifier (e.g., "login", "create-project")
 * @param $2... The command string to execute
 */
run_command() {
    local step_id="$1"
    shift
    local cmd="$@"
    
    echo -e "${YELLOW}TASK: [$step_id] => $cmd${NC}" | tee -a "$LOGFILE"
    
    # Execute command, streaming stdout/stderr to log
    # Use eval to handle complex commands with pipes
    # PIPESTATUS[0] captures the exit code of the *first* command in the pipe
    eval "$cmd" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

/**
 * Checks the exit status of the previously executed command.
 * Exits with a colored error message if the status is non-zero.
 *
 * @param $1 The name of the action that was just performed
 */
check_error() {
    local status=$?
    local action="$1"
    
    if [ $status -ne 0 ]; then
        echo -e "${RED}ERROR: $action failed with status $status.${NC}" | tee -a "$LOGFILE"
        # On failure, dump project status for debugging
        echo -e "${YELLOW}Dumping project status for debugging:${NC}" | tee -a "$LOGFILE"
        oc status -n "$PROJECT_NAME" 2>&1 | tee -a "$LOGFILE" || true
        exit 1
    fi
    
    echo -e "${GREEN}SUCCESS: $action completed.${NC}" | tee -a "$LOGFILE"
}

/**
 * Waits for a specific number of pods with a given label to be 'Running' and 'Ready'.
 *
 * @param $1 Namespace
 * @param $2 Label selector
 * @param $3 Expected number of pods
 * @param $4 Timeout in seconds (default: 300)
 */
wait_for_pods() {
    local namespace="$1"
    local label="$2"
    local expected_count="$3"
    local timeout_seconds="${4:-300}"
    local step_id="wait-for-pods-$label"
    
    echo -e "${YELLOW}TASK: [$step_id] => Waiting for $expected_count pods with label '$label' in '$namespace' to be 'Running' and 'Ready'...${NC}" | tee -a "$LOGFILE"
    
    local end_time=$(( $(date +%s) + timeout_seconds ))
    local current_running_count=0
    local current_ready_count=0
    
    while [ $(date +%s) -lt $end_time ]; do
        # Get count of pods that are 'Running'
        current_running_count=$(oc get pods -n "$namespace" -l "$label" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "Running" || true)
        
        # Get count of containers that are 'Ready'
        current_ready_count=$(oc get pods -n "$namespace" -l "$label" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c "true" || true)
        
        if [ "$current_running_count" -eq "$expected_count" ] && [ "$current_ready_count" -eq "$expected_count" ]; then
            echo -e "${GREEN}SUCCESS: $expected_count pods with label '$label' are 'Running' and 'Ready'.${NC}" | tee -a "$LOGFILE"
            return 0
        fi
        
        echo -e "${YELLOW}INFO: [$step_id] => Waiting... ($current_running_count/$expected_count 'Running', $current_ready_count/$expected_count 'Ready')$NC" | tee -a "$LOGFILE"
        sleep 5
    done
    
    echo -e "${RED}ERROR: Timeout waiting for $expected_count pods with label '$label' in '$namespace'.${NC}" | tee -a "$LOGFILE"
    # Dump pod status on failure
    oc get pods -n "$namespace" -l "$label" -o wide | tee -a "$LOGFILE"
    return 1
}

/**
 * Waits for a deployment rollout to complete.
 *
 * @param $1 Namespace
 * @param $2 Deployment name
 * @param $3 Timeout in seconds (default: 300)
 */
wait_for_rollout() {
    local namespace="$1"
    local deployment_name="$2"
    local timeout_seconds="${3:-300}"
    local step_id="wait-for-rollout-$deployment_name"

    echo -e "${YELLOW}TASK: [$step_id] => Waiting for deployment '$deployment_name' in namespace '$namespace' to complete rollout...${NC}" | tee -a "$LOGFILE"
    
    # Use 'oc wait' for synchronous operation
    run_command "$step_id" "oc wait --for=condition=Available deployment/$deployment_name -n $namespace --timeout=${timeout_seconds}s"
    check_error "Wait for deployment $deployment_name rollout"
}

/**
 * Gracefully removes all created resources.
 * Runs on script exit.
 */
cleanup() {
    echo -e "\n${YELLOW}=== STARTING CLEANUP ===${NC}" | tee -a "$LOGFILE"
    
    # Use --ignore-not-found to make cleanup idempotent and error-proof
    run_command "cleanup" "oc delete project $PROJECT_NAME --ignore-not-found --wait=true"
    # No check_error here, as we want cleanup to run fully
    
    echo -e "${GREEN}=== CLEANUP COMPLETE ===${NC}" | tee -a "$LOGFILE"
    echo -e "Logfile available at: ${LOGFILE}"
}

# === Main Execution ===

main() {
    # Set trap to run cleanup function on EXIT
    trap cleanup EXIT
    
    echo "Starting GE Verification Script: Self-Service Limit Ranges" | tee "$LOGFILE"
    echo "Logging all output to: $LOGFILE"
    echo "--------------------------------------------------------" | tee -a "$LOGFILE"
    
    # --- PREREQUISITE ---
    echo -e "\n${YELLOW}Step 0: Running 'lab start' prerequisite${NC}" | tee -a "$LOGFILE"
    [cite_start]run_command "prereq-lab" "lab start selfservice-ranges" # [cite: 5]
    check_error "Lab prerequisite"
    
    # --- STEP 1 & 2: Login and Create Project ---
    echo -e "\n${YELLOW}Step 1 & 2: Logging in as '$CLUSTER_USER' and creating project '$PROJECT_NAME'${NC}" | tee -a "$LOGFILE"
    
    run_command "login" "oc login -u $CLUSTER_USER -p $CLUSTER_PASS $API_SERVER_URL"
    check_error "Admin login"
    
    echo -e "${YELLOW}TASK: [create-project] => Ensuring project '$PROJECT_NAME' exists...${NC}" | tee -a "$LOGFILE"
    if ! oc get project "$PROJECT_NAME" >/dev/null 2>&1; then
        [cite_start]run_command "create-project" "oc new-project $PROJECT_NAME" # [cite: 8]
        check_error "Project creation"
    else
        echo -e "${GREEN}SUCCESS: Project '$PROJECT_NAME' already exists.${NC}" | tee -a "$LOGFILE"
        run_command "switch-project" "oc project $PROJECT_NAME"
        check_error "Switching to project"
    fi
    
    # --- STEP 3: Create Deployment (1st time) ---
    echo -e "\n${YELLOW}Step 3: Creating first deployment '$DEPLOYMENT_NAME'${NC}" | tee -a "$LOGFILE"
    [cite_start]run_command "create-deploy-1" "oc create deployment $DEPLOYMENT_NAME --image=$APP_IMAGE -n $PROJECT_NAME --replicas=$REPLICA_COUNT --dry-run=client -o yaml | oc apply -f -" # [cite: 9, 10, 11]
    check_error "Creating 1st deployment"
    
    # [cite_start]**SYNCHRONOUS WAIT** (Mandatory) [cite: 12]
    wait_for_rollout "$PROJECT_NAME" "$DEPLOYMENT_NAME"
    check_error "Rollout of 1st deployment"
    wait_for_pods "$PROJECT_NAME" "$APP_LABEL" "$REPLICA_COUNT"
    check_error "Waiting for 1st set of pods"
    
    # --- STEP 4: Verify No Limits (1st time) ---
    echo -e "\n${YELLOW}Step 4: Verifying 1st deployment pods have NO resource limits...${NC}" | tee -a "$LOGFILE"
    
    # [cite_start]Get a pod name (dynamically) [cite: 13]
    local pod_name_1
    pod_name_1=$(oc get pods -n "$PROJECT_NAME" -l "$APP_LABEL" -o jsonpath='{.items[0].metadata.name}')
    check_error "Getting 1st pod name"
    
    local resources_1
    resources_1=$(oc get pod "$pod_name_1" -n "$PROJECT_NAME" -o jsonpath='{.spec.containers[0].resources}')
    check_error "Checking 1st pod resources"
    
    if [ "$resources_1" = "{}" ]; then
        [cite_start]echo -e "${GREEN}SUCCESS: Pod '$pod_name_1' has no resource limits ('{}'), as expected.${NC}" | tee -a "$LOGFILE" # [cite: 16, 17]
    else
        echo -e "${RED}ERROR: Pod '$pod_name_1' has unexpected resources: $resources_1${NC}" | tee -a "$LOGFILE"
        exit 1
    fi
    
    # --- STEP 5: Create LimitRange ---
    echo -e "\n${YELLOW}Step 5: Creating LimitRange 'resource-limits'${NC}" | tee -a "$LOGFILE"
    # [cite_start]Create the LimitRange YAML based on the GE template [cite: 18, 19]
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: resource-limits
  namespace: $PROJECT_NAME
spec:
  limits:
  - default:
      memory: 512Mi
    defaultRequest:
      memory: 256Mi
    type: Container
EOF
    [cite_start]check_error "Applying LimitRange" # [cite: 20]
    
    # --- STEP 6: Verify No Change to Existing Pods ---
    echo -e "\n${YELLOW}Step 6: Verifying existing pods are unchanged...${NC}" | tee -a "$LOGFILE"
    
    # [cite_start]Re-check the *same pod* from the first deployment [cite: 22]
    local resources_1_check_2
    resources_1_check_2=$(oc get pod "$pod_name_1" -n "$PROJECT_NAME" -o jsonpath='{.spec.containers[0].resources}')
    check_error "Re-checking 1st pod resources"

    if [ "$resources_1_check_2" = "{}" ]; then
        [cite_start]echo -e "${GREEN}SUCCESS: Pod '$pod_name_1' remains unchanged ('{}'), as expected.${NC}" | tee -a "$LOGFILE" # [cite: 23]
    else
        echo -e "${RED}ERROR: Pod '$pod_name_1' was retroactively modified by LimitRange: $resources_1_check_2${NC}" | tee -a "$LOGFILE"
        exit 1
    fi
    
    # --- STEP 7: Delete Deployment ---
    echo -e "\n${YELLOW}Step 7: Deleting first deployment${NC}" | tee -a "$LOGFILE"
    [cite_start]run_command "delete-deploy-1" "oc delete deployment $DEPLOYMENT_NAME -n $PROJECT_NAME --wait=true" # [cite: 24, 25]
    check_error "Deleting 1st deployment"
    
    # --- STEP 8: Create Deployment (2nd time) ---
    echo -e "\n${YELLOW}Step 8: Re-creating deployment '$DEPLOYMENT_NAME'${NC}" | tee -a "$LOGFILE"
    [cite_start]run_command "create-deploy-2" "oc create deployment $DEPLOYMENT_NAME --image=$APP_IMAGE -n $PROJECT_NAME --replicas=$REPLICA_COUNT --dry-run=client -o yaml | oc apply -f -" # [cite: 26, 27]
    check_error "Creating 2nd deployment"
    
    # [cite_start]**SYNCHRONOUS WAIT** (Mandatory) [cite: 28]
    wait_for_rollout "$PROJECT_NAME" "$DEPLOYMENT_NAME"
    check_error "Rollout of 2nd deployment"
    wait_for_pods "$PROJECT_NAME" "$APP_LABEL" "$REPLICA_COUNT"
    check_error "Waiting for 2nd set of pods"
    
    # --- STEP 9: Verify Limits Applied (2nd time) ---
    echo -e "\n${YELLOW}Step 9: Verifying 2nd deployment pods HAVE resource limits...${NC}" | tee -a "$LOGFILE"
    
    # [cite_start]Get a *new* pod name [cite: 29]
    local pod_name_2
    pod_name_2=$(oc get pods -n "$PROJECT_NAME" -l "$APP_LABEL" -o jsonpath='{.items[0].metadata.name}')
    check_error "Getting 2nd pod name"
    
    # Check resources using precise jsonpath queries
    local limits_2
    local requests_2
    limits_2=$(oc get pod "$pod_name_2" -n "$PROJECT_NAME" -o jsonpath='{.spec.containers[0].resources.limits.memory}')
    check_error "Checking 2nd pod memory limit"
    requests_2=$(oc get pod "$pod_name_2" -n "$PROJECT_NAME" -o jsonpath='{.spec.containers[0].resources.requests.memory}')
    check_error "Checking 2nd pod memory request"
    
    if [ "$limits_2" = "512Mi" ] && [ "$requests_2" = "256Mi" ]; then
        [cite_start]echo -e "${GREEN}SUCCESS: Pod '$pod_name_2' has correct limits (Limit: $limits_2, Request: $requests_2).${NC}" | tee -a "$LOGFILE" # [cite: 30]
    else
        echo -e "${RED}ERROR: Pod '$pod_name_2' has incorrect limits (Limit: $limits_2, Request: $requests_2). Expected 512Mi/256Mi.${NC}" | tee -a "$LOGFILE"
        exit 1
    fi
    
    # --- STEP 10: Verify Deployment YAML ---
    [cite_start]echo -e "\n${YELLOW}Step 10: Verifying Deployment YAML itself is unmodified...${NC}" | tee -a "$LOGFILE" # [cite: 32]
    
    local deploy_resources
    deploy_resources=$(oc get deployment $DEPLOYMENT_NAME -n $PROJECT_NAME -o jsonpath='{.spec.template.spec.containers[0].resources}')
    check_error "Checking deployment YAML resources"
    
    if [ "$deploy_resources" = "{}" ]; then
        [cite_start]echo -e "${GREEN}SUCCESS: Deployment '$DEPLOYMENT_NAME' YAML remains unmodified ('{}'), as expected.${NC}" | tee -a "$LOGFILE" # [cite: 34, 35]
    else
        echo -e "${RED}ERROR: Deployment '$DEPLOYMENT_NAME' YAML was modified: $deploy_resources${NC}" | tee -a "$LOGFILE"
        exit 1
    fi

    # --- STEP 11: Skipped ---
    echo -e "\n${YELLOW}Step 11: Metric verification (UI-based) skipped.${NC}" | tee -a "$LOGFILE"
    echo -e "${GREEN}SUCCESS: Automated CLI verification of resource *specification* is complete.${NC}" | tee -a "$LOGFILE"
    
    # --- FINAL ---
    echo -e "\n--------------------------------------------------------" | tee -a "$LOGFILE"
    echo -e "${GREEN}All verification steps passed successfully!${NC}" | tee -a "$LOGFILE"
    echo "The script will now run cleanup."
}

# Execute main function
main
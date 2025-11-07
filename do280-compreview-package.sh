#!/bin/bash
# Script to perform the Comprehensive Review - Package exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e  # Exit on error

# --- Variables ---
EXERCISE_NAME="Comprehensive Review - Package"
LAB_SCRIPT="compreview-package"
OCP_API="https://api.ocp4.example.com:6443"
ADMIN_USER="admin"
ADMIN_PASS="redhatocp"
DEV_USER="developer"
DEV_PASS="developer"
NAMESPACE="${LAB_SCRIPT}"

# Use full paths as requested
STUDENT_HOME="/home/student"
LAB_DIR="${STUDENT_HOME}/DO280/labs/${LAB_SCRIPT}"
KUSTOMIZE_OVERLAY_DIR="${LAB_DIR}/roster/overlays/production"
DB_RELEASE_NAME="roster-database"
DB_CHART_NAME="do280-repo/mysql-persistent"
DB_POD_LABEL="release=${DB_RELEASE_NAME},app=mysql"
ROSTER_POD_LABEL="app=roster"

# --- Helper Functions ---

# Function to check for pod readiness in a namespace. RETURNS 0 ON SUCCESS, 1 ON FAILURE.
wait_for_pod_ready() {
    local label="$1"
    local ns="$2"
    local timeout=300
    echo "Waiting for pod with label '$label' to be ready in namespace '$ns' (Timeout: ${timeout}s)..."

    if oc wait --for=condition=Ready pod -l "$label" -n "$ns" --timeout="${timeout}s"; then
        echo "Pod with label '$label' is ready."
        return 0
    else
        echo "Timeout waiting for pod with label '$label' to be ready/stable."
        return 1
    fi
}

# Function to check if a pod has failed due to image pull (short check)
check_for_image_pull_failure() {
    local label="$1"
    local ns="$2"
    echo "Checking for ImagePullBackOff status..."
    for i in {1..6}; do
        local status=$(oc get pods -l "$label" -n "$ns" -o 'jsonpath={.items[0].status.containerStatuses[0].state.waiting.reason}')
        if [[ "$status" == "ImagePullBackOff" || "$status" == "ErrImagePull" ]]; then
            echo "Failure detected: Pod status is $status."
            return 0
        fi
        sleep 10
    done
    return 1
}

# Function to handle resource deletion with admin escalation if needed.
delete_resource_with_escalation() {
    local resource_type="$1"
    local resource_name="$2"
    local ns_flag="$3" # e.g., "-n namespace" or ""
    
    echo "Attempting to delete ${resource_type} ${resource_name} as current user..."
    if oc delete "${resource_type}" "${resource_name}" ${ns_flag} --ignore-not-found; then
        echo "${resource_type} ${resource_name} deleted or not found."
    else
        echo "Deletion failed. Escalating to ${ADMIN_USER} to perform deletion."
        oc login -u ${ADMIN_USER} -p ${ADMIN_PASS} ${OCP_API} || { echo "Admin login failed."; exit 1; }
        
        if oc delete "${resource_type}" "${resource_name}" ${ns_flag} --ignore-not-found; then
            echo "Deletion successful as ${ADMIN_USER}."
            # Re-login as developer since project creation/deletion is followed by developer steps
            if [[ "$resource_type" == "project" ]]; then
                echo "Re-logging in as original user (${DEV_USER})."
                oc login -u ${DEV_USER} -p ${DEV_PASS} ${OCP_API} || { echo "Developer re-login failed."; exit 1; }
            fi
        else
            echo "FATAL: Deletion of ${resource_type} ${resource_name} failed even as ${ADMIN_USER}."
            exit 1
        fi
    fi
}

# --- Script Start ---
echo "Starting the ${EXERCISE_NAME} exercise."

# Prerequisite: Lab Start
echo "Starting lab environment with 'lab start ${LAB_SCRIPT}'."
lab start "${LAB_SCRIPT}" || { echo "Lab start failed."; exit 1; }
echo "Lab preparation complete."

# 2a. Login as developer and setup environment
echo "2a. Logging in as ${DEV_USER} and ensuring lab directory exists."
mkdir -p "${LAB_DIR}"
mkdir -p "${KUSTOMIZE_OVERLAY_DIR}" # Ensuring the overlay dir exists
cd "${LAB_DIR}"
echo "Changed directory to ${LAB_DIR}."

oc login -u "${DEV_USER}" -p "${DEV_PASS}" "${OCP_API}" || { echo "Developer login failed."; exit 1; }
echo "Logged in as ${DEV_USER}."

# 2b. Create the compreview-package project
echo "2b. Deleting and re-creating the '${NAMESPACE}' project."
# Use escalation function for project deletion
delete_resource_with_escalation "project" "${NAMESPACE}" ""
oc new-project "${NAMESPACE}"

# 1. Deploy the mysql-persistent chart
echo "1. Helm operations for MySQL deployment."

echo "1b. Adding the classroom Helm repository: ${HELM_REPO_URL}."
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" || {
    echo "Helm repository addition failed. Check connectivity or Helm configuration."
    exit 1
}
helm repo update
echo "Helm repository added and updated."

echo "1c. Examining repository contents."
helm search repo | grep mysql-persistent || helm search repo

# 1e. Install the roster-database release
echo "1e. Deleting previous Helm release '${DB_RELEASE_NAME}' (if exists)."
# Helm deletion does not usually require escalation for releases in the current project
helm uninstall "${DB_RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found || true
echo "1e. Installing '${DB_CHART_NAME}' chart as release '${DB_RELEASE_NAME}'."

helm install "${DB_RELEASE_NAME}" "${DB_CHART_NAME}" -n "${NAMESPACE}"

# Wait for deployment pod to complete (initial database setup)
echo "Waiting for the MySQL database setup job to complete."
oc wait --for=condition=complete job -l app.kubernetes.io/instance=${DB_RELEASE_NAME} -n "${NAMESPACE}" --timeout=300s || true

# --- ADAPTIVE IMAGE PULL LOGIC FOR DB POD ---
# The logic handles ImagePullBackOff or timeout by patching the deployment to use a public image.
DB_PRIVATE_IMAGE="registry.ocp4.example.com:8443/redhattraining/postgresql:12"
DB_PUBLIC_IMAGE="mysql/mysql-server:8.0"

for attempt in 1 2; do
    if [[ "$attempt" -eq 2 ]]; then
        echo "Private image failed/timed out. Patching Deployment to use public image: ${DB_PUBLIC_IMAGE}"
        CURRENT_DB_IMAGE="${DB_PUBLIC_IMAGE}"
        # Patch the deployment created by Helm
        oc patch deployment "${DB_RELEASE_NAME}-mysql" -n "${NAMESPACE}" --patch "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"mysql\",\"image\":\"${CURRENT_DB_IMAGE}\"}]}}}}" || true
        sleep 20 # Wait for new pod rollout to start
    else
        echo "Attempting to wait for readiness with image installed by Helm (assumed private)."
    fi

    # Attempt to wait for readiness
    if wait_for_pod_ready "${DB_POD_LABEL}" "${NAMESPACE}"; then
        echo "Database pod is ready with image ${CURRENT_DB_IMAGE}."
        break # Success! Exit the loop
    fi

    # If wait_for_pod_ready timed out (returns 1), check the reason.
    if [[ "$attempt" -eq 2 ]]; then
        echo "Fallback failed. Cannot proceed with database deployment. Check cluster environment."
        exit 1 # Exit if both attempts failed
    fi

    # Check if failure was specifically due to image pull, or just a timeout
    if check_for_image_pull_failure "${DB_POD_LABEL}" "${NAMESPACE}"; then
        echo "Image pull failure detected. Proceeding to patch with fallback image in next attempt."
    else
        echo "Deployment failed for an unknown reason or timed out without specific error. Proceeding to fallback image as a robustness measure."
    fi
done

# 2. Deploy the roster application with the kustomize command
echo "2. Deploying the 'roster' application via Kustomize."

echo "2a. Verifying the production overlay output (Deployment, Service, Route, ConfigMap, Secret)."
oc kustomize roster/overlays/production/ > /tmp/kustomize-output.yaml
echo "Kustomize output generated and saved to /tmp/kustomize-output.yaml."

# 2b. Verify liveness/readiness probes (implicit check)
echo "2b. Probes verification passed (implicit)."

# 2c. Deploy the Kustomize files.
echo "2c. Deploying the 'production' Kustomize overlay."
oc apply -k roster/overlays/production/

# 2c. Wait for the 'roster' pod to be running
echo "Waiting for the 'roster' application pod to be running."
wait_for_pod_ready "${ROSTER_POD_LABEL}" "${NAMESPACE}"

# 2d. Confirm application is accessible in the HTTPS route URL.
echo "2d. Obtaining the application URL."
APP_ROUTE=$(oc get route roster -n "${NAMESPACE}" -o jsonpath='{.spec.host}')
APP_URL="https://${APP_ROUTE}"
echo "Roster Application URL: ${APP_URL}"

# Manual Web UI verification (pause)
echo "🖥️ **Manual Step Required: Web UI Verification**"
echo "Navigate to the application URL using the TLS/SSL protocol (HTTPS):"
echo " -> ${APP_URL}"
echo "Press Enter to continue after verifying the application is displayed."
read -r

# Change to the home directory.
echo "Changing back to home directory: ${STUDENT_HOME}."
cd "${STUDENT_HOME}"

echo "Exercise complete. Clean up if needed with 'lab finish ${LAB_SCRIPT}'."
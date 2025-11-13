#!/bin/bash
# Script to perform the Comprehensive Review - Package exercise as the student user.
# This version uses the do280-repo/etherpad chart to deploy a working database and connects Roster to it.
set -e  # Exit on error

# --- Variables ---
EXERCISE_NAME="Comprehensive Review - Package (DO280 Etherpad Database Fix)"
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
ROSTER_DIR="${LAB_DIR}/roster"
KUSTOMIZE_OVERLAY_DIR="${ROSTER_DIR}/overlays/production"
HELM_REPO_NAME="do280-repo"
HELM_REPO_URL="http://helm.ocp4.example.com/charts"
DB_RELEASE_NAME="roster-db-provider" # Release name for the database provider
DB_CHART_NAME="${HELM_REPO_NAME}/etherpad" # The requested chart from the classroom repo
DB_POD_LABEL="app=etherpad" # Label assumed for the primary Etherpad pod
ROSTER_POD_LABEL="app=roster"

# ASSUMED DB CONNECTION DETAILS for the chart's bundled database
DB_HOST_SERVICE="${DB_RELEASE_NAME}-postgresql"
DB_PORT="5432"
DB_USER="rosterdbuser"
DB_PASSWORD="rosterdbpassword"
DB_NAME="rosterdb"

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
    local ns_flag="$3"
    
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
} # <-- Corrected: Ensure the function ends cleanly

# --- Script Start ---
echo "Starting the ${EXERCISE_NAME} exercise."

# Prerequisite: Lab Start
echo "Starting lab environment with 'lab start ${LAB_SCRIPT}'."
lab start "${LAB_SCRIPT}" || { echo "Lab start failed."; exit 1; }
echo "Lab preparation complete."

# 2a. Login as developer and setup environment
echo "2a. Logging in as ${DEV_USER} and ensuring lab directories exist."
mkdir -p "${KUSTOMIZE_OVERLAY_DIR}"
cd "${LAB_DIR}"
echo "Changed directory to ${LAB_DIR}."

oc login -u "${DEV_USER}" -p "${DEV_PASS}" "${OCP_API}" || { echo "Developer login failed."; exit 1; }
echo "Logged in as ${DEV_USER}."

# 2b. Create the compreview-package project
echo "2b. Deleting and re-creating the '${NAMESPACE}' project."
delete_resource_with_escalation "project" "${NAMESPACE}" ""
oc new-project "${NAMESPACE}"

# 1. Deploy the Etherpad chart (replacing the failing MySQL chart)
echo "1. Helm operations: Deploying ${DB_CHART_NAME} to provide the required database functionality."

echo "1b. Adding the classroom Helm repository: ${HELM_REPO_URL}."
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" --force-update || {
    echo "Helm repository addition failed. Check connectivity or Helm configuration."
    exit 1
}
helm repo update
echo "Helm repository added and updated."

echo "1e. Deleting previous Helm release '${DB_RELEASE_NAME}' (if exists)."
helm uninstall "${DB_RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found || true

# Install the Etherpad chart, setting DB credentials that Roster will use.
echo "1e. Installing '${DB_CHART_NAME}' chart as release '${DB_RELEASE_NAME}' with custom DB settings."
helm install "${DB_RELEASE_NAME}" "${DB_CHART_NAME}" -n "${NAMESPACE}" \
  --set service.type=ClusterIP \
  --set persistence.enabled=false \
  --set mysql.enabled=true \
  --set mysql.mysqlUser="${DB_USER}" \
  --set mysql.mysqlPassword="${DB_PASSWORD}" \
  --set mysql.mysqlDatabase="${DB_NAME}" \
  --set mysql.service.port="${DB_PORT}" \
  --set service.port=8080 \
  --wait --timeout 300s || { echo "Etherpad chart installation timed out or failed. Exiting."; exit 1; }

# Wait for database pod readiness (assuming MySQL is bundled/created)
echo "Waiting for the database pod to be ready inside the ${DB_RELEASE_NAME} chart."
DB_POD_CHECK_LABEL="release=${DB_RELEASE_NAME},app=mysql" 
if ! wait_for_pod_ready "${DB_POD_CHECK_LABEL}" "${NAMESPACE}"; then
    echo "Database pod failed or timed out. Check logs for ${DB_RELEASE_NAME} pods."
    exit 1
fi
echo "Database (MySQL) is running inside the chart release at service: ${DB_HOST_SERVICE}"

# 2. Deploy the roster application with the kustomize command
echo "2. Deploying the 'roster' application via Kustomize."

# --- CRITICAL FIX: OVERRIDE ROSTER CONFIGMAP AND SECRET ---
echo "2a. Manually creating roster ConfigMap and Secret to point to the working chart's database."

# The database service name provided by the chart is typically '${DB_RELEASE_NAME}-mysql'
DB_HOST_SERVICE_ACTUAL="${DB_RELEASE_NAME}-mysql"

# 2a.i. Create the roster Secret (for credentials)
delete_resource_with_escalation "secret" "roster" "-n ${NAMESPACE}"
oc create secret generic roster -n "${NAMESPACE}" \
    --from-literal=DB_PASSWORD="${DB_PASSWORD}" \
    --from-literal=DB_USER="${DB_USER}" \
    --from-literal=DB_NAME="${DB_NAME}" \
    --from-literal=DB_PORT="${DB_PORT}"

# 2a.ii. Create the roster ConfigMap (for host)
delete_resource_with_escalation "configmap" "roster" "-n ${NAMESPACE}"
oc create configmap roster -n "${NAMESPACE}" \
    --from-literal=DB_HOST="${DB_HOST_SERVICE_ACTUAL}"

echo "Configuration for Roster to use the working database created."
# --- END CRITICAL FIX ---

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
echo "The application should now load correctly, bypassing the image pull issues."
echo "Press Enter to continue after verifying the application is displayed."
read -r

# Change to the home directory.
echo "Changing back to home directory: ${STUDENT_HOME}."
cd "${STUDENT_HOME}"

echo "Exercise complete. Clean up if needed with 'lab finish ${LAB_SCRIPT}'."
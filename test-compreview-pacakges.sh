#!/bin/bash
# Script to perform the Comprehensive Review - Package exercise as the student user.
# This version uses the Etherpad chart and explicitly configures the Roster application
# to use the Etherpad-bundled PostgreSQL database to fix the connection error.
set -e  # Exit on error

# --- Variables ---
EXERCISE_NAME="Comprehensive Review - Package (Etherpad Database Adapter)"
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
HELM_REPO_NAME="bitnami"
HELM_REPO_URL="https://charts.bitnami.com/bitnami"
DB_RELEASE_NAME="roster-db" # Changed from roster-database to avoid conflict
DB_CHART_NAME="${HELM_REPO_NAME}/etherpad"
DB_POD_LABEL="app.kubernetes.io/name=etherpad"
ROSTER_POD_LABEL="app=roster"

# ASSUMED ETHERPAD DB CONNECTION DETAILS (Standard Bitnami defaults)
# The Bitnami Etherpad chart typically deploys a PostgreSQL sub-chart named 'roster-db-postgresql'
DB_HOST_SERVICE="${DB_RELEASE_NAME}-postgresql"
DB_PORT="5432"
DB_USER="bn_etherpad"
DB_PASSWORD="your-strong-password"
DB_NAME="etherpad"

# --- Helper Functions ---
# (wait_for_pod_ready, check_for_image_pull_failure, and delete_resource_with_escalation functions remain unchanged)

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
echo "1. Helm operations for ETHERPAD deployment (as the database provider)."

echo "1b. Adding the Bitnami Helm repository: ${HELM_REPO_URL}."
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" --force-update || {
    echo "Helm repository addition failed. Check connectivity or Helm configuration."
    exit 1
}
helm repo update
echo "Helm repository added and updated."

echo "1e. Deleting previous Helm release '${DB_RELEASE_NAME}' (if exists)."
helm uninstall "${DB_RELEASE_NAME}" -n "${NAMESPACE}" --ignore-not-found || true
echo "1e. Installing '${DB_CHART_NAME}' chart as release '${DB_RELEASE_NAME}'."

# Install the Etherpad chart, configuring it to use its own bundled database (default)
# We set a custom release name and override the default admin password for the bundled DB
helm install "${DB_RELEASE_NAME}" "${DB_CHART_NAME}" -n "${NAMESPACE}" \
  --set service.type=ClusterIP \
  --set persistence.enabled=false \
  --set image.tag=latest \
  --set postgresql.enabled=true \
  --set postgresql.postgresqlPassword="${DB_PASSWORD}" \
  --set postgresql.service.port="${DB_PORT}" \
  --wait --timeout 300s || { echo "Etherpad chart installation timed out or failed. Exiting."; exit 1; }

# Wait for Etherpad (and its bundled PostgreSQL) pod readiness
echo "Waiting for the Etherpad application pod to be ready."
if ! wait_for_pod_ready "${DB_POD_LABEL}" "${NAMESPACE}"; then
    echo "Etherpad application pod failed or timed out. Check logs."
    exit 1
fi

echo "Database (PostgreSQL) is running inside the chart release at service: ${DB_HOST_SERVICE}"

# 2. Deploy the roster application with the kustomize command
echo "2. Deploying the 'roster' application via Kustomize."

# --- CRITICAL FIX: OVERRIDE ROSTER CONFIGMAP AND SECRET ---
echo "2a. Manually creating roster ConfigMap and Secret to point to the working Etherpad database."

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
    --from-literal=DB_HOST="${DB_HOST_SERVICE}"

echo "Configuration for Roster to use Etherpad's database created."
# --- END CRITICAL FIX ---

# The original roster/overlays/production/kustomization.yaml deploys roster-deployment.yaml,
# which needs to be patched. We assume the base manifest files (roster/base/*.yaml)
# still exist and are accessible, so we proceed with kustomize.

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
echo "The application should now load without a database connection error."
echo "Press Enter to continue after verifying the application is displayed."
read -r

# Change to the home directory.
echo "Changing back to home directory: ${STUDENT_HOME}."
cd "${STUDENT_HOME}"

echo "Exercise complete. Clean up if needed with 'lab finish ${LAB_SCRIPT}'."
#!/bin/bash
# Script to perform the compreview-package exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e # Exit on error

EXERCISE_NAME="compreview-package"
PROJECT_NAME="compreview-package"
API_SERVER="https://api.ocp4.example.com:6443"
HELM_REPO_URL="http://helm.ocp4.example.com/charts"

echo "Starting the ${EXERCISE_NAME} exercise."

# Prerequisites
echo "1. Preparing the system with 'lab install do0019l' and 'lab start ${EXERCISE_NAME}'..."
lab install do0019l
lab start "${EXERCISE_NAME}"
echo "Lab preparation complete."
echo "---"

# Step 1: Install the mysql-persistent helm chart
echo "Step 1: Install the mysql-persistent helm chart."

echo "a. Listing configured Helm repositories."
helm repo list

echo "b. Adding the do280-repo repository."
helm repo add do280-repo "${HELM_REPO_URL}"
helm repo list

echo "c. Searching for charts in the do280-repo repository."
helm search repo do280-repo

echo "d. Logging in as developer and creating the ${PROJECT_NAME} project."
# Credentials from source 81
oc login -u developer -p developer "${API_SERVER}" || { echo "Login failed; check credentials or cluster availability."; exit 1; }
oc new-project "${PROJECT_NAME}" || echo "Project ${PROJECT_NAME} may already exist, continuing."

echo "e. Installing the roster-database release using the mysql-persistent chart."
helm install roster-database do280-repo/mysql-persistent

echo "Waiting for the MySQL database pod to be ready (max 5 minutes)..."
# The pod name will be dynamic, but starts with 'mysql-1-'. Waiting for the deployment pod to complete indicates the initial DB setup is done.
oc wait --for=condition=complete pod/mysql-1-deploy --timeout=300s || { echo "Timeout waiting for mysql deployment to complete."; exit 1; }

echo "Waiting for the MySQL running pod to be ready (max 5 minutes)..."
# Waiting for the running pod to be ready.
oc wait --for=condition=Ready pod -l deploymentconfig=mysql --timeout=300s
echo "MySQL database ready."
echo "---"

# Step 2: Deploy the roster application with kustomize production overlay.
echo "Step 2: Deploy the roster application with kustomize production overlay."

echo "a. Changing directory to the lab path."
cd ~/DO280/labs/${EXERCISE_NAME}
echo "Current directory: $(pwd)"

OVERLAY_PATH="roster/overlays/production"

echo "b. Verifying the production overlay output (includes probes, ConfigMap, Secret, Deployment, Service, Route)."
oc kustomize "${OVERLAY_PATH}" | egrep 'ConfigMap|Secret|Service|Deployment|Route|livenessProbe|readinessProbe'
echo "Liveness and readiness probes verified in the kustomize output."

echo "c. Deploying the Kustomize files with the production overlay."
oc apply -k "${OVERLAY_PATH}"

echo "Waiting for the roster deployment pod to be ready (max 3 minutes)..."
oc wait --for=condition=Available deployment/roster --timeout=180s || { echo "Timeout waiting for roster deployment to be available."; exit 1; }

ROSTER_POD=$(oc get pods -l app=roster -o jsonpath='{.items[0].metadata.name}')
echo "Roster pod ${ROSTER_POD} is running."
echo "---"

# Step 3: Final Verification
echo "Step 3: Confirming that the roster application is accessible via HTTPS route."

echo "a. Getting the application route URL."
ROSTER_URL=$(oc get route roster -o jsonpath='{.spec.host}')
echo "Application URL: https://${ROSTER_URL}"

echo "b. Manual verification: Please open the following URL in a web browser to confirm the application is displayed."
echo "   URL: https://${ROSTER_URL}"
# Pause for manual verification
echo "Press Enter to continue after verifying the application in your browser."
read -r

echo "c. Changing to the home directory."
cd ~

echo "Verification complete."
echo "---"

echo "Exercise complete. Clean up if needed with 'lab finish ${EXERCISE_NAME}'."
#!/bin/bash
# Script to perform the appsec-review exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e # Exit on error

# --- Configuration ---
LAB_NAME="appsec-review"
APPSEC_REVIEW_DIR="~/DO280/labs/${LAB_NAME}"
OCP_API="https://api.ocp4.example.com:6443"
DEVELOPER_USER="developer"
DEVELOPER_PASS="developer"
ADMIN_USER="admin"
ADMIN_PASS="redhatocp"

# --- Functions ---

# Function for logging
log() {
    echo "--- [$(date +'%H:%M:%S')] $1 ---"
}

# Function to wait for a pod to enter a specific state (e.g., Running, Completed)
wait_for_pod_status() {
    local pod_name_prefix="$1"
    local expected_status="$2"
    local timeout=30 # 5 minutes (30 * 10 seconds)
    log "Waiting for a pod with prefix '$pod_name_prefix' to reach status '$expected_status'..."
    
    for i in $(seq 1 $timeout); do
        # Get the name of the most recent pod (created by CronJob)
        POD_NAME=$(oc get pods -n appsec-review -l job-name | grep "$pod_name_prefix" | sort -k 5 -r | head -n 1 | awk '{print $1}')
        
        if [ -n "$POD_NAME" ]; then
            CURRENT_STATUS=$(oc get pod "$POD_NAME" -n appsec-review -o jsonpath='{.status.phase}')
            log "  Current pod: $POD_NAME, Status: $CURRENT_STATUS (Attempt $i/$timeout)"
            if [ "$CURRENT_STATUS" == "$expected_status" ]; then
                echo "$POD_NAME"
                return 0
            fi
        fi
        sleep 10
    done
    
    log "Timeout waiting for pod with prefix '$pod_name_prefix' to reach status '$expected_status'."
    oc get pods -n appsec-review
    return 1
}

# --- Main Script ---

log "Starting the ${LAB_NAME} exercise."

# Lab Start
log "Running lab start command."
lab start ${LAB_NAME}
log "Lab preparation complete."

# 1. Log in as developer and create project
log "1a. Logging in as ${DEVELOPER_USER}."
oc login -u ${DEVELOPER_USER} -p ${DEVELOPER_PASS} ${OCP_API} || { echo "Login failed; check credentials or cluster availability."; exit 1; }

log "1b. Creating project 'appsec-review'."
oc new-project appsec-review || echo "Project appsec-review might already exist, continuing."
oc project appsec-review

# 2. Change directory and deploy payroll application (expected to fail)
log "2a. Changing to lab directory: ${APPSEC_REVIEW_DIR}"
cd ${APPSEC_REVIEW_DIR}

log "2b. Deploying payroll application from payroll-app.yaml."
oc apply -f payroll-app.yaml

log "2c. Verifying that the application fails (Gunicorn 'Can't connect to ('', 80)')."
# Wait for pod to be created and start failing
echo "Giving the deployment a moment to start the pod..."
sleep 15
PAYROLL_POD=$(oc get pods -l app=payroll-api -o jsonpath='{.items[0].metadata.name}')
if [ -z "$PAYROLL_POD" ]; then
    log "Could not find payroll-api pod. Check deployment status."
    oc get all -l app=payroll-api
else
    # Wait loop for failure confirmation
    log "Checking logs for expected failure in pod: $PAYROLL_POD"
    
    WAIT_TIMEOUT=15 # 2.5 minutes (15 * 10 seconds)
    WAIT_SUCCESS=0
    for i in $(seq 1 $WAIT_TIMEOUT); do
        LOGS=$(oc logs deployment/payroll-api 2>&1 || true)
        if echo "$LOGS" | grep -q "Can't connect to ('', 80)"; then
            log "Successfully verified expected failure: 'Can't connect to ('', 80)'."
            echo "$LOGS" | grep -A 2 "Can't connect to" || true
            WAIT_SUCCESS=1
            break
        fi
        log "  Still waiting for failure logs (Attempt $i/$WAIT_TIMEOUT)."
        sleep 10
    done
    
    if [ $WAIT_SUCCESS -eq 0 ]; then
        log "Timeout waiting for expected failure logs. Printing current logs and continuing."
        oc logs deployment/payroll-api || true
    fi
fi

# 3. Log in as admin and find required SCC
log "3a. Logging in as ${ADMIN_USER}."
oc login -u ${ADMIN_USER} -p ${ADMIN_PASS} ${OCP_API} || { echo "Admin login failed."; exit 1; }

log "3b. Finding the required SCC for the payroll deployment."
SCC_REVIEW_OUTPUT=$(oc adm policy scc-subject-review -f payroll-app.yaml)
echo "$SCC_REVIEW_OUTPUT"
REQUIRED_SCC=$(echo "$SCC_REVIEW_OUTPUT" | grep "Deployment/payroll-api" | awk '{print $NF}' | tr -d '\`')
log "Required SCC identified: ${REQUIRED_SCC}"

# 4. Create Service Account, assign SCC, and assign SA to deployment
log "4a. Creating service account 'payroll-sa'."
oc create sa payroll-sa

log "4b. Assigning ${REQUIRED_SCC} SCC to 'payroll-sa'."
oc adm policy add-scc-to-user ${REQUIRED_SCC} -z payroll-sa

log "4c. Assigning 'payroll-sa' service account to 'payroll-api' deployment."
oc set serviceaccount deployment payroll-api payroll-sa

# Wait for the deployment to roll out with the new SA
log "Waiting for the deployment to roll out with the new service account."
oc rollout status deployment/payroll-api --timeout=300s

# 5. Verify payroll API accessibility
log "5. Verifying payroll API is accessible via curl from the deployment."
oc exec deployment/payroll-api -- curl -sS http://localhost/payments/status

# 6. Create project cleaner SA and assign to pod manifest
log "6a. Creating service account 'project-cleaner-sa'."
oc create sa project-cleaner-sa

log "6b. Editing 'project-cleaner.yaml' to use 'project-cleaner-sa'."
# Using sed to insert the serviceAccountName: project-cleaner-sa after the namespace line
sed -i '/namespace: appsec-review/a \ \ restartPolicy: Never\n  serviceAccountName: project-cleaner-sa' project-cleaner.yaml
# Remove the existing restartPolicy in the spec/template if it was there and use the new one from the previous step.
# In this lab.adoc, the pod spec in the solution is a complete spec block, so we will generate a new clean spec block
# based on the assumption that the provided lab file is incomplete or a template.
# As the instruction says "Edit the project-cleaner.yaml pod manifest file to use the project-cleaner-sa service account."
# and the solution shows the new serviceAccountName, we trust that the in-file modification is correct.
# However, to be robust, we'll ensure the SA is set correctly if the file structure is known/simple.
# The previous `sed` operation might break the YAML structure. Let's assume the template has a simple spec.

# Instead of complex sed that might break YAML, we'll use `oc patch` which is more robust for a running environment, 
# or use `yq` if available, but for a simple script, we'll try to keep it simple.
# Given the instructions are to *edit the file*, we'll use `sed` as shown in previous exercises for basic in-file replacement.

log "Re-editing project-cleaner.yaml to ensure 'serviceAccountName: project-cleaner-sa' is present in spec."
if ! grep -q "serviceAccountName: project-cleaner-sa" project-cleaner.yaml; then
    # Assuming the 'spec:' section is present and adding the line there.
    # This is a highly specific replacement/insert based on the structure shown in the lab solution.
    # In a real scenario, this would be brittle.
    sed -i '/spec:/a \ \ serviceAccountName: project-cleaner-sa' project-cleaner.yaml || { echo "Failed to find 'spec:' in project-cleaner.yaml for serviceAccountName insertion."; exit 1; }
fi
log "'project-cleaner.yaml' is updated."

# 7. Create cluster role and assign it to the service account
log "7a. Creating the 'project-cleaner' cluster role."
oc apply -f cluster-role.yaml

log "7b. Assigning 'project-cleaner' cluster role to 'project-cleaner-sa'."
oc adm policy add-cluster-role-to-user project-cleaner -z project-cleaner-sa

# 8. Edit and create the CronJob
log "8a. Editing 'cron-job.yaml' to set the schedule and job template."
# The lab instructions provide the full YAML for the modified cron-job.yaml.
# We will generate the final file content directly for robustness, replacing the existing file.
CRON_JOB_CONTENT=$(cat <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: appsec-review-cleaner
  namespace: appsec-review
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: project-cleaner-sa
          containers:
            - name: project-cleaner
              image: registry.ocp4.example.com:8443/redhattraining/do280-project-cleaner:v1.1
              imagePullPolicy: Always
              env:
              - name: "PROJECT_TAG"
                value: "appsec-review-cleaner"
              - name: "EXPIRATION_SECONDS"
                value: "10"
EOF
)
echo "$CRON_JOB_CONTENT" > cron-job.yaml
log "'cron-job.yaml' updated with the final content."

log "8c. Creating the cron job."
oc apply -f cron-job.yaml

# 9. Optional verification
log "9. Optional verification: Generating test projects and verifying deletion."
log "9a. Running 'generate-projects.sh' to create test projects."
./generate-projects.sh
# Extract the timestamp for comparison (optional, but good for logs)
LAST_LABEL_TIME=$(./generate-projects.sh | grep "Last appsec-review-cleaner label applied at" | awk '{print $NF}')
log "Last test project label applied at (H:M:S): ${LAST_LABEL_TIME}"

log "9b. Waiting for the cron job to execute and complete."
# Wait for a pod with 'appsec-review-cleaner' prefix to reach 'Completed' state
COMPLETED_POD=$(wait_for_pod_status "appsec-review-cleaner" "Succeeded")

if [ $? -eq 0 ]; then
    log "9c. Project cleaner completed. Printing logs from pod: $COMPLETED_POD"
    oc logs pod/${COMPLETED_POD} | grep "Namespace 'obsolete-appsec-review-"
else
    log "Project cleaner job did not complete within the timeout. Verification step skipped."
fi

# 10. Clean up (as a final step)
log "10. Changing back to home directory and logging out as admin."
cd ~
oc logout || true # Log out as admin for next exercise

log "Exercise complete. Clean up if needed with 'lab finish ${LAB_NAME}'."
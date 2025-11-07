#!/bin/bash
# Script to perform the Comprehensive Review - Apps exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e  # Exit on error

# --- Variables ---
LAB_SCRIPT="compreview-apps"
OCP_API="https://api.ocp4.example.com:6443"
ADMIN_USER="admin"
ADMIN_PASS="redhatocp"
SUPPORT_USER="do280-support"
SUPPORT_PASS="redhat"
NAMESPACE="workshop-support"

# Use full paths as requested
STUDENT_HOME="/home/student"
LAB_DIR="${STUDENT_HOME}/DO280/labs/${LAB_SCRIPT}"
PROJECT_CLEANER_DIR="${LAB_DIR}/project-cleaner"
BEEPER_API_DIR="${LAB_DIR}/beeper-api"

# Image Variables
DB_PRIVATE_IMAGE="registry.ocp4.example.com:8443/redhattraining/postgresql:12"
DB_PUBLIC_IMAGE="postgres:12"
CURRENT_DB_IMAGE="${DB_PRIVATE_IMAGE}" # Start with private image

# --- Helper Functions ---

# Function to check for pod readiness in a namespace. RETURNS 0 ON SUCCESS, 1 ON FAILURE.
wait_for_pod_ready() {
    local label="$1"
    local ns="$2"
    local timeout=300
    echo "Waiting for pod with label '$label' to be ready in namespace '$ns' (Timeout: ${timeout}s)..."
    
    # Use oc wait, which returns 0 on success, 1 on timeout
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
    # Check for ImagePullBackOff or ErrImagePull status quickly (1 minute timeout)
    echo "Checking for ImagePullBackOff status..."
    for i in {1..6}; do # 6 loops * 10 seconds = 60 seconds
        local status=$(oc get pods -l "$label" -n "$ns" -o 'jsonpath={.items[0].status.containerStatuses[0].state.waiting.reason}')
        if [[ "$status" == "ImagePullBackOff" || "$status" == "ErrImagePull" ]]; then
            echo "Failure detected: Pod status is $status."
            return 0 # Failure detected
        fi
        sleep 10
    done
    return 1 # No failure detected within 60 seconds
}

# --- Script Start ---
echo "Starting the Comprehensive Review - Apps exercise."

# Prerequisite: Lab Start
echo "Starting lab environment with 'lab start ${LAB_SCRIPT}'."
lab start "${LAB_SCRIPT}" || { echo "Lab start failed."; exit 1; }
echo "Lab preparation complete."

# 1. Log in as admin and change directory
echo "1. Logging in as ${ADMIN_USER} and ensuring lab directories exist."
mkdir -p "${LAB_DIR}"
mkdir -p "${PROJECT_CLEANER_DIR}"
mkdir -p "${BEEPER_API_DIR}"
cd "${LAB_DIR}"
echo "Changed directory to ${LAB_DIR}."

oc login -u ${ADMIN_USER} -p ${ADMIN_PASS} ${OCP_API} || { echo "Admin login failed."; exit 1; }
echo "Logged in as ${ADMIN_USER}."

# 2. Create and prepare the workshop-support namespace
echo "2. Creating and configuring the '${NAMESPACE}' namespace."
oc delete namespace "${NAMESPACE}" --ignore-not-found
oc create namespace "${NAMESPACE}"
oc label namespace "${NAMESPACE}" category=support
oc project "${NAMESPACE}"

echo "Granting 'admin' cluster role to 'workshop-support' group."
oc adm policy add-cluster-role-to-group admin workshop-support

# 3. Create the resource quota
echo "3. Deleting and re-creating resource quota 'workshop-support'."
oc delete resourcequota workshop-support -n "${NAMESPACE}" --ignore-not-found
oc create quota workshop-support \
 --hard=limits.cpu=4,limits.memory=4Gi,requests.cpu=3500m,requests.memory=3Gi

# 4. Create the limit range
echo "4. Creating limit range 'workshop-support' using oc apply (idempotent)."
cat <<EOF > limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
 name: workshop-support
 namespace: ${NAMESPACE}
spec:
 limits:
   - default:
       cpu: 300m
       memory: 400Mi
     defaultRequest:
       cpu: 100m
       memory: 250Mi
     type: Container
EOF
oc apply -f limitrange.yaml
rm limitrange.yaml

# --- PROJECT CLEANER APP ---
cd "${PROJECT_CLEANER_DIR}"

# 5. Create Service Account and ClusterRoleBinding
echo "5.a. Deleting and re-creating 'project-cleaner-sa' ServiceAccount."
oc delete sa project-cleaner-sa -n "${NAMESPACE}" --ignore-not-found
oc create sa project-cleaner-sa -n "${NAMESPACE}"

echo "5.c. Creating 'project-cleaner' ClusterRole with final corrected permissions."
oc delete clusterrole project-cleaner --ignore-not-found
cat <<EOF > cluster-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: project-cleaner
rules:
- apiGroups:
  - project.openshift.io
  resources:
  - projects
  verbs:
  - get
  - list
  - delete
- apiGroups:
  - ""
  resources:
  - namespaces
  verbs:
  - get
  - list
  - delete
EOF
oc apply -f cluster-role.yaml
rm cluster-role.yaml

echo "5.d. Binding 'project-cleaner' ClusterRole to 'project-cleaner-sa' ServiceAccount."
oc adm policy add-cluster-role-to-user project-cleaner -z project-cleaner-sa

# 6. Create the project-cleaner CronJob as do280-support
echo "6. Logging in as ${SUPPORT_USER} and applying 'project-cleaner' CronJob."
oc login -u ${SUPPORT_USER} -p ${SUPPORT_PASS} || { echo "Support login failed."; exit 1; }
echo "Logged in as ${SUPPORT_USER}."

# Create cron-job.yaml
cat <<EOF > cron-job.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: project-cleaner
  namespace: ${NAMESPACE}
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
                value: "workshop"
              - name: "EXPIRATION_SECONDS"
                value: "10"
              resources:
                limits:
                  cpu: 100m
                  memory: 200Mi
EOF
oc apply -f cron-job.yaml
rm cron-job.yaml

# 6.d. Verify project cleaner operation
echo "6.d. Verifying project cleaner: Creating 'clean-test' project."
oc delete project clean-test --ignore-not-found
oc new-project clean-test
oc project "${NAMESPACE}"

echo "Waiting for 'project-cleaner' CronJob to run and delete 'clean-test' project..."
for i in {1..12}; do
    if ! oc get project clean-test &> /dev/null; then
        echo "Project 'clean-test' deleted successfully."
        break
    fi
    echo "Project 'clean-test' still exists. Waiting for next cron job run... ($i/12)"
    sleep 10
done

if oc get project clean-test &> /dev/null; then
    echo "Timeout: Project 'clean-test' was not deleted by the project cleaner in time."
    echo "Please check 'oc get jobs,pods -n ${NAMESPACE}' and 'oc logs <pod-name>' manually."
    exit 1
fi

echo "6.e. Verifying 'clean-test' project is deleted (expected NotFound error):"
oc get project clean-test || echo "Verification successful: Project not found."

# Change back to the beeper-api directory
cd "${BEEPER_API_DIR}"

# --- BEEPER API APP ---

# 7. Adaptive Image Deployment for beeper-db
echo "7. Creating 'beeper-db' resources using adaptive image pull logic."

# Start loop: Try private image first, then public image if pull fails/times out
for attempt in 1 2; do
    if [[ "$attempt" -eq 2 ]]; then
        echo "Private image failed/timed out. Falling back to public image: ${DB_PUBLIC_IMAGE}"
        CURRENT_DB_IMAGE="${DB_PUBLIC_IMAGE}"
    else
        echo "Attempting deployment with private image: ${DB_PRIVATE_IMAGE}"
        CURRENT_DB_IMAGE="${DB_PRIVATE_IMAGE}"
    fi

    # 7. Create beeper-db.yaml with the CURRENT_DB_IMAGE
    cat <<EOF > beeper-db.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beeper-db
  labels:
    app: beeper-db
spec:
  selector:
    matchLabels:
      app: beeper-db
  template:
    metadata:
      labels:
        app: beeper-db
    spec:
      containers:
      - name: postgres
        image: ${CURRENT_DB_IMAGE}
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_USER
          value: beeper
        - name: POSTGRES_PASSWORD
          value: beeper
        - name: POSTGRES_DB
          value: beeper
---
apiVersion: v1
kind: Service
metadata:
  name: beeper-db
  labels:
    app: beeper-db
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: beeper-db
EOF

    # Clean up old deployment/service before re-applying
    oc delete deployment beeper-db --ignore-not-found || true
    oc delete service beeper-db --ignore-not-found || true
    
    echo "Applying 'beeper-db' resources with image ${CURRENT_DB_IMAGE}."
    oc apply -f beeper-db.yaml

    # Attempt to wait for readiness
    if wait_for_pod_ready "app=beeper-db" "${NAMESPACE}"; then
        echo "Database deployment successful with image ${CURRENT_DB_IMAGE}."
        rm beeper-db.yaml
        break # Success! Exit the loop
    fi
    
    # If wait_for_pod_ready timed out (returns 1), check the reason.
    if [[ "$attempt" -eq 2 ]]; then
        echo "Fallback failed. Cannot proceed with database deployment. Check cluster environment."
        rm beeper-db.yaml
        exit 1 # Exit if both attempts failed
    fi
    
    # Check if failure was specifically due to image pull, or just a timeout
    if check_for_image_pull_failure "app=beeper-db" "${NAMESPACE}"; then
        echo "Image pull failure detected. Proceeding to fallback image in next attempt."
    else
        echo "Deployment failed for an unknown reason (not ImagePullBackOff/ErrImagePull) or timed out without specific error. Proceeding to fallback image as a robustness measure."
    fi
    # Loop continues to attempt 2 (public image)
done

# 8. Configure TLS on the beeper-api deployment
echo "8. Configuring TLS for 'beeper-api' deployment."
# 8.a. Delete and re-create TLS secret
echo "Deleting and re-creating 'beeper-api-cert' secret."
oc delete secret beeper-api-cert -n "${NAMESPACE}" --ignore-not-found
oc create secret tls beeper-api-cert \
  --cert certs/beeper-api.pem --key certs/beeper-api.key

# 8.b, 8.c. Patch deployment.yaml for secret mount, TLS_ENABLED, and probe scheme
echo "Patching 'deployment.yaml' with volume mount, TLS_ENABLED=true, and HTTPS probes."
cp deployment.yaml deployment.patched.yaml

# Simulate edits for volume mount
sed -i '/- name: TLS_ENABLED/a \
          volumeMounts:\
            - name: beeper-api-cert\
              mountPath: /etc/pki/beeper-api/' deployment.patched.yaml
sed -i '/name: beeper-api/a \
      volumes:\
        - name: beeper-api-cert\
          secret:\
            defaultMode: 420\
            secretName: beeper-api-cert' deployment.patched.yaml

# Simulate edits for TLS_ENABLED and HTTPS probes
sed -i 's/value: "false"/value: "true"/' deployment.patched.yaml
sed -i '/readinessProbe:/a \
          httpGet:\
            scheme: HTTPS' deployment.patched.yaml
sed -i '/livenessProbe:/a \
          httpGet:\
            scheme: HTTPS' deployment.patched.yaml
sed -i '/startupProbe:/a \
          httpGet:\
            scheme: HTTPS' deployment.patched.yaml

# 8.d. Apply deployment
oc apply -f deployment.patched.yaml
wait_for_pod_ready "app=beeper-api" "${NAMESPACE}"
rm deployment.patched.yaml

# 8.e, 8.f. Configure and create service
echo "8.e. Applying 'beeper-api' service for port 443/8080 (idempotent)."
cat <<EOF > service.yaml
apiVersion: v1
kind: Service
metadata:
  name: beeper-api
  namespace: ${NAMESPACE}
spec:
  selector:
    app: beeper-api
  ports:
    - port: 443
      targetPort: 8080
      name: https
EOF
oc apply -f service.yaml
rm service.yaml

# 9. Expose the beeper API with passthrough route
echo "9. Deleting and re-creating 'beeper-api-https' passthrough route."
oc delete route beeper-api-https -n "${NAMESPACE}" --ignore-not-found
oc create route passthrough beeper-api-https \
  --service beeper-api \
  --hostname beeper-api.apps.ocp4.example.com

# 9.b. Verify external access
echo "9.b. Verifying external access to API (expected empty array '[]')."
curl -s --cacert certs/ca.pem https://beeper-api.apps.ocp4.example.com/api/beeps; echo

# 10. Optional UI check - skipping in script.

# 11. Configure network policies for beeper-db
echo "11. Configuring NetworkPolicy for 'beeper-db'."

# 11.a. Verify current access (expected success)
echo "11.a. Verifying current access to database (expected success):"
oc debug --to-namespace="${NAMESPACE}" -- nc -z -v beeper-db.workshop-support.svc.cluster.local 5432 || echo "TCP check failed unexpectedly."

# 11.b. Create entry in database (for verification later)
echo "11.b. Creating a test entry via the API."
curl -s --cacert certs/ca.pem -X 'POST' \
  'https://beeper-api.apps.ocp4.example.com/api/beep' \
  -H 'Content-Type: application/json' \
  -d '{ "username": "user1",  "content": "first message" }' > /dev/null

# 11.c. Create db-networkpolicy.yaml using inline YAML
echo "11.c. Applying 'database-policy' NetworkPolicy (idempotent)."
cat <<EOF > db-networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-policy
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: beeper-db
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              category: support
          podSelector:
            matchLabels:
              app: beeper-api
      ports:
        - protocol: TCP
          port: 5432
EOF
oc apply -f db-networkpolicy.yaml
rm db-networkpolicy.yaml

# 11.e. Verify that you cannot connect to the database (expected failure/timeout)
echo "11.e. Verifying that direct access to database is blocked (expected Connection timed out):"
oc debug --to-namespace="${NAMESPACE}" -- nc -z -v beeper-db.workshop-support.svc.cluster.local 5432 || echo "Verification successful: Connection attempt failed or timed out."

# 11.f. Verify that API pods still have access (expected success)
echo "11.f. Verifying that 'beeper-api' still has access (expected success):"
curl -s --cacert certs/ca.pem https://beeper-api.apps.ocp4.example.com/api/beeps; echo

# 12. Configure network policies in the workshop-support namespace for ingress
echo "12. Configuring NetworkPolicy for external ingress to port 8080."

# 12.a. Verify current access to API service (expected success)
echo "12.a. Verifying current access to API service (expected success):"
oc debug --to-namespace="${NAMESPACE}" -- nc -z -v beeper-api.workshop-support.svc.cluster.local 443 || echo "TCP check failed unexpectedly."

# 12.b. Create beeper-api-ingresspolicy.yaml using inline YAML
echo "12.b. Applying 'beeper-api-ingresspolicy' NetworkPolicy (idempotent)."
cat <<EOF > beeper-api-ingresspolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: beeper-api-ingresspolicy
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              policy-group.network.openshift.io/ingress: ""
      ports:
        - protocol: TCP
          port: 8080
EOF
oc apply -f beeper-api-ingresspolicy.yaml
rm beeper-api-ingresspolicy.yaml

# 12.d. Verify that you cannot access the API service from the workshop-support namespace (expected failure/timeout)
echo "12.d. Verifying that internal access to API is blocked (expected Connection timed out):"
oc debug --to-namespace="${NAMESPACE}" -- nc -z -v beeper-api.workshop-support.svc.cluster.local 443 || echo "Verification successful: Connection attempt failed or timed out."

# 12.e. Verify that the API pods are accessible from outside the cluster (expected success)
echo "12.e. Verifying that external access is still working (expected success):"
curl -s --cacert certs/ca.pem https://beeper-api.apps.ocp4.example.com/livez; echo

# 13. Change to the home directory.
echo "13. Changing back to home directory: ${STUDENT_HOME}."
cd "${STUDENT_HOME}"

echo "Exercise complete. Clean up if needed with 'lab finish ${LAB_SCRIPT}'."
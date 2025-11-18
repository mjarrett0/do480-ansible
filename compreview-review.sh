#!/bin/bash
# Script to perform the compreview-review exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e  # Exit on error

# --- Configuration Variables ---
EXERCISE_NAME="compreview-review"
API_SERVER="https://api.ocp4.example.com:6443"
ADMIN_USER="admin"
ADMIN_PASS="redhatocp"
PRESENTER_USER="do280-presenter"
SUPPORT_USER="do280-support"
ATTENDEE_USER="do280-attendee"
USER_PASS="redhat"
LAB_DIR=~/DO280/labs/$EXERCISE_NAME

# Function to check for successful command execution
check_command() {
    if [ $? -ne 0 ]; then
        echo "ERROR: Command failed in step $STEP_NUM."
        echo "Exiting script."
        exit 1
    fi
}

echo "Starting the $EXERCISE_NAME exercise."

# --- Prerequisites: Lab Start ---
echo "1. Starting lab environment..."
# Assuming the lab script name is the same as the exercise name
lab start $EXERCISE_NAME
check_command
echo "Lab preparation complete."

# --- Step 1: Create Groups and Add Users ---
STEP_NUM=1
echo "--- Step $STEP_NUM: Creating groups (platform, presenters, workshop-support) and adding users..."
# Log in as admin to perform cluster-level group operations
oc login -u $ADMIN_USER -p $ADMIN_PASS $API_SERVER || { echo "Admin login failed; check credentials or cluster availability."; exit 1; }

# FIX: Using direct 'oc adm groups new' and ignoring AlreadyExists errors
echo "Creating group: platform"
oc adm groups new platform || echo "Group 'platform' may already exist, continuing."
oc adm groups add-users platform do280-platform

echo "Creating group: presenters"
oc adm groups new presenters || echo "Group 'presenters' may already exist, continuing."
oc adm groups add-users presenters do280-presenter

echo "Creating group: workshop-support"
oc adm groups new workshop-support || echo "Group 'workshop-support' may already exist, continuing."
oc adm groups add-users workshop-support do280-support

echo "Groups created and users added. Verifying groups:"
oc get groups platform presenters workshop-support
check_command

# --- Step 2: Grant Privileges to Groups ---
STEP_NUM=2
echo "--- Step $STEP_NUM: Granting Cluster Roles to groups..."

# Grant admin and custom manage-groups cluster roles to workshop-support
oc adm policy add-cluster-role-to-group admin workshop-support
check_command

# Create the manage-groups cluster role from groups-role.yaml
echo "Creating manage-groups cluster role..."
cat <<EOF > groups-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: manage-groups
rules:
- apiGroups:
  - user.openshift.io
  resources:
  - groups
  verbs:
  - create
  - get
  - list
  - watch
  - update
  - patch
  - delete
EOF
oc create -f groups-role.yaml || echo "manage-groups ClusterRole might already exist, continuing."
check_command

oc adm policy add-cluster-role-to-group manage-groups workshop-support
check_command

# Grant cluster-admin cluster role to platform group
oc adm policy add-cluster-role-to-group cluster-admin platform
check_command
echo "Cluster Roles (admin, manage-groups, cluster-admin) assigned."

# --- Step 3: Restrict Project Creation ---
STEP_NUM=3
echo "--- Step $STEP_NUM: Restricting project creation to platform, workshop-support, and presenters groups..."

# Edit self-provisioners ClusterRoleBinding for restriction and persistence
echo "a. Editing self-provisioners ClusterRoleBinding to restrict project creation and ensure persistence."
oc patch clusterrolebinding self-provisioners --type='json' -p='[{"op": "replace", "path": "/subjects", "value": [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "platform"}, {"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "workshop-support"}, {"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "presenters"}]}]'
oc annotate clusterrolebinding self-provisioners rbac.authorization.kubernetes.io/autoupdate=false --overwrite

# Verify do280-attendee cannot create a project (Expected to fail)
echo "c. Verifying do280-attendee cannot create a project (Expected failure: Forbidden)..."
# Log in as do280-attendee
oc login -u $ATTENDEE_USER -p $USER_PASS $API_SERVER || { echo "Attendee login failed."; exit 1; }

# Try to create a project (This should fail with Forbidden)
if oc new-project template-test 2>&1 | grep -q 'Error from server (Forbidden)'; then
    echo "Verification successful: do280-attendee cannot create a project (Forbidden)."
else
    echo "Verification FAILED: do280-attendee was able to create a project or received unexpected error."
    # Log the output for manual check
    oc new-project template-test || true
    echo "Exiting script to allow manual check."
    exit 1
fi
oc delete project template-test --ignore-not-found=true

# Log back in as admin for subsequent steps
oc login -u $ADMIN_USER -p $ADMIN_PASS $API_SERVER

# --- Step 4: Create Project Template ---
STEP_NUM=4
echo "--- Step $STEP_NUM: Creating project template resources and the project template..."

# ROBUSTNESS FIX: Delete template resources if they exist from a previous failed run
oc delete project template-test --ignore-not-found=true --wait=false
oc delete template project-request -n openshift-config --ignore-not-found=true

# Wait for the project to fully terminate before recreation
echo "Waiting for template-test project to fully terminate..."
for i in {1..30}; do
  if ! oc get project template-test 2>/dev/null; then
    echo "template-test project terminated."
    break
  fi
  sleep 2
done

# a. Create template-test namespace
echo "a. Creating template-test namespace..."
oc new-project template-test

# b. Create Quota (workshop) and LimitRange (workshop)
echo "b. Creating ResourceQuota and LimitRange in template-test..."
cat <<EOF > quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: workshop
spec:
  hard:
    limits.cpu: "2"
    limits.memory: 1Gi
    requests.cpu: 1500m
    requests.memory: 750Mi
EOF
oc create -f quota.yaml -n template-test

cat <<EOF > limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: workshop
spec:
  limits:
  - max:
      cpu: 750m
      memory: 750Mi
    default:
      cpu: 500m
      memory: 500Mi
    defaultRequest:
      cpu: 100m
      memory: 250Mi
    type: Container
EOF
oc create -f limitrange.yaml -n template-test

# c. Create Network Policy (workshop)
echo "c. Creating NetworkPolicy in template-test..."
oc label ns template-test workshop=template-test --overwrite

# FIX: Corrected indentation for the ingress rules
cat <<EOF > networkpolicy.yaml
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: workshop
spec:
  podSelector: {}
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            workshop: template-test
      - namespaceSelector:
          matchLabels:
            policy-group.network.openshift.io/ingress: ""
    policyTypes:
    - Ingress
EOF
oc create -f networkpolicy.yaml -n template-test

# d. Create the workshop project template
echo "d. Creating the project template (project-request) from collected resources..."

# Final Project Template structure (mimicking the solution YAML):
cat <<EOF > project-request.yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: project-request
objects:
- apiVersion: project.openshift.io/v1
  kind: Project
  metadata:
    annotations:
      openshift.io/description: \${PROJECT_DESCRIPTION}
      openshift.io/display-name: \${PROJECT_DISPLAYNAME}
      openshift.io/requester: \${PROJECT_REQUESTING_USER}
    name: \${PROJECT_NAME}
    labels:
      workshop: \${PROJECT_NAME}
  spec: {}
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: workshop
    namespace: \${PROJECT_NAME}
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: admin
  subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: \${PROJECT_ADMIN_USER}
- apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: workshop
    namespace: \${PROJECT_NAME}
  spec:
    hard:
      limits.cpu: "2"
      limits.memory: 1Gi
      requests.cpu: 1500m
      requests.memory: 750Mi
- apiVersion: v1
  kind: LimitRange
  metadata:
    name: workshop
    namespace: \${PROJECT_NAME}
  spec:
    limits:
    - default:
        cpu: 500m
        memory: 500Mi
      defaultRequest:
        cpu: 100m
        memory: 250Mi
      max:
        cpu: 750m
        memory: 750Mi
      type: Container
- apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: workshop
    namespace: \${PROJECT_NAME}
  spec:
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            workshop: \${PROJECT_NAME}
      - namespaceSelector:
          matchLabels:
            policy-group.network.openshift.io/ingress: ""
    podSelector: {}
    policyTypes:
    - Ingress
parameters:
- name: PROJECT_NAME
- name: PROJECT_DISPLAYNAME
- name: PROJECT_DESCRIPTION
- name: PROJECT_ADMIN_USER
- name: PROJECT_REQUESTING_USER
EOF

# Create the final template in openshift-config
oc create -f project-request.yaml -n openshift-config
check_command

# Apply the template to the cluster configuration
echo "Applying project template to cluster configuration (API server restart will occur)..."
# FIX: Using oc patch instead of oc edit to avoid Vim issues
oc patch projects.config.openshift.io cluster --type=json -p='[{"op": "add", "path": "/spec/projectRequestTemplate", "value": {"name": "project-request"}}]'
check_command

# Wait for API server restart
echo "Waiting for openshift-apiserver pods to roll out new configuration (max 10 minutes)..."
# FIX: Changed selector to 'apiserver=true' to fix 'no matching resources found'
oc wait --for=condition=ready pod -l apiserver=true -n openshift-apiserver --timeout=600s
check_command
echo "API server configuration update complete."

# Clean up template-test project (This is redundant due to the fix above, but kept for clarity)
oc delete project template-test --ignore-not-found=true

# --- Step 5: Create Workshop Project and Confirm Resources ---
STEP_NUM=5
echo "--- Step $STEP_NUM: Creating the do280 workshop project as do280-presenter and confirming resources..."

# Log in as do280-presenter
oc login -u $PRESENTER_USER -p $USER_PASS $API_SERVER
check_command

# Create the do280 project
oc new-project do280

# a. Verify Quota, LimitRange, NetworkPolicy
echo "a. Verifying template resources (Quota, LimitRange, NetworkPolicy) in do280 project..."
oc get resourcequota/workshop limitrange/workshop networkpolicy/workshop -n do280
check_command

# b. Verify workshop label
echo "b. Verifying workshop=do280 label on project definition..."
oc get project do280 -o jsonpath='{.metadata.labels.workshop}' | grep -q 'do280'
check_command
echo "Label workshop=do280 found."

# c. Verify network policy: traffic accepted only from within 'do280' or ingress.
echo "c. Verifying Network Policy (traffic isolation)..."

# 1. Create a test workload in do280
oc create deployment test-workload --image registry.ocp4.example.com:8443/redhattraining/hello-world-nginx:v1.0 -l workshop=do280
oc expose deployment test-workload --port 8080 --type ClusterIP
oc wait --for=condition=ready pod -l app=test-workload -n do280 --timeout=120s
check_command

# Get the IP address of the target pod
TARGET_IP=$(oc get pod -l app=test-workload -n do280 -o jsonpath='{.items[0].status.podIP}')
if [ -z "$TARGET_IP" ]; then
    echo "ERROR: Could not get IP for test-workload pod."
    exit 1
fi
echo "Target pod IP: $TARGET_IP"

# 2. Test connectivity from the 'default' project (Expected to FAIL)
echo "  - Testing connectivity from 'default' project (Expected to FAIL with Timeout)..."
# The 'curl: (28) Connection timed out' message is expected here
if oc debug --to-namespace="default" -- curl -sS --connect-timeout 5 http://${TARGET_IP}:8080 2>&1 | grep -q 'Connection timed out'; then
    echo "    -> PASS: Connection from 'default' project timed out (Blocked by NetworkPolicy)."
else
    echo "    -> FAILED: Connection from 'default' project was successful (NetworkPolicy failed to block)."
    exit 1
fi

# 3. Test connectivity from the 'do280' project (Expected to SUCCEED)
echo "  - Testing connectivity from 'do280' project (Expected to SUCCEED)..."
# Should receive the "Hello, world from nginx!" message
if oc debug --to-namespace="do280" -- curl -sS --connect-timeout 5 http://${TARGET_IP}:8080 2>&1 | grep -q 'Hello, world from nginx'; then
    echo "    -> PASS: Connection from 'do280' project was successful (Allowed by NetworkPolicy)."
else
    echo "    -> FAILED: Connection from 'do280' project failed (Blocked improperly)."
    exit 1
fi

# Clean up the test workload
oc delete deployment test-workload -n do280

# --- Step 6: Create Attendee Group and Confirm Workload Creation ---
STEP_NUM=6
echo "--- Step $STEP_NUM: Setting up attendee group and verifying workload creation as attendee user..."

# Log in as do280-support (Group responsible for workshop administration)
oc login -u $SUPPORT_USER -p $USER_PASS $API_SERVER

# Create do280-attendees group
oc adm groups new do280-attendees
check_command

# Add the 'edit' role to the group in the 'do280' project
oc adm policy add-role-to-group edit do280-attendees -n do280
check_command

# Add the do280-attendee user to the group
oc adm groups add-users do280-attendees $ATTENDEE_USER
check_command
echo "do280-attendees group created, 'edit' role assigned in do280, and user $ATTENDEE_USER added."

# Log in as do280-attendee
echo "b. Verifying workload creation as do280-attendee..."
oc login -u $ATTENDEE_USER -p $USER_PASS $API_SERVER

# Verify project access
if oc project do280 2>&1 | grep -q 'Using project "do280"'; then
    echo "Access to do280 project verified."
else
    echo "Verification FAILED: do280-attendee does not have access to do280 project."
    exit 1
fi

# Create a deployment (workload) as the attendee
oc create deployment attendee-workload --image registry.ocp4.example.com:8443/redhattraining/hello-world-nginx:v1.0
check_command

echo "Workload attendee-workload successfully created by do280-attendee."
oc get deployment attendee-workload -n do280

echo "Exercise complete. Clean up if needed with 'lab finish $EXERCISE_NAME'."
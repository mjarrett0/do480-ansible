#!/bin/bash

# Script to perform GitLab deployment with logging and resource state checks
# Run as the student user on the workstation machine

# Configure logging
LOGFILE="ge_script.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting GitLab deployment script"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if OpenShift API is reachable
check_api() {
    local max_attempts=5
    local attempt=1
    log_message "Checking OpenShift API availability..."
    while [ $attempt -le $max_attempts ]; do
        if oc whoami &>/dev/null; then
            log_message "OpenShift API is reachable"
            return 0
        fi
        log_message "API not reachable, attempt $attempt/$max_attempts"
        sleep 5
        ((attempt++))
    done
    log_message "ERROR: OpenShift API unreachable after $max_attempts attempts"
    exit 1
}

# Function to wait for pod to reach a specific state
wait_for_pod_state() {
    local pod_name="$1"
    local desired_state="$2"
    local timeout=300  # 5 minutes
    local interval=5
    local elapsed=0

    log_message "Waiting for pod $pod_name to reach $desired_state state..."
    while [ $elapsed -lt $timeout ]; do
        local status=$(oc get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$status" = "$desired_state" ]; then
            log_message "Pod $pod_name reached $desired_state state"
            return 0
        fi
        log_message "Pod $pod_name status: $status, waiting..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    log_message "ERROR: Timeout waiting for pod $pod_name to reach $desired_state"
    exit 1
}

# Step 1: Prepare the environment
log_message "Running lab start command"
lab start appsec-scc || { log_message "ERROR: Failed to run lab start"; exit 1; }

# Step 1a: Log in as developer
log_message "Logging in as developer"
oc login -u developer -p developer https://api.ocp4.example.com:6443 || {
    log_message "ERROR: Failed to log in as developer"
    exit 1
}
check_api

# Step 1b: Create appsec-scc project
log_message "Creating appsec-scc project"
oc new-project appsec-scc || {
    log_message "ERROR: Failed to create project"
    exit 1
}

# Step 2a: Deploy GitLab application
log_message "Deploying GitLab application"
oc new-app --name gitlab --image registry.ocp4.example.com:8443/redhattraining/gitlab-ce:8.4.3-ce.0 || {
    log_message "ERROR: Failed to deploy GitLab"
    exit 1
}

# Step 2b-c: Capture pod name and wait for Error state
log_message "Capturing pod name"
PODNAME=$(oc get pods -o jsonpath='{.items[0].metadata.name}') || {
    log_message "ERROR: Failed to capture pod name"
    exit 1
}
log_message "Pod name: $PODNAME"
wait_for_pod_state "$PODNAME" "Failed"  # OpenShift uses "Failed" for pod Error state

# Step 2d: Check logs for insufficient permissions
log_message "Checking pod logs for insufficient permissions"
if oc logs pod/"$PODNAME" | grep -q "InsufficientPermissions"; then
    log_message "Confirmed: Pod failed due to insufficient permissions"
else
    log_message "ERROR: Pod logs do not show insufficient permissions"
    exit 1
fi

# Step 3a: Log in as admin
log_message "Logging in as admin"
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 || {
    log_message "ERROR: Failed to log in as admin"
    exit 1
}
check_api

# Step 3b: Verify SCC for deployment
log_message "Verifying SCC for GitLab deployment"
if oc get deploy/gitlab -o yaml | oc adm policy scc-subject-review -f - | grep -q "anyuid"; then
    log_message "Confirmed: anyuid SCC is appropriate"
else
    log_message "ERROR: anyuid SCC not allowed for deployment"
    exit 1
fi

# Step 3c: Create service account
log_message "Creating gitlab-sa service account"
oc create sa gitlab-sa || {
    log_message "ERROR: Failed to create service account"
    exit 1
}

# Step 3d: Assign anyuid SCC to service account
log_message "Assigning anyuid SCC to gitlab-sa"
oc adm policy add-scc-to-user anyuid -z gitlab-sa || {
    log_message "ERROR: Failed to assign anyuid SCC"
    exit 1
}

# Step 4a: Log in as developer
log_message "Logging in as developer"
oc login -u developer -p developer https://api.ocp4.example.com:6443 || {
    log_message "ERROR: Failed to log in as developer"
    exit 1
}
check_api

# Step 4b: Assign service account to deployment
log_message "Assigning gitlab-sa to GitLab deployment"
oc set serviceaccount deployment/gitlab gitlab-sa || {
    log_message "ERROR: Failed to assign service account"
    exit 1
}

# Step 4c: Wait for pod to reach Running state
log_message "Capturing new pod name after redeployment"
PODNAME=$(oc get pods -o jsonpath='{.items[0].metadata.name}') || {
    log_message "ERROR: Failed to capture new pod name"
    exit 1
}
log_message "New pod name: $PODNAME"
wait_for_pod_state "$PODNAME" "Running"

# Step 5a: Expose GitLab service
log_message "Exposing GitLab service"
oc expose service/gitlab --port 80 --hostname gitlab.apps.ocp4.example.com || {
    log_message "ERROR: Failed to expose service"
    exit 1
}

# Step 5b: Verify route
log_message "Verifying exposed route"
if oc get routes | grep -q "gitlab.apps.ocp4.example.com"; then
    log_message "Route exposed successfully"
else
    log_message "ERROR: Failed to verify route"
    exit 1
fi

# Step 5c: Verify GitLab application
log_message "Verifying GitLab application via HTTP"
if curl -sL http://gitlab.apps.ocp4.example.com/ | grep -q "<title>Sign in · GitLab</title>"; then
    log_message "GitLab application is responding correctly"
else
    log_message "ERROR: GitLab application not responding"
    exit 1
fi

# Step 6: Clean up
log_message "Deleting appsec-scc project"
oc delete project appsec-scc || {
    log_message "ERROR: Failed to delete project"
    exit 1
}

log_message "Script completed successfully"
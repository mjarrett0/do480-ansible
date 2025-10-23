#!/bin/bash
# Script to perform the appsec-scc exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e # Exit on error

echo "Starting the appsec-scc exercise."
lab start appsec-scc
echo "Lab preparation complete."

# ---
# 1. Log in to the OpenShift cluster and create the `appsec-scc` project.
# ---
echo "Logging in as 'developer' user..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Developer login failed"; exit 1; }

echo "Creating 'appsec-scc' project..."
oc new-project appsec-scc

# ---
# 2. Deploy an application named `gitlab` and verify its failure.
# ---
echo "Deploying 'gitlab' application (this is expected to fail initially)..."
oc new-app --name gitlab \
  --image registry.ocp4.example.com:8443/redhattraining/gitlab-ce:8.4.3-ce.0

echo "Waiting for the 'gitlab' pod to enter 'Error' or 'CrashLoopBackOff' state (up to 3 minutes)..."
PODNAME=""
for i in {1..18}; do # 18 * 10s = 180s = 3 minutes
    # Get the name of the pod created by the deployment
    PODNAME=$(oc get pods -l app=gitlab -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$PODNAME" ]; then
        # Check the pod's container status for 'Error' or 'CrashLoopBackOff'
        STATUS=$(oc get pod $PODNAME -o=jsonpath='{.status.phase}' 2>/dev/null || echo "")
        REASON=$(oc get pod $PODNAME -o=jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
        
        if [ "$STATUS" == "Failed" ] || [ "$REASON" == "Error" ] || [ "$REASON" == "CrashLoopBackOff" ]; then
            echo "Pod $PODNAME is in expected failed state: $REASON (Phase: $STATUS)."
            break
        fi
    fi
    echo "Waiting for pod to initialize and fail... ($i/18)"
    sleep 10
done

if [ "$i" -eq 18 ]; then
    echo "Timeout waiting for pod to fail. Please check the pod status manually."
    oc get pods
    exit 1
fi

echo "Checking pod logs for permission error..."
if oc logs pod/$PODNAME | grep -q "Chef::Exceptions::InsufficientPermissions"; then
    echo "Confirmed: Pod logs show 'InsufficientPermissions' error as expected."
else
    echo "Warning: Could not automatically confirm 'InsufficientPermissions' in logs. Please check manually."
    oc logs pod/$PODNAME | tail -n 20
fi

# ---
# 3. Create a service account and assign the `anyuid` SCC to it.
# ---
echo "Logging in as 'admin' user..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 > /dev/null || { echo "Admin login failed"; exit 1; }

echo "Switching to 'appsec-scc' project as admin..."
oc project appsec-scc > /dev/null

echo "Verifying required SCC for the deployment..."
oc get deploy/gitlab -o yaml | oc adm policy scc-subject-review -f -

echo "Creating 'gitlab-sa' service account..."
oc create sa gitlab-sa

echo "Assigning 'anyuid' SCC to 'gitlab-sa'..."
oc adm policy add-scc-to-user anyuid -z gitlab-sa

# ---
# 4. Modify the `gitlab` application to use the new service account.
# ---
echo "Logging back in as 'developer' user..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Developer login failed"; exit 1; }

echo "Assigning 'gitlab-sa' service account to the 'gitlab' deployment..."
oc set serviceaccount deployment/gitlab gitlab-sa

echo "Waiting for the new 'gitlab' pod to be 'Running' (1/1)... (up to 5 minutes)"
# The deployment update will terminate the old pod and create a new one.
# We wait for the new pod (matching the 'app=gitlab' label) to be Ready.
if ! oc wait --for=condition=Ready pod -l app=gitlab --timeout=300s; then
    echo "Timeout waiting for the new gitlab pod to become Ready."
    echo "Current pod status:"
    oc get pods -l app=gitlab
    exit 1
fi
echo "New 'gitlab' pod is now 'Running' (1/1)."
oc get pods -l app=gitlab

# ---
# 5. Verify that the `gitlab` application works.
# ---
echo "Exposing the 'gitlab' service as a route..."
oc expose service/gitlab --port 80 --hostname gitlab.apps.ocp4.example.com

echo "Verifying route creation..."
oc get routes

echo "Testing the 'gitlab' application route..."
if curl -sL http://gitlab.apps.ocp4.example.com/ | grep -q '<title>Sign in · GitLab</title>'; then
    echo "Success: GitLab sign-in page loaded."
else
    echo "Error: Failed to retrieve the GitLab sign-in page. Please check the route and pod status."
    exit 1
fi

# ---
# 6. Delete the `appsec-scc` project.
# ---
echo "Deleting the 'appsec-scc' project..."
oc delete project appsec-scc
echo "Project 'appsec-scc' deleted."

echo "Exercise complete. Clean up if needed with 'lab finish appsec-scc'."
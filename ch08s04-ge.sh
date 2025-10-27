#!/bin/bash
# Script to perform the appsec-scc exercise as the student user.
# This script automates CLI-based steps for deploying an application
# that requires elevated privileges, handling the expected failure,
# and applying the correct SCC.
set -e # Exit on error

echo "Starting the appsec-scc exercise."
lab start appsec-scc || { echo "lab start command failed. Exiting."; exit 1; }
echo "Lab preparation complete."

---

echo "Step 1: Logging in as 'developer' and creating 'appsec-scc' project..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Login failed; check credentials or cluster availability."; exit 1; }
echo "Login as 'developer' successful."

oc new-project appsec-scc || echo "Project 'appsec-scc' may already exist. Continuing..."
echo "Now using project 'appsec-scc'."

---

echo "Step 2: Deploying 'gitlab' application (expected to fail initially)..."
oc new-app --name gitlab --image registry.ocp4.example.com:8443/redhattraining/gitlab-ce:8.4.3-ce.0
echo "Application creation initiated."

echo "Waiting for the 'gitlab' pod to enter 'Error' or 'CrashLoopBackOff' state..."

# This loop waits for the *expected failure*
POD_NAME=""
TIMEOUT_COUNT=0
while true; do
    # Try to find a pod that is not Running or Succeeded
    POD_NAME=$(oc get pods -l app=gitlab -o jsonpath='{.items[?(@.status.phase!="Running")].metadata.name}' | awk '{print $1}')
    
    if [ -z "$POD_NAME" ]; then
        echo "Waiting for a pod to be created..."
        sleep 5
        continue
    fi
    
    STATUS=$(oc get pod "$POD_NAME" -o jsonpath='{.status.phase}')
    # Check for container state reason if pod is 'Pending' or 'Running' (but container is not ready)
    REASON=$(oc get pod "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')
    
    if [ "$STATUS" == "Failed" ] || [ "$REASON" == "CrashLoopBackOff" ] || [ "$REASON" == "Error" ]; then
        echo "Pod $POD_NAME is in expected failed state (Status: $STATUS, Reason: $REASON)."
        break
    fi
    
    echo "Current pod status: $STATUS (Reason: $REASON). Waiting..."
    
    # Increment timeout counter
    TIMEOUT_COUNT=$((TIMEOUT_COUNT+1))
    
    if [ $TIMEOUT_COUNT -gt 24 ]; then # 24 * 5s = 120s (2 min) timeout
        echo "Timeout waiting for pod to fail."
        echo "Current pod status:"
        oc get pods -l app=gitlab
        echo
        echo "Please check the pod status manually."
        echo "1) Retry (wait another 2 minutes)"
        echo "2) Resume (continue script, may fail)"
        read -p "Enter option (1 or 2): " choice
        
        case $choice in
            1) TIMEOUT_COUNT=0; continue ;; # Retry
            2) echo "Resuming script..."; break ;; # Resume
            *) echo "Invalid option. Resuming script..."; break ;;
        esac
    fi
    
    sleep 5
done

echo "Confirming failure reason from logs..."
if [ -n "$POD_NAME" ]; then
    oc logs "pod/$POD_NAME" | grep "Chef::Exceptions::InsufficientPermissions" || echo "Could not find exact permission error in log, but pod failed as expected."
else
    echo "Could not find a failed pod to check logs."
fi

---

echo "Step 3: Logging in as 'admin' to manage SCCs..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 > /dev/null || { echo "Admin login failed."; exit 1; }
echo "Login as 'admin' successful."

echo "Switching to 'appsec-scc' project as admin..."
oc project appsec-scc > /dev/null

echo "Verifying required SCC for the 'gitlab' deployment..."
REVIEW_OUTPUT=$(oc get deploy/gitlab -o yaml | oc adm policy scc-subject-review -f -)
echo "$REVIEW_OUTPUT"
if ! echo "$REVIEW_OUTPUT" | grep -q "anyuid"; then
    echo "Warning: 'scc-subject-review' did not suggest 'anyuid'. Proceeding based on exercise instructions."
else
    echo "'anyuid' SCC is confirmed as appropriate."
fi

echo "Creating 'gitlab-sa' service account..."
oc create sa gitlab-sa || echo "Service account 'gitlab-sa' may already exist."

echo "Assigning 'anyuid' SCC to 'gitlab-sa'..."
oc adm policy add-scc-to-user anyuid -z gitlab-sa

---

echo "Step 4: Modifying 'gitlab' deployment to use 'gitlab-sa'..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Login as 'developer' failed."; exit 1; }
echo "Login as 'developer' successful."
oc project appsec-scc > /dev/null

echo "Assigning 'gitlab-sa' service account to 'gitlab' deployment..."
oc set serviceaccount deployment/gitlab gitlab-sa
echo "This will trigger a new deployment."

echo "Waiting for the new 'gitlab' deployment to complete..."
if ! oc rollout status deployment/gitlab --timeout=5m; then
     echo "Timeout waiting for 'gitlab' deployment to complete."
     oc get pods -l app=gitlab
     echo "Checking logs of any failing pods..."
     FAILED_PODS=$(oc get pods -l app=gitlab -o jsonpath='{.items[?(@.status.phase!="Running")].metadata.name}')
     for pod in $FAILED_PODS; do
        echo "--- Logs for $pod ---"
        oc logs "pod/$pod" || echo "Could not retrieve logs for $pod"
        echo "----------------------"
     done
     exit 1
fi

echo "'gitlab' deployment successful."
oc get pods -l app=gitlab

---

echo "Step 5: Verifying the 'gitlab' application..."
echo "Exposing the 'gitlab' service..."
oc expose service/gitlab --port 80 --hostname gitlab.apps.ocp4.example.com || echo "Route may already exist."

echo "Verifying route..."
oc get route gitlab

echo "Waiting for route to become available and testing application with curl..."
for i in {1..10}; do # 10 * 6s = 60s timeout
    if curl -sL http://gitlab.apps.ocp4.example.com/ | grep -q '<title>Sign in · GitLab</title>'; then
        echo "Verification successful: Found '<title>Sign in · GitLab</title>'"
        curl -sL http://gitlab.apps.ocp4.example.com/ | grep '<title>'
        break
    else
        echo "Application not yet responding... ($i/10)"
        sleep 6
    fi
    
    if [ $i -eq 10 ]; then
        echo "Timeout verifying application response. Please check the route manually."
        exit 1
    fi
done

---

echo "Step 6: Deleting the 'appsec-scc' project..."
oc delete project appsec-scc
echo "Project 'appsec-scc' deleted."

---

echo "Exercise complete. Clean up if needed with 'lab finish appsec-scc'."
#!/bin/bash

# Script to perform the selfservice-ranges exercise as the student user.
# This script uses oc CLI where possible to automate actions and verifications.
# For parts requiring the web UI (e.g., viewing metrics graphs), it will prompt and pause.
# Includes waits for resource readiness and logging of key steps.

set -e  # Exit on error

echo "Starting the exercise script. Ensure you are logged in as the student user on workstation."
echo "Running lab start command..."

lab start selfservice-ranges

echo "Lab preparation complete."

# Step 1-2: Log in to web console and create project.
# Since project creation can be done via CLI, automating it.
# But prompt for login if needed; assume oc is authenticated as admin-equivalent.

echo "Creating project 'selfservice-ranges' via CLI (equivalent to UI step)."
oc new-project selfservice-ranges || echo "Project already exists, continuing."

# Step 3: Create the example deployment.
echo "Creating deployment 'example' with image registry.access.redhat.com/ubi8/httpd-24."
oc create deployment example --image=registry.access.redhat.com/ubi8/httpd-24
# The UI defaults to 1 replica, but document shows 3 pods; scaling to 3 to match.
oc scale deployment/example --replicas=3

echo "Waiting for pods to be ready (up to 60s)..."
oc wait --for=condition=Ready pod -l app=example --timeout=60s || { echo "Timeout waiting for pods; check manually."; exit 1; }

# Step 4: Examine containers (verify no limits by default).
echo "Verifying no resource limits/requests by default."
POD_NAME=$(oc get pods -l app=example -o jsonpath='{.items[0].metadata.name}')
oc describe pod/$POD_NAME | grep -A 10 'Limits:' || true
echo "Above should show no Limits or Requests (or empty). If not, review output."

# Step 5: Create limit range.
echo "Creating LimitRange with default memory request 256Mi and limit 512Mi."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: core-limit-range
spec:
  limits:
  - default:
      memory: 512Mi
    defaultRequest:
      memory: 256Mi
    type: Container
EOF

# Wait a bit for limit range to apply (though it doesn't affect existing pods).
sleep 5

# Step 6: Examine original deployment (no changes).
echo "Verifying limit range did not affect existing pods."
oc describe pod/$POD_NAME | grep -A 10 'Limits:' || true
echo "Above should still show no Limits/Requests."

# Step 7: Delete deployment.
echo "Deleting deployment 'example'."
oc delete deployment/example

# Wait for deletion.
sleep 10

# Step 8: Recreate deployment.
echo "Recreating deployment 'example'."
oc create deployment example --image=registry.access.redhat.com/ubi8/httpd-24
oc scale deployment/example --replicas=3

echo "Waiting for new pods to be ready (up to 60s)..."
oc wait --for=condition=Ready pod -l app=example --timeout=60s || { echo "Timeout waiting for pods; check manually."; exit 1; }

# Step 9: Examine new containers (should have limits).
echo "Verifying new pods have resource limits/requests from LimitRange."
NEW_POD_NAME=$(oc get pods -l app=example -o jsonpath='{.items[0].metadata.name}')
oc describe pod/$NEW_POD_NAME | grep -A 10 'Limits:' || true
echo "Above should show Memory Limit: 512Mi and Request: 256Mi."

# Step 10: Examine deployment YAML.
echo "Examining deployment YAML (note: resources key is empty in spec)."
oc get deployment/example -o yaml | grep -A 20 'spec:' || true

# Step 11: Evaluate limit range with pod metrics.
# This requires web UI for graphs.
echo "CLI equivalent: Checking pod metrics with 'oc adm top'."
oc adm top pods -l app=example
echo "Note: Memory usage should be around 50MiB, vs request 256MiB and limit 512MiB."

echo "For full UI metrics view:"
echo "Please perform the following manually in the web UI:"
echo "1. Log in to https://console-openshift-console.apps.ocp4.example.com as admin/redhatocp."
echo "2. Go to Workloads > Pods, select a pod from 'example' deployment."
echo "3. Click Metrics tab and review Memory usage graph."
echo "Press Enter to continue the script after reviewing."
read -r

echo "Exercise complete. Clean up if needed with 'lab finish selfservice-ranges'."
#!/bin/bash
# Script to perform the [non-http-review] exercise as the student user.
# This script automates CLI-based steps and pauses for manual GUI verification.
# Includes waits for resource readiness and logging of key steps.
set -e # Exit on error

echo "Starting the non-http-review exercise."

# Prerequisite: Run lab start
echo "Running 'lab start non-http-review'..."
lab start non-http-review || { echo "Lab start failed. Please check the lab command."; exit 1; }
echo "Lab preparation complete."

# --- Step 1: Deploy virtual-rtsp application ---
echo "--- Step 1: Deploying virtual-rtsp ---"
echo "Logging in as developer..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Developer login failed."; exit 1; }

echo "Changing to lab directory..."
cd ~/DO280/labs/non-http-review

echo "Creating project 'non-http-review-rtsp'..."
oc new-project non-http-review-rtsp > /dev/null

echo "Creating 'virtual-rtsp' deployment from virtual-rtsp.yaml..."
oc create -f virtual-rtsp.yaml -n non-http-review-rtsp

echo "Waiting for 'virtual-rtsp' deployment to be ready (max 5 minutes)..."
oc wait --for=condition=Available --timeout=300s deployment/virtual-rtsp -n non-http-review-rtsp
echo "'virtual-rtsp' deployment is ready."

# --- Step 2: Expose virtual-rtsp deployment ---
echo "--- Step 2: Exposing virtual-rtsp as LoadBalancer ---"
echo "Exposing deployment 'virtual-rtsp' as LoadBalancer service..."
oc expose deployment/virtual-rtsp --name=virtual-rtsp-loadbalancer --type=LoadBalancer -n non-http-review-rtsp

echo "Waiting for LoadBalancer service to get external IP '192.168.50.20' (max 2 minutes)..."
EXTERNAL_IP=""
for i in {1..12}; do
  EXTERNAL_IP=$(oc get svc/virtual-rtsp-loadbalancer -n non-http-review-rtsp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  if [ "$EXTERNAL_IP" == "192.168.50.20" ]; then
    echo "External IP $EXTERNAL_IP acquired."
    break
  fi
  echo "Waiting... (Current: $EXTERNAL_IP)"
  sleep 10
done

if [ "$EXTERNAL_IP" != "192.168.50.20" ]; then
  echo "Timeout waiting for External IP. Current status:"
  oc get svc/virtual-rtsp-loadbalancer -n non-http-review-rtsp
  exit 1
fi

# --- Step 3: Access the application (Manual) ---
echo "--- Step 3: Accessing virtual-rtsp (Manual Verification) ---"
echo "Launching media player 'totem' to verify the stream."
echo "Please VERIFY the video stream, then CLOSE the media player window to continue the script."
totem rtsp://192.168.50.20:8554/stream
echo "Media player closed. Continuing script."

# --- Step 4: Deploy nginx application ---
echo "--- Step 4: Deploying nginx ---"
# Already logged in as developer
echo "Creating project 'non-http-review-nginx'..."
oc new-project non-http-review-nginx > /dev/null

echo "Deploying 'nginx' application from nginx.yaml..."
oc apply -f nginx.yaml -n non-http-review-nginx

echo "Waiting for 'nginx' deployment to be ready (max 5 minutes)..."
oc wait --for=condition=Available --timeout=300s deployment/nginx -n non-http-review-nginx
echo "'nginx' deployment is ready."

# --- Step 5: Configure NetworkAttachmentDefinition (NAD) ---
echo "--- Step 5: Configuring NetworkAttachmentDefinition ---"
echo "Logging in as admin..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 > /dev/null || { echo "Admin login failed."; exit 1; }

echo "Creating network-attachment-definition.yaml..."
cat <<EOF > network-attachment-definition.yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: custom
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "custom",
      "type": "host-device",
      "device": "ens4",
      "ipam": {
        "type": "static",
        "addresses": [
          {"address": "192.168.51.10/24"}
        ]
      }
    }
EOF

echo "Creating NetworkAttachmentDefinition 'custom'..."
# Use 'oc apply' for idempotency, though lab uses 'oc create'
oc apply -f network-attachment-definition.yaml
echo "NetworkAttachmentDefinition 'custom' created/updated."

# --- Step 6: Attach NAD to nginx pod ---
echo "--- Step 6: Attaching NAD to nginx ---"
echo "Logging in as developer..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Developer login failed."; exit 1; }

echo "Switching to 'non-http-review-nginx' project..."
oc project non-http-review-nginx > /dev/null

echo "Patching 'nginx' deployment to add network annotation..."
# This scripts the 'edit file and apply' step non-interactively
oc patch deployment/nginx -p '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"custom"}}}}}' -n non-http-review-nginx

echo "Waiting for 'nginx' deployment to redeploy with new annotation (max 5 minutes)..."
oc wait --for=condition=Available --timeout=300s deployment/nginx -n non-http-review-nginx
echo "'nginx' deployment is ready."

echo "Verifying network status on the new 'nginx' pod..."
# Wait a moment for the annotation to populate
sleep 5
POD_NAME=$(oc get pods -n non-http-review-nginx -l app=nginx -o jsonpath='{.items[0].metadata.name}')
echo "Checking pod: $POD_NAME"
oc get pod $POD_NAME -n non-http-review-nginx -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | jq .
echo
echo "Verifying IP '192.168.51.10' is present in network status..."
if ! oc get pod $POD_NAME -n non-http-review-nginx -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | grep -q "192.168.51.10"; then
  echo "ERROR: IP 192.168.51.10 not found in pod annotation!"
  exit 1
fi
echo "IP 192.168.51.10 successfully verified on pod."

# --- Step 7: Verify access from utility machine ---
echo "--- Step 7: Verifying access from 'utility' machine ---"
echo "Running 'curl http://192.168.51.10:8080/' from 'utility' via ssh..."
if ssh utility "curl -s 'http://192.168.51.10:8080/'" | grep -q "Hello, world from nginx!"; then
  echo "Verification from 'utility' machine SUCCEEDED."
else
  echo "Verification FAILED from 'utility' machine."
  exit 1
fi

# --- Step 8: Verify no access from workstation ---
echo "--- Step 8: Verifying (expected) lack of access from 'workstation' ---"
echo "Running 'curl http://192.168.51.10:8080/' from 'workstation' (expected to time out)..."
set +e # Don't exit on this expected failure
curl --connect-timeout 5 'http://192.168.51.10:8080/'
if [ $? -eq 0 ]; then
  echo "ERROR: Was able to connect from workstation, which is unexpected."
  set -e
  exit 1
else
  echo "Successfully failed to connect from workstation (as expected)."
fi
set -e # Re-enable exit on error

echo "Changing back to home directory..."
cd

echo
echo "Exercise complete. Clean up if needed with 'lab finish non-http-review'."
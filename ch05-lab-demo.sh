#!/bin/bash
# Script to perform the non-http-review exercise as the student user.
# This script automates CLI-based steps and pauses for manual verification where required.
# Includes waits for resource readiness and logging of key steps.
set -e

echo "Starting the non-http-review exercise."
# Infer exercise name from the lab file path
EXERCISE_NAME="non-http-review"
lab start ${EXERCISE_NAME} || { echo "lab start failed"; exit 1; }
echo "Lab preparation complete."

# --- Step 1: Deploy virtual-rtsp application ---
echo "---"
echo "Step 1: Deploying virtual-rtsp application"
echo "Logging in as developer..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Login as developer failed"; exit 1; }

echo "Changing to lab directory..."
mkdir -p ~/DO280/labs/non-http-review
cd ~/DO280/labs/non-http-review

echo "Creating project 'non-http-review-rtsp'..."
oc new-project non-http-review-rtsp > /dev/null

echo "Creating virtual-rtsp deployment from virtual-rtsp.yaml..."
oc create -f virtual-rtsp.yaml

echo "Waiting for virtual-rtsp deployment to be ready..."
oc wait --for=condition=Available deployment/virtual-rtsp --timeout=300s
echo "Waiting for virtual-rtsp pod to be Running..."
POD_NAME=$(oc get pods -l app=virtual-rtsp -o jsonpath='{.items[0].metadata.name}')
oc wait --for=condition=Ready pod/${POD_NAME} --timeout=300s
echo "virtual-rtsp deployment and pod are running."
oc get deployments,pods

# --- Step 2: Expose virtual-rtsp with LoadBalancer ---
echo "---"
echo "Step 2: Exposing virtual-rtsp with a LoadBalancer service"
oc expose deployment/virtual-rtsp --name=virtual-rtsp-loadbalancer --type=LoadBalancer

echo "Waiting for LoadBalancer to get external IP 192.168.50.20..."
EXTERNAL_IP=""
for i in {1..30}; do
  EXTERNAL_IP=$(oc get svc/virtual-rtsp-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ "$EXTERNAL_IP" == "192.168.50.20" ]; then
    echo "LoadBalancer service is ready with IP 192.168.50.20."
    break
  fi
  echo "Waiting for external IP (Attempt $i/30)..."
  sleep 10
done

if [ "$EXTERNAL_IP" != "192.168.50.20" ]; then
  echo "Error: LoadBalancer did not get the expected IP 192.168.50.20."
  oc get svc/virtual-rtsp-loadbalancer
  exit 1
fi
oc get svc/virtual-rtsp-loadbalancer

# --- Step 3: Access the rtsp stream (Manual GUI Step) ---
echo "---"
echo "Step 3: Accessing the rtsp stream"
echo "The script will now attempt to launch the Totem media player."
echo "Please verify the video stream appears, then CLOSE the Totem window."
totem rtsp://192.168.50.20:8554/stream &
echo "Press Enter to continue after closing the media player..."
read -r
# Clean up the background process
pkill totem || echo "Totem already closed."

# --- Step 4: Deploy nginx application ---
echo "---"
echo "Step 4: Deploying nginx application"
# User is already developer
echo "Creating project 'non-http-review-nginx'..."
oc new-project non-http-review-nginx > /dev/null

echo "Creating nginx deployment from nginx.yaml..."
oc apply -f nginx.yaml

echo "Waiting for nginx deployment to be ready..."
oc wait --for=condition=Available deployment/nginx --timeout=300s
echo "Waiting for nginx pod to be Running..."
POD_NAME=$(oc get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
oc wait --for=condition=Ready pod/${POD_NAME} --timeout=300s
echo "nginx deployment and pod are running."
oc get deployments,pods

# --- Step 5: Configure NetworkAttachmentDefinition (NAD) ---
echo "---"
echo "Step 5: Configuring NetworkAttachmentDefinition (NAD)"
echo "Logging in as admin..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 > /dev/null || { echo "Login as admin failed"; exit 1; }

echo "Creating network-attachment-definition.yaml..."
cd ~/DO280/labs/non-http-review
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

echo "Applying the NAD..."
oc create -f network-attachment-definition.yaml || echo "NAD 'custom' may already exist. Continuing."
echo "NAD 'custom' created."

# --- Step 6: Assign isolated network to nginx ---
echo "---"
echo "Step 6: Assigning isolated network to nginx"
echo "Logging in as developer..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Login as developer failed"; exit 1; }
oc project non-http-review-nginx > /dev/null

echo "Patching nginx deployment to add network annotation..."
# Patching the live deployment is more robust for automation than editing the file
oc patch deployment/nginx --type='merge' -p '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"custom"}}}}}'

echo "Waiting for new nginx pod to be ready (due to annotation update)..."
oc wait --for=condition=Available deployment/nginx --timeout=300s

echo "Waiting for new nginx pod to be Running..."
NEW_POD_NAME=""
for i in {1..30}; do
    # Get the first pod (which should be the new one after recreate)
    NEW_POD_NAME=$(oc get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
    STATUS=$(oc get pod ${NEW_POD_NAME} -o jsonpath='{.status.phase}')
    if [ "$STATUS" == "Running" ]; then
        oc wait --for=condition=Ready pod/${NEW_POD_NAME} --timeout=120s
        echo "New nginx pod ${NEW_POD_NAME} is running."
        break
    fi
    echo "Waiting for new pod to start (Attempt $i/30)..."
    sleep 5
done

if [ "$STATUS" != "Running" ]; then
    echo "Error: New nginx pod did not start."
    oc get pods
    exit 1
fi

echo "Verifying network status annotation on pod ${NEW_POD_NAME}..."
NETWORK_STATUS=$(oc get pod ${NEW_POD_NAME} -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}')
echo "${NETWORK_STATUS}"

if echo "${NETWORK_STATUS}" | grep -q "192.168.51.10"; then
    echo "Verification successful: Pod has IP 192.168.51.10."
else
    echo "Verification failed: Pod does not have IP 192.168.51.10."
    exit 1
fi

# --- Step 7: Verify access from 'utility' machine ---
echo "---"
echo "Step 7: Verifying access from 'utility' machine"
echo "Connecting to 'utility' via SSH and running curl..."
ssh utility "curl -s 'http://192.168.51.10:8080/'" | grep "Hello, world from nginx!"
echo "Access from 'utility' machine successful."

# --- Step 8: Verify no access from 'workstation' machine ---
echo "---"
echo "Step 8: Verifying *no* access from 'workstation' machine"
echo "Running curl, this is expected to fail with a timeout..."

if curl --connect-timeout 10 'http://192.168.51.10:8080/'; then
    echo "Error: Curl succeeded, but was expected to fail."
    exit 1
else
    RC=$?
    # 7 = Failed to connect, 28 = Operation timed out
    if [ ${RC} -eq 7 ] || [ ${RC} -eq 28 ]; then
        echo "Success: Curl failed with exit code ${RC} (timeout/connection failed) as expected."
    else
        echo "Warning: Curl failed with an unexpected error code ${RC}, but continuing."
    fi
fi

echo "Returning to home directory."
cd

echo "---"
echo "Exercise complete. Clean up if needed with 'lab finish ${EXERCISE_NAME}'."
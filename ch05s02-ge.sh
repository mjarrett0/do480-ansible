#!/bin/bash
# Script to perform the non-http-lb exercise as the student user.
# This script automates CLI-based steps and pauses for manual verification steps (VLC).
# Includes waits for resource readiness and logging of key steps.

set -e # Exit on error

# Helper function to wait for a LoadBalancer service to get an external IP
wait_for_ip() {
    local service_name=$1
    local namespace=$2
    local ip=""
    echo "Waiting for external IP for service '$service_name'..."
    for i in {1..30}; do # Timeout after 150 seconds (30 * 5s)
        ip=$(oc get svc "$service_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$ip" ] && [ "$ip" != "<pending>" ]; then
            echo "Service '$service_name' got external IP: $ip"
            echo "$ip"
            return 0
        fi
        sleep 5
    done
    echo "Error: Timeout waiting for external IP for service '$service_name'."
    oc get svc "$service_name" -n "$namespace"
    return 1
}

# Helper function to verify a LoadBalancer service is <pending>
# This is expected when the IP pool is exhausted
verify_pending_ip() {
    local service_name=$1
    local namespace=$2
    local ip=""
    echo "Verifying service '$service_name' remains <pending> (this is expected)..."
    
    # Give the load balancer controller a moment to process
    sleep 10 

    for i in {1..6}; do # Check for 30 seconds (6 * 5s)
        ip=$(oc get svc "$service_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$ip" ] && [ "$ip" != "<pending>" ]; then
            echo "Error: Service '$service_name' received an IP ($ip) unexpectedly."
            echo "The exercise expects this service to be <pending> due to IP pool exhaustion."
            return 1
        fi
        echo "($i/6) Service '$service_name' is still pending..."
        sleep 5
    done
    
    echo "Verified: Service '$service_name' is <pending> as expected."
    return 0
}


echo "Starting the 'non-http-lb' exercise."

# Prerequisite: Run lab start
echo "Running 'lab start non-http-lb'..."
lab start non-http-lb
echo "Lab preparation complete."

# Step 1: Log in as developer
echo "Logging in as 'developer' user..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Login failed; check credentials or cluster availability."; exit 1; }
echo "Login successful."

# Step 2: Change to the lab directory
echo "Changing to '~/DO280/labs/non-http-lb' directory..."
cd ~/DO280/labs/non-http-lb
echo "Current directory: $(pwd)"

# Step 3: Deploy the first instance (virtual-rtsp-1)
echo "--- Step 3: Deploying virtual-rtsp-1 ---"

# a. Create project
echo "Creating 'non-http-lb' project..."
oc new-project non-http-lb

# b. Create deployment
echo "Applying 'virtual-rtsp-1.yaml'..."
oc apply -f virtual-rtsp-1.yaml

# c. Wait for deployment to be ready
echo "Waiting for 'virtual-rtsp-1' deployment to be available..."
oc wait --for=condition=Available --timeout=180s deployment/virtual-rtsp-1 -n non-http-lb
echo "Deployment 'virtual-rtsp-1' is ready."

# d. Expose service
echo "Exposing 'virtual-rtsp-1' as a LoadBalancer service..."
oc expose deployment/virtual-rtsp-1 --type=LoadBalancer --target-port=8554 -n non-http-lb

# e. Get external IP
IP1=$(wait_for_ip virtual-rtsp-1 non-http-lb)
if [ -z "$IP1" ]; then
    echo "Failed to get IP for virtual-rtsp-1. Exiting."
    exit 1
fi

# f. Verify connection
echo "Verifying connection to $IP1:8554..."
nc -vz "$IP1" 8554

# g. Manual step: View stream
echo "---"
echo "MANUAL STEP: Please open VLC media player and view the stream at:"
echo "rtsp://$IP1:8554/stream"
echo "This should be the 'downtown' camera."
echo "Press Enter to continue after confirming the stream."
read -r
echo "---"

# Step 4: Deploy remaining instances
echo "--- Step 4: Deploying virtual-rtsp-2 and virtual-rtsp-3 ---"

# a. Create second deployment
echo "Applying 'virtual-rtsp-2.yaml'..."
oc apply -f virtual-rtsp-2.yaml

# b. Create third deployment
echo "Applying 'virtual-rtsp-3.yaml'..."
oc apply -f virtual-rtsp-3.yaml

# c. Wait for deployments
echo "Waiting for 'virtual-rtsp-2' deployment to be available..."
oc wait --for=condition=Available --timeout=180s deployment/virtual-rtsp-2 -n non-http-lb
echo "Deployment 'virtual-rtsp-2' is ready."

echo "Waiting for 'virtual-rtsp-3' deployment to be available..."
oc wait --for=condition=Available --timeout=180s deployment/virtual-rtsp-3 -n non-http-lb
echo "Deployment 'virtual-rtsp-3' is ready."

# d. Expose second service
echo "Exposing 'virtual-rtsp-2' as a LoadBalancer service..."
oc expose deployment/virtual-rtsp-2 --type=LoadBalancer --target-port=8554 -n non-http-lb

# e. Expose third service
echo "Exposing 'virtual-rtsp-3' as a LoadBalancer service..."
oc expose deployment/virtual-rtsp-3 --type=LoadBalancer --target-port=8554 -n non-http-lb

# f. Get IP for rtsp-2 and verify rtsp-3 is pending
IP2=$(wait_for_ip virtual-rtsp-2 non-http-lb)
if [ -z "$IP2" ]; then
    echo "Failed to get IP for virtual-rtsp-2. Exiting."
    exit 1
fi

verify_pending_ip virtual-rtsp-3 non-http-lb
if [ $? -ne 0 ]; then
    echo "Verification failed. Exiting."
    exit 1
fi

echo "Current service status:"
oc get services -n non-http-lb

# g. Manual step: View second stream
echo "---"
echo "MANUAL STEP: Please open VLC media player and view the stream at:"
echo "rtsp://$IP2:8554/stream"
echo "This should be the 'roundabout' camera."
echo "Press Enter to continue after confirming the stream."
read -r
echo "---"

# Step 5: Reallocate IP address
echo "--- Step 5: Reallocating IP address ---"

# a. Delete first service
echo "Deleting 'virtual-rtsp-1' service to release its IP ($IP1)..."
oc delete service/virtual-rtsp-1 -n non-http-lb

# b. Verify rtsp-3 gets the IP
echo "Waiting for 'virtual-rtsp-3' to acquire the released IP..."
IP3=$(wait_for_ip virtual-rtsp-3 non-http-lb)
if [ -z "$IP3" ]; then
    echo "Failed to get IP for virtual-rtsp-3. Exiting."
    exit 1
fi

echo "Service 'virtual-rtsp-3' acquired IP: $IP3"
echo "Current service status:"
oc get services -n non-http-lb

# c. Manual step: View third stream
echo "---"
echo "MANUAL STEP: Please open VLC media player and view the stream at:"
echo "rtsp://$IP3:8554/stream"
echo "This should be the 'intersection' camera."
echo "Press Enter to continue after confirming the stream."
read -r
echo "---"

# Step 6: Clean up
echo "--- Step 6: Cleaning up resources ---"

# a. Change to home directory
echo "Changing to home directory..."
cd

# b. Delete all services
echo "Deleting all services in 'non-http-lb' project..."
oc delete services --all -n non-http-lb

# c. Delete all deployments
echo "Deleting all deployments in 'non-http-lb' project..."
oc delete deployments --all -n non-http-lb

# d. Delete project
echo "Deleting 'non-http-lb' project..."
oc delete project non-http-lb

echo "Exercise complete. Clean up if needed with 'lab finish non-http-lb'."
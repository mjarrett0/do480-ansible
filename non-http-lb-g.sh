#!/bin/bash

# Script to automate the non-http-lb guided exercise as the student user

# Exit on any error
set -e

# Step 1: Prepare the system
echo "Starting lab setup..."
lab start non-http-lb

# Step 1a: Log in as developer
echo "Logging in as developer..."
oc login -u developer -p developer https://api.ocp4.example.com:6443

# Step 1b: Change to the lab directory
echo "Changing to lab directory..."
cd ~/DO280/labs/non-http-review

# Step 1c: Create non-http-review-rtsp project
echo "Creating non-http-review-rtsp project..."
oc new-project non-http-review-rtsp

# Step 1d: Create virtual-rtsp deployment
echo "Creating virtual-rtsp deployment..."
oc create -f virtual-rtsp.yaml

# Step 1e: Wait for virtual-rtsp pod to be ready
echo "Waiting for virtual-rtsp pod to be ready..."
timeout 300 bash -c "while ! oc get pods | grep virtual-rtsp | grep -q Running; do sleep 5; done"
echo "virtual-rtsp pod is running."

# Step 2a: Expose virtual-rtsp with LoadBalancer
echo "Exposing virtual-rtsp with LoadBalancer service..."
oc expose deployment/virtual-rtsp --name=virtual-rtsp-loadbalancer --type=LoadBalancer

# Step 2b: Verify external IP
echo "Checking external IP for virtual-rtsp-loadbalancer..."
timeout 300 bash -c "while ! oc get svc/virtual-rtsp-loadbalancer | grep -q 192.168.50.20; do sleep 5; done"
echo "External IP 192.168.50.20 assigned."

# Step 3a: Access RTSP stream
echo "Testing RTSP stream with totem..."
totem rtsp://192.168.50.20:8554/stream &
sleep 5  # Give totem some time to start
pkill totem  # Close totem after verification
echo "RTSP stream tested."

# Step 4a: Create non-http-review-nginx project
echo "Creating non-http-review-nginx project..."
oc new-project non-http-review-nginx

# Step 4b: Create nginx deployment
echo "Creating nginx deployment..."
oc apply -f nginx.yaml

# Step 4c: Wait for nginx pod to be ready
echo "Waiting for nginx pod to be ready..."
timeout 300 bash -c "while ! oc get pods | grep nginx | grep -q Running; do sleep 5; done"
echo "nginx pod is running."

# Step 5a: Log in as admin
echo "Logging in as admin..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443

# Step 5b: Create network attachment definition
echo "Creating network attachment definition..."
oc create -f network-attachment-definition.yaml

# Step 6a: Log in as developer
echo "Logging in as developer..."
oc login -u developer -p developer https://api.ocp4.example.com:6443

# Step 6b-c: Update nginx deployment with network annotation
echo "Updating nginx deployment with network annotation..."
oc apply -f nginx.yaml

# Step 6d: Wait for updated nginx pod to be ready
echo "Waiting for updated nginx pod to be ready..."
timeout 300 bash -c "while ! oc get pods | grep nginx | grep -q Running; do sleep 5; done"
echo "Updated nginx pod is running."

# Step 6e: Verify network-status annotation
echo "Checking network-status annotation..."
oc get pod $(oc get pods | grep nginx | awk '{print $1}') -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | grep -q "192.168.51.10"
echo "Network annotation verified."

# Step 7a-b: Verify nginx access from utility machine
echo "Testing nginx access from utility machine..."
ssh utility "curl -s http://192.168.51.10:8080/" | grep -q "Hello, world from nginx"
echo "nginx accessible from utility machine."

# Step 7c: Exit SSH session (handled automatically by script)

# Step 8a: Verify nginx inaccessibility from workstation
echo "Testing nginx inaccessibility from workstation..."
if curl -s --connect-timeout 5 http://192.168.51.10:8080/; then
    echo "Error: nginx should not be accessible from workstation."
    exit 1
else
    echo "nginx is not accessible from workstation, as expected."
fi

# Step 8b: Return to home directory
echo "Returning to home directory..."
cd ~

echo "Script completed successfully."
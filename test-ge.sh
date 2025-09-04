#!/bin/bash

# Script to automate the deployment and verification of a MySQL database server in OpenShift 4.18
# Run this as the student user on the workstation machine after running 'lab start deploy-services'

# Step 1: Log in to the OpenShift cluster
oc login -u developer -p developer https://api.ocp4.example.com:6443

# Step 1.1: Set the deploy-services project as active
oc project deploy-services

# Step 2: Create the db-pod deployment
oc create deployment db-pod --port 3306 --image registry.ocp4.example.com:8443/rhel8/mysql-80

# Step 2.1: Add environment variables
oc set env deployment/db-pod MYSQL_USER=user1 MYSQL_PASSWORD=mypa55w0rd MYSQL_DATABASE=items

# Step 2.2: Confirm the pod is running (wait a bit for it to start)
sleep 30
oc get pods

# Step 2.3: View the deployment
oc get deployment

# Step 3: Expose the deployment to create a ClusterIP service
oc expose deployment/db-pod

# Step 3.2: Validate the service
oc get service db-pod -o wide

# Step 4: Identify the selector
# Already shown in previous command

# Step 4.1: Capture pod name in a variable
PODNAME=$(oc get pods -o jsonpath='{.items[0].metadata.name}')

# Step 4.2: Query the label on the pod
oc get pod $PODNAME --show-labels

# Step 4.3: Retrieve endpoints
oc get endpoints db-pod

# Step 4.4: Verify pod IP
oc get pods -o wide

# Step 5: Delete and re-create the deployment
oc delete deployment/db-pod

# Step 5.1: Verify service still exists
oc get service

# Step 5.2: Confirm endpoints empty
oc get endpoints db-pod

# Step 5.3: Re-create deployment
oc create deployment db-pod --port 3306 --image registry.ocp4.example.com:8443/rhel8/mysql-80

# Step 5.4: Add environment variables again
oc set env deployment/db-pod MYSQL_USER=user1 MYSQL_PASSWORD=mypa55w0rd MYSQL_DATABASE=items

# Step 5.5: Confirm new pod has selector (wait a bit)
sleep 30
oc get pods --selector app=db-pod -o wide

# Step 5.6: Confirm endpoints updated
oc get endpoints db-pod

# Step 6: Create a pod to identify DNS names
oc run shell --image registry.ocp4.example.com:8443/openshift4/network-tools-rhel8 --restart=Never --rm -it -- /bin/bash -c "cat /etc/resolv.conf"

# Step 6.2: Test DNS with nc (run in a new pod for simplicity)
oc run shell --image registry.ocp4.example.com:8443/openshift4/network-tools-rhel8 --restart=Never --rm -it -- /bin/bash -c "nc -z db-pod.deploy-services 3306 && echo 'Connection success to db-pod.deploy-services:3306' || echo 'Connection failed'"

# No need for exit and delete as --rm handles it

# Step 7: Test from another namespace
oc new-project deploy-services-2

# Step 7.1: Test DNS from new namespace
oc run shell --image registry.ocp4.example.com:8443/openshift4/network-tools-rhel8 --restart=Never --rm -it -- /bin/bash -c "nc -z db-pod.deploy-services.svc.cluster.local 3306 && echo 'Connection success to db-pod.deploy-services.svc.cluster.local:3306' || echo 'Connection failed'"

# Step 7.2: Return to original project
oc project deploy-services

# Step 8: Create job to initialize database
oc create job mysql-init --image registry.ocp4.example.com:8443/redhattraining/do180-dbinit:v1 -- /bin/bash -c "mysql -uuser1 -pmypa55w0rd --protocol tcp -h db-pod -P3306 items"

# Wait for job to complete
sleep 60
oc get jobs
oc logs job/mysql-init

#!/bin/bash
# Script to perform the auth-rbac exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e # Exit on error

echo "Starting the auth-rbac exercise."

# Prerequisite: Prepare the system
echo "Preparing the system with 'lab start auth-rbac'..."
lab start auth-rbac
echo "Lab preparation complete."

# --- Step 1: Log in and determine self-provisioner cluster role bindings ---

echo "## 1. Log in to the OpenShift cluster and determine self-provisioner cluster role bindings"

# 1a. Log in as admin
echo "1a. Logging in to the cluster as the 'admin' user..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 || { echo "Login as 'admin' failed; check credentials or cluster availability."; exit 1; }

# 1b. List all cluster role bindings that reference the 'self-provisioner' cluster role
echo "1b. Listing cluster role bindings that reference 'self-provisioner'..."
oc get clusterrolebinding -o wide | grep -E 'ROLE|self-provisioner'

# --- Step 2: Remove the privilege to create projects ---

echo "## 2. Remove the privilege to create projects for non-cluster administrators"

# 2a. Confirm the self-provisioners cluster role binding
echo "2a. Describing the 'self-provisioners' cluster role binding..."
oc describe clusterrolebindings self-provisioners

# 2b. Remove the 'self-provisioner' cluster role from the 'system:authenticated:oauth' virtual group
echo "2b. Removing 'self-provisioner' cluster role from 'system:authenticated:oauth' group..."
oc adm policy remove-cluster-role-from-group self-provisioner system:authenticated:oauth
# NOTE: Safely ignore the warning about changes being lost.

# 2c. Verify that the role is removed (the cluster role binding should not exist)
echo "2c. Verifying removal of 'self-provisioners' cluster role binding (expecting NotFound error)..."
if oc describe clusterrolebindings self-provisioners 2>&1 | grep -q 'NotFound'; then
  echo "Verification successful: clusterrolebindings.rbac.authorization.k8s.io 'self-provisioners' not found."
else
  echo "Verification failed: 'self-provisioners' cluster role binding still exists."
  # Non-fatal error here to continue the script, but log the issue
fi

# 2d. Determine whether any other cluster role bindings reference the 'self-provisioner' cluster role
echo "2d. Checking for any remaining cluster role bindings referencing 'self-provisioner'..."
oc get clusterrolebinding -o wide | grep -E 'ROLE|self-provisioner'

# 2e. Log in as the 'leader' user
echo "2e. Logging in as the 'leader' user..."
oc login -u leader -p redhat || { echo "Login as 'leader' failed; check credentials."; exit 1; }

# 2f. Try to create a project (Operation should fail)
echo "2f. Attempting to create a new project 'test' as 'leader' (expecting Forbidden error)..."
if oc new-project test 2>&1 | grep -q 'Forbidden'; then
  echo "Verification successful: Project creation failed as expected."
else
  echo "Verification failed: Project creation did NOT fail as expected."
  # Non-fatal error here
fi

# --- Step 3: Create a project and add project administration privileges to leader user ---

echo "## 3. Create a project and add project administration privileges to the 'leader' user"

# 3a. Log in as the 'admin' user
echo "3a. Logging in as the 'admin' user..."
oc login -u admin -p redhatocp || { echo "Login as 'admin' failed; check credentials."; exit 1; }

# 3b. Create the 'auth-rbac' project
echo "3b. Creating the 'auth-rbac' project..."
oc new-project auth-rbac || echo "Project 'auth-rbac' already exists, continuing."

# 3c. Grant project administration privileges to the 'leader' user
echo "3c. Granting 'admin' role to 'leader' user on 'auth-rbac' project..."
oc policy add-role-to-user admin leader

# --- Step 4: Create groups and add members ---

echo "## 4. Create the 'dev-group' and 'qa-group' groups and add their respective members"

# 4a. Create a group named 'dev-group'
echo "4a. Creating group 'dev-group'..."
oc adm groups new dev-group || echo "Group 'dev-group' already exists, continuing."

# 4b. Add the 'developer' user to 'dev-group'
echo "4b. Adding 'developer' user to 'dev-group'..."
oc adm groups add-users dev-group developer

# 4c. Create a second group named 'qa-group'
echo "4c. Creating group 'qa-group'..."
oc adm groups new qa-group || echo "Group 'qa-group' already exists, continuing."

# 4d. Add the 'qa-engineer' user to 'qa-group'
echo "4d. Adding 'qa-engineer' user to 'qa-group'..."
oc adm groups add-users qa-group qa-engineer

# 4e. Review all existing OpenShift groups
echo "4e. Reviewing all existing OpenShift groups..."
oc get groups

# --- Step 5: Assign privileges as leader user ---

echo "## 5. As the 'leader' user, assign write and read privileges to groups on 'auth-rbac' project"

# 5a. Log in as the 'leader' user
echo "5a. Logging in as the 'leader' user and switching to 'auth-rbac' project..."
oc login -u leader -p redhat
oc project auth-rbac

# 5b. Add write privileges (edit role) to the 'dev-group'
echo "5b. Adding 'edit' role (write privileges) to 'dev-group'..."
oc policy add-role-to-group edit dev-group

# 5c. Add read privileges (view role) to the 'qa-group'
echo "5c. Adding 'view' role (read privileges) to 'qa-group'..."
oc policy add-role-to-group view qa-group

# 5d. Review all role bindings on the 'auth-rbac' project
echo "5d. Reviewing all non-system role bindings on the 'auth-rbac' project..."
oc get rolebindings -o wide | grep -v '^system:'

# --- Step 6: Verify developer user write privileges (and no admin privileges) ---

echo "## 6. Verify 'developer' user write privileges"

# 6a. Log in as the 'developer' user
echo "6a. Logging in as the 'developer' user and switching to 'auth-rbac' project..."
oc login -u developer -p developer
oc project auth-rbac

# 6b. Deploy an Apache HTTP Server (Test write privilege)
echo "6b. Deploying an Apache HTTP Server 'httpd:2.4' (Test write privilege)..."
oc new-app --name httpd httpd:2.4
echo "Waiting for 'httpd' deployment to be ready..."
# The success output indicates creation, so a brief wait is enough for the script flow
sleep 5
oc get deployment httpd

# 6c. Try to grant write privileges to the 'qa-engineer' user (Test no admin privilege)
echo "6c. Attempting to grant 'edit' role to 'qa-engineer' (Test no admin privilege, expecting Forbidden error)..."
if oc policy add-role-to-user edit qa-engineer 2>&1 | grep -q 'Forbidden'; then
  echo "Verification successful: Role binding failed as expected (no admin privilege)."
else
  echo "Verification failed: Role binding succeeded, contrary to expectation."
  # Non-fatal error here
fi

# --- Step 7: Verify qa-engineer user view privileges (and no modify privileges) ---

echo "## 7. Verify 'qa-engineer' user view privileges"

# 7a. Log in as the 'qa-engineer' user
echo "7a. Logging in as the 'qa-engineer' user and switching to 'auth-rbac' project..."
oc login -u qa-engineer -p redhat
oc project auth-rbac

# 7b. Attempt to scale the 'httpd' application (Test no modify privilege)
echo "7b. Attempting to scale 'httpd' deployment to 3 replicas (Test no modify privilege, expecting Forbidden error)..."
if oc scale deployment httpd --replicas 3 2>&1 | grep -q 'Forbidden'; then
  echo "Verification successful: Scaling failed as expected (no modify privilege)."
else
  echo "Verification failed: Scaling succeeded, contrary to expectation."
  # Non-fatal error here
fi
echo "The 'qa-engineer' user can view resources but cannot modify them (e.g., oc get all)."
oc get all

# --- Step 8: Restore project creation privileges to all users ---

echo "## 8. Restore project creation privileges to all users"

# 8a. Log in as the 'admin' user
echo "8a. Logging in as the 'admin' user..."
oc login -u admin -p redhatocp || { echo "Login as 'admin' failed; check credentials."; exit 1; }

# 8b. Restore project creation privileges
echo "8b. Restoring 'self-provisioners' cluster role binding for project creation..."
# NOTE: Safely ignore the warning that the group was not found.
oc adm policy add-cluster-role-to-group \
  --rolebinding-name self-provisioners \
  self-provisioner system:authenticated:oauth

echo "Exercise complete. Clean up if needed with 'lab finish auth-rbac'."
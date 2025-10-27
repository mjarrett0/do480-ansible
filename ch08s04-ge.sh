#!/bin/bash
# Script to perform the appsec-api exercise as the student user.
# This script automates CLI-based steps, including logging in, modifying
# YAML files, and granting permissions.
# It pauses for the 'watch' command and continues after the user exits.
set -e # Exit on error

# Inferring lab name from project name
LAB_NAME="appsec-api"

echo "Starting the $LAB_NAME exercise."
lab start $LAB_NAME || { echo "lab start command failed. Exiting."; exit 1; }
echo "Lab preparation complete."

---

echo "Step 1: Changing to the lab directory..."
cd ~/DO280/labs/$LAB_NAME || { echo "Failed to change to lab directory."; exit 1; }
echo "Current directory: $(pwd)"

---

echo "Step 2: Logging in as 'admin' and switching to 'configmap-reloader' project..."
oc login -u admin -p redhatocp https://api.ocp4.example.com:6443 > /dev/null || { echo "Admin login failed."; exit 1; }
echo "Login as 'admin' successful."
oc project configmap-reloader

---

echo "Step 3: Creating SA and updating 'configmap-reloader' deployment..."
oc create sa configmap-reloader-sa || echo "Service account 'configmap-reloader-sa' may already exist. Continuing."

echo "Modifying reloader-deployment.yaml to add serviceAccountName..."
# This sed command inserts the serviceAccountName line right before the 'containers:' line
# It's idempotent; if the line already exists, grep prevents it from running.
if ! grep -q "serviceAccountName: configmap-reloader-sa" reloader-deployment.yaml; then
    sed -i '/containers:/i \      serviceAccountName: configmap-reloader-sa' reloader-deployment.yaml
    echo "File modified."
else
    echo "File already contains serviceAccountName."
fi

echo "Applying 'reloader-deployment.yaml'..."
oc apply -f reloader-deployment.yaml

echo "Waiting for 'configmap-reloader' deployment to be ready..."
if ! oc rollout status deployment/configmap-reloader --timeout=5m; then
    echo "Timeout waiting for 'configmap-reloader' deployment."
    oc get pods
    exit 1
fi
echo "Deployment 'configmap-reloader' is ready."

---

echo "Step 4: Logging in as 'developer' and creating 'appsec-api' project..."
oc login -u developer -p developer https://api.ocp4.example.com:6443 > /dev/null || { echo "Login as 'developer' failed."; exit 1; }
echo "Login as 'developer' successful."
oc new-project $LAB_NAME || echo "Project '$LAB_NAME' may already exist. Continuing..."

---

echo "Step 5: Granting 'edit' role to 'configmap-reloader-sa' in '$LAB_NAME' project..."
oc policy add-role-to-user edit \
   system:serviceaccount:configmap-reloader:configmap-reloader-sa \
   --rolebinding-name=reloader-edit \
   -n $LAB_NAME
echo "Role binding 'reloader-edit' created."

---

echo "Step 6: Installing the 'config-app' API..."
oc apply -f ./config-app

echo "Waiting for 'config-app' deployment to be ready..."
if ! oc rollout status deployment/config-app -n $LAB_NAME --timeout=3m; then
    echo "Timeout waiting for 'config-app' deployment."
    oc get pods -n $LAB_NAME
    exit 1
fi
echo "'config-app' deployment is ready."

echo "Verifying initial config map content:"
oc get configmap config-app -n $LAB_NAME --output="jsonpath={.data.config\.yaml}"
echo ""

echo "Verifying API endpoint..."
APP_URL="https://config-app-appsec-api.apps.ocp4.example.com/config"
for i in {1..15}; do
    # Use -s for silent
    if curl -s $APP_URL | jq . > /dev/null 2>&1; then
        echo "Route is responsive. Current config:"
        curl -s $APP_URL | jq
        break
    else
        echo "Waiting for route... ($i/15)"
        sleep 5
    fi
    if [ $i -eq 15 ]; then
        echo "Timeout waiting for $APP_URL. Check pods and routes."
        exit 1
    fi
done

---

echo "Step 7: Updating 'config-app' configmap and watching for reload..."
echo "Modifying config-app/configmap.yaml..."
# Change description from "config-app" to "API that exposes its configuration"
sed -i 's/description: "config-app"/description: "API that exposes its configuration"/' config-app/configmap.yaml
echo "File modified."

echo "Applying modified configmap..."
oc apply -f config-app/configmap.yaml

echo ""
echo "--- WATCHING FOR CHANGES ---"
echo "The 'watch' command will now start."
echo "Wait until you see the 'description' change to 'API that exposes its configuration'."
echo "This confirms the reloader is working."
echo ""
echo "==> PRESS Ctrl+C TO EXIT 'watch' AND CONTINUE THE SCRIPT. <=="
echo ""

# Run watch, and use '|| true' to ensure that Ctrl+C (which returns non-zero)
# does not trigger 'set -e' and kill the script.
watch "curl -s https://config-app-appsec-api.apps.ocp4.example.com/config | jq" || true

echo ""
echo "'watch' command exited. Resuming script."

---

echo "Step 8: Changing back to home directory..."
cd
echo "Now in home directory: $(pwd)"

---

echo "Exercise complete. Clean up if needed with 'lab finish $LAB_NAME'."
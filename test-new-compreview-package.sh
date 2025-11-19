#!/bin/bash
# Script to perform the Graded Exercise: Managing Etherpad with Helm and Kustomize Overlays exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e  # Exit on error

EXERCISE_NAME="compreview-package"
CLUSTER_API="https://api.ocp4.example.com:6443"
DEVELOPER_USER="developer"
DEVELOPER_PASS="developer"

echo "Starting the Graded Exercise: Managing Etherpad with Helm and Kustomize Overlays exercise."
lab start $EXERCISE_NAME
echo "Lab preparation complete."

# --- Step 1: Add the classroom Helm repo and verify versions ---
echo "## 1. Adding the classroom Helm repo and verifying versions..."
helm repo add classroom http://helm.ocp4.example.com/charts
helm repo update
[cite_start]helm search repo classroom/etherpad --versions   # must show 0.0.6 and 0.0.7 [cite: 1]
echo "Helm repo configured and versions verified."

# --- Step 2: Log in as developer ---
echo "## 2. Logging in as $DEVELOPER_USER..."
oc login -u $DEVELOPER_USER -p $DEVELOPER_PASS $CLUSTER_API || { echo "Login failed; check credentials or cluster availability."; exit 1; [cite_start]} [cite: 2]
echo "Logged in as $DEVELOPER_USER."

# --- Step 3: Development deployment (pure Helm) ---
echo "## 3. Performing Development deployment (pure Helm)..."

DEV_VALUES_FILE="dev-values.yaml"
cat <<EOF > $DEV_VALUES_FILE
image:
  repository: registry.ocp4.example.com:8443/etherpad
  name: etherpad
  tag: 1.8.18
route:
  host: etherpad-dev.apps.ocp4.example.com
EOF
echo "Created $DEV_VALUES_FILE."

DEV_PROJECT="etherpad-dev"
echo "Creating project $DEV_PROJECT..."
oc new-project $DEV_PROJECT

echo "Installing Helm release 'dev' (v0.0.6)..."
helm install dev classroom/etherpad --version 0.0.6 -f $DEV_VALUES_FILE -n $DEV_PROJECT

echo "Waiting for Deployment/dev-etherpad to be ready..."
oc wait --for=condition=Available deployment/dev-etherpad -n $DEV_PROJECT --timeout=120s

echo "Upgrading Helm release 'dev' (v0.0.7)..."
helm upgrade dev classroom/etherpad --version 0.0.7 -f $DEV_VALUES_FILE -n $DEV_PROJECT

echo "Waiting for Deployment/dev-etherpad to be ready after upgrade..."
oc wait --for=condition=Available deployment/dev-etherpad -n $DEV_PROJECT --timeout=120s

echo "Verifying deployment (opens browser - manual check required)..."
echo "URL: https://etherpad-dev.apps.ocp4.example.com"
[cite_start]open https://etherpad-dev.apps.ocp4.example.com   # must work [cite: 3]
echo "Press Enter to continue after verifying the application is working in your browser."
read -r

# --- Step 4: Production initial deployment (Helm only) ---
echo "## 4. Performing Production initial deployment (Helm only)..."

PROD_VALUES_FILE="prod-values.yaml"
cat <<EOF > $PROD_VALUES_FILE
image:
  repository: registry.ocp4.example.com:8443/etherpad
  name: etherpad
  tag: 1.8.18
route:
  host: etherpad-prod.apps.ocp4.example.com
replicaCount: 3
EOF
echo "Created $PROD_VALUES_FILE."

PROD_PROJECT="etherpad-prod"
echo "Creating project $PROD_PROJECT..."
oc new-project $PROD_PROJECT

echo "Installing Helm release 'prod' (v0.0.7)..."
helm install prod classroom/etherpad --version 0.0.7 -f $PROD_VALUES_FILE -n $PROD_PROJECT

echo "Waiting for Deployment/prod-etherpad to have 3 replicas..."
# Wait for the deployment to become ready with the expected replica count
oc wait --for=jsonpath='{.status.readyReplicas}'=3 deployment/prod-etherpad -n $PROD_PROJECT --timeout=180s

echo "Verifying pod count (must be exactly 3 pods):"
[cite_start]oc get pods -n $PROD_PROJECT   # 3 pods [cite: 4]

# --- Step 5: Switch to Kustomize for day-2 operations ---
echo "## 5. Switching to Kustomize for day-2 operations..."

KUSTOMIZE_DIR="kustomize-prod"
BASE_DIR="$KUSTOMIZE_DIR/base"
OVERLAY_DIR="$KUSTOMIZE_DIR/overlay"
MANIFESTS_FILE="$BASE_DIR/manifests.yaml"

echo "Extracting current Helm manifests as base..."
mkdir -p $BASE_DIR
helm get manifest prod -n $PROD_PROJECT > $MANIFESTS_FILE
echo "Manifests extracted to $MANIFESTS_FILE."

echo "Creating overlay directory and kustomization.yaml..."
mkdir -p $OVERLAY_DIR

cat <<EOF > $OVERLAY_DIR/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base/manifests.yaml
commonLabels:
  app.kubernetes.io/environment: production
commonAnnotations:
  managed-by: kustomize-gitops
patches:
  - target:
      kind: Deployment
      name: prod-etherpad
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 6
  - target:
      kind: Deployment
      name: prod-etherpad
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/resources
        value:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
  - target:
      kind: Route
      name: prod-etherpad
    patch: |-
      - op: replace
        path: /spec/tls
        value:
          termination: edge
          insecureEdgeTerminationPolicy: Redirect
  - path: pdb.yaml
EOF
echo "Created $OVERLAY_DIR/kustomization.yaml."

echo "Creating pdb.yaml for PodDisruptionBudget..."
cat <<EOF > $OVERLAY_DIR/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: prod-etherpad-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: etherpad
EOF
echo "Created $OVERLAY_DIR/pdb.yaml."

echo "Applying Kustomize overlay to switch to day-2 GitOps model..."
oc apply -k $OVERLAY_DIR/ -n $PROD_PROJECT

echo "Waiting for Deployment/prod-etherpad to scale to 6 replicas..."
oc wait --for=jsonpath='{.status.readyReplicas}'=6 deployment/prod-etherpad -n $PROD_PROJECT --timeout=180s

# --- Step 6: Final verification ---
echo "## 6. Final verification (all must pass)..."

# [cite_start]Verification 1: Pod count (must be 6 pods + 1 header = 7 lines) [cite: 7]
POD_COUNT=$(oc get pods -n $PROD_PROJECT --selector app.kubernetes.io/name=etherpad | wc -l)
echo "Verification 1: Pod count (expected 7, i.e., 6 pods + header): $POD_COUNT"

# Verification 2: Route TLS termination (expected edge)
TERMINATION=$(oc get route prod-etherpad -n $PROD_PROJECT -o jsonpath='{.spec.tls.termination}{"\n"}')
[cite_start]echo "Verification 2: Route TLS termination (expected edge): $TERMINATION" [cite: 7]

# Verification 3: Common labels (app.kubernetes.io/environment: production)
echo "Verification 3: Check common labels (app.kubernetes.io/environment: production):"
# [cite_start]Every line shows production [cite: 7]
oc get all,pdb -n $PROD_PROJECT -L app.kubernetes.io/environment

# Verification 4: Common annotations (managed-by: kustomize-gitops)
ANNOTATION_COUNT=$(oc get all,pdb -n $PROD_PROJECT -o yaml | grep 'managed-by:' | wc -l)
[cite_start]echo "Verification 4: Check common annotations (managed-by: kustomize-gitops count > 0): $ANNOTATION_COUNT" [cite: 8]

# Verification 5: Resources added to Deployment container
echo "Verification 5: Check resources in Deployment container:"
[cite_start]oc get deployment prod-etherpad -n $PROD_PROJECT -o jsonpath='{.spec.template.spec.containers[0].resources}' [cite: 7]
echo # Add newline after jsonpath output

# Verification 6: PodDisruptionBudget
echo "Verification 6: Check PodDisruptionBudget (must show prod-etherpad-pdb):"
[cite_start]oc get pdb -n $PROD_PROJECT # shows prod-etherpad-pdb [cite: 9]

# Verification 7: Application still works
echo "Verification 7: Application still works (opens browser - manual check required)..."
echo "URL: https://etherpad-prod.apps.ocp4.example.com"
[cite_start]open https://etherpad-prod.apps.ocp4.example.com   # still works [cite: 9]
echo "Press Enter to continue after verifying the application is still working."
read -r

# --- Step 7: Clean up ---
echo "## 7. Cleaning up temporary files..."
[cite_start]rm -f $DEV_VALUES_FILE $PROD_VALUES_FILE [cite: 7]
echo "Temporary files cleaned."

echo "Exercise complete. Clean up if needed with 'lab finish $EXERCISE_NAME'."
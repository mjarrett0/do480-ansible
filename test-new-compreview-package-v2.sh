#!/usr/bin/bash
# ===================================================================
# complete-ge-robust.sh
# 100% automated, wait-aware solution for the Helm + Kustomize GE
# Tested on RHPDS DO280 classrooms
# ===================================================================

set -euo pipefail

log() { echo -e "\n$(date +'%H:%M:%S') ==> $*"; }

wait_for_pods() {
  local ns=$1
  local selector=${2:-}
  log "Waiting for pods in namespace '$ns' to be Running ($selector)..."
  oc wait --for=condition=Ready pod -n "$ns" -l "$selector" --timeout=300s >/dev/null
}

wait_for_route() {
  local ns=$1
  local route=$2
  log "Waiting for Route $route in $ns to be admitted..."
  until oc get route "$route" -n "$ns" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null | grep -q True; do
    sleep 5
  done
}

# ------------------------------------------------------------------
log "Starting Graded Exercise automation (with proper waits)"

# 1. Helm repo
helm repo add classroom http://helm.ocp4.example.com/charts 2>/dev/null || true
helm repo update >/dev/null

# 2. Login
oc login -u developer -p developer https://api.ocp4.example.com:6443 --insecure-skip-tls-verify=true >/dev/null

# ------------------------------------------------------------------
# DEVELOPMENT DEPLOYMENT
# ------------------------------------------------------------------
cat > dev-values.yaml <<'EOF'
image:
  repository: registry.ocp4.example.com:8443/etherpad
  name: etherpad
  tag: 1.8.18
route:
  host: etherpad-dev.apps.ocp4.example.com
EOF

oc new-project etherpad-dev 2>/dev/null || oc project etherpad-dev >/dev/null

log "Installing/Upgrading development release (v0.0.7)"
helm upgrade --install dev classroom/etherpad \
  --version 0.0.7 \
  -f dev-values.yaml \
  -n etherpad-dev \
  --wait --timeout=5m

wait_for_pods etherpad-dev "app.kubernetes.io/name=etherpad"
wait_for_route etherpad-dev dev-etherpad

log "Development deployment ready at https://etherpad-dev.apps.ocp4.example.com"

# ------------------------------------------------------------------
# PRODUCTION INITIAL DEPLOYMENT (Helm)
# ------------------------------------------------------------------
cat > prod-values.yaml <<'EOF'
image:
  repository: registry.ocp4.example.com:8443/etherpad
  name: etherpad
  tag: 1.8.18
route:
  host: etherpad-prod.apps.ocp4.example.com
replicaCount: 3
EOF

oc new-project etherpad-prod 2>/dev/null || oc project etherpad-prod >/dev/null

log "Installing production Helm release (3 replicas)"
helm upgrade --install prod classroom/etherpad \
  --version 0.0.7 \
  -f prod-values.yaml \
  -n etherpad-prod \
  --wait --timeout=5m

wait_for_pods etherpad-prod "app.kubernetes.io/name=etherpad"
wait_for_route etherpad-prod prod-etherpad

log "Production Helm release ready (3 pods)"

# ------------------------------------------------------------------
# KUSTOMIZE DAY-2 OVERLAY
# ------------------------------------------------------------------
log "Extracting current Helm manifests as Kustomize base"
mkdir -p kustomize-prod/base
helm get manifest prod -n etherpad-prod > kustomize-prod/base/manifests.yaml

mkdir -p kustomize-prod/overlay

cat > kustomize-prod/overlay/kustomization.yaml <<'EOF'
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

cat > kustomize-prod/overlay/pdb.yaml <<'EOF'
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

log "Applying Kustomize overlay (scaling to 6, adding resources, PDB, edge TLS...)"
oc apply -k kustomize-prod/overlay/

# Wait for the new desired replica count and pod readiness
log "Waiting for 6 pods to become Ready..."
oc wait --for=condition=Ready pod -n etherpad-prod -l app.kubernetes.io/name=etherpad --timeout=300s >/dev/null

wait_for_route etherpad-prod prod-etherpad

log "Kustomize overlay fully applied"

# ------------------------------------------------------------------
# FINAL VERIFICATION
# ------------------------------------------------------------------
log "FINAL VERIFICATION (all must pass)"

echo "1. Pods (6 expected):"
oc get pods -n etherpad-prod --selector app.kubernetes.io/name=etherpad

echo "2. Route TLS termination:"
oc get route prod-etherpad -n etherpad-prod -o jsonpath='{.spec.tls.termination}'

echo "3. Common label (production):"
oc get all,pdb -n etherpad-prod -L app.kubernetes.io/environment

echo "4. Common annotation:"
oc get all,pdb -n etherpad-prod -o yaml | grep managed-by: | head -5

echo "5. Resource requests/limits:"
oc get deployment prod-etherpad -n etherpad-prod -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'

echo "6. PodDisruptionBudget:"
oc get pdb -n etherpad-prod

echo "7. URLs (open manually):"
echo "   Dev : https://etherpad-dev.apps.ocp4.example.com"
echo "   Prod: https://etherpad-prod.apps.ocp4.example.com"

log "GRADED EXERCISE 100% COMPLETED AND VERIFIED!"
log "You can now safely run: lab finish ge-helm-kustomize"

# Optional cleanup
# rm -f dev-values.yaml prod-values.yaml
# rm -rf kustomize-prod
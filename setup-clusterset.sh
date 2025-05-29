#!/bin/bash

# Script to automate creation of ManagedClusterSet and ManagedClusterSetBinding for RHACM

# Configuration
CLUSTERSET_NAME="default"
NAMESPACE="policies-deploy"
YAML_FILE="clusterset-config.yaml"

# Check if oc is installed
if ! command -v oc &> /dev/null; then
    echo "Error: 'oc' CLI is not installed. Please install it and log in to the RHACM hub cluster."
    exit 1
fi

# Check if logged into the cluster
if ! oc whoami &> /dev/null; then
    echo "Error: Not logged into an OpenShift cluster. Please run 'oc login' first."
    exit 1
fi

# Ensure policies namespace exists
echo "Checking if namespace '$NAMESPACE' exists..."
if ! oc get namespace "$NAMESPACE" &> /dev/null; then
    echo "Creating namespace '$NAMESPACE'..."
    oc create namespace "$NAMESPACE" || { echo "Failed to create namespace '$NAMESPACE'"; exit 1; }
else
    echo "Namespace '$NAMESPACE' already exists."
fi

# Check if ManagedClusterSet exists
echo "Checking if ManagedClusterSet '$CLUSTERSET_NAME' exists..."
if oc get managedclusterset "$CLUSTERSET_NAME" -n openshift-cluster-management &> /dev/null; then
    echo "ManagedClusterSet '$CLUSTERSET_NAME' already exists."
else
    echo "Creating ManagedClusterSet '$CLUSTERSET_NAME'..."
    oc apply -f "$YAML_FILE" --type=ManagedClusterSet || { echo "Failed to create ManagedClusterSet '$CLUSTERSET_NAME'"; exit 1; }
fi

# Check if ManagedClusterSetBinding exists
echo "Checking if ManagedClusterSetBinding '$CLUSTERSET_NAME' exists in namespace '$NAMESPACE'..."
if oc get managedclustersetbinding "$CLUSTERSET_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo "ManagedClusterSetBinding '$CLUSTERSET_NAME' already exists in namespace '$NAMESPACE'."
else
    echo "Creating ManagedClusterSetBinding '$CLUSTERSET_NAME' in namespace '$NAMESPACE'..."
    oc apply -f "$YAML_FILE" --type=ManagedClusterSetBinding || { echo "Failed to create ManagedClusterSetBinding '$CLUSTERSET_NAME'"; exit 1; }
fi

echo "Setup complete! ManagedClusterSet '$CLUSTERSET_NAME' and ManagedClusterSetBinding are configured in namespace '$NAMESPACE'."
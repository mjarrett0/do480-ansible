#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ]
then
  exit -1
fi

function message()
{
  python3 -c "print('#' * ${COLS})"
  echo "# ${1}"
}

export TERM=linux
COLS=$(tput cols)
NAMESPACE=updates-api
TYPE="cronjobs"
VERSION="v1beta1"
GROUP="batch"
TYPE_GROUP="${TYPE}.${GROUP}"
TYPE_VERSION_GROUP="${TYPE}.${VERSION}.${GROUP}"
NAME=ubi
ANNOTATION=last-applied-configuration
FULL_ANNOTATION=kubectl.kubernetes.io/last-applied-configuration

RHT_OCP4_MASTER_API=https://api.ocp4.example.com:6443
RHT_OCP4_USER_NAME=admin
RHT_OCP4_USER_PASSWD=redhatocp

export KUBECONFIG=/tmp/.kubeconfig
RESOURCES_FILE="${1}"

message "Preparing the '${FULL_ANNOTATION}' annotation"
date

truncate --size=0 ${KUBECONFIG}
oc login --insecure-skip-tls-verify -u "${RHT_OCP4_USER_NAME}" -p "${RHT_OCP4_USER_PASSWD}" "${RHT_OCP4_MASTER_API}"
oc project "${NAMESPACE}"
oc get ${TYPE_VERSION_GROUP}/${NAME} -o yaml | grep "${ANNOTATION}" || true
oc apply set-last-applied -f "${RESOURCES_FILE}" --create-annotation=true
oc get ${TYPE_VERSION_GROUP}/${NAME} -o yaml | grep "${ANNOTATION}"
oc logout
rm -v ${KUBECONFIG}

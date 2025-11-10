#!/bin/bash

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
FILTER='{range .status.currentHour..byUser[*]}{..byVerb[*].verb}{","}{.username}{","}{.userAgent}{"\n"}{end}'

date

# message "API resources in the '${GROUP}' group"
# oc api-resources --api-group="${GROUP}"

# message "API versions in the '${GROUP}' group"
# oc api-versions | grep -i "${GROUP}"

message "'${TYPE_GROUP}' resources in the '${NAMESPACE}' namespace"
oc get ${TYPE_GROUP} -n ${NAMESPACE}
# oc get ${TYPE_VERSION_GROUP} -n ${NAMESPACE}

message "API request count for '${TYPE_VERSION_GROUP}' resources"
oc get apirequestcounts ${TYPE_VERSION_GROUP}

message "Users who performed API operations on '${TYPE_VERSION_GROUP}' resources"
oc get apirequestcount.apiserver.openshift.io/${TYPE_VERSION_GROUP} -o jsonpath="${FILTER}" |
  sort -k 2 -t ',' -u |
  column -t -s, -N "Verbs,Username,UserAgent"

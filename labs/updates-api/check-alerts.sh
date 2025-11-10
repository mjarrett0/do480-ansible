#!/bin/bash

function message()
{
  python3 -c "print('#' * ${COLS})"
  echo "# ${1}"
}

export TERM=linux
COLS=$(tput cols)
TYPE="cronjobs"
VERSION="v1beta1"
GROUP="batch"
TYPE_VERSION_GROUP="${TYPE}.${VERSION}.${GROUP}"

date

message "Deprecated API alerts for '${TYPE_VERSION_GROUP}' resources"
oc exec -it statefulset/prometheus-k8s -c prometheus \
  -n openshift-monitoring -- \
    curl -fsSL 'http://localhost:9090/api/v1/alerts' |
  jq -r -c -M '.data.alerts[] |
    select((.labels.alertname=="APIRemovedInNextReleaseInUse" or .labels.alertname=="APIRemovedInNextEUSReleaseInUse") and
           (.labels.resource=="'${TYPE}'" and .labels.version=="'${VERSION}'" and .labels.group=="'${GROUP}'")) |
    [ .labels.alertname , .labels.namespace ,
     (.labels.resource + "." + .labels.group + "/" + .labels.version),
      .annotations.summary ] | join(",")' |
  grep -i "${TYPE}.${GROUP}/${VERSION}" |
  column -t -s ',' -N "AlertName,Namespace,Resource,Summary"

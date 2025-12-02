#!/usr/bin/env bash

# https://rol-factory-prod.ole.redhat.com/rol/app/courses/do280-4.18/pages/pr01
# https://rol.redhat.com/rol/app/courses/do280-4.18/pages/pr01

# chmod -c +x *.sh
# script ~/test-do280.log -c "time ~/test-do280.sh"
# ls -lA /tmp/log/labs/ ; tail -n 0 -f /tmp/log/labs/*

COURSE_SKU=DO280
PR_PACKAGE=4.18.0.dev0+pr.1981

TEST_LOG=test-${COURSE_SKU,,}.log
LOG_LEVEL=debug
LOG_DIR=/tmp/log/labs/
CONFIG_FILE=~/.grading/config.yaml

LAB_LIST=labs.txt
LAB_SCRIPTS=$(grep -v '#' ${LAB_LIST})

# PYPI_SERVER_DEV=https://pypi.apps.tools-na100.dev.ole.redhat.com/repository/labs/simple/
PYPI_SERVER_DEV=https://pypi.apps.tools.dev.nextcle.com/repository/labs/simple/
PYPI_SERVER_PROD=https://pypi.apps.tools-na.prod.nextcle.com/repository/labs/simple/

SLEEP_SHORT=15
SLEEP_LONG=60

################################################################################

# set -e
set -vxuo pipefail

reset

################################################################################

which lab

################################################################################

# FIXME: Deprecated in 4.18
# date ; time ssh lab@utility ./wait.sh ; echo $? ; date ;

# + lab start wait-cluster
#
# 	🔍 Running OpenShift Cluster Readiness Check
#
# 	⏱️ Please note: If this environment is being prepared for you for the
#	   first time, it may take up to 40 MINUTES before you can use it.
#
#	✅ The lab command will automatically continue once the cluster is ready

################################################################################

mkdir -vp ${LOG_DIR}

ln -vs ~/${TEST_LOG} ${LOG_DIR}/${TEST_LOG}

for LAB_SCRIPT
in ${LAB_SCRIPTS}
do
  touch "${LOG_DIR}/${LAB_SCRIPT}"
done

if [ -f "${CONFIG_FILE}" ]
then
  sed -i'' -e "s/level: error/level: ${LOG_LEVEL}/g" "${CONFIG_FILE}"
fi

export LOGGING__LEVEL=${LOG_LEVEL}

sleep ${SLEEP_SHORT}

################################################################################

# lab install -u --env prod "${COURSE_SKU,,}" ; echo $? ;
# lab install -u --env test --version "${PR_PACKAGE}" "${COURSE_SKU,,}" ; echo $? ;
lab force "${COURSE_SKU,,}=${PR_PACKAGE}" ; echo $? ;

################################################################################

for LAB_SCRIPT
in ${LAB_SCRIPTS}
do
  python3 -c 'print("#"*40)'
  printf "#\t%s\n\n" "${LAB_SCRIPT}"

  # start
  time lab start ${LAB_SCRIPT} ; echo $? ;
  sleep ${SLEEP_SHORT}

  # grade
  if [[ "${LAB_SCRIPT}" =~ "review" ]]
  then
    time lab grade ${LAB_SCRIPT} ; echo $? ;
    sleep ${SLEEP_SHORT}
  fi

  # finish
  time lab finish ${LAB_SCRIPT} ; echo $? ;
  sleep ${SLEEP_LONG}
done

################################################################################


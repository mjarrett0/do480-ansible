#!/usr/bin/env bash

# lab-test version 0.2.3
# Andres Hernandez - Red Hat
# BSD 3-clause license

# Fill your OCP credentials and API endpoint

OCP_USER=admin
OCP_PASS=redhatocp
OCP_URL=https://api.ocp4.example.com:6443

SLEEP=15

# Put the list of lab names in the `labs.txt` file
# The labs will run in the order that they are listed
SKU=DO316
SKU_LOWER=${SKU,,}

LAB_PACKAGE=rht-labs-${SKU_LOWER}
# LAB_VERSION="4.14.6"
# LAB_VERSION="4.14.7.dev0+pr.803"
# LAB_VERSION="4.14.7.dev0+pr.774"
# LAB_VERSION="4.14.10.dev0+pr.839"
LAB_VERSION="4.16.0.dev0+pr.840"

# The ENV could be 'test' or 'prod', to describe the environment for installed packages.
LAB_ENV=test
LOGLEVEL=debug
LABS=$(cat labs.txt)

GRADING_CONFIG=~/.grading/config.yaml
TMP_LOG_DIR=/tmp/log/labs
TIMESTAMP=$(date '+%+4Y-%m-%d_%H-%M')
LOG_DIR=./${SKU}-logs-${TIMESTAMP}
LOG_ARCHIVE=./${SKU}-logs-${TIMESTAMP}.tar.gz
LOG_ID=./${SKU}-${LAB_ENV}-${LAB_VERSION}.log

# TMPDIR=/tmp
# TMP="$(mktemp -d -p "${TMPDIR}" GLS.XXXXXXXX)"
CLUSTER_VERSION_LOG="${LOG_DIR}/_00-cluster-version.txt"
PROJECTS_BEFORE_LOG="${LOG_DIR}/_01-projects.before.txt"
PROJECTS_AFTER_LOG="${LOG_DIR}/_02-projects.after.txt"
PROJECTS_DIFF_LOG="${LOG_DIR}/_03-projects.diff"
VM_VMI_AFTER_LOG="${LOG_DIR}/_04-vm-vmi.after.txt"

VENV=${HOME}/.venv/labs
VENV_PYTHON=${VENV}/bin/python
VENV_PIP=${VENV}/bin/pip
VENV_ANSIBLE_GALAXY=${VENV}/bin/ansible-galaxy

PIP_OPTS=""
# PIP_OPTS="${PIP_OPTS} --force"
PIP_OPTS="${PIP_OPTS} --use-pep517"
PIP_EXTRA_INDEX_URL_DEV="https://pypi.apps.tools.dev.nextcle.com/repository/labs/simple/"
PIP_EXTRA_INDEX_URL_PROD="https://pypi.apps.tools-na.prod.nextcle.com/repository/labs/simple/"
PIP_EXTRA_INDEX_URL="${PIP_EXTRA_INDEX_URL_DEV}"

# Toggle true/false to enable or disable grading altogether
# GRADE=true
GRADE=true

# https://github.com/RedHatTraining/rht-labs-core/blob/master/docs/source/developers/guides/implementing.md
# > If you have problems with the spinner, prefix the lab command with 'DEV=y'.
# > On older versions of DynoLabs, this disables all output from steps, which can be confusing.
# > Newer versions work better.
#
# However, this doesn't work at the moment.
#
# export DEV=y
unset DEV

# Get variables from command line arguments (if any)
NO_WAIT="${1}"
NO_GRADE="${2}"

export TERM=linux

################################################################################

function separator()
{
  if [ -z "${1}" ]
  then
    N=0
  else
    N=${1}
  fi
  python3 -c "print('#'*${N})"
}

function configure_logging()
{
  # Create log files and directories
  mkdir -vp ${LOG_DIR} ${TMP_LOG_DIR}
  ln -vsf ${LOG_DIR} logs
  cp -v labs.txt ${LOG_DIR}/
  pushd ${LOG_DIR}
  touch ${SKU}-test.log
  ln -vs ${SKU}-test.log ${LOG_ID}
  popd
}

function configure_grading()
{
  # Set the 'debug' logging in '~/.grading/config.yaml' (defaults to 'info')
  cat > ${GRADING_CONFIG} << EOF
rhtlab:
  course:
    sku: ${SKU_LOWER}
  logging:
    level: ${LOGLEVEL}
    path: ${TMP_LOG_DIR}/
EOF
}

function lab_package()
{
  # Print lab version
  lab --version

  # Enter the Python VENV
  source ${VENV}/bin/activate

  # FIXME: The uninstall command is disabled for now because it causes a severe error in the lab
  # ${VENV_PIP} uninstall "${LAB_PACKAGE}" <<< "y" || true
  # sleep 1

  # Install the specified version of the lab package
  # lab install -u  "${SKU_LOWER}"
  lab install -u --env "${LAB_ENV}" --version "${LAB_VERSION}" "${SKU_LOWER}" || \
  ${VENV_PIP} install \
    ${PIP_OPTS} \
    --no-cache-dir \
    --pre \
    --extra-index-url="${PIP_EXTRA_INDEX_URL}" \
    "${LAB_PACKAGE}==${LAB_VERSION}"

  # List the installed 'rht' packages in the classroom environment
  ${VENV_PIP} list | grep 'rht'
  sleep 1
  lab select "${SKU_LOWER}"

  # NOTE: Uncomment the following to use the 'editable' version of the lab package
  # FIXME: This is currently not supported because of a problem with Ansible collections
  # REPO_DIR=${HOME}/repo/src/${SKU_LOWER}
  # VENV_DIR=${HOME}/.venv/labs/lib/python3.9/site-packages/${SKU_LOWER}
  # for DIR in ${REPO_DIR} ${VENV_DIR}
  # do
  #   if [ -e "${DIR}/ansible/collections/requirements.yaml" ]
  #   then
  #     ${VENV_ANSIBLE_GALAXY} collection install -r "${REQUIREMENTS_FILE}"
  #   fi
  # done

  # Leave the Python VENV
  deactivate
}

function wait_cluster()
{
  # Check if we want to run the `wait.sh` script or not
  if [ -z "${NO_WAIT}" ]
  then
    printf "\n\t%s\n\n" "wait"
    time ssh lab@utility ./wait.sh
  fi
}

function cluster_login()
{
  oc login -u "${OCP_USER}" -p "${OCP_PASS}" "${OCP_URL}"
  oc whoami
  oc whoami --show-console
}

function cluster_status()
{
  oc version
  oc get nodes
  oc get ClusterVersion
  oc get ClusterOperators
  oc get CatalogSource -A
  oc get PackageManifest -A
  oc get Operators
  oc get packagemanifests \
    -o jsonpath='{range .items[*]}"{.metadata.name}": {range .status.channels[*]}"{.currentCSV}",{"\t"}{end}{"\n"}{end}' | \
    sort -V
}

function test_lab()
{
  # Fail if args are empty
  LAB=${1}
  if [ -z "${LAB}" ]
  then
    return
  fi
  separator 80
  touch ${TMP_LOG_DIR}/${LAB}
  for VERB in start fix grade finish
  do
    case "${VERB}"
    in
      start|fix|finish)
        run_lab ${LAB} ${VERB}
        ;;
      grade)
        if [[ "${VERB}" = "grade" && "${LAB}" =~ "review" ]]
        then
          if [[ "${GRADE}" = "true" && -z "${NO_GRADE}" ]]
          then
            run_lab "${LAB}" "${VERB}"
          fi
        fi
        ;;
      *)
        continue
        ;;
    esac
    sleep ${SLEEP}
  done
  separator 5
  cp -v ${TMP_LOG_DIR}/${LAB} ${LOG_DIR}/${LAB}
}

function run_lab()
{
  # Fail if args are empty
  LAB=${1}
  VERB=${2}
  if [ -z "${LAB}" -o -z "${VERB}" ]
  then
    return
  fi
  LAB_RUN_LOG=${LOG_DIR}/${LAB}.log
  # login
  separator 40
  printf "\n\t%s\t%s\n" "${LAB}" "${VERB}"
  # time lab ${VERB} ${LAB} || true
  script -e -f -a -O "${LAB_RUN_LOG}" -c "time lab ${VERB} ${LAB}"
  X=$?
  separator 20
  script -e -f -a -O "${LAB_RUN_LOG}" -c "oc get vm,vmi,dv -A" &> /dev/null || true
  separator 10
  # TODO: Run 'lab logs' If 'lab' return code is not zero
  echo ${X}
}

################################################################################

# set -e
# set -vx
set -uo pipefail

# Create log files and directories
configure_logging

# Set the 'debug' logging in '~/.grading/config.yaml' (defaults to 'info')
configure_grading

# Install the desired lab package version
lab_package

# Check if we want to run the `wait.sh` script or not
wait_cluster

# Log in as admin when the cluster is ready
cluster_login

# Check cluster status
cluster_status 2>&1 | tee "${CLUSTER_VERSION_LOG}"

# List the projects that are present in the cluster before starting the test
oc get projects -o name &> "${PROJECTS_BEFORE_LOG}"

# Another option is to put here all the lab scripts in the order they appear in the course
# (the last lab script should not end with a backslash '\')
# TODO: Use 'yq' to extract the GE and lab names from the 'outline.yml' file

# Run all the scripts in batch, just run the `grade` task on GEs, labs and compreviews

separator 80
cat << EOF
#
# Starting automated test
#
# - All lab scripts run the 'start' and 'finish' actions
# - The 'grade' task only runs on GEs, labs and compreviews
#
EOF
separator 80

# Print timestamp when testing begins
date

for LAB in ${LABS}
do
  test_lab "${LAB}"
done

oc get vm,vmi,dv -A 2>&1 | tee "${VM_VMI_AFTER_LOG}" || true

# List the projects that are present in the cluster after the testing finishes
oc get projects -o name &> "${PROJECTS_AFTER_LOG}"

# Compare the project list to see if there were any leftovers
(diff -U0 "${PROJECTS_BEFORE_LOG}" "${PROJECTS_AFTER_LOG}" 2>&1 | tee "${PROJECTS_DIFF_LOG}") || true

# Print timestamp when testing is done
date

separator 80
cat << EOF
#
# Testing done
#
# Copy this output to a text file and save it for future reference.
#
# Also save the logs from the '${LOG_DIR}' folder for inspection.
#
EOF
separator 80

# Save logs to archive
tar -cvzpf ${LOG_ARCHIVE} ${LOG_DIR}
ls -l ${LOG_ARCHIVE}

# Exit the script
exit 0

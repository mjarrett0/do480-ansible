#!/bin/bash
# Script to perform the appsec-prune exercise as the student user.
# This script automates CLI-based steps and pauses for web UI interactions where required.
# Includes waits for resource readiness and logging of key steps.
set -e # Exit on error

EXERCISE_NAME="appsec-prune"
PROJECT_NAME="appsec-prune"
API_SERVER="https://api.ocp4.example.com:6443"

echo "Starting the ${EXERCISE_NAME} exercise."

# Prerequisites
echo "1. Preparing the system with 'lab start ${EXERCISE_NAME}'..."
lab start "${EXERCISE_NAME}"
echo "Lab preparation complete."
echo "---"

# Step 1: Log in and set up project
echo "Step 1: Log in to the OpenShift cluster and switch to the ${PROJECT_NAME} project."
echo "a. Logging in as admin..."
oc login -u admin -p redhatocp "${API_SERVER}" || { echo "Login failed; check credentials or cluster availability."; exit 1; }

echo "b. Creating the ${PROJECT_NAME} project (and switching to it)..."
oc new-project "${PROJECT_NAME}" || echo "Project ${PROJECT_NAME} may already exist, continuing."

echo "c. Changing directory to lab path..."
cd ~/DO280/labs/${EXERCISE_NAME}
echo "Current directory: $(pwd)"
echo "---"

# Step 2: Clean up unused container images in the node (Manual Pruning)
echo "Step 2: Clean up the unused container images in the node."
echo "a. Listing deployments and pods in the prune-apps namespace to show in-use nginx images."
oc get deployments -n prune-apps -o wide
oc get pods -n prune-apps

echo "b. Listing all httpd and nginx container images on node master01."
oc debug node/master01 -- chroot /host crictl images | egrep '^IMAGE|httpd|nginx'

echo "c. Removing unused images in the node (httpd images should be deleted, nginx should not)."
# The command is expected to succeed in deleting httpd images and show errors for nginx images.
oc debug node/master01 -- chroot /host crictl rmi --prune

echo "d. Deleting the deployments in the prune-apps namespace to allow subsequent pruning of nginx images."
oc delete deployment nginx-ubi7 nginx-ubi8 nginx-ubi9 -n prune-apps
echo "---"

# Step 3: Create a cron job to automate the image pruning process (Expected to Fail)
echo "Step 3: Create a cron job to automate the image pruning process (Initial Run - Expected to Fail)."

echo "a. Creating configmap-prune.yaml inline for maintenance script."
cat <<EOF > configmap-prune.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: maintenance
  labels:
    ge: appsec-prune
    app: crictl
data:
  maintenance.sh: |
    #!/bin/bash -eu
    NODES=\$(oc get nodes -o=name)
    for NODE in \${NODES}
    do
      echo \${NODE}
      oc debug \${NODE} -- \
        chroot /host \
          /bin/bash -euxc 'crictl images ;
crictl rmi --prune'
    done
EOF

echo "b. Creating the configuration map 'maintenance'."
oc apply -f configmap-prune.yaml

echo "c. Creating cronjob-prune.yaml inline for image-pruner."
cat <<EOF > cronjob-prune.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: image-pruner
  labels:
    ge: appsec-prune
    app: crictl
spec:
  schedule: '*/4 * * * *'
  jobTemplate:
    spec:
      template:
        spec:
          dnsPolicy: ClusterFirst
          restartPolicy: Never
          containers:
          - name: crictl
            image: registry.ocp4.example.com:8443/openshift/origin-cli:4.18
            resources: {}
            command:
            - /opt/maintenance.sh
            volumeMounts:
            - name: scripts
              mountPath: /opt
          volumes:
          - name: scripts
            configMap:
              name: maintenance
              defaultMode: 0555
EOF

echo "d. Applying the cron job resource (will use default service account)."
oc apply -f cronjob-prune.yaml

echo "e. Waiting for the cron job to be scheduled and fail (STATUS: Error, COMPLETIONS: 0/1)..."
# Wait up to 3 minutes (18 * 10s) for the job to appear and fail
TIMEOUT=18
for i in $(seq 1 $TIMEOUT); do
    JOB_NAME=$(oc get jobs -l job-name=image-pruner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$JOB_NAME" ]; then
        POD_NAME=$(oc get pods --field-selector=status.phase=Error -l job-name=image-pruner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$POD_NAME" ]; then
            echo "Job ${JOB_NAME} and pod ${POD_NAME} created and in Error state."
            break
        fi
    fi
    if [ $i -eq $TIMEOUT ]; then
        echo "Timeout waiting for job/pod to be created and fail. Checking current status:"
        oc get cronjobs,jobs,pods -l ge=appsec-prune
        echo "Please check the job/pod status manually. Press Enter to continue."
        read -r
        break
    fi
    echo "Waiting for job/pod to enter Error state (Attempt $i/$TIMEOUT)..."
    sleep 10
done

# Extracting the pod name for logs
if [ -z "$POD_NAME" ]; then
    POD_NAME_LOGS=$(oc get pods -l job-name=image-pruner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
else
    POD_NAME_LOGS="$POD_NAME"
fi

if [ -n "$POD_NAME_LOGS" ]; then
    echo "f. Getting logs of the failed pod ${POD_NAME_LOGS} (expecting a Forbidden error)."
    oc logs "pod/${POD_NAME_LOGS}"
else
    echo "Could not reliably get the failed pod name for logs. Please check manually."
fi

echo "g. Deleting the failed cron job, job, and pod."
oc delete cronjob/image-pruner
echo "---"

# Step 4: Set the appropriate permissions and rerun the cron job (Expected to Succeed)
echo "Step 4: Set the appropriate permissions to run the image pruner cron job."
SA_NAME="image-pruner"

echo "a. Creating service account '${SA_NAME}'."
oc create sa "${SA_NAME}"

echo "b. Adding the 'privileged' SCC to the '${SA_NAME}' service account."
oc adm policy add-scc-to-user privileged -z "${SA_NAME}"

echo "c. Adding the 'cluster-admin' role to the '${SA_NAME}' service account."
oc adm policy add-cluster-role-to-user cluster-admin -z "${SA_NAME}"

echo "d. Editing cronjob-prune.yaml to use '${SA_NAME}' service account."
# Overwrite the file with the added serviceAccountName
cat <<EOF > cronjob-prune.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: image-pruner
  labels:
    ge: appsec-prune
    app: crictl
spec:
  schedule: '*/4 * * * *'
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: image-pruner # ADDITION
          dnsPolicy: ClusterFirst
          restartPolicy: Never
          containers:
          - name: crictl
            image: registry.ocp4.example.com:8443/openshift/origin-cli:4.18
            resources: {}
            command:
            - /opt/maintenance.sh
            volumeMounts:
            - name: scripts
              mountPath: /opt
          volumes:
          - name: scripts
            configMap:
              name: maintenance
              defaultMode: 0555
EOF

echo "e. Creating the cron job resource again."
oc apply -f cronjob-prune.yaml

echo "f. Waiting until the new job and the pod are created and completed (STATUS: Completed, COMPLETIONS: 1/1)..."
# Wait up to 3 minutes (18 * 10s) for the job to complete
SUCCESS_TIMEOUT=18
for i in $(seq 1 $SUCCESS_TIMEOUT); do
    JOB_STATUS=$(oc get jobs -l job-name=image-pruner -o jsonpath='{.items[0].status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
    if [ "$JOB_STATUS" == "True" ]; then
        COMPLETED_JOB_NAME=$(oc get jobs -l job-name=image-pruner -o jsonpath='{.items[0].metadata.name}')
        COMPLETED_POD_NAME=$(oc get pods -l job-name=image-pruner,status.phase=Succeeded -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        echo "Job ${COMPLETED_JOB_NAME} completed successfully!"
        break
    fi
    if [ $i -eq $SUCCESS_TIMEOUT ]; then
        echo "Timeout waiting for job to complete. Current status:"
        oc get cronjobs,jobs,pods -l ge=appsec-prune
        echo "The job may take longer. Please check the status manually."
        # Use a retry/resume loop for interactive fallback on success timeout
        while true; do
            echo "1) Retry waiting for completion"
            echo "2) Resume script (check logs now)"
            read -p "Enter option (1 or 2): " choice
            case "$choice" in
                1) i=0; continue 2;; # Reset loop counter and retry outer loop
                2) break 2;;        # Break out of both loops
                *) echo "Invalid option. Please enter 1 or 2.";;
            esac
        done
    fi
    echo "Waiting for job to complete (Attempt $i/$SUCCESS_TIMEOUT)..."
    sleep 10
done

# Extracting the completed pod name for logs
if [ -z "$COMPLETED_POD_NAME" ]; then
    COMPLETED_POD_NAME=$(oc get pods -l job-name=image-pruner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -n "$COMPLETED_POD_NAME" ]; then
    echo "g. Getting the logs of the completed pod ${COMPLETED_POD_NAME} (expecting deletion of nginx images)."
    oc logs "pods/${COMPLETED_POD_NAME}" | tail
else
    echo "Could not reliably get the completed pod name for logs. Please check manually."
fi
echo "---"

# Step 5: Clean up resources
echo "Step 5: Clean up resources."

echo "a. Changing to student home directory."
cd ~

echo "b. Ensuring we are on the correct project."
oc project

echo "c. Removing the cron job resource and the configuration map."
oc delete cronjob/image-pruner configmap/maintenance

echo "d. Removing the security constraint from the service account."
oc adm policy remove-scc-from-user -z "${SA_NAME}" privileged

echo "e. Removing the role from the service account."
oc adm policy remove-cluster-role-from-user cluster-admin -z "${SA_NAME}"

echo "f. Deleting the ${PROJECT_NAME} and prune-apps projects."
oc delete project ${PROJECT_NAME} prune-apps

echo "---"
echo "Exercise complete. Clean up if needed with 'lab finish ${EXERCISE_NAME}'."
#
# Copyright 2021 Red Hat, Inc.
#
# NAME
#     applications-review - DO480 Configure lab exercise script
#
# SYNOPSIS
#     applications-review {start|finish}
#
#        start   - prepare the system for starting the lab
#        finish  - perform post-exercise cleanup steps
#
# CHANGELOG

"""
Lab script for DO480 Configure.
This module implements the start and finish functions for the
applications-review guided exercise.
"""

import os
import sys
import logging
import pkg_resources
import requests
import yaml

from .common import steps
from urllib3.exceptions import InsecureRequestWarning
from ocp import api
from ocp.utils import OpenShift
from labs import labconfig
from labs.common.userinterface import Console
from labs.common import labtools
from labs.grading import Default as GuidedExercise
from kubernetes.client.exceptions import ApiException
from .common.constants import USER_NAME, IDM_SERVER, OCP4_API, OCP4_MNG_API


labname = 'applications-review'
SKU = labconfig.get_course_sku().upper()
this_path = os.path.abspath(os.path.dirname(__file__))
_targets = ["localhost","workstation"]
# Default namespace for the resources
NAMESPACE = "mysql"



# TODO: Change this to LabError
class GradingError(Exception):
    pass

class ApplicationsReview(OpenShift):
    """
    applications-review lab script for DO480
    """
    __LAB__ = "applications-review"

    # Get the OCP host and port from environment variables
    OCP_API = {
        "user": os.environ.get("OCP_USER", "admin"),
        "password": os.environ.get("OCP_PASSWORD", "redhat"),
        "host": os.environ.get("OCP_HOST", "api.ocp4.example.com"),
        "port": os.environ.get("OCP_PORT", "6443"),
    }

    OCP_MNG_API = {
        "user": os.environ.get("OCP_USER", "admin"),
        "password": os.environ.get("OCP_PASSWORD", "redhat"),
        "host": os.environ.get("OCP_HOST", "api.ocp4-mng.example.com"),
        "port": os.environ.get("OCP_PORT", "6443"),
    }

# Initialize class
    def __init__(self):
        logging.debug("{} / {}".format(SKU, sys._getframe().f_code.co_name))
        try:
            super().__init__()
        except requests.exceptions.ConnectionError:
            print("The Lab environment is not ready, please wait 10 minutes before trying again.")
            sys.exit(1)
        except ApiException:
            print("The OpenShift cluster is not ready, please wait 5 minutes before trying again.")
            sys.exit(1)
        except Exception as e:
            print("An unknown error ocurred: " + str(e))
            logging.exception("An unknown error ocurred: " + str(e))
            sys.exit(1)


    def start(self):
        """Prepare the system for starting the lab."""
        items = [
            {
                "label": "Checking lab systems",
                "task": labtools.check_host_reachable,
                "hosts": _targets,
                "fatal": True
            },
            {
                "label": "Checking that the OCP hub is up and ready",
                "task": self.run_playbook,
                "playbook": "ansible/common/ocp_cluster_up_and_ready.yaml",
                "fatal": True
            },
            {
                "label": "Checking that RHACM is installed. Installing if needed",
                "task": self.run_playbook,
                "playbook": "ansible/common/acm_install.yaml",
                "fatal": True
                
            },
            {
                "label": "Checking that MulticlusterHub is deployed. Deploying if needed",
                "task": self.run_playbook,
                "playbook": "ansible/common/acm_create_multiclusterhub.yaml",
                "fatal": True
                
            },
            {
                "label": "Importing the managed clusters",
                "task": self.run_playbook,
                "playbook": "ansible/common/acm_import_cluster2.yaml",
                "fatal": True
                
            },
            steps.run_command(label="Verifying connectivity to the OCP4 managed cluster", hosts=["workstation"], command="oc login", options="-u admin -p redhat " + OCP4_MNG_API, returns="0"),
            steps.run_command(label="Project `mysql` is not present", hosts=["workstation"], command="oc", options="get projects mysql", returns="1", failmsg="The mysql project already exists, please delete it or run 'lab finish applications-review' before starting this GE"),
            steps.run_command(label="Verifying connectivity to the OCP4 hub cluster", hosts=["workstation"], command="oc login", options="-u admin -p redhat " + OCP4_API, returns="0"),
            steps.run_command(label="Verifying RHACM Operator deployment", hosts=["workstation"], command="oc get csv -n open-cluster-management", options="", prints="Succeeded", failmsg="Install the RHACM Operator"),
            steps.run_command(label="Verifying RHACM MultiClusterHub deployment", hosts=["workstation"], command="oc", options="get multiclusterhub -n open-cluster-management", prints="Running", failmsg="Create the MultiClusterHub object"),
            steps.run_command(label="Verifying the availability of the local-cluster", hosts=["workstation"], command="oc", options="get managedclusters", prints="local-cluster", failmsg="Create the MultiClusterHub object"),
            steps.run_command(label="Verifying the availability of the managed-cluster", hosts=["workstation"], command="oc", options="get managedclusters", prints="managed-cluster", failmsg="Import the managed-cluster into RHACM"),
            {
                "label": "Project 'mysql' is not present",
                "task": self._fail_if_exists,
                "name": "mysql",
                "type": "Project",
                "api": "project.openshift.io/v1",
                "namespace": "",
                "fatal": True
            },
            steps.run_command(label="Removing the environment label from managed-cluster", hosts=["workstation"], command="oc", options="label managedclusters managed-cluster environment- --overwrite", returns="0"),
            steps.run_command(label="Removing the environment label from local-cluster", hosts=["workstation"], command="oc", options="label managedclusters local-cluster environment- --overwrite", returns="0"),
            steps.run_command(label="Logging out", hosts=["workstation"], command="oc", options="logout", returns="0")
        ]
        Console(items).run_items(action="Starting")

    def grade(self):
        """
        Grade lab exercise.
        """
        items = [
            {
                "label": "Project 'mysql' is present",
                "task": self._fail_if_not_exists,
                "name": "mysql",
                "type": "Namespace",
                "api": "v1",
                "namespace": "",
                "fatal": True
            },
            {
                "label": "Deployment 'mysql' is present",
                "task": self._fail_if_not_exists,
                "name": "mysql",
                "type": "Deployment",
                "api": "apps/v1",
                "namespace": "mysql",
                "fatal": True
            },
             {
                "label": "Image 'registry.redhat.io/rhel8/mysql-80:1-156' is present",
                "task": self._fail_if_not_exists,
                "name": "mysql",
                "type": "Deployment",
                "api": "apps/v1",
                "namespace": "mysql",
                "image": "registry.redhat.io/rhel8/mysql-80:1-156",
                "fatal": True
            },
            {
                "label": "PlacementRule 'mysql-placement-1' is present",
                "task": self._fail_if_not_exists,
                "name": "mysql-placement-1",
                "type": "PlacementRule",
                "api": "apps/v1",
                "namespace": "mysql",
                "env": "development",
                "fatal": True
            },
 
            {
                "label": "Checking image registry config",
                "task": self._check_cluster_imageregistry,
                "fatal": True,
            },
            steps.run_command(label="Verifying connectivity to OCP4 hub cluster", hosts=["workstation"], command="oc login", options="-u admin -p redhat https://api.ocp4.example.com:6443", returns="0"),
            steps.run_command(label="Verifying connectivity to OCP4 managed cluster", hosts=["workstation"], command="oc login", options="-u admin -p redhat  https://api.ocp4-mng.example.com:6443", returns="0"),
            steps.run_command(label="Verifying that the deployment has the correct image'", hosts=["workstation"], command="oc", options="get pods mysql -n mysql -o jsonpath='{.items[*].spec.containers[*].image}'", prints='quay.io/redhattraining/todo-single:v1.0 registry.redhat.io/rhel8/mysql-80:1-156', failmsg="Fix the deployment to use the correct image"),
            steps.run_command(label="Verifying'", hosts=["workstation"], command="oc", options="get deployment mysql -n mysql -o=jsonpath='{.status.replicas}'", prints="1", failmsg="Fix the deployment to run with 1 replica"),
            steps.run_command(label="Logging out", hosts=["workstation"], command="oc", options="logout", returns="0")
        ]
        ui = Console(items)
        ui.run_items(action="Grading")
        ui.report_grade()


    def finish(self):
        """
        Perform any post-lab cleanup tasks.
        """
        items = [
            steps.run_command(label="Verifying connectivity to the OCP4 managed cluster", hosts=["workstation"], command="oc login", options="-u admin -p redhat " + OCP4_MNG_API, returns="0"),
            steps.run_command(label="Removing the mysql namespace", hosts=["workstation"], command=this_path + "/files/applications-review/delete_project.sh", options="", returns="0"),
            steps.run_command(label="Verifying connectivity to the OCP4 cluster", hosts=["workstation"], command="oc login", options="-u admin -p redhat " + OCP4_API, returns="0"),
            {
                "label": "Removing the mysql namespace",
                "task": self._delete_resource,
                "kind": "Project",
                "api": "project.openshift.io/v1",
                "name": "mysql",
                "namespace": None,
            },
            steps.run_command(label="Removing the environment label from managed-cluster", hosts=["workstation"], command="oc", options="label managedclusters managed-cluster environment- --overwrite", returns="0"),
            steps.run_command(label="Removing the environment label from local-cluster", hosts=["workstation"], command="oc", options="label managedclusters local-cluster environment- --overwrite", returns="0"),
            steps.run_command(label="Logging out", hosts=["workstation"], command="oc", options="logout", returns="0")
        ]
        Console(items).run_items(action="Finishing")

    def _delete_resource(self, item):
        item["failed"] = False
        try:
            self.delete_resource(
                item["api"],
                item["kind"],
                item["name"],
                item["namespace"]
            )
        except Exception as e:
            item["failed"] = True
            item["msgs"] = [
                {"text": "Failed removing %s: %s" % (item["kind"], e)}
            ]
            logging.debug(e)

############################################################################################################################
 ############################################################################
    # Grading tasks

    def _fail_if_not_exists(self, item):
        """
        Check resource existence
        """
        item["failed"] = False
        if not self.resource_exists(item["api"], item["type"], item["name"], item["namespace"]):
            item["failed"] = True
            item["msgs"] = [{"text":
                "The %s %s does not exist, " % (item["name"], item["type"]) +
                "please work through the lab instructions "}]
        return item["failed"]
    
    def _check_cluster_imageregistry(self, item):
        try:
            o = self.resource_get("imageregistry.operator.openshift.io/v1", "Config", "cluster", "")

            item["failed"] = False
            if not o:
                raise GradingError("Something went really wrong.")
            if "noobaa-review-" not in o.spec.storage.s3.bucket:
                raise GradingError("Image registry is set to the wrong value.")
        except AttributeError:
            item["failed"] = True
            item["msgs"] = [{"text": "Image registry is not configured. Please work through the lab instructions."}]
        except GradingError as e:
            item["failed"] = True
            item["msgs"] = [{"text": "{} Please work through the lab instructions.".format(str(e))}]
        return item["failed"]
    
    def _check_app_exists(self, item):
        try:
            a, n = item["app"], item["namespace"]
            o = self.resource_get("v1", "Deployment", a, n)
            item["failed"] = False
            if not o:
                raise GradingError("{} does not exist within namespace {}.".format(a, n))
        except GradingError as e:
            item["failed"] = True
            item["msgs"] = [{"text": "{} Please work through the lab instructions.".format(str(e))}]
        return item["failed"]

# Copyright (c) 2022 Red Hat Training <training@redhat.com>
#
# All rights reserved.
# No warranty, explicit or implied, provided.
#
# CHANGELOG
# * Apr 25 2022 Herve Quatremain <hquatrem@redhat.com>
#   - original code
# * Jul 04 2024 Andres Hernandez <andres.hernandez@redhat.com>
#   - Refactor: Lab script style
#   - Refactor: Move all functions to 'common.py'

"""
Grading module for DO316 review-cr3 lab.
This module either does start, grade, or finish for the review-cr3 lab.
"""

import sys
import logging
import requests

from urllib3 import disable_warnings
from urllib3.exceptions import InsecureRequestWarning
from kubernetes.client.exceptions import ApiException

from ocp.utils import OpenShift
from labs import labconfig
from labs.common import labtools, userinterface

# Import all the functions defined in the common.py module
from do316 import common


# Course SKU
SKU = labconfig.get_course_sku().upper()

# List of hosts involved in that module. Before doing anything,
# the module checks that they can be reached on the network
_targets = ["utility"]

# Default namespace for the resources
NAMESPACE = "review-cr3"

# List of operators used in the course
OPERATORS = common.OPERATORS

# Disable certificate validation
disable_warnings(InsecureRequestWarning)


class ReviewCR3(OpenShift):
    """
    Comprehensive review 3 script for DO316
    """

    __LAB__ = NAMESPACE

    # Get the OCP parameters from the common class
    OCP_API = common.OCP_API

    # Initialize class
    def __init__(self):
        logging.debug("{} / {}".format(SKU, sys._getframe().f_code.co_name))
        try:
            super().__init__()
        except requests.exceptions.ConnectionError:
            msg = (
                "The Lab environment is not ready, "
                "please wait 10 minutes before trying again."
            )
            print(str(msg))
            sys.exit(3)
        except ApiException:
            msg = (
                "The OpenShift cluster is not ready, "
                "please wait 5 minutes before trying again."
            )
            print(str(msg))
            sys.exit(2)
        except Exception as e:
            msg = "An unknown error ocurred."
            print(str(msg))
            msg += str(e)
            logging.exception(msg)
            sys.exit(1)

    def start(self):
        """
        Prepare the system for starting the lab
        """
        logging.debug("{} / {}".format(SKU, sys._getframe().f_code.co_name))
        items = []
        items.append(
            {
                "label": "Checking lab systems",
                "task": labtools.check_host_reachable,
                "hosts": _targets,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Pinging API",
                "task": common.start_ping_api,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Checking API",
                "task": common.start_check_api,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Checking cluster readiness",
                "task": common.start_check_cluster_ready,
                "oc_client": self.oc_client,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Checking CatalogSource",
                "task": self.run_playbook,
                "playbook": "ansible/playbooks/check-catalog-source.yaml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Install the 'OpenShift Virtualization' operator",
                "task": common.openshift_virt,
                "oc_client": self.oc_client,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Confirming virtctl availability",
                "task": self.run_playbook,
                "playbook": "ansible/playbooks/deploy-virtctl.yml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": f"Confirming that the '{NAMESPACE}' project does not exist",
                "task": common.check_ge_namespace,
                "oc_client": self.oc_client,
                "namespace": NAMESPACE,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Preparing the disk images on the 'utility' machine",
                "task": self.run_playbook,
                "playbook": f"ansible/{self.__LAB__}/start_image.yml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Creating the data volumes",
                "task": self.run_playbook,
                "playbook": f"ansible/{self.__LAB__}/start_data_volumes.yml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Creating the 'golden-web' virtual machine",
                "task": self.run_playbook,
                "playbook": f"ansible/{self.__LAB__}/golden-web.yml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Copying exercise content",
                "task": labtools.copy_lab_files,
                "lab_name": self.__LAB__,
                "fatal": True,
            }
        )
        userinterface.Console(items).run_items(action="Starting")

    def grade(self):
        """
        Perform evaluation steps on the system
        """
        logging.debug("{} / {}".format(SKU, sys._getframe().f_code.co_name))
        items = []
        items.append(
            {
                "label": "Checking lab systems",
                "task": labtools.check_host_reachable,
                "hosts": _targets,
                "fatal": True,
                "grading": True,
            }
        )
        items.append(
            {
                "label": "Checking cluster readiness",
                "task": common.start_check_cluster_ready,
                "oc_client": self.oc_client,
                "fatal": True,
                "grading": True,
            }
        )
        items.append(
            {
                "label": "Checking CatalogSource",
                "task": self.run_playbook,
                "playbook": "ansible/playbooks/check-catalog-source.yaml",
                "fatal": True,
                "grading": True,
            }
        )
        items.append(
            {
                "label": "Check if the 'OpenShift Virtualization' operator is installed",
                "task": common.grade_virtualization,
                "oc_client": self.oc_client,
                "fatal": True,
                "grading": True,
            }
        )
        # FIXME: There is no task to grade the 'MTV' operator
        # NOTE: This loop is defined to repeat the same task with different parameters
        for vm in ["web1", "web2"]:
            items.append(
                {
                    "label": f"The '{vm}' VM is running",
                    "task": common.grade_vm_running,
                    "oc_client": self.oc_client,
                    "namespace": NAMESPACE,
                    "name": vm,
                    "fatal": False,
                    "grading": True,
                }
            )
            items.append(
                {
                    "label": f"The readiness probe is configured for '{vm}'",
                    "task": common.grade_vm_readiness,
                    "oc_client": self.oc_client,
                    "namespace": NAMESPACE,
                    "name": vm,
                    "path": "/cgi-bin/health",
                    "port": 80,
                    "period": 5,
                    "failures": 2,
                    "fatal": False,
                    "grading": True,
                }
            )
            items.append(
                {
                    "label": f"The '{vm}-documentroot' PVC is connected to VM '{vm}'",
                    "task": common.grade_vm_pvc,
                    "oc_client": self.oc_client,
                    "namespace": NAMESPACE,
                    "name": vm,
                    "pvc_name": f"{vm}-documentroot",
                    "fatal": False,
                    "grading": True,
                }
            )
            items.append(
                {
                    "label": f"The '{vm}' VM has the 'tier=front' label",
                    "task": common.grade_vm_label,
                    "oc_client": self.oc_client,
                    "namespace": NAMESPACE,
                    "name": vm,
                    "label_key": "tier",
                    "label_value": "front",
                    "fatal": False,
                    "grading": True,
                }
            )
        items.append(
            {
                "label": "The 'web1-snap1' snapshot exists",
                "task": common.grade_vm_snapshot_exists,
                "oc_client": self.oc_client,
                "namespace": NAMESPACE,
                "name": "web1-snap1",
                "vm_name": "web1",
                "fatal": False,
                "grading": True,
            }
        )
        items.append(
            {
                "label": "The 'front' service exists",
                "task": common.grade_service,
                "oc_client": self.oc_client,
                "namespace": NAMESPACE,
                "name": "front",
                "type": "ClusterIP",
                "selector_label_key": "tier",
                "selector_label_value": "front",
                "port": 80,
                "target_port": 80,
                "proto": "TCP",
                "fatal": False,
                "grading": True,
            }
        )
        items.append(
            {
                "label": "The web application is reachable from outside",
                "task": common.grade_url_code,
                "url": "http://front-review-cr3.apps.ocp4.example.com",
                "code": 200,
                "fatal": False,
                "grading": True,
            }
        )
        ui = userinterface.Console(items)
        ui.run_items(action="Grading")
        ui.report_grade()

    def finish(self):
        """
        Perform post-lab cleanup
        """
        logging.debug("{} / {}".format(SKU, sys._getframe().f_code.co_name))
        items = []
        items.append(
            {
                "label": "Checking lab systems",
                "task": labtools.check_host_reachable,
                "hosts": _targets,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Checking cluster readiness",
                "task": common.start_check_cluster_ready,
                "oc_client": self.oc_client,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Checking CatalogSource",
                "task": self.run_playbook,
                "playbook": "ansible/playbooks/check-catalog-source.yaml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": f"Deleting the '{NAMESPACE}' project",
                "task": common.delete_ge_namespace,
                "oc_client": self.oc_client,
                "namespace": NAMESPACE,
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Removing the disk images from the 'utility' machine",
                "task": self.run_playbook,
                "playbook": f"ansible/{self.__LAB__}/finish_image.yml",
                "fatal": True,
            }
        )
        items.append(
            {
                "label": "Deleting exercise files",
                "task": labtools.delete_workdir,
                "lab_name": self.__LAB__,
                "fatal": True,
            }
        )
        userinterface.Console(items).run_items(action="Finishing")

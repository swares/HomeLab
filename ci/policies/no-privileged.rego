# Deny containers with privileged: true.
package main

import rego.v1

_containers contains c if {
    input.kind in {"Deployment", "StatefulSet", "DaemonSet", "Job"}
    c := input.spec.template.spec.containers[_]
}
_containers contains c if {
    input.kind in {"Deployment", "StatefulSet", "DaemonSet", "Job"}
    c := input.spec.template.spec.initContainers[_]
}
_containers contains c if {
    input.kind == "CronJob"
    c := input.spec.jobTemplate.spec.template.spec.containers[_]
}
_containers contains c if {
    input.kind == "CronJob"
    c := input.spec.jobTemplate.spec.template.spec.initContainers[_]
}

deny contains msg if {
    c := _containers[_]
    c.securityContext.privileged == true
    msg := sprintf("container '%s' sets privileged: true — use specific capabilities instead", [c.name])
}

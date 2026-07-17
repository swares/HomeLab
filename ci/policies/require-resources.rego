# All containers in Deployments, StatefulSets, and DaemonSets must declare
# CPU and memory limits. kube-system namespace is exempt (system components).
package main

import rego.v1

_workload_kinds := {"Deployment", "StatefulSet", "DaemonSet"}

_exempt_namespaces := {"kube-system"}

_has_cpu_limit(c) if { c.resources.limits.cpu }

_has_memory_limit(c) if { c.resources.limits.memory }

deny contains msg if {
    input.kind in _workload_kinds
    not input.metadata.namespace in _exempt_namespaces
    c := input.spec.template.spec.containers[_]
    not _has_cpu_limit(c)
    msg := sprintf("%s '%s/%s': container '%s' is missing a CPU limit", [
        input.kind, input.metadata.namespace, input.metadata.name, c.name,
    ])
}

deny contains msg if {
    input.kind in _workload_kinds
    not input.metadata.namespace in _exempt_namespaces
    c := input.spec.template.spec.containers[_]
    not _has_memory_limit(c)
    msg := sprintf("%s '%s/%s': container '%s' is missing a memory limit", [
        input.kind, input.metadata.namespace, input.metadata.name, c.name,
    ])
}

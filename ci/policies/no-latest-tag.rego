# Deny containers using floating :latest (or latest-*) image tags.
# Exceptions: add image base names to ci/data/exceptions.yaml under
# no_latest_tag_exceptions with a comment explaining why.
package main

import rego.v1

# All containers (main + init) across workload kinds.
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

_image_base(image) := base if {
    base := split(image, ":")[0]
}

_allowed(image) if {
    base := _image_base(image)
    base == data.no_latest_tag_exceptions[_]
}

# Deny :latest or latest-* tags
deny contains msg if {
    c := _containers[_]
    image := c.image
    parts := split(image, ":")
    count(parts) > 1
    startswith(parts[1], "latest")
    not _allowed(image)
    msg := sprintf("container '%s' uses floating tag — pin to a specific version: %s", [c.name, image])
}

# Deny images with no tag at all (implicit :latest)
deny contains msg if {
    c := _containers[_]
    image := c.image
    parts := split(image, ":")
    count(parts) == 1
    not _allowed(image)
    msg := sprintf("container '%s' has no image tag (implicit :latest) — pin to a specific version: %s", [c.name, image])
}

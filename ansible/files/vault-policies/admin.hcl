path "sys/auth"                    { capabilities = ["read","list"] }
path "sys/auth/*"                  { capabilities = ["create","read","update","delete","sudo"] }
path "sys/policies/acl"            { capabilities = ["list"] }
path "sys/policies/acl/*"          { capabilities = ["create","read","update","delete","list","sudo"] }
path "sys/mounts"                  { capabilities = ["read","list"] }
path "sys/mounts/*"                { capabilities = ["create","read","update","delete","sudo"] }
path "sys/leases/*"                { capabilities = ["create","read","update","delete","list","sudo"] }
path "sys/storage/raft/snapshot"   { capabilities = ["read"] }
# sys/audit — added 2026-09-05 for BACKLOG §2.6. `sudo` is REQUIRED, not decorative:
# sys/audit is a root-protected path, so the operation capabilities alone are refused.
# Without this, `vault audit list` returns rc=2 and `vault audit enable` returns 403 —
# which is how this gap was found.
#
# Note what granting it does NOT change: §2.8 records that `admin` already holds
# create+sudo on sys/policies/acl/*, so a token carrying it could always have written
# itself this permission. This makes an existing capability explicit and reviewable in
# git rather than adding a new one.
path "sys/audit"                   { capabilities = ["read","list","sudo"] }
path "sys/audit/*"                 { capabilities = ["create","read","update","delete","sudo"] }
path "auth/*"                      { capabilities = ["create","read","update","delete","list","sudo"] }
path "secret/*"                    { capabilities = ["create","read","update","delete","list","patch"] }

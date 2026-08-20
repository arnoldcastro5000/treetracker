#!/usr/bin/env bash
# up hook: Emissary-ingress (OSS Ambassador) - the shared API gateway on localhost:8088.
# Bespoke (CRDs + helm + Service-type patch), so it lives in a hook instead of a plain overlay.
# Subsystem overlays ship getambassador.io/v2 Mappings (they need these CRDs first); 3.x serves
# v2 via its conversion webhook.
set -euo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$(cd "$HOOK_DIR/../../../lib" && pwd)/orchestrator-lib.sh"

log "emissary-ingress (API gateway → localhost:8088)"
k apply -f "https://app.getambassador.io/yaml/emissary/${EMISSARY_VER}/emissary-crds.yaml" >/dev/null 2>&1 \
  || { net_check_die "emissary CRD download" app.getambassador.io; die "emissary CRD apply failed"; }
k wait --timeout=150s --for=condition=available deployment emissary-apiext -n emissary-system >/dev/null 2>&1 \
  || die "emissary-apiext never ready"
helm --kube-context "$CONTEXT" repo add datawire https://app.getambassador.io >/dev/null 2>&1 || true
helm --kube-context "$CONTEXT" repo update datawire >/dev/null 2>&1 || true
# No `--wait` here. The chart's Service defaults to type LoadBalancer; in NodePort mode
# servicelb is disabled, so that Service never receives an ingress IP and `helm --wait` blocks
# on it until the timeout, failing (context deadline exceeded) BEFORE the patch below can
# convert it. Install without waiting, patch the Service, then gate on the Deployment rollout
# explicitly, which is the readiness that actually matters and works in both Service modes.
helm --kube-context "$CONTEXT" upgrade --install emissary-ingress datawire/emissary-ingress \
  --version "$EMISSARY_CHART_VER" -n emissary --create-namespace >/tmp/up-emissary.log 2>&1 \
  || { net_check_die "emissary chart download" datawire-static-files.s3.amazonaws.com
       net_check_die "emissary chart index" app.getambassador.io
       die "emissary helm install failed (see /tmp/up-emissary.log)"; }
# The chart defaults the Service to LoadBalancer; with servicelb disabled (NodePort mode)
# that would stay <pending> forever. Pin the two NodePorts the k3d LB maps 8088/8443 onto.
# A strategic-merge patch (merge key = port) sets type + nodePort while preserving the
# chart's name/targetPort, so we do not need to know emissary's container ports. Patch
# rather than helm --set (the chart's service.ports list is index-fragile under --set).
# LoadBalancer mode keeps the chart default (no patch). Patch BEFORE waiting on rollout so a
# LoadBalancer Service is never in the wait path.
if [ "$GATEWAY_SERVICE_TYPE" = NodePort ]; then
  k -n emissary patch svc emissary-ingress -p "$(cat <<EOF
{"spec":{"type":"NodePort","ports":[
  {"port":80,"nodePort":${GATEWAY_NODEPORT_HTTP}},
  {"port":443,"nodePort":${GATEWAY_NODEPORT_HTTPS}}]}}
EOF
)" >/dev/null || die "emissary NodePort patch failed"
fi
k -n emissary rollout status deploy/emissary-ingress --timeout=300s || die "emissary-ingress deployment never ready"
k apply -f "$HOOK_DIR/../emissary.yaml" >/dev/null   # Listener + wildcard Host

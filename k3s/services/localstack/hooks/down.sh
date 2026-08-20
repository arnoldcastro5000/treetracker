#!/usr/bin/env bash
# down hook: remove the host-side LocalStack container (and its in-memory S3/SQS state).
# Symmetric teardown for a service that lives outside the cluster, so `down.sh` leaves nothing
# running on the host.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"

if docker ps -a --filter "name=^/${LOCALSTACK_NAME}$" -q | grep -q .; then
  log "removing localstack container $LOCALSTACK_NAME"
  docker rm -f "$LOCALSTACK_NAME" >/dev/null
else
  info "localstack container $LOCALSTACK_NAME not present"
fi

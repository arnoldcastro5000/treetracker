#!/usr/bin/env bash
# up hook: run the LocalStack container (S3 + SQS) on the host and wait until both services are
# healthy. Provisioning (buckets/queues/notifications) is NOT here: the orchestrator provisions
# each subsystem's declared objectStorage resources after this hook succeeds.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)/orchestrator-lib.sh"

log "localstack (S3 + SQS on :$LOCALSTACK_PORT, region $OBJECT_STORAGE_REGION)"
command -v docker >/dev/null 2>&1 || die "docker missing - run ./k3s/prepare.sh"
# Image present? Pull once (a firewall block is deterministic → fail fast with the real cause).
if ! docker image inspect "$LOCALSTACK_IMAGE" >/dev/null 2>&1; then
  for i in $(seq 1 10); do
    docker pull "$LOCALSTACK_IMAGE" >/dev/null 2>&1 && break
    [ "$i" = 1 ]  && net_check_die "docker pull $LOCALSTACK_IMAGE" registry-1.docker.io
    [ "$i" = 10 ] && die "docker pull $LOCALSTACK_IMAGE failed after 10 attempts"
    info "pull $LOCALSTACK_IMAGE: retry $i"; sleep 5
  done
fi
# Container lifecycle: reuse a running one, start a stopped one, else create. DEFAULT_REGION on
# the container makes eu-central-1 its default so a bucket without an explicit constraint still
# lands in-region; the orchestrator's provisioning sets it explicitly regardless.
if docker ps --filter "name=^/${LOCALSTACK_NAME}$" --filter status=running -q | grep -q .; then
  info "$LOCALSTACK_NAME already running"
elif docker ps -a --filter "name=^/${LOCALSTACK_NAME}$" -q | grep -q .; then
  info "starting existing $LOCALSTACK_NAME"; docker start "$LOCALSTACK_NAME" >/dev/null
else
  info "creating $LOCALSTACK_NAME"
  docker run -d --name "$LOCALSTACK_NAME" \
    -p "${LOCALSTACK_PORT}:4566" \
    -e SERVICES=s3,sqs -e DEFAULT_REGION="$OBJECT_STORAGE_REGION" \
    "$LOCALSTACK_IMAGE" >/dev/null || die "localstack container failed to start"
fi
# Readiness: the health endpoint must list s3 and sqs before anything provisions against it.
health=""
for i in $(seq 1 60); do
  health=$(curl -s -m 3 "http://localhost:${LOCALSTACK_PORT}/_localstack/health" 2>/dev/null || true)
  case "$health" in *'"sqs"'*'"s3"'*|*'"s3"'*'"sqs"'*) break ;; esac
  sleep 2
done
case "$health" in *'"s3"'*'"sqs"'*|*'"sqs"'*'"s3"'*) : ;; *) die "localstack never became ready on :$LOCALSTACK_PORT (s3+sqs)" ;; esac
info "localstack ready on :$LOCALSTACK_PORT"

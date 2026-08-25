# Local k3s backend — setup runbook

How to build the local Greenstand backend (for the Android capture→verify e2e) from scratch: a k3d
cluster running PostgreSQL, the db-migrate-managed schemas, RabbitMQ, and the treetracker-field-data
service. Everything runs in the **`k3d-greenstand`** cluster; nothing here touches the real cloud
clusters.

## Quick start (scripts)
```bash
./k3s/prepare.sh     # ONCE per machine (macOS-specific): install tools (k3d/helm/awscli/libpq).
./k3s/prepare-linux.sh # ONCE per machine (Linux, incl. restricted-kernel sandboxes): install tools.
./k3s/up.sh          # portable, idempotent: bring up every subsystem + verify it works. Re-run to repair.
                     #   one subsystem + its deps: ./k3s/up.sh capture
                     #   plan only: ./k3s/up.sh plan   re-verify: ./k3s/up.sh verify   skip: --no-verify
./k3s/smoke.sh       # the capture subsystem's verify hook (17-check in-cluster smoke test); up.sh runs it.
./k3s/down.sh        # tear down: delete the k3d cluster (all pods + data).
                     #   ./k3s/down.sh --namespaces   (keep cluster, drop stack namespaces)
                     #   ./k3s/down.sh --images        (also remove built/pulled images)
```
`prepare.sh` = your-machine-specific bootstrap (Homebrew installs, ClashX/Docker proxy). `up.sh` = pure
stack setup, same for local (`ENV=local`, k3d) and cloud CI (`ENV=ci KUBE_CONTEXT=… IMAGE_REGISTRY=…`).
The sections below document what those scripts do, step by step.

> ⚠️ **Context safety:** the kube context often reverts to the real dev cluster
> `do-sfo2-dev-k8s-treetracker` across sessions. Before ANY `kubectl`/`apply`/`exec`, run
> `kubectl config use-context k3d-greenstand` and assert it.
>
> **This machine no longer uses a proxy** — write plain commands (no `NO_PROXY`/`http_proxy`
> scaffolding). See [Environment gotchas](#environment-gotchas-found-the-hard-way) for the
> proxy/DNS cleanup that had to happen and why a network hang is *not* a proxy issue anymore.

---

## 0. Toolchain (one-time)
```bash
brew install k3d helm awscli libpq
brew link --force libpq         # puts psql/pg_dump on PATH (keg-only otherwise)
# Docker Desktop installed; Node via nvm (v24 used here)
```

## 1. Networking — no proxy (was ClashX)
This machine **no longer uses a proxy**; commands reach the network directly. Earlier it ran ClashX
(`127.0.0.1:7890`) and needed proxy env + a Docker-daemon proxy; that is all removed. Two config-level
proxies had to be cleared or builds/installs hung against the dead `…:7890`:
- **npm:** `npm config delete proxy && npm config delete https-proxy` (was in `~/.npmrc`).
- **Docker daemon:** `~/Library/Group Containers/group.com.docker/settings-store.json` →
  `ProxyHTTPMode=system`, blank `OverrideProxyHTTP/HTTPS`, then restart Docker.

ClashX's **fake-IP DNS is still active**, though — see [gotchas](#environment-gotchas-found-the-hard-way):
it hands `198.18.x.x` for names it doesn't really own (e.g. `host.docker.internal`), which breaks a
fresh k3d cluster's kubeconfig until pinned to `127.0.0.1` (up.sh does this).

## 2. Create the k3d cluster
```bash
k3d cluster create greenstand \
  --k3s-arg "--disable=traefik@server:*" \
  -p "8088:80@loadbalancer" -p "8443:443@loadbalancer" --agents 0
# up.sh does this for you; the host ports come from GATEWAY_HTTP_PORT/GATEWAY_HTTPS_PORT
# (defaults 8088/8443). Set them BEFORE the first up.sh if 8088/8443 are taken.
# after a Docker/machine restart the cluster is stopped, not gone:
k3d cluster start greenstand
```
In-cluster containerd does NOT use the proxy → **pull images on the host, then import**:
```bash
docker pull <image> && k3d image import <image> -c greenstand
```

## 3. PostgreSQL
```bash
kubectl apply -f k3s/services/postgres/postgres.yaml           # postgis/postgis:15-3.4, ns=data, DB=treetracker (postgres/postgres)
kubectl -n data rollout status deploy/postgres
# second database:
POD=$(kubectl -n data get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl -n data exec "$POD" -- psql -U postgres -d postgres -c "CREATE DATABASE data_pipeline;"
```
Port-forward for host-side db-migrate (keep running in a second terminal):
```bash
kubectl -n data port-forward svc/postgres 5432:5432
```

## 4. Schemas via db-migrate (repo: `treetracker-database-nextgen`)
Baselined from the online dev DB; each DB is its own db-migrate project, first migration = the schema
baseline, tracking table `nextgen_migrations`. See that repo's README for details.
```bash
cd treetracker-database-nextgen/treetracker    && npm install && npm run migrate:up   # public (122 tables incl. trees/planter)
cd ../data_pipeline                            && npm install && npm run migrate:up   # data_pipeline.bulk_tree_upload
```

## 5. field_data schema (repo: `treetracker-field-data`, its own migrations)
`field_data` is a schema **inside the `treetracker` DB**, created by field-data's own 23 migrations.
```bash
# treetracker-field-data/database/database.json  → env "local": host 127.0.0.1:5432, db treetracker,
#                                                    user/pw postgres, "schema": "field_data"
cd treetracker-field-data/database
../../treetracker-database-nextgen/treetracker/node_modules/.bin/db-migrate up -e local
# → field_data.raw_capture, session, track, wallet_registration, device_configuration, domain_event*
```

## 6. RabbitMQ (field-data publishes raw-capture-created)
```bash
docker pull rabbitmq:3.13-management-alpine && k3d image import rabbitmq:3.13-management-alpine -c greenstand
kubectl apply -f k3s/services/rabbitmq/rabbitmq.yaml           # ns=rabbitmq, svc rabbitmq.rabbitmq.svc:5672 (guest/guest)
```

## 7. treetracker-field-data service
Build the image, import it, deploy the local kustomize overlay (reuses the repo's base; swaps
sealed-secrets → plain local Secrets, drops the Ambassador Mapping / migration Job / RBAC, `:local`
image, 1 replica, no DO node-affinity):
```bash
cd treetracker-field-data
docker build -t treetracker-field-data:local .
k3d image import treetracker-field-data:local -c greenstand
kubectl apply -k deployment/overlays/local
kubectl -n field-data-api rollout status deploy/treetracker-field-data
```
- Env (both DB URLs → the one `treetracker` DB; field_data via `DATABASE_SCHEMA`, public.trees via the
  legacy connection): `DATABASE_URL` + `DATABASE_URL_LEGACYDB` = `database-connection/db`,
  `RABBIT_MQ_URL` = `rabbitmq-connection/messageQueue`. HTTP :3006, Service exposes **:80→3006**
  at `treetracker-field-data.field-data-api.svc`.
- Healthy log: `setting a schema` / `listening on port:3006`.

---

## AWS `local` environment (real AWS, not LocalStack)
The Android→S3→SQS leg uses **real AWS**: account `053061259712`, region `eu-central-1`, CLI profile
**`greenstand`** (creds in `~/.aws`, never committed). Resources (`treetracker-local-*`):
batch-uploads bucket (JSON bundles), images bucket (photos), SQS `treetracker-local-queue`, Cognito pool
`treetracker_local` (unauth), IAM role `treetracker-local-cognito-unauth` (inline policy
`treetracker-local-s3-put`).

**Two fixes the Android upload requires** — the app does `PutObject` with a **public-read ACL**
(`x-amz-grant-read:…AllUsers`) on every object; without both, the app's "ready to upload" counter
never drains and both buckets stay empty:
1. **Buckets must allow ACLs.** They were created ACL-disabled (modern default `BucketOwnerEnforced`)
   → `400 AccessControlListNotSupported`. Per bucket:
   ```bash
   aws s3api put-bucket-ownership-controls --bucket <b> \
     --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]'
   aws s3api put-public-access-block --bucket <b> \
     --public-access-block-configuration 'BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false'
   ```
2. **Cognito unauth role needs `s3:PutObjectAcl`** (+`s3:PutObjectVersionAcl`) → else
   `403 … not authorized to perform s3:PutObjectAcl`. Add them to the inline policy alongside
   `s3:PutObject`/`GetObject`/… (IAM eval is live — cached Cognito creds pick it up immediately).

The **bulk-pack-consumer** reads SQS+S3 from the shared LocalStack (fully local, no real AWS). The
capture adapter (`k3s/services/capture/standalone.yaml`) declares its Secrets as DUMMY literals and
`up.sh` creates them imperatively (never real creds, never in git). Env keys: `DATABASE_URL`
(data_pipeline DB), `SQS_URL` (LocalStack queue via `host.k3d.internal`), `AWS_ACCESS_KEY_ID`,
`AWS_ACCESS_KEY` (note: **not** `_SECRET_`; LocalStack accepts any), plus `AWS_ENDPOINT` +
`AWS_REGION` from the `localstack-endpoint` secret. Checks (against LocalStack): `awslocal s3 ls
s3://treetracker-local-batch-uploads/ --recursive` · `awslocal sqs get-queue-attributes
--queue-url <q> --attribute-names ApproximateNumberOfMessages` (run inside the `greenstand-localstack`
container).

## Environment gotchas (found the hard way)
- **Fake-IP DNS breaks a fresh cluster.** k3d writes the kubeconfig API server as
  `host.docker.internal:<port>`; ClashX fake-IP DNS resolves that to a bogus `198.18.x.x` → `kubectl`
  gets `EOF`. `up.sh` (step_cluster) rewrites the server to `https://127.0.0.1:<port>` (serverlb publishes
  6443 on `0.0.0.0`; `127.0.0.1` is in the API cert SANs).
- **Cold-cluster OpenAPI lag.** Right after create, `kubectl apply` validation fails
  `failed to download openapi … EOF`. `step_cluster` gates on `/readyz`==ok + `/openapi/v2` + node Ready
  before anything applies.
- **chromedriver must match host Chrome major** (admin `/verify` step drives Chrome) — bump
  `apps/e2e` `chromedriver@^<major>` when Chrome updates (147→150 here).
- **npm ci peer-dep conflicts** (node16/npm8) in some service repos (e.g. `co-mocha` vs `mocha@8`) →
  build with `npm ci --omit=dev --legacy-peer-deps`.
- **Async session → capture 409.** field-data creates sessions asynchronously, so a capture POSTed
  right after its session 409s ("session … yet to be created") and is left `processed=f`; the
  bulk-pack-processor cron is `* * * * *` locally so retries land within the e2e `/verify` poll window.
- **treetracker-api uses a `treetracker` schema** (not public): the migrate step does
  `CREATE SCHEMA treetracker; ALTER DATABASE treetracker SET search_path TO treetracker, public;`
  then runs its db-migrate migrations.

## API gateway (Ambassador / Emissary-ingress)
The browser reaches everything through **one origin — `http://localhost:8088`** (the k3d loadbalancer →
Emissary), routed by each service's **shipped `getambassador.io` Mapping** (`/api/admin/` → admin-api,
`/images/` → images-api, `/field-data/`, `/treetracker/`, all `rewrite: /`) plus an admin-client `/`
Mapping. the gateway adapter hook (`k3s/services/gateway/hooks/up.sh`) installs Emissary (CRDs + helm) and a `Listener` + wildcard `Host`
(`k3s/services/gateway/emissary.yaml`) **before** the service overlays (which now keep their Mappings). No per-service
port-forward, no nginx reverse-proxy (admin-client nginx serves static only); single origin ⇒ no CORS.

## Status
**Done — full capture→verify stack, `apps/e2e` `03_capture_setup` passes 19/19** (via the Ambassador
gateway, and after a from-scratch `down.sh`→`up.sh` rebuild). Cluster, Postgres (+ `treetracker`,
`data_pipeline`, `field_data` schemas), RabbitMQ, Emissary gateway, treetracker-field-data,
treetracker-api, images-api, bulk-pack-transformer-v2, bulk-pack-processor (CronJob `*/1`),
**bulk-pack-consumer** (SQS→`bulk_tree_upload`, `pg@8` — replaced the old `treetracker-data-pipeline`
consumer that hung on PG15 SCRAM), admin-api + admin-client (legacy username/password + `JWT_SECRET`,
no Keycloak). `./k3s/up.sh` brings it all up and prints `ADMIN_URL=http://localhost:8088`.

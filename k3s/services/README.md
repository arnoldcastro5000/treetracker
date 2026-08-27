# k3s/services - stand-up adapters + vendored local-dev deployment config

This directory holds two kinds of folders:

1. **Stand-up adapters** - every folder with a `standalone.yaml` is one SUBSYSTEM the
   orchestrator (`k3s/up.sh`) discovers and stands up. Current adapters: `postgres`, `gateway`,
   `rabbitmq`, `localstack` (shared tier) and `capture` (the capture -> verify pipeline).
2. **Vendored per-service overlays** - folders without a `standalone.yaml` (for example
   `treetracker-field-data/`). They are plain kustomize overlays that an adapter's aggregate
   overlay references; the orchestrator never reads them directly.

## The stand-up contract (`standalone.yaml`)

Adding a repo to the environment = adding one adapter folder here. The orchestrator is never
edited. Schema (all paths are repo-root relative):

```yaml
name: my-subsystem
tier: universal | conditional   # tier services only. universal = always stands up;
                                # conditional = only when a selected subsystem dependsOn it.
optIn: true                     # subsystems only: excluded from a bare `up.sh`, included when named.
dependsOn: [postgres, gateway]  # adapters that must be fully up first (transitive).
namespaces: [my-ns]             # the namespace GROUP this subsystem owns (collision-checked).
databases: [mydb]               # ensured (idempotent createdb) on the shared Postgres before hooks.
images:
  - name: my-service            # built from `context` as my-service:local, imported into the cluster
    context: my-service         # (submodule dir). Optional: dockerfile, extraContexts {name: path}.
  - pull: redis:7-alpine        # pulled + imported verbatim (no build).
secrets:                        # created imperatively as plain Secrets. DUMMY literals only,
  - namespace: my-ns            # never real credentials. ${VAR} expands from the orchestrator
    name: my-secret             # config (LOCALSTACK_PORT, OBJECT_STORAGE_REGION, ...).
    literals: { key: value }
objectStorage:                  # provisioned idempotently on the shared LocalStack, one region.
  buckets: [my-bucket]
  queues: [my-queue]
  notifications:
    - { bucket: my-bucket, queue: my-queue, events: ["s3:ObjectCreated:*"] }
overlay: k3s/services/my-subsystem   # kustomize dir applied after images are in the cluster.
waitFor:                        # Deployments that signal ready. `image` ties the Deployment to
  - namespace: my-ns            # its build so --rebuild rolls exactly what changed.
    deployment: my-service
    image: my-service:local
hooks:
  pre:  path.sh                 # after deps + databases + objectStorage, before the overlay applies
  up:   path.sh                 # after the overlay (or instead of one) for bespoke bring-up
  post: path.sh                 # after waitFor (seeds, readiness gates)
  down: path.sh                 # run by down.sh for state outside the cluster
verify: path.sh                 # the subsystem's definition-of-done check; up.sh runs it as a
                                # hard gate after stand-up (skip: --no-verify; alone: up.sh verify)
```

Per adapter the orchestrator runs: ensure namespaces -> create secrets -> ensure databases ->
provision object storage -> `pre` -> build/pull images -> apply `overlay` -> `up` -> `waitFor` ->
`post`; then, after every selected adapter is up, each `verify`. Contract tests:
`k3s/orchestrator-test.sh`.

## Vendored overlays

The overlay files are vendored into the superproject rather than pulled from each
service submodule, because the superproject is the long-term home for how the stack runs locally
(the monorepo direction) and because it removes any dependency on the service repos' `k3s` side
branches, which could be squash-merged or deleted.

## What lives here

For six services this is the `deployment/overlays/local` kustomize overlay (a thin local layer on
top of each submodule's committed `deployment/base`). For the admin-client it is the local build
config (there is no kustomize base to reuse).

Two services also vendor an override `Dockerfile` here (see the table). It builds from the submodule
source as context and pulls extra files from the `localdeploy` named build context
(`--build-context localdeploy=k3s/services/<name>`, wired by `up.sh` from the adapter's
`extraContexts`). The admin-client overlays `nginx.conf` this way; bulk-pack-transformer-v2 overlays
a submodule SOURCE file, `s3.js`, so the local image reaches LocalStack for its S3 upload. The
vendored `s3.js` is a strict superset of upstream (endpoint honored only when `AWS_ENDPOINT` is set),
so the submodule pin stays pristine and production behavior is unchanged.

| Service | Source: repo `k3s` branch @ sha | Vendored files |
|---|---|---|
| treetracker-field-data | `c0fe3dd0` | `kustomization.yaml`, `secrets.yaml` |
| treetracker-api | `5c2dbd29` | `kustomization.yaml`, `namespace.yaml`, `secrets.yaml` |
| bulk-pack-transformer-v2 | `02f32f19` | `kustomization.yaml`, `namespace.yaml`, `Dockerfile`, `s3.js` |
| bulk-pack-processor | `657a3606` | `kustomization.yaml`, `cronjob.yaml` |
| treetracker-admin-api | `a6c8fbee` | `kustomization.yaml`, `namespace.yaml`, `secrets.yaml` |
| images-api | `c96d5a13` | `kustomization.yaml` |
| treetracker-admin-client | `ee69221c` (trio) | `Dockerfile`, `nginx.conf`, `k8s.yaml`, `Dockerfile.dockerignore` |

## The relative-base contract (the five overlays that reuse a base)

Every overlay except `bulk-pack-processor` (which ships a self-contained `cronjob.yaml`) references
its submodule's base by relative path. The upstream overlays live at
`<submodule>/deployment/overlays/local/` and reference `../../base`; vendored here at
`k3s/services/<name>/`, that path is rewritten to:

```
resources:
  - ../../../<submodule>/deployment/base
```

This reuses the base in place (no duplication). It is safe because the base at each submodule's
**recorded pin** is byte-identical to the base the overlay was written against: the service `k3s`
branches added only the `deployment/overlays/local` files on top of the recorded pin, with zero
change to `deployment/base`. `kubectl kustomize k3s/services/<name>` is the check that this holds.

Drift risk: if a service's `deployment/base` changes before the service folds into the monorepo, a
vendored overlay could break without the submodule pin moving. Mitigation: `k3s/smoke.sh` exercises
every service end to end, so a broken overlay fails the smoke test.

## admin-client specifics

The admin-client pin tracks upstream `master` (2.0.0, `ecbfe050`), which carries no `deployment/`
tree, so its local build config is vendored here instead. The image build (in `up.sh`) uses the
submodule as the build context for the app source and pulls `nginx.conf` from this directory via a
named build context:

```
docker build -f k3s/services/treetracker-admin-client/Dockerfile \
  --build-context localdeploy=k3s/services/treetracker-admin-client treetracker-admin-client
```

`Dockerfile.dockerignore` is the BuildKit per-Dockerfile ignore file (applied to the submodule
context). The Dockerfile sets `CYPRESS_INSTALL_BINARY=0` so the Cypress devDependency's postinstall
binary download does not break the build on restricted networks.

## Refreshing a vendored overlay

If an upstream overlay changes and you need to re-vendor, copy the file from the service repo's
`k3s` branch and re-apply the `../../base` -> `../../../<submodule>/deployment/base` rewrite, then
confirm with `kubectl kustomize k3s/services/<name>`.

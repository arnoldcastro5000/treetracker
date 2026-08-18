# k3s/services - vendored local-dev deployment config

This directory holds the Kubernetes config needed to run each backend service in the local k3d
stack (`k3s/up.sh`). The files are vendored into the superproject rather than pulled from each
service submodule, because the superproject is the long-term home for how the stack runs locally
(the monorepo direction) and because it removes any dependency on the service repos' `k3s` side
branches, which could be squash-merged or deleted.

## What lives here

For six services this is the `deployment/overlays/local` kustomize overlay (a thin local layer on
top of each submodule's committed `deployment/base`). For the admin-client it is the local build
config (there is no kustomize base to reuse).

| Service | Source: repo `k3s` branch @ sha | Vendored files |
|---|---|---|
| treetracker-field-data | `c0fe3dd0` | `kustomization.yaml`, `secrets.yaml` |
| treetracker-api | `5c2dbd29` | `kustomization.yaml`, `namespace.yaml`, `secrets.yaml` |
| bulk-pack-transformer-v2 | `02f32f19` | `kustomization.yaml`, `namespace.yaml` |
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

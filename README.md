# Greenstand Treetracker monorepo

Treetracker tracks and verifies the trees that smallholder growers plant, so organizations can
pay the growers. Treetracker is a project of [Greenstand](https://greenstand.org), and the
upstream code is in the [Greenstand GitHub organization](https://github.com/Greenstand).

This repository is the umbrella for the Treetracker platform. It contains every application as a
git submodule. The `k3s/` directory holds a stand-alone Kubernetes environment that runs the
platform on your own machine. The default standup is the capture pipeline (Android app uploads ->
processing -> admin verification). The wallet app and more subsystems are opt-ins. You need no
secrets and no access to Greenstand servers. For help, open an issue on this repository.

Status: this monorepo is in the build stage. Greenstand production currently deploys from the
individual repositories; this repository is being validated as the future single deployment
source. The local environment below works today.

## Quickstart

```bash
git clone --recurse-submodules https://github.com/arnoldcastro5000/treetracker.git
cd treetracker
./k3s/prepare-linux.sh     # macOS: ./k3s/prepare.sh   (run once per machine)
./k3s/up.sh
```

Success is: `up.sh` ends with every verify check green. The environment then serves the admin
panel and the APIs at `http://localhost:8088`. Re-check any time with `./k3s/up.sh verify`. Tear
down with `./k3s/down.sh`.

Useful variants:

```bash
./k3s/up.sh plan           # print what would stand up; touches nothing
./k3s/up.sh capture        # one subsystem and its dependencies only
./k3s/up.sh wallet-app     # opt-in: wallet web app + backend + Keycloak
```

## Requirements

- OS: Linux or macOS. Windows: use WSL2 (Ubuntu) with Docker Desktop, then follow the Linux steps
  inside WSL2. Native Windows is not supported.
- Docker Engine (Linux) or Docker Desktop (macOS), running. The prepare script installs the other
  tools (kubectl, k3d, helm, yq, jq, psql; macOS via Homebrew).
- Hardware floor: 4 CPU cores, 8 GB RAM, ~20 GB free disk for the core stack. The optional local
  Android emulator work needs 16 GB RAM and KVM; the Android e2e suite normally runs in CI instead
  (`.github/workflows/android-e2e-route2.yml`).
- Host ports 8088 (HTTP) and 8443 (HTTPS) must be free. Override with `GATEWAY_HTTP_PORT` /
  `GATEWAY_HTTPS_PORT` before the first `up.sh`.
- Network: the standup pulls from these hosts. On a restricted network, allow them:
  `registry-1.docker.io`, `auth.docker.io`, `quay.io`, `app.getambassador.io`,
  `datawire-static-files.s3.amazonaws.com`, `registry.npmjs.org`, `registry.yarnpkg.com`,
  `dl.k8s.io`, `cdn.dl.k8s.io`, `github.com`, `objects.githubusercontent.com`,
  `release-assets.githubusercontent.com`, `get.helm.sh`, `archive.ubuntu.com`,
  `security.ubuntu.com` (and optionally `awscli.amazonaws.com`). A blocked pull fails fast and
  names the exact host to allow.

## Submodules

Every application lives in this repository as a git submodule. The clone pins each submodule to the
exact commit this environment was validated with. Do not switch submodule branches for a normal
standup. Developers who work on a submodule can opt in to branch tips with
`FOLLOW_SUBMODULE_BRANCHES=1 ./k3s/prepare-linux.sh`.

A submodule is "working" when it has a stand-up adapter in `k3s/`, starts on the local cluster, and
passes its verify check. A submodule is "considered for integration" when the team plans to add it
but has not built the adapter yet.

### Working today

These submodules stand up and verify on the local cluster. They are grouped by subsystem.

**Capture pipeline** (the default `./k3s/up.sh`). An Android device uploads a tree capture, the
pipeline processes it, and the admin panel verifies it.

- `treetracker-android`: the Android capture app. It sends captures to the pipeline. It runs in
  the end-to-end test suite (`apps/e2e`), not as a Kubernetes service.
- `treetracker-database`: the shared Postgres schema. The capture standup loads it before the
  services start.
- `bulk-pack-consumer`: reads new uploads from the queue and hands them to the pipeline.
- `bulk-pack-processor`: processes each upload bundle. It runs as a scheduled job (CronJob).
- `bulk-pack-transformer`: transforms upload data (version 1).
- `bulk-pack-transformer-v2`: transforms upload data (version 2; captures and tracks).
- `treetracker-field-data`: the field-data API. It writes the final `raw_capture` rows.
- `treetracker-api`: the core Treetracker API.
- `images-api`: stores and serves the capture images.
- `treetracker-admin-api`: the backend for the admin panel.
- `treetracker-admin-client`: the admin panel web app. It serves the `/verify` page.

**Wallet app** (opt-in: `./k3s/up.sh wallet-app`). The wallet web app, its backend, and a shared
Keycloak for login.

- `treetracker-wallet-app`: the wallet web app plus its user backend.
- `treetracker-wallet-api`: the wallet backend API.

**Web map** (opt-in: `./k3s/up.sh web-map`). A map that renders the tracked trees. It serves at
`/map`.

- `treetracker-web-map-client`: the map web app.
- `treetracker-query-api`: serves the map data queries.
- `node-mapnik-1`: the vector tile server. It renders the map tiles.

### Considered for integration

These are planned but not wired up yet. They do not stand up today.

- `treetracker-infrastructure`: the upstream infrastructure and deploy configuration. It is
  already a submodule in this repository, but it has no local adapter. The team keeps it as a
  reference for the future production profile.
- `wallet-admin-client` (not yet a submodule): the admin web app for wallets. It is planned as a
  local adapter under the wallet subsystem.
- `stakeholder-api` (not yet a submodule): the stakeholder (organization) API. It is planned for
  both local and production.
- `treetracker-airflow-dags` and Airflow (not yet a submodule): data pipeline orchestration. It
  is planned for both local and production.
- `webmap-query-service-consumer` (not yet a submodule): an enrichment step for the web map. It is
  planned as an opt-in add-on to the web-map subsystem.

## More documentation

- Volunteers: [`k3s/README.md`](k3s/README.md) describes how the local environment works.
- Contributors: [`k3s/services/README.md`](k3s/services/README.md) describes the stand-up adapter
  contract (how to add a subsystem), and [`apps/e2e/`](apps/e2e/) contains the Android end-to-end
  suite.
- Operators: `docs/production/` will describe the production profile. The production-profile work
  creates that directory.

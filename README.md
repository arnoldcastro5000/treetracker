# Greenstand Treetracker monorepo

Treetracker tracks and verifies the trees that smallholder growers plant, so organizations can
pay the growers. Treetracker is a project of [Greenstand](https://greenstand.org), and the
upstream code is in the [Greenstand GitHub organization](https://github.com/Greenstand).

This repository is the umbrella for the Treetracker platform. It contains every application as a
git submodule. The `k3s/` directory holds a stand-alone Kubernetes environment that runs the
platform on your own machine. The default standup is the capture pipeline (Android app uploads ->
processing -> admin verification). The wallet app and more subsystems are opt-ins. You need no
secrets and no access to Greenstand servers.

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

The clone pins every submodule to the exact commit this environment was validated with. Do not
switch submodule branches for a normal standup. Developers who work on a submodule can opt in to
branch tips with `FOLLOW_SUBMODULE_BRANCHES=1 ./k3s/prepare-linux.sh`.

## More documentation

- Volunteers: [`k3s/README.md`](k3s/README.md) describes how the local environment works.
- Contributors: [`k3s/services/README.md`](k3s/services/README.md) describes the stand-up adapter
  contract (how to add a subsystem), and [`apps/e2e/`](apps/e2e/) contains the Android end-to-end
  suite.
- Operators: `docs/production/` will describe the production profile. The production-profile work
  creates that directory.

# The stand-alone k3s environment

This directory runs the Treetracker platform on your own machine, inside one local
[k3d](https://k3d.io) cluster named `greenstand` (kube context `k3d-greenstand`). You need no
secrets and no access to Greenstand servers. The root [README](../README.md) has the quickstart, the requirements, and the
network-host list. This file describes how the environment works.

## Subsystems

`up.sh` discovers stand-up adapters: every `services/*/standalone.yaml` is one subsystem.
[`services/README.md`](services/README.md) describes the adapter contract and how to add a
subsystem.

| Subsystem | Command | Contents |
|---|---|---|
| capture (default) | `./k3s/up.sh` | The capture pipeline: treetracker-field-data, treetracker-api, images-api, the four bulk-pack services, admin-api, and the admin client. |
| wallet-app (opt-in) | `./k3s/up.sh wallet-app` | The wallet web app, the wallet API, the user backend, and Keycloak. |

PostgreSQL and the Emissary gateway are universal tier services: they always stand up. RabbitMQ,
LocalStack, and Keycloak stand up when a selected subsystem declares them as dependencies.

## Commands

```bash
./k3s/prepare-linux.sh   # once per machine (Linux): install the tools
./k3s/prepare.sh         # once per machine (macOS, via Homebrew): install the tools
./k3s/up.sh              # stand up every subsystem, then verify
./k3s/up.sh <subsystem>  # one subsystem and its dependencies
./k3s/up.sh plan         # print the resolved stand-up order; touches nothing
./k3s/up.sh verify       # re-run only the verify hooks
./k3s/down.sh            # tear down: delete the cluster (all pods and data)
./k3s/down.sh --namespaces   # keep the cluster, drop the stack namespaces
./k3s/down.sh --images       # also remove the built and pulled images
```

`up.sh` is idempotent and readiness-gated: a re-run repairs and continues. It does not duplicate
work. An image build is gated on presence in the cluster, so a re-run skips the images that are
already loaded and rebuilds only the missing ones. `--rebuild` forces the builds and rolls the
affected deployments.

## How verify decides green

After every selected adapter is up, its declared verify hook runs as a hard gate. "`up.sh`
succeeded" means "the environment works". The capture verify hook is `smoke.sh`, an in-cluster
smoke test that follows a capture from upload to the admin panel. Re-check any time with
`./k3s/up.sh verify`. Skip the gate with `--no-verify` when you iterate.

## The gateway and the endpoints

The browser reaches everything through one origin: `http://localhost:8088` (the k3d load balancer
to Emissary-ingress). Each service ships its own `getambassador.io` Mapping (`/api/admin/` to
admin-api, `/images/` to images-api, `/field-data/`, `/treetracker/`), and the admin client maps
`/`. One origin means no CORS and no per-service port-forward. The capture standup prints
`ADMIN_URL=http://localhost:8088`, and `up.sh` ends with the gateway URL.

## Environment knobs

- `GATEWAY_HTTP_PORT` / `GATEWAY_HTTPS_PORT`: the host ports (defaults 8088/8443). Set them
  before the first `up.sh` if the defaults are taken.
- `FOLLOW_SUBMODULE_BRANCHES=1` on `prepare*.sh`: developer opt-in to submodule branch tips. The
  default pins every submodule to the validated commit.
- `ENV=local` (default) runs on k3d. `ENV=ci` targets an existing kube context (`KUBE_CONTEXT`)
  and pushes images to `$IMAGE_REGISTRY`. The same script serves both.
- `NO_VERIFY=1` (or `--no-verify`): skip the verify gate.

## Databases and schemas

One shared PostgreSQL pod (namespace `data`) holds the `treetracker` database (schemas `public`,
`field_data`, `treetracker`) and the `data_pipeline` database. Each adapter declares its
databases in `standalone.yaml`, and its hooks run the migrations. You do not run migrations by
hand.

## The AWS `local` environment for the Android app (optional)

The standup itself needs no AWS account: LocalStack provides S3 and SQS as a host-side Docker
container on port 4566 (not a cluster workload), and the capture adapter declares its secrets as
dummy literals that `up.sh` creates imperatively (never real credentials, never in git).

The optional Android-app leg uses real AWS, so the app's Cognito-based S3 upload works with full
fidelity: account `053061259712`, region `eu-central-1`, CLI profile `greenstand` (credentials in
`~/.aws`, never committed). The provisioned resources:

| Resource | Identifier |
|---|---|
| Batch-uploads bucket | `treetracker-local-batch-uploads` (capture and session JSON) |
| Images bucket | `treetracker-local-images` |
| SQS queue | `treetracker-local-queue` |
| S3-to-SQS notification | `s3:ObjectCreated:*` on the batch-uploads bucket |
| Cognito identity pool | `treetracker_local` (`eu-central-1:a9ae848f-b57a-411c-97f8-68127119fc2c`, unauth enabled) |
| IAM unauth role | `treetracker-local-cognito-unauth` (inline `s3:PutObject` on both buckets) |

The app does `PutObject` with a public-read ACL on every object. The setup needs two fixes, or
the app's "ready to upload" counter never drains: the buckets must allow ACLs, and the Cognito
unauth role needs `s3:PutObjectAcl` and `s3:PutObjectVersionAcl` in its inline policy. Per
bucket:

```bash
aws s3api put-bucket-ownership-controls --bucket <bucket> \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerPreferred}]'
aws s3api put-public-access-block --bucket <bucket> \
  --public-access-block-configuration 'BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false'
```

## The Android `local` build (optional)

The `local` build type (`treetracker-android/app/build.gradle`) wires the app to the resources
above and points `API_GATEWAY` at the local ingress. Build notes:

- Use JDK 17 (the version CI builds with; see `.github/workflows/android-e2e-route2.yml`) and set
  `ANDROID_HOME` (or `sdk.dir` in the gitignored `local.properties`). JDK 21 also works; Gradle
  8.13 rejects the newest JDKs.
- `app/google-services.json` has a `.local` client, so the Firebase plugin accepts the package.
- Build with `./gradlew :app:assembleLocal`. The APK is
  `app/build/outputs/apk/local/app-local.apk`, package
  `org.greenstand.android.TreeTracker.local`. The e2e config (`apps/e2e/.env`, the wdio
  capabilities) must use this package and APK path.

The Android e2e suite normally runs in CI against this stack
(`.github/workflows/android-e2e-route2.yml`); a local run is optional.

## Troubleshooting

- Wrong kube context: your context can point at another cluster. Run
  `kubectl config use-context k3d-greenstand` before manual `kubectl` commands.
- After a Docker or machine restart the cluster is stopped, not gone: run
  `k3d cluster start greenstand`, or just re-run `./k3s/up.sh`.
- A blocked network pull fails fast and names the exact host to allow. The root README lists the
  hosts.
- `kubectl` gets `EOF` against a fresh cluster: some DNS setups resolve `host.docker.internal` to
  a bogus address. `up.sh` rewrites the API server to `https://127.0.0.1:<port>` for you.
- The admin `/verify` e2e step drives Chrome: the `apps/e2e` `chromedriver` major version must
  match the host Chrome. Bump it when Chrome updates.
- Some service repos hit `npm ci` peer-dependency conflicts on their pinned toolchains. The
  adapters build with `--legacy-peer-deps` where needed.
- A capture that arrives before its session gets a 409 and stays unprocessed for a short time.
  The bulk-pack-processor CronJob runs every minute locally, so the retry lands within the
  verify poll window.

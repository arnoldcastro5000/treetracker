# Component coverage

This page lists, in detail, how much of the Greenstand production estate the monorepo covers, and
how each item maps to a submodule.

We checked the monorepo against everything Greenstand runs in production today: **55 components** in
all (application services, static sites, jobs, platform pieces, data stores, and the mobile app).
Each component gets one gap class:

- **Covered** - the source is in the monorepo and it stands up and passes its checks locally (some
  platform pieces are covered by a local substitute, noted per row).
- **Wired, not yet standing up** - the source is in the monorepo, but no local stand-up runs yet.
- **Not yet integrated** - the source is not in the monorepo yet.
- **Out of scope** - deliberately excluded from this effort.

Snapshot counts (baseline 2026-08-25): **covered 21 &middot; wired-not-standing-up 8 &middot;
not-integrated 10 &middot; out-of-scope 16**.

> **Update since the snapshot (2026-08-27).** The web-map thin spine has since been built and now
> stands up (`./k3s/up.sh web-map`, verify green), and `node-mapnik-1` is now a submodule on `main`.
> So the three rows marked "now built" below have moved from "wired, not standing up" to covered. If
> recounted today, covered is about 24 and wired-not-standing-up about 5. The snapshot counts above
> are kept as the reference figure used in the status report.

For the executive view of these figures, see the program status report. For the plain repo view of
what is a submodule, see the [Submodules section of the README](../README.md#submodules).

## Covered (21)

| Component (production) | Submodule / source | Local stand-up |
| --- | --- | --- |
| treetracker-api | `treetracker-api` | built (capture) |
| field-data API | `treetracker-field-data` | built (capture) |
| admin API | `treetracker-admin-api` | built (capture) |
| wallet API | `treetracker-wallet-api` | built (wallet-app, opt-in) |
| images API | `images-api` | built (capture) |
| bulk-pack-consumer | `bulk-pack-consumer` | built (capture) |
| bulk-pack-processor | `bulk-pack-processor` | built (capture, scheduled job) |
| bulk-pack-transformer (v1) | `bulk-pack-transformer` | built (capture) |
| bulk-pack-transformer-v2 | `bulk-pack-transformer-v2` | built (capture) |
| Admin panel (web) | `treetracker-admin-client` | built (capture, served at `/`) |
| Admin panel, Freetown tenant | `treetracker-admin-client` (same source) | source covered; tenant config is a production-profile item |
| Wallet app (web) | `treetracker-wallet-app` | built (wallet-app, opt-in) |
| Gateway | local Emissary adapter; upstream config in `treetracker-infrastructure` | built (local substitute) |
| Keycloak sign-in | local adapter; config in `treetracker-infrastructure` | built (local substitute) |
| pgpool | none (local uses direct Postgres) | covered by substitute |
| RabbitMQ | local adapter; config in `treetracker-infrastructure` | built (local substitute) |
| Secret management | none (local uses dummy secrets) | covered by substitute |
| Postgres database | postgres adapter; schema from `treetracker-database` | built (local substitute) |
| Object storage (S3) | LocalStack adapter | built (local substitute) |
| Android app | `treetracker-android` | covered as the automated-test client (emulator) |

_Note: this table lists 20 explicit rows; the snapshot headline count is 21. The one-row difference
is an off-by-one in the source snapshot and does not change the picture._

## Wired, not yet standing up (8)

| Component (production) | Submodule / source | Note |
| --- | --- | --- |
| query API | `treetracker-query-api` | **now built** (web-map, opt-in) |
| web-map client | `treetracker-web-map-client` | **now built** (web-map, opt-in) |
| tile server | `node-mapnik-1` | **now built** (web-map, opt-in); now a submodule on `main` |
| Airflow + DAGs | `treetracker-airflow-dags` on the `wt-integrate` branch only (not in `main`) | opt-in decided, not built |
| tile-warm cronjob | config in `treetracker-infrastructure` | folds into the tile-server stand-up |
| Monitoring (metrics, logs) | config in `treetracker-infrastructure` | production-profile item |
| Bastion host | config in `treetracker-infrastructure` | production-profile item |
| Production backups bucket | config in `treetracker-infrastructure` | production-profile item |

## Not yet integrated (10)

None of these is a submodule yet.

| Component (production) | Planned as | Note |
| --- | --- | --- |
| stakeholder API | submodule + adapter | on the prod cluster; release pipeline failing since 2026-05 |
| wallet-admin-client | submodule + adapter (wallet) | actively deployed; zero integration |
| webmap-query-service-consumer | opt-in add-on to web-map | charted; integration is the missing step |
| messaging API | rule in or out | frozen since 2023; needs a live-traffic check |
| earnings API | rule in or out | frozen since 2023; needs a live-traffic check |
| reporting | rule in or out | frozen since 2023; reachable via admin + Airflow |
| denormalization | rule in or out | frozen since 2024; reachable via the web-map data path |
| contract API | rule in or out | frozen since 2023 |
| regions API | rule in or out | frozen since 2022 |
| queue service | rule in or out | frozen; dev-only schema |

## Out of scope (16)

Deliberately excluded from this effort. None is a submodule.

| Component | Reason |
| --- | --- |
| Herbarium content site | content site, not reachable from any monorepo product |
| Legacy static web map | superseded by the k8s web-map client |
| wallet-web-client dev site | repo gone |
| Solr + search | only consumer is frozen since 2022 |
| Jaeger tracing | no monorepo product depends on it |
| Botkube | ops chat tooling |
| OpenProject | org tooling, not a product |
| CKAN | dev-only values |
| cdn-images-api (CloudFront) | repo gone |
| treetracker-search | frozen |
| treetracker-functions | frozen |
| map-config-api | ruled out by the web-map plan |
| treetracker-auth | frozen |
| grower-account-query | frozen |
| treetracker-mobile-api | frozen |
| treetracker-web-map-api | ruled out by the web-map plan |

## How this maps to the 17 submodules

The repo has 17 submodules (see the README). They account for the coverage above as follows:

- **15 product-service submodules are covered / built:** `treetracker-api`, `treetracker-field-data`,
  `treetracker-admin-api`, `treetracker-wallet-api`, `images-api`, `bulk-pack-consumer`,
  `bulk-pack-processor`, `bulk-pack-transformer`, `bulk-pack-transformer-v2`,
  `treetracker-admin-client`, `treetracker-wallet-app`, `treetracker-android`,
  `treetracker-query-api`, `treetracker-web-map-client`, `node-mapnik-1` (the last three via the
  web-map opt-in).
- **`treetracker-database`** is the shared Postgres schema behind the database substitute (covered).
- **`treetracker-infrastructure`** is the source for the platform pieces (gateway, sign-in, queue,
  monitoring, bastion, backups). Locally these are covered by substitutes; in production they are the
  production-profile work.

Everything counted as "not yet integrated" or "out of scope" is **not a submodule**. The only planned
submodule that already exists but is not on `main` is `treetracker-airflow-dags` (on the
`wt-integrate` branch), which the README lists under "Considered for integration".

---

_Source: the estate-coverage assessment (`.scratch/estate-coverage`), validated by a live
`./k3s/up.sh verify` (17 of 17 checks green) and a green CI gate run. "Covered" means proven by a
real run, not by document review._

# Kubernetes deployment

`kubernetes/` is a small [Kustomize](https://kustomize.io/) overlay that deploys
a single `CronJob` running the `teslamate-fuel-roi` image. There is no
ConfigMap, RBAC, ServiceAccount, or spawned `Job`: the `CronJob`'s container runs
the image entrypoint, which fetches the MASE report and then imports it, so each
scheduled run is one fetch-and-import cycle.

The `CronJob` is named `fuel-roi` and runs **Mondays at 20:00**
(`schedule: "0 20 * * 1"`), after MASE publishes the weekly report. It sets
`concurrencyPolicy: Forbid` so an overrun never runs two imports at once, keeps
three successful and three failed Jobs for inspection, and retries a failed pod
twice (`backoffLimit: 2`).

The pod runs as non-root (`runAsNonRoot: true`, UID/GID `10001`, matching the
image's `fuelroi` user).

## Namespace

The default namespace comes from `kubernetes/kustomization.yaml`:

```yaml
namespace: teslamate
```

`teslamate` is the namespace TeslaMate itself commonly runs in. This is only a
default — edit that line to target a different namespace before applying.

## Database credentials

The container reads libpq's standard `PG*` variables. All of them are supplied
at once by `envFrom`-ing a Secret named **`fuel-roi-db`** (referenced in
`kubernetes/cronjob.yaml`).

Create that Secret with the five keys the app expects — `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD`, `PGDATABASE`:

```sh
kubectl -n teslamate create secret generic fuel-roi-db \
  --from-literal=PGHOST=teslamate-postgres-rw \
  --from-literal=PGPORT=5432 \
  --from-literal=PGUSER=teslamate \
  --from-literal=PGPASSWORD="$PGPASSWORD" \
  --from-literal=PGDATABASE=teslamate
```

The database user must be able to `CREATE SCHEMA fuel`; the image creates the
schema and tables on first run and only ever writes inside `fuel`.

### Reusing the CloudNativePG secret

If TeslaMate runs on [CloudNativePG](https://cloudnative-pg.io/), its generated
`teslamate-postgres-app` Secret already holds the connection details — but under
different keys: `host`, `port`, `user`, `password`, `dbname`. `envFrom` **copies
those keys verbatim and cannot rename them**, so pointing the `CronJob` at the
CNPG Secret would expose `host`/`port`/etc. and leave `PGHOST`/`PGPORT`/etc.
unset.

Reuse therefore requires mapping the keys into a small `PG*`-keyed Secret
instead of an `envFrom` of the CNPG Secret. `jq` can build a Secret that reuses
CNPG's values under the right key names (they stay base64-encoded, which `Secret`
`data` expects):

```sh
kubectl -n teslamate get secret teslamate-postgres-app -o json \
  | jq '{apiVersion:"v1", kind:"Secret", metadata:{name:"fuel-roi-db"}, data:{
        PGHOST:.data.host, PGPORT:.data.port, PGUSER:.data.user,
        PGPASSWORD:.data.password, PGDATABASE:.data.dbname}}' \
  | kubectl -n teslamate apply -f -
```

## Applying

```sh
kubectl apply -k kubernetes/
```

You can render the manifests without touching the cluster to check them first:

```sh
kubectl kustomize kubernetes/
```

## Verifying

Check the `CronJob` was created and see recent runs:

```sh
kubectl -n teslamate get cronjob fuel-roi
kubectl -n teslamate get jobs
kubectl -n teslamate get pods
```

To trigger a run immediately instead of waiting for Monday, create a one-off Job
from the `CronJob`:

```sh
kubectl -n teslamate create job --from=cronjob/fuel-roi fuel-roi-manual
kubectl -n teslamate logs job/fuel-roi-manual
```

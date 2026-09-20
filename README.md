# Fluxer (self-hosted) — Helm chart

A Helm chart that packages the **microservices** split of
[fluxerapp/fluxer](https://github.com/fluxerapp/fluxer) — an open-source (AGPL-3.0)
chat & VoIP platform — for Kubernetes. The chart installs the full
stack: infrastructure, application services, and Istio ingress.

## What this chart installs

- **Infrastructure:** postgres 16 (StatefulSet), valkey 8 (Deployment),
  nats 2.14 + JetStream (StatefulSet), meilisearch (StatefulSet),
  seaweedfs 4.34 (StatefulSet + bucket-creation Job), livekit
  (Deployment + media Service).
- **App services (stateless HTTP):** api, gateway, media-proxy, static-proxy,
  app-proxy, admin, worker.
- **Shard services (router + shard, over NATS, no Service):** users, gifs,
  messages, unfurl, snowflakes.
- **Istio VirtualService:** public routing with prefix strip on
  `/api`, `/gateway`, `/media`, `/livekit`, `/admin`, plus an (optional) TURN
  VirtualService (SNI passthrough) for voice/video.

## Prerequisites

- Kubernetes 1.28+
- Helm 3 (tested with Helm 3/4).
- A **Secret** with the `FLUXER_*` keys (see **Secrets**). The chart does not
  create the Secret by default (`secrets.create: false`).

## Install

```bash
helm upgrade --install fluxer-helm . \
  --namespace fluxer \
  --create-namespace \
  --set fluxer.domain=chat.your-domain.com
```

## Quick configuration (values.yaml)

| Field | Description | Default |
|---|---|---|
| `fluxer.domain` | Public hostname of the instance | `chat.example.com` |
| `fluxer.scheme` | `http` / `https` | `https` |
| `livekit.nodeIP` | Public IP of the inbound NAT (announced in ICE candidates) | empty (auto) |
| `livekit.mediaLBIP` | Free LoadBalancer IP for media/TURN (e.g. MetalLB) | empty |
| `livekit.turn.enabled` | Enable the TURN relay (requires hostname + TLS secret) | `false` |
| `livekit.turn.domain` | Dedicated TURN hostname (non-proxied DNS) | `turn.chat.example.com` |
| `livekit.turn.certSecret` | Secret holding the TURN TLS certificate | `fluxer-livekit-tls` |
| `storage.*.class` / `storage.*.size` | StorageClass + size per component | `standard` |
| `ingress.istio.gateway` | Istio gateway | `istio-system/istio-gateway` |
| `secrets.create` + `secrets.secretData` | Create the Secret from `stringData` | `false` |

## Secrets

The stack uses a single Secret (`secretName`, default `fluxer-secrets`) consumed
by every workload via `envFrom`. It must exist before (or together with) the
install. Two options:

### Option A — create it with kubectl (recommended; nothing sensitive in git)

```bash
kubectl create namespace fluxer
kubectl create secret generic fluxer-secrets -n fluxer \
  --from-literal=POSTGRES_PASSWORD='change-me' \
  --from-literal=FLUXER_POSTGRES_PASSWORD='change-me' \
  --from-literal=MEILI_MASTER_KEY='meili-master-key' \
  --from-literal=FLUXER_SEARCH_API_KEY='meili-master-key' \
  --from-literal=LIVEKIT_API_SECRET='livekit-secret' \
  --from-literal=FLUXER_LIVEKIT_API_SECRET='livekit-secret' \
  --from-literal=LIVEKIT_KEYS='fluxer: livekit-secret' \
  --from-literal=FLUXER_S3_ACCESS_KEY_ID='fluxer' \
  --from-literal=FLUXER_S3_SECRET_ACCESS_KEY='s3-secret' \
  --from-literal=AWS_ACCESS_KEY_ID='s3-access-key' \
  --from-literal=AWS_SECRET_ACCESS_KEY='s3-secret' \
  --from-literal=FLUXER_SUDO_MODE_SECRET='sudo-secret' \
  --from-literal=FLUXER_CONNECTION_INITIATION_SECRET='connection-secret' \
  --from-literal=FLUXER_GATEWAY_RPC_AUTH_TOKEN='rpc-token' \
  --from-literal=FLUXER_MEDIA_PROXY_SECRET_KEY='media-key' \
  --from-literal=FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64='relay-base64' \
  --from-literal=FLUXER_ADMIN_SECRET_KEY_BASE='admin-key-base' \
  --from-literal=FLUXER_ADMIN_OAUTH_CLIENT_SECRET='oauth-secret' \
  --from-literal=FLUXER_VAPID_PUBLIC_KEY='vapid-public-jwk' \
  --from-literal=FLUXER_VAPID_PRIVATE_KEY='vapid-private-jwk'
```

The **placeholders above are examples only**. Replace every value with whatever
your instance needs. Real values must never be committed to git.

### Option B — let the chart create the Secret (values in secretData)

```yaml
secrets:
  create: true
  secretData:
    POSTGRES_PASSWORD: "..."
    FLUXER_POSTGRES_PASSWORD: "..."
    # ... all keys ...
```

### What each key is

| Key | Purpose |
|---|---|
| `POSTGRES_PASSWORD` / `FLUXER_POSTGRES_PASSWORD` | Postgres password (same value; apps read `FLUXER_*`) |
| `MEILI_MASTER_KEY` / `FLUXER_SEARCH_API_KEY` | Meilisearch master key (same value) |
| `LIVEKIT_API_SECRET` / `FLUXER_LIVEKIT_API_SECRET` | LiveKit API secret (key `fluxer`) |
| `LIVEKIT_KEYS` | `key: secret` format expected by livekit-server (e.g. `fluxer: <secret>`) |
| `FLUXER_S3_ACCESS_KEY_ID` / `FLUXER_S3_SECRET_ACCESS_KEY` | SeaweedFS (S3) credentials |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Same (fluxer reads the `AWS_*` vars) |
| `FLUXER_SUDO_MODE_SECRET` | Admin sudo mode |
| `FLUXER_CONNECTION_INITIATION_SECRET` | Connection initiation (WebRTC/WebSocket) |
| `FLUXER_GATEWAY_RPC_AUTH_TOKEN` | Gateway internal RPC auth |
| `FLUXER_MEDIA_PROXY_SECRET_KEY` | media-proxy secret |
| `FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64` | Upload relay secret (base64) |
| `FLUXER_ADMIN_SECRET_KEY_BASE` | Admin panel session key |
| `FLUXER_ADMIN_OAUTH_CLIENT_SECRET` | Admin OAuth2 client secret |
| `FLUXER_VAPID_PUBLIC_KEY` / `FLUXER_VAPID_PRIVATE_KEY` | VAPID keypair (JWK) for push |

> If postgres fails with `password authentication failed`, the Secret is missing
> the `FLUXER_*` keys — the apps read the mapped names, not the infra ones.

## Storage (important)

- **Postgres** and **SeaweedFS** need a **block-backed** StorageClass
  (e.g. `standard` / `gp3` / `local-path`). Don't use SMB/NFS for postgres
  (permissions and locking) — it breaks `initdb` and WAL writes.
- The ext4 volume has `lost+found` at the root, so postgres uses
  `PGDATA=/var/lib/postgresql/data/pgdata` (a subdirectory of the mount).

## Voice/video (LiveKit + TURN)

- By default the **TURN relay is off** (`livekit.turn.enabled: false`): LiveKit
  does signaling (7880) and ICE-direct media. To enable the TURN relay, turn the
  flag on, set `livekit.turn.domain`, and create the secret
  `livekit.turn.certSecret` with the TLS certificate (or wildcard).
- `livekit.nodeIP` **must** be the public IP of the inbound NAT (never the
  cluster-internal LoadBalancer IP) — clients only send STUN to the announced candidate.
- The TURN hostname is dedicated and **cannot** be proxied by Cloudflare (TURN
  is not HTTP). Istio terminates TLS via the `livekit.turn.certSecret` cert.
- Open in the firewall: 7881/TCP, 7882/UDP, 3478/UDP and the TURN relay range →
  the media LoadBalancer IP (`livekit.mediaLBIP`).

## Distribution (OCI registry)

Releases are published as an OCI chart on GHCR by `.github/workflows/publish.yml`
(tag `v*`), and listed on Artifact Hub:

```bash
helm install fluxer oci://ghcr.io/antoniolago/fluxer-helm --version 0.2.0 \
  --namespace fluxer --create-namespace
```

- Repository URL for Artifact Hub: `oci://ghcr.io/antoniolago/fluxer-helm`
  (the chart name is part of the URL — `oci://ghcr.io/antoniolago` alone is not
  a valid chart repository).
- Artifact Hub metadata (`artifacthub-repo.yml`) has no HTTP path to live on in
  an OCI registry: the workflow pushes it to the reserved `artifacthub.io` tag
  with ORAS, which is where Artifact Hub reads it from.

## Validate (no cluster)

```bash
helm lint .
helm template fluxer . --namespace fluxer
```

## CI / E2E (GitHub Actions)

- **`.github/workflows/test.yml`** (PR/push on main): `lint` (helm lint +
  `ct lint`), `template` (defaults, e2e overrides, custom domain), and **`e2e`** —
  spins up a **KinD** cluster (`helm/kind-action`), installs the chart with
  `ci/values-e2e.yaml`, and runs `scripts/e2e-test.sh`.
- **`.github/workflows/publish.yml`** (tag `v*`): after `lint`+`e2e`, packages and
  publishes the chart to an OCI registry `oci://ghcr.io/<owner>`
  (login `GITHUB_TOKEN` + `packages: write`).
- **`ci/values-e2e.yaml`**: overrides for KinD — StorageClass `standard`
  (local-path), LiveKit media as `ClusterIP` (no MetalLB), TURN off, Istio off,
  Secret created by the chart (test placeholders).

### What the E2E validates (real assertions)
1. Rollout of every Deployment/StatefulSet.
2. The `seaweedfs-init` Job completed.
3. **Postgres**: the `fluxer_kv` table exists (the API migration ran).
4. **SeaweedFS**: the 5 S3 buckets exist (via `weed shell`).
5. Endpoints return 200: `api/_health`, `media-proxy/_health`, `admin/_health`,
   `gateway/_health`, `livekit` (7880).
6. **Discovery** `/api/.well-known/fluxer` → 200 with the endpoint document
   (`api/gateway/media/static_cdn/admin`).
7. **Web client** `app-proxy` serves the Fluxer SPA (HTTP 200 with the app shell).

The E2E applies `ci/e2e-proxy.yaml` (a tiny nginx) after the chart: the API's
`RequireClientIpMiddleware` rejects `/.well-known/fluxer` unless a proxy header
(`x-forwarded-for`) is present, and the app-proxy fetches the discovery through
it — standing in for the ingress used in production.

Run the E2E locally:
```bash
kind create cluster --config .github/kind-config.yaml
helm upgrade --install fluxer . -n fluxer --create-namespace -f ci/values-e2e.yaml
bash scripts/e2e-test.sh
```

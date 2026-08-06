<img width="100%" src="https://github.com/user-attachments/assets/da17b160-f289-436f-b140-972083a08602" />

<p align="center">
  <a href="https://penpot.app/"><b>Website</b></a>  •
  <a href="https://help.penpot.app/user-guide/"><b>User Guide</b></a>  •
  <a href="https://help.penpot.app/technical-guide/configuration/"><b>Configuration Guide</b></a>  •
  <a href="https://community.penpot.app/"><b>Community</b></a>
</p>

> **About this document** — This README documents *our* self-hosted deployment: what's in `docker-compose.yaml`, how the services fit together, and how to deploy it — production only, no separate dev setup.

## Table of contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
  - [Service Inventory](#service-inventory)
  - [Architecture Diagram](#architecture-diagram)
  - [Component Deep Dive](#component-deep-dive)
  - [Configuration Model](#configuration-model)
  - [Data & State](#data--state)
  - [Request Flow Examples](#request-flow-examples)
- [Setup Instructions](#setup-instructions)
  - [Prerequisites](#prerequisites)
  - [Deploy](#deploy)
  - [Updating to a New Version](#updating-to-a-new-version)
  - [Security Checklist](#security-checklist)
- [Scaling Considerations](#scaling-considerations)
- [References](#references)

---

## Project Overview

[Penpot](https://penpot.app/) is the open-source design and prototyping platform for teams that build digital products at scale — a self-hostable, Figma-style collaborative design tool built entirely on open web standards (SVG, CSS, HTML, JSON).

What makes Penpot relevant to us as a self-hosted deployment:

- **Full ownership of the design infrastructure.** Nothing about a user's designs, files, or teams leaves our servers.
- **Real-time collaboration** — co-editing, live cursors, comments — powered by WebSockets and pub/sub, not a third-party sync service.
- **Design as code.** Design Tokens, an [Inspect mode](https://help.penpot.app/user-guide/) (SVG/CSS/HTML export), and CSS Grid/Flex layout mean design output translates directly to what developers ship.
- **Programmable via [MCP](https://penpot.app/penpot-mcp-server)** — an open API and Model Context Protocol server let AI agents and external tools read/write Penpot designs, which is why this stack runs its own `penpot-mcp` service.
- **Deployment-agnostic** — Penpot can run on their SaaS, Kubernetes, Elestio, or, as here, plain Docker Compose on a single host.

This repository currently holds the deployment manifest (`docker-compose.yaml`) for a single-host, Docker Compose-based install — six application services plus supporting infrastructure (PostgreSQL, Valkey, a mail catcher for dev).

## Architecture

### Service Inventory

| Service | Image | Role |
|---|---|---|
| `penpot-frontend` | `penpotapp/frontend` | Serves the SPA (web client), acts as reverse proxy in front of backend/exporter/MCP |
| `penpot-backend` | `penpotapp/backend` | Core application server: API, auth, business logic, persistence, websockets |
| `penpot-mcp` | `penpotapp/mcp` | Model Context Protocol server — exposes Penpot capabilities to AI agents/assistants |
| `penpot-exporter` | `penpotapp/exporter` | Headless rendering service for exporting shapes/boards to PNG/SVG/PDF |
| `penpot-postgres` | `postgres:15` | Primary relational datastore |
| `penpot-valkey` | `valkey/valkey:8.1` | In-memory store (Redis-compatible fork) for pub/sub & websocket notifications |
| `penpot-mailcatch` | `sj26/mailcatcher` | Dev/staging SMTP sink — captures outgoing emails for inspection (**not for production**) |
| `traefik` *(commented out)* | `traefik:v3.3` | Optional reverse proxy / TLS termination for public-internet exposure |

All services share a single user-defined bridge network, **`penpot`**, which provides internal DNS resolution between containers (e.g. `penpot-postgres`, `penpot-valkey`, `penpot-mailcatch` are reachable by service name).

### Architecture Diagram

```
                                   Internet / LAN
                                         │
                                         ▼
                              ┌─────────────────────┐
                              │   penpot-frontend    │  :9001 → :8080
                              │  (SPA + reverse      │
                              │   proxy)             │
                              └─────────┬─────────────┘
                     ┌───────────────────┼───────────────────┐
                     ▼                   ▼                   ▼
          ┌─────────────────┐ ┌──────────────────┐ ┌──────────────────┐
          │  penpot-backend  │ │ penpot-exporter   │ │   penpot-mcp     │
          │  (API/WS/auth)   │ │ (render/export)   │ │ (AI agent access)│
          └───┬─────────┬────┘ └─────────┬─────────┘ └──────────────────┘
              │         │                │
              ▼         ▼                ▼
   ┌────────────────┐ ┌───────────────┐ ┌───────────────────────┐
   │ penpot-postgres │ │ penpot-valkey │ │ penpot-frontend:8080   │
   │ (relational DB) │ │ (pub/sub, WS  │ │ (exporter fetches      │
   │                 │ │  notifications)│ │  rendered pages via    │
   └────────────────┘ └───────────────┘ │  internal HTTP)        │
                                          └───────────────────────┘
              │
              ▼
   ┌────────────────────┐
   │ penpot-mailcatch    │  (SMTP :1025 internal, UI :1080 exposed)
   └────────────────────┘

   Shared volume: penpot_assets (mounted by frontend + backend)
```

### Component Deep Dive

**`penpot-frontend`** — Serves the compiled ClojureScript/JS SPA and acts as an entry-point reverse proxy, routing API/websocket traffic to the backend, export requests to the exporter, and MCP traffic to the MCP service. Exposes host port **9001** (→ container 8080); this is the URL users hit, matching `PENPOT_PUBLIC_URI`. Mounts the shared `penpot_assets` volume. Depends on `penpot-backend`, `penpot-exporter`, and `penpot-mcp`.

**`penpot-backend`** — The core Clojure application. Handles the REST/WebSocket API and real-time collaboration; authentication (session cookies, OAuth via GitHub/GitLab/Google/LDAP/OIDC — configurable via `PENPOT_FLAGS`); persistence to PostgreSQL; pub/sub through Valkey so multiple instances stay in sync; asset storage (filesystem by default, S3-compatible optional); and transactional email (invitations, verification) via SMTP. Waits for Postgres and Valkey to be **healthy** before starting. `PENPOT_SECRET_KEY` derives all session/invitation subsystem keys — must be changed for any real deployment.

**`penpot-mcp`** — Runs Penpot's Model Context Protocol server so AI assistants/agents can introspect and interact with designs programmatically (list files, read shapes, export elements). Enabled via the `enable-mcp` flag; sits behind the frontend proxy with no directly published port.

**`penpot-exporter`** — A headless-browser rendering service used to export boards/shapes to PNG/SVG/PDF. Talks to `penpot-frontend` over the internal Docker network to render pages exactly as the SPA displays them, then captures the render. Uses Valkey for job coordination and `PENPOT_SECRET_KEY` to validate signed export requests from the backend.

**`penpot-postgres`** — PostgreSQL 15, system of record for all structured data (users, teams, projects, files, comments, versions). `--data-checksums` enabled for corruption detection. Health-checked via `pg_isready`; other services gate startup on it. Data persisted in `penpot_postgres_v15`.

**`penpot-valkey`** — Redis-compatible in-memory store used for WebSocket notification fan-out (so backend replicas scale horizontally) and export job coordination. Capped at 128MB with LFU eviction; no persistence volume by design — its data is transient.

**`penpot-mailcatch`** — A disposable SMTP catch-all for local/dev — intercepts outbound email so nothing is actually delivered. Web UI on host port **1080**; SMTP listens internally on **1025**. **Not for production** — point `PENPOT_SMTP_*` at a real provider instead.

**`traefik`** *(optional, commented out)* — Template for exposing Penpot to the internet with automatic TLS (Let's Encrypt) and Docker-based service discovery. Disabled by default since the stack targets `localhost`.

### Configuration Model

Docker Compose YAML anchors (`x-flags`, `x-uri`, `x-body-size`, `x-secret-key`) centralize shared environment variables and merge them into each service via YAML's `<<` merge key, avoiding duplication across `frontend`, `backend`, and `exporter`.

Key feature flags (`PENPOT_FLAGS`, space-separated):

| Flag | Effect |
|---|---|
| `disable-email-verification` | Skip email confirmation on signup (dev convenience) |
| `enable-smtp` | Turn on email sending |
| `enable-prepl-server` | Expose a Clojure REPL in the backend container |
| `disable-secure-session-cookies` | Allow non-HTTPS session cookies — must be re-enabled before exposing to the internet |
| `enable-mcp` | Turn on the Model Context Protocol integration |
| `enable-registration` | Allow open self-signup |

Other notable env vars: `PENPOT_PUBLIC_URI` (externally visible base URL), `PENPOT_HTTP_SERVER_MAX_BODY_SIZE` (upload cap, default ~350MB), `PENPOT_SECRET_KEY` (master crypto key, shared by backend and exporter), `PENPOT_DATABASE_URI` / `PENPOT_REDIS_URI` (internal service discovery via Docker DNS).

### Data & State

| Volume | Mounted by | Purpose | Durability |
|---|---|---|---|
| `penpot_postgres_v15` | `penpot-postgres` | All relational application data | Persistent |
| `penpot_assets` | `penpot-frontend`, `penpot-backend` | Uploaded design assets (images, fonts) on the filesystem storage backend | Persistent |
| `penpot_traefik` *(unused, optional)* | `traefik` | ACME/TLS certificate storage | Persistent |

Valkey holds no durable volume by design — its role is transient pub/sub and cache, not storage of record.

### Request Flow Examples

- **Opening the app:** `browser → penpot-frontend:9001 → (proxy) → penpot-backend (API/WS) → penpot-postgres / penpot-valkey`
- **Exporting a board:** `browser → frontend → backend (signed export job) → exporter → frontend:8080 (headless render) → exporter returns file → backend/frontend → browser`
- **Registration email:** `backend → SMTP → mail provider (mailcatch in dev, real SMTP in prod)`
- **AI agent via MCP:** `AI client → penpot-frontend (proxy) → penpot-mcp → backend API`

## Setup Instructions

This stack has **one path: production**. There is no separate dev mode to switch out of — `docker-compose.override.yaml` (committed in this repo) already hardens the base file: real SMTP instead of Mailcatcher, secure cookies/email verification on, and a placeholder-free config driven entirely by `.env`. Running the stack always means running it in this configuration.

### Prerequisites

- **Windows Server/PC**: Docker Desktop (WSL2 backend) + Git for Windows
- **Linux**: Docker Engine + Docker Compose v2 (`docker compose version`)
- The port your `PENPOT_PUBLIC_URI` will be served on reachable on the host (`9001` by default, or 80/443 if fronted by a reverse proxy/tunnel)
- ~2GB RAM free for the full stack (Postgres + Valkey + 4 app services)
- A [Resend](https://resend.com/api-keys) account (or swap for another transactional SMTP provider) for real email delivery

### Deploy

**1. Clone the repository**

```powershell
git clone https://github.com/raksitbell/penpot.git
cd penpot
```

**2. Generate secrets**

```powershell
# Windows (PowerShell)
.\scripts\setup.ps1
```
```sh
# macOS/Linux/WSL
./scripts/setup.sh
```

This copies `.env.example` → `.env` and auto-generates a secure `PENPOT_SECRET_KEY` (64 random bytes, URL-safe base64) and a random `POSTGRES_PASSWORD`. It's idempotent and refuses to overwrite an existing `.env`.

**3. Fill in the remaining values**

Open `.env` in VS Code (not Notepad — it can add a BOM that breaks Compose's parsing) and set:

- `PENPOT_PUBLIC_URI` — your real domain, e.g. `https://design.yourcompany.com`
- `RESEND_API_KEY` — from your Resend account
- `SMTP_FROM_EMAIL` — the sender address for registration/invitation emails

**4. Start the stack**

```sh
docker compose up -d
docker compose ps
```

No `-f` flags — Compose auto-merges `docker-compose.yaml` with `docker-compose.override.yaml` by default. Then open the app at whatever `PENPOT_PUBLIC_URI` points to.

**5. (Optional) TLS termination** — if exposing beyond your LAN, put a reverse proxy or tunnel in front rather than serving raw HTTP: the commented-out `traefik` service in `docker-compose.yaml`, or a Cloudflare Tunnel if you're behind residential NAT without a static IP.

**6. (Optional) Auto-deploy on merge** — see [Automated update pipeline](#automated-update-pipeline) below to wire up the self-hosted runner so version-bump PRs deploy automatically once merged.

### Updating to a New Version

```sh
docker compose pull
docker compose up -d
```

Run these **without** an explicit `-f docker-compose.yaml` flag — Compose's default file discovery auto-merges `docker-compose.yaml` with your `docker-compose.override.yaml`. If you explicitly pass `-f`, Compose uses *only* the files you list, which would silently drop your production overrides.

The image tag is controlled by `PENPOT_VERSION` (defaults to `2.16` in this file, e.g. `penpotapp/backend:${PENPOT_VERSION:-2.16}`). Bump it via `.env` (`PENPOT_VERSION=2.17`) rather than editing the base compose file, and check the [Penpot releases](https://github.com/penpot/penpot/releases) before upgrading in production.

#### Automated update pipeline

Two GitHub Actions workflows handle detecting and applying upstream updates:

1. **`.github/workflows/check-penpot-update.yml`** — runs weekly (Monday 06:00 UTC) plus on manual trigger. It polls Penpot's GitHub Releases API (there's no true push/webhook trigger available since we don't own that repo) and:
   - If a newer version exists, opens a PR bumping the `PENPOT_VERSION` default in `docker-compose.yaml`, with the full release notes in the PR body.
   - Separately diffs our `docker-compose.yaml` against [upstream's example file](https://github.com/penpot/penpot/blob/develop/docker/images/docker-compose.yaml) to catch structural changes (new services, new env vars) beyond just version bumps — reported in the Actions run summary, not auto-applied.
2. **`.github/workflows/deploy.yml`** — triggers on push to `main` (i.e. once you merge the version-bump PR) and runs on a **self-hosted runner installed on the Windows server itself**, executing `docker compose pull && docker compose up -d` there directly. GitHub's cloud runners never touch the server — only this self-hosted runner does.

**You still control the gate**: nothing deploys until you review and merge the PR. Once merged, deployment is automatic.

**Setting up the self-hosted runner (one-time, on the Windows PC):**
1. In the GitHub repo → Settings → Actions → Runners → "New self-hosted runner", choose Windows, and follow the generated PowerShell commands to download/configure/install it as a service.
2. Set the runner's working directory to this repo's clone location, and make sure `.env` (with real secrets) already exists there — the runner reuses this directory across every deploy run, and `.env` is gitignored so it survives `git pull`/checkout untouched.
3. Only use a self-hosted runner on a **private** repo — a public repo with a self-hosted runner lets anyone who can open a PR execute code on that machine.

### Security Checklist

- [ ] `PENPOT_SECRET_KEY` changed from the placeholder, generated securely, stored outside version control
- [ ] `disable-secure-session-cookies` and `disable-email-verification` removed from `PENPOT_FLAGS`
- [ ] Real SMTP provider configured (Mailcatcher disabled)
- [ ] Default Postgres credentials changed
- [ ] TLS termination in front of the frontend (Traefik or equivalent)
- [ ] `.env` / override files containing secrets are git-ignored

## Scaling Considerations

- `penpot-backend` and `penpot-frontend` are stateless relative to each other — real-time sync goes through Valkey pub/sub, so backend replicas can scale horizontally behind a load balancer.
- `penpot-postgres` is a single point of failure in this topology; production deployments typically externalize it to a managed/clustered Postgres instance.
- `penpot-exporter` is CPU/memory-intensive (headless browser rendering) and is a good candidate for independent horizontal scaling under export-heavy workloads.

## References

- Official configuration guide: https://help.penpot.app/technical-guide/configuration/
- Official architecture docs: https://help.penpot.app/technical-guide/developer/architecture/
- Penpot releases: https://github.com/penpot/penpot/releases
- Upstream project repository: https://github.com/penpot/penpot

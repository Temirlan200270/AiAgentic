# Deploy to Hetzner VPS via Coolify

This repo is now set up for a Coolify deployment with:

- `n8n` main container
- `n8n-worker` for real queue-mode execution
- `postgres`
- `redis`

`docker-compose.yml` is production-first for Coolify.
`docker-compose.override.yml` keeps local `localhost:5678` and `localhost:5432` working for local development.

## 1. Push the repo to GitHub

Push this project to a GitHub repository first, because the VPS bootstrap script is meant to be downloaded from raw GitHub:

```bash
git add .
git commit -m "Prepare Coolify deployment"
git push origin main
```

## 2. Bootstrap the Hetzner VPS

SSH into the server:

```bash
ssh root@YOUR_VPS_IP
```

Run the setup script from your repository:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/setup-vps.sh | bash
```

What the script does:

- updates Ubuntu packages
- installs and enables UFW
- opens `22`, `80`, `443`, and `8000`
- installs Coolify

Open:

```text
http://YOUR_VPS_IP:8000
```

Create the first Coolify admin immediately.

Note:

- `8000` is intentionally opened for the first login. Coolify's current docs require it when you access the dashboard by IP first.
- After you switch the instance to `coolify.your-domain.com`, you can close `8000` again with `ufw delete allow 8000/tcp`.

## 3. Create DNS records in Cloudflare

Create a Cloudflare API token:

1. Cloudflare -> My Profile -> API Tokens -> Create Token -> Custom Token
2. Permissions: `Zone -> DNS -> Edit`
3. Zone Resources: `Include -> Specific zone -> your domain`

Find your `Zone ID` on the domain overview page in Cloudflare.

From your local machine, run:

```bash
export CF_API_TOKEN=your_token_here
export CF_ZONE_ID=your_zone_id_here
export VPS_IP=YOUR_VPS_IPV4
./cloudflare-dns.sh
```

What it creates:

- `coolify.${DOMAIN}` -> `VPS_IP`
- `n8n.${DOMAIN}` -> `VPS_IP`

Defaults:

- the script auto-loads `DOMAIN` from your local `.env` if present
- records are created with `proxied=false` by default to avoid SSL/bootstrap surprises
- rerunning the script updates existing A records instead of duplicating them

## 4. Prepare the production env values

Use your existing local `.env` as the source of truth, but add the new keys from `.env.example` before pasting values into Coolify.

Minimum additional keys for production:

```env
DOMAIN=example.com
N8N_HOST=n8n.example.com
N8N_PROTOCOL=https
N8N_EDITOR_BASE_URL=https://n8n.example.com
N8N_SECURE_COOKIE=true
N8N_WEBHOOK_URL=https://n8n.example.com/
REDIS_PASSWORD=a-long-random-password
REDIS_URL=redis://:a-long-random-password@redis:6379/0
N8N_RUNNERS_ENABLED=true
N8N_RUNNERS_MODE=internal
EXECUTIONS_MODE=queue
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_WORKER_CONCURRENCY=5
QUEUE_BULL_PREFIX=n8n
```

Keep using the same `N8N_ENCRYPTION_KEY` everywhere. Do not generate a new one for production later unless you also plan to recreate credentials.

## 5. Configure Coolify itself

Inside the Coolify UI:

1. Create the admin account.
2. Go to `Settings -> Instance Domain`.
3. Set the instance domain to:

```text
https://coolify.your-domain.com
```

Wait until the instance domain is reachable over HTTPS.

Optional hardening after that:

```bash
ufw delete allow 8000/tcp
```

## 6. Create the n8n stack in Coolify

Inside Coolify:

1. `New Project`
2. `New Resource`
3. `Service`
4. `Docker Compose Empty`
5. Paste the contents of `docker-compose.yml`

Then configure the service:

1. Add all environment variables from your updated `.env`
2. Save
3. Open the `n8n` service inside the stack
4. In the domain field, set:

```text
https://n8n.your-domain.com:5678
```

Do not assign public domains to `postgres`, `redis`, or `n8n-worker`.

Why the compose file does not hardcode raw Traefik labels:

- current Coolify service deployments already generate proxy config from the domain field
- keeping the domain mapping in Coolify avoids having two competing sources of truth for routing

Why there is an `n8n-worker` now:

- real n8n queue mode needs a worker process
- without a worker, `EXECUTIONS_MODE=queue` would accept work but not execute it correctly

## 7. Deploy

Click `Deploy`.

Expected healthy containers:

- `n8n`
- `n8n-worker`
- `postgres`
- `redis`

## 8. Verify

Check these after deployment:

1. `https://coolify.your-domain.com` opens the Coolify panel.
2. `https://n8n.your-domain.com` opens n8n without certificate warnings.
3. The Coolify logs show `n8n`, `n8n-worker`, `postgres`, and `redis` as healthy/running.
4. Your Telegram bot answers to `/start`.

## Notes

- The stack uses n8n queue mode with a single worker to stay simple and production-safe enough for this assistant.
- `N8N_RUNNERS_MODE=internal` was chosen on purpose to avoid extra sidecar containers. n8n recommends external runners for stricter production isolation, but that would add more moving parts and more manual setup.
- If you later move to webhook-heavy or higher-throughput traffic, the easiest next step is scaling `n8n-worker`.

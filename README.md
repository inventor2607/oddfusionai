# oddfusion.ai

Static single-page marketing site for **ODD FUSION**. One HTML file, one PNG, no
build step and no dependencies.

```
site/index.html                        the page
site/preview.png                       Open Graph image (1200x630)
.github/workflows/deploy.yml           push to main -> rsync to the VPS
infra/nginx/oddfusion.conf             the nginx server blocks (authoritative)
infra/nginx/oddfusion-acme-bootstrap.conf   temporary block used once, to get the cert
```

`site/index.html` is byte-for-byte the reviewed design. It is a spec, not a
draft — do not restructure it, rewrite copy, or tidy the markup.

## The form

The page posts to a hosted form service. Near the bottom of `site/index.html`:

```js
const ENDPOINT = "";
```

Empty is a valid state: the page catches the submit, tells the visitor nothing
was sent, and does not lose the message silently. Set it to the Formspree/Tally
POST URL when there is one.

There is deliberately no form backend on this VPS. Sending mail from a fresh IP
means SPF/DKIM/DMARC and reputation work, and the entire point of the page is
that a message from a stranger actually arrives.

## Deployment

Push to `main` touching `site/**` → GitHub Actions rsyncs `site/` to the web
root. `--delete` is on, so the web root mirrors `site/` exactly.

### Required repository secrets

| Secret | What it is |
|---|---|
| `DEPLOY_SSH_KEY` | Private key of the **dedicated deploy user**. Not a personal key, and never root. |
| `DEPLOY_KNOWN_HOSTS` | The server's SSH host key line, from `ssh-keyscan -t ed25519 <host>`. Pinned so a deploy cannot be sent to an impostor. |
| `DEPLOY_USER` | The deploy user's name. |
| `DEPLOY_HOST` | Server hostname or IP. |
| `DEPLOY_PATH` | Absolute web root, e.g. `/var/www/oddfusion.ai`. |
| `DEPLOY_PORT` | Optional. Defaults to 22. |

**Until these secrets exist the workflow will fail.** That is expected on a fresh
repository, not a bug — the first successful run is the one after the deploy user
is created and the secrets are set.

### The deploy user

The deploy account has write access to the web root and nothing else. It is not
root, is not in `sudo`, and has no shell login worth stealing. If the key in
GitHub secrets leaks, the blast radius is "someone can replace a marketing page",
not "someone owns the box that also runs two other production sites".

## Server

The nginx config in `infra/nginx/` is the authority. It is installed by hand,
not by the deploy workflow — the workflow only ever writes into the web root, so
a bad push cannot reconfigure the server.

Certificates are obtained with `certbot certonly --webroot`, **not**
`certbot --nginx`. The `--nginx` installer rewrites server blocks in place, which
would make the copy on the box quietly diverge from the copy in this repo.

Routing:

| Name | Behaviour |
|---|---|
| `oddfusion.ai` | serves the site over TLS — canonical |
| `www.oddfusion.ai` | 301 → `https://oddfusion.ai` |
| `oddfusionai.com` | 301 → `https://oddfusion.ai` |
| `www.oddfusionai.com` | 301 → `https://oddfusion.ai` |

`oddfusionai.com` is a typo-catcher. It never serves content.

## Local preview

```
python -m http.server -d site 8000    # then open http://localhost:8000
```

Mobile is the primary surface — most traffic arrives from a QR code at events —
so check 390px width before shipping anything.

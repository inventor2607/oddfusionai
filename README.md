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
| `VPS_SSH_KEY` | Private key of the **dedicated deploy user**. Not a personal key, and never root. |
| `VPS_USER` | The deploy user's name (`oddfusion-deploy`). |
| `VPS_HOST` | Server hostname or IP. |

Three secrets, not six. The destination path is `/` and the port is 22, and
neither is sensitive, so both are in the workflow where they can be read. The
server's SSH **host public key** is pinned in the workflow too: it is public by
definition — every client that connects is shown it — and pinning it in version
control, where it can be reviewed, is what stops a deploy being handed to
whatever happens to answer on that address.

**Until these secrets exist the workflow will fail.** That is expected on a fresh
repository, not a bug — the first successful run is the one after the deploy user
is created and the secrets are set.

The destination is `/`, which looks wrong and is not. The deploy key is wrapped
in `rrsync` (see below), which roots that SSH connection at the web root, so `/`
over that connection already *means* `/var/www/oddfusion.ai`.

The rsync flags are `-rlvz --delete` and deliberately **not** `--chmod`: rrsync
refuses `--chmod`, so adding it fails the deploy. Checkout already produces 644
files and 755 directories.

### The deploy user

`oddfusion-deploy` is a system account: not root, not in `sudo`, owning nothing
but the web root. Its `authorized_keys` entry pins the key to

```
command="/usr/bin/rrsync /var/www/oddfusion.ai",restrict
```

so that key can run exactly one program, confined to one directory, with no pty
and no port/agent/X11 forwarding. If it leaks, the blast radius is "someone can
replace a marketing page" — not "someone owns the box that also runs tenkif.com
and tripplansai.com".

### First-time setup

`infra/setup-vps.sh` does the one-time server setup: deploy user, directories,
nginx blocks, certificate. It is the only step that needs sudo, it refuses to
overwrite anything that already exists, and it validates nginx before every
reload so a mistake cannot take the neighbouring sites down. It prints the six
secret values at the end.

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

`infra/nginx/default-tls-reject.conf` is shared-host hygiene rather than part of
this site: it makes nginx reject the TLS handshake for names this box does not
serve, instead of answering them with the first site's certificate.

## Local preview

```
python -m http.server -d site 8000    # then open http://localhost:8000
```

Mobile is the primary surface — most traffic arrives from a QR code at events —
so check 390px width before shipping anything.

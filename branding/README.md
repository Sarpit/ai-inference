# Acceptable-use splash screen

A blocking "I Agree" modal shown to each user on first login, injected into
Open WebUI without forking it or rebuilding the image.

## How it works

Open WebUI's page template (`src/app.html`) loads two customization hooks on
every page:

```html
<script src="/static/loader.js" defer crossorigin="use-credentials"></script>
<link rel="stylesheet" href="/static/custom.css" crossorigin="use-credentials" />
```

Both ship in the image as **empty placeholder files**, served by FastAPI from
`STATIC_DIR` (default `/app/backend/open_webui/static/`). `loader.js` is
bind-mounted read-only over the empty one in `docker-compose.yaml`.

Acceptance is recorded **server-side per user** via
`POST /api/v1/users/user/info/update` (a merge-patch into the user's info blob),
with `localStorage` as a fallback if the API is unreachable. That ties the click
to an LDAP identity and survives cache clears, which a cookie would not.

## Deploy

```sh
podman compose up -d --force-recreate openwebui
```

No rebuild needed — it's a bind mount.

## Verify

```sh
# 1. The hook exists in this image version (should print our file, not 0 bytes)
podman exec openwebui ls -l /app/backend/open_webui/static/loader.js

# 2. The template actually references it
curl -sk https://chat.example.com/ | grep loader.js

# 3. The file is served
curl -sk https://chat.example.com/static/loader.js | head -5
```

Then hard-reload the site in a browser (Cmd/Ctrl+Shift+R) and log in. The modal
should appear once; after clicking **I Agree** it should not return on reload.

To re-test as an already-accepted user, open devtools console and run:

```js
fetch('/api/v1/users/user/info/update', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + localStorage.token },
  body: JSON.stringify({ aup_accepted_v1: null })
}).then(() => localStorage.removeItem('aup_accepted_v1'));
```

## Changing the text

Edit `TITLE`, `BODY`, and `BUTTON` at the top of `loader.js`. `BODY[0]` renders
as a lead paragraph; the remaining entries render as bullet points. Text is
inserted via `textContent`, so HTML is not interpreted — that's deliberate.

**When Legal revises the wording, bump `CONSENT_KEY`** (`aup_accepted_v1` →
`_v2`). Everyone gets re-prompted and the new acceptance is recorded under the
new key, leaving the old timestamps intact for the record.

Restart to pick up changes: `podman compose restart openwebui`, then hard-reload
the browser (the file is cached).

## Auditing who accepted

```sh
# For one user, as an admin:
curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://chat.example.com/api/v1/users/{user_id}/info
```

Returns the info blob including `aup_accepted_v1` and its ISO-8601 timestamp.

## Caveats

- **This is not a security control.** It's a speed bump plus an acceptance
  record. A user can dismiss it from devtools, and the model API is reachable
  directly through LiteLLM at `/litellm/` without ever loading this page. Say
  this out loud to anyone who thinks it constitutes enforcement.
- The user info blob is user-writable, so a determined user can clear their own
  acceptance record. Fine for "cover ourselves," not for compliance evidence.
- `/static/loader.js` is a convention, not a documented API — the maintainer's
  position on admin JS injection is "fork the repo"
  ([discussion #5428](https://github.com/open-webui/open-webui/discussions/5428)).
  Pin the `openwebui` image tag and re-run the verify steps after any upgrade.
- A native consent feature is still an open request
  ([discussion #13019](https://github.com/open-webui/open-webui/discussions/13019)).
  If it lands, drop this in favour of it.

## Fallback if the hook disappears

Inject from nginx instead — in the `chat.` vhost's `location /`:

```nginx
proxy_set_header Accept-Encoding "";   # required: disables upstream gzip
sub_filter_types text/html;
sub_filter_once on;
sub_filter '</head>' '<script src="/aup.js" defer></script></head>';
```

plus `location = /aup.js { alias /etc/nginx/inject/loader.js; }` and a mount of
this directory into the nginx container. Costs you compression on that vhost and
conflicts with `proxy_buffering off`, which is why it's the fallback.

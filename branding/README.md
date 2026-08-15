# Open WebUI injections

Three customisations applied to Open WebUI without forking it or rebuilding the
image:

1. **Acceptable-use splash** — a blocking "I Agree" modal, shown on every login.
2. **Pinned sidebar** — always open, no collapse control.
3. **No chat search** — the sidebar Search button and its shortcut removed.

## How it works

Open WebUI's page template (`src/app.html`) loads two customization hooks on
every page:

```html
<script src="/static/loader.js" defer crossorigin="use-credentials"></script>
<link rel="stylesheet" href="/static/custom.css" crossorigin="use-credentials" />
```

Both ship in the image as **empty placeholder files**, served by FastAPI from
`STATIC_DIR` (default `/app/backend/open_webui/static/`). Both are bind-mounted
read-only over the empty ones in `docker-compose.yaml`.

The split between the two files is deliberate:

- **`custom.css`** hides elements, and carries the logo/accent-colour branding
  rules in a section at the bottom. A stylesheet in `<head>` applies before the
  SPA hydrates, so nothing flashes into view and then disappears.
- **`loader.js`** does everything that needs to run: the modal, the keyboard
  shortcut blocking, and the sidebar watchdog.

**None of this is configurable in Open WebUI.** `backend/open_webui/config.py`
has no `USER_PERMISSIONS_*` entry for sidebar visibility or chat search, so
injection is the only route short of a fork.

## Deploy

```sh
podman compose up -d --force-recreate openwebui
```

No rebuild needed — they're bind mounts.

---

## 1. Acceptable-use splash

Shown **once per login**. The gate is the JWT in `localStorage.token`: Open
WebUI issues a new one per sign-in and keeps it stable across reloads, so
`loader.js` prompts whenever the current token is not the one it last recorded
an acceptance for (`aup_seen_token_v1` in `localStorage`). Reloads do not
re-prompt; a fresh sign-in does.

The poll runs for the lifetime of the page rather than stopping at first sight
of a token, so a logout followed by a login re-prompts even if it happens
without a full page load.

Acceptance is recorded **server-side per user** via
`POST /api/v1/users/user/info/update` (a merge-patch into the user's info blob):

- `aup_accepted_v1` — ISO-8601 timestamp of the most recent acceptance.
- `aup_accepted_log` — rolling array of the last 20 acceptance timestamps.

That ties each click to an LDAP identity and survives cache clears. It is a
record, not the gate — clearing it does not change who gets prompted.

### Changing the text

Edit `TITLE`, `BODY`, and `BUTTON` at the top of `loader.js`. `BODY[0]` renders
as a lead paragraph; the remaining entries render as bullet points. Text is
inserted via `textContent`, so HTML is not interpreted — that's deliberate.

**When Legal revises the wording, bump `CONSENT_KEY`** (`aup_accepted_v1` →
`_v2`). Everyone gets re-prompted on their *next page load* rather than waiting
for their next login, and the new acceptances are recorded under the new key,
leaving the old timestamps intact for the record.

Restart to pick up changes: `podman compose restart openwebui`, then hard-reload
the browser (the file is cached).

### Auditing who accepted

```sh
# For one user, as an admin:
curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://chat.example.com/api/v1/users/{user_id}/info
```

Returns the info blob including `aup_accepted_v1` and `aup_accepted_log`.

---

## 2. Pinned sidebar

`showSidebar` is a plain Svelte store, seeded in `Sidebar.svelte`'s `onMount`
from `localStorage.sidebar === 'true'` and written back on every change.
`loader.js` runs before hydration, so setting `localStorage.sidebar = 'true'`
there decides the initial state.

Three ways a user can collapse it, and what closes each off:

| Path | Fix |
| --- | --- |
| Collapse button in the sidebar header | `custom.css` — the only `<button>` in `#sidebar .sidebar` |
| `Cmd/Ctrl+Shift+S` (`Shortcut.TOGGLE_SIDEBAR`) | capture-phase `keydown` in `loader.js` |
| Anything else (rebound shortcut, devtools, stale selector) | watchdog in `loader.js` |

The watchdog polls every 500ms: when expanded, `#sidebar` carries
`data-state="true"`; when collapsed it is replaced by a 42px rail that also uses
`id="sidebar"` and whose first child div toggles on click. If `data-state` is
missing, the watchdog clicks the rail to re-open.

Shortcut chords are **user-rebindable** in Settings, which is why blocking the
default chord alone is not enough and the watchdog exists.

Not covered:

- **Mobile.** Open WebUI force-closes the sidebar under its `$mobile` breakpoint
  regardless of stored state, and a 245px sidebar over a phone screen would be
  worse than the collapse button. Desktop only, by choice.
- **Drag-resize.** The sidebar can still be narrowed via its resize handle
  (`localStorage.sidebarWidth`). Clamp it in `custom.css` if that matters.

---

## 3. No chat search

Three entry points, all in `Sidebar.svelte`:

- `#sidebar-search-button` — the visible one in the expanded sidebar.
- An `aria-label="Search"` icon button in the 42px collapsed rail — unreachable
  while the pin holds, but a separate element, so hidden separately.
- **`Cmd/Ctrl+K`** — the `SearchModal` is mounted unconditionally and the button
  only flips a store, so hiding the button alone leaves search fully working
  from the keyboard. Blocked in the same capture-phase handler as the sidebar
  toggle.

Blocking `Cmd/Ctrl+K` also swallows the browser's own binding for it on that
page. Accepted trade-off.

---

## Verify

```sh
# 1. Both hooks exist in this image version (should print our files, not 0 bytes)
podman exec openwebui ls -l /app/backend/open_webui/static/loader.js \
                            /app/backend/open_webui/static/custom.css

# 2. The template actually references them
curl -sk https://chat.example.com/ | grep -E "loader.js|custom.css"

# 3. The files are served
curl -sk https://chat.example.com/static/loader.js  | head -5
curl -sk https://chat.example.com/static/custom.css | head -5

# 4. The DOM ids the CSS targets still exist in the built frontend
podman exec openwebui grep -rlo "sidebar-search-button" /app/build | head -3
```

If step 4 finds nothing, the running version predates those ids and the
selectors in `custom.css` need re-deriving from devtools.

Then hard-reload the site in a browser (Cmd/Ctrl+Shift+R) and log in:

- The modal should appear, and not return on reload.
- Sign out and back in — it should appear again.
- The sidebar should be open with no collapse button; `Cmd/Ctrl+Shift+S` should
  do nothing.
- There should be no Search button, and `Cmd/Ctrl+K` should do nothing.

To re-test the modal without signing out, open devtools console and run:

```js
localStorage.removeItem('aup_seen_token_v1');
```

## Caveats

- **This is not a security control.** It's a speed bump plus an acceptance
  record. A user can dismiss the modal from devtools, un-hide the sidebar
  controls from devtools, and the model API is reachable directly through
  LiteLLM at `/litellm/` without ever loading this page. Say this out loud to
  anyone who thinks it constitutes enforcement.
- **Hiding search is cosmetic.** `POST /api/v1/chats/search` stays reachable
  with the user's own token.
- The user info blob is user-writable, so a determined user can clear their own
  acceptance log. Fine for "cover ourselves," not for compliance evidence.
- If the deployed version rotates the JWT mid-session (token refresh), users
  will see an extra prompt when it rotates. Check whether `localStorage.token`
  changes on a long-lived session before rolling out widely.
- `/static/loader.js` and `/static/custom.css` are a convention, not a
  documented API — the maintainer's position on admin JS injection is "fork the
  repo" ([discussion #5428](https://github.com/open-webui/open-webui/discussions/5428)).
  **Pin the `openwebui` image tag** and re-run the verify steps after any
  upgrade; all three customisations match unversioned DOM ids.
- A native consent feature is still an open request
  ([discussion #13019](https://github.com/open-webui/open-webui/discussions/13019)).
  If it lands, drop the modal in favour of it.

## Fallback if the hooks disappear

Inject from nginx instead — in the `chat.` vhost's `location /`:

```nginx
proxy_set_header Accept-Encoding "";   # required: disables upstream gzip
sub_filter_types text/html;
sub_filter_once on;
sub_filter '</head>' '<script src="/aup.js" defer></script><link rel="stylesheet" href="/aup.css"></head>';
```

plus `location = /aup.js { alias /etc/nginx/inject/loader.js; }` (and the same
for `/aup.css`) and a mount of this directory into the nginx container. Costs
you compression on that vhost and conflicts with `proxy_buffering off`, which is
why it's the fallback.

# Open WebUI injections

Three customisations applied to Open WebUI without forking it or rebuilding the
image:

1. **Acceptable-use splash** — a blocking "I Agree" modal, shown on every login.
2. **Pinned sidebar** — locked to its 42px icon rail, cannot be expanded.
3. **No chat search** — the sidebar Search button and its shortcut removed.
4. **Trimmed chrome** — the "Chats" section heading hidden.

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

## 2. Sidebar pinned to the icon rail

The sidebar is locked to its **42px collapsed rail** — always visible, icon
only, and it cannot be expanded. The chat area keeps its full width, because
Open WebUI only applies `max-w-[calc(100% - var(--sidebar-width))]` to the
content wrapper while the sidebar is expanded.

> **Consequence, stated plainly:** with the rail pinned there is no route to the
> chat history list on desktop. New Chat, the pinned nav items (Notes,
> Workspace, …) and the user menu still work; browsing or resuming an old chat
> does not. If that is not what you want, see *Reverting to expanded* below.

`showSidebar` is a plain Svelte store, seeded in `Sidebar.svelte`'s `onMount`
from `localStorage.sidebar === 'true'` and written back on every change.
`loader.js` runs before hydration, so setting `localStorage.sidebar = 'false'`
there decides the initial state.

Three ways a user can expand it, and what closes each off:

| Path | Fix |
| --- | --- |
| Clicking the rail | `custom.css` — the rail wraps its icon column in one `#sidebar > button` that expands on click; it gets `pointer-events: none` |
| `Cmd/Ctrl+Shift+S` (`Shortcut.TOGGLE_SIDEBAR`) | capture-phase `keydown` in `loader.js` |
| Anything else (rebound shortcut, devtools, stale selector) | watchdog in `loader.js` |

The rail is made inert rather than hidden so its icons still render. New Chat
and the pinned nav items are `<a>` elements inside that wrapper which already
`stopImmediatePropagation()`, so re-enabling `pointer-events` on just those
keeps them clickable without re-arming the expand. The user menu sits outside
the wrapper and is untouched.

The watchdog polls every 500ms: only the *expanded* container carries
`data-state="true"` (the rail reuses `id="sidebar"` without it), so if that
attribute shows up, the watchdog clicks the header collapse control to put the
rail back. That control is `display: none` from `custom.css`, which does not
stop a programmatic `.click()`.

Shortcut chords are **user-rebindable** in Settings, which is why blocking the
default chord alone is not enough and the watchdog exists.

Not covered:

- **Mobile.** Below 768px Open WebUI does not render the rail at all — it uses a
  hamburger and a full overlay. Collapsing there would leave no route to
  anything, so the watchdog is desktop-gated and mobile behaves normally.

### Reverting to expanded

Flip `localStorage.sidebar` to `'true'` in `railSidebar()`, invert the
watchdog's `data-state` test, and in `custom.css` drop the `#sidebar > button`
`pointer-events` block (keeping the `#sidebar .sidebar button` hide, which is
what removes the collapse control from the expanded header).

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
- The sidebar should be the 42px icon rail. Clicking it should not expand it,
  and `Cmd/Ctrl+Shift+S` should do nothing. New Chat and the user menu should
  still work.
- There should be no Search button, and `Cmd/Ctrl+K` should do nothing.
- No "Chats" heading (only visible in the mobile overlay, where the chat list
  still renders).

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

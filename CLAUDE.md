# CLAUDE.md

## No real environment details in this repo

This repo is a public mirror of a private work deployment. **Nothing that
identifies the real environment, organisation, or its users may be committed.**

Never write, and actively scrub if found:

- **Hostnames / domains** — use `example.com` subdomains (`chat.example.com`,
  `testai.example.com`). Never a real internal or organisation domain.
- **Organisation names** — no employer, client, agency, or department names in
  code, comments, config, docs, or user-facing strings. Use "internal" or
  "sample".
- **People** — no real names, usernames, email addresses, or contact details.
  Use `sample@example.com`.
- **Credentials** — no real keys, tokens, passwords, or certificates. Use
  obvious placeholders (`sample-key-a`, `change-me-...`).
- **File / cert names** — use `sample.pem`, `sample.key`, not names derived from
  the real deployment.
- **Container images** — do not reference the work registry or its image names;
  use upstream public images only.
- **Team / user / project identifiers** — `sample_team_a`, `sample_user_b`, not
  real team or project names.

The rule applies **everywhere**, not just code: YAML, nginx configs, Markdown,
comments, JS string literals, example `curl` commands, and commit messages.

When adding an example that needs a concrete value, reach for a `sample`
placeholder or an RFC-reserved domain (`example.com`) rather than copying
whatever the real deployment uses.

Before committing, a quick sweep is worth it:

```sh
git diff --cached | grep -inE "<real-domain>|<org-name>|<registry-host>"
```

If a real value is genuinely needed to run locally, keep it out of tracked files
— put it in `.env`, `CLAUDE.local.md`, or an untracked override, all of which are
gitignored.

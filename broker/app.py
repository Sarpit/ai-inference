"""LDAP -> LiteLLM key broker.

Runs as its own long-lived service (see ../docker-compose.yaml), sitting
behind nginx. A client (see ../scripts/crush) POSTs a username/password to
/login; this service validates them against LDAP, creates the corresponding
LiteLLM user on first login, and returns a LiteLLM virtual API key.

LiteLLM only ever returns a key's plaintext value at the moment /key/generate
creates it -- a later /user/info call only returns masked key metadata. So
the sqlite DB here is not just a cache: it is the only place a previously
issued key's plaintext can come from. Once a user_id has a row, that same key
is returned on every subsequent login rather than minting a new one.
"""

import calendar
import logging
import os
import sqlite3
import time
from contextlib import closing

import requests
from fastapi import FastAPI, HTTPException
from ldap3 import ALL, Connection, Server, Tls
from ldap3.utils.conv import escape_filter_chars
from pydantic import BaseModel

logger = logging.getLogger("broker")

LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://litellm:9001")
LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "change-me-to-a-secure-master-key")

LDAP_SERVER_HOST = os.environ.get("LDAP_SERVER_HOST", "ldapserver.example.com")
LDAP_SERVER_PORT = int(os.environ.get("LDAP_SERVER_PORT", "389"))
LDAP_SEARCH_BASE = os.environ.get("LDAP_SEARCH_BASE", "dc=auth,dc=example,dc=com")
LDAP_SEARCH_FILTER = os.environ.get("LDAP_SEARCH_FILTER", "(objectClass=person)")
LDAP_ATTR_USERNAME = os.environ.get("LDAP_ATTRIBUTE_FOR_USERNAME", "uid")
LDAP_ATTR_MAIL = os.environ.get("LDAP_ATTRIBUTE_FOR_MAIL", "mail")
LDAP_USE_TLS = os.environ.get("LDAP_USE_TLS", "false").lower() == "true"
# Path to a CA bundle to validate the LDAP server cert against, when
# LDAP_USE_TLS is set. ldap3 does NOT validate the cert by default, so
# LDAP_USE_TLS alone is not enough -- leaving this unset still connects (with
# a warning) but accepts any cert, i.e. no real protection against MITM.
LDAP_CA_CERT_FILE = os.environ.get("LDAP_CA_CERT_FILE", "")

# Service account used only to *look up* a user's DN before the real bind
# test. Leave both unset for an anonymous search bind.
LDAP_BIND_DN = os.environ.get("LDAP_BIND_DN", "")
LDAP_BIND_PASSWORD = os.environ.get("LDAP_BIND_PASSWORD", "")

KEY_DURATION = os.environ.get("KEY_DURATION", "30d")
MAX_BUDGET = float(os.environ.get("MAX_BUDGET", "10"))
TPM_LIMIT = int(os.environ.get("TPM_LIMIT", "100000"))
RPM_LIMIT = int(os.environ.get("RPM_LIMIT", "60"))
TEAM_ID = os.environ.get("TEAM_ID", "")

DB_PATH = os.environ.get("DB_PATH", "/data/broker.sqlite3")

app = FastAPI()


class LoginRequest(BaseModel):
    username: str
    password: str


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS keys ("
        "user_id TEXT PRIMARY KEY, api_key TEXT NOT NULL, issued_at TEXT NOT NULL)"
    )
    return conn


def parse_duration_seconds(duration: str) -> int:
    """Parses LiteLLM-style durations ("30d", "12h", "45m", "90s")."""
    multipliers = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    unit = duration[-1]
    if unit not in multipliers:
        raise ValueError(f"unsupported duration unit in '{duration}'")
    return int(duration[:-1]) * multipliers[unit]


def build_ldap_tls() -> Tls | None:
    if not LDAP_USE_TLS:
        return None
    if not LDAP_CA_CERT_FILE:
        logger.warning(
            "LDAP_USE_TLS is set but LDAP_CA_CERT_FILE is not; connecting without "
            "certificate validation (vulnerable to MITM)"
        )
        return Tls(validate=0)  # ssl.CERT_NONE
    return Tls(validate=2, ca_certs_file=LDAP_CA_CERT_FILE)  # ssl.CERT_REQUIRED


def ldap_authenticate(username: str, password: str) -> str:
    """Validates credentials against LDAP. Returns the user's email (best effort)."""
    server = Server(
        LDAP_SERVER_HOST,
        port=LDAP_SERVER_PORT,
        use_ssl=LDAP_USE_TLS,
        tls=build_ldap_tls(),
        get_info=ALL,
    )
    safe_username = escape_filter_chars(username)

    try:
        lookup_conn = Connection(
            server,
            user=LDAP_BIND_DN or None,
            password=LDAP_BIND_PASSWORD or None,
            auto_bind=True,
        )
    except Exception:
        raise HTTPException(status_code=502, detail="could not reach LDAP server")

    # ldap3.Connection has .unbind(), not .close() -- contextlib.closing()
    # calls .close() on exit, which doesn't exist on it and raises
    # AttributeError. Use try/finally with .unbind() instead.
    try:
        lookup_conn.search(
            search_base=LDAP_SEARCH_BASE,
            search_filter=f"(&{LDAP_SEARCH_FILTER}({LDAP_ATTR_USERNAME}={safe_username}))",
            attributes=[LDAP_ATTR_MAIL],
        )
        if not lookup_conn.entries:
            raise HTTPException(status_code=401, detail="invalid credentials")

        entry = lookup_conn.entries[0]
        user_dn = entry.entry_dn
        mail_values = entry[LDAP_ATTR_MAIL].values if LDAP_ATTR_MAIL in entry else []
        email = mail_values[0] if mail_values else f"{username}@example.com"
    finally:
        lookup_conn.unbind()

    # Real credential check: bind AS the user with the password they gave us.
    user_conn = None
    try:
        user_conn = Connection(server, user=user_dn, password=password, auto_bind=True)
    except Exception:
        raise HTTPException(status_code=401, detail="invalid credentials")
    finally:
        if user_conn is not None:
            user_conn.unbind()

    return email


def litellm_headers() -> dict:
    return {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}


def litellm_user_exists(user_id: str) -> bool:
    resp = requests.get(
        f"{LITELLM_BASE_URL}/user/info",
        params={"user_id": user_id},
        headers=litellm_headers(),
        timeout=10,
    )
    return resp.status_code == 200


def litellm_create_user(user_id: str, email: str) -> None:
    body = {"user_id": user_id, "user_email": email, "auto_create_key": False}
    if TEAM_ID:
        body["team_id"] = TEAM_ID
    resp = requests.post(
        f"{LITELLM_BASE_URL}/user/new", json=body, headers=litellm_headers(), timeout=10
    )
    if resp.status_code != 200:
        logger.error("/user/new failed for %s: HTTP %s: %s", user_id, resp.status_code, resp.text)
        raise HTTPException(status_code=502, detail="upstream error creating user; contact an administrator")


def litellm_generate_key(user_id: str) -> str:
    body = {
        "user_id": user_id,
        "key_alias": f"ldap-{user_id}",
        "duration": KEY_DURATION,
        "max_budget": MAX_BUDGET,
        "tpm_limit": TPM_LIMIT,
        "rpm_limit": RPM_LIMIT,
    }
    if TEAM_ID:
        body["team_id"] = TEAM_ID
    resp = requests.post(
        f"{LITELLM_BASE_URL}/key/generate", json=body, headers=litellm_headers(), timeout=10
    )
    if resp.status_code != 200:
        logger.error("/key/generate failed for %s: HTTP %s: %s", user_id, resp.status_code, resp.text)
        raise HTTPException(status_code=502, detail="upstream error generating key; contact an administrator")
    key = resp.json().get("key")
    if not key:
        logger.error("/key/generate succeeded for %s but returned no key: %s", user_id, resp.text)
        raise HTTPException(status_code=502, detail="upstream error generating key; contact an administrator")
    return key


@app.post("/login")
def login(req: LoginRequest):
    if not req.username or not req.password:
        raise HTTPException(status_code=400, detail="username and password required")

    username = req.username.strip()
    ttl_seconds = parse_duration_seconds(KEY_DURATION)

    with closing(db()) as conn:
        row = conn.execute(
            "SELECT api_key, issued_at FROM keys WHERE user_id = ?", (username,)
        ).fetchone()

        if row:
            api_key, issued_at = row
            issued_epoch = calendar.timegm(time.strptime(issued_at, "%Y-%m-%dT%H:%M:%SZ"))
            if time.time() < issued_epoch + ttl_seconds:
                # Still verify the password on every login -- a cached key
                # does not mean the caller currently knows valid credentials.
                ldap_authenticate(username, req.password)
                return {"api_key": api_key}
            # Cached key has outlived LiteLLM's own key duration; LiteLLM has
            # since expired it too, so drop it and mint a fresh one below.
            conn.execute("DELETE FROM keys WHERE user_id = ?", (username,))
            conn.commit()

        email = ldap_authenticate(username, req.password)

        if not litellm_user_exists(username):
            litellm_create_user(username, email)

        api_key = litellm_generate_key(username)
        try:
            conn.execute(
                "INSERT INTO keys (user_id, api_key, issued_at) VALUES (?, ?, ?)",
                (username, api_key, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
            )
            conn.commit()
        except sqlite3.IntegrityError:
            # Lost a race with a concurrent first login for the same user;
            # the other request's row wins so both callers agree on one key.
            existing = conn.execute(
                "SELECT api_key FROM keys WHERE user_id = ?", (username,)
            ).fetchone()
            if existing is None:
                raise
            api_key = existing[0]
        return {"api_key": api_key}


@app.get("/health")
def health():
    return {"status": "ok"}

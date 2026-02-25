from mitmproxy import http
import logging
import re
import csv
import os

# Setup logging
logging.basicConfig(
    filename='/mnt/kb/runtime/proxy/traffic.log',
    level=logging.INFO,
    format='%(asctime)s - %(message)s'
)

# Whitelist of allowed domains
DOMAINS_FILE = '/mnt/kb/runtime/proxy/allowed_domains.csv'
ALLOWED_DOMAINS = []

def load_domains():
    global ALLOWED_DOMAINS
    if os.path.exists(DOMAINS_FILE):
        with open(DOMAINS_FILE, mode='r') as f:
            reader = csv.DictReader(f)
            ALLOWED_DOMAINS = [row['domain'] for row in reader if row.get('domain')]
        logging.info(f"Loaded {len(ALLOWED_DOMAINS)} domains from {DOMAINS_FILE}")
    else:
        logging.warning(f"Domains file not found: {DOMAINS_FILE}. Using empty whitelist.")
        ALLOWED_DOMAINS = []

load_domains()

# Gmail API write operations to BLOCK (read-only access allowed)
GMAIL_BLOCKED_PATTERNS = [
    re.compile(r'/gmail/v1/users/[^/]+/messages/send'),
    re.compile(r'/gmail/v1/users/[^/]+/messages/[^/]+$'),
    re.compile(r'/gmail/v1/users/[^/]+/messages/[^/]+/trash'),
    re.compile(r'/gmail/v1/users/[^/]+/messages/batchDelete'),
    re.compile(r'/gmail/v1/users/[^/]+/threads/[^/]+$'),
    re.compile(r'/gmail/v1/users/[^/]+/threads/[^/]+/trash'),
    re.compile(r'/gmail/v1/users/[^/]+/drafts/[^/]+$'),
    re.compile(r'/gmail/v1/users/[^/]+/drafts/send'),
]

GMAIL_WRITE_METHODS = {"POST", "DELETE", "PUT", "PATCH"}

def _is_gmail_write_blocked(flow: http.HTTPFlow) -> bool:
    path = flow.request.path
    method = flow.request.method
    if method not in GMAIL_WRITE_METHODS:
        return False
    for pattern in GMAIL_BLOCKED_PATTERNS:
        if pattern.search(path):
            if pattern.pattern.endswith('$') and method != "DELETE":
                continue
            return True
    return False

def request(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host
    allowed = False
    for domain in ALLOWED_DOMAINS:
        if host == domain or host.endswith("." + domain):
            allowed = True
            break
    if not allowed:
        logging.warning(f"BLOCKED: {flow.request.method} {flow.request.url}")
        flow.response = http.Response.make(
            403, b"Access Denied by OpenClaw Proxy",
            {"Content-Type": "text/plain"}
        )
        return
    if _is_gmail_write_blocked(flow):
        logging.warning(f"BLOCKED GMAIL WRITE: {flow.request.method} {flow.request.url}")
        flow.response = http.Response.make(
            403, b"Gmail write operation blocked by OpenClaw Proxy (read-only mode)",
            {"Content-Type": "text/plain"}
        )
        return
    logging.info(f"ALLOWED: {flow.request.method} {flow.request.url}")

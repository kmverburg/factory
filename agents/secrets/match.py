"""Finds secrets in text read from stdin (docs/secret-scan.md). Prints one JSON line per finding: {"type", "how"}.

"how" is "format" (looks like that kind of secret) or "value:NAME" (equals the current value of the secret NAME).
The current values come from the environment variables named in SCAN_SECRET_NAMES. They are only compared as SHA-256
hashes of whole words; no output, error or log ever contains a secret or a part of one.
"""
import hashlib
import json
import os
import re
import sys

FORMATS = [
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})")),
    ("Linear API key", re.compile(r"\blin_(?:api|oauth)_[A-Za-z0-9]{30,}")),
    ("Claude token", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{30,}")),
    ("Cloudflare token", re.compile(r"\bcf(?:ut|at|k)_[A-Za-z0-9]{30,}")),
    ("Private key", re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----")),
]
WORD = re.compile(r"[^\s\"'`<>(){}\[\],;:=@|\\]{16,}")
SECRET_TYPES = {  # secret name -> type shown in the ticket
    "CLAUDE_CODE_OAUTH_TOKEN": "Claude token", "LINEAR_API_KEY": "Linear API key", "LINEAR_WEBHOOK_SECRET": "Linear webhook secret",
    "CLOUDFLARE_API_TOKEN": "Cloudflare token", "CLOUDFLARE_BUILDS_TOKEN": "Cloudflare token",
    "CLOUDFLARE_OBSERVABILITY_TOKEN": "Cloudflare token", "HEALTH_CHECK_SECRET": "Health check secret",
    "FACTORY_APP_PRIVATE_KEY": "Private key", "GITHUB_TOKEN": "GitHub token",
}


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def current_hashes():
    """hash -> secret name. Multi-line values (private keys) also get one hash per long line."""
    names = os.environ.get("SCAN_SECRET_NAMES", " ".join(SECRET_TYPES)).split()
    out = {}
    for name in names:
        value = os.environ.get(name, "").strip()
        if len(value) < 16 and "\n" not in value:
            continue  # too short to be a secret worth matching (and would give false hits)
        out[sha(value)] = name
        if "\n" in value:
            for line in value.splitlines():
                line = line.strip()
                if len(line) >= 20 and not line.startswith("-----"):
                    out[sha(line)] = name
    return out


def placeholder(text):
    """Obvious placeholders (xxxxxxxx, SECRETSECRET, abcabc: fewer than 10 different characters) are not secrets."""
    body = re.sub(r"^[a-z_]+?_|^sk-ant-[a-z0-9]*-?", "", text)
    return len(set(body)) < 10


def main():
    hashes = current_hashes()
    found = set()
    text = sys.stdin.buffer.read().decode("utf-8", "replace")
    for kind, rx in FORMATS:
        for m in rx.finditer(text):
            if kind == "Private key" or not placeholder(m.group(0)):
                found.add((kind, "format"))
    for word in set(WORD.findall(text)):
        name = hashes.get(sha(word)) or hashes.get(sha(word.rstrip(".")))
        if name:
            found.add((SECRET_TYPES.get(name, "Secret"), "value:" + name))
    for kind, how in sorted(found):
        print(json.dumps({"type": kind, "how": how}))


if __name__ == "__main__":
    main()

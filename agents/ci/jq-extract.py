#!/usr/bin/env python3
"""Prints every jq filter written inline in the given shell scripts, as NUL-separated "file:line\n<filter>" records.
Filters that are built with shell expansion ($(...), ${...}, "$var") can't be checked and are skipped."""
import re, sys

WITH_ARG = {"--arg": 2, "--argjson": 2, "--slurpfile": 2, "--rawfile": 2, "-f": 1, "--from-file": 1,
            "--indent": 1, "--tab": 0, "-L": 1}

def read_word(s, i):
    """Reads one shell word starting at i. Returns (kind, text, end); kind is 'lit' for a fully literal word."""
    n, out, literal = len(s), [], True
    while i < n:
        c = s[i]
        if c in " \t\n;|&<>)":
            break
        if c == "\\" and i + 1 < n:
            if s[i + 1] == "\n":
                i += 2
                continue
            out.append(s[i + 1]); i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                return "lit", "".join(out), n
            out.append(s[i + 1:j]); i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == "\\":
                    j += 1
                elif s[j] == "$":
                    literal = False
                j += 1
            seg = s[i + 1:j]
            out.append(re.sub(r'\\(["\\$`])', r"\1", seg)); i = j + 1
        elif c == "$" and i + 1 < n and s[i + 1] in "({":
            depth, j = 0, i + 1
            while j < n:
                if s[j] in "({": depth += 1
                elif s[j] in ")}":
                    depth -= 1
                    if depth == 0: break
                j += 1
            literal = False; i = j + 1
        elif c == "$":
            literal = False; out.append(c); i += 1
        else:
            out.append(c); i += 1
    return ("lit" if literal else "dyn"), "".join(out), i

for path in sys.argv[1:]:
    src = open(path).read()
    for m in re.finditer(r"(?<![\w./$-])jq(?=[ \t\\])", src):
        line_start = src.rfind("\n", 0, m.start()) + 1
        prefix = src[line_start:m.start()]
        # Only where a command can start; not in a comment or an echoed sentence.
        if not re.search(r"(^|[|&;({!`]|\bthen|\bdo|\belse|\$\()\s*$", prefix):
            continue
        i, n = m.end(), len(src)
        while i < n:
            while i < n and src[i] in " \t" or src[i:i + 2] == "\\\n":
                i += 2 if src[i:i + 2] == "\\\n" else 1
            if i >= n or src[i] in "\n;|&<>)":
                break
            kind, word, i = read_word(src, i)
            if word.startswith("-") and kind == "lit" and len(word) > 1:
                skip = WITH_ARG.get(word, 0)
                if word == "-f" or word == "--from-file":
                    break
                for _ in range(skip):
                    while i < n and src[i] in " \t\n\\": i += 1
                    _, _, i = read_word(src, i)
                continue
            if kind == "lit" and word:
                lineno = src.count("\n", 0, m.start()) + 1
                sys.stdout.write(f"{path}:{lineno}\n{word}\0")
            break

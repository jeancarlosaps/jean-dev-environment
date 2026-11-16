#!/usr/bin/env python3
"""Analisa um comando de shell para o merge-guard.sh.

Entrada: GUARD_CMD (comando) e GUARD_CWD (diretório do evento) no ambiente.
Saída: um objeto JSON em stdout com o que o comando faz de relevante:

  merges    merges de PR identificados (gh pr merge, gh api .../pulls/N/merge)
  pushes    pushes git com os destinos resolvidos ou o motivo de não resolver
  indirect  formas de merge que não podem ser avaliadas (alias, script)
  hits      ocorrências com cara de merge no texto executável
  no_verify uso de --no-verify em commit ou push
  error     comando que não pôde ser tokenizado

Não executa o comando. Só lê arquivos de script citados (para procurar
merge) e a configuração local do git e do gh (destino de push, aliases).
Tokeniza com shlex respeitando aspas: o valor de uma opção nunca é lido
como outra opção.
"""
import json
import os
import re
import shlex
import subprocess

MERGE_LIKE = re.compile(
    r"(?<![A-Za-z0-9])pr[^A-Za-z0-9]{1,8}merge(?![A-Za-z0-9-])"
    r"|pulls/\S*/merge(?![A-Za-z0-9_])"
    r"|mergePullRequest|enablePullRequestAutoMerge"
)
SHA40 = re.compile(r"^[0-9a-f]{40}$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SEPARATORS = set(";&|\n()")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
WRAPPERS = {"command", "exec", "nohup", "time", "nice", "builtin", "sudo",
            "xargs", "caffeinate", "timeout", "doas"}
INTERPRETERS = {"python", "python3", "node", "ruby", "perl", "osascript",
                "php", "deno", "bun"}
# Valores de texto livre: não contam como código, salvo com substituição.
MESSAGE_FLAGS = {"-m", "--message", "-b", "--body", "-t", "--title", "--subject"}
GH_CORE = {"pr", "api", "repo", "issue", "run", "workflow", "release", "auth",
           "alias", "search", "browse", "status", "label", "secret", "variable",
           "cache", "codespace", "gist", "org", "project", "ruleset",
           "attestation", "config", "extension", "gpg-key", "ssh-key",
           "completion", "help", "version"}
GH_VALUE_FLAGS = {"-R", "--repo", "-t", "--subject", "--title", "-b", "--body",
                  "-F", "--body-file", "--field", "-f", "--raw-field", "-A",
                  "--author-email", "--match-head-commit", "-X", "--method",
                  "-H", "--header", "--input", "-q", "--jq", "--template",
                  "-p", "--preview", "--hostname", "--cache"}
MERGE_BOOL_FLAGS = {"--auto", "-d", "--delete-branch", "--disable-auto", "-m",
                    "--merge", "-r", "--rebase", "-s", "--squash"}
MERGE_VALUE_FLAGS = {"-t", "--subject", "-b", "--body", "-F", "--body-file",
                     "-A", "--author-email", "--match-head-commit", "-R", "--repo"}
PUSH_VALUE_FLAGS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
PUSH_BULK_FLAGS = {"--all", "--mirror", "--branches", "--prune"}

result = {"merges": [], "pushes": [], "indirect": [], "hits": 0,
          "no_verify": False, "error": ""}


def tokenize(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def split_commands(tokens):
    commands, current, skip_next = [], [], False
    for tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if tok and set(tok) <= SEPARATORS:
            if current:
                commands.append(current)
            current = []
        elif tok and set(tok) <= set("<>"):
            skip_next = True  # alvo de redirecionamento
        else:
            current.append(tok)
    if current:
        commands.append(current)
    return commands


def is_message_value(prev, tok):
    if "$(" in tok or "`" in tok:
        return False
    return prev in MESSAGE_FLAGS


def scan_text(words):
    kept, prev = [], ""
    for tok in words:
        if is_message_value(prev, tok):
            prev = ""
            continue
        if "=" in tok and tok.split("=", 1)[0] in MESSAGE_FLAGS \
                and "$(" not in tok and "`" not in tok:
            prev = tok
            continue
        kept.append(tok)
        prev = tok
    result["hits"] += len(MERGE_LIKE.findall(" ".join(kept)))


def resolve(path, cwd):
    return path if os.path.isabs(path) else os.path.join(cwd, path)


def scan_file(path, cwd, label):
    full = resolve(path, cwd)
    try:
        if not os.path.isfile(full) or os.path.getsize(full) > 1_000_000:
            return
        with open(full, "rb") as handle:
            data = handle.read()
    except OSError:
        return
    if b"\0" in data[:8192]:
        return  # binário (ex.: o próprio executável do gh)
    if MERGE_LIKE.search(data.decode("utf-8", "replace")):
        result["indirect"].append(f"{label} {path}")


def git(cwd, *args):
    try:
        out = subprocess.run(["git", "-C", cwd, *args], capture_output=True,
                             text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def strip_heads(ref):
    return ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref


def analyze(text, cwd, depth=0):
    if depth > 5:
        result["error"] = "aninhamento de shells além do limite"
        return
    try:
        tokens = tokenize(text)
    except ValueError as exc:
        result["error"] = f"comando não tokenizável: {exc}"
        return
    for words in split_commands(tokens):
        analyze_simple(words, cwd, depth)


def analyze_simple(words, cwd, depth):
    env = {}
    words = list(words)
    while words:
        head = words[0]
        base = os.path.basename(head)
        if ASSIGNMENT.match(head):
            key, value = head.split("=", 1)
            env[key] = value
            words.pop(0)
        elif base == "env":
            words.pop(0)
            while words and (words[0].startswith("-") or ASSIGNMENT.match(words[0])):
                tok = words.pop(0)
                if tok in ("-u", "--unset", "-C", "--chdir", "-S") and words:
                    words.pop(0)
                elif ASSIGNMENT.match(tok):
                    key, value = tok.split("=", 1)
                    env[key] = value
        elif base in WRAPPERS:
            words.pop(0)
            while words and (words[0].startswith("-") or words[0].isdigit()):
                words.pop(0)
        elif base in SHELLS:
            words.pop(0)
            while words and words[0].startswith("-") and words[0] != "-":
                opt = words.pop(0)
                if not opt.startswith("--") and "c" in opt[1:]:
                    analyze(words.pop(0) if words else "", cwd, depth + 1)
                    return
            if words:
                scan_file(words[0], cwd, "script")
            return
        elif base == "eval":
            words.pop(0)
            analyze(" ".join(words), cwd, depth + 1)
            return
        elif base in ("source", "."):
            words.pop(0)
            if words:
                scan_file(words[0], cwd, "script")
            return
        else:
            break
    if not words:
        return

    scan_text(words)
    base = os.path.basename(words[0])
    if base in INTERPRETERS:
        if len(words) > 1 and not words[1].startswith("-"):
            scan_file(words[1], cwd, "script")
    elif base == "gh":
        parse_gh(words[1:], env)
    elif base == "git":
        parse_git(words[1:], cwd)
    elif "/" in words[0]:
        scan_file(words[0], cwd, "script")


def option_value(tok, words, i, value_flags):
    """Retorna (nome, valor, próximo índice) de uma opção."""
    if tok.startswith("--") and "=" in tok:
        name, value = tok.split("=", 1)
        return name, value, i + 1
    if tok in value_flags:
        return tok, (words[i + 1] if i + 1 < len(words) else None), i + 2
    if len(tok) > 2 and not tok.startswith("--") and tok[:2] in value_flags:
        return tok[:2], tok[2:], i + 1
    return tok, None, i + 1


def parse_gh(words, env):
    repo, positionals, opts = None, [], []
    i = 0
    while i < len(words):
        tok = words[i]
        if tok.startswith("-") and tok != "-":
            name, value, i = option_value(tok, words, i, GH_VALUE_FLAGS)
            if name in ("-R", "--repo"):
                repo = value
            opts.append((name, value))
        else:
            positionals.append(tok)
            i += 1
    if not positionals:
        return
    sub = positionals[0]
    if sub not in GH_CORE:
        alias = gh_alias(sub)
        if alias is not None and (MERGE_LIKE.search(alias) or "merge" in alias):
            result["indirect"].append(f"alias do gh '{sub}'")
        return
    if sub == "pr" and len(positionals) > 1 and positionals[1] == "merge":
        merge = {"via": "gh pr merge", "repo": repo, "number": None,
                 "head": None, "admin": False, "ambiguous": [],
                 "env_repo": env.get("GH_REPO")}
        targets = positionals[2:]
        for name, value in opts:
            if name.startswith("--admin"):
                merge["admin"] = True
            elif name == "--match-head-commit":
                merge["head"] = value
            elif name not in MERGE_BOOL_FLAGS and name not in MERGE_VALUE_FLAGS:
                merge["ambiguous"].append(f"opção desconhecida {name}")
        if len(targets) > 1:
            merge["ambiguous"].append("mais de um argumento posicional")
        if targets:
            target = targets[0]
            url = re.match(r"^https://github\.com/([^/]+/[^/]+)/pull/(\d+)", target)
            if url:
                merge["repo"] = merge["repo"] or url.group(1)
                merge["number"] = url.group(2)
            else:
                merge["number"] = target
        result["merges"].append(merge)
    elif sub == "api" and len(positionals) > 1:
        path = re.match(r"^/?repos/([^/]+/[^/]+)/pulls/(\d+)/merge/?$", positionals[1])
        if not path:
            return
        merge = {"via": "gh api", "repo": path.group(1), "number": path.group(2),
                 "head": None, "admin": False, "ambiguous": [],
                 "env_repo": env.get("GH_REPO")}
        for name, value in opts:
            if name in ("-f", "-F", "--field", "--raw-field") and value \
                    and value.startswith("sha="):
                merge["head"] = value[4:]
            elif name == "--input":
                merge["ambiguous"].append("corpo via --input não é verificável")
        result["merges"].append(merge)


def gh_alias(name):
    try:
        out = subprocess.run(["gh", "alias", "list"], capture_output=True,
                             text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.stdout.splitlines():
        key, sep, expansion = line.partition(":")
        if sep and key.strip() == name:
            return expansion.strip()
    return None


def parse_git(words, cwd):
    eff, unresolved = cwd, []
    i = 0
    while i < len(words) and words[i].startswith("-"):
        tok = words[i]
        if tok == "-C" and i + 1 < len(words):
            eff = resolve(words[i + 1], eff)
            i += 2
        elif tok == "-c":
            i += 2
        elif tok.startswith("--git-dir") or tok.startswith("--work-tree"):
            unresolved.append("--git-dir/--work-tree")
            i += 1 if "=" in tok else 2
        else:
            i += 1
    if i >= len(words):
        return
    sub, rest = words[i], words[i + 1:]
    if sub in ("commit", "push", "merge", "rebase", "am") and \
            ("--no-verify" in rest or (sub == "commit" and "-n" in rest)):
        result["no_verify"] = True
    if sub != "push":
        return

    positionals, j = [], 0
    while j < len(rest):
        tok = rest[j]
        if tok in PUSH_VALUE_FLAGS:
            j += 2
            continue
        if tok in PUSH_BULK_FLAGS:
            unresolved.append(f"push em massa ({tok})")
        elif not tok.startswith("-"):
            positionals.append(tok)
        j += 1

    current = git(eff, "symbolic-ref", "--short", "-q", "HEAD")
    remote, refspecs = (positionals[0] if positionals else None), positionals[1:]
    targets = []

    def add_refspec(spec):
        spec = spec.lstrip("+")
        if "*" in spec:
            unresolved.append(f"refspec com curinga {spec}")
            return
        if spec.startswith(":"):
            src, dst = "", spec[1:]
        elif ":" in spec:
            src, dst = spec.split(":", 1)
        else:
            src = dst = spec
        if dst in ("HEAD", "") and src in ("HEAD", ""):
            if current:
                targets.append(current)
            else:
                unresolved.append("HEAD sem branch")
            return
        if dst == "HEAD":
            dst = current or "HEAD"
        if dst.startswith("refs/tags/"):
            return
        targets.append(strip_heads(dst))

    if refspecs:
        for spec in refspecs:
            add_refspec(spec)
    elif unresolved:
        pass  # push em massa ou repositório alternativo: destino já indeterminado
    else:
        if not current:
            unresolved.append("destino não determinado (HEAD sem branch ou diretório inválido)")
        else:
            remote = remote or git(eff, "config", f"branch.{current}.remote") or "origin"
            configured = git(eff, "config", "--get-all", f"remote.{remote}.push")
            if configured:
                for spec in configured.splitlines():
                    add_refspec(spec)
            else:
                mode = git(eff, "config", "push.default") or "simple"
                if mode == "matching":
                    unresolved.append("push.default=matching")
                elif mode != "nothing":
                    targets.append(current)
                    upstream = git(eff, "config", f"branch.{current}.merge")
                    if upstream:
                        targets.append(strip_heads(upstream))
    result["pushes"].append({"dir": eff, "targets": targets, "unresolved": unresolved})


analyze(os.environ.get("GUARD_CMD", ""), os.environ.get("GUARD_CWD") or os.getcwd())
print(json.dumps(result))

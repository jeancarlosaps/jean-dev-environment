"""Leitura do repositório pelo git: base, merge-base, arquivos e linhas adicionadas."""

import re
import subprocess


class GitError(Exception):
    pass


def git(repo, *args, check=True):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if check and proc.returncode != 0:
        message = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError(f"git {' '.join(args)}: {message}")
    return proc.stdout.decode("utf-8", "replace")


def rev_ok(repo, ref):
    proc = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "-q",
                           f"{ref}^{{commit}}"], capture_output=True)
    return proc.returncode == 0


def discover_base(repo, explicit=None):
    """Retorna (ref, origem). Nunca assume: informada > origin/HEAD > convenção."""
    if explicit:
        if not rev_ok(repo, explicit):
            raise GitError(f"base informada não existe: {explicit}")
        return explicit, "informada"
    head = git(repo, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD",
               check=False).strip()
    if head and rev_ok(repo, head):
        return head, "origin/HEAD"
    for ref in ("origin/main", "origin/master", "origin/dev", "origin/develop",
                "main", "master"):
        if rev_ok(repo, ref):
            return ref, "convenção (origin/HEAD ausente)"
    raise GitError("branch-base não encontrada; informe --base")


def merge_base(repo, base):
    return git(repo, "merge-base", base, "HEAD").strip()


def changed_files(repo, mb):
    """Lista de dicts {status, path, old_path} entre merge-base e HEAD."""
    out = git(repo, "diff", "--name-status", "-M", mb, "HEAD")
    files = []
    for line in out.splitlines():
        parts = line.split("\t")
        status = parts[0][0]
        if status == "R" and len(parts) == 3:
            files.append({"status": "R", "old_path": parts[1], "path": parts[2]})
        elif len(parts) >= 2:
            files.append({"status": status, "old_path": parts[1], "path": parts[1]})
    return files


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def added_lines(repo, mb, path):
    """[(número da linha em HEAD, texto)] das linhas adicionadas no arquivo."""
    out = git(repo, "diff", "-U0", "-M", mb, "HEAD", "--", path)
    lines, current = [], None
    for raw in out.splitlines():
        match = HUNK.match(raw)
        if match:
            current = int(match.group(1))
            continue
        if current is None or raw.startswith(("+++", "---")):
            continue
        if raw.startswith("+"):
            lines.append((current, raw[1:]))
            current += 1
        elif raw.startswith(" "):
            current += 1
    return lines


_READERS = {}


def show(repo, rev, path):
    """Conteúdo de rev:path, ou None (ausente ou binário). Um processo por repositório."""
    reader = _READERS.get(repo)
    if reader is None or reader.poll() is not None:
        reader = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        _READERS[repo] = reader
    reader.stdin.write(f"{rev}:{path}\n".encode("utf-8"))
    reader.stdin.flush()
    header = reader.stdout.readline().decode("utf-8", "replace").split()
    if len(header) != 3 or header[1] != "blob":
        return None
    data = reader.stdout.read(int(header[2]))
    reader.stdout.read(1)  # quebra de linha que encerra o objeto
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace")


def tracked_files(repo, rev="HEAD"):
    return git(repo, "ls-tree", "-r", "--name-only", rev).splitlines()


def uncommitted(repo):
    return [line for line in git(repo, "status", "--porcelain").splitlines() if line]

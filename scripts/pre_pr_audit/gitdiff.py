"""Leitura do repositório pelo git: base, merge-base, arquivos e linhas adicionadas."""

import re
import subprocess


class GitError(Exception):
    pass


def git(repo, *args, check=True, raw=False):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    if check and proc.returncode != 0:
        message = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError(f"git {' '.join(args)}: {message}")
    if raw:
        return proc.stdout
    return proc.stdout.decode("utf-8", "replace")


def decode_paths(data):
    """Caminhos separados por NUL (saída -z), sem aspas nem escapes do git.

    surrogateescape preserva bytes que não são UTF-8 e os devolve intactos
    ao git; caminho com quebra de linha não cabe no protocolo de leitura em
    lote e encerra a auditoria (fail-closed), em vez de ser ignorado.
    """
    paths = [p.decode("utf-8", "surrogateescape") for p in data.split(b"\0")]
    if paths and paths[-1] == "":
        paths.pop()
    for path in paths:
        if "\n" in path:
            raise GitError(f"caminho com quebra de linha não suportado: {path!r}")
    return paths


def literal(path):
    return ":(literal)" + path


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
    fields = decode_paths(git(repo, "diff", "--name-status", "-z", "-M", mb, "HEAD", raw=True))
    files, i = [], 0
    while i < len(fields):
        status = fields[i][:1]
        if status in ("R", "C"):
            if i + 2 >= len(fields):
                raise GitError("saída inesperada de git diff --name-status -z")
            files.append({"status": status, "old_path": fields[i + 1], "path": fields[i + 2]})
            i += 3
        else:
            if i + 1 >= len(fields) or status not in "AMDTU":
                raise GitError(f"saída inesperada de git diff --name-status -z: {fields[i]!r}")
            files.append({"status": status, "old_path": fields[i + 1], "path": fields[i + 1]})
            i += 2
    return files


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def added_lines(repo, mb, path, old_path=None):
    """[(número da linha em HEAD, texto)] das linhas adicionadas no arquivo."""
    specs = [literal(path)] + ([literal(old_path)] if old_path and old_path != path else [])
    out = git(repo, "diff", "-U0", "-M", mb, "HEAD", "--", *specs)
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
    """Conteúdo de rev:path, ou None se binário. Ausente é erro: quem chama
    só pede arquivos que o git listou. Um processo por repositório."""
    reader = _READERS.get(repo)
    if reader is None or reader.poll() is not None:
        reader = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        _READERS[repo] = reader
    if "\n" in path:
        raise GitError(f"caminho com quebra de linha não suportado: {path!r}")
    reader.stdin.write(f"{rev}:".encode("utf-8") + path.encode("utf-8", "surrogateescape") + b"\n")
    reader.stdin.flush()
    line = reader.stdout.readline()
    header = line.rsplit(b" ", 2)
    if len(header) == 3 and header[1] == b"blob":
        size = int(header[2])
    elif line.rstrip().endswith(b"missing"):
        raise GitError(f"objeto ausente: {rev}:{path}")
    else:
        raise GitError(f"resposta inesperada de git cat-file para {rev}:{path}")
    data = reader.stdout.read(size)
    reader.stdout.read(1)  # quebra de linha que encerra o objeto
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace")


def tracked_files(repo, rev="HEAD"):
    return decode_paths(git(repo, "ls-tree", "-r", "-z", "--name-only", rev, raw=True))


def uncommitted(repo):
    return [line for line in git(repo, "status", "--porcelain").splitlines() if line]

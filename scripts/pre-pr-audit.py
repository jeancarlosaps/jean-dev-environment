#!/usr/bin/env python3
"""pre-pr-audit — auditoria do diff da branch antes de publicar o PR.

Uso:
  python3 scripts/pre-pr-audit.py [--repo DIR] [--base REF] [--policy ARQ]
                                  [--evidence ARQ] [--scope GLOB ...]
                                  [--format markdown|json] [--output ARQ]

Compara HEAD com o merge-base da branch-base (informada, origin/HEAD ou
convenção). Lê só o git; não compila, não executa testes e não acessa rede.

Política opcional (JSON): --policy, a variável PRE_PR_AUDIT_POLICY ou
.pre-pr-audit.json na raiz do repositório auditado. Sem política, rodam só
as verificações universais. Chaves aceitas: scope_paths, ignore_paths,
required_checks, verb_synonyms, min_platforms, library.

Evidência opcional (JSON): {"checks": [{"name", "command", "exit"}]}.

Saída: 0 sem BLOCKER · 1 com BLOCKER · 2 erro de uso ou de leitura.
Requisitos: Python 3.9+ e git 2.20+.
"""
import argparse
import fnmatch
import json
import os
import sys

sys.dont_write_bytecode = True  # não deixa __pycache__ no repositório auditado nem neste
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from pre_pr_audit import core, gitdiff, report, swift  # noqa: E402
from pre_pr_audit.model import Audit, Finding  # noqa: E402

POLICY_KEYS = {"scope_paths", "ignore_paths", "required_checks", "verb_synonyms", "min_platforms", "library"}


class Context:
    def __init__(self, args):
        self.repo = os.path.abspath(args.repo)
        gitdiff.git(self.repo, "rev-parse", "--git-dir")
        self.base, self.base_origin = gitdiff.discover_base(self.repo, args.base)
        self.merge_base = gitdiff.merge_base(self.repo, self.base)
        self.head = gitdiff.git(self.repo, "rev-parse", "HEAD").strip()
        self.policy, self.policy_path = load_policy(self.repo, args.policy)
        self.evidence = load_json(args.evidence, "evidência") if args.evidence else {}
        self.scope = args.scope or []
        self.covered = []
        self._head, self._old = {}, {}
        ignore = self.policy.get("ignore_paths", [])
        self.files = []
        for f in gitdiff.changed_files(self.repo, self.merge_base):
            if any(fnmatch.fnmatch(f["path"], g) for g in ignore):
                continue
            f["added"] = gitdiff.added_lines(self.repo, self.merge_base, f["path"]) if f["status"] != "D" else []
            self.files.append(f)
        self.swift_files = [f for f in self.files if f["path"].endswith(".swift") and f["status"] != "D"
                            and not core.is_fixture_path(f["path"])]
        self.head_files = gitdiff.tracked_files(self.repo, "HEAD")
        self.old_files = gitdiff.tracked_files(self.repo, self.merge_base)
        self.uncommitted = gitdiff.uncommitted(self.repo)

    def read_head(self, path):
        if path not in self._head:
            self._head[path] = gitdiff.show(self.repo, "HEAD", path)
        return self._head[path]

    def read_old(self, path):
        if path not in self._old:
            self._old[path] = gitdiff.show(self.repo, self.merge_base, path)
        return self._old[path]

    def summary(self):
        return {"repo": os.path.basename(self.repo), "base": self.base, "base_origin": self.base_origin,
                "merge_base": self.merge_base, "head": self.head, "files_changed": len(self.files),
                "policy": os.path.basename(self.policy_path) if self.policy_path else None}


def load_json(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        raise gitdiff.GitError(f"{label} ilegível ({path}): {exc}")
    if not isinstance(data, dict):
        raise gitdiff.GitError(f"{label} deve ser um objeto JSON: {path}")
    return data


def load_policy(repo, explicit):
    path = explicit or os.environ.get("PRE_PR_AUDIT_POLICY")
    if path:
        policy = load_json(path, "política")  # configurada e ausente é erro, não silêncio
    else:
        local = os.path.join(repo, ".pre-pr-audit.json")
        if not os.path.isfile(local):
            return {}, None
        path, policy = local, load_json(local, "política")
    unknown = set(policy) - POLICY_KEYS
    if unknown:
        raise gitdiff.GitError(f"política com chave desconhecida: {', '.join(sorted(unknown))}")
    return policy, path


def main(argv=None):
    parser = argparse.ArgumentParser(description="Auditoria pré-PR do diff da branch.")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base")
    parser.add_argument("--policy")
    parser.add_argument("--evidence")
    parser.add_argument("--scope", action="append")
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    parser.add_argument("--output")
    args = parser.parse_args(argv)

    try:
        ctx = Context(args)
    except gitdiff.GitError as exc:
        print(f"pre-pr-audit: {exc}", file=sys.stderr)
        return 2

    audit = Audit()
    if not ctx.files:
        audit.add(Finding("CORE-EMPTY-DIFF", "INFO", f"nenhuma diferença entre {ctx.base} e HEAD",
                          "nada a auditar", "confirmar a branch e a base", "determinística", "alta"))
        audit.checked("diff entre merge-base e HEAD")
    else:
        audit.checked(f"diff entre merge-base {ctx.merge_base[:10]} e HEAD {ctx.head[:10]}: {len(ctx.files)} arquivo(s)")
        swift.run(audit, ctx)  # antes da duplicação genérica, que pula regiões já explicadas
        core.check_scope(audit, ctx)
        core.check_secrets(audit, ctx)
        core.check_tests(audit, ctx)
        core.check_duplication(audit, ctx)
        core.check_naming(audit, ctx, ctx.read_old)
        core.check_required(audit, ctx)
    core.check_uncommitted(audit, ctx)
    audit.skipped("comportamento em execução: a auditoria não compila nem roda testes")
    audit.skipped("revisão semântica: depende da revisão adversarial descrita na skill")

    text = report.as_json(ctx, audit) if args.format == "json" else report.as_markdown(ctx, audit)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 1 if any(f["severity"] == "BLOCKER" for f in audit.findings) else 0


if __name__ == "__main__":
    sys.exit(main())

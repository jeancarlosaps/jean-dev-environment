"""Relatório em Markdown e JSON."""

import json

from . import VERSION

ORDER = {"BLOCKER": 0, "WARNING": 1, "INFO": 2}

ADVERSARIAL = [
    "Existe duplicação evitável ou simplificação arquitetural justificada?",
    "A mudança segue os padrões do módulo (camadas, responsabilidades, nomes)?",
    "Diferenças entre versões de contrato estão isoladas num ponto só?",
    "Alguma API pública mudou sem necessidade ou sem compatibilidade?",
    "O comportamento legado (payload, headers, erros, seleção de endpoint) foi preservado?",
    "O cliente repete algo que o servidor já faz (requisição, remoção, recálculo)?",
    "Há caminho de erro sem tratamento ou com fallback que repete uma mutação?",
    "Os testes reproduzem o problema que a mudança corrige, ou só passam?",
    "A plataforma mínima declarada foi respeitada em código e testes?",
    "O diff contém algo fora do escopo do PR?",
]


def ordered(findings):
    return sorted(findings, key=lambda f: (ORDER[f["severity"]], f["rule"], f.get("file") or "", f.get("line") or 0))


def counts(findings):
    return {s: sum(1 for f in findings if f["severity"] == s) for s in ORDER}


def as_json(ctx, audit):
    return json.dumps({
        "tool": "pre-pr-audit", "version": VERSION,
        "context": ctx.summary(),
        "counts": counts(audit.findings),
        "findings": ordered(audit.findings),
        "verified": audit.verified,
        "not_evaluated": audit.not_evaluated,
        "adversarial_review": {"status": "pendente", "questions": ADVERSARIAL},
    }, ensure_ascii=False, indent=2)


def cell(text):
    return str(text if text is not None else "").replace("|", "\\|").replace("\n", " ")


def as_markdown(ctx, audit):
    info = ctx.summary()
    total = counts(audit.findings)
    out = ["# Auditoria pré-PR", "",
           "| Item | Valor |", "|---|---|",
           f"| Repositório | `{cell(info['repo'])}` |",
           f"| Base | `{cell(info['base'])}` ({cell(info['base_origin'])}) |",
           f"| Merge-base | `{cell(info['merge_base'])}` |",
           f"| HEAD | `{cell(info['head'])}` |",
           f"| Arquivos alterados | {info['files_changed']} |",
           f"| Política | {cell(info['policy'] or 'nenhuma (só verificações universais)')} |",
           "", f"## Achados — {total['BLOCKER']} BLOCKER · {total['WARNING']} WARNING · {total['INFO']} INFO", ""]
    if audit.findings:
        out += ["| Severidade | Regra | Local | Evidência | Impacto | Recomendação | Método | Confiança |",
                "|---|---|---|---|---|---|---|---|"]
        for f in ordered(audit.findings):
            where = f["file"] or "—"
            if f["file"] and f["line"]:
                where = f"{f['file']}:{f['line']}"
            out.append("| " + " | ".join(cell(x) for x in (
                f["severity"], f["rule"], where, f["evidence"], f["impact"], f["recommendation"],
                f["method"], f["confidence"])) + " |")
    else:
        out.append("Nenhum achado.")
    out += ["", "## Verificado", ""] + [f"- {cell(v)}" for v in audit.verified]
    out += ["", "## Não avaliado", ""] + [f"- {cell(v)}" for v in audit.not_evaluated]
    out += ["", "## Revisão adversarial (pendente)", "",
            "Responder cada pergunta com evidência `arquivo:linha` do diff. Resposta sem evidência não conta.", ""]
    out += [f"{i}. {q}" for i, q in enumerate(ADVERSARIAL, 1)]
    out += ["", "**Resultado:** " + (
        f"BLOQUEADO ({total['BLOCKER']} BLOCKER)." if total["BLOCKER"] else
        "sem BLOCKER. WARNINGs exigem análise antes de publicar; a revisão adversarial continua pendente.")]
    return "\n".join(out) + "\n"

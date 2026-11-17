"""Padrões de credencial e mascaramento.

Usado pela regra CORE-SECRET e, de forma independente, por todo achado
registrado: nenhum texto de relatório (evidência, impacto, recomendação)
sai com uma credencial reconhecível, seja qual for a regra que o produziu.
"""

import re

SECRET_RULES = [
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b"), "token do GitHub"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{60,}\b"), "token do GitHub (fine-grained)"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "chave de acesso AWS"),
    (re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----"), "chave privada"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"), "token do Slack"),
    (re.compile(r"\bsk_live_[0-9A-Za-z]{24,}\b"), "chave secreta de pagamento"),
    (re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b"), "chave de API do Google"),
]
GENERIC_SECRET = re.compile(
    r"(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\b\s*[:=]\s*[\"']([^\"'\s]{8,})[\"']")


def mask(secret):
    return secret[:4] + "…" if len(secret) > 4 else "…"


def redact(text):
    """Mascara credenciais reconhecíveis em qualquer texto de relatório."""
    if not isinstance(text, str):
        return text
    for pattern, _ in SECRET_RULES:
        text = pattern.sub(lambda m: mask(m.group(0)), text)
    return GENERIC_SECRET.sub(lambda m: m.group(0).replace(m.group(2), mask(m.group(2))), text)

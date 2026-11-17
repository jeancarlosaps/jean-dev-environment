"""Achados, contexto da auditoria e o que foi ou não verificado."""

SEVERITIES = ("BLOCKER", "WARNING", "INFO")


class Finding(dict):
    """Um achado com evidência. Campos fixos para o relatório e o JSON.

    severity: BLOCKER (violação comprovada de requisito obrigatório),
              WARNING (possível problema que exige investigação),
              INFO (melhoria opcional).
    method:   "determinística" (casamento exato de regra) ou
              "heurística" (padrão que pode errar).
    """

    def __init__(self, rule, severity, evidence, impact, recommendation,
                 method, confidence, file=None, line=None):
        assert severity in SEVERITIES, severity
        assert method in ("determinística", "heurística"), method
        assert confidence in ("alta", "média", "baixa"), confidence
        super().__init__(rule=rule, severity=severity, file=file, line=line,
                         evidence=evidence, impact=impact,
                         recommendation=recommendation, method=method,
                         confidence=confidence)


class Audit:
    """Estado compartilhado entre as verificações."""

    def __init__(self):
        self.findings = []
        self.verified = []
        self.not_evaluated = []

    def add(self, finding):
        self.findings.append(finding)

    def checked(self, text):
        if text not in self.verified:
            self.verified.append(text)

    def skipped(self, text):
        if text not in self.not_evaluated:
            self.not_evaluated.append(text)

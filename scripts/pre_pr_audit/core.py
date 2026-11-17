"""Verificações universais: valem para qualquer repositório e linguagem."""

import fnmatch
import hashlib
import os
import re

from .credentials import GENERIC_SECRET, SECRET_RULES, mask
from .model import Finding

SOURCE_EXT = {
    ".swift": "Swift", ".m": "Objective-C", ".mm": "Objective-C",
    ".py": "Python", ".js": "JavaScript", ".jsx": "JavaScript",
    ".ts": "TypeScript", ".tsx": "TypeScript", ".go": "Go", ".kt": "Kotlin",
    ".java": "Java", ".rb": "Ruby", ".rs": "Rust", ".cs": "C#", ".php": "PHP",
    ".c": "C", ".cc": "C++", ".cpp": "C++", ".h": "C/C++", ".sh": "Shell",
}
TEST_DIRS = {"test", "tests", "spec", "specs", "__tests__", "testing"}
TEST_NAME = re.compile(
    r"(Tests?|Spec|UITests?)\.(swift|kt|java|m)$|^test_.*\.py$|_test\.(py|go)$"
    r"|\.(test|spec)\.[jt]sx?$|_spec\.rb$")
FIXTURE_DIRS = {"fixtures", "fixture", "testdata", "__snapshots__", "snapshots"}

PERSONAL_PATH = re.compile(r"(/Users/(?!Shared/)[A-Za-z][^/\s\"']*/|/home/[a-z][^/\s\"']*/)")
DEFAULT_SYNONYMS = [["remove", "delete", "del"]]
IDENTIFIER = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")
STRING_OR_COMMENT = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|//.*$|#.*$")


def is_test_path(path):
    parts = path.split("/")
    if any(p.lower() in TEST_DIRS or p.endswith(("Tests", "UITests")) for p in parts[:-1]):
        return True
    return bool(TEST_NAME.search(parts[-1]))


def is_fixture_path(path):
    return any(p.lower() in FIXTURE_DIRS for p in path.split("/")[:-1])


def language(path):
    return SOURCE_EXT.get(os.path.splitext(path)[1])


def matches_any(path, globs):
    return any(fnmatch.fnmatch(path, g) for g in globs)


def check_scope(audit, ctx):
    scope = ctx.policy.get("scope_paths") or ctx.scope
    if not scope:
        audit.skipped("escopo: nenhum escopo declarado (--scope ou scope_paths na política)")
        return
    outside = [f["path"] for f in ctx.files if not matches_any(f["path"], scope)]
    audit.checked(f"escopo: {len(ctx.files)} arquivo(s) comparados com {', '.join(scope)}")
    for path in outside:
        audit.add(Finding(
            "CORE-SCOPE", "WARNING", f"{path} fora do escopo declarado ({', '.join(scope)})",
            "mudança fora do escopo mistura assuntos no mesmo PR",
            "mover para outra branch/PR ou ajustar o escopo declarado",
            "determinística", "alta", file=path))


def check_secrets(audit, ctx):
    for f in ctx.files:
        for line_no, text in f["added"]:
            found = False
            for pattern, label in SECRET_RULES:
                match = pattern.search(text)
                if match:
                    found = True
                    audit.add(Finding(
                        "CORE-SECRET", "BLOCKER", f"{label} adicionado: {mask(match.group(0))}",
                        "credencial publicada no histórico do repositório",
                        "remover do commit (reescrevendo o histórico local) e revogar a credencial",
                        "determinística", "alta", file=f["path"], line=line_no))
            generic = GENERIC_SECRET.search(text)
            if generic and not found and not is_test_path(f["path"]):
                audit.add(Finding(
                    "CORE-SECRET-LIKE", "WARNING",
                    f"valor literal atribuído a '{generic.group(1)}': {mask(generic.group(2))}",
                    "pode ser credencial real", "confirmar que é valor fictício ou mover para segredo",
                    "heurística", "média", file=f["path"], line=line_no))
            personal = PERSONAL_PATH.search(text)
            if personal:
                audit.add(Finding(
                    "CORE-LOCAL-PATH", "WARNING", f"caminho pessoal adicionado: {personal.group(1)}",
                    "expõe dado da máquina e quebra em outro ambiente",
                    "usar caminho relativo, variável de ambiente ou $HOME",
                    "determinística", "alta", file=f["path"], line=line_no))
    audit.checked("segredos (formatos conhecidos e atribuições literais) e caminhos pessoais nas linhas adicionadas")


def check_tests(audit, ctx):
    # renomeação sem linha alterada não muda comportamento
    changed = [f for f in ctx.files if f["status"] != "D" and not (f["status"] == "R" and not f["added"])]
    tests_by_lang, sources_by_lang = {}, {}
    for f in changed:
        lang = language(f["path"])
        if not lang or is_fixture_path(f["path"]):
            continue
        bucket = tests_by_lang if is_test_path(f["path"]) else sources_by_lang
        bucket.setdefault(lang, []).append(f["path"])
    all_tests = [p for paths in tests_by_lang.values() for p in paths]
    test_text = "\n".join(ctx.read_head(p) or "" for p in all_tests)
    for lang, sources in sorted(sources_by_lang.items()):
        if lang in tests_by_lang:
            continue
        # teste em outra linguagem que cita o arquivo pelo nome também cobre
        sources = [s for s in sources if os.path.basename(s) not in test_text]
        if not sources:
            continue
        shown = ", ".join(sources[:5]) + (" …" if len(sources) > 5 else "")
        audit.add(Finding(
            "CORE-TESTS-MISSING", "WARNING",
            f"{len(sources)} arquivo(s) {lang} alterado(s) sem teste {lang} no diff: {shown}",
            "comportamento alterado pode ficar sem cobertura",
            "acrescentar ou ajustar teste que exercite a mudança, ou registrar por que não se aplica",
            "heurística", "média", file=sources[0]))
    audit.checked("testes: código-fonte alterado comparado com arquivos de teste no diff, por linguagem")


def normalize(line):
    line = re.sub(r"\s+", " ", line.strip())
    return line


def trivial(line):
    return not line or len(line) < 4 or re.fullmatch(r"[\s{}()\[\];,]*", line) is not None \
        or line.startswith(("//", "#", "/*", "*", "import ", "from ", "}"))


def check_duplication(audit, ctx, window=6):
    seen, reported = {}, []
    for f in ctx.files:
        if is_test_path(f["path"]) or is_fixture_path(f["path"]) or not language(f["path"]):
            continue
        rows = [(n, normalize(t)) for n, t in f["added"] if not trivial(normalize(t))]
        for i in range(len(rows) - window + 1):
            chunk = rows[i:i + window]
            if chunk[-1][0] - chunk[0][0] > window * 3:
                continue  # linhas não contíguas no arquivo
            start = chunk[0][0]
            if any(lo <= start <= hi for (p, lo, hi) in ctx.covered if p == f["path"]):
                continue
            key = hashlib.sha1("\n".join(t for _, t in chunk).encode()).hexdigest()
            here = (f["path"], start)
            first = seen.setdefault(key, here)
            if first == here or (first[0] == here[0] and abs(first[1] - start) < window):
                continue
            # um achado por bloco repetido, não um por janela deslizante
            if any(p == here[0] and 0 <= start - s < 40 for p, s in reported):
                continue
            reported.append(here)
            audit.add(Finding(
                "CORE-DUPLICATION", "WARNING",
                f"{window}+ linhas adicionadas idênticas em {first[0]}:{first[1]} e {here[0]}:{here[1]}",
                "lógica repetida diverge com o tempo",
                "avaliar extração para um ponto único; manter se a repetição for intencional",
                "heurística", "média", file=here[0], line=here[1]))
    audit.checked(f"duplicação: blocos de {window}+ linhas adicionadas idênticas (sem testes e fixtures)")


def identifier_prefix(identifier, synonyms):
    """Primeira palavra do identificador (camelCase, PascalCase ou snake_case) se for sinônimo."""
    word = re.match(r"^_?([A-Za-z][a-z0-9]*)", identifier)
    if not word:
        return None
    head = word.group(1).lower()
    rest = identifier[word.end():]
    if rest and not (rest[0].isupper() or rest[0] == "_" or rest[0].isdigit()):
        return None
    if not rest:
        return None  # palavra sozinha (ex.: remove) não indica convenção de nome
    for group in synonyms:
        if head in group:
            return head
    return None


def module_of(path):
    parts = path.split("/")
    if "Sources" in parts:
        i = parts.index("Sources")
        return "/".join(parts[:i + 2])
    if "src" in parts:
        i = parts.index("src")
        return "/".join(parts[:i + 1])
    return parts[0] if len(parts) > 1 else "."


def strip_strings_comments(text):
    return STRING_OR_COMMENT.sub(" ", text)


def check_naming(audit, ctx, read_old):
    synonyms = [list(map(str.lower, g)) for g in DEFAULT_SYNONYMS + ctx.policy.get("verb_synonyms", [])]
    vocab_cache = {}

    def vocabulary(module):
        if module not in vocab_cache:
            counts = {}
            for path in ctx.old_files:
                if not language(path) or not (path == module or path.startswith(module.rstrip("/") + "/") or module == "."):
                    continue
                text = read_old(path) or ""
                for ident in set(IDENTIFIER.findall(strip_strings_comments(text))):
                    prefix = identifier_prefix(ident, synonyms)
                    if prefix:
                        counts[prefix] = counts.get(prefix, 0) + 1
            vocab_cache[module] = counts
        return vocab_cache[module]

    reported = set()
    for f in ctx.files:
        if not language(f["path"]) or is_fixture_path(f["path"]):
            continue
        module = module_of(f["path"])
        for line_no, text in f["added"]:
            for ident in IDENTIFIER.findall(strip_strings_comments(text)):
                prefix = identifier_prefix(ident, synonyms)
                if not prefix or (module, ident) in reported:
                    continue
                group = next(g for g in synonyms if prefix in g)
                counts = vocabulary(module)
                dominant = max(group, key=lambda w: counts.get(w, 0))
                if dominant != prefix and counts.get(dominant, 0) >= 2 and counts.get(prefix, 0) == 0:
                    reported.add((module, ident))
                    audit.add(Finding(
                        "CORE-NAMING", "INFO",
                        f"'{ident}' usa '{prefix}', mas o módulo {module} usa '{dominant}' "
                        f"({counts[dominant]} identificadores antes desta mudança; '{prefix}': 0)",
                        "nomes equivalentes com verbos diferentes dificultam busca e leitura",
                        f"seguir o vocabulário do módulo ('{dominant}…')",
                        "heurística", "média", file=f["path"], line=line_no))
    audit.checked("nomenclatura: verbos sinônimos em identificadores novos comparados ao vocabulário do módulo na base")


def check_required(audit, ctx):
    required = ctx.policy.get("required_checks", [])
    if not required:
        audit.skipped("verificações obrigatórias: nenhuma declarada na política")
        return
    runs = {c.get("name"): c for c in ctx.evidence.get("checks", [])}
    for name in required:
        run = runs.get(name)
        if run is None:
            audit.add(Finding(
                "CORE-CHECK-UNPROVEN", "WARNING", f"verificação obrigatória '{name}' sem evidência de execução",
                "o PR pode ser publicado sem a validação exigida",
                f"executar '{name}' e registrar o resultado no arquivo de evidência (--evidence)",
                "determinística", "alta"))
        elif run.get("exit") != 0:
            audit.add(Finding(
                "CORE-CHECK-FAILED", "BLOCKER",
                f"verificação obrigatória '{name}' falhou (exit {run.get('exit')}): {run.get('command', '')}",
                "requisito obrigatório não atendido", "corrigir até a verificação passar",
                "determinística", "alta"))
    audit.checked(f"verificações obrigatórias da política: {', '.join(required)}")


def check_uncommitted(audit, ctx):
    if ctx.uncommitted:
        audit.add(Finding(
            "CORE-UNCOMMITTED", "INFO",
            f"{len(ctx.uncommitted)} alteração(ões) não commitada(s) fora da auditoria",
            "o PR não conterá essas alterações; a auditoria cobre só commits",
            "commitar o que pertence ao PR ou separar o resto", "determinística", "alta"))

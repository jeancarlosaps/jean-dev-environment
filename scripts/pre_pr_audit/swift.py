"""Especialização Swift/iOS.

Sem compilador: o código é limpo (comentários e strings viram espaços,
posições preservadas) e as estruturas são lidas por casamento de chaves.
Declarações e tabelas de API são verificações determinísticas no nível do
texto; conclusões sobre comportamento são heurísticas e marcadas assim.
"""

import os
import re

from .core import is_fixture_path, is_test_path
from .model import Finding

PLATFORMS = {"iOS": "ios", "macOS": "macos", "tvOS": "tvos", "watchOS": "watchos",
             "visionOS": "visionos", "macCatalyst": "maccatalyst"}

# Tabela curada a partir da documentação de disponibilidade da Apple. Não é
# exaustiva. "alta": o símbolo é inequívoco; "média": pode ser tipo próprio.
# Último campo: nome que, declarado pelo projeto, indica backport (rebaixa a WARNING).
AVAILABILITY = [
    (r"\bTask\s*\.\s*sleep\s*\(\s*for\s*:", "Task.sleep(for:)", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "sleep"),
    (r"\bTask\s*\.\s*sleep\s*\(\s*until\s*:", "Task.sleep(until:)", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "sleep"),
    (r"\b(ContinuousClock|SuspendingClock)\b", "ContinuousClock/SuspendingClock", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "ContinuousClock"),
    (r"\bNavigationStack\b", "NavigationStack", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "NavigationStack"),
    (r"\bNavigationSplitView\b", "NavigationSplitView", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "NavigationSplitView"),
    (r"\bImageRenderer\b", "ImageRenderer", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "ImageRenderer"),
    (r"\.toolbar\s*\(\s*\.hidden", "toolbar(.hidden)", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta", "toolbar"),
    (r"\bRegex\s*<", "Regex<…>", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "média", "Regex"),
    (r"\bContentUnavailableView\b", "ContentUnavailableView", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta", "ContentUnavailableView"),
    (r"@Observable\b", "@Observable", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta", "Observable"),
    (r"@Bindable\b", "@Bindable", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta", "Bindable"),
    (r"\.scrollTargetBehavior\s*\(", "scrollTargetBehavior(_:)", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta", "scrollTargetBehavior"),
    (r"\.containerRelativeFrame\s*\(", "containerRelativeFrame(_:)", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta", "containerRelativeFrame"),
    (r"\.sensoryFeedback\s*\(", "sensoryFeedback(_:trigger:)", {"ios": 17, "macos": 14, "watchos": 10}, "alta", "sensoryFeedback"),
    (r"\.onChange\s*\(\s*of\s*:[^)\n]*\binitial\s*:", "onChange(of:initial:_:)", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta", "onChange"),
    (r"\bAsyncImage\b", "AsyncImage", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "alta", "AsyncImage"),
    (r"\.refreshable\s*\{", "refreshable(action:)", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "alta", "refreshable"),
    (r"\bURLSession\b[^\n]*\.data\s*\(\s*(from|for)\s*:", "URLSession.data(from:/for:) async", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "alta", None),
    (r"\.formatted\s*\(", "formatted(_:)", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "média", "formatted"),
]
AVAILABILITY = [(re.compile(p), s, v, c, d) for p, s, v, c, d in AVAILABILITY]

TYPE_KINDS = ("class", "struct", "enum", "protocol", "actor", "extension")
DECL = re.compile(
    r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*"
    r"(?P<access>public|open)\s+"
    r"(?:(?:final|static|class|override|mutating|nonmutating|convenience|required|dynamic|lazy|weak|unowned|indirect|nonisolated|async|private\(set\)|internal\(set\)|fileprivate\(set\))\s+)*"
    r"(?P<kind>func|init|var|let|subscript|class|struct|enum|protocol|typealias|actor|case)\b(?P<rest>.*)$")
TYPE_DECL = re.compile(r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|open|internal|fileprivate|private|final|indirect)\s+)*"
                       r"(?P<kind>class|struct|enum|protocol|actor|extension)\s+(?P<name>[A-Za-z_][\w.]*)"
                       r"(?:\s*<[^>{]*>)?(?:\s*:\s*(?P<inherits>[^{]+?))?\s*(?:where\b[^{]*)?\{")
PROTOCOL_MEMBER = re.compile(r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:static|class|mutating|nonmutating|nonisolated|async)\s+)*"
                             r"(?P<kind>func|var|init|subscript|associatedtype)\b(?P<rest>.*)$")
MUTATION = re.compile(r"(?i)^(add|remove|delete|apply|submit|create|update|post|put|patch|purchase|pay|select|set|save|send|place|cancel)")


# ---------------------------------------------------------------------
# Leitura do código
# ---------------------------------------------------------------------

def clean(text):
    """Comentários e conteúdo de strings viram espaços; quebras de linha ficam."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1; j += 2
                elif text.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j])); i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
            hashes = len(re.match(r'#*', text[i:]).group(0))
            start = i + hashes
            triple = text.startswith('"""', start)
            quote = '"""' if triple else '"'
            close = quote + "#" * hashes
            j = start + len(quote)
            while j < n:
                if text[j] == "\\" and not hashes:
                    j += 2; continue
                if text.startswith(close, j):
                    j += len(close); break
                if text[j] == "\n" and not triple:
                    break
                j += 1
            out.append('"' + re.sub(r"[^\n]", " ", text[i + 1:j - 1]) + '"' if j - i >= 2 else text[i:j]); i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def block_end(code, open_index):
    """Índice após a chave que fecha a aberta em open_index."""
    depth = 0
    for j in range(open_index, len(code)):
        if code[j] == "{":
            depth += 1
        elif code[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    return len(code)


# ---------------------------------------------------------------------
# Deployment target e disponibilidade
# ---------------------------------------------------------------------

def parse_version(text):
    """'15', '15.4', '10_15' → (15,), (15, 4), (10, 15). Tupla: 15.10 > 15.9."""
    return tuple(int(p) for p in re.findall(r"\d+", text))


def show_version(version):
    return ".".join(str(p) for p in version)


def manifest_platforms(text):
    """Plataformas de um Package.swift. A declaração é localizada no código sem
    comentários; o literal de .iOS("15.0") é lido no texto original, na mesma
    posição (a limpeza apaga o conteúdo das strings, mas preserva posições)."""
    found = {}
    code = clean(text)
    for name, key in PLATFORMS.items():
        for match in re.finditer(r"\." + name + r"\s*\(\s*(?:\.v(\d+(?:_\d+)*)|\"([^\"\n]*)\")\s*\)", code):
            if match.group(1):
                found[key] = parse_version(match.group(1))
            else:
                literal = text[match.start(2):match.end(2)]
                if re.fullmatch(r"\d+(\.\d+)*", literal):
                    found[key] = parse_version(literal)
    return found


def project_platforms(read_head, tracked):
    """Alvos de project.pbxproj: {plataforma: (mínimo, valores distintos)}."""
    values = {}
    for path in tracked:
        if path.endswith("project.pbxproj") and not is_fixture_path(path):
            text = read_head(path) or ""
            for setting, key in (("IPHONEOS", "ios"), ("MACOSX", "macos"), ("TVOS", "tvos"), ("WATCHOS", "watchos")):
                for match in re.finditer(setting + r"_DEPLOYMENT_TARGET = ([\d.]+);", text):
                    values.setdefault(key, set()).add(parse_version(match.group(1)))
    return {k: (min(v), len(v)) for k, v in values.items()}


def targets_for(path, ctx, read_head):
    """Alvos válidos para o arquivo e se são inequívocos.

    Ordem: política (min_platforms) > Package.swift ancestral mais próximo >
    project.pbxproj. pbxproj com valores diferentes por target é ambíguo:
    não se sabe a qual target o arquivo pertence.
    """
    policy = ctx.policy.get("min_platforms") or {}
    if policy:
        return {k.lower(): parse_version(str(v)) for k, v in policy.items()}, "política", True
    manifests = {p for p in ctx.head_files if os.path.basename(p) == "Package.swift" and not is_fixture_path(p)}
    directory = os.path.dirname(path)
    while True:
        candidate = os.path.join(directory, "Package.swift") if directory else "Package.swift"
        if candidate in manifests:
            found = manifest_platforms(read_head(candidate) or "")
            if found:
                return found, candidate, True
        if not directory:
            break
        directory = os.path.dirname(directory)
    project = project_platforms(read_head, ctx.head_files)
    if project:
        return ({k: v[0] for k, v in project.items()}, "project.pbxproj",
                all(count == 1 for _, count in project.values()))
    return {}, None, False


DECL_START = re.compile(
    r"\s*(?:@|}|(?:(?:public|open|internal|fileprivate|private|package|static|class|final|override|mutating|"
    r"nonmutating|nonisolated|convenience|required|dynamic|lazy|weak|unowned|indirect)\s+)*"
    r"(?:func|init|deinit|var|let|typealias|associatedtype|subscript|case|struct|class|enum|actor|protocol|extension)\b)")
BODYLESS = ("typealias", "associatedtype", "case")


def statement_keyword(code, at):
    """if/guard/while da lista de condições que contém a posição at, ou None.

    Volta até a palavra-chave sem atravessar chave: a condição de
    disponibilidade pode ser a primeira ou vir depois de outras
    (if enabled, #available(iOS 16, *) { … })."""
    j = at - 1
    while j >= 0 and code[j] not in "{};":
        j -= 1
    head = code[j + 1:at]
    match = None
    for match in re.finditer(r"\b(if|guard|while)\b", head):
        pass
    return (match.group(1), j + 1 + match.end()) if match else None


def condition_body(code, start):
    """Índice da { que abre o corpo do comando: a primeira fora de parênteses."""
    depth = 0
    for j in range(start, len(code)):
        c = code[j]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "{" and depth == 0:
            return j
    return -1


def rest_of_block(code, start):
    depth, j = 0, start
    while j < len(code):
        if code[j] == "{":
            depth += 1
        elif code[j] == "}":
            if depth == 0:
                return j
            depth -= 1
        j += 1
    return j


def declaration_extent(code, start):
    """Fim da declaração que começa em start (depois dos atributos).

    Com corpo, vai até a } que o fecha. Sem corpo (typealias, case,
    requisito de protocolo, propriedade armazenada), termina na quebra de
    linha que antecede a próxima declaração: o atributo não protege o que
    vem depois."""
    while start < len(code) and code[start].isspace():
        start += 1
    kind = re.match(r"\s*(?:\w+\s+)*?(func|init|deinit|var|let|typealias|associatedtype|subscript|case|"
                    r"struct|class|enum|actor|protocol|extension)\b", code[start:])
    if kind and kind.group(1) in BODYLESS:
        end = code.find("\n", start)
        return len(code) if end < 0 else end
    depth, j = 0, start
    while j < len(code):
        c = code[j]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "{" and depth == 0:
            return block_end(code, j)
        elif c == "\n" and depth == 0 and DECL_START.match(code, j + 1):
            return j  # a próxima linha já é outra declaração: esta não tem corpo
        j += 1
    return len(code)


def guarded_regions(code):
    """[(início, fim, {plataforma: versão})] cobertos por #available/@available/#unavailable."""
    regions = []
    for match in re.finditer(r"#(available|unavailable)\s*\(([^)]*)\)", code):
        spec = availability_spec(match.group(2))
        owner = statement_keyword(code, match.start())
        if not spec or not owner:
            continue
        keyword, _ = owner
        brace = condition_body(code, match.end())
        if brace < 0:
            continue
        body_end = block_end(code, brace)
        if match.group(1) == "available":
            if keyword == "guard":
                regions.append((body_end, rest_of_block(code, body_end), spec))
            else:
                regions.append((brace, body_end, spec))
        elif keyword == "if":
            other = re.match(r"\s*else\s*\{", code[body_end:])
            if other:
                open_index = body_end + other.end() - 1
                regions.append((open_index, block_end(code, open_index), spec))
        elif keyword == "guard":  # guard #unavailable(...) else { protegido } — corpo do else
            regions.append((brace, body_end, spec))
    for match in re.finditer(r"@available\s*\(([^)]*)\)", code):
        spec = availability_spec(match.group(1))
        if not spec:
            continue
        start = match.end()
        while True:  # pula atributos seguintes (@available de outra plataforma, @MainActor…)
            more = re.match(r"\s*@\w+(?:\s*\((?:[^()]|\([^()]*\))*\))?", code[start:])
            if not more:
                break
            start += more.end()
        regions.append((match.start(), declaration_extent(code, start), spec))
    return regions


def availability_spec(text):
    spec = {}
    for name, key in PLATFORMS.items():
        match = re.search(r"\b" + name + r"\s+([\d.]+)", text) or \
            re.search(r"\b" + name + r"\s*,[^)]*?\bintroduced\s*:\s*([\d.]+)", text)
        if match:
            spec[key] = parse_version(match.group(1))
    return spec


def conditional_regions(code):
    """[(início, fim)] de blocos #if … #endif: a plataforma que compila o trecho é incerta."""
    regions, stack = [], []
    for match in re.finditer(r"^[ \t]*#(if|endif)\b", code, re.M):
        if match.group(1) == "if":
            stack.append(match.start())
        elif stack:
            regions.append((stack.pop(), match.end()))
    return regions


def project_declares(name, ctx, read_head):
    """O projeto declara um símbolo com o mesmo nome (ex.: backport)?"""
    pattern = re.compile(r"\b(?:struct|class|enum|actor|typealias|protocol|func|macro)\s+" + re.escape(name) + r"\b")
    for path in ctx.head_files:
        if path.endswith(".swift") and not is_fixture_path(path):
            if pattern.search(clean(read_head(path) or "")):
                return True
    return False


def check_availability(audit, ctx, read_head):
    shown, declared_cache = {}, {}
    for f in ctx.swift_files:
        targets, origin, unambiguous = targets_for(f["path"], ctx, read_head)
        if not targets:
            audit.skipped(f"disponibilidade de API em {f['path']}: deployment target não encontrado")
            continue
        shown[origin] = ", ".join(f"{k} {show_version(v)}" for k, v in sorted(targets.items()))
        text = read_head(f["path"]) or ""
        code = clean(text)
        regions = guarded_regions(code)
        conditionals = conditional_regions(code)
        added = {n for n, _ in f["added"]}
        for pattern, symbol, needs, confidence, declared_name in AVAILABILITY:
            for match in pattern.finditer(code):
                line = line_of(code, match.start())
                if line not in added:
                    continue
                before = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
                if re.search(r"\b(?:struct|class|enum|actor|typealias|protocol|func)\s+$", before):
                    continue  # declaração do próprio projeto, não uso da API
                failing = []
                for platform, minimum in targets.items():
                    required = needs.get(platform)
                    if required is None or minimum >= (required,):
                        continue
                    covered = any(lo <= match.start() < hi and spec.get(platform, ()) >= (required,)
                                  for lo, hi, spec in regions)
                    if not covered:
                        failing.append(f"{platform} {required}+ (alvo {show_version(minimum)})")
                if not failing:
                    continue
                doubts = []
                if confidence != "alta":
                    doubts.append("o símbolo pode ser um tipo do próprio projeto")
                if not unambiguous:
                    doubts.append("project.pbxproj tem alvos diferentes por target")
                if any(lo <= match.start() < hi for lo, hi in conditionals):
                    doubts.append("o uso está dentro de #if; a plataforma que compila o trecho é incerta")
                if declared_name:
                    if declared_name not in declared_cache:
                        declared_cache[declared_name] = project_declares(declared_name, ctx, read_head)
                    if declared_cache[declared_name]:
                        doubts.append(f"o projeto declara '{declared_name}' (possível backport)")
                proven = not doubts
                evidence = f"{symbol} exige {', '.join(failing)} e não está protegido por #available/@available"
                if doubts:
                    evidence += "; não comprovado: " + "; ".join(doubts)
                audit.add(Finding(
                    "SWIFT-AVAILABILITY", "BLOCKER" if proven else "WARNING", evidence,
                    "não compila na plataforma mínima declarada" if proven else
                    "pode não compilar na plataforma mínima declarada",
                    "usar API equivalente disponível no alvo ou proteger com if #available",
                    "determinística" if proven else "heurística", "alta" if proven else "média",
                    file=f["path"], line=line))
    if shown:
        audit.checked("disponibilidade de API nas linhas adicionadas (tabela curada, não exaustiva) contra "
                      + "; ".join(f"{v} ({k})" for k, v in sorted(shown.items())))


# ---------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------

def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


def tidy(text):
    text = collapse(text)
    text = re.sub(r"\s*->\s*", "->", text)
    return re.sub(r"\s*([(),:<>\[\]?!&])\s*", r"\1", text)


def split_top(text, sep=","):
    """Divide por sep fora de (), [], {} e <> (exceto o > de ->)."""
    parts, depth, start, i = [], 0, 0, 0
    while i < len(text):
        c = text[i]
        if c in "([{<":
            depth += 1
        elif c in ")]}" or (c == ">" and text[i - 1:i] != "-"):
            depth -= 1
        elif c == sep and depth == 0:
            parts.append(text[start:i]); start = i + 1
        i += 1
    parts.append(text[start:])
    return parts


def canonical_param(param):
    """'label nome: Tipo = padrão' → 'label:Tipo' (+ '=' se aceita omissão).

    O nome local e o valor do padrão não mudam a chamada; o rótulo externo,
    o tipo e a possibilidade de omitir o argumento mudam.
    """
    head, _, after = param.partition(":")
    pieces = split_top(after, "=")
    type_text, has_default = pieces[0], len(pieces) > 1
    names = [n for n in head.split() if not n.startswith("@")]
    label = names[0] if names else "_"
    return f"{label}:{tidy(type_text)}" + ("=" if has_default else "")


def signature(kind, rest):
    rest = rest.split("{")[0]
    if kind in ("var", "let"):
        rest = split_top(rest, "=")[0]
        return " " + tidy(rest).rstrip(":")
    if kind == "typealias":  # o tipo associado é a própria API do alias
        parts = split_top(rest, "=")
        return " " + tidy(parts[0]) + ("=" + tidy("=".join(parts[1:])) if len(parts) > 1 else "")
    start = rest.find("(")
    if start < 0:
        return " " + tidy(rest).rstrip(":")
    depth, end = 0, start
    for end in range(start, len(rest)):
        depth += {"(": 1, ")": -1}.get(rest[end], 0)
        if depth == 0:
            break
    name = tidy(rest[:start])
    params = [canonical_param(p) for p in split_top(rest[start + 1:end]) if p.strip()]
    sig = f"{name}({','.join(params)}){tidy(rest[end + 1:])}"
    return sig if sig.startswith(("(", "<")) else " " + sig


def parse_key(key):
    """'Dono.func nome(a:Int=,b:String)->X' → (prefixo, [parâmetros], sufixo)."""
    start = key.find("(")
    if start < 0:
        return None
    depth = 0
    for end in range(start, len(key)):
        depth += {"(": 1, ")": -1}.get(key[end], 0)
        if depth == 0:
            break
    return key[:start], [p for p in split_top(key[start + 1:end]) if p], key[end + 1:]


def compatible(old_key, new_key):
    """A chamada da API antiga continua válida na nova? Só aceita padrão novo."""
    old, new = parse_key(old_key), parse_key(new_key)
    if not old or not new or old[0] != new[0] or old[2] != new[2] or len(old[1]) != len(new[1]):
        return False
    for before, after in zip(old[1], new[1]):
        if before.rstrip("=") != after.rstrip("="):
            return False
        if before.endswith("=") and not after.endswith("="):
            return False
    return True


def member_key(owner, kind, rest, static=False):
    """static e class func/var são chamados pelo tipo (S.load()); método de
    instância, pela instância. São APIs diferentes."""
    return f"{owner}.{'static ' if static else ''}{kind}{signature(kind, rest)}"


MEMBER = re.compile(
    r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*"
    r"(?P<mods>(?:(?:static|class|final|override|mutating|nonmutating|convenience|required|dynamic|lazy|nonisolated|async|private\(set\)|internal\(set\)|fileprivate\(set\))\s+)*)"
    r"(?P<kind>func|init|var|let|subscript|typealias|associatedtype|case)\b(?P<rest>.*)$")
EXPLICIT_ACCESS = re.compile(r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:\w+\s+)*?(public|open|internal|fileprivate|private|package)\b")


def public_api(text):
    """{chave: (linha, deprecated)} da API pública: declarações public/open,
    conformidades, requisitos de protocolo público, membros sem modificador
    de public extension e cases de public enum. Só membros diretos do tipo
    entram (nada declarado dentro de funções)."""
    code = clean(text)
    lines = code.split("\n")
    api, stack, depth = {}, [], 0
    pending_deprecated = False
    i = 0
    while i < len(lines):
        line = lines[i]
        line_depth = depth
        if re.search(r"@available\s*\(\s*\*\s*,\s*deprecated", line):
            pending_deprecated = True
        type_match = TYPE_DECL.match(line)
        owner = ".".join(name for name, _, _, _ in stack) or "<global>"
        direct = not stack or line_depth == stack[-1][2] + 1
        decl = DECL.match(line) if direct else None
        container = stack[-1] if stack else None
        implicit = None
        if direct and container and container[3] and not type_match and not decl:
            kind_c = container[1]
            member = MEMBER.match(line)
            if member and not EXPLICIT_ACCESS.match(line):
                if kind_c in ("protocol", "extension") and member.group("kind") != "case":
                    implicit = (member.group("kind"), member.group("rest"),
                                bool(re.search(r"\b(static|class)\b", member.group("mods"))))
                elif kind_c == "enum" and member.group("kind") == "case":
                    implicit = ("case", member.group("rest"), False)
        if decl or implicit:
            if decl:
                prefix = line[:decl.start("kind")]
                kind, rest, static = decl.group("kind"), decl.group("rest"), bool(re.search(r"\b(static|class)\s", prefix))
            else:
                kind, rest, static = implicit
            j = i
            while rest.count("(") > rest.count(")") and j + 1 < len(lines):
                j += 1
                rest += " " + lines[j]
            if kind == "case":
                for case in split_top(rest.split("{")[0]):
                    case = split_top(case, "=")[0]  # valor bruto não é parte da API de chamada
                    if case.strip():
                        api[f"{owner}.case {tidy(case)}"] = (i + 1, pending_deprecated)
            elif kind not in TYPE_KINDS:
                api[member_key(owner, kind, rest, static)] = (i + 1, pending_deprecated)
        if type_match and direct:
            name = type_match.group("name")
            kind = type_match.group("kind")
            if kind == "extension":
                is_public = bool(re.search(r"\b(public|open)\s+extension\b", line))
            else:
                is_public = bool(decl)
            if (is_public or kind == "extension") and type_match.group("inherits"):
                for conformance in type_match.group("inherits").split(","):
                    conformance = collapse(conformance)
                    if conformance:
                        api[f"conformidade {name}: {conformance}"] = (i + 1, False)
            if decl and kind != "extension":
                api[f"{owner}.{kind} {name}"] = (i + 1, pending_deprecated)
            # extensão adiciona membros ao tipo estendido, não a um tipo aninhado
            stack.append((name, kind, line_depth, is_public))
        elif type_match:
            stack.append((type_match.group("name"), type_match.group("kind"), line_depth, False))
        if line.strip() and not line.strip().startswith("@"):
            pending_deprecated = False
        for ch in line:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                while stack and stack[-1][2] >= depth:
                    stack.pop()
        i += 1
    return api


def is_library(read_head, tracked, policy):
    if "library" in policy:
        return bool(policy["library"])
    for path in tracked:
        if os.path.basename(path) == "Package.swift" and not is_fixture_path(path) \
                and ".library(" in (read_head(path) or ""):
            return True
    return False


TARGET_CALL = re.compile(r"\.(target|executableTarget|testTarget|macro|plugin)\s*\(")


def module_map(read_head, tracked):
    """[(prefixo de diretório, módulo)] dos targets declarados nos Package.swift.

    Só o que o manifesto declara: path: explícito ou o padrão do SwiftPM
    (Sources/<nome>, Tests/<nome> para testTarget). Diretório que nenhum
    target cobre fica sem módulo — nunca inventado."""
    prefixes = []
    for manifest in tracked:
        if os.path.basename(manifest) != "Package.swift" or is_fixture_path(manifest):
            continue
        raw = read_head(manifest) or ""
        code = clean(raw)
        root = os.path.dirname(manifest)
        for match in TARGET_CALL.finditer(code):
            open_index = match.end() - 1
            depth, end = 0, open_index
            for end in range(open_index, len(code)):
                depth += {"(": 1, ")": -1}.get(code[end], 0)
                if depth == 0:
                    break
            call = code[open_index:end]
            name = re.search(r"\bname\s*:\s*\"", call)
            if not name:
                continue
            literal_start = open_index + name.end()
            literal_end = code.find('"', literal_start)
            target = raw[literal_start:literal_end]
            folder = "Tests" if match.group(1) == "testTarget" else "Sources"
            path = f"{folder}/{target}"
            custom = re.search(r"\bpath\s*:\s*\"", call)
            if custom:
                p_start = open_index + custom.end()
                path = raw[p_start:code.find('"', p_start)].strip("/")
            prefix = os.path.normpath(os.path.join(root, path)) if root else os.path.normpath(path)
            prefixes.append((prefix, f"{manifest}:{target}"))
    return sorted(prefixes, key=lambda item: -len(item[0]))


def module_for(path, prefixes):
    for prefix, module in prefixes:
        if path == prefix or path.startswith(prefix + "/"):
            return module
    return None


def check_public_api(audit, ctx, read_head, read_old):
    changed = [f for f in ctx.files if f["old_path"].endswith(".swift") and f["status"] in ("M", "R", "D")
               and not is_test_path(f["path"]) and not is_fixture_path(f["path"])]
    if not changed:
        audit.skipped("API pública: nenhum arquivo Swift existente foi modificado ou removido")
        return
    library = is_library(read_head, ctx.head_files, ctx.policy)
    prefixes = module_map(read_head, ctx.head_files)
    head_api = {}
    swift_head = [p for p in ctx.head_files if p.endswith(".swift") and not is_test_path(p) and not is_fixture_path(p)]
    for path in swift_head[:3000]:
        module = module_for(path, prefixes)
        for key, (line, deprecated) in public_api(read_head(path) or "").items():
            head_api.setdefault(key, []).append((path, line, deprecated, module))
    if len(swift_head) > 3000:
        audit.skipped("API pública: mais de 3000 arquivos Swift; declarações movidas além desse limite não são encontradas")
    severity = "BLOCKER" if library else "WARNING"
    for f in changed:
        old_api = public_api(read_old(f["old_path"]) or "")
        new_api = public_api(read_head(f["path"]) or "") if f["status"] != "D" else {}
        old_module = module_for(f["old_path"], prefixes)
        new_module = module_for(f["path"], prefixes)
        # arquivo renomeado só continua no mesmo módulo se ficou no mesmo diretório
        # ou se os dois caminhos caem no mesmo target declarado
        stays = os.path.dirname(f["old_path"]) == os.path.dirname(f["path"]) or \
            (old_module is not None and old_module == new_module)
        file_module = old_module if stays else new_module
        for key, (line, old_deprecated) in old_api.items():
            same_file = [(f["path"], new_api[key][0], new_api[key][1], file_module)] if key in new_api else []
            exact = same_file or head_api.get(key, [])
            candidates = list(exact)
            if not candidates and "(" in key:  # mesma chamada continua válida (ex.: só ganhou padrão)
                candidates = [entry for other, entries in head_api.items()
                              if other.split("(")[0] == key.split("(")[0] and compatible(key, other)
                              for entry in entries]
            local = [c for c in candidates if (c in same_file and stays) or (old_module and c[3] == old_module)]
            if local:
                path, new_line, deprecated, _ = local[0]
                if deprecated and not old_deprecated and local[0] in exact:
                    audit.add(Finding(
                        "SWIFT-API-DEPRECATED", "INFO", f"{key} mantida e marcada como deprecated em {path}:{new_line}",
                        "deprecated preserva a compilação, não o comportamento",
                        "confirmar que a API antiga delega para a nova e tem teste comparando as duas",
                        "heurística", "média", file=path, line=new_line))
                continue
            uncertain = bool(candidates) and (old_module is None or any(c[3] is None for c in candidates))
            if uncertain:
                where = ", ".join(sorted({c[0] for c in candidates}))
                audit.add(Finding(
                    "SWIFT-API-ORIGIN-UNKNOWN", "WARNING",
                    f"{key} saiu de {f['old_path']} e há declaração equivalente em {where}, "
                    "mas o módulo de origem não pôde ser determinado pelos Package.swift",
                    "se a declaração equivalente for de outro módulo, a API foi removida para os consumidores",
                    "confirmar que a declaração continua no mesmo módulo/target",
                    "heurística", "baixa", file=f["path"]))
                continue
            similar = [k for k in new_api if "(" in key and k.split("(")[0] == key.split("(")[0]
                       and k != key and k not in old_api]
            if key.startswith("conformidade "):
                what = "conformidade pública removida"
            elif similar:
                what = f"assinatura alterada (agora: {similar[0]})"
            else:
                what = "declaração pública removida"
            if candidates:  # só existe em outro módulo, conhecido
                others = ", ".join(sorted({c[3].split(":")[-1] for c in candidates}))
                what += f"; homônimo em outro módulo ({others}) não substitui"
            audit.add(Finding(
                "SWIFT-API-BREAK", severity, f"{what}: {key} (base, linha {line})",
                "quebra consumidores do módulo" if library else
                "quebra quem consome esta API fora do arquivo; o projeto não declara produto de biblioteca",
                "manter a API antiga (delegando para a nova) e marcar @available(*, deprecated, renamed:)",
                "determinística", "alta" if library else "média", file=f["path"], line=None))
        if f["status"] == "D":
            continue
        protocols = {k.split(".protocol ")[1] for k in new_api if ".protocol " in k}
        head_text = None
        for key, (line, _) in new_api.items():
            owner = key.split(".")[0]
            if key in old_api or owner not in protocols or key.startswith(owner + ".protocol"):
                continue
            name = re.match(r".*?\.(?:func|var|let|init|subscript) ([A-Za-z_]\w*)?", key)
            member = name.group(1) if name and name.group(1) else None
            if head_text is None:
                head_text = "\n".join(clean(read_head(p) or "") for p in swift_head[:3000])
            default = member and re.search(r"extension\s+" + re.escape(owner) + r"\b[^{]*\{[^}]*\b" + re.escape(member) + r"\b", head_text)
            if not default:
                audit.add(Finding(
                    "SWIFT-PROTOCOL-REQUIREMENT", "WARNING",
                    f"requisito novo em protocolo público {owner}: {key}",
                    "conformidades externas deixam de compilar sem implementação padrão",
                    "fornecer implementação padrão em extensão do protocolo ou criar protocolo novo",
                    "heurística", "média", file=f["path"], line=line))
    audit.checked("API pública: declarações public/open e conformidades da base comparadas com o HEAD "
                  + ("(produto de biblioteca)" if library else "(sem produto de biblioteca declarado)"))


# ---------------------------------------------------------------------
# Pipeline versionado duplicado
# ---------------------------------------------------------------------

CALL = re.compile(r"\.\s*([A-Za-z_]\w*)\s*(?=[({])")


def chain_ops(body):
    """Operadores encadeados; ignora chamadas em tipo (Endpoint.x) e membros implícitos em argumento."""
    ops = []
    for match in CALL.finditer(body):
        j = match.start() - 1
        while j >= 0 and body[j].isspace():
            j -= 1
        if j < 0:
            continue
        before = body[j]
        if before in ")}]":
            ops.append(match.group(1))
        elif before.isalnum() or before == "_":
            k = j
            while k >= 0 and (body[k].isalnum() or body[k] == "_"):
                k -= 1
            if body[k + 1].islower() or body[k + 1] == "_":
                ops.append(match.group(1))
    return ops


def cases_of(body):
    """[(rótulo, texto)] dos cases de primeiro nível de um bloco switch."""
    result, depth, label, start = [], 0, None, 0
    for match in re.finditer(r"[{}]|\b(case\b[^:\n]*|default)\s*:", body):
        token = match.group(0)
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
        elif depth == 0:
            if label is not None:
                result.append((label, body[start:match.start()]))
            label, start = collapse(match.group(1)), match.end()
    if label is not None:
        result.append((label, body[start:]))
    return result


def is_subsequence(short, long_):
    it = iter(long_)
    return all(op in it for op in short)


def check_versioned_pipeline(audit, ctx, read_head):
    found = 0
    for f in ctx.swift_files:
        if is_test_path(f["path"]):
            continue
        code = clean(read_head(f["path"]) or "")
        added = {n for n, _ in f["added"]}
        for match in re.finditer(r"\bswitch\s+([^{\n]*)\{", code):
            if not re.search(r"(?i)version", match.group(1)):
                continue
            open_index = match.end() - 1
            end = block_end(code, open_index)
            first, last = line_of(code, match.start()), line_of(code, end)
            if not any(first <= n <= last for n in added):
                continue
            chains = [(label, chain_ops(body)) for label, body in cases_of(code[open_index + 1:end - 1])]
            chains = [(label, ops) for label, ops in chains if len(ops) >= 3]
            for i in range(len(chains)):
                for j in range(i + 1, len(chains)):
                    (la, a_ops), (lb, b_ops) = chains[i], chains[j]
                    if a_ops == b_ops:
                        detail, confidence = f"diferindo só nos argumentos", "média"
                    else:
                        short, long_, ls, ll = (a_ops, b_ops, la, lb) if len(a_ops) <= len(b_ops) else (b_ops, a_ops, lb, la)
                        if len(short) < 4 or not is_subsequence(short, long_):
                            continue  # troca ou remoção de operador: diferença real de transporte/erro
                        extra = list(long_)
                        for op in short:
                            extra.remove(op)
                        detail, confidence = f"{ll} só acrescenta {', '.join(extra)}", "baixa"
                    found += 1
                    ctx.covered.append((f["path"], first, last))
                    audit.add(Finding(
                        "SWIFT-PIPELINE-DUPLICATED", "WARNING",
                        f"{la} e {lb} repetem a cadeia {' → '.join(a_ops if len(a_ops) <= len(b_ops) else b_ops)}; {detail}",
                        "cada versão mantém sua própria cópia do pipeline de rede; correções divergem",
                        "um pipeline só: parametrizar o operador que muda (ex.: .op(version == .v2)) e levar a "
                        "diferença de resposta para um .map { switch version { … } }; manter separado se o "
                        "transporte ou o tratamento de erro diferirem de fato",
                        "heurística", confidence, file=f["path"], line=first))
    audit.checked("pipeline versionado: cases de switch sobre versão com cadeias de operadores idênticas")


# ---------------------------------------------------------------------
# Contrato de payload (CodingKeys)
# ---------------------------------------------------------------------

def coding_keys(text):
    code = clean(text)
    raw_text = text
    keys = {}
    for type_match in re.finditer(r"\b(struct|class|enum)\s+([A-Za-z_]\w*)[^{]*\{", code):
        open_index = type_match.end() - 1
        end = block_end(code, open_index)
        inner = code[open_index:end]
        ck = re.search(r"\benum\s+CodingKeys\b[^{]*\{", inner)
        if not ck:
            continue
        ck_open = open_index + ck.end() - 1
        ck_end = block_end(code, ck_open)
        if ck_end > end:
            continue
        body_raw = raw_text[ck_open:ck_end]
        values = {}
        for case in re.finditer(r"\bcase\s+([^\n}]+)", clean(body_raw)):
            start = ck_open + case.start(1)
            segment = raw_text[start:ck_open + case.end(1)]
            for part in segment.split(","):
                name_raw = re.match(r"\s*`?([A-Za-z_]\w*)`?\s*(?:=\s*\"([^\"]*)\")?", part)
                if name_raw:
                    values[name_raw.group(1)] = name_raw.group(2) or name_raw.group(1)
        keys.setdefault(type_match.group(2), values)
    return keys


def type_body(code, name):
    match = re.search(r"\b(?:struct|class|enum|actor)\s+" + re.escape(name) + r"\b[^{]*\{", code)
    return code[match.end() - 1:block_end(code, match.end() - 1)] if match else None


def check_coding_keys(audit, ctx, read_head, read_old):
    for f in ctx.swift_files:
        if f["status"] not in ("M", "R") or is_test_path(f["path"]):
            continue
        old = coding_keys(read_old(f["old_path"]) or "")
        new_text = read_head(f["path"]) or ""
        new = coding_keys(new_text)
        new_code = clean(new_text)
        for type_name, old_keys in old.items():
            if type_name in new:
                new_values = set(new[type_name].values())
                removed = sorted(v for v in set(old_keys.values()) if v not in new_values)
                if removed:
                    audit.add(Finding(
                        "SWIFT-CONTRACT-KEYS", "WARNING",
                        f"{type_name}.CodingKeys deixou de mapear {', '.join(repr(r) for r in removed)}",
                        "payload legado muda: o campo some do encode ou deixa de ser lido no decode",
                        "confirmar no contrato do backend; se a versão antiga continua ativa, versionar em vez de trocar",
                        "determinística", "alta", file=f["path"]))
                continue
            body = type_body(new_code, type_name)
            if body is None:
                continue  # o tipo saiu: a comparação de API pública trata a remoção
            if re.search(r"\binit\s*\(\s*from\s+\w+\s*:\s*Decoder|\bfunc\s+encode\s*\(\s*to\s+\w+\s*:\s*Encoder", body):
                audit.add(Finding(
                    "SWIFT-CONTRACT-KEYS", "INFO",
                    f"{type_name}.CodingKeys removida; o tipo implementa encode/decode explicitamente",
                    "o contrato depende das chaves usadas nessa implementação",
                    "confirmar que as chaves antigas continuam sendo lidas e escritas",
                    "heurística", "média", file=f["path"]))
                continue
            renamed = sorted((name, raw) for name, raw in old_keys.items() if raw != name)
            if renamed:
                audit.add(Finding(
                    "SWIFT-CONTRACT-KEYS", "WARNING",
                    f"{type_name}.CodingKeys removida: " + ", ".join(f"'{raw}' passa a ser '{name}'" for name, raw in renamed),
                    "com Codable sintetizado o payload muda, salvo keyDecodingStrategy/keyEncodingStrategy "
                    "configurada para produzir as chaves antigas",
                    "manter o mapeamento ou confirmar a estratégia de chaves do encoder/decoder e o contrato",
                    "heurística", "média", file=f["path"]))
    audit.checked("contrato: CodingKeys de tipos existentes comparadas com a base, inclusive remoção da enum")


# ---------------------------------------------------------------------
# Regressão funcional e higiene
# ---------------------------------------------------------------------

def enclosing_function(code, offset):
    names = [m for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)", code[:offset])]
    return names[-1].group(1) if names else None


def check_mutation_fallback(audit, ctx, read_head):
    for f in ctx.swift_files:
        if is_test_path(f["path"]):
            continue
        code = clean(read_head(f["path"]) or "")
        added = {n for n, _ in f["added"]}
        for match in re.finditer(r"(\bcatch\b[^{\n]*|\.catch\s*|case\s+\.failure[^:\n]*:)\s*\{?", code):
            start = match.end()
            if code[match.end() - 1] == "{":
                end = block_end(code, match.end() - 1)
            else:
                end = code.find("\n\n", start)
                end = len(code) if end < 0 else end
            body = code[start:end]
            legacy = re.search(r"\b([A-Za-z_]\w*(?:[Vv]1|[Ll]egacy)\w*)\s*\(|\.\s*v1\b", body)
            if not legacy:
                continue
            line = line_of(code, start + legacy.start())
            if line not in added:
                continue
            function = enclosing_function(code, match.start()) or ""
            if not MUTATION.match(function):
                continue
            audit.add(Finding(
                "SWIFT-MUTATION-FALLBACK", "WARNING",
                f"{function}: no caminho de erro chama {legacy.group(0).strip()} (versão anterior)",
                "repetir uma mutação por outro caminho pode duplicar o efeito se a primeira chegou ao servidor",
                "tratar o erro sem reenviar a mutação; fallback só com garantia de que nada foi aplicado",
                "heurística", "baixa", file=f["path"], line=line))
    audit.checked("regressão: chamadas a versão anterior dentro de caminho de erro de funções de mutação")


def check_hygiene(audit, ctx):
    for f in ctx.swift_files:
        test = is_test_path(f["path"])
        for line_no, text in f["added"]:
            code = clean(text)
            if re.search(r"@unchecked\s+Sendable|nonisolated\s*\(\s*unsafe\s*\)", code):
                audit.add(Finding(
                    "SWIFT-CONCURRENCY-UNSAFE", "WARNING",
                    f"isolamento desligado manualmente: {collapse(code)[:80]}",
                    "o compilador deixa de verificar acesso concorrente a este estado",
                    "provar a sincronização (lock, actor, imutabilidade) num comentário de contrato ou remover",
                    "determinística", "alta", file=f["path"], line=line_no))
            if not test and re.search(r"@available\s*\(\s*\*\s*,\s*deprecated\s*\)", code):
                audit.add(Finding(
                    "SWIFT-DEPRECATED-NO-MESSAGE", "INFO", "@available(*, deprecated) sem message: nem renamed:",
                    "quem usa não sabe o substituto nem quando remover",
                    "informar renamed:/message: com o substituto", "determinística", "alta",
                    file=f["path"], line=line_no))
        if test and f["status"] != "D":
            head = ctx.read_head(f["path"]) or ""
            if re.search(r"^\s*import\s+XCTest\b", head, re.M) and re.search(r"^\s*import\s+Testing\b", head, re.M):
                audit.add(Finding(
                    "SWIFT-TEST-FRAMEWORK-MIX", "WARNING", "arquivo de teste importa XCTest e Testing",
                    "dois frameworks no mesmo arquivo dificultam leitura e manutenção",
                    "usar o framework predominante do módulo no arquivo inteiro",
                    "determinística", "alta", file=f["path"]))
    audit.checked("higiene Swift: @unchecked Sendable, nonisolated(unsafe), deprecated sem mensagem, XCTest + Testing no mesmo arquivo")


def run(audit, ctx):
    swift_changed = [f for f in ctx.files if (f["path"].endswith(".swift") or f["old_path"].endswith(".swift"))
                     and not is_fixture_path(f["path"])]
    if not swift_changed:
        audit.skipped("camada Swift: nenhum arquivo .swift alterado")
        return
    check_public_api(audit, ctx, ctx.read_head, ctx.read_old)  # inclui arquivos excluídos
    if not ctx.swift_files:
        audit.skipped("camada Swift: só exclusões; demais verificações dependem de arquivos existentes")
        return
    check_versioned_pipeline(audit, ctx, ctx.read_head)
    check_availability(audit, ctx, ctx.read_head)
    check_coding_keys(audit, ctx, ctx.read_head, ctx.read_old)
    check_mutation_fallback(audit, ctx, ctx.read_head)
    check_hygiene(audit, ctx)
    audit.skipped("Swift: análise sem compilador; tipos, sobrecargas e macros não são resolvidos")

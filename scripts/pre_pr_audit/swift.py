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
AVAILABILITY = [
    (r"\bTask\s*\.\s*sleep\s*\(\s*for\s*:", "Task.sleep(for:)", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\bTask\s*\.\s*sleep\s*\(\s*until\s*:", "Task.sleep(until:)", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\b(ContinuousClock|SuspendingClock)\b", "ContinuousClock/SuspendingClock", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\bNavigationStack\b", "NavigationStack", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\bNavigationSplitView\b", "NavigationSplitView", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\bImageRenderer\b", "ImageRenderer", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\.toolbar\s*\(\s*\.hidden", "toolbar(.hidden)", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "alta"),
    (r"\bRegex\s*<", "Regex<…>", {"ios": 16, "macos": 13, "tvos": 16, "watchos": 9}, "média"),
    (r"\bContentUnavailableView\b", "ContentUnavailableView", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta"),
    (r"@Observable\b", "@Observable", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta"),
    (r"@Bindable\b", "@Bindable", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta"),
    (r"\.scrollTargetBehavior\s*\(", "scrollTargetBehavior(_:)", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta"),
    (r"\.containerRelativeFrame\s*\(", "containerRelativeFrame(_:)", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta"),
    (r"\.sensoryFeedback\s*\(", "sensoryFeedback(_:trigger:)", {"ios": 17, "macos": 14, "watchos": 10}, "alta"),
    (r"\.onChange\s*\(\s*of\s*:[^)\n]*\binitial\s*:", "onChange(of:initial:_:)", {"ios": 17, "macos": 14, "tvos": 17, "watchos": 10}, "alta"),
    (r"\bAsyncImage\b", "AsyncImage", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "alta"),
    (r"\.refreshable\s*\{", "refreshable(action:)", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "alta"),
    (r"\bURLSession\b[^\n]*\.data\s*\(\s*(from|for)\s*:", "URLSession.data(from:/for:) async", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "alta"),
    (r"\.formatted\s*\(", "formatted(_:)", {"ios": 15, "macos": 12, "tvos": 15, "watchos": 8}, "média"),
]
AVAILABILITY = [(re.compile(p), s, v, c) for p, s, v, c in AVAILABILITY]

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
    parts = re.findall(r"\d+", text)
    return float(f"{parts[0]}.{parts[1]}") if len(parts) > 1 else float(parts[0])


def deployment_targets(read_head, tracked, policy):
    """{plataforma: versão mínima} e a origem de cada valor."""
    targets, origin = {}, {}
    for key, value in (policy.get("min_platforms") or {}).items():
        targets[key.lower()] = parse_version(str(value)); origin[key.lower()] = "política"
    manifests = [p for p in tracked if os.path.basename(p) == "Package.swift"]
    for path in manifests:
        text = clean(read_head(path) or "")
        for name, key in PLATFORMS.items():
            for match in re.finditer(r"\." + name + r"\s*\(\s*(?:\.v(\d+(?:_\d+)?)|\"([\d.]+)\")\s*\)", text):
                version = parse_version((match.group(1) or match.group(2)).replace("_", "."))
                if key not in origin or origin[key] != "política":
                    if key not in targets or version < targets[key]:
                        targets[key], origin[key] = version, path
    for path in tracked:
        if path.endswith("project.pbxproj"):
            text = read_head(path) or ""
            for setting, key in (("IPHONEOS", "ios"), ("MACOSX", "macos"), ("TVOS", "tvos"), ("WATCHOS", "watchos")):
                for match in re.finditer(setting + r"_DEPLOYMENT_TARGET = ([\d.]+);", text):
                    version = parse_version(match.group(1))
                    if origin.get(key) != "política" and (key not in targets or version < targets[key]):
                        targets[key], origin[key] = version, path
    return targets, origin


def guarded_regions(code):
    """[(início, fim, {plataforma: versão})] cobertos por #available/@available."""
    regions = []
    for match in re.finditer(r"\bif\s+#available\s*\(([^)]*)\)", code):
        brace = code.find("{", match.end())
        if brace >= 0:
            regions.append((brace, block_end(code, brace), availability_spec(match.group(1))))
    for match in re.finditer(r"\bguard\s+#available\s*\(([^)]*)\)[^{]*\{", code):
        else_end = block_end(code, match.end() - 1)
        depth, j = 0, else_end
        while j < len(code):
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                if depth == 0:
                    break
                depth -= 1
            j += 1
        regions.append((else_end, j, availability_spec(match.group(1))))
    for match in re.finditer(r"@available\s*\(([^)]*)\)", code):
        spec = availability_spec(match.group(1))
        if not spec:
            continue
        brace = code.find("{", match.end())
        if brace >= 0:
            regions.append((match.start(), block_end(code, brace), spec))
    return regions


def availability_spec(text):
    spec = {}
    for name, key in PLATFORMS.items():
        match = re.search(r"\b" + name + r"\s+([\d.]+)", text)
        if match:
            spec[key] = parse_version(match.group(1))
    return spec


def check_availability(audit, ctx, read_head):
    targets, origin = deployment_targets(read_head, ctx.head_files, ctx.policy)
    if not targets:
        audit.skipped("disponibilidade de API: deployment target não encontrado (Package.swift, project.pbxproj ou min_platforms)")
        return
    shown = ", ".join(f"{k} {v:g} ({origin[k]})" for k, v in sorted(targets.items()))
    for f in ctx.swift_files:
        text = read_head(f["path"]) or ""
        code = clean(text)
        regions = guarded_regions(code)
        added = {n for n, _ in f["added"]}
        starts = [0] + [m.end() for m in re.finditer("\n", code)]
        for pattern, symbol, needs, confidence in AVAILABILITY:
            for match in pattern.finditer(code):
                line = line_of(code, match.start())
                if line not in added:
                    continue
                failing = []
                for platform, minimum in targets.items():
                    required = needs.get(platform)
                    if required is None or minimum >= required:
                        continue
                    covered = any(lo <= match.start() < hi and spec.get(platform, 0) >= required
                                  for lo, hi, spec in regions)
                    if not covered:
                        failing.append(f"{platform} {required:g}+ (alvo {minimum:g})")
                if failing:
                    severity = "BLOCKER" if confidence == "alta" else "WARNING"
                    audit.add(Finding(
                        "SWIFT-AVAILABILITY", severity,
                        f"{symbol} exige {', '.join(failing)} e não está protegido por #available/@available",
                        "não compila (ou não roda) na plataforma mínima declarada",
                        "usar API equivalente disponível no alvo ou proteger com if #available",
                        "determinística" if confidence == "alta" else "heurística", confidence,
                        file=f["path"], line=line))
    audit.checked(f"disponibilidade de API nas linhas adicionadas contra {shown} (tabela curada, não exaustiva)")


# ---------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------

def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


def signature(kind, rest):
    rest = rest.split("{")[0]
    if kind in ("var", "let"):
        rest = re.split(r"=", rest)[0]
    rest = re.sub(r"=\s*[^,)]+", "", rest)  # valores padrão não mudam a assinatura do chamador
    sig = collapse(rest).rstrip(":").rstrip()
    # forma canônica: quebra de linha e espaço junto de pontuação não mudam a assinatura
    sig = re.sub(r"\s*([(),:<>\[\]?!])\s*", r"\1", sig)
    sig = re.sub(r"\s*->\s*", "->", sig).replace(",)", ")")
    return sig if sig.startswith(("(", "<")) else " " + sig


def member_key(owner, kind, rest):
    return f"{owner}.{kind}{signature(kind, rest)}"


def public_api(text):
    """{chave: (linha, deprecated)} de declarações public/open e conformidades."""
    code = clean(text)
    lines = code.split("\n")
    api, stack, depth = {}, [], 0
    pending_deprecated = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.search(r"@available\s*\(\s*\*\s*,\s*deprecated", line):
            pending_deprecated = True
        type_match = TYPE_DECL.match(line)
        owner = ".".join(name for name, _, _, _ in stack) or "<global>"
        decl = DECL.match(line)
        in_public_protocol = bool(stack) and stack[-1][1] == "protocol" and stack[-1][3]
        member = PROTOCOL_MEMBER.match(line) if in_public_protocol and not type_match else None
        if member:
            rest = member.group("rest")
            api[member_key(owner, member.group("kind"), rest)] = (i + 1, pending_deprecated)
        elif decl:
            kind = decl.group("kind")
            rest = decl.group("rest")
            j = i
            while rest.count("(") > rest.count(")") and j + 1 < len(lines):
                j += 1
                rest += " " + lines[j]
            if kind == "case":
                for name in re.split(r",", rest.split("{")[0]):
                    key = f"{owner}.case {collapse(name)}"
                    api[key] = (i + 1, pending_deprecated)
            elif kind not in TYPE_KINDS:
                api[member_key(owner, kind, rest)] = (i + 1, pending_deprecated)
        if type_match:
            name = type_match.group("name")
            kind = type_match.group("kind")
            public_type = bool(decl) or kind == "extension"
            if public_type and type_match.group("inherits"):
                for conformance in type_match.group("inherits").split(","):
                    conformance = collapse(conformance)
                    if conformance:
                        api[f"conformidade {name}: {conformance}"] = (i + 1, False)
            if decl and kind != "extension":
                api[f"{owner}.{kind} {name}"] = (i + 1, pending_deprecated)
            stack.append((name, kind, depth, bool(decl)))
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
        if os.path.basename(path) == "Package.swift" and ".library(" in (read_head(path) or ""):
            return True
    return False


def check_public_api(audit, ctx, read_head, read_old):
    changed = [f for f in ctx.files if f["old_path"].endswith(".swift") and f["status"] in ("M", "R", "D")
               and not is_test_path(f["path"]) and not is_fixture_path(f["path"])]
    if not changed:
        audit.skipped("API pública: nenhum arquivo Swift existente foi modificado ou removido")
        return
    library = is_library(read_head, ctx.head_files, ctx.policy)
    head_api = {}
    swift_head = [p for p in ctx.head_files if p.endswith(".swift") and not is_test_path(p) and not is_fixture_path(p)]
    for path in swift_head[:3000]:
        for key, value in public_api(read_head(path) or "").items():
            head_api.setdefault(key, (path,) + value)
    if len(swift_head) > 3000:
        audit.skipped("API pública: mais de 3000 arquivos Swift; declarações movidas além desse limite não são encontradas")
    severity = "BLOCKER" if library else "WARNING"
    for f in changed:
        old_api = public_api(read_old(f["old_path"]) or "")
        new_api = public_api(read_head(f["path"]) or "") if f["status"] != "D" else {}
        for key, (line, _) in old_api.items():
            if key in head_api:
                path, new_line, deprecated = head_api[key]
                if deprecated and not old_api[key][1]:
                    audit.add(Finding(
                        "SWIFT-API-DEPRECATED", "INFO", f"{key} mantida e marcada como deprecated em {path}:{new_line}",
                        "deprecated preserva a compilação, não o comportamento",
                        "confirmar que a API antiga delega para a nova e tem teste comparando as duas",
                        "heurística", "média", file=path, line=new_line))
                continue
            similar = [k for k in new_api if "(" in key and k.split("(")[0] == key.split("(")[0]
                       and k != key and k not in old_api]
            if key.startswith("conformidade "):
                what = "conformidade pública removida"
            elif similar:
                what = f"assinatura alterada (agora: {similar[0]})"
            else:
                what = "declaração pública removida"
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


def check_coding_keys(audit, ctx, read_head, read_old):
    for f in ctx.swift_files:
        if f["status"] not in ("M", "R") or is_test_path(f["path"]):
            continue
        old = coding_keys(read_old(f["old_path"]) or "")
        new = coding_keys(read_head(f["path"]) or "")
        for type_name, old_keys in old.items():
            if type_name not in new:
                continue
            new_values = set(new[type_name].values())
            removed = sorted(v for v in set(old_keys.values()) if v not in new_values)
            if removed:
                audit.add(Finding(
                    "SWIFT-CONTRACT-KEYS", "WARNING",
                    f"{type_name}.CodingKeys deixou de mapear {', '.join(repr(r) for r in removed)}",
                    "payload legado muda: o campo some do encode ou deixa de ser lido no decode",
                    "confirmar no contrato do backend; se a versão antiga continua ativa, versionar em vez de trocar",
                    "determinística", "alta", file=f["path"]))
    audit.checked("contrato: chaves de CodingKeys de tipos existentes comparadas com a base")


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
                    f"isolamento desligado manualmente: {collapse(text)[:80]}",
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
    if not ctx.swift_files:
        audit.skipped("camada Swift: nenhum arquivo .swift alterado")
        return
    check_versioned_pipeline(audit, ctx, ctx.read_head)
    check_availability(audit, ctx, ctx.read_head)
    check_public_api(audit, ctx, ctx.read_head, ctx.read_old)
    check_coding_keys(audit, ctx, ctx.read_head, ctx.read_old)
    check_mutation_fallback(audit, ctx, ctx.read_head)
    check_hygiene(audit, ctx)
    audit.skipped("Swift: análise sem compilador; tipos, sobrecargas e macros não são resolvidos")

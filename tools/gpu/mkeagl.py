#!/usr/bin/env python3
"""Generate eagl_gen.h, the function table behind eagl.c's EAGLContext.

CoreAnimation's GL renderer does not call OpenGL ES by name: it calls entries of a table iOS's
own GLES hands it through -[EAGLContext getMacroContextPrivate], each entry at a fixed byte
offset, every call passing the "macro context" as the first argument. eagl.c stands in for that
table: table[0] is its own state, table[offset / 8] is a function that takes the state as its
first argument and forwards the rest to Mesa -- or, for the entries eagl.c writes itself, does
some work first.

This generator turns two inputs into the header eagl.c includes twice:

  eagl_slots.txt        OFFSET NAME [hand [MACRO]]  -- which entry is which function
  the GL headers        the prototypes (iPhoneOS SDK: OpenGLES.framework/Headers)

and emits

  #define EAGL_GEN_DECLARATIONS   extern prototypes for the gl* functions eagl.c calls, so that
                                  eagl.c needs no OpenGL ES header of its own
  #define EAGL_GEN_TABLE          one forwarder per entry, one "not there" stub per unlisted
                                  offset, eagl_slot_name(), eagl_fill_table(), EAGL_TABLE_SIZE

The whole table is filled, not only the listed entries: an offset nothing is known about gets a
stub that logs the offset once (eagl_missing(), which eagl.c has for exactly this) and returns 0.
That is not a working GLES -- it is how the missing part of eagl_slots.txt is discovered on the
device, one boot at a time.

The five names eagl.c expects are the contract: EAGL_GEN_DECLARATIONS, EAGL_GEN_TABLE,
eagl_fill_table(), eagl_slot_name() and EAGL_TABLE_SIZE. They are what the reference port's eagl.c
uses, so that file compiles against this header with nothing changed but the names of the port and
the offsets themselves -- no adaptation was needed, which is also the check that the contract was
read correctly.

    tools/gpu/mkeagl.py                          # eagl_slots.txt -> eagl_gen.h
    tools/gpu/mkeagl.py -o /tmp/eagl_gen.h
    tools/gpu/mkeagl.py --from-log boot.log --write-slots eagl_slots.txt
    tools/gpu/mkeagl.py --check                  # report entries with no prototype

The log form is what mondrian_inject.c prints with glslots=1:

    mondrian-gl: slot 0x0030 glBindTexture
    mondrian-gl: slot 0x0f40 (not named)
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SLOTS = os.path.join(HERE, "eagl_slots.txt")
DEFAULT_OFFSETS = os.path.join(HERE, "mondrian_offsets.h")
DEFAULT_OUTPUT = os.path.join(HERE, "eagl_gen.h")

# Prototypes the table is meant to have. The order files are read in decides which declaration
# wins when the ES2 and ES3 headers disagree; the SDK's are the same for the shared functions.
HEADER_FILES = ("ES3/gl.h", "ES3/glext.h", "ES2/gl.h", "ES2/glext.h")

# Tokens the SDK puts around a prototype; none of them is part of the type.
CALL_MACROS = re.compile(r"\b(GL_APIENTRY|GL_APICALL|GL_APIENTRYP|GL_API|APIENTRY|APIENTRYP|GLAPIENTRY)\b")

# Words that end a parameter list without naming the parameter.
TYPE_WORDS = {
    "void", "const", "volatile", "restrict", "struct", "union", "enum", "unsigned", "signed",
    "char", "short", "int", "long", "float", "double", "size_t", "intptr_t", "uintptr_t",
    "GLvoid", "GLbyte", "GLshort", "GLint", "GLubyte", "GLushort", "GLuint", "GLfloat",
    "GLclampf", "GLdouble", "GLclampd", "GLenum", "GLboolean", "GLbitfield", "GLsizei",
    "GLfixed", "GLclampx", "GLchar", "GLintptr", "GLsizeiptr", "GLint64", "GLuint64", "GLsync",
    "GLhalf", "GLeglImageOES", "GLDEBUGPROC", "GLDEBUGPROCKHR",
}


# The entries of the table Apple's own headers do not declare (private to its GLES, or a name it
# exports without a header). The parameter lists are the ones eagl.c calls them with.
PRIVATE_PROTOTYPES = {
    "glFinishObjectAPPLE": ("void", [("GLenum", "object"), ("GLint", "name")]),
    "glFramebufferParameteriAPPLE": ("void", [("GLenum", "target"), ("GLenum", "pname"), ("GLint", "param")]),
    "glGetTexLevelParameteriv": ("void", [("GLenum", "target"), ("GLint", "level"), ("GLenum", "pname"),
                                          ("GLint *", "params")]),
}


def note(message):
    print(message, file=sys.stderr)


# ---- the two inputs -------------------------------------------------------------------------

def read_macros(path):
    """{NAME: int} of the #defines in mondrian_offsets.h that have a number."""
    macros = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"#define\s+(\w+)\s+(0x[0-9a-fA-F]+|\d+)\s*(?:/\*.*)?$", line.strip())
            if m:
                macros[m.group(1)] = int(m.group(2), 0)
    return macros


def read_slots(path, macros):
    """[(offset, name, hand)] sorted by offset; checks the hand entries against the header."""
    slots, seen, problems = [], {}, []
    with open(path) as f:
        for number, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            offset = None
            try:
                offset = int(parts[0], 0)
            except ValueError:
                offset = macros.get(parts[0])
                if offset is None:
                    problems.append(f"{path}:{number}: no offset {parts[0]}")
                    continue
            if len(parts) < 2 or not re.fullmatch(r"\w+", parts[1]):
                problems.append(f"{path}:{number}: expected OFFSET NAME [hand [MACRO]]")
                continue
            name, hand = parts[1], len(parts) > 2 and parts[2] == "hand"
            if offset % 8 or offset == 0:
                problems.append(f"{path}:{number}: {offset:#x} is not an entry (a multiple of 8, not 0)")
                continue
            if offset in seen:
                problems.append(f"{path}:{number}: {offset:#x} is {seen[offset]} already")
                continue
            if hand:
                if len(parts) < 4:
                    problems.append(f"{path}:{number}: {name} is hand-written but names no mondrian_offsets.h macro")
                    continue
                if parts[3] not in macros:
                    problems.append(f"{path}:{number}: {parts[3]} is not in mondrian_offsets.h")
                    continue
                if macros[parts[3]] != offset:
                    problems.append(f"{path}:{number}: {name} is at {offset:#x}, {parts[3]} is "
                                    f"{macros[parts[3]]:#x}")
                    continue
            seen[offset] = name
            slots.append((offset, name, hand))
    if problems:
        for problem in problems:
            note(problem)
        sys.exit("the slot list and mondrian_offsets.h do not agree")
    return sorted(slots)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def read_prototypes(directory):
    """{name: (return type, [parameter text])} from the SDK's gl.h/glext.h files."""
    found, conflicts = {}, []
    for relative in HEADER_FILES:
        path = os.path.join(directory, relative)
        if not os.path.isfile(path):
            continue
        text = strip_comments(open(path).read())
        lines = [line for line in text.splitlines()
                 if not line.lstrip().startswith("#") and line.strip() not in ("}", "extern \"C\" {")]
        text = " ".join(" ".join(lines).split())
        for statement in text.split(";"):
            statement = CALL_MACROS.sub(" ", statement).strip()
            declared = re.search(r"\b(gl[A-Za-z0-9_]+)\s*\(", statement)
            if not declared:
                continue
            name, at = declared.group(1), declared.end()
            depth, end = 1, at
            while end < len(statement) and depth:
                depth += {"(": 1, ")": -1}.get(statement[end], 0)
                end += 1
            if depth:
                continue                                    # unbalanced: not a prototype
            ret = " ".join(statement[:declared.start()].split()) or "void"
            args = statement[at:end - 1].strip()
            params = [] if args in ("", "void") else split_parameters(args)
            if not params and args not in ("", "void"):
                conflicts.append(f"{relative}: {name}: cannot read the parameters ({args})")
                continue
            if name in found and found[name] != (ret, params):
                # ES2 and ES3 redeclare the same function; a real difference is not ours to pick.
                if [p[0] for p in found[name][1]] != [p[0] for p in params]:
                    conflicts.append(f"{relative}: {name}: two different declarations")
                continue
            found[name] = (ret, params)
    found.update(PRIVATE_PROTOTYPES)
    for conflict in conflicts:
        note(f"warning: {conflict}")
    return found


def split_parameters(args):
    """[parameter] at top-level commas (a function pointer argument hides commas in parens)."""
    parts, depth, current = [], 0, ""
    for char in args:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    parts.append(current)
    parameters = []
    for part in parts:
        parameter = split_type_name(part.strip())
        if parameter is None:
            return []
        parameters.append(parameter)
    return parameters


def split_type_name(parameter):
    """(type, name or None) of one parameter, None when it cannot be read (a function pointer)."""
    if "(" in parameter:                        # void (*callback)(GLenum, ...)
        return None
    array = re.match(r"^(?P<type>.+?)\s*(?P<name>[A-Za-z_]\w*)\s*\[\s*\w*\s*\]$", parameter)
    if array:                                   # const GLchar string[] -> const GLchar *string
        return (array.group("type").strip() + " *", array.group("name"))
    if parameter.rstrip().endswith("*"):        # const GLchar * : no name
        return (parameter, None)
    named = re.fullmatch(r"(?P<type>.*?)(?P<name>[A-Za-z_]\w*)", parameter)
    if named and named.group("name") not in TYPE_WORDS and named.group("type").strip():
        return (named.group("type").strip(), named.group("name"))
    return (parameter, None)


# ---- the device's own table -----------------------------------------------------------------

def slots_from_log(path):
    """[(offset, name)] from the lines mondrian_inject.c prints with glslots=1."""
    slots = []
    with open(path) as f:
        for line in f:
            m = re.search(r"slot (0x[0-9a-fA-F]+) (\w+|\(not named\))", line)
            if m:
                name = m.group(2)
                slots.append((int(m.group(1), 16), None if name.startswith("(") else name))
    return slots


def write_slots(path, slots, hand):
    """Rewrite the slot file from a dump, keeping the hand flags and the file's own comment."""
    entries = {offset: value for offset, value in hand.items() if isinstance(value, tuple)}
    header = []
    if os.path.isfile(path):
        for line in open(path):
            if line.lstrip().startswith("#") or not line.strip():
                header.append(line.rstrip("\n"))
            else:
                break
    while header and not header[-1].strip():
        header.pop()
    lines = header or ["# The table of -[EAGLContext getMacroContextPrivate], written by mkeagl.py.",
                       "# OFFSET  NAME  [hand [MACRO]]"]
    lines += ["", f"# {len(slots)} entries, dumped from the build itself on the device."]
    for offset, name in slots:
        if name is None:
            continue
        if offset in entries:
            macro = entries[offset][1]
            lines.append(f"{offset:#06x}  {name:<38} hand  {macro}")
        else:
            lines.append(f"{offset:#06x}  {name}")
    open(path, "w").write("\n".join(lines) + "\n")
    note(f"{len(slots)} entries read; {sum(1 for offset, name in slots if name and offset in entries)} "
         f"of them are hand-written entries kept from the old file")


# ---- the header -----------------------------------------------------------------------------

def types_known(ret, params):
    """True when every type in a prototype is one eagl.c's own typedefs cover."""
    for text in [ret] + [p[0] for p in params]:
        for word in re.findall(r"[A-Za-z_]\w*", text):
            if word not in TYPE_WORDS:
                return False
    return True


def emit_declarations(slots, prototypes):
    """Every prototype the headers give, so that eagl.c needs no OpenGL ES header of its own.

    The slot list only says which functions the table has; eagl.c calls about forty more of them
    while it works (glEnable, glViewport, glTexParameteri, ...) and those are declared here too.
    A prototype that mentions a type eagl.c does not typedef (an ARB or vendor extension) is
    left out; nothing here calls one.
    """
    out = ["", "/* ---- the gl functions behind the table (EAGL_GEN_DECLARATIONS) ---- */", ""]
    for name in sorted(prototypes):
        ret, params = prototypes[name]
        if not types_known(ret, params):
            continue
        arguments = ", ".join(p[0] for p in params) or "void"
        out.append(f"extern {ret} {name}({arguments});")
    return out


def emit_stub(offset, name, prototype):
    """A forwarder: enter, call, leave, hand back what the call gave (if anything)."""
    ret, params = prototype
    arguments, names = [], []
    for index, (kind, identifier) in enumerate(params):
        name_here = identifier or f"a{index + 1}"
        arguments.append(f"{kind} {name_here}")
        names.append(name_here)
    call = f"{name}({', '.join(names)})"
    lines = [
        "static " + ret,
        f"eagl_slot_{offset:#06x}(void *context{''.join(', ' + a for a in arguments)})",
        "{",
        "\tstruct eagl *e = context;",
    ]
    if ret != "void":
        lines.append(f"\t{ret} value;")
    lines.append("")
    lines.append(f"\tEAGL_ENTER(e, {offset:#06x});")
    lines.append(f"\t{'value = ' if ret != 'void' else ''}{call};")
    lines.append(f"\tEAGL_LEAVE(e, {offset:#06x});")
    if ret != "void":
        lines.append("\treturn value;")
    lines += ["}", ""]
    return lines


def emit_table(slots, prototypes, slots_count):
    named = {offset for offset, _, _ in slots}
    top = max(named)
    out = ["", "/* ---- the table (EAGL_GEN_TABLE) ---- */", ""]

    for offset, name, hand in slots:
        if hand:
            continue
        if name in prototypes:
            out += emit_stub(offset, name, prototypes[name])
        else:
            note(f"warning: {offset:#06x} {name}: no prototype in the headers, it is a "
                 f"'not there' entry")

    # Every offset nothing is known about: one stub each, so the log names the offset.
    out.append("/* One per entry this file does not know: logs the offset once, returns 0. */")
    for offset in range(8, slots_count * 8, 8):
        if offset in named:
            continue
        out.append(f"static long eagl_unknown_{offset:#06x}(void *context, ...)")
        out.append("{")
        out.append("\tuint64_t arguments[6];")
        out.append("\tva_list list;")
        out.append("\tunsigned i;")
        out.append("")
        out.append("\tva_start(list, context);")
        out.append("\tfor (i = 0; i < 6; i++) {")
        out.append("\t\targuments[i] = va_arg(list, uint64_t);")
        out.append("\t}")
        out.append("\tva_end(list);")
        out.append(f"\treturn eagl_missing(context, {offset:#06x}, arguments);")
        out.append("}")
    out.append("")
    out.append("static void *const eagl_unknown_slots[] = {")
    for offset in range(8, slots_count * 8, 8):
        if offset in named:
            continue
        out.append(f"\t[({offset:#06x} - 8) / 8] = (void *)eagl_unknown_{offset:#06x},")
    out.append("};")
    out.append("")
    out.append("static const char *")
    out.append("eagl_slot_name(unsigned offset)")
    out.append("{")
    out.append("\tswitch (offset) {")
    for offset, name, _ in slots:
        out.append(f"\tcase {offset:#06x}: return \"{name}\";")
    out.append("\tdefault: return \"?\";")
    out.append("\t}")
    out.append("}")
    out.append("")
    out.append("static void")
    out.append("eagl_fill_table(void *table[])")
    out.append("{")
    out.append(f"\tfor (unsigned slot = 1; slot < MONDIAN_GL_TABLE_SLOTS; slot++) {{")
    out.append("\t\ttable[slot] = (void *)eagl_unknown_slots[slot - 1];")
    out.append("\t}")
    for offset, name, hand in slots:
        entry = f"my_{name}" if hand else f"eagl_slot_{offset:#06x}"
        out.append(f"\ttable[{offset:#06x} / 8] = (void *){entry};")
    out.append("}")
    out.append("")
    out.append(f"#define EAGL_TABLE_SIZE {top + 8:#06x}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--slots", default=DEFAULT_SLOTS)
    ap.add_argument("-O", "--offsets", default=DEFAULT_OFFSETS)
    ap.add_argument("-H", "--headers", action="append",
                    help="a directory of the SDK's OpenGLES headers (default: xcrun's SDK)")
    ap.add_argument("-o", "--output", default=None,
                    help=f"the header to write (default: {DEFAULT_OUTPUT}, or none with --check)")
    ap.add_argument("--from-log", metavar="LOG", help="read the table from a glslots=1 boot log")
    ap.add_argument("--write-slots", metavar="FILE", help="with --from-log: rewrite this slot file")
    ap.add_argument("--check", action="store_true", help="report only, write nothing")
    ap.add_argument("-e", "--eagl", default=os.path.join(HERE, "eagl.c"),
                    help="check that every hand-written entry is defined in this file")
    args = ap.parse_args()

    macros = read_macros(args.offsets)
    slots_count = macros.get("MONDIAN_GL_TABLE_SLOTS")
    if slots_count is None:
        sys.exit(f"no MONDIAN_GL_TABLE_SLOTS in {args.offsets}")

    if args.from_log:
        dumped = slots_from_log(args.from_log)
        if not dumped:
            sys.exit(f"no 'slot 0x...' lines in {args.from_log}")
        destination = args.write_slots
        if destination is None:
            sys.exit("--from-log needs --write-slots")
        hand = {}
        if os.path.isfile(destination):
            for offset, name, is_hand in read_slots(destination, macros):
                hand[offset] = name if is_hand else None
            for line in open(destination):
                parts = line.split("#", 1)[0].split()
                if len(parts) > 3 and parts[2] == "hand" and parts[3] in macros:
                    try:
                        offset = int(parts[0], 0)
                    except ValueError:
                        offset = macros.get(parts[0])
                    if offset is not None:
                        hand[offset] = (parts[1], parts[3])
        write_slots(destination, dumped, hand)
        return

    slots = read_slots(args.slots, macros)
    if os.path.isfile(args.eagl):
        source = open(args.eagl).read()
        undefined = [name for _, name, hand in slots if hand and not re.search(rf"\bmy_{name}\s*\(", source)]
        if undefined:
            sys.exit(f"{args.eagl} defines no my_<name> for: " + ", ".join(undefined))

    if args.headers:
        directories = args.headers
    else:
        sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
                             capture_output=True, text=True).stdout.strip()
        directories = [os.path.join(sdk, "System/Library/Frameworks/OpenGLES.framework/Headers")]
    prototypes = {}
    for directory in directories:
        if not os.path.isdir(directory):
            sys.exit(f"no GL headers in {directory}")
        prototypes.update({k: v for k, v in read_prototypes(directory).items() if k not in prototypes})

    unknown = [name for _, name, _ in slots if name not in prototypes]
    if args.check:
        print(f"{len(slots)} entries, {len(prototypes)} prototypes, {len(unknown)} without one")
        for name in unknown:
            print(f"  no prototype: {name}")
        return
    if unknown:
        note(f"{len(unknown)} entries have no prototype and become 'not there' entries: "
             + ", ".join(unknown))

    output = args.output or DEFAULT_OUTPUT
    text = [
        "/* Generated by tools/gpu/mkeagl.py -- do not edit.",
        f" * {len(slots)} entries of {os.path.basename(args.slots)}, prototypes from the iPhoneOS SDK's",
        " * OpenGL ES headers.",
        " * eagl.c includes this file twice: EAGL_GEN_DECLARATIONS declares, EAGL_GEN_TABLE defines.",
        " */",
        "",
        "#if defined(EAGL_GEN_DECLARATIONS)",
    ]
    text += emit_declarations(slots, prototypes)
    text += ["", "#endif", "", "#if defined(EAGL_GEN_TABLE)"]
    text += emit_table(slots, prototypes, slots_count)
    text += ["", "#endif"]
    open(output, "w").write("\n".join(text) + "\n")
    print(f"{output}: {len(slots)} entries, {len(unknown)} without a prototype")


if __name__ == "__main__":
    main()

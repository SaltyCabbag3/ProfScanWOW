"""Read Lua data files: WoW SavedVariables and data-only addon files.

    load_assignments(text) -> {"ProfScanDB": {...}, ...}   top-level `Name = value` lines
    parse_value(text, start) -> (value, end)               one Lua value starting at `start`

Tables become lists when they only have implicit 1..n entries, otherwise
dicts (implicit entries keyed 1, 2, ...). Only literals are understood:
strings, numbers, true/false/nil and tables; no expressions or code.
"""
import re

_TOKEN = re.compile(r"""
    (?P<space>\s+|--\[(?P<eq>=*)\[.*?\](?P=eq)\]|--[^\n]*)
  | (?P<string>"(?:[^"\\\n]|\\.|\\\n)*"|'(?:[^'\\\n]|\\.|\\\n)*')
  | (?P<long>\[(?P<leq>=*)\[.*?\](?P=leq)\])
  | (?P<number>0[xX][0-9a-fA-F]+|-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)
  | (?P<name>[A-Za-z_][A-Za-z0-9_.]*)
  | (?P<sym>[{}\[\]=,;])
""", re.S | re.X)

_ESCAPES = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
            "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


class LuaDataError(ValueError):
    pass


def _unescape(body):
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt.isdigit():
            m = re.match(r"\d{1,3}", body[i + 1:])
            out.append(chr(int(m.group())))
            i += 1 + len(m.group())
        else:
            out.append(_ESCAPES.get(nxt, nxt))
            i += 2
    return "".join(out)


class _Parser:
    def __init__(self, text, pos=0):
        self.text, self.pos = text, pos
        self.tok = None
        self._advance()

    def _advance(self):
        while True:
            m = _TOKEN.match(self.text, self.pos)
            if not m:
                if self.pos >= len(self.text):
                    self.tok = ("eof", None)
                    return
                raise LuaDataError(f"unexpected {self.text[self.pos:self.pos + 30]!r} at {self.pos}")
            self.pos = m.end()
            if m.group("space") is not None:
                continue
            if m.group("string") is not None:
                self.tok = ("value", _unescape(m.group("string")[1:-1]))
            elif m.group("long") is not None:
                s = m.group("long")
                n = len(m.group("leq")) + 2
                self.tok = ("value", s[n:-n].lstrip("\n"))
            elif m.group("number") is not None:
                s = m.group("number")
                if s.lower().startswith("0x"):
                    v = int(s, 16)
                elif re.fullmatch(r"-?\d+", s):
                    v = int(s)
                else:
                    v = float(s)
                self.tok = ("value", v)
            elif m.group("name") is not None:
                name = m.group("name")
                self.tok = ("value", {"true": True, "false": False, "nil": None}[name]) \
                    if name in ("true", "false", "nil") else ("name", name)
            else:
                self.tok = ("sym", m.group("sym"))
            return

    def _expect(self, sym):
        if self.tok != ("sym", sym):
            raise LuaDataError(f"expected {sym!r}, got {self.tok!r} near {self.pos}")
        self._advance()

    def value(self):
        kind, v = self.tok
        if kind == "value":
            self._advance()
            return v
        if self.tok == ("sym", "{"):
            return self.table()
        raise LuaDataError(f"expected a value, got {self.tok!r} near {self.pos}")

    def table(self):
        self._expect("{")
        implicit, keyed = [], {}
        while self.tok != ("sym", "}"):
            if self.tok == ("sym", "["):
                self._advance()
                key = self.value()
                self._expect("]")
                self._expect("=")
                keyed[key] = self.value()
            elif self.tok[0] == "name":
                key = self.tok[1]
                self._advance()
                self._expect("=")
                keyed[key] = self.value()
            else:
                implicit.append(self.value())
            if self.tok in (("sym", ","), ("sym", ";")):
                self._advance()
            elif self.tok != ("sym", "}"):
                raise LuaDataError(f"expected ',' or '}}', got {self.tok!r} near {self.pos}")
        self._advance()
        if not keyed:
            return implicit
        # WoW writes long arrays as implicit entries, but [n] = keys can mix in
        for i, v in enumerate(implicit, 1):
            keyed[i] = v
        if keyed and all(isinstance(k, int) for k in keyed) and sorted(keyed) == list(range(1, len(keyed) + 1)):
            return [keyed[i] for i in range(1, len(keyed) + 1)]
        return keyed


def parse_value(text, start=0):
    p = _Parser(text, start)
    v = p.value()
    return v, p.pos


def load_assignments(text):
    """Every top-level `Name = value` in a SavedVariables-style file."""
    p, out = _Parser(text), {}
    while p.tok[0] != "eof":
        if p.tok[0] != "name":
            raise LuaDataError(f"expected a variable name, got {p.tok!r} near {p.pos}")
        name = p.tok[1]
        p._advance()
        p._expect("=")
        out[name] = p.value()
    return out


def as_list(v):
    """Lua array that may have come back as [] / {} / None."""
    if v is None or v == {}:
        return []
    if isinstance(v, dict):
        return [v[k] for k in sorted(v)]
    return v


def as_dict(v):
    """Lua table used as a map; an empty or array-shaped one becomes a dict keyed 1..n."""
    if v is None or v == []:
        return {}
    if isinstance(v, list):
        return {i: x for i, x in enumerate(v, 1)}
    return v

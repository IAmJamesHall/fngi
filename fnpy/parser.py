#########################################
# Parser
#
# With what is in types.py we should have enough to compile the stage0
# language.
#
# First we are going to build the parser, which is fairly self-explanatory. We
# parse and emit lexemes (sometimes also called tokens).

from pdb import set_trace as debug

import copy
import enum
import os
import io
import pprint

from dataclasses import dataclass
from typing import List
from typing import Dict

from .types import Env

MISSING_SEMICOLON_ERR = "Expected ';'"

## Lexemes
class LexemeVariant(enum.Enum):
    # TODO: use solid integer values
    EOF = enum.auto()
    INVALID = enum.auto()

    # Values
    LINE_COMMENT = enum.auto() # //
    BLOCK_COMMENT = enum.auto() # /* ... */
    NUMBER = enum.auto()
    IDEN = enum.auto()
    ESC_STR = enum.auto() # \"
    RAW_STR = enum.auto() # "

    # Symbol Operators (Grammar Order)
    MACRO1 = enum.auto() # !
    MACRO2 = enum.auto() # !!
    MINUS = enum.auto() # -
    REF = enum.auto() # &
    DEREF = enum.auto() # @
    CALL = enum.auto() # $
    DIVIDE = enum.auto() # /
    MULTIPLY = enum.auto() # *
    PLUS = enum.auto() # +
    GE = enum.auto() # >=
    GT = enum.auto() # >
    LE = enum.auto() # <=
    LT = enum.auto() # <
    NE = enum.auto() # !=
    EQ = enum.auto() # ==
    SET = enum.auto() # :=

    SEMICOLON = enum.auto() # ;
    COLON = enum.auto() # :
    EQUAL = enum.auto() # =
    BLOCK_OPEN = enum.auto() # (
    BLOCK_CLOSE = enum.auto() # )
    DATA_OPEN = enum.auto() # {
    DATA_CLOSE = enum.auto() # }
    TYPE_OPEN = enum.auto() # [
    TYPE_CLOSE = enum.auto() # ]

    # Type operators
    ARROW = enum.auto() # ->
    DOT = enum.auto() # .
    LABEL = enum.auto() # #

    # Keywords
    FN = enum.auto()
    DO = enum.auto()
    STRUCT = enum.auto()
    ENUM = enum.auto()
    IMPL = enum.auto()
    STK = enum.auto()
    ARR = enum.auto()

    IF = enum.auto()
    ELIF = enum.auto()
    ELDO = enum.auto()
    SWITCH = enum.auto()
    CASE = enum.auto()
    WHILE = enum.auto()

    NOT = enum.auto()
    AND = enum.auto()
    OR = enum.auto()
    BITNOT = enum.auto()
    BITOR = enum.auto()
    BITXOR = enum.auto()
    BITAND = enum.auto()

    CONT = enum.auto()
    BREAK = enum.auto()
    RETURN = enum.auto()


LV = LexemeVariant


@dataclass
class Lexeme:
    variant: LV
    text: str = None


EOF = Lexeme(LV.EOF)

MACRO1 = Lexeme(LV.MACRO1)
MACRO2 = Lexeme(LV.MACRO2)
MINUS = Lexeme(LV.MINUS)
REF = Lexeme(LV.REF)
DEREF = Lexeme(LV.DEREF)
CALL = Lexeme(LV.CALL)
DIVIDE = Lexeme(LV.DIVIDE)
MULTIPLY = Lexeme(LV.MULTIPLY)
PLUS = Lexeme(LV.PLUS)
GE = Lexeme(LV.GE)
GT = Lexeme(LV.GT)
LE = Lexeme(LV.LE)
LT = Lexeme(LV.LT)
NE = Lexeme(LV.NE)
EQ = Lexeme(LV.EQ)
SET = Lexeme(LV.SET)

SEMICOLON = Lexeme(LV.SEMICOLON)
COLON = Lexeme(LV.COLON)
EQUAL = Lexeme(LV.EQUAL)
BLOCK_OPEN = Lexeme(LV.BLOCK_OPEN)
BLOCK_CLOSE = Lexeme(LV.BLOCK_CLOSE)
DATA_OPEN = Lexeme(LV.DATA_OPEN)
DATA_CLOSE = Lexeme(LV.DATA_CLOSE)
TYPE_OPEN = Lexeme(LV.TYPE_OPEN)
TYPE_CLOSE = Lexeme(LV.TYPE_CLOSE)

ARROW = Lexeme(LV.ARROW)
DOT = Lexeme(LV.DOT)
LABEL = Lexeme(LV.LABEL)

FN = Lexeme(LV.FN)
DO = Lexeme(LV.DO)
STRUCT = Lexeme(LV.STRUCT)
ENUM = Lexeme(LV.ENUM)
IMPL = Lexeme(LV.IMPL)
STK = Lexeme(LV.STK)
ARR = Lexeme(LV.ARR)

IF = Lexeme(LV.IF)
ELIF = Lexeme(LV.ELIF)
ELDO = Lexeme(LV.ELDO)
SWITCH = Lexeme(LV.SWITCH)
CASE = Lexeme(LV.CASE)
WHILE = Lexeme(LV.WHILE)

NOT = Lexeme(LV.NOT)
AND = Lexeme(LV.AND)
OR = Lexeme(LV.OR)
BITNOT = Lexeme(LV.BITNOT)
BITOR = Lexeme(LV.BITOR)
BITXOR = Lexeme(LV.BITXOR)
BITAND = Lexeme(LV.BITAND)

CONT = Lexeme(LV.CONT)
BREAK = Lexeme(LV.BREAK)
RETURN = Lexeme(LV.RETURN)

################################
# Scanner
# The scanner reads into a 32 byte buffer and provides nextByte() and
# backByte() methods.
#
# The scanner only allows going back by 1 byte before progressing again.
# Any more may throw an error. The scanner also tracks the filePos, line, and
# col.
#
# Obviously there are python classes that can do this for us, but we
# want something that we can emulate in the forth implementation.

class Scanner(object):
    BUF_SIZE = 32
    LAST_COL_SENTINEL = 0xFFFFFFFF

    def __init__(self, fo: io.TextIOWrapper):
        self.fo = fo
        self.buffer = bytearray(self.BUF_SIZE)
        self.bufMax = 0
        self.bufIndex = 0
        self.filePos = 0
        self.lastCol = self.LAST_COL_SENTINEL
        self.col = 0
        self.line = 0

    def nextByte(self) -> int:
        if self.bufIndex == self.bufMax:
            if self.bufMax != 0:
                # Move the last character to the start to allow backByte()
                self.buffer[0] = self.buffer[self.bufMax -1]
                self.bufIndex = 1
            else:
                self.bufIndex = 0 # no byte to go back to

            # try to fill the buffer
            readBytes = self.fo.read(self.BUF_SIZE - 1)
            self.bufMax = self.bufIndex + len(readBytes)
            self.buffer[self.bufIndex:self.bufMax] = readBytes

        self.lastCol = self.col

        if self.bufIndex == self.bufMax:
            # We pretend we are returning a character even though it is the EOF
            # so that backByte still works.
            b = 0 # EOF
        else:
            b = self.buffer[self.bufIndex]
        self.bufIndex += 1
        self.filePos += 1
        if b == ord('\n'):
            self.line += 1
            self.col = 0
        else:
            self.col += 1

        return b

    def backByte(self):
        if self.bufIndex == 0:
            raise IndexError("Cannot go back at start.")
        if self.lastCol == self.LAST_COL_SENTINEL:
            raise IndexError("Cannot go back > 1 byte")
        self.bufIndex -= 1
        self.filePos -= 1
        self.col = self.lastCol
        self.lastCol = self.LAST_COL_SENTINEL
        if self.buffer[self.bufIndex] == ord('\n'):
            self.line -= 1

def testScanner_basic():
    sc = Scanner(io.BytesIO(b'42'))
    for i in range(10):
        assert ord('4') == sc.nextByte()
        sc.backByte()
    assert ord('4') == sc.nextByte()
    for i in range(10):
        assert ord('2') == sc.nextByte()
        sc.backByte()
    assert ord('2') == sc.nextByte()
    for i in range(10):
        assert 0 == sc.nextByte()
        sc.backByte()
    assert 0 == sc.nextByte()


################################
# Lexer
# The lexer returns a stream of Lexemes, which must be stored by another data
# structure. Complex tokens like numbers, full identifiers and strings are
# handled directly.

def isWhitespace(c: int) -> bool:
    if c == 0: return False
    return c <= ord(' ')

def isSymbol(c: int) -> bool:
    return (ord('!') <= c <= ord('/') or
            ord(':') <= c <= ord('@') or
            ord('[') <= c <= ord('`') or
            ord('{') <= c <= ord('~'))

def isNumber(c: int) -> bool:
    return ord('0') <= c <= ord('9')

def isHex(c: int) -> bool:
    return (
        isNumber(c)
        or (ord('A') <= c <= ord('F'))
        or (ord('a') <= c <= ord('f')))

def isNameChar(c: int) -> bool:
    return c != 0 and not isWhitespace(c) and not isSymbol(c)


class Lexer(object):
    def __init__(self, fo: io.TextIOWrapper):
        fo.seek(0)
        self.scanner = Scanner(fo)

        self.fo = fo
        self.tokenIndex = 0

    def nextLexeme(self) -> Lexeme:
        sc = self.scanner
        c = sc.nextByte()
        while isWhitespace(c):
            if c == b'': break
            c = sc.nextByte()

        if c == 0:
            return EOF

        elif c == ord('/'):
            c = sc.nextByte()
            if c == ord('/'): # LINE_COMMENT
                out = bytearray(b'/')
                while True:
                    if c == 0: break
                    if c == ord('\n'):
                        sc.backByte()
                        break
                    out.append(c)
                    c = sc.nextByte()
                return Lexeme(LV.LINE_COMMENT, out)
            elif c == ord('*'): # BLOCK_COMMENT
                out = bytearray(b'/*')
                lastWasStar = False
                while True:
                    c = sc.nextByte()
                    out.append(c)
                    if c == '*':
                        lastWasStar = True
                    elif c == 0 or (lastWasStar and c == '/'):
                        return Lexeme(LV.BLOCK_COMMENT, out)
                    else:
                        lastWasStar = False

            else:
                return DIVIDE

        elif c == ord('"'):
            out = bytearray(b'"')
            c = sc.nextByte()
            while True:
                if c == 0:
                    return Lexeme(LV.INVALID, out)
                out.append(c)
                if c == ord('"'):
                    break
                c = sc.nextByte()
            return Lexeme(LV.RAW_STR, out)

        elif c == ord('!'):
            c = sc.nextByte()
            if c == ord('='):
                return NE
            elif c == ord('!'):
                return MACRO2
            sc.backByte()
            return MACRO1

        elif c == ord('-'):
            c = sc.nextByte()
            if c == ord('>'):
                return ARROW
            return MINUS

        elif c == ord('>'):
            c = sc.nextByte()
            if c == ord('='):
                return GE
            sc.backByte()
            return GT

        elif c == ord('<'):
            c = sc.nextByte()
            if c == ord('='):
                return LE
            sc.backByte()
            return LT

        elif c == ord(':'):
            c = sc.nextByte()
            if c == ord('='):
                return SET
            sc.backByte()
            return COLON

        elif c == ord('\\'): # Escape, must be \"
            out = bytearray([c])
            c = sc.nextByte()
            out.append(c)
            if c != ord('"'):
                return Lexeme(LV.INVALID, out)

            while True:
                c = sc.nextByte()
                out.append(c)
                if c == ord('\\'):
                    c = sc.nextByte()
                    out.append(c)
                    if c == ord('"'):
                        break

            return Lexeme(LV.ESC_STR, out)

        elif ord('0') <= c <= ord('9'):
            out = bytearray([c])
            c = sc.nextByte()

            numIsHex = False
            if c == ord('x'):
                numIsHex = True
                out.append(c)
                c = sc.nextByte()

            while True:
                if numIsHex and isHex(c):
                    out.append(c)
                elif isNumber(c):
                    out.append(c)
                elif isNameChar(c):
                    sc.backByte()
                    out.extend(b' followed by nameChar')
                    return Lexeme(LV.INVALID, out)
                else:
                    sc.backByte()
                    return Lexeme(LV.NUMBER, out)
                c = sc.nextByte()

        elif c == ord('&'): return REF
        elif c == ord('@'): return DEREF
        elif c == ord('$'): return CALL
        elif c == ord('+'): return PLUS
        elif c == ord('*'): return MULTIPLY

        elif c == ord('.'): return DOT
        elif c == ord('#'): return LABEL
        elif c == ord(';'): return SEMICOLON
        elif c == ord('='): return EQUAL
        elif c == ord('('): return BLOCK_OPEN
        elif c == ord(')'): return BLOCK_CLOSE
        elif c == ord('{'): return DATA_OPEN
        elif c == ord('}'): return DATA_CLOSE
        elif c == ord('['): return TYPE_OPEN
        elif c == ord(']'): return TYPE_CLOSE
        elif isSymbol(c): return Lexeme(LV.INVALID, bytearray([c]))

        name = bytearray([c])
        while True:
            c = sc.nextByte()
            if not isNameChar(c):
                sc.backByte()
                break
            name.append(c)

        if name == b'fn': return FN
        if name == b'do': return DO
        if name == b'struct': return STRUCT
        if name == b'enum': return ENUM
        if name == b'impl': return IMPL
        if name == b'stk': return STK
        if name == b'arr': return ARR

        if name == b'if': return IF
        if name == b'elif': return ELIF
        if name == b'eldo': return ELDO
        if name == b'switch': return SWITCH
        if name == b'case': return CASE
        if name == b'while': return WHILE

        if name == b'not': return NOT
        if name == b'and': return AND
        if name == b'or': return OR
        if name == b'bitnot': return BITNOT
        if name == b'bitor': return BITOR
        if name == b'bitand': return BITAND

        if name == b'cont': return CONT
        if name == b'break': return BREAK
        if name == b'return': return RETURN

        return Lexeme(LV.IDEN, name)

    def getAllLexemes(self) -> List[Lexeme]:
        """Used in testing."""
        out = []
        while True:
            lexeme = self.nextLexeme()
            out.append((self.scanner.line, lexeme))
            if lexeme is EOF:
                return out

    def getAllVariants(self) -> List[LV]:
        return [t.variant for t in self.getAllLexemes()]


class FakeLexer(Lexer):
    """For testing."""
    def __init__(self, b: bytes):
        super().__init__(io.BytesIO(b))


def lineVariants(line: int, variants: List[LV]):
    return [(line, v) for v in variants]


def testLexer_basic():
    expected = [(0, Lexeme(LV.NUMBER, b'42')), (0, EOF)]
    result = FakeLexer(b'42').getAllLexemes()
    assert expected == result


def testLexer_helloWorld():
    lv = LV
    ts = Lexer(open("grammar/hello_world.fn", 'rb', buffering=0))
    result = ts.getAllLexemes()
    resultVariants = [l[1].variant for l in result]
    resultLineVariants = [(l[0], l[1].variant) for l in result]
    expectLineVariants = (
        [(0, lv.LINE_COMMENT)]
        # say: Str = "Hello " + "World";
        + lineVariants(1, [
            lv.IDEN, lv.COLON, lv.IDEN, lv.EQUAL, lv.RAW_STR,
            lv.PLUS, lv.RAW_STR, lv.SEMICOLON])

        # fn helloWorld: [] -> [] do (
        + lineVariants(3, [
            lv.FN, lv.IDEN, lv.COLON, lv.TYPE_OPEN, lv.TYPE_CLOSE,
            lv.ARROW, lv.TYPE_OPEN, lv.TYPE_CLOSE, lv.DO, lv.BLOCK_OPEN])

        # println! say
        + lineVariants(4, [lv.IDEN, lv.MACRO1, lv.IDEN])

        # );
        + lineVariants(5, [lv.BLOCK_CLOSE, lv.SEMICOLON])
        + [(6, lv.EOF)]
    )

    assert lv.INVALID not in resultVariants
    assert expectLineVariants == resultLineVariants


################################
# Lexeme Node List
# For the parser to be implemented it must be able to:
# - Retrieve lexeme nodes that contain metadata (line, col, etc)
# - Do lookahead of at least 1 lexeme, probably more (we will see)
# - Advance the root (dropping nodes) up until a specific node.

@dataclass
class LexemeNode:
    lexeme: Lexeme
    line: int
    col: int
    next: "LexemeNode" = None


class LexemeLL(object):
    """Lexeme linked list."""
    def __init__(self, lexer: Lexer):
        self.lexer = lexer
        self.root = None
        self.last = None
        self.gotEof = False

    def pop(self) -> LexemeNode:
        """Get the next lexeme node and advance the root."""
        if self.root is None:
            self._populateNext()
        out = self.root
        self.root = out.next
        if self.root is None:
            assert self.last is out
            self.last = None
        return out

    def advance(self, node):
        """Advance the root until node."""
        while self.root is not node:
            if self.root is None: raise IndexError(node)
            self.pop()

    def peek(self, index: int = 0, fromNode=None) -> LexemeNode:
        """Peek at the Lexeme Node at index relative to node

        If node is None, it is relative to root.
        """
        if fromNode is None:
            if self.root is None and not self.gotEof:
                self._populateNext()
            fromNode = self.root
        prev = fromNode
        ln = prev
        while index > 0:
            ln = prev.next
            if ln is None and not self.gotEof:
                self._populateNext()
                continue
            if ln is None: return
            prev = ln
            index = index - 1
        return ln

    def _populateNext(self):
        if self.gotEof:
            raise IndexError("Already to EOF")
        lexeme = self.lexer.nextLexeme()
        if lexeme is EOF:
            self.gotEof = True

        node = LexemeNode(
            lexeme,
            self.lexer.scanner.line,
            self.lexer.scanner.col)

        if self.last is None:
            assert self.root is None
            self.root = node
            self.last = node
        else:
            self.last.next = node
            self.last = node


class FakeLexemeLL(LexemeLL):
    """For testing."""
    def __init__(self, b: bytes):
        super().__init__(FakeLexer(b))

################################
# AST Nodes and Parser
# The parser implements the syntax defined in grammar/grammar.peg, which is
# structured (ordered) such that it can be transparently implemented by a
# recursive-descent style parser.
#
# The parser consumes the result of the lexer and converts it into AST nodes.

# ParsePtr
# Mutable global parsers that will be defined later. Callers will use i.e.
# parseStmt.ptr(ll) to call them.
# 
# Note: this is not really needed in python, it is mostly to demonstrate how
# fngi/forth can implement it.

@dataclass
class ParsePtr:
    ptr = None

parseStmt = ParsePtr()
parseExpr = ParsePtr()
parseTy = ParsePtr()
parseName = ParsePtr()
parseMacro2 = ParsePtr()

# Error handling is done through a global variable to demonstrate how to
# implement on resource/syntax constrained languages like we will be doing in
# Forth.

@dataclass
class ParseError:
    msg: str
    line: int
    col: int

    @classmethod
    def new(cls, msg: any, ln: LexemeNode):
        return cls(str(msg), ln.line, ln.col)

PARSE_ERROR = ParsePtr()

def updateError(msg, ln: LexemeNode):
    PARSE_ERROR.ptr = ParseError.new(msg, ln)

def assertAndCleanError(expectedMsg = None):
    if PARSE_ERROR.ptr:
        result = PARSE_ERROR.ptr.msg
    else:
        result = None
    PARSE_ERROR.ptr = None
    assert expectedMsg == result


def testError():
    assert PARSE_ERROR.ptr is None
    assertAndCleanError()
    updateError('foo', LexemeNode(None, 11, 42))
    assert PARSE_ERROR.ptr.msg == 'foo'
    assert PARSE_ERROR.ptr.line == 11
    assert PARSE_ERROR.ptr.col == 42
    assertAndCleanError('foo')
    assert PARSE_ERROR.ptr is None
    assertAndCleanError()

class ASTNode(object):
    """The base AST node type."""

@dataclass
class ParserState:
    env: Env
    # whether we are in a function or not
    inFn: bool = False
    # whether the fn we are in is const
    fnIsConst: bool = False
    localVars: Dict[str, ASTNode] = None

@dataclass
class Number(ASTNode):
    value: int

@dataclass
class PrimaryBytes(ASTNode):
    variant: LV
    value: bytes

@dataclass
class Void(ASTNode):
    pass

@dataclass
class Empty(ASTNode):
    pass

@dataclass
class LabelStmt(ASTNode):
    label: bytes
    stmt: ASTNode

@dataclass
class Block(ASTNode):
    stmts: List[LabelStmt]
    lastSemicolon: bool

@dataclass
class NameBlockUnit(ASTNode):
    number: int
    ref: bool
    deref: bool
    name: "Name"


# Test Helpers
def unwrapAST(ast: ASTNode, out=None) -> List[any]:
    """Takes a single node and "unwrapps" it into a list of values that we can
    easily write assertions for.  """
    if out is None:
        out = []
    if isinstance(ast, Number):
        out.append(ast.value)
    elif isinstance(ast, PrimaryBytes):
        out.append('{}::{}'.format(ast.variant.variant.name, ast.value))
    elif isinstance(ast, LabelStmt):
        if ast.label:
            out.append('#' + str(ast.label))
        unwrapAST(ast.stmt, out=out)
    elif isinstance(ast, Block):
        out.append('(')
        unrollAST(ast.stmts, out=out)
        out.append((';' if ast.lastSemicolon else '') + ')')
    return out

def unrollAST(asts: List[ASTNode], out=None) -> List[ASTNode]:
    """Takes a list of nodes and "unrolls" them into a flat list that can be
    more easily asserted against.
    """
    if out is None:
        out = []
    for a in asts:
        unwrapAST(a, out=out)
    return out



################################
# Parser
# The parser is mostly a recursive descent parser. We implement the "least
# complicated" expressions first and work our way up.

# grammar: NUMBER = ("0x" _hex+) / _numeric+
def parseNumber(ll: LexemeLL) -> Number:
    ln = ll.pop()
    assert ln.lexeme.variant is LV.NUMBER
    numTxt = ln.lexeme.text
    try:
        if len(numTxt) >= 2 and numTxt[1] == 'x':
            value = int(numTxt, 16)
        else:
            value = int(numTxt)
    except ValueError as e:
        return updateError(e, ln)
    return Number(value)


def test_parseNumber():
    ll = FakeLexemeLL(b'42')
    result = parseNumber(ll)
    assert 42 == result.value
    result = ll.pop()
    assert result.lexeme is EOF
    assertAndCleanError()


# TODO parseEscStr(ll: LexmeLL) -> EscStr:
def parseRawStr(ll: LexemeLL) -> PrimaryBytes:
    ln = ll.pop()
    assert ln.lexeme.variant is LV.RAW_STR
    return PrimaryBytes(LV.RAW_STR, ln.lexeme.text[1:-1])

def testParseRawStr():
    result = parseRawStr(FakeLexemeLL(b'"foo bar"'))
    assert b'foo bar' == result.value
    assertAndCleanError()


# Grammar: label = w? "#" IDEN
LABEL_ERR = "Expected IDEN after '#' for label"
def parseLabel(ll: LexemeLL) -> PrimaryBytes:
    assert ll.pop().lexeme is LABEL
    ln = ll.pop()

    if ln.lexeme.variant is not LV.IDEN:
        return updateError(LABEL_ERR, ln)

    return PrimaryBytes(LV.LABEL, ln.lexeme.text)

def test_parseLabel():
    ll = FakeLexemeLL(b'#foo')
    result = parseLabel(ll)
    assert b'foo' == result.value
    assert ll.pop().lexeme is EOF
    assertAndCleanError()

def test_parseLabel_bad():
    ll = FakeLexemeLL(b'#(foo)')
    result = parseLabel(ll)
    assert None == result
    assertAndCleanError(LABEL_ERR)


# Grammar: multiExpr = expr (SC expr)* SC?
# Note: we add on a bit here with endLexeme
def parseMultiExpr(state: ParserState, ll: LexemeLL, endLexeme: Lexeme) -> List[ASTNode]:
    """Parse the label statements and consume the endLexeme."""
    out = []
    while True:
        if ll.peek().lexeme is endLexeme:
            ll.pop()
            return out

        expr = parseExpr.ptr(state, ll)
        if expr is None: return
        out.append(expr)


# Grammar: multiLabelStmt = label? stmt (SC label? stmt)* SC?
def parseMultiLabelStmt(
        state: ParserState, ll: LexemeLL, endLexeme: Lexeme
        ) -> (bool, List[LabelStmt]):
    """Parse the label statements and consume the endLexeme."""
    out = []
    while True:
        label = None
        if ll.peek().lexeme is LABEL:
            label = parseLabel()
            if label is None: return

        stmt = parseStmt.ptr(state, ll)
        if stmt is None: return
        labelStmt = LabelStmt(label, stmt)
        out.append(labelStmt)

        lastSemicolon = ll.peek().lexeme is SEMICOLON
        if lastSemicolon: ll.pop()

        if ll.peek().lexeme is endLexeme:
            ll.pop()
            return lastSemicolon, out
        elif not lastSemicolon:
            updateError(MISSING_SEMICOLON_ERR, ll.peek())


# Grammar: file = multiLabelStmt w?
def parseFile(env: Env, ll: LexemeLL) -> List[LabelStmt]:
    state = ParserState(env)
    out = parseMultiLabelStmt(state, ll, EOF)
    if not out: return
    return out[1]

###################
# Note for readers following along:
# During development I am building up the complexity of the parseStmt,
# parseExpr, etc "pointer" parsers as well as improving parsePrimary. While I
# am doing so I am testing the new parsers I have added.  Each of these tests
# represents additional built-up complexity in our recursive descent parser.

def testParseNumbers():
    ll = FakeLexemeLL(b'42; 33; 009')
    stmts = parseFile(None, ll)
    assert [42, 33, 9] == unrollAST(stmts)
    assertAndCleanError()

def testParseNumbersBlock():
    ll = FakeLexemeLL(b' ( 42; 33;); 0')
    stmts = parseFile(None, ll)
    assert ['(', 42, 33, ';)', 0] == unrollAST(stmts)
    assertAndCleanError()

    ll = FakeLexemeLL(b' (1; 2); 3')
    stmts = parseFile(None, ll)
    assert ['(', 1, 2, ')', 3] == unrollAST(stmts)
    assertAndCleanError()

# TODO: stk
# TODO: arr
# TODO: struct
# TODO: ifElDo
# TODO: switch
# TODO: while
def parseIden(ll: LexemeLL) -> PrimaryBytes:
    ln = ll.pop()
    assert ln.lexeme is IDEN
    return PrimaryBytes(LV.IDEN, ln.lexeme.text)


def parsePrimary(state: ParserState, ll: LexemeLL) -> ASTNode:
    peek = ll.peek()
    if peek.lexeme.variant is LV.NUMBER:
        return parseNumber(ll)
    # TODO: ESC_STR
    elif peek.lexeme.variant is LV.RAW_STR:
        return parseRawStr(ll)
    elif ( # empty / emptyBlock
            (peek.lexeme is DATA_OPEN and ll.peek(1).lexeme is DATA_CLOSE)
            or (peek.lexeme is BLOCK_OPEN and ll.peek(1).lexeme is BLOCK_CLOSE)
        ):
        ll.pop(); ll.pop()
        return Empty
    elif peek.lexeme is BLOCK_OPEN:
        ll.pop()
        lastSemicolon, stmts = parseMultiLabelStmt(state, ll, BLOCK_CLOSE)
        return Block(stmts, lastSemicolon)
    # TODO: stk
    # TODO: arr
    # TODO: struct
    # TODO: ifElDo
    # TODO: switch
    # TODO: while
    elif peek.lexeme is IDEN:
        return parseIden(ll)
    else:
        raise NotImplementedError(peek)

##
# Non Primary Expressions

# grammar: nameBlUnit = w? NUMBER? (w? "&")? macro2
def parseNameBlockUnit(state: ParserState, ll: LexemeLL) -> ASTNode:
    number = None
    if ll.peek().lexeme.variant is LV.NUMBER:
        number = parseNumber(ll).value

    if ll.peek().lexeme is REF:
        ll.pop(); ref = True

    parseMacro2.ptr(state, ll)


# grammar: nameBlock = "[" nameBlUnit (SC nameBlUnit)* SC? w? "]"
def parseNameBlock(state: ParserState, ll: LexemeLL) -> bytes:
    assert ll.pop().lexeme is TYPE_OPEN

    outb = bytearray(b'[')
    while True:
        macro2 = parseMacro2.ptr(state, ll)
        if macro2 is None: return

        name = macro2 # TODO: execute if macro2
        if isinstance(name, Void):
            nameBytes = b'[]'
        elif isinstance(name, PrimaryBytes) and name.variant is LV.NAME:
            nameBytes = name.value
        else:
            msg = (
                "Expected name or macro that resolves to name."
                " Got: {}"
            ).format(name)
            updateError(msg, macro2)

        outb.extend(nameBytes)

        lastSemicolon = ll.peek().lexeme is SEMICOLON
        if lastSemicolon: ll.pop()

        if ll.peek().lexeme is TYPE_CLOSE:
            ll.pop(); return out
        elif not lastSemicolon:
            updateError(MISSING_SEMICOLON_ERR, ll.peek())

    outb.append(ord(']'))
    return outb

# grammar:nameNoDot = primary (w? nameBlock)?
def parseNameNoDot(state: ParserState, ll: LexemeLL) -> ASTNode:
    primary = parsePrimary(state, ll)
    if primary is None: return
    if ll.peek().lexeme is TYPE_OPEN:
        if not isinstance(primary, Iden):
            return updateError(
                f"Did not expect name block following {type(primary)}",
                ll.peek())
        nameBlock = parseNameBlock(state, ll)
        return PrimaryBytes(LV.NAME, primary.value + nameBlock)


def _checkName(node: ASTNode, ln: Lexeme):
    if not (isinstance(node, PrimaryBytes) and node.variant is LV.NAME):
        return updateError(f"Expected name or macro that resolves to name", ln)
    return True

# grammar: name = nameNoDot (w? "." nameNoDot)*
def parseName(state: ParserState, ll: LexemeLL) -> ASTNode:
    firstLexeme = ll.peek()
    maybeNameNoDot = parseNameNoDot(state, ll)
    if maybeNameNoDot is None: return
    if ll.peek().lexeme is not DOT:
        return maybeNameNoDot

    if not _checkName(maybeNameNoDot, firstLexeme): return
    outb = bytearray(maybeNameNoDot.value)
    while ll.peek().lexeme is DOT:
        ll.pop(); firstLexeme = ll.peek()
        nameNoDot = parseNameNoDot(state, ll)
        if not _checkName(nameNoDot, firstLexeme): return
        outb.append(ord('.'))
        outb.extend(nameNoDot.value)
    return PrimaryBytes(LV.NAME, outb)

# def parseCall(ll: LexemeLL) -> ASTNode:
#     callOperations = [parseUnary(ll)]
# 
#     while ll.peek() is CALL:
#         callOperations.append(parseUnary(ll))
# 
#     return Binary(callOperations, CALL)


def _parseExpr(state: ParserState, ll: LexemeLL) -> ASTNode:
    return parsePrimary(state, ll)

# Grammar: stmt = (flow / decl / expr)
def _parseStmt(state: ParserState, ll: LexemeLL) -> ASTNode:
    return parseExpr.ptr(state, ll)

parseExpr.ptr = _parseExpr
parseStmt.ptr = _parseStmt



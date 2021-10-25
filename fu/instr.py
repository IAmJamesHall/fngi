from .imports import *

class Instr(BetterEnum): pass

def instrSizeTy(instrBits: int):
    """
    0: 8bit    1: 16bit
    3: 32bit     4: undefined
    """
    if bits == 0: return U8
    elif bits == 1: return U16
    elif bits == 3: return U32
    else: raise Trap(f"size {bits}")

class MemM(Instr):  # Mem Mode
    SRLP = 0x0
    SRCP = 0x1
    SROI = 0x2
    FTLP = 0x3
    FTCI = 0x4
    FTOI = 0x5
    IMWS = 0x6
    WS   = 0x7

class JmpM(Instr):  # Jump Mode
    JZ        = 0x0
    CALL      = 0x1
    JST       = 0x2
    CNW       = 0x3
    reserved0 = 0x4
    reserved1 = 0x5
    RET       = 0x6
    NOJ       = 0x7

class OpM(Instr):  # Operation
    FT  = 0x00
    SR  = 0x01
    DVF = 0x02
    DVS = 0x03
    NOP = 0x04

    DRP = enumVal()
    INV = enumVal()
    NEG = enumVal()
    EQZ = enumVal()
    EQZ_NC = enumVal()

    DRP2 = enumVal()
    OVR = enumVal()
    ADD = enumVal()
    SUB = enumVal()
    MOD = enumVal()
    MUL = enumVal()
    DIV_U = enumVal()
    DIV_S = enumVal()
    OR = enumVal()
    XOR = enumVal()
    SHL = enumVal()
    SHR = enumVal()
    EQU = enumVal()
    NEQ = enumVal()
    GE_U = enumVal()
    GE_S = enumVal()
    LT_U = enumVal()
    LT_S = enumVal()


def testInstrAPI():
    assert 0x0 == MemM.SRLP.value
    assert "SRLP" == MemM.SRLP.name

    assert 0x00 == Op.FT.value
    assert 0x04 == Op.IDN.value
    assert 0x05 == Op.DRP.value

    assert Op.DRP == Op(0x05)
    assert Op.DRP == Op.fromStr("DRP")

    assert isinstance(Op.DRP, Op)

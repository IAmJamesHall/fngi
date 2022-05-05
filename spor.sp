\  |00322998|L0027|@158D {0...      72C4|        1} [JMPL  U2] +++ "a" ((_setImpl   0x1527)) 

\ This file bootstraps spor from the native (i.e. C) implementation into
\ a more full-featured language with helpful macros.
\
\ Note: this file requires the compiler to pass the current heap value on the
\ stack so that it can define it's first function (_h), which it then
\ uses to define the other functions.
\
\ # Table of Contents
\ Search for these headings to find information
\
\ [0] Documented Core Structs and Fn Types
\ [1] Instructions: contains definition of spore assembly instructions and
\    documentation.
\    [1.a] Operations: Special
\    [1.b] Operations: One Inp -> One Out
\    [1.c] Operations: Two Inp -> One Out
\    [1.d] Small Literal [0x40 - 0x80)
\    [1.e] Sizes: SZ1, SZ2, SZ4, SZA
\    [1.f] Jmp: jumping, execution, tables
\    [1.g] Mem: fetch, store, locals, globals
\ [2] Registers and Device Operations (RGFT, RGSR, DVFT, DVSR)
\ [3] Constants
\    [3.a] Dict Ty Bits
\    [3.b] Zoab
\    [3.c] Log Levels
\    [3.d] Errors
\ [4] Globals
\ [5] Bootstrap Macros: necessary functionality for the rest of the language.
\ [6] Core functions and macros: bread and butter of spor assembly
\ [7] ASM Flow Control (IF, LOOP, etc)
\ [8] Scanning and Alignment Utilities: reading, peeking and szI alignment
\ [9] globals and locals
\ [10] Zoa strings and logging zoab
\ [11] Fngi compile loop
\
\ **********
\ * [0] Documented Core Structs and Fn Types
\
\ There are a few "core structs" and associated "core function types". These allow
\ cohesion and interoperability among various APIs in spor/fngi.
\
\ Structs:
\   struct Slc [ref: &uty; len: U2]          : a slice of data
\   struct Buf [ref: &uty; len: U2; cap: U2] : buffer (len and total capacity)
\   struct Sll [next: AP]                    : singly linked list
\
\ Fn Types:
\   fn wlkr [ref: &uty -> ref: AP, done:Bool]: function walker, used with wlk
\   fn wlk  [ref: &uty, w: wlkr -> AP]       : walk a walker. Call until done,
\   fn sllwlkr [ref: &Sll -> done:Bool]      : Sll version of walker.
\   fn sllwlk  [ref: &Sll, w:sllwlkr -> AP]  : walk an Sll walker, ret done ref.
\
\ **********
\ * [1] Instructions: these are constants that can be used directly by: % ^
\ Spor uses 8 bit instructions with the following bit layout (S=size bit):
\   00XX XXXX: operation
\   01XX XXXX: small literal [0x00 - 0x3F]
\   10SS XXXX: jmp
\   11SS XXXX: mem

\ # [1.a] Operations: Special
#00 =NOP   \ { -> }     no operation
#01 =RETZ  \ Return if zero
#02 =RET   \ Return
#03 =SWP   \ {l r -> r l} swap
#04 =DRP   \ {l -> }    drop
#05 =OVR   \ {l r -> }  drop 2
#06 =DUP   \ {l -> l l} duplicate
#07 =DUPN  \ {l -> l l==0} DUP then NOT
#08 =DVFT  \ Device Operation Fetch
#09 =DVSR  \ Device Operation Store
#0A =RGFT  \ {-> v}  Register Fetch
#0B =RGSR  \ {v}     Register Store

\ # [1.b] Operations: One Inp -> One Out
#10 =INC   \ {l+1}  increment 1
#11 =INC2  \ {l+2}  increment 2
#12 =INC4  \ {l+4}  increment 4
#13 =DEC   \ {l-4}  decrement 1
#14 =INV   \ {~l}   Bitwise Inversion
#15 =NEG   \ {-l}   Negate (2's compliment)
#16 =NOT   \ {l==0} Logical NOT
#17 =CI1   \ {ISz}  Convert I1 to ISz
#18 =CI2   \ {ISz}  Convert I2 to ISz
\ future: leading 0's, trailing 0's, count of 1's
\ Some single-arg extension commands might be:
\ (7) floating point abs, negative, ceil, floor, trunc, nearest, and sqrt
\ (1) i -> f conversion
\ (1) f -> i conversion

\ # [1.c] Operations: Two Inp -> One Out
#20 =ADD   \ {l +  r } add
#21 =SUB   \ {l -  r } subtract
#22 =MOD   \ {l %  r } integer modulo (remainder)
#23 =SHL   \ {l << r } bit shift left
#24 =SHR   \ {l >> r } bit shift right
#25 =MSK  \ {l &  r } bitwise and
#26 =JN    \ {l |  r } bitwise or
#27 =XOR   \ {l ^  r } bitwise xor
#28 =AND  \ {l && r } logical and
#29 =OR    \ {l || r } logical or
#2A =EQ    \ {l == r } equal
#2B =NEQ   \ {l != r } not equal
#2C =GE_U  \ {l >= r } unsigned greater than or equal
#2D =LT_U  \ {l <  r } unsigned less than
#2E =GE_S  \ {l >= r } signed greater than or equal
#2F =LT_S  \ {l <  r } signed less than

#30 =MUL   \ {l *  r } multiplication
#31 =DIV_U \ {l / r  } unsigned division
#32 =DIV_S \ {l / r  } signed division
\ Double-arg extension commands might be:
\ floating point: add,sub,mul,div,ge,lt

\ # [1.d] Small Literal [0x40 - 0x80)
#40 =SLIT

\ # [1.e] Sizes (note: SZA defined after `select`)
#00 =SZ1
#10 =SZ2
#20 =SZ4

\ # [1.f] Jmp
\
\ Jumps can be to either a literal (L) or to an item on the working stack (W).
\ - X means "execute" and is a call.
\ - XS is an "execute small" and means that the function has no local stack.
\ - XL/XW will execute a function that has a local stack. The size of the
\   local stack is stored in the first 16bits at the function's address, which
\   are loaded by the execute instr and stored in the highest byte in the
\   callstack (which RET uses to shrink the local stack on return).

\   Jmp      Description
#80 =JMPL  \ Jmp to Literal
#81 =JMPW  \ Jmp to WS
#82 =JZL   \ Jmp to Literal if store==0
#83 =JTBL  \ Jump to Table index using size=Literal
#84 =XL    \ Execute Literal (mPtr)
#85 =XW    \ Execute WS (aPtr)
#86 =XSL   \ Execute Small Literal (no LS update)
#87 =XSW   \ Execute Small WS (no LS update)

\ JZL and JMPL for SZ=1
\ For SZ=1 they jump to the 1 byte signed offset from the location
\ of the operation (NOT the location of the literal).

\ # [1.g] Mem|Store              |Description
#C0 =FT    \ {addr} -> {value}  |FeTch value from addr
#C1 =FTO   \ {addr} -> {value}  |FeTch value from addr + U1 literal offset
#C2 =FTLL  \ {} -> {local}      |FeTch from LP + U1 literal offset
#C3 =FTGL  \ {} -> {global}     |FeTch from GB + U2 literal offset
#C4 =SR    \ {value addr} -> {} |Store value at addr
#C5 =SRO   \ {value addr} -> {} |Store value at addr + U1 literal offset
#C6 =SRLL  \ {value} -> {}      |StoRe value at LP + U1 literal offset
#C7 =SRGL  \ {value} -> {}      |StoRe value at GB + U2 literal offset
#C8 =LIT   \ {} -> {literal}    |Literal (U1, U2 or U4)

\ Common instr+szs
@SZ2 @XSL  ^JN   =XSL2
@SZ2 @JMPL ^JN   =JMPL2

\ **********
\ * [2] Registers and Device Operations: RGXX|DVXX w/ 1 byte literal

\ The RG 1 byte literal has the following byte format. Note: FT will return the
\ register value + offset, SR will store the value + offset in the register.
\   1OOO OOOO: (R_LP) local stack pointer with 7bit offset (O)
\   0XXX XXXR: register. X is currently undefined.
#80 =R_LP \ local stack pointer
#00 =R_EP \ execution pointer, SR will panic
#01 =R_GB \ global base pointer

\ The DV 1 byte literal select the operation
#00 =D_read   \ read from src, filling up tokenBuf
#01 =D_scan   \ FT: scan next word (tokenBuf)  SR: line comment
#02 =D_dict   \ [(SR-only)value &dict] FT=get SR=set dict key=tokenBuf
#03 =D_dictK  \ [&dict] FT=get reference to val  SR=forget including key
#05 =D_comp   \ compile (assemble) the token in tokenBuf
#06 =D_assert \ error if != 0
#07 =D_wslen  \ get working stack length (in slots)
#08 =D_cslen  \ get call stack lengh (in slots)
\ {-> err} D_xCatch executes large function from WS but catches a panic.
\ The errCode is returned (or 0 if no error).
\ Note: caches and restores ep, call stack and local stack state. Working stack
\ is cleared besides the returned err.
#09 =D_xCatch
#0A =D_memSet  \ {dst v len} "dst = v [len]". FT: memset, SR: memmove
#0B =D_memCmp  \ {&a &b len} -> I32: <0 if a<b; >0 if a>b; 0 if a==b
#0C =D_com     \ {&msg len} -> {ioResult}: write to debug stream
#0D =D_zoa     \ {} -> {} parse zoa to heap
#0E =D_dictDump\ {<dict-args> [&entry]} dump a dictionary FT=entry SR=full
#0F =D_comZoab \ FT{U4}  SR{len &data join}
#10 =D_comDone \ signifies end of one com. On linux this is a flush.

\ **********
\ * [3] Constants
#0  =FALSE
#1  =TRUE
#4  =ASIZE \ size of an absolute pointer
@ASIZE ^INC =DICT_OLEN \ dict name len offset
#30 =SZ_MASK \ size bit mask (for instr and meta)

\ * [3.a] Dict Ty Bits (meta byte):  TTXX XXXX T=TY_MASK
#40 =KEY_HAS_TY \ in len byte, not meta. If 1, dict entry is a non-constant.
#C0 =META_TY_MASK \ upper three bits determine type
#40 =TY_FN      \ function, can be called and has an fnMeta
#80 =TY_VAR     \ variable (local, global, struct field, etc). Has varMeta
#C0 =TY_DICT    \ a "dictionary" type which has dictMeta.
#FF_FFFF =REF_MASK
#FF_0000 =MOD_MASK

\ FN meta bits [TTPL FF--] L=locals F=fnTy P=pre
#20 =TY_FN_PRE     \ Compile next token first. Creates pre-order arguments.
#10 =TY_FN_LARGE   \ large, has locals (called with XL or XW)

#0C =TY_FN_TY_MASK \ 4 function types
#00 =TY_FN_NORMAL  \ Normally compiled, can use $ to make NOW
#04 =TY_FN_NOW     \ Required to be run as NOW (must use $)
#08 =TY_FN_SYN     \ (syntactical) always run now (knowing asNow)

\ Local meta bits  [TTTI RRSS] I=input R=ref S=szI
\ Local meta bits  [TTSS RR-I] I=input R=ref S=szI
\ Global meta bits [TTSS RR--]         R=ref S=szI
#01 =TY_VAR_INPUT
#0C =TY_VAR_REF

\ * [3.b] Zoab
#C0 =ZOAB_TY   \ bitmask: all types
#80 =ZOAB_JOIN \ bitmask: join type
#40 =ZOAB_ARR  \ bitmask: arr type
#C0 =ZOAB_PTR  \ equality: next 4 bytes are a pointer.

\ * [3.c] Log Levels
#00 =LOG_SILENT

\ Log Levels
#10 =LOG_USER
#1F =LOG_TRACE
#17 =LOG_DEBUG
#13 =LOG_INFO
#11 =LOG_WARN
#10 =LOG_CRIT

\ Language Level (builtin) Logs
#27 =LOG_INSTR
#23 =LOG_EXECUTE
#21 =LOG_ASM
#20 =LOG_COMPILER

\ * [3.d] Errors
\ [E000 - E100): built-in errors.
\  E100: device-specific hardware errors
\ [E200-E800): reserved
\  E800+: application errors
\  AXXX_EXXX: test case assertion error.

#0     =E_ok      \ no error
#E000  =E_general \ general errors [E000-E010)
#E010  =E_io      \ IO error class
#E0A0  =E_asm     \ assembly error class (cause in asm).
#E0C0  =E_comp    \ compiler error class (cause in comp).
#A000  =E_test    \ [AXXX] (assert) test case error.

#E001  =E_intern  \ internal (undefined) error
#E002  =E_undef   \ undefined error
#E003  =E_unreach \ unreachable code
#E004  =E_todo    \ executed incomplete (to do) code
#E005  =E_wsEmpty \ the WS was expected empty
#E006  =E_unimpl  \ unimplemented error

#E0A1  =E_null    \ null access
#E0A2  =E_oob     \ out of bounds access
#E0A3  =E_stkUnd  \ Stack underflow
#E0A4  =E_stkOvr  \ Stack overflow
#E0A5  =E_align2  \ access off 2byte allign
#E0A6  =E_align4  \ access off 4byte align
#E0A7  =E_divZero \ divide by zero

#E0C1  =E_cInstr  \ invalid instr
#E0C2  =E_cToken  \ token invalid
#E0C3  =E_cTLen   \ token invalid
#E0C4  =E_cKey    \ key already exists
#E0C5  =E_cNoKey  \ dict key not found
#E0C6  =E_cHex    \ non-hex number
#E0C7  =E_cSz     \ invalid Sz selected
#E0C8  =E_cSzPtr  \ invalid Sz for aptr
#E0C9  =E_cRet    \ invalid RET
#E0CA  =E_cDblSr  \ Double store
#E0CB  =E_cDevOp  \ device op not impl
#E0CC  =E_DictOvr \ dict overflow
#E0CD  =E_cXHasL  \ small-execute to fn w/locals
#E0CE  =E_cXNoL   \ large-execute to fn wo/locals
#E0CF  =E_cErr    \ D_assert err code invalid
#E0D0  =E_cKeyLen \ Key len too large
#E0D1  =E_cReg    \ Register error
#E0D2  =E_cStr    \ Str invalid

#E0E0  =E_cNotGlobal \ using a non-global as global
#E0E1  =E_cIsX       \ using an XS for an X
#E0E2  =E_cIsXS      \ using an X for an XS
#E0E3  =E_cJmpL1     \ JMP1 over too much space
#E0E4  =E_cNotFn
#E0E5  =E_cNotFnLarge
#E0E6  =E_cMod       \ different modules
#E0E7  =E_cLSz       \ literal sz
#E0E9  =E_cNotType
#E0EA  =E_cNotLocal
#E0EB  =E_cNotVar
#E0EC  =E_cNotFnOrConst
#E0ED  =E_eof
#E0EE  =E_cUnclosed   \ unclosed paren/brace/etc
#E0EF  =E_cReqNow     \ fn is NOW but no '$' used
#E0EF  =E_cNoNow      \ fn is SYN and requires no $ used.
#E0F0  =E_cUnknownEsc \ unknown character escape
#E0F1  =E_cZoab       \ Zoab invalid
#E0F2  =E_cNeedToken  \ token not present
#E0F3  =E_cNeedNumber \ number not present
#E0F4  =E_cBadRefs    \ too many de/refs
#E0F5  =E_cRefEq      \ .&var = not allowed.

#E0B0  =E_iBlock      \ invalid block index
#E0B1  =E_ptrBlk      \ invalid block ptr
#E0B2  =E_aaPo2       \ invalid po2

\ **********
\ * [4] Globals: many of these must be the same as in spor.c
#0000_0004 =heap
#0000_0008 =topHeap
#0000_000C =topMem
#0000_0010 =err      \ U2
#0000_0012 =c_state  \ U2
\ #0000_0014 =_unimpl1
\ #0000_0018 =_unimpl2
#0000_001C =sysLogLvl
#0000_001E =usrLogLvl

\ Dictionary Struct
#0000_0020 =c_gdictRef   \ U4
#0000_0024 =c_gdictLen   \ U2
#0000_0026 =c_gdictCap   \ U2

#0000_0028 =c_ldictRef  \ U4
#0000_002C =c_ldictLen  \ U2
#0000_002E =c_ldictCap  \ U2

\ TokenBuf Struct
#0000_0030 =c_tokenBuf   \ [APtr] TokenBuf struct
#0000_0034 =c_tokenLen   \ [U2] length of token
#0000_0036 =c_tokenSize  \ [U2] characters buffered
#0000_0038 =c_tokenGroup \ [U1] token group

\ Global Error Variables
#0000_003C =c_errValTy     \ [U1] + 3align
#0000_0040 =c_dataASz      \ [U2]
#0000_0042 =c_dataBSz      \ [U2]
#0000_0044 =c_errVal1      \ [U4]
#0000_0048 =c_errVal2      \ [U4]
#0000_004C =c_msg          \ [APtr]

\ Block allocator (12 bytes, see fngi.fn)
#0000_0050 =BA_kernel

\ Global Compiler Variables
#0000_005C =c_gkey         \ [U4] current gdict &key
#0000_0060 =c_lkey         \ [U4] current ldict &key
#0000_0064 =c_gheap        \ [U4] global heap
#0000_0068 =c_localOffset  \ [U2] Local Offset (for local var setup)

#00  =ERR_DATA_NONE
#01  =ERR_DATA_INT1
#02  =ERR_DATA_DATA1
#03  =ERR_DATA_INT2
#04  =ERR_DATA_DATA2

\ **********
\ * [5] Bootstrap Macros
\ These macros must be defined in pure ASM. They build on eachother
\ to make the syntax much more readable.
\
\   fn select [a b s -> a|b]      : a if s else b
\   fn h1 [U1] -> []              : push 1 byte to heap
\   fn h2 [U2] -> []              : push 2 byte to heap
\   fn h4 [U4] -> []              : push 4 byte to heap
\   fn L0 [U1] -> []              : compile a small literal [#0 - #3F]
\   fn $gdictGet <key>  [-> U4]   : get dictionary key's value
\   fn $gdictGetK <key> [-> APtr] : get the key's &key
\   fn $loc <token> []            : set token to the current heap location
\
\ Assertions: these panic with the supplied errCode if cond is not met.
\   assert [cond errCode]
\   assertNot [cond errCode]
\
\ Test Assertions: these panic with E_test if the cond is not met.
\   tAssert, tAssertNot, tAssertEq

=_h  .A%FTGL @heap.2,  %RET \ { -> heap} get the heap

$_h =select \ {a b s -> a|b} a if s else b
  .1%JZL #3.1, %DRP %RET \ if(s) ret a
  %SWP %DRP %RET         \ ret b
@INC2 @INC4  @ASIZE #2 ^EQ  $select =INCA
@SZ2 @SZ4    @ASIZE #2 ^EQ  $select =SZA
#1   #2      @ASIZE #2 ^EQ  $select =APO2

$_h =h1  \ h1: {val:1} push 1bytes from stack to heap
  .A%FTGL @heap.2, .1%SR    \ store 1 byte value at heap
  .A%FTGL @heap.2,  %INC  .A%SRGL @heap.2, \ heap=heap+1
  %RET

$_h =L0   \ L0: compile a small literal (unchecked)
  .1%LIT  #3F, %MSK \ truncated to bottom 6 bits
  .1%LIT  @SLIT,
  %JN     .2%JMPL @h1, \ made into SLIT instr and stored.

$_h =srBE2 \ {val addr} store a value at addr encoded BE2 (big-endian 2)
  %OVR #48.1, %SHR \ {val addr val>>8} note: #48 is SLIT(8)
  %OVR .1%SR       \ store upper byte {val addr}
  %INC .1%SR %RET  \ {} store lower byte

$_h =srBE4 \ {val addr} store a value at addr encoded BE4 (big-endian 4)
  %OVR #50.1, %SHR \ {val addr val>>16} note: #50 is SLIT(16)
  %OVR .2%XSL @srBE2,   \ handle the large bytes (1 & 2)
  %INC2 .2%JMPL @srBE2, \ small bytes            (3 & 4)

$_h =h2  \ h2: {val:2} push 2bytes from stack to heap
  .A%FTGL @heap.2, .2%XSL @srBE2.2, \ store value at heap
  .A%FTGL @heap.2, \ {heap}
  %INC2   .A%SRGL   @heap.2,   \ heap=heap+2
  %RET

$_h =h4  \ h4: {val:4} push 4bytes from stack to heap
  .A%FTGL @heap.2, .2%XSL @srBE4.2, \ store value at heap
  .A%FTGL @heap.2,  %INC4     .A%SRGL @heap.2, \ heap=heap+4
  %RET

$_h =gdictArgs \ [ -> &buf &len isLocal] args for dict.
  .2%LIT @c_gdictRef$h2 %RET \ TODO: add R_GB to it.

$_h =_dict
  @D_scan$L0  %DVFT .2%JMPL @gdictArgs$h2

\ TODO: remove
$_h =gdictSet \ gdictSet: Set "global" dictionary to next token.
  .2%XSL @_dict $h2  @D_dict$L0   %DVSR  \ set dict key
  .A%FTGL @c_gdictRef$h2  .2%FTGL @c_gdictLen$h2
    %ADD  .A%SRGL @c_ldictRef$h2 \ ldictRef = gdictRef + gdictLen
  #0$L0 .2%SRGL @c_ldictLen$h2   \ ldictLen = 0
  .2%FTGL @c_gdictCap$h2  .2%FTGL @c_gdictLen$h2
    %SUB  .2%SRGL @c_ldictCap$h2 \ ldictCap = gdictCap - gdictLen
  #0$L0 .2%SRGL @c_localOffset$h2 %RET

$_h =gdictGet \ gdictGet: Get the value of the next token.
  .2%XSL @_dict$h2   @D_dict$L0   %DVFT  %RET

$_h =gdictGetK \ gdictGetK: Get the &key of the next token.
  .2%XSL @_dict$h2   @D_dictK$L0   %DVFT  %RET

$_h =loc \ $loc <name>: define location
  .A%FTGL @heap$h2
  .2%XSL @_dict $h2  @D_dict$L0   %DVSR  \ set dict key
  .A%FTGL @c_gdictRef$h2  .2%FTGL @c_gdictLen$h2
    %ADD  .A%SRGL @c_ldictRef$h2 \ ldictRef = gdictRef + gdictLen
  #0$L0 .2%SRGL @c_ldictLen$h2   \ ldictLen = 0
  .2%FTGL @c_gdictCap$h2  .2%FTGL @c_gdictLen$h2
    %SUB  .2%SRGL @c_ldictCap$h2 \ ldictCap = gdictCap - gdictLen
  #0$L0 .2%SRGL @c_localOffset$h2 %RET

\ Assert checks a condition or panics with an error
\ ex: <some check> @E_myError assert
$loc assertNot \ {failIfTrue errCode}
  %SWP %NOT %SWP \ fallthrough
$loc assert    \ {failIfFalse errCode}
  @D_assert$L0     %DVFT  %RET

$loc tAssert
        .2%LIT @E_test $h2
  %JMPL @assert $h2

$loc tAssertNot  %NOT .2%JMPL @tAssert,
$loc tAssertEq \ {a b}
   @ERR_DATA_INT2$L0  .1%SRGL @c_errValTy$h2
        .A%SRGL @c_errVal2$h2 \ b {a}
   %DUP .A%SRGL @c_errVal1$h2 \ a {a}
        .A%FTGL @c_errVal2$h2 \ {a b}
  %EQ   .2%JMPL @tAssert,

\ **********
\ * [6] Core functions and macros
\ These are the bread and butter of spor assembly needed to create the fngi compiler.
\ They define and call functions, check the type of dictionary entries,
\ provide local dictionary support, etc.
\
\ fn $xsl  <token>                : compile execute small function
\ fn $xl   <token>                : compile execute large function
\ fn $jmpl <token>                : compile jump to small function
\ fn L1 / L2 / L4 / LA  [U] -> [] : compile 1 / 2 / 4 / ASIZE byte literal.
\ fn xCatch [... &fn]             : execute a large function and catch error.
\ fn retz  [a]                    : return immediately if not a  (     %RETZ)
\ fn retif [a]                    : return immediately if a      (%NOT %RETZ)
\ fn reteq [a b]                  : return immediately if a == b (%NEQ %RETZ)
\
\ fn FN <name>                    : declare a function
\ fn PRE                          : make function "pre" (run after next token)
\ fn SYN                          : make function "syn" (syntax, always now)
\ fn NOW                          : require function to be "now" (use $)
\ fn LARGE                        : make function large (has locals)
\
\ fn $c1 [instr]                  : NOW to compile instr when executed
\ fn keyMeta [&key] -> [meta]     : get meta of key
\ fn isTyped     [&key] -> [U]    : &key has a type (is not const)
\ fn isTyFn      [&key] -> [U1]   : &key is a fn
\ fn isFnLarge   [&key] -> [U1]   : &key is a large fn (has locals)
\ fn isFnPre     ...
\ fn isFnNormal  ...
\ fn isFnNow     ...
\ fn isFnSyn     ...
\ fn isTyVar [&key -> U1]      : is a local offset
\ fn isTyVarInput [&key -> U1] : is a local offset input
\
\ fn toMod [ref -> mod]           : get the "module" (upper byte of U4)
\ fn curMod [ -> mod]             : get the module of the last dict entry
\ fn isCurMod [ref -> mod]        : get whether ref is curMod
\
\ fn panic [errCode]              : instantly panic with error
\ fn unreach []                   : instantly panic with E_unreach
\ fn assertWsEmpty []             : assert the working stack is empty (E_wsEmpty)
\ fn assertNoNow [asNow]          : used by SYN to assert not called with $
\ fn assertCurMod [ref]           : assert ref is cur mod
\ fn assertNotNull [&r]           : E_null if r is NULL
\ fn assertTyped [&key]           :
\ fn assertFnSmall [&key]         : assert fn is small (no locals)
\ fn assertFnLarge [&key]         : assert fn is large (has locals)
\
\ fn c_updateGkey [ -> &key]      : update gkey=dictLen and return it
\ fn ldictRef / ldictArgs / ldictLen  : interface directly with local dict
\ fn ldictSet / ldictGet / ldictGetK  : set/get/get-ref of local dict key
\ fn c_keySetTyped [&key]                    : make a key non-global
\ fn c_makeTy <token> [<dictArgs> meta]      : make token be typed meta
\ fn c_dictSetMeta [<dictArgs> meta:U1 &key] : update dict key meta
\
\ Note: any SYN function must be prefixed with asNow (typically #0)
\ since it will not be tagged as SYN until c_makeFn.

$loc _j2 \ {ref instr} compile jmpInstr to 2 byte ref
  .2%XSL @h1 $h2      \ compile instr {ref}
  .2%JMPL @h2 $h2     \ compile addr

$loc _xsl \ $_xsl <token> : compile unchecked xsl
  .2%XSL @gdictGet $h2 \ {key}
  .1%LIT @XSL2 $h1  \ push .2%XSL instr
  .2%JMPL @_j2 $h2

$loc _jmpl \ $_jmpl <token>: compile unchecked jmpl
  $_xsl gdictGet             \ {key}
  .1%LIT @JMPL2 $h1 \ push .2%JMPL instr
  .2%JMPL @_j2 $h2

$loc L1 \ {U1} compile 1 byte literal
  .1%LIT  @SZ1 @LIT ^JN   $h1 \ push .1%LIT instr
  $_xsl h1 \ compile it
  $_jmpl h1

\ NOW PRE $c1: {instr:U1}
\ Compiles code so that when executed the instr will be compiled.
$loc c1
  $_xsl L1    \ compile the instr literal itself
  \ compile xsl to h1
  .2%LIT @h1 $h2
  .2%LIT @XSL2 $h2
  $_jmpl _j2

$loc L2 \ {U2} compile 2 byte literal
  @SZ2 @LIT  ^JN   $c1  \ compile .2%LIT instr
  $_jmpl h2  \ compile the 2 byte literal

$loc L4 \ {U4} compile 4 byte literal
  @SZ4 @LIT  ^JN   $c1 \ compile .4%LIT
  $_jmpl h4  \ compile the 4 byte literal

@L2 @L4    @ASIZE #2 ^EQ  $select =LA \ {UA} comipile ASIZE literal

$loc keyMeta \ SYN {&key -> meta}
  .1%JZL #4$h1 %INCA .1%FT %RET \ if(asNow) get it
  @INCA $c1
  @SZ1 @FT ^JN  $c1 %RET

$loc isTyped  \ {&key} dict value is a constant
  %DUP @E_cNoKey$L2 $_xsl assert \ no key if &key=NULL
  @DICT_OLEN$L0 %ADD .1%FT @KEY_HAS_TY$L1 %MSK %RET

\ These take {&key} and tell information about it
$loc isTyFn      #0$keyMeta  @META_TY_MASK$L1 %MSK  @TY_FN$L1  %EQ %RET
$loc isFnLarge   #0$keyMeta  @TY_FN_LARGE$L1 %MSK %RET
$loc assertNotNull @E_null$L2 $_jmpl assert

$loc assertTyped \ [&key]
  %DUP @E_cKey$L2 $_xsl assert \ assert key was found
  $_xsl isTyped @E_cNotType $L2 $_jmpl assert
$loc assertFn   $_xsl isTyFn  @E_cNotFn $L2  $_jmpl assert \ [&key] -> []

$loc assertFnSmall \ [&key]
  %DUP $_xsl assertFn
  $_xsl isFnLarge  @E_cIsX $L2  $_jmpl assertNot

$loc assertFnLarge \ [&key]
  %DUP $_xsl assertFn
  $_xsl isFnLarge  @E_cIsX $L2  $_jmpl assert

$loc toMod @MOD_MASK $L4 %MSK %RET \ {ref} -> {mod}
$loc isSameMod \ {ref ref} -> {sameMod}
  $_xsl toMod  %SWP  $_xsl toMod  %EQ %RET

$loc curMod   .2%FTGL @c_gkey$h2 .A%FT  $_jmpl toMod \ [] -> [mod]
$loc isCurMod $_xsl toMod  $_xsl curMod %EQ %RET     \ [ref] -> [isCurMod]
$loc assertCurMod  $_xsl isCurMod  @E_cMod$L2  $_jmpl assert

$loc _jSetup \ [&key] -> [ref]: checked jmp setup
  %DUP $_xsl assertTyped
  %DUP $_xsl assertFnSmall
  .A%FT %DUP $_jmpl assertCurMod \ {ref}

$loc  assertNoNow @E_cNoNow$L2 $_jmpl assertNot   \ {asNow} -> {}

$loc xsl \ $xsl <token> : compile .2%xsl
  $_xsl gdictGetK $_xsl _jSetup \ {ref}
  @XSL2 $L1 $_jmpl _j2

$loc xl \ $xl <token> : compile .2%xl
  $_xsl gdictGetK \ {&key}
  %DUP $_xsl assertFnLarge
  .A%FT %DUP $_xsl assertCurMod
  @SZ2 @XL ^JN   $L1  $_jmpl _j2

$loc jmpl  \ $jmpl <token> : compile jmpl2
  $_xsl gdictGetK $_xsl _jSetup \ {ref}
  @JMPL2$L1  $_jmpl _j2

$loc c_updateGkey \ [] -> [&key] update and return current key
  .A%FTGL @c_gdictRef$h2 \ dict.buf
  .2%FTGL @c_gdictLen$h2 \ dict.heap
  %ADD \ {&newKey}
  %DUP .A%SRGL @c_gkey$h2 \ gkey=newKey
  %RET \ return &key
$loc locK $_xsl c_updateGkey $_jmpl loc \ { <token> -> &key} def loc, ret &key

$loc c_keyJnMeta \ {&key meta:U1} -> U4 : apply meta to &key
  %OVR %INCA \ {... &key newmeta &meta} note: #0 for unregistered SYN
  .1%FT %JN    \ {&key newMeta}
  %SWP %INCA .1%SR \ update meta
  %RET

$loc c_keySetTyped \ {&key} -> []
  @DICT_OLEN$L0 %ADD %DUP   \ {&len &len}
  .1%FT @KEY_HAS_TY$L1 %JN  \ {&len tyKeyLen}
  %SWP .1%SR %RET           \ update tyKeyLen

$loc c_dictSetMeta \ {<dictArgs> meta:U1 &key} update dict key's meta.
  %SWP %OVR \ {<dictArgs> &key meta &key}
  %DUP $_xsl c_keySetTyped \ make key "typed" {<dictArgs> &key meta &key}
  %SWP $_xsl c_keyJnMeta \ {<dictArgs> &key}
  @D_dictDump$L0 %DVFT %RET \ dict dump entry


$loc _declFn \ [<dictArgs> meta]
  @TY_FN$L1 %JN  \ {<dictArgs> meta}
  $_xsl locK  $_jmpl c_dictSetMeta

\ example: $FN <token> $SYN $LARGE: declare a function with attributes.
$loc assertWsEmpty   @D_wslen$L0 %DVFT  @E_wsEmpty $L2  $_jmpl assertNot
$loc FN      $_xsl assertNoNow $_xsl assertWsEmpty $_xsl gdictArgs #0$L0 $_jmpl _declFn
$loc SYN     %DRP .A%FTGL @c_gkey$h2  @TY_FN_SYN$L1   $_jmpl c_keyJnMeta
$loc NOW     %DRP .A%FTGL @c_gkey$h2  @TY_FN_NOW$L1   $_jmpl c_keyJnMeta
$loc LARGE   %DRP .A%FTGL @c_gkey$h2  @TY_FN_LARGE$L1 $_jmpl c_keyJnMeta

\ Backfill the fn meta
$loc c_makeTy \ {<dictArgs> meta} make an existing symbol a type.
  $_xsl gdictGetK   \ {meta &key}
  $_jmpl c_dictSetMeta

\ {{meta} <token>}: set meta for token to be a small function.
#0$FN c_makeFn #0$LARGE \ note: asNow=#0 for SYN
  #1$h1  \ locals: 0=meta:U1
  .1%SRLL#0$h1  $_xsl gdictArgs .1%FTLL#0$h1 \ {<dictArgs> meta}
  @TY_FN$L1 %JN   $_jmpl c_makeTy

$loc PRE %DRP .A%FTGL @c_gkey$h2  @TY_FN_PRE$L1   $_jmpl c_keyJnMeta

#0 $c_makeFn xsl    #0 $c_makeFn loc   #0 $c_makeFn xl
@TY_FN_NOW $c_makeFn jmpl  @TY_FN_PRE $c_makeFn select
@TY_FN_SYN $c_makeFn FN
#0 $c_makeFn assertWsEmpty
@TY_FN_SYN $c_makeFn PRE   @TY_FN_SYN $c_makeFn SYN
@TY_FN_SYN $c_makeFn NOW   @TY_FN_SYN $c_makeFn LARGE
@TY_FN_PRE $c_makeFn L0    @TY_FN_PRE $c_makeFn L1
@TY_FN_PRE $c_makeFn L2    @TY_FN_PRE $c_makeFn L4
@TY_FN_PRE $c_makeFn LA
@TY_FN_PRE $c_makeFn h1    @TY_FN_PRE $c_makeFn h2
@TY_FN_PRE $c_makeFn h4
@TY_FN_PRE @TY_FN_NOW ^JN  $c_makeFn c1
#0 $c_makeFn gdictSet
#0 $c_makeFn gdictGet        #0 $c_makeFn gdictGetK
#0 $c_makeFn gdictArgs
@TY_FN_PRE $c_makeFn toMod  #0 $c_makeFn curMod   @TY_FN_PRE
@TY_FN_PRE @TY_FN_SYN ^ADD $c_makeFn keyMeta
$c_makeFn isTyped                @TY_FN_PRE $c_makeFn isTyFn
@TY_FN_PRE $c_makeFn isSameMod   @TY_FN_PRE $c_makeFn isCurMod
@TY_FN_PRE $c_makeFn isFnLarge
#0 $c_makeFn c_updateGkey           #0 $c_makeFn locK
@TY_FN_PRE $c_makeFn c_keySetTyped  @TY_FN_PRE $c_makeFn c_keyJnMeta
@TY_FN_PRE $c_makeFn c_dictSetMeta
#0 $c_makeFn c_makeTy
@TY_FN_PRE $c_makeFn assert         @TY_FN_PRE $c_makeFn assertNot
@TY_FN_PRE $c_makeFn assertNotNull  @TY_FN_PRE $c_makeFn tAssert
@TY_FN_PRE $c_makeFn tAssertNot     @TY_FN_PRE $c_makeFn tAssertEq
@TY_FN_PRE $c_makeFn assertFn       @TY_FN_PRE $c_makeFn assertFnSmall
@TY_FN_PRE $c_makeFn assertFnLarge  @TY_FN_PRE $c_makeFn assertCurMod
@TY_FN_PRE $c_makeFn assertTyped    @TY_FN_PRE $c_makeFn assertNoNow

$FN isFnPre     $PRE $keyMeta  @TY_FN_PRE$L1     %MSK %RET
$FN isVarInput  $PRE $keyMeta  @TY_VAR_INPUT$L1  %MSK %RET
$FN isFnNormal  $PRE $keyMeta  @TY_FN_TY_MASK$L1 %MSK  @TY_FN_NORMAL$L1 %EQ %RET
$FN isFnNow     $PRE $keyMeta  @TY_FN_TY_MASK$L1 %MSK  @TY_FN_NOW$L1    %EQ %RET
$FN isFnSyn     $PRE $keyMeta  @TY_FN_TY_MASK$L1 %MSK  @TY_FN_SYN$L1    %EQ %RET
$FN isTyVar     $PRE $keyMeta  @META_TY_MASK$L1  %MSK  @TY_VAR$L1       %EQ %RET
$FN assertTyVar $PRE $xsl isTyVar  @E_cNotLocal$L2 $jmpl assert

$FN c_scan        @D_scan$L0   %DVFT %RET
$FN panic   $PRE #0$L0 %SWP  $jmpl assert \ {errCode}: panic with errCode
$FN unreach      @E_unreach$L2 $jmpl panic \ {}: assert unreachable code
$FN unimplIfTrue $PRE @E_unimpl$L2 $jmpl assert \ {}: if true raise unimpl
$FN assertLt128    $PRE #80 $L1 %LT_U  @E_cJmpL1 $L2   $jmpl assert
$FN tAssertKeyMeta $PRE %SWP $keyMeta %SWP $_jmpl tAssertEq \ {&key meta}

$FN assertSzI $PRE \ {szI}
  %DUP #CF$L1 %MSK @E_cSz$L2 $xsl assertNot \ non-sz bits empty
  #4$L0 %SHR #3$L1 %LT_U @E_cSz$L2 $jmpl assert \ sz bits < 3

$FN ftoN $NOW  \ {offset szI} compile FTO szI w/offset
  %DUP $xsl assertSzI  @FTO$L1 %ADD $xsl h1 $jmpl h1

\ Update the harness with the new dictionary
$FN c_dictDump       $xsl gdictArgs @D_dictDump$L0 %DVSR %RET \ {}
$c_dictDump

$FN ldictArgs \ {} -> dictArgs
  @c_ldictRef$L2 %RET \ TODO: add R_GB to it.

$FN _ldict $xsl c_scan $jmpl ldictArgs
$FN ldictGet   $xsl _ldict @D_dict$L0  %DVFT %RET
$FN ldictSet   $PRE $xsl _ldict @D_dict$L0  %DVSR %RET
$FN ldictGetK  $xsl _ldict @D_dictK$L0 %DVFT %RET
$FN retz  $PRE $SYN $xsl assertNoNow @RETZ$c1 %RET
$FN reteq $PRE $SYN $xsl assertNoNow @NEQ$c1 @RETZ$c1 %RET
$FN retif $PRE $SYN $xsl assertNoNow @NOT$c1 @RETZ$c1 %RET

\ **********
\ * [7] ASM (initial) Flow Control
\ Flow control either pushes the current heap on the WS or uses a local
\ constant. END/AGAIN uses this heap-val/local to do the right thing.
\
\   if/else: $IF ... $ELSE ... $END
\   loop:    $LOOP <l0> ... $BREAK0 <b0> ... $AGAIN <l0> $BREAK_END <b0>
$FN IF  $PRE $SYN $xsl assertNoNow \ {} -> {&jmpTo} : start an if block
  @SZ1 @JZL  ^JN   $c1 \ compile .1%JZL instr
  .A%FTGL @heap$h2 \ {&jmpTo} push &jmpTo location to stack
  #0$L0  $xsl h1 \ compile 0 (jump pad)
  %RET

$FN _END $PRE \ {&jmpTo} end of IF
  %DUP          \ {&jmpTo &jmpTo}
  .A%FTGL @heap$h2  \ {&jmpTo &jmpTo heap}
  %SWP %SUB     \ {&jmpTo (heap-&jmpTo)}
  %DUP $xsl assertLt128
  %SWP .1%SR %RET \ store at location after start (1 byte literal)
$FN END $SYN $xsl assertNoNow $jmpl _END  \ {&jmpTo} -> {} : end of IF or BREAK0

$FN ELSE $SYN $xsl assertNoNow \ {&ifNotJmpTo} -> {&elseBlockJmpTo}
  @JMPL $c1         \ (end IF) compile unconditional jmp to end of ELSE
  .A%FTGL @heap$h2 %SWP \ {&elseBlockJmpTo &ifNotJmpTo}
  #0$L0 $xsl h1     \ compile jmp lit for &elseBlockJmpTo
  $jmpl _END        \ end of IF block (beginning of ELSE)

\ $LOOP l0 ... $BREAK0 b0 ... $AGAIN l0  $BREAK_END b0
$FN LOOP   $SYN $xsl assertNoNow .A%FTGL @heap$h2  $jmpl ldictSet
$FN BREAK0 $PRE $SYN   $xsl IF $jmpl ldictSet
$FN BREAK_IF  $PRE $SYN @NOT$c1  $jmpl BREAK0 \ break if true
$FN BREAK_EQ  $PRE $SYN @NEQ$c1  $jmpl BREAK0 \ break if equal
$FN BREAK_NEQ $PRE $SYN @EQ$c1  $jmpl BREAK0 \ break if equal
$FN AGAIN $SYN $xsl assertNoNow
  @JMPL $c1  \ compile jmp
  .A%FTGL @heap$h2  \ {heap}
  $xsl ldictGet \ {heap &loopTo}
  %SUB     \ {heap-&loopTo}
  %DUP $xsl assertLt128
  %NEG          \ make negative for backwards jmp
  $jmpl h1      \ compile as jmp offset

$FN END_BREAK $SYN $xsl assertNoNow $xsl ldictGet $jmpl _END

$FN END_N $PRE $SYN $xsl assertNoNow \ {...(N &jmpTo) numJmpTo}
  $LOOP l0 %DUP %RETZ
    %SWP #0$L0 $xsl _END
    %DEC \ dec numJmpTo
  $AGAIN l0

\ **********
\ * [8] Scanning and Alignment Utilities
\ Reading, peeking and szI alignment
\
\ fn align [aptr sz -> aptr]      : align aptr with sz bytes
\ fn align4 [aptr -> aptr]        : align aptr with 4 bytes
\ fn alignSzI [aptr szI -> aptr]  : align aptr with szI bytes
\ fn hN [U4 szI]                  : write a value of szI to heap (no align)
\ fn szToSzI [U4 -> SzI]          : convert number of bytes to SzI
\ fn szIToSz [SzI -> U1]          : convert szI to number of bytes
\
\ fn dictK [-> &key isFromLocal]  : any ref to current token.
\ fn c_read [ -> numRead]         : attempt to read bytes from src.
\ fn c_readNew [ -> numRead]      : clear token buf and read bytes.
\ fn c_scanNoEof []               : scan and assert not EOF.
\ fn c_peekChr [ -> c]            : peek at the next character.
\ fn c_clearToken []              : shift buffer to clear current token
\
\ fn assertSzI [szI]              : assert that szI is valid
\ fn c_isEof [ -> bool]           : return whether there was a token scanned
\ fn c_assertToken []             : assert there is a token
\ fn c_assertNoEof [numRead]      : assert that numRead > 0 (E_eof)

$FN keySzI $PRE $keyMeta @SZ_MASK$L1 %MSK %RET \ {&key -> szI}

$FN szIToSz $PRE \ {szI} -> {sz}
  %DUP @SZ1$L1 %EQ $IF  %DRP #1$L0 %RET  $END
  %DUP @SZ2$L1 %EQ $IF  %DRP #2$L0 %RET  $END
       @SZ4$L1 %EQ $IF       #4$L0 %RET  $END
  @E_cSz$L2 $xsl panic

$FN hN $PRE \ {value szI} write a value of szI to heap
  %DUP @SZ1$L1 %EQ $IF  %DRP $jmpl h1  $END
  %DUP @SZ2$L1 %EQ $IF  %DRP $jmpl h2  $END
  %DUP @SZ4$L1 %EQ $IF  %DRP $jmpl h4  $END
  @E_cSz$L2 $xsl panic

$FN szToSzI $PRE \ [sz] -> [SzI] convert sz to szI (instr)
  %DUP #1$L0 %EQ $IF  %DRP @SZ1 $L1 %RET  $END
  %DUP #2$L0 %EQ $IF  %DRP @SZ2 $L1 %RET  $END
       #4$L0 %EQ $IF  %DRP @SZ4 $L1 %RET  $END
  @E_cSz$L2 $xsl panic

$FN reqAlign $PRE \ {sz -> sz}: get required alignment
  %DUP @ASIZE$L0 %DEC %LT_U $retif  %DRP @ASIZE$L0 %RET

$FN align $LARGE $PRE \ {aptr sz -> aptr}: align aptr with sz bytes
  #1 $h1 \ locals [sz:U1]
  .1%SRLL#0$h1 \ cache sz
  %DUP \ {aptr aptr}
  .1%FTLL#0$h1 %MOD \ {aptr aptr%sz}
  %DUP $IF
    .1%FTLL#0$h1 %SWP %SUB \ {aptr (sz - aptr%sz)}
    %ADD %RET \ aptr + (sz - aptr%sz)
  $END
  %DRP %RET

$FN alignA $PRE $xsl reqAlign $xl align %RET \ {aptr sz -> aptr}: align to SZA
$FN align4 $PRE #4$L0 $xl align %RET \ {addr -> aligned4Addr}
$FN alignSzI $PRE $xsl szIToSz  $xl align  %RET \ {addr szI -> addrAlignedSzI}

$FN ftSzI \ {&addr szI}
  %DUP @SZ1$L1 %EQ $IF %DRP .1%FT %RET $END
  %DUP @SZ2$L1 %EQ $IF %DRP .2%FT %RET $END
       @SZ4$L1 %EQ $IF      .4%FT %RET $END
  @E_cSz$L2 $jmpl panic

$FN srSzI \ {value &addr szI}
  %DUP @SZ1$L1 %EQ $IF %DRP .1%SR %RET $END
  %DUP @SZ2$L1 %EQ $IF %DRP .2%SR %RET $END
       @SZ4$L1 %EQ $IF      .4%SR %RET $END
  @E_cSz$L2 $jmpl panic

$FN c_isEof .2%FTGL@c_tokenLen$h2 %NOT %RET
$FN c_assertToken .2%FTGL@c_tokenLen$h2 @E_cNeedToken$L2 $jmpl assert
$FN c_assertNoEof $PRE @E_eof$L2 $jmpl assert \ {numRead}

$FN c_scanNoEof
  $xsl c_scan
  $xsl c_isEof
  @E_eof$L2 $jmpl assertNot

$FN c_peekChr \ {} -> {c} peek at a character
  $xsl c_scan
  $xsl c_isEof $IF  #0$L0 %RET  $END
  .A%FTGL@c_tokenBuf$h2 .1%FT \ {c}
  #0$L0 .2%SRGL@c_tokenLen$h2 %RET \ reset scanner for next scan

$FN c_read \ { -> numRead} attempt to read bytes
  #1$L0 @D_read$L0 %DVFT %RET

$FN c_readNew \ { -> numRead} clear token buf and read bytes
  #0$L0 .2%SRGL@c_tokenLen$h2
  #0$L0 .2%SRGL@c_tokenSize$h2
  #1$L0 @D_read$L0 %DVFT %RET

$FN c_clearToken \ shift buffer to clear current token
  .A%FTGL@c_tokenBuf$h2                 \ {&tokenBuf}
  %DUP .2%FTGL@c_tokenLen$h2 %ADD \ {&tokenBuf &tokenEnd}
  .2%FTGL@c_tokenLen$h2           \ {&tokenBuf &tokenEnd tokenLen}
  @D_memSet$L0 %DVSR %RET  \ memMove

$FN dictK \ {} -> {&key isFromLocal}
  $xsl ldictArgs  @D_dictK$L0 %DVFT %DUP  $IF
    @TRUE$L1 %RET
  $END %DRP
  $xsl gdictArgs  @D_dictK$L0 %DVFT %DUP  $IF
    @FALSE$L0 %RET
  $END @E_cNotType$L2 $xsl panic

$FN c_updateLkey \ [] -> [&key] update and return current local key
  .A%FTGL @c_ldictRef$h2 \ dict.buf
  .2%FTGL @c_ldictLen$h2 \ dict.heap
  %ADD \ {&newLKey}
  %DUP .A%SRGL @c_lkey$h2 \ gkey=newKey
  %RET \ return &key

\ **********
\ * [9] Globals and Locals
\ We need a way to define global and local variables, as well as GET, SET and
\ obtain a REF to them.
\
\ fn GET <token>            SYN : compile a FT of token (local or global)
\ fn _SET <token>           SYN : compile a SR of token (local or global)
\ fn REF <token>            SYN : compile a "get ref" of token
\ fn LOCAL <token> [SzI]    SYN : define a local variable of szI
\ fn INPUT <token> [SzI]    SYN : define a local input variable of szI
\ fn declVar                    : declare a local/gloabl variable
\ fn declEnd                    : end locals declaration

$FN declG \ [<token> -> &key isLocal] create global and return it.
  $xsl locK
  %DUP $xsl c_keySetTyped
  %DUP @TY_VAR$L1 $xsl c_keyJnMeta \ {&key}
  @FALSE$L0 %RET \ {&key isLocal=FALSE}

$FN declL \ [<token> -> &key isLocal] create local and return it.
  $xsl c_updateLkey \ {&key}
  #0$L0 $xsl ldictSet \ initialize lDict token (to heap for now)
  %DUP $xsl c_keySetTyped
  %DUP @TY_VAR$L1 $xsl c_keyJnMeta \ {&key} update meta as local
  @TRUE$L0 %RET \ {&key isLocal=TRUE}

$FN declVar $LARGE $PRE \ {&key isLocal meta szBytes} declare a variable (global or local)
  #1$h1 .1%SRLL #0$h1  .1%SRLL #1$h1   .1%SRLL #2$h1 \ Locals 0=szBytes 1=meta 2=isLocal
  %DUP .1%FTLL #1$h1 $xsl c_keyJnMeta \ update key meta {&key}
  .1%FTLL #2$h1 $IF \ if(isLocal) {&key}
    .2%FTGL @c_localOffset$h2  .1%FTLL #0$h1  $xsl alignA \ {&key offsetAligned}
    %DUP .1%FTLL #0$h1 %ADD .2%SRGL @c_localOffset$h2 \ update c_localOffset {...}
  $ELSE
    .A%FTGL @c_gheap$h2        .1%FTLL #0$h1  $xsl alignA \ {&key gheapAligned}
    %DUP .1%FTLL #0$h1 %ADD .A%SRGL @c_gheap$h2       \ update gheap {...}
  $END %SWP .A%SR %RET \ update key's value

$FN _varSetup $PRE \ {&key} -> {&key} : checked local setup
  %DUP $_xsl assertTyped
  %DUP $_jmpl assertTyVar

\ {&key szInstr szLit instr} compile a literal memory instr.
\   szLit the size of the literal to compile for the instr.
\   oRef: either a reference or an offset
$FN c_instrLitImpl $PRE $LARGE
  #1 $h1 \ 1 slot [szLit:U1 instr:U1]
  .1%SRLL #1$h1 \ var instr          {&key szInstr szLit}
  .1%SRLL #0$h1 \ var szLit          {&key szInstr}
  .1%FTLL #1$h1 %JN  $xsl h1 \ compile (szInstr | instr) {&key}
  .A%FT \ {oRef} offset or reference
  .1%FTLL #0$h1  $jmpl hN \ compile literal of proper instrSz

\ Compile a get or set instruction.
\ Args:
\   &key: key to compile.
\   dotMeta: whether the value to compile is a local or global.
\   localInstrSz localInstr: if isFromLocal: use these as the literal sz and instr.
\   globalInstrSz globalInstr: if NOT isFromLocal: use these as the literal sz and instr.
$FN _getSetImpl $PRE $LARGE
  #1 $h1 \ locals (see below)
  .1%SRLL#3$h1   .1%SRLL#2$h1 \ 2=globalInstrSz 3=globalInstr
  .1%SRLL#1$h1   .1%SRLL#0$h1 \ 0=localInstrSz 1=localInstr
  \ {&key dotMeta}
  $IF
    $xsl _varSetup %DUP $xsl keySzI \ {&key szInstr}
    .1%FTLL#0$h1 .1%FTLL#1$h1
  $ELSE
    $xsl _varSetup %DUP $xsl keySzI \ {&key szInstr}
    .1%FTLL#2$h1 .1%FTLL#3$h1
  $END
  $xl c_instrLitImpl %RET

\ (create _xxxImpl for fngi to use)
$FN _getImpl $PRE \ {&key dotMeta}
  @SZ1$L1  @FTLL$L1  \ local sz + instr
  @SZ2$L1  @FTGL$L1  \ global sz + instr
  $xl _getSetImpl %RET

$FN _setImpl $PRE \ {&key dotMeta}
  @SZ1$L1  @SRLL$L1  \ local sz + instr
  @SZ2$L1  @SRGL$L1  \ global sz + instr
  $xl _getSetImpl %RET

$FN gRef $NOW \ [<token> -> &gref] get token's global reference
  $xsl gdictGetK  $xsl _varSetup .A%FT %RGFT @R_GB$h1 %ADD %RET

$FN _refImpl \ {}
  $xsl ldictArgs  @D_dictK$L0 %DVFT %DUP  $IF \ {&key}
    $xsl _varSetup \ {&key}
    .A%FT %DUP #40$L1 %LT_U @E_cReg$L2 $xsl assert \ {offset}
    @R_LP$L1 %JN  \ {LpOffset}: offset is lower 7 bits
    @RGFT$c1 $jmpl h1  \ compile: %RGFT (@R_LP + offset)$h1
  $END %DRP
  $xsl gdictArgs  @D_dictK$L0 %DVFT %DUP  $IF \ {&key}
    $xsl _varSetup  .A%FT $jmpl LA \ write literal directly TODO: use c_lit
  $END @E_cNotType$L2 $xsl panic

$FN REF  $SYN
  $IF \ asNow: we can get &fn or &global
    $xsl gdictGetK \ next: assert(isTyVar or isTyFn)
    %DUP $xsl assertTyped
      %DUP $xsl isTyVar %OVR $xsl isTyFn %OR
      @E_cNotType$L2 $xsl assert
    .A%FT %RET
  $END \ else: we can get &local or &global
  $xsl c_scan $jmpl _refImpl

$FN GET  $SYN
  $IF  $xsl gdictGetK $xsl _varSetup %DUP $xsl keySzI \ {&key szInstr}
       %SWP .A%FT %SWP $jmpl ftSzI   $END
  $xsl c_scan $xsl dictK $jmpl _getImpl

$FN _SET $SYN
  $xsl assertNoNow $xsl c_scan $xsl dictK $jmpl _setImpl

$FN c_makeGlobal $PRE \ {szI} <token>: set meta for token to be a global.
  $LARGE #1$h1 \ locals 0=szI:u1
  .1%SRLL#0$h1  $xsl gdictArgs .1%FTLL#0$h1 \ {<dictArgs> szI}
  @TY_VAR$L1  %JN   $_jmpl c_makeTy

@SZA $c_makeGlobal heap        @SZA $c_makeGlobal topHeap
@SZA $c_makeGlobal topMem      @SZ2 $c_makeGlobal err
@SZ2 $c_makeGlobal c_state
@SZ2 $c_makeGlobal sysLogLvl   @SZ2 $c_makeGlobal usrLogLvl
@SZA $c_makeGlobal c_gdictRef   @SZ2 $c_makeGlobal c_gdictLen
@SZ2 $c_makeGlobal c_gdictCap
@SZA $c_makeGlobal c_ldictRef   @SZ2 $c_makeGlobal c_ldictLen
@SZ2 $c_makeGlobal c_ldictCap
@SZA $c_makeGlobal c_tokenBuf  @SZ2 $c_makeGlobal c_tokenLen
@SZ2 $c_makeGlobal c_tokenSize @SZ1 $c_makeGlobal c_tokenGroup
@SZ1 $c_makeGlobal c_errValTy
@SZ2 $c_makeGlobal c_dataASz   @SZ2 $c_makeGlobal c_dataBSz
@SZA $c_makeGlobal c_errVal1   @SZA $c_makeGlobal c_errVal2
@SZA $c_makeGlobal c_msg
@SZA $c_makeGlobal BA_kernel

@SZA $c_makeGlobal c_gkey      @SZA $c_makeGlobal c_lkey
@SZA $c_makeGlobal c_gheap     @SZ2 $c_makeGlobal c_localOffset

\ **********
\ * Local Variables
\ implement LOCAL or INPUT. Mostly just updating ldict key and globals.

\ All of these take &key and output len (U1 len), sz (total key size), nextKey (&key)
$FN Dict_keyLen  $PRE @DICT_OLEN$L0 %ADD .1%FT #3F$L1 %MSK %RET
$FN Dict_keySz   $PRE $xsl Dict_keyLen @DICT_OLEN^INC$L0 %ADD $jmpl align4
$FN Dict_nextKey $PRE %DUP $xsl Dict_keySz %ADD %RET

\ {&key} -> {} recursive function to compile INPUTs
\ Inputs are "compiled" (i.e. a SRLL is compiled) in reverse order.
\ This maps them well to the conventional stack nomenclature.
$FN _compileInputs $PRE $LARGE
  #1$h1 \ locals 0=&key:APtr
  %DUP  .A%SRLL#0$h1 \ {&key} var key
  .A%FTGL @c_ldictRef$h2 .2%FTGL @c_ldictLen$h2 %ADD \ {&key &ldictEnd}
    $reteq \ return if key=ldictEnd
  .A%FTLL#0$h1  $xsl Dict_nextKey  $xl _compileInputs \ get the next key and recurse {}
  .A%FTLL#0$h1  %DUP $xsl isTyped %SWP \ {hasTy &key}
  %DUP $xsl isTyVar %SWP \ {hasTy isTyVar &key}
  $xsl isVarInput %AND %AND %RETZ \ {} all of (hasTy isTyVar isVarInput)
  .A%FTLL#0$h1  %DUP $xsl keySzI \ {&key szInstr}
  @SZ1$L1 @SRLL$L1 $xl c_instrLitImpl %RET

\ End locals declaration. Update FN slots and LARGE.
\ Compiles SRLL for each TY_VAR_INPUT, in reverse order.
$FN declEnd
  $GET c_localOffset $IF \ if localOffset: update fn to large
    $GET c_gkey @TY_FN_LARGE$L0 $xsl c_keyJnMeta
  $END
  $GET c_localOffset #4$L0 $xl align
  @APO2$L0 %SHR $xsl h1 \ update number of slots
  $GET c_ldictRef  $xl _compileInputs
  %RET

\ **********
\ * [10] Zoa strings and logging zoab
\ See ./harness.md for design reasoning.
\
\ fn $loc <name> |zoa string literal|    : define a zoa string
\
\ fn comzStart []                 : zoab start
\ fn comzArr [len join]           : start an array of len and join
\ fn comzLogStart [lvl extraLen]  : start a log arr of data len exraLen
\ fn print [len &raw]             : print raw data to the user (LOG_USER)
\ fn _printz [&z]                 : print zoab bytes (<=63) to the user
\ fn TODO: not finished

\ |zoa string literal|
\ Creates a zoa string in the heap.
$FN |
  $SYN $xsl assertNoNow
  $GET heap
  \ maxLen: (topHeap - heap)
  %DUP .A%FTGL@topHeap$h2 %SWP %SUB
  @D_zoa$L0 %DVFT .A%SRGL @heap$h2 %RET

$FN c_logAll $PRE \ {&writeStruct len &buf } Write raw data to log output
  $LARGE $declEnd \ no locals, but used in XW.
  %DRP
  $LOOP l0
    %OVR %OVR
    @D_com$L0 %DVFT
    %NOT $IF %DRP %DRP %RET $END
  $AGAIN l0

$FN ft4BE $PRE \ {&a -> U4} fetch4 unaligned big-endian
  %DUP%INC %DUP%INC %DUP%INC .1%FT \ {&a &a+1 &a+2                 a@3 }
  %SWP .1%FT #08$L0%SHL %ADD       \ {&a &a+1            (a@2<<8 + a@3)}
  %SWP .1%FT #10$L0%SHL %ADD       \ {&a       (a@1<<16 + a@2<<8 + a@3)}
  %SWP .1%FT #18$L0%SHL %ADD       \ {a@0<<24 + a@1<<16 + a@2<<8 + a@3 }
  %RET

$loc LOG_ZOAB_START  #80$h1 #03$h1
$FN comzStart  #2$L0 @LOG_ZOAB_START$LA  @D_com$L0 %DVSR %RET

$loc TODO #0$h1
$FN comzArr  $PRE \ {len join}
  $declL b0  @SZ1  #1 $declVar $declEnd \ b0 is used as an array for com
  \ $IF @ZOAB_JOIN$L1 $ELSE #0$L0 $END %SWP \ join -> joinTy       {joinTy len}
  \ %DUP #40$L1 %LT_U @E_cZoab$L2 $xsl assert \ assert len <= 0x3F {joinTy len}
  \ %JN  $_SET b0
  \ #33$L0 $REF b0 $jmpl com \ send via com

  %DRP \ ignore join TODO
  @ZOAB_ARR$L1 %JN  \ len->arrLen
  @TODO$L2 .1%SR \ store len @TODO
  #1$L0 @TODO$L2 @D_com$L0 %DVSR %RET \ {len &raw} communicate directly

$FN comzLogStart  $PRE \ {lvl extraLen}  extraLen is in addition to sending the lvl
  $xsl comzStart \ TODO: check return code once it's added
  %INC @FALSE$L0 $xl comzArr
  @D_comZoab$L0 %DVFT %RET \ send lvl

$FN print  $PRE \ {len &raw}: print data to user
  @LOG_USER$L1 #1$L0 $xsl comzLogStart
  @FALSE$L0 @D_comZoab$L0 %DVSR %RET

$FN _printz  $PRE \ {&z}: print zoab bytes to user. (single segment)
  %DUP .1%FT %DUP #40$L1 %LT_U @E_cZoab$L2 $xsl assert \ {len}
  %SWP %INC  $xsl print
  @D_comDone$L0 %DVFT %RET

\ **********
\ * [11] Fngi compile loop
\ The fngi compile loop is implemented in spore. In addition to the compile loop itself,
\ this section implements several essential parsing functions that can be used
\ in other areas of fngi.
\
\ Globals:
\   global c_compFn: a function reference used to compile individual tokens.
\
\ fn spor <token>                 : compile token as spor.
\ fn ( <...> )                    : ( compiles tokens until )
\ fn $ <token>                    : execute token asNow
\ fn ret [U4]                     : compile %RET
\ fn _   fn ,   fn ;              : syntax helpers that do nothing.
\
\ fn betweenIncl [value a b -> bool]  : return whether value between [a,b]
\ fn charToInt [c -> U8]          : convert ascii -> hex
\
\ c_fngi                          : fngi compile loop.
\ fn fngiSingle [ -> ...]         : starting (base) c_compFn
\ fn c_single [asNow -> ...]  : compile/execute a single token (c_compFn).
\ fn c_fn [&key]                  : compile a function (small or large)
\ fn execute [&key]               : execute a function (small or large)
\ fn parseNumber [ -> value isNum]: parse token as number
\ fn lit [U4]                     : compile literal
\ fn xSzI [&key -> szI]        : return szI of the fn
\
\ fn c_charNext [ -> c]           : read next character (WARN: AFTER tokenLen)
\ fn c_charNextEsc [ -> c unkEsc] : read an escapeable character (string).
\ fn c_updateCompFn [newComp -> prevComp] : update c_compFn + ret old
\ fn c_number <number> -> [value isNum]   : parse next token (parseNumber).

$FN betweenIncl $PRE \ {value a b} -> a <= value <= b
  $declL b  @SZA@TY_VAR_INPUT^JN  @ASIZE $declVar
  $declEnd \ {value a}
  %OVR %SWP \ {value value a}
  \ if (value<a) return FALSE;
  %LT_U $IF %DRP @FALSE$L0 %RET $END
  $GET b %SWP \ {b value}
  %LT_U %NOT %RET \ return not(b<value)

$FN charToInt $PRE \ {c} -> {U8}
  \ '0' - '9'
  %DUP #30$L0 #39$L0 $xl betweenIncl $IF #30$L0 %SUB %RET $END
  \ 'A' - 'Z'
  %DUP #41$L1 #5A$L1 $xl betweenIncl $IF #41$L1 %SUB #A$L0 %ADD %RET $END
  \ 'a' - 'z'
  %DUP #61$L1 #7A$L1 $xl betweenIncl $IF #61$L1 %SUB #A$L0 %ADD %RET $END
  %DRP #FF$L1 %RET

\ {} -> {c}: read next character from AFTER tokenLen.
\ Increments tokenLen. This is destructive to token, use with care.
$FN c_charNext
  $GET c_tokenLen  $GET c_tokenSize %GE_U $IF
    $xsl c_readNew  $xsl c_assertNoEof
  $END
  $GET c_tokenBuf  $GET c_tokenLen  %ADD .1%FT
  $GET c_tokenLen %INC  $_SET c_tokenLen %RET

\ {} -> {char unknownEscape} read a character that can be escaped.
$FN c_readCharEsc
  $xsl c_charNext \ {char}
  %DUP #5C$L1 %NEQ $IF @FALSE$L0 %RET $END \ if(c != '\\') ret;
  \ c is an escape character: \
  %DRP $xsl c_charNext
  %DUP #5C$L1 %EQ $IF             @FALSE$L0 %RET $END \ \\: escape
  %DUP #74$L1 %EQ $IF %DRP #09$L0 @FALSE$L0 %RET $END \ \t: tab
  %DUP #6E$L1 %EQ $IF %DRP #0A$L0 @FALSE$L0 %RET $END \ \n: newline
  %DUP #20$L1 %EQ $IF %DRP #20$L0 @FALSE$L0 %RET $END \ \ : space (raw)
  %DUP #73$L1 %EQ $IF %DRP #20$L0 @FALSE$L0 %RET $END \ \s: space (explicit)
  %DUP #78$L1 %EQ $IF \ \xHH
    \ charToInt(c_charNext) << 8 + charToInt(c_charNext)
    %DRP $xsl c_charNext  $xsl charToInt #8$L0  %SHL
    $xsl c_charNext       $xsl charToInt %ADD
    \ assertNot(dup < inc(0xFF), E_cStr)
    %DUP #FF$L1 %INC %LT_U  @E_cStr$L2  $xsl assertNot
    @FALSE$L0 %RET
  $END
  @TRUE$L0 %RET \ just return the character as-is but unknownEscape=true

$FN c_parseNumber \ {} -> {value isNumber}
  $declL value  @SZA  @ASIZE $declVar
  $declL i      @SZ1  #1     $declVar
  $declL base   @SZ1  #1     $declVar
  $declEnd
  #A$L0 $_SET base
  #0$L0 $_SET value
  #0$L0 $_SET i

  \ Get correct base
  $GET c_tokenBuf .1%FT #30$L0 %EQ $IF \ if c0 == '0' {}
    $GET c_tokenBuf %INC .1%FT %DUP \ {c1 c1} if there was a char

    \ First handle 0c: character literal
    #63$L1 %EQ  $IF \ if .tokenBuf@1=='c' {c1}
      \ set tokenLen=2 to treat anything after 0c as next character.
      %DRP #2$L0 $_SET c_tokenLen
      $xsl c_readCharEsc  @E_cUnknownEsc$L2 $xsl assertNot
      @TRUE$L0 %RET
    $END

    %DUP \ {c1 c1}
    #62$L1 %EQ  $IF \ if .tokenBuf@1=='b' {c1}
      #2$L0  $_SET base  #2$L0 $_SET i
    $END \ {c1}
    #78$L1 %EQ  $IF \ if .tokenBuf@1=='x' {}
      #10$L0 $_SET base  #2$L0 $_SET i
    $END
  $END

  $LOOP l0
    $GET i  $GET c_tokenLen $BREAK_EQ b0
    $GET c_tokenBuf $GET i %ADD .1%FT \ {c}
    $xsl charToInt \ {v}
    \ return {0 0} if not integer character
    %DUP $GET base %GE_U $IF  @FALSE$L0 %RET  $END

    $GET base  $GET value %MUL \ {base * value}
    %ADD $_SET value \ value = v + value*10
    $GET i %INC $_SET i \ i += 1
  $AGAIN l0  $END_BREAK b0

  $GET i %NOT $IF  #0$L0 @FALSE$L0 %RET  $END \ no token
  $GET value @TRUE$L0 %RET

$FN lit  $PRE \ {U4} compile literal
  %DUP #40$L1 %LT_U        $IF  $jmpl L0  $END
  %DUP #FF$L1 %INC %LT_U   $IF  $jmpl L1  $END
  %DUP #FFFF$L2 %INC %LT_U $IF  $jmpl L2  $END
  $jmpl L4

\ {asNow value:U4} -> {?nowVal}: compile proper sized literal
\ if asNow=true the value is left on the stack.
$FN c_lit
  %SWP %NOT %RETZ \ if now, leave on stack
  $jmpl lit

$FN xSzI $PRE \ {&key} -> {szI}: return the size requirement of the X instr
   .A%FT $xsl isCurMod $IF  @SZ2$L1 %RET  $END  @SZA$L1 %RET

$FN c_fn $PRE \ {&key}: compile a function
  %DUP $xsl assertFn \ {&key}
  %DUP $xsl xSzI     \ {&key szLit}
  %OVR $xsl isFnLarge  $IF @XL$L1 $ELSE @XSL$L1 $END \ {&key instrSzI instr}
  %OVR %SWP \ {&key instrSzI litSzI instr} instr & lit are same sz
  $xl c_instrLitImpl %RET

$FN execute \ {&key} -> {...}: tycheck and execute a dictionary key
  %DUP $xsl isFnLarge  $IF .A%FT .A%XW %RET $END
  .A%FT .A%JMPW

$FN _compConstant $PRE \ {asNow} -> {&keyFn[nullable]}
  $xl c_parseNumber \ {asNow value isNumber}
  $IF  $xsl c_lit #0$L0 %RET  $END %DRP \ {asNow}
  $xsl c_isEof $IF  %DRP #0$L0 %RET  $END \ {asNow}

  \ Handle local dictionary. Only constants allowed here.
  $xsl ldictArgs  @D_dictK$L0 %DVFT %DUP  $IF \ {asNow &key}
    %DUP $xsl isTyped  @E_cNotFnOrConst$L2 $xsl assertNot
    .A%FT $xsl c_lit  #0$L0 %RET
  $END %DRP \ {asNow}
  $xsl gdictArgs  @D_dictK$L0 %DVFT \ {asNow &key}
  %DUP $xsl isTyped %NOT $IF \ Constant case {asNow &key}
    .A%FT $xsl c_lit #0$L0 %RET
  $END %SWP %DRP %DUP $jmpl assertFn \ {&key}

$assertWsEmpty

\ declare c_compFn = 0
$declG c_compFn  @SZA @ASIZE $declVar
  #0  $gRef c_compFn  .4^SR

$FN c_updateCompFn $PRE \ {&newCompFn -> &prevCompFn}
  $GET c_compFn %SWP $_SET c_compFn %RET

\ {asNow} -> {}: compile a single token.
\ This is the primary function that all compilation steps (besides spor
\ compilation) reduce to.
$FN c_single $PRE
  $declL asNow @SZ1 #1     $declVar
  $declL key   @SZA @ASIZE $declVar $declEnd
  \ Handle constants, return if it compiled the token.
  %DUP $_SET asNow $xsl _compConstant %DUP $_SET key %RETZ
  \ if pre, recursively call fngiSingle (compile next token first)
  $GET key $xsl isFnPre $IF $GET c_compFn .A%XW $END \ recurse for PRE
  $GET key $xsl isFnSyn $IF $GET asNow $GET key $jmpl execute    $END
  $GET key $xsl isFnNow $IF $GET asNow @E_cReqNow$L2 $xsl assert $END
  $GET key $GET asNow $IF  $jmpl execute  $END  $jmpl c_fn

$FN fngiSingle \ base c_compFn for fngi tokens.
  #0$h1 $LARGE \ not really any locals (but called with XW)
  $xsl c_scan $GET c_tokenLen %RETZ
  @FALSE$L0 $xl c_single %RET

@fngiSingle $c_updateCompFn ^DRP

$FN c_number $xsl c_scan $xl c_parseNumber %RET \ compile next token as number.

$FN (  $SYN%DRP  \ parens ()
  $xsl c_assertToken
  $xsl c_peekChr #29$L0 %EQ $IF  $jmpl c_scan  $END \ return if we hit ")"
  $LOOP l0
    $GET c_compFn .A%XW
    $xsl c_assertToken
    $xsl c_peekChr #29$L0 %EQ $IF  $jmpl c_scan  $END \ return if we hit ")"
  $AGAIN l0

$FN _spor
  $declL compFn  @SZA  @ASIZE $declVar $declEnd
  @_spor$L2  $xsl c_updateCompFn $_SET compFn \ update c_compFn and cache
  $xsl c_scanNoEof
  @D_comp$L0  %DVFT \ compile next token as spor asm
  $GET compFn $_SET c_compFn %RET

$FN spor $SYN $xsl assertNoNow $xl _spor %RET \ compile as assembly

$FN c_now \ used in $ to make next token/s run NOW.
  $declL compFn  @SZA  @ASIZE $declVar $declEnd
  @c_now$L2  $xsl c_updateCompFn $_SET compFn \ update c_compFn and cache
  $xsl c_scanNoEof
  @TRUE$L0 $xl c_single  \ compile next token as NOW
  $GET compFn $_SET c_compFn %RET

$FN $ $SYN $xsl assertNoNow $xl c_now %RET \ make NOW

$FN _comment \ used in \ to make next token ignored (comment)
  $declL compFn  @SZA  @ASIZE $declVar $declEnd
  @_comment$L2  $xsl c_updateCompFn $_SET compFn
  $xsl c_scanNoEof
  \ Execute an open paren, else ignore
  $GET c_tokenBuf .1%FT #28$L0 %EQ $IF @TRUE$L0 $xl c_single $END
  $GET compFn $_SET c_compFn %RET

\ {-> c} peek at the char after current token.
$FN c_peekNoScan
  $GET c_tokenLen  $GET c_tokenSize %GE_U $IF
    $xsl c_read $xsl c_assertNoEof \ ensure a char exists
  $END
  $GET c_tokenBuf $GET c_tokenLen %ADD .1%FT %RET

\ Comment, of which there are three forms.
\    \        : a line comment
\    \foo     : an inline comment, commenting out one token
\    \( ... ) : a block comment
$FN \
  $SYN %NOP %DRP
  \ Line comment if '\' is followed by space or newline
  $xsl c_peekNoScan #20$L0 %EQ
  $IF @D_scan$L0 %DVSR %RET $END \ scanEol
  $xl _comment %RET \ else token comment

$FN ret $PRE $SYN $xsl assertNoNow @RET $c1 %RET \ ret 4, or just ret;

\ These do nothing and are used for more readable code.
$FN _ $SYN%DRP %RET  $FN , $SYN%DRP %RET  $FN ; $SYN%DRP %RET
$FN -> $SYN%DRP %RET

$FN c_fngi \ fngi compile loop
  $LOOP l0
    $GET c_tokenSize %RETZ \ exit on EOF
    $GET c_compFn .A%XW
  $AGAIN l0

$c_dictDump

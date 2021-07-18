# Imported by wasm.py
from collections import OrderedDict
from dataclasses import dataclass
import copy
import ctypes
from ctypes import c_bool as Bool
import operator

# This is the only way to get the base class for ctypes (_CData) which is
# technically private.
DataTy = ctypes.c_uint8.__bases__[0].__bases__[0]

# Used for classifying things into "modules"
class _Namespace: pass

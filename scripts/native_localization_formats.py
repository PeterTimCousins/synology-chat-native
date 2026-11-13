"""Static NSString scalar-format contracts; never evaluates a format string.

Catalog prose containing ordinary percentages is not automatically a format.
Once a string contains a recognized directive (including %% escapes), every
percent must belong to a valid directive. Numeric prose such as ``100% done``
is recognized as literal only in strings with no actual formatting directives.
This cannot infer arbitrary author intent; explicit format call sites must use
escaped percent signs and should be reviewed separately from scalar prose.
"""

import re


class FormatValidationError(ValueError):
    """A catalog contains a malformed or incompatible scalar format."""


_DIRECTIVE = re.compile(
    r"%(?:(?P<position>[0-9]+)\$)?"
    r"(?P<flags>[-+ #0']*)"
    r"(?P<width>[0-9]+)?(?:\.(?P<precision>[0-9]*))?"
    r"(?P<length>hh|ll|h|l|q|L|z|t|j)?"
    r"(?P<conversion>[@diuoxXfFeEgGaAcCsSpDUOn])"
)
_STAR = re.compile(r"%(?:[0-9]+\$)?[-+ #0']*(?:[0-9]+)?(?:\.)?\*")
_EXPLICIT_POSITION = re.compile(r"%[0-9]+\$")


def _argument_type(conversion, length):
    length = length or ""
    if conversion == "n":
        raise FormatValidationError("Forbidden %n write directive")
    if conversion in "diuoxX":
        if length not in ("", "hh", "h", "l", "ll", "q", "z", "t", "j"):
            raise FormatValidationError("Invalid integer length modifier")
        # q and ll describe the same long-long value in NSString formatting.
        width = "ll" if length == "q" else length or "int"
        return ("signed:" if conversion in "di" else "unsigned:") + width
    if conversion in "DUO":
        if length:
            raise FormatValidationError("Invalid legacy integer length modifier")
        return "signed:l" if conversion == "D" else "unsigned:l"
    if conversion in "fFeEgGaA":
        if length not in ("", "l", "L"):
            raise FormatValidationError("Invalid floating-point length modifier")
        return "long-double" if length == "L" else "double"
    if conversion == "c":
        if length not in ("", "l"):
            raise FormatValidationError("Invalid character length modifier")
        return "wide-character" if length else "character"
    if conversion == "s":
        if length not in ("", "l"):
            raise FormatValidationError("Invalid string length modifier")
        return "wide-string-pointer" if length else "cstring-pointer"
    if length:
        raise FormatValidationError("Invalid length modifier for " + conversion)
    return {"@": "object", "C": "unicode-character", "S": "utf16-string-pointer", "p": "pointer"}[conversion]


def scalar_format_contract(value):
    """Return {one_based_argument_position: type}; reject unsafe formats.

    Reordered/repeated positional arguments are valid. Sequential and positional
    arguments cannot be mixed, positional gaps are rejected, and a repeated
    position must have one compatible type. Star width/precision and %n are
    deliberately unsupported. No plural tokens or stringsdict parsing occurs.
    """
    if not isinstance(value, str):
        raise FormatValidationError("Scalar catalog values must be strings")
    arguments = {}
    mode = None
    sequential = 0
    cursor = 0
    recognized = False
    malformed = []
    while cursor < len(value):
        offset = value.find("%", cursor)
        if offset < 0:
            break
        if value.startswith("%%", offset):
            recognized = True
            cursor = offset + 2
            continue
        if _STAR.match(value, offset):
            raise FormatValidationError("Star width/precision is unsupported")
        # Ordinary UI percentages, including "100% complete", must not become
        # accidental % c / % o directives. In an actual format they are invalid
        # until escaped, just like a bare percent at the end of the string.
        numeric_percent = offset > 0 and value[offset - 1].isdigit() and (
            offset + 1 == len(value) or value[offset + 1].isspace()
            or value[offset + 1] in ".,;:!?)]}"
        )
        match = None if numeric_percent else _DIRECTIVE.match(value, offset)
        if not match:
            if _EXPLICIT_POSITION.match(value, offset):
                raise FormatValidationError("Malformed positional directive")
            malformed.append(offset)
            cursor = offset + 1
            continue
        recognized = True
        position_text = match.group("position")
        directive_mode = "positional" if position_text is not None else "sequential"
        if mode is not None and mode != directive_mode:
            raise FormatValidationError("Mixed sequential and positional arguments")
        mode = directive_mode
        if position_text is None:
            sequential += 1
            position = sequential
        else:
            if len(position_text) > 10:
                raise FormatValidationError("Argument position is outside the supported range")
            position = int(position_text)
            if position < 1:
                raise FormatValidationError("Argument positions must start at 1")
            if position > 2_147_483_647:
                raise FormatValidationError("Argument position is outside the supported range")
        argument_type = _argument_type(match.group("conversion"), match.group("length"))
        if position in arguments and arguments[position] != argument_type:
            raise FormatValidationError("Repeated argument position changes type")
        arguments[position] = argument_type
        cursor = match.end()
    if recognized and malformed:
        raise FormatValidationError("Malformed or unescaped percent in format string")
    # Positions are positive; this proves contiguity without allocating a range
    # based on an untrusted catalog's potentially enormous positional number.
    if arguments and len(arguments) != max(arguments):
        raise FormatValidationError("Argument positions must be contiguous from 1")
    return arguments


def validate_scalar_catalog(english, translated):
    """Require identical scalar keys and compatible argument identities.

    Raises FormatValidationError (a ValueError) on the first failure; returns
    None on success. Callers comparing scalar/plural catalog unions should pass
    only the scalar keys common to both representations, checking union and
    plural contracts separately.
    """
    if not isinstance(english, dict) or not isinstance(translated, dict):
        raise FormatValidationError("Scalar catalogs must be dictionaries")
    if any(not isinstance(key, str) or not key for key in english.keys() | translated.keys()):
        raise FormatValidationError("Scalar catalog keys must be nonempty strings")
    if english.keys() != translated.keys():
        raise FormatValidationError("Scalar catalog key sets differ")
    for key in sorted(english):
        try:
            original = scalar_format_contract(english[key])
            localized = scalar_format_contract(translated[key])
            if original != localized:
                raise FormatValidationError("Argument positions/types differ")
        except FormatValidationError as error:
            raise FormatValidationError(f"Scalar key {key[:120]!r}: {error}") from error

import Foundation

/// HTML 4 named character references beyond the few in `HTMLText.named`: the whole Latin-1
/// set (ø, æ, ü, é, ß, §, ½ …) and the common typographic ones (Œ, „, ‰, •, ™, →, ≤ …).
/// `nbsp` is left out on purpose: `HTMLText.named` maps it to a plain space.
enum HTMLEntities {
    static let table: [String: String] = [
        "iexcl": "¡", "cent": "¢", "pound": "£", "curren": "¤", "yen": "¥", "brvbar": "¦",
        "sect": "§", "uml": "¨", "copy": "©", "ordf": "ª", "laquo": "«", "not": "¬",
        "shy": "\u{00AD}", "reg": "®", "macr": "¯", "deg": "°", "plusmn": "±", "sup2": "²",
        "sup3": "³", "acute": "´", "micro": "µ", "para": "¶", "middot": "·", "cedil": "¸",
        "sup1": "¹", "ordm": "º", "raquo": "»", "frac14": "¼", "frac12": "½", "frac34": "¾",
        "iquest": "¿", "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä",
        "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê",
        "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð",
        "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö",
        "times": "×", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
        "Yacute": "Ý", "THORN": "Þ", "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â",
        "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è",
        "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î",
        "iuml": "ï", "eth": "ð", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô",
        "otilde": "õ", "ouml": "ö", "divide": "÷", "oslash": "ø", "ugrave": "ù", "uacute": "ú",
        "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
        // Latin Extended, punctuation and symbols
        "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ",
        "circ": "ˆ", "tilde": "˜", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "ndash": "–", "mdash": "—", "lsquo": "‘",
        "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "dagger": "†",
        "Dagger": "‡", "bull": "•", "hellip": "…", "permil": "‰", "prime": "′", "Prime": "″",
        "lsaquo": "‹", "rsaquo": "›", "oline": "‾", "euro": "€", "trade": "™", "larr": "←",
        "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "minus": "−", "le": "≤",
        "ge": "≥", "ne": "≠", "infin": "∞", "asymp": "≈",
    ]
}

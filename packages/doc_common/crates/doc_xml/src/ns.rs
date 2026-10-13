//! Namespace identities.
//!
//! An [`Ns`] names a namespace URI independently of the prefix a document
//! binds it to. Well-known document namespaces have fixed identities (the
//! constants below), and OOXML's *Strict* URIs share the identity of their
//! *Transitional* counterparts, so readers handle both dialects with the
//! same code. Other URIs are interned process-wide on first sight.

use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Ns(pub u16);

macro_rules! well_known {
    ($( $(#[$doc:meta])* $name:ident = $id:literal => [$($uri:literal),+ $(,)?] ),* $(,)?) => {
        $( $(#[$doc])* pub const $name: Ns = Ns($id); )*

        /// The identity of a well-known URI.
        fn well_known(uri: &str) -> Option<Ns> {
            match uri {
                $( $($uri)|+ => Some($name), )*
                _ => None,
            }
        }

        /// The canonical (first listed) URI of a well-known identity.
        fn well_known_uri(ns: Ns) -> Option<&'static str> {
            match ns.0 {
                $( $id => Some(well_known!(@first $($uri),+)), )*
                _ => None,
            }
        }
    };
    (@first $first:literal $(, $rest:literal)*) => { $first };
}

/// No namespace: unprefixed attributes, and elements outside any default
/// namespace.
pub const NONE: Ns = Ns(0);

well_known! {
    XML = 1 => ["http://www.w3.org/XML/1998/namespace"],
    XMLNS = 2 => ["http://www.w3.org/2000/xmlns/"],

    // --- OOXML packaging (OPC)
    /// Package relationships (`_rels/*.rels`).
    PKG_REL = 10 => ["http://schemas.openxmlformats.org/package/2006/relationships"],
    /// `[Content_Types].xml`.
    CONTENT_TYPES = 11 => ["http://schemas.openxmlformats.org/package/2006/content-types"],
    CORE_PROPS = 12 => ["http://schemas.openxmlformats.org/package/2006/metadata/core-properties"],
    DC = 13 => ["http://purl.org/dc/elements/1.1/"],
    DCTERMS = 14 => ["http://purl.org/dc/terms/"],
    DCMITYPE = 15 => ["http://purl.org/dc/dcmitype/"],
    XSI = 16 => ["http://www.w3.org/2001/XMLSchema-instance"],
    EXT_PROPS = 17 => [
        "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties",
        "http://purl.oclc.org/ooxml/officeDocument/extendedProperties",
    ],
    CUSTOM_PROPS = 18 => [
        "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties",
        "http://purl.oclc.org/ooxml/officeDocument/customProperties",
    ],
    VT = 19 => [
        "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes",
        "http://purl.oclc.org/ooxml/officeDocument/docPropsVTypes",
    ],
    MC = 20 => ["http://schemas.openxmlformats.org/markup-compatibility/2006"],

    // --- OOXML documents
    /// Office document relationships (`r:id` attributes).
    R = 30 => [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships",
    ],
    /// WordprocessingML.
    W = 31 => [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main",
    ],
    /// SpreadsheetML.
    S = 32 => [
        "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
        "http://purl.oclc.org/ooxml/spreadsheetml/main",
    ],
    /// PresentationML.
    P = 33 => [
        "http://schemas.openxmlformats.org/presentationml/2006/main",
        "http://purl.oclc.org/ooxml/presentationml/main",
    ],
    /// DrawingML.
    A = 34 => [
        "http://schemas.openxmlformats.org/drawingml/2006/main",
        "http://purl.oclc.org/ooxml/drawingml/main",
    ],
    PIC = 35 => [
        "http://schemas.openxmlformats.org/drawingml/2006/picture",
        "http://purl.oclc.org/ooxml/drawingml/picture",
    ],
    WP = 36 => [
        "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        "http://purl.oclc.org/ooxml/drawingml/wordprocessingDrawing",
    ],
    XDR = 37 => [
        "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
        "http://purl.oclc.org/ooxml/drawingml/spreadsheetDrawing",
    ],
    C = 38 => [
        "http://schemas.openxmlformats.org/drawingml/2006/chart",
        "http://purl.oclc.org/ooxml/drawingml/chart",
    ],
    M = 39 => [
        "http://schemas.openxmlformats.org/officeDocument/2006/math",
        "http://purl.oclc.org/ooxml/officeDocument/math",
    ],
    DGM = 40 => [
        "http://schemas.openxmlformats.org/drawingml/2006/diagram",
        "http://purl.oclc.org/ooxml/drawingml/diagram",
    ],
    V = 41 => ["urn:schemas-microsoft-com:vml"],
    O = 42 => ["urn:schemas-microsoft-com:office:office"],
    W10 = 43 => ["urn:schemas-microsoft-com:office:word"],
    X = 44 => ["urn:schemas-microsoft-com:office:excel"],
    PVML = 45 => ["urn:schemas-microsoft-com:office:powerpoint"],
    W14 = 46 => ["http://schemas.microsoft.com/office/word/2010/wordml"],
    W15 = 47 => ["http://schemas.microsoft.com/office/word/2012/wordml"],
    WPS = 48 => ["http://schemas.microsoft.com/office/word/2010/wordprocessingShape"],
    WPG = 49 => ["http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"],
    X14 = 50 => ["http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"],
    X14AC = 51 => ["http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac"],
    P14 = 52 => ["http://schemas.microsoft.com/office/powerpoint/2010/main"],
    A14 = 53 => ["http://schemas.microsoft.com/office/drawing/2010/main"],
    XR = 54 => ["http://schemas.microsoft.com/office/spreadsheetml/2014/revision"],

    // --- OpenDocument
    OFFICE = 100 => ["urn:oasis:names:tc:opendocument:xmlns:office:1.0"],
    STYLE = 101 => ["urn:oasis:names:tc:opendocument:xmlns:style:1.0"],
    TEXT = 102 => ["urn:oasis:names:tc:opendocument:xmlns:text:1.0"],
    TABLE = 103 => ["urn:oasis:names:tc:opendocument:xmlns:table:1.0"],
    DRAW = 104 => ["urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"],
    FO = 105 => ["urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"],
    SVG = 106 => ["urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"],
    XLINK = 107 => ["http://www.w3.org/1999/xlink"],
    NUMBER = 108 => ["urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"],
    META = 109 => ["urn:oasis:names:tc:opendocument:xmlns:meta:1.0"],
    PRESENTATION = 110 => ["urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"],
    MANIFEST = 111 => ["urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"],
    CHART = 112 => ["urn:oasis:names:tc:opendocument:xmlns:chart:1.0"],
    DR3D = 113 => ["urn:oasis:names:tc:opendocument:xmlns:dr3d:1.0"],
    FORM = 114 => ["urn:oasis:names:tc:opendocument:xmlns:form:1.0"],
    SCRIPT = 115 => ["urn:oasis:names:tc:opendocument:xmlns:script:1.0"],
    OF = 116 => ["urn:oasis:names:tc:opendocument:xmlns:of:1.2"],
    LOEXT = 117 => ["urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0"],
    CALCEXT = 118 => ["urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0"],
    ANIM = 119 => ["urn:oasis:names:tc:opendocument:xmlns:animation:1.0"],
    SMIL = 120 => ["urn:oasis:names:tc:opendocument:xmlns:smil-compatible:1.0"],
    OOO = 121 => ["http://openoffice.org/2004/office"],
    MATHML = 122 => ["http://www.w3.org/1998/Math/MathML"],

    // --- Web and e-books
    XHTML = 150 => ["http://www.w3.org/1999/xhtml"],
    SVG_W3C = 151 => ["http://www.w3.org/2000/svg"],
    OPF = 152 => ["http://www.idpf.org/2007/opf"],
    OPS = 153 => ["http://www.idpf.org/2007/ops"],
    NCX = 154 => ["http://www.daisy.org/z3986/2005/ncx/"],
    CONTAINER = 155 => ["urn:oasis:names:tc:opendocument:xmlns:container"],
}

/// First identity handed to interned (not well-known) URIs.
const FIRST_DYNAMIC: u16 = 1024;
/// Interned URIs beyond this share one identity, so a hostile document cannot
/// grow the table without bound.
const MAX_DYNAMIC: usize = 4096;
/// The identity shared once the table is full.
pub const OVERFLOW: Ns = Ns(u16::MAX);

fn table() -> &'static Mutex<Vec<&'static str>> {
    static TABLE: OnceLock<Mutex<Vec<&'static str>>> = OnceLock::new();
    TABLE.get_or_init(|| Mutex::new(Vec::new()))
}

impl Ns {
    /// The identity of a namespace URI, interning it if it is new.
    pub fn from_uri(uri: &str) -> Ns {
        if uri.is_empty() {
            return NONE;
        }
        if let Some(ns) = well_known(uri) {
            return ns;
        }
        let mut table = table().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(i) = table.iter().position(|&known| known == uri) {
            return Ns(FIRST_DYNAMIC + i as u16);
        }
        if table.len() >= MAX_DYNAMIC {
            return OVERFLOW;
        }
        table.push(Box::leak(uri.to_owned().into_boxed_str()));
        Ns(FIRST_DYNAMIC + (table.len() - 1) as u16)
    }

    /// The URI this identity stands for (the Transitional URI for OOXML
    /// namespaces that also have a Strict one).
    pub fn uri(self) -> &'static str {
        if self == NONE {
            return "";
        }
        if let Some(uri) = well_known_uri(self) {
            return uri;
        }
        let table = table().lock().unwrap_or_else(|e| e.into_inner());
        self.0
            .checked_sub(FIRST_DYNAMIC)
            .and_then(|i| table.get(i as usize).copied())
            .unwrap_or("")
    }
}

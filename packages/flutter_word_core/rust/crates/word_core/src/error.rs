//! Errors reading, editing or writing a document.

use doc_opc::OpcError;
use doc_zip::ZipError;

/// Why a document could not be read or written, worded for people.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WordError {
    #[error("{0}")]
    Corrupt(String),
    #[error("{0}")]
    Unsupported(String),
    #[error("This document is protected with a password.")]
    Encrypted,
    #[error("{0}")]
    TooLarge(String),
    /// An edit that does not fit the document (an unknown paragraph...).
    #[error("{0}")]
    Invalid(String),
}

impl From<OpcError> for WordError {
    fn from(e: OpcError) -> Self {
        match e {
            OpcError::Zip(ZipError::Encrypted(_)) => WordError::Encrypted,
            OpcError::Zip(ZipError::TooLarge(m)) => {
                WordError::TooLarge(format!("'{m}' is larger than this app allows."))
            }
            OpcError::Zip(ZipError::NotZip) => {
                WordError::Corrupt("This file is not a document this app can read.".into())
            }
            other => WordError::Corrupt(format!("This document is damaged: {other}.")),
        }
    }
}

impl From<doc_xml::XmlError> for WordError {
    fn from(e: doc_xml::XmlError) -> Self {
        WordError::Corrupt(format!("This document is damaged: {e}."))
    }
}

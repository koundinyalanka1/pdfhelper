//! Errors reading, editing or writing a presentation.

use doc_opc::OpcError;
use doc_zip::ZipError;

/// Why a presentation could not be read or written, worded for people.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SlideError {
    #[error("{0}")]
    Corrupt(String),
    #[error("{0}")]
    Unsupported(String),
    #[error("This presentation is protected with a password.")]
    Encrypted,
    #[error("{0}")]
    TooLarge(String),
    /// An edit that does not fit the deck (an unknown slide or shape...).
    #[error("{0}")]
    Invalid(String),
}

impl From<OpcError> for SlideError {
    fn from(e: OpcError) -> Self {
        match e {
            OpcError::Zip(ZipError::Encrypted(_)) => SlideError::Encrypted,
            OpcError::Zip(ZipError::TooLarge(m)) => SlideError::TooLarge(format!("'{m}' is larger than this app allows.")),
            OpcError::Zip(ZipError::NotZip) => SlideError::Corrupt("This file is not a presentation this app can read.".into()),
            other => SlideError::Corrupt(format!("This presentation is damaged: {other}.")),
        }
    }
}

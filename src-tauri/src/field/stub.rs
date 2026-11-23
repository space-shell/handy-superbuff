//! Placeholder for platforms that have no implementation yet.

use super::{FieldError, TextField};

pub(super) fn focused(_pid: Option<i32>) -> Result<Box<dyn TextField>, FieldError> {
    Err(FieldError::Unsupported)
}

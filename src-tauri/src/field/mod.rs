//! The text field that has keyboard focus in another application.
//!
//! Everything goes through one small trait, so the logic that uses the field is the same
//! on every platform and can be tested without a GUI. macOS implements the trait with
//! the Accessibility API; other platforms answer [`FieldError::Unsupported`] for now.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as platform;
#[cfg(not(target_os = "macos"))]
mod stub;
#[cfg(not(target_os = "macos"))]
use stub as platform;

use std::fmt;

/// A range of text in a field, counted in UTF-16 code units: the unit every
/// Accessibility text offset is expressed in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextRange {
    /// Offset of the first unit, counted from the start of the text.
    pub location: usize,
    /// Number of units. Zero makes the range a caret.
    pub length: usize,
}

/// Why a field could not be read or changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldError {
    /// This platform has no implementation.
    Unsupported,
    /// The process lacks the Accessibility permission.
    NotTrusted,
    /// No text field has keyboard focus.
    NoFocusedField,
    /// The field went away between two calls: focus moved, or the app rebuilt its element.
    Gone,
    /// The app did not apply the selection. Chromium apps do that unless their window is key.
    SelectionIgnored,
    /// The field holds more text than is read.
    TooLong,
    /// An Accessibility call failed with this `AXError` code.
    Ax(i32),
}

impl fmt::Display for FieldError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            FieldError::Unsupported => "not supported on this platform",
            FieldError::NotTrusted => "Accessibility permission is missing",
            FieldError::NoFocusedField => "no text field has focus",
            FieldError::Gone => "the text field went away",
            FieldError::SelectionIgnored => "the app ignored the selection",
            FieldError::TooLong => "the text field holds more text than is read",
            FieldError::Ax(code) => return write!(f, "Accessibility call failed ({code})"),
        })
    }
}

impl std::error::Error for FieldError {}

/// A text field in another application.
///
/// Not `Send` or `Sync`: a field is fetched, read and changed on one thread, in one
/// go, and never kept.
pub trait TextField {
    /// The whole text of the field.
    fn text(&self) -> Result<String, FieldError>;
    /// What is selected right now. Zero length means a caret.
    fn selection(&self) -> Result<TextRange, FieldError>;
    /// The text that is selected right now, empty for a caret.
    fn selected_text(&self) -> Result<String, FieldError>;
    /// Selects a range of text. Zero length places the caret.
    fn set_selection(&self, range: TextRange) -> Result<(), FieldError>;
}

/// The text field that has keyboard focus, in whichever application.
pub fn focused() -> Result<Box<dyn TextField>, FieldError> {
    platform::focused(None)
}

/// The text field that has keyboard focus in the application with this process id.
///
/// Resolved anew on every call. An element fetched earlier may have gone stale: Electron
/// rebuilds its accessibility tree while an app is starting up.
pub fn focused_in(pid: i32) -> Result<Box<dyn TextField>, FieldError> {
    platform::focused(Some(pid))
}

impl TextRange {
    /// The range between two byte offsets of `text`. An offset inside a character
    /// counts as the start of that character, so a range never contains half of one.
    pub fn from_byte_range(text: &str, start: usize, end: usize) -> TextRange {
        let mut units = 0;
        let mut location = None;
        for (byte, c) in text.char_indices() {
            let inside = |offset: usize| byte < offset && offset < byte + c.len_utf8();
            if location.is_none() && (byte >= start || inside(start)) {
                location = Some(units);
            }
            if location.is_some() && (byte >= end || inside(end)) {
                break;
            }
            units += c.len_utf16();
        }
        let location = location.unwrap_or(units);
        TextRange {
            location,
            length: units.saturating_sub(location),
        }
    }

    /// The byte offsets of this range in `text`. `None` when an offset falls inside a
    /// surrogate pair or past the end of the text.
    pub fn to_byte_range(self, text: &str) -> Option<std::ops::Range<usize>> {
        let end = self.location.checked_add(self.length)?;
        let mut start_byte = None;
        let mut end_byte = None;
        let mut units = 0;
        for (byte, c) in text.char_indices() {
            if start_byte.is_none() && units == self.location {
                start_byte = Some(byte);
            }
            if end_byte.is_none() && units == end {
                end_byte = Some(byte);
            }
            if start_byte.is_some() && end_byte.is_some() {
                return Some(start_byte?..end_byte?);
            }
            units += c.len_utf16();
        }
        if units == self.location {
            start_byte = Some(text.len());
        }
        if units == end {
            end_byte = Some(text.len());
        }
        Some(start_byte?..end_byte?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEXT: &str = "ab😀cd";

    #[test]
    fn byte_offsets_count_utf16_units() {
        // a and b are one unit each, the emoji two.
        assert_eq!(TextRange::from_byte_range(TEXT, 0, TEXT.len()).length, 6);
        assert_eq!(
            TextRange::from_byte_range(TEXT, 0, 2),
            TextRange {
                location: 0,
                length: 2
            }
        );
        assert_eq!(
            TextRange::from_byte_range(TEXT, 2, 6),
            TextRange {
                location: 2,
                length: 2
            }
        );
        assert_eq!(
            TextRange::from_byte_range(TEXT, 6, TEXT.len()),
            TextRange {
                location: 4,
                length: 2
            }
        );
    }

    #[test]
    fn a_byte_offset_inside_a_character_rounds_down() {
        // The emoji occupies bytes 2..6; offsets 3 and 5 fall inside it.
        assert_eq!(
            TextRange::from_byte_range(TEXT, 3, 5),
            TextRange {
                location: 2,
                length: 0
            }
        );
        assert_eq!(
            TextRange::from_byte_range(TEXT, 0, 5),
            TextRange {
                location: 0,
                length: 2
            }
        );
    }

    #[test]
    fn offsets_past_the_end_land_at_the_end() {
        assert_eq!(
            TextRange::from_byte_range(TEXT, 1_000, 2_000),
            TextRange {
                location: 6,
                length: 0
            }
        );
        assert_eq!(
            TextRange::from_byte_range("", 0, 0),
            TextRange {
                location: 0,
                length: 0
            }
        );
    }

    #[test]
    fn units_convert_back_to_bytes() {
        for (location, length) in [(0, 0), (0, 2), (2, 2), (4, 2), (0, 6), (6, 0)] {
            let range = TextRange { location, length };
            let bytes = range.to_byte_range(TEXT).expect("on character boundaries");
            assert_eq!(
                TextRange::from_byte_range(TEXT, bytes.start, bytes.end),
                range
            );
        }
        assert_eq!(
            TextRange {
                location: 6,
                length: 0
            }
            .to_byte_range(TEXT),
            Some(TEXT.len()..TEXT.len())
        );
        assert_eq!(
            TextRange {
                location: 0,
                length: 0
            }
            .to_byte_range(""),
            Some(0..0)
        );
    }

    #[test]
    fn a_unit_offset_inside_a_surrogate_pair_has_no_byte_offset() {
        assert_eq!(
            TextRange {
                location: 3,
                length: 0
            }
            .to_byte_range(TEXT),
            None
        );
        assert_eq!(
            TextRange {
                location: 0,
                length: 3
            }
            .to_byte_range(TEXT),
            None
        );
    }

    #[test]
    fn a_unit_offset_past_the_end_has_no_byte_offset() {
        assert_eq!(
            TextRange {
                location: 7,
                length: 0
            }
            .to_byte_range(TEXT),
            None
        );
        assert_eq!(
            TextRange {
                location: 5,
                length: 5
            }
            .to_byte_range(TEXT),
            None
        );
        assert_eq!(
            TextRange {
                location: usize::MAX,
                length: 1
            }
            .to_byte_range(TEXT),
            None
        );
    }

    #[test]
    fn errors_read_well() {
        assert_eq!(
            FieldError::Ax(-25204).to_string(),
            "Accessibility call failed (-25204)"
        );
        assert_eq!(
            FieldError::SelectionIgnored.to_string(),
            "the app ignored the selection"
        );
    }
}

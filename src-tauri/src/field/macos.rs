//! macOS: the focused field through the Accessibility API.
//!
//! Written for what the Phase 0 probe measured on this API:
//!
//! * In Chromium apps (Chrome, Electron), `AXValue` and `AXNumberOfCharacters` show only
//!   the first 10,000 units of a long field, and `AXStringForRange` answers up to offset
//!   200,000. `AXSelectedText` is not cut, so the rest is read through selections.
//! * Chromium apps refuse a selection that runs past the end of their text, and ignore
//!   every selection write unless their window is key, while reporting success.
//! * Electron hands out element handles that stop working while its tree is first built,
//!   so nothing here keeps a handle for longer than one call.

use std::ptr::NonNull;

use objc2_application_services::{AXUIElement, AXValue, AXValueType};
use objc2_core_foundation::{CFRange, CFRetained, CFString, CFType};

use super::{FieldError, TextField, TextRange};

const FOCUSED_ELEMENT: &str = "AXFocusedUIElement";
const ROLE: &str = "AXRole";
const VALUE: &str = "AXValue";
const SELECTED_RANGE: &str = "AXSelectedTextRange";
const SELECTED_TEXT: &str = "AXSelectedText";
const STRING_FOR_RANGE: &str = "AXStringForRange";

const AX_SUCCESS: i32 = 0;
const AX_INVALID_ELEMENT: i32 = -25202;
const AX_ATTRIBUTE_UNSUPPORTED: i32 = -25205;
const AX_API_DISABLED: i32 = -25211;
const AX_NO_VALUE: i32 = -25212;
const AX_PARAMETERIZED_ATTRIBUTE_UNSUPPORTED: i32 = -25213;

/// Units read per call.
const PAGE: usize = 10_000;
/// Up to this offset a long field is read with `AXStringForRange`, which touches nothing.
const PAGING_LIMIT: usize = 200_000;
/// A field with more units than this is not read.
const MAX_TEXT_UNITS: usize = 1_000_000;

pub(super) fn focused(pid: Option<i32>) -> Result<Box<dyn TextField>, FieldError> {
    let app = match pid {
        Some(pid) => unsafe { AXUIElement::new_application(pid as libc::pid_t) },
        None => unsafe { AXUIElement::new_system_wide() },
    };
    let element = attribute(&app, FOCUSED_ELEMENT)?
        .ok_or(FieldError::NoFocusedField)?
        .downcast::<AXUIElement>()
        .map_err(|_| FieldError::NoFocusedField)?;
    match string_attribute(&element, ROLE)?.as_deref() {
        Some("AXTextArea") | Some("AXTextField") => {}
        _ => return Err(FieldError::NoFocusedField),
    }
    Ok(Box::new(AxTextField { element }))
}

struct AxTextField {
    element: CFRetained<AXUIElement>,
}

impl TextField for AxTextField {
    fn text(&self) -> Result<String, FieldError> {
        let mut text = string_attribute(&self.element, VALUE)?.unwrap_or_default();
        let mut from = utf16_len(&text);
        while from < PAGING_LIMIT {
            match string_for_range(&self.element, from, PAGE)? {
                Some(page) if !page.is_empty() => {
                    from += utf16_len(&page);
                    text.push_str(&page);
                }
                _ => break,
            }
            if from > MAX_TEXT_UNITS {
                return Err(FieldError::TooLong);
            }
        }
        if from >= PAGING_LIMIT {
            let saved = self.selection()?;
            let tail = self.read_through_selections(from)?;
            // The selection belongs to the user: put it back, and give the text even if that fails.
            let _ = self.set_selection(saved);
            text.push_str(&tail);
        }
        Ok(text)
    }

    fn selection(&self) -> Result<TextRange, FieldError> {
        range_attribute(&self.element, SELECTED_RANGE)?
            .ok_or(FieldError::Ax(AX_ATTRIBUTE_UNSUPPORTED))
    }

    fn selected_text(&self) -> Result<String, FieldError> {
        Ok(string_attribute(&self.element, SELECTED_TEXT)?.unwrap_or_default())
    }

    fn set_selection(&self, range: TextRange) -> Result<(), FieldError> {
        set_range_attribute(&self.element, SELECTED_RANGE, range)?;
        // Chromium reports success and changes nothing unless its window is key.
        if self.selection()? == range {
            Ok(())
        } else {
            Err(FieldError::SelectionIgnored)
        }
    }
}

impl AxTextField {
    /// Reads from `from` to the end of the text by selecting page after page.
    fn read_through_selections(&self, from: usize) -> Result<String, FieldError> {
        // Telling a refused selection from the end of the text needs an app that takes
        // selections at all, and this one is always valid this far into a field.
        self.set_selection(TextRange {
            location: 1,
            length: 0,
        })?;

        let mut text = String::new();
        let mut at = from;
        while at <= MAX_TEXT_UNITS {
            let Some(length) = self.select_as_far_as_allowed(at)? else {
                break;
            };
            if length == 0 {
                break;
            }
            let page = self.selected_text()?;
            let read = utf16_len(&page);
            text.push_str(&page);
            at += read;
            if read < length {
                break;
            }
        }
        Ok(text)
    }

    /// Selects up to a page from `at`, halving the length until the app takes the
    /// selection, since Chromium refuses one that runs past the end of its text.
    /// Returns the length the app reports back, or `None` when it took none.
    fn select_as_far_as_allowed(&self, at: usize) -> Result<Option<usize>, FieldError> {
        let mut length = PAGE;
        loop {
            set_range_attribute(
                &self.element,
                SELECTED_RANGE,
                TextRange {
                    location: at,
                    length,
                },
            )?;
            let applied = range_attribute(&self.element, SELECTED_RANGE)?;
            if let Some(applied) = applied {
                if applied.location == at && applied.length <= length {
                    return Ok(Some(applied.length));
                }
            }
            if length == 1 {
                return Ok(None);
            }
            length /= 2;
        }
    }
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

fn from_ax_error(code: i32) -> FieldError {
    match code {
        AX_API_DISABLED => FieldError::NotTrusted,
        AX_INVALID_ELEMENT => FieldError::Gone,
        other => FieldError::Ax(other),
    }
}

/// The value of an attribute. `Ok(None)` when the element has no such attribute or no
/// value for it.
fn attribute(element: &AXUIElement, name: &str) -> Result<Option<CFRetained<CFType>>, FieldError> {
    let name = CFString::from_str(name);
    let mut value: *const CFType = std::ptr::null();
    let error = unsafe { element.copy_attribute_value(&name, NonNull::from(&mut value)) };
    if error.0 == AX_ATTRIBUTE_UNSUPPORTED || error.0 == AX_NO_VALUE {
        return Ok(None);
    }
    if error.0 != AX_SUCCESS {
        return Err(from_ax_error(error.0));
    }
    Ok(NonNull::new(value.cast_mut()).map(|value| unsafe { CFRetained::from_raw(value) }))
}

fn string_attribute(element: &AXUIElement, name: &str) -> Result<Option<String>, FieldError> {
    let Some(value) = attribute(element, name)? else {
        return Ok(None);
    };
    match value.downcast::<CFString>() {
        Ok(text) => Ok(Some(text.to_string())),
        Err(_) => Ok(None),
    }
}

fn range_attribute(element: &AXUIElement, name: &str) -> Result<Option<TextRange>, FieldError> {
    let Some(value) = attribute(element, name)? else {
        return Ok(None);
    };
    let Ok(value) = value.downcast::<AXValue>() else {
        return Ok(None);
    };
    if unsafe { value.r#type() } != AXValueType::CFRange {
        return Ok(None);
    }
    let mut range = CFRange {
        location: 0,
        length: 0,
    };
    let copied = unsafe { value.value(AXValueType::CFRange, NonNull::from(&mut range).cast()) };
    Ok(
        (copied && range.location >= 0 && range.length >= 0).then_some(TextRange {
            location: range.location as usize,
            length: range.length as usize,
        }),
    )
}

fn set_range_attribute(
    element: &AXUIElement,
    name: &str,
    range: TextRange,
) -> Result<(), FieldError> {
    let mut value = CFRange {
        location: isize::try_from(range.location).unwrap_or(isize::MAX),
        length: isize::try_from(range.length).unwrap_or(isize::MAX),
    };
    let value = unsafe { AXValue::new(AXValueType::CFRange, NonNull::from(&mut value).cast()) }
        .ok_or(FieldError::Ax(-1))?;
    let name = CFString::from_str(name);
    let error = unsafe { element.set_attribute_value(&name, &value) };
    if error.0 == AX_SUCCESS {
        Ok(())
    } else {
        Err(from_ax_error(error.0))
    }
}

/// The text at a range of the field, or `Ok(None)` when the element does not answer
/// this query.
fn string_for_range(
    element: &AXUIElement,
    location: usize,
    length: usize,
) -> Result<Option<String>, FieldError> {
    let mut value = CFRange {
        location: isize::try_from(location).unwrap_or(isize::MAX),
        length: isize::try_from(length).unwrap_or(isize::MAX),
    };
    let Some(value) =
        (unsafe { AXValue::new(AXValueType::CFRange, NonNull::from(&mut value).cast()) })
    else {
        return Err(FieldError::Ax(-1));
    };
    let name = CFString::from_str(STRING_FOR_RANGE);
    let mut text: *const CFType = std::ptr::null();
    let error = unsafe {
        element.copy_parameterized_attribute_value(&name, &value, NonNull::from(&mut text))
    };
    if error.0 == AX_ATTRIBUTE_UNSUPPORTED
        || error.0 == AX_NO_VALUE
        || error.0 == AX_PARAMETERIZED_ATTRIBUTE_UNSUPPORTED
    {
        return Ok(None);
    }
    if error.0 != AX_SUCCESS {
        return Err(from_ax_error(error.0));
    }
    let Some(text) = NonNull::new(text.cast_mut()) else {
        return Ok(Some(String::new()));
    };
    let text = unsafe { CFRetained::from_raw(text) };
    Ok(text
        .downcast::<CFString>()
        .ok()
        .map(|text| text.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Opens a document in TextEdit and reads and selects in it. Needs the Accessibility
    /// permission for the test process, and an unlocked screen. The document stays open.
    ///
    /// Run with: cargo test field:: -- --ignored --nocapture
    #[test]
    #[ignore = "opens TextEdit and needs the Accessibility permission"]
    fn reads_and_selects_in_textedit() {
        const MARKER: &str = "handy field test";
        let text = format!("first line of the {MARKER}\nsecond line 😀 with an emoji\nthird line");
        let dir = std::env::temp_dir().join("handy-field-test");
        std::fs::create_dir_all(&dir).expect("temp dir");
        let file = dir.join("text.txt");
        std::fs::write(&file, &text).expect("write the test document");

        let before = textedit_pids();
        let status = std::process::Command::new("open")
            .args(["-a", "TextEdit", file.to_str().unwrap()])
            .status()
            .expect("start TextEdit");
        assert!(status.success(), "open failed");

        // TextEdit needs a moment, and the document a moment more.
        let mut field = None;
        for _ in 0..100 {
            std::thread::sleep(std::time::Duration::from_millis(200));
            field = textedit_pids()
                .into_iter()
                .filter(|pid| !before.contains(pid))
                .chain(before.iter().copied())
                .find_map(|pid| field_in(pid).ok());
            if let Some(found) = &field {
                if found.text().ok().as_deref() == Some(text.as_str()) {
                    break;
                }
            }
            field = None;
        }
        let field = field.unwrap_or_else(|| {
            panic!("TextEdit did not show the test document with the text field focused")
        });
        assert_eq!(field.text().unwrap(), text, "the whole text is read");

        let wanted = "second line 😀 with an emoji";
        let start = text.find(wanted).unwrap();
        let range = TextRange::from_byte_range(&text, start, start + wanted.len());
        field.set_selection(range).expect("set the selection");
        assert_eq!(
            field.selection().unwrap(),
            range,
            "the selection reads back"
        );
        assert_eq!(
            field.selected_text().unwrap(),
            wanted,
            "the selected text reads back"
        );

        // A caret.
        field
            .set_selection(TextRange {
                location: 0,
                length: 0,
            })
            .expect("place the caret");
        assert_eq!(
            field.selection().unwrap(),
            TextRange {
                location: 0,
                length: 0
            }
        );
        eprintln!("close the TextEdit document {file:?} by hand");
    }

    fn textedit_pids() -> Vec<i32> {
        let output = std::process::Command::new("pgrep")
            .args(["-x", "TextEdit"])
            .output()
            .expect("pgrep");
        String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .filter_map(|pid| pid.parse().ok())
            .collect()
    }

    fn field_in(pid: i32) -> Result<Box<dyn TextField>, FieldError> {
        super::super::focused_in(pid)
    }
}

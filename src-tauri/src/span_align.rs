//! Finds the span of a field's text that a spoken phrase refers to.
//!
//! Matching tolerates what dictation produces: inflections (`jump` for `jumps`), words
//! the speaker leaves out (`quick fox` for `quick brown fox`), and recognition errors
//! (`dawg` for `dog`). It does not match synonyms or a paraphrase: the words have to be
//! the field's words, in order. A candidate scores as the mean over the words it matched,
//! minus a penalty for every field word skipped and every spoken word that found no
//! counterpart. Below the threshold nothing is selected.

use std::borrow::Cow;

/// A phrase found in a field: byte offsets into the field's text, and the score.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Match {
    /// Byte offset of the first character of the match.
    pub start: usize,
    /// Byte offset just past the last character of the match.
    pub end: usize,
    /// Mean score of the words the phrase matched in the field, after the penalties.
    /// 1.0 means every word matched exactly and nothing was skipped.
    pub score: f32,
}

/// Aligns a spoken phrase to the words of a field.
#[derive(Debug, Clone, Copy)]
pub struct Aligner {
    /// Mean per-word score a candidate needs to be returned at all.
    pub threshold: f32,
    /// Field words allowed between two neighbouring words of the phrase.
    pub max_skipped: usize,
}

impl Default for Aligner {
    fn default() -> Self {
        Self {
            threshold: 0.8,
            max_skipped: 3,
        }
    }
}

/// Score of the same word twice.
const SAME: f32 = 1.0;
/// Score of two forms of one word, such as `jump` and `jumps`.
const INFLECTION: f32 = 0.95;
/// Score of two words that sound alike but are spelled differently.
const SAME_SOUND: f32 = 0.8;
/// A field word the phrase leaves out. Cheap, because speakers leave words out.
const SKIPPED_WORD: f32 = -0.15;
/// A spoken word with no counterpart in the candidate: the recogniser produced a word
/// that is not there, or the speaker said more than the field holds.
const ABSENT_WORD: f32 = -0.5;
/// Candidates within this of the best score count as ties; the tie goes to the one
/// nearest the caret.
const TIE: f32 = 0.02;
/// A field word can only start a candidate if its first letter is the first letter of
/// one of this many leading words of the phrase.
const ANCHOR_WORDS: usize = 2;
/// Words of the phrase that are taken into account. A longer phrase is cut.
pub const MAX_PHRASE_WORDS: usize = 24;

const NEG_INF: f32 = f32::NEG_INFINITY;

struct Token {
    start: usize,
    end: usize,
    word: String,
}

#[derive(Clone, Copy)]
struct Candidate {
    /// Index of the first field word.
    first: usize,
    /// Number of field words.
    len: usize,
    score: f32,
}

impl Aligner {
    /// Finds the span of `text` that `phrase` refers to.
    ///
    /// `caret` is a byte offset into `text`. Among candidates that score alike the one
    /// nearest to it wins; without it the earliest wins.
    pub fn find(&self, text: &str, phrase: &str, caret: Option<usize>) -> Option<Match> {
        let field = tokenize(text);
        let mut words: Vec<String> = tokenize(phrase).into_iter().map(|t| t.word).collect();
        words.truncate(MAX_PHRASE_WORDS);
        if words.is_empty() || field.is_empty() {
            return None;
        }

        let anchors: Vec<char> = words
            .iter()
            .take(ANCHOR_WORDS)
            .filter_map(|word| word.chars().next())
            .collect();
        let mut best = NEG_INF;
        let mut candidates: Vec<Candidate> = Vec::new();
        for first in 0..field.len() {
            match field[first].word.chars().next() {
                Some(letter) if anchors.contains(&letter) => {}
                _ => continue,
            }
            if let Some(candidate) = self.align_from(&field, first, &words) {
                best = best.max(candidate.score);
                candidates.push(candidate);
            }
        }
        if best < self.threshold {
            return None;
        }
        candidates.retain(|candidate| candidate.score >= best - TIE);

        let span = |candidate: Candidate| {
            let start = field[candidate.first].start;
            let end = field[candidate.first + candidate.len - 1].end;
            (start, end)
        };
        let chosen = match caret {
            None => candidates[0],
            Some(caret) => {
                let distance = |candidate: Candidate| {
                    let (start, end) = span(candidate);
                    if (start..=end).contains(&caret) {
                        0
                    } else {
                        start.abs_diff(caret).min(end.abs_diff(caret))
                    }
                };
                candidates
                    .iter()
                    .copied()
                    .min_by_key(|candidate| distance(*candidate))
                    .unwrap_or(candidates[0])
            }
        };
        let (start, end) = span(chosen);
        Some(Match {
            start,
            end,
            score: chosen.score,
        })
    }

    /// The best way to align the phrase to field words starting at `first`.
    fn align_from(&self, field: &[Token], first: usize, words: &[String]) -> Option<Candidate> {
        let max_len = (words.len() + self.max_skipped).min(field.len() - first);
        // Score and number of matched words of the best path to each cell of the grid.
        let mut previous = vec![(NEG_INF, 0usize); max_len + 1];
        let mut current = vec![(NEG_INF, 0usize); max_len + 1];
        // Leading field words are not skipped: a candidate starts at its first matched word.
        previous[0] = (0.0, 0);
        let mut best: Option<Candidate> = None;
        for (index, word) in words.iter().enumerate() {
            // The spoken words so far, none of them found in the field.
            current[0] = (ABSENT_WORD * (index + 1) as f32, 0);
            // `left` is the cell before the one being filled: the path that skips a field word.
            let mut left = current[0];
            for (len, cell) in current.iter_mut().enumerate().skip(1) {
                let field_word = &field[first + len - 1].word;
                let absent = (previous[len].0 + ABSENT_WORD, previous[len].1);
                let matched = (
                    previous[len - 1].0 + similarity(field_word, word),
                    previous[len - 1].1 + 1,
                );
                let skipped = (left.0 + SKIPPED_WORD, left.1);
                // Of equal paths, the one with more matched words is kept.
                let best = if matched.0 >= absent.0 {
                    matched
                } else {
                    absent
                };
                *cell = if skipped.0 > best.0 { skipped } else { best };
                left = *cell;
            }
            if index + 1 == words.len() {
                for (len, &(total, matched)) in current.iter().enumerate().skip(1) {
                    let score = total / matched.max(1) as f32;
                    if score > best.map_or(NEG_INF, |best| best.score) {
                        best = Some(Candidate { first, len, score });
                    }
                }
            }
            std::mem::swap(&mut previous, &mut current);
        }
        best
    }
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

fn is_apostrophe(c: char) -> bool {
    c == '\'' || c == '’'
}

/// Splits text into lowercased words and remembers where each one starts and ends.
/// Anything that is not a letter or digit separates words, except an apostrophe
/// between two word characters.
fn tokenize(text: &str) -> Vec<Token> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !is_word_char(chars[i].1) {
            i += 1;
            continue;
        }
        let start = chars[i].0;
        loop {
            let here = chars[i].1;
            let next = chars.get(i + 1).map(|c| c.1);
            let after = chars.get(i + 2).map(|c| c.1);
            let joined = match (next, after) {
                (Some(next), _) if is_word_char(next) => true,
                (Some(next), Some(after)) => {
                    is_apostrophe(next) && is_word_char(here) && is_word_char(after)
                }
                _ => false,
            };
            if !joined {
                break;
            }
            i += 1;
        }
        let end = chars[i].0 + chars[i].1.len_utf8();
        tokens.push(Token {
            start,
            end,
            word: text[start..end].to_lowercase(),
        });
        i += 1;
    }
    tokens
}

/// How much two words alike count for, between 0.0 and 1.0.
fn similarity(a: &str, b: &str) -> f32 {
    if a == b {
        return SAME;
    }
    let mut best = if stem(a) == stem(b) { INFLECTION } else { 0.0 };

    let longest = a.chars().count().max(b.chars().count());
    let by_edit = 1.0 - levenshtein(a, b) as f32 / longest as f32;
    // Soundex ignores vowels, so for words this short it says "same" far too often.
    let same_sound = a.chars().count().min(b.chars().count()) >= 3 && soundex(a) == soundex(b);
    let same_start = a.chars().next() == b.chars().next();
    // An edit distance is weak evidence on its own: unrelated words of similar length
    // sit one or two edits apart.
    let by_edit = if same_start || same_sound {
        by_edit
    } else {
        by_edit / 2.0
    };

    best = best.max(by_edit);
    if same_sound {
        best = best.max(SAME_SOUND);
    }
    best.max(0.0)
}

fn levenshtein(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = (diagonal + usize::from(ca != *cb))
                .min(row[j] + 1)
                .min(above + 1);
            diagonal = above;
        }
    }
    row[b.len()]
}

fn soundex_code(c: char) -> u8 {
    match c.to_ascii_uppercase() {
        'B' | 'F' | 'P' | 'V' => 1,
        'C' | 'G' | 'J' | 'K' | 'Q' | 'S' | 'X' | 'Z' => 2,
        'D' | 'T' => 3,
        'L' => 4,
        'M' | 'N' => 5,
        'R' => 6,
        _ => 0,
    }
}

/// American Soundex: the first letter and three digits for the consonant sounds.
fn soundex(word: &str) -> [u8; 4] {
    let mut out = [b'0'; 4];
    let mut letters = word.chars().filter(|c| c.is_ascii_alphabetic());
    let Some(first) = letters.next() else {
        return out;
    };
    out[0] = (first as u8).to_ascii_uppercase();
    let mut previous = soundex_code(first);
    let mut vowel_seen = false;
    let mut digits = 1;
    for c in letters {
        match soundex_code(c) {
            // H and W are transparent: they neither join nor separate two consonants.
            0 if c == 'h' || c == 'w' || c == 'y' => {}
            0 => vowel_seen = true,
            code => {
                // Two consonants with one code count once, unless a vowel separates them.
                if (code != previous || vowel_seen) && digits < 4 {
                    out[digits] = b'0' + code;
                    digits += 1;
                }
                previous = code;
                vowel_seen = false;
            }
        }
    }
    out
}

/// Words whose final `s` belongs to the word.
const NO_PLURAL_S: &[&str] = &[
    "as", "bus", "gas", "has", "his", "is", "its", "plus", "thus", "us", "was", "yes",
];

fn without_last(word: &str, n: usize) -> &str {
    &word[..word.len() - n]
}

fn is_vowel(c: char) -> bool {
    matches!(c, 'a' | 'e' | 'i' | 'o' | 'u')
}

/// Porter's measure: how many times the word goes from a vowel to a consonant.
fn measure(word: &str) -> usize {
    let mut count = 0;
    let mut in_vowel = false;
    for c in word.chars() {
        if is_vowel(c) {
            in_vowel = true;
        } else if in_vowel {
            count += 1;
            in_vowel = false;
        }
    }
    count
}

/// Whether the word ends consonant, vowel, consonant, the last one not W, X or Y.
fn ends_cvc(word: &str) -> bool {
    let mut letters = word.chars().rev();
    match (letters.next(), letters.next(), letters.next()) {
        (Some(c1), Some(c2), Some(c3)) => {
            !is_vowel(c1) && !"wxy".contains(c1) && is_vowel(c2) && !is_vowel(c3)
        }
        _ => false,
    }
}

/// Takes a regular English suffix off a word, so that `jumps`, `jumped` and `jumping`
/// all come out as `jump`. Irregular forms are left alone.
fn stem(word: &str) -> Cow<'_, str> {
    let (base, was_ed_or_ing) = if word.len() > 5 && word.ends_with("ing") {
        (without_last(word, 3), true)
    } else if word.len() > 4 && word.ends_with("ed") {
        (without_last(word, 2), true)
    } else if word.len() > 4 && word.ends_with("ies") {
        return Cow::Owned(format!("{}y", without_last(word, 3)));
    } else if word.len() > 3
        && ["ches", "shes", "ses", "xes", "zes"]
            .iter()
            .any(|ending| word.ends_with(ending))
    {
        (without_last(word, 2), false)
    } else if word.len() > 3
        && word.ends_with('s')
        && !NO_PLURAL_S.contains(&word)
        && !["ss", "us", "is"]
            .iter()
            .any(|ending| word.ends_with(ending))
    {
        (without_last(word, 1), false)
    } else {
        return Cow::Borrowed(word);
    };
    if !was_ed_or_ing {
        return Cow::Borrowed(base);
    }

    // Porter's step 1b: what to do with what is left of -ed and -ing.
    let mut owned = base.to_owned();
    let letters: Vec<char> = base.chars().collect();
    if letters.len() >= 2 && letters[letters.len() - 1] == letters[letters.len() - 2] {
        let doubled = letters[letters.len() - 1];
        if !"lsz".contains(doubled) {
            owned.pop();
            return Cow::Owned(owned);
        }
    }
    if ["at", "bl", "iz"]
        .iter()
        .any(|ending| base.ends_with(ending))
        || (measure(base) == 1 && ends_cvc(base))
    {
        owned.push('e');
    }
    Cow::Owned(owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn select<'a>(text: &'a str, phrase: &str) -> Option<&'a str> {
        select_near(text, phrase, None)
    }

    fn select_near<'a>(text: &'a str, phrase: &str, caret: Option<usize>) -> Option<&'a str> {
        Aligner::default()
            .find(text, phrase, caret)
            .map(|m| &text[m.start..m.end])
    }

    fn score(text: &str, phrase: &str) -> f32 {
        Aligner::default()
            .find(text, phrase, None)
            .map(|m| m.score)
            .unwrap_or(0.0)
    }

    const FOX: &str = "The quick brown fox jumps over the lazy dog";

    #[test]
    fn exact_words_select_exactly() {
        assert_eq!(select(FOX, "quick brown fox"), Some("quick brown fox"));
        assert_eq!(score(FOX, "quick brown fox"), 1.0);
    }

    #[test]
    fn field_has_an_inflection_of_the_spoken_word() {
        assert_eq!(
            select(FOX, "jump over the dog"),
            Some("jumps over the lazy dog")
        );
        assert!((0.9..1.0).contains(&score(FOX, "jump over the dog")));
    }

    #[test]
    fn recognition_error_inside_a_word() {
        assert_eq!(
            select(FOX, "jump over the dawg"),
            Some("jumps over the lazy dog")
        );
    }

    #[test]
    fn speaker_leaves_out_a_field_word() {
        assert_eq!(select(FOX, "quick fox"), Some("quick brown fox"));
    }

    #[test]
    fn phrase_has_an_inflection_of_the_field_word() {
        let text = "We are running through the tests now";
        assert_eq!(
            select(text, "run through the tests"),
            Some("running through the tests")
        );
        assert_eq!(
            select(FOX, "jumps over the lazy dog"),
            Some("jumps over the lazy dog")
        );
    }

    #[test]
    fn case_does_not_matter() {
        assert_eq!(
            select("The Quick Brown Fox", "quick brown fox"),
            Some("Quick Brown Fox")
        );
        assert_eq!(select(FOX, "The Quick Fox"), Some("The quick brown fox"));
    }

    #[test]
    fn punctuation_separates_words_and_stays_outside_the_selection() {
        assert_eq!(
            select("Quick, brown fox! Then rest.", "quick fox"),
            Some("Quick, brown fox")
        );
        assert_eq!(select(FOX, "quick, fox!"), Some("quick brown fox"));
    }

    #[test]
    fn apostrophes_belong_to_the_word_whichever_shape_they_have() {
        assert_eq!(select("Don’t stop now", "don't stop"), Some("Don’t stop"));
        assert_eq!(select("Don't stop now", "don’t stop"), Some("Don't stop"));
    }

    #[test]
    fn a_hyphenated_field_word_covers_two_spoken_words() {
        assert_eq!(
            select("a well-known fact", "well known fact"),
            Some("well-known fact")
        );
    }

    #[test]
    fn digits_are_words_and_a_dot_separates() {
        assert_eq!(
            select("Use Version 2.1 here", "version 2"),
            Some("Version 2")
        );
    }

    #[test]
    fn one_absent_word_in_a_long_phrase_still_matches() {
        let text = "we are running through the tests now";
        assert_eq!(
            select(text, "we are running through all the tests now"),
            Some("we are running through the tests now")
        );
    }

    #[test]
    fn match_at_the_start_and_at_the_end_of_the_text() {
        let text = "alpha beta\ngamma delta";
        assert_eq!(select(text, "alpha beta"), Some("alpha beta"));
        assert_eq!(select(text, "gamma delta"), Some("gamma delta"));
    }

    #[test]
    fn match_across_a_line_break_includes_it() {
        assert_eq!(
            select("alpha beta\ngamma delta", "beta gamma"),
            Some("beta\ngamma")
        );
    }

    #[test]
    fn text_before_the_match_can_be_any_unicode() {
        let text = "😀 — ça va? quick brown fox";
        let m = Aligner::default().find(text, "quick fox", None).unwrap();
        assert_eq!(&text[m.start..m.end], "quick brown fox");
    }

    #[test]
    fn single_word_phrases_work() {
        assert_eq!(select(FOX, "fox"), Some("fox"));
        assert_eq!(select(FOX, "dogs"), Some("dog"));
    }

    #[test]
    fn without_a_caret_the_earliest_occurrence_wins() {
        let text = "one two three one two three";
        assert_eq!(select(text, "one two"), Some("one two"));
        assert_eq!(select(text, "one two").unwrap().as_ptr(), text.as_ptr());
    }

    #[test]
    fn with_a_caret_the_nearest_occurrence_wins() {
        let text = "the cat sat on the mat. the cat sat again.";
        let first = text.find("cat sat").unwrap();
        let second = text.rfind("cat sat").unwrap();
        let start = |caret: usize| {
            Aligner::default()
                .find(text, "cat sat", Some(caret))
                .unwrap()
                .start
        };
        assert_eq!(
            start(text.len()),
            second,
            "a caret at the end selects the last one"
        );
        assert_eq!(
            start(0),
            first,
            "a caret at the start selects the first one"
        );
        assert_eq!(start(first + 2), first, "a caret inside a match keeps it");
        assert_eq!(
            start(second - 1),
            second,
            "a caret just before a match selects it"
        );
    }

    #[test]
    fn an_exact_occurrence_beats_an_approximate_one() {
        let text = "jumps over the lazy dog. Then jump over the dog again.";
        assert_eq!(select(text, "jump over the dog"), Some("jump over the dog"));
    }

    #[test]
    fn a_higher_threshold_refuses_an_approximate_match() {
        let strict = Aligner {
            threshold: 0.99,
            ..Aligner::default()
        };
        assert!(strict.find(FOX, "jump over the dog", None).is_none());
        assert!(strict.find(FOX, "quick brown fox", None).is_some());
    }

    #[test]
    fn paraphrase_is_refused() {
        assert_eq!(select(FOX, "leaps over the hound"), None);
        assert!(score(FOX, "leaps over the hound") < 0.7);
    }

    #[test]
    fn words_that_are_not_there_are_refused() {
        assert_eq!(select(FOX, "open the settings"), None);
        assert!(score(FOX, "open the settings") < 0.7);
    }

    #[test]
    fn a_synonym_is_refused() {
        assert_eq!(select("the car is red", "automobile"), None);
    }

    #[test]
    fn another_word_order_is_refused() {
        assert_eq!(select(FOX, "lazy dog jumps"), None);
    }

    #[test]
    fn half_the_words_wrong_is_refused() {
        let text = "running through the tests";
        assert_eq!(select(text, "walk through the exams"), None);
    }

    #[test]
    fn no_more_field_words_are_skipped_than_allowed() {
        let text = "The quick one two three four fox jumps";
        assert_eq!(select(text, "the quick fox jumps"), None);
        let lenient = Aligner {
            max_skipped: 4,
            ..Aligner::default()
        };
        assert_eq!(
            lenient
                .find(text, "the quick fox jumps", None)
                .map(|m| &text[m.start..m.end]),
            Some("The quick one two three four fox jumps")
        );
    }

    #[test]
    fn one_extra_spoken_word_is_tolerated_and_two_are_not() {
        assert_eq!(
            select(FOX, "jump over the dog now"),
            Some("jumps over the lazy dog")
        );
        assert_eq!(
            select(FOX, "jump right over the dog"),
            Some("jumps over the lazy dog")
        );
        assert_eq!(select(FOX, "jump right over the dog now"), None);
    }

    #[test]
    fn an_extra_word_needs_three_matched_words_beside_it() {
        assert_eq!(select(FOX, "now quick fox"), None);
        assert_eq!(
            select(FOX, "now the quick brown fox"),
            Some("The quick brown fox")
        );
    }

    #[test]
    fn nothing_to_match_gives_nothing() {
        let aligner = Aligner::default();
        assert!(aligner.find("", "quick fox", None).is_none());
        assert!(aligner.find(FOX, "", None).is_none());
        assert!(aligner.find(FOX, " , ! ", None).is_none());
    }

    #[test]
    fn a_phrase_longer_than_the_text_gives_nothing() {
        assert_eq!(select("a b", "a b c d e"), None);
    }

    #[test]
    fn a_long_field_is_searched_quickly() {
        let filler: String = "lorem ipsum dolor sit amet ".repeat(4_000);
        let text = format!("{filler} and finally the quick brown fox {filler}");
        let started = std::time::Instant::now();
        let m = Aligner::default()
            .find(&text, "quick fox", None)
            .expect("the phrase is in the text");
        assert_eq!(&text[m.start..m.end], "quick brown fox");
        assert!(
            started.elapsed() < std::time::Duration::from_secs(10),
            "took {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn a_candidate_starts_on_one_of_the_first_two_spoken_words() {
        // The first spoken word is not in the field; the second one still finds the spot.
        assert_eq!(
            select("A quick brown fox", "uh quick brown fox"),
            Some("quick brown fox")
        );
        // Neither of the first two is: nothing starts a candidate, by design.
        assert_eq!(select("A quick brown fox", "uh um quick brown fox"), None);
    }

    #[test]
    fn stems_come_out_as_expected() {
        for (word, expected) in [
            ("jump", "jump"),
            ("jumps", "jump"),
            ("jumped", "jump"),
            ("jumping", "jump"),
            ("run", "run"),
            ("runs", "run"),
            ("running", "run"),
            ("hop", "hop"),
            ("hoped", "hope"),
            ("hoping", "hope"),
            ("make", "make"),
            ("making", "make"),
            ("read", "read"),
            ("reading", "read"),
            ("test", "test"),
            ("tests", "test"),
            ("tested", "test"),
            ("testing", "test"),
            ("story", "story"),
            ("stories", "story"),
            ("box", "box"),
            ("boxes", "box"),
            ("bus", "bus"),
            ("buses", "bus"),
            ("fill", "fill"),
            ("filling", "fill"),
            ("less", "less"),
            ("this", "this"),
            ("his", "his"),
        ] {
            assert_eq!(stem(word), expected, "stem of {word}");
        }
    }

    #[test]
    fn words_that_sound_alike_share_a_soundex_code() {
        for (a, b) in [("dog", "dawg"), ("for", "far"), ("smith", "smyth")] {
            assert_eq!(soundex(a), soundex(b), "{a} and {b}");
        }
        assert_ne!(soundex("dog"), soundex("hound"));
        assert_ne!(soundex("jump"), soundex("leaps"));
    }

    #[test]
    fn edit_distances() {
        assert_eq!(levenshtein("dog", "dawg"), 2);
        assert_eq!(levenshtein("jump", "jumps"), 1);
        assert_eq!(levenshtein("", "abc"), 3);
    }

    #[test]
    fn unrelated_words_score_low_and_related_words_high() {
        assert_eq!(similarity("fox", "fox"), 1.0);
        assert_eq!(similarity("jump", "jumps"), INFLECTION);
        assert_eq!(similarity("dog", "dawg"), SAME_SOUND);
        assert!(similarity("jump", "leaps") < 0.5);
        assert!(similarity("dog", "hound") < 0.3);
        assert!(
            similarity("a", "away") < 0.5,
            "a one-letter word does not sound like a long one"
        );
    }
}

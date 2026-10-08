//! One tokenizer for preparation, queries, phrases, vocabulary and highlights.
//! ICU dictionary boundaries handle scripts without spaces; Snowball is opt-in.
use icu_segmenter::WordSegmenter;
use rusqlite::{ffi, Connection};
use rust_stemmers::{Algorithm, Stemmer};
use std::{
    ffi::{c_char, c_int, c_void, CStr},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

pub fn algorithm(language: &str) -> Option<Algorithm> {
    Some(match language {
        "en" => Algorithm::English,
        "fr" => Algorithm::French,
        "de" => Algorithm::German,
        "es" => Algorithm::Spanish,
        "pt" => Algorithm::Portuguese,
        "it" => Algorithm::Italian,
        "nl" => Algorithm::Dutch,
        "sv" => Algorithm::Swedish,
        "da" => Algorithm::Danish,
        "no" => Algorithm::Norwegian,
        "fi" => Algorithm::Finnish,
        "ru" => Algorithm::Russian,
        "ro" => Algorithm::Romanian,
        "hu" => Algorithm::Hungarian,
        "tr" => Algorithm::Turkish,
        "ar" => Algorithm::Arabic,
        "el" => Algorithm::Greek,
        "ta" => Algorithm::Tamil,
        _ => return None,
    })
}
pub fn language(plan: &crate::Plan) -> Result<&str, Box<dyn std::error::Error>> {
    let language = plan.word_language.as_deref().unwrap_or("en");
    if algorithm(language).is_none() {
        return Err("Unsupported stemming language".into());
    }
    Ok(language)
}
pub fn table(plan: &crate::Plan) -> Result<String, Box<dyn std::error::Error>> {
    let language = language(plan)?;
    Ok(if !plan.stem_words {
        "words".into()
    } else if language == "en" {
        "stems".into()
    } else {
        format!("stems_{language}")
    })
}
pub fn normalize(text: &str) -> String {
    text.to_lowercase()
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect()
}
struct Tokenizer {
    stemmer: Option<Stemmer>,
}
unsafe extern "C" fn create(
    _: *mut c_void,
    args: *mut *const c_char,
    count: c_int,
    output: *mut *mut ffi::Fts5Tokenizer,
) -> c_int {
    catch_unwind(|| {
        let stemmer = if count == 0 {
            None
        } else if count == 1 {
            let Ok(language) = CStr::from_ptr(*args).to_str() else {
                return ffi::SQLITE_ERROR;
            };
            let Some(algorithm) = algorithm(language) else {
                return ffi::SQLITE_ERROR;
            };
            Some(Stemmer::create(algorithm))
        } else {
            return ffi::SQLITE_ERROR;
        };
        *output = Box::into_raw(Box::new(Tokenizer { stemmer })).cast();
        ffi::SQLITE_OK
    })
    .unwrap_or(ffi::SQLITE_ERROR)
}
unsafe extern "C" fn delete(tokenizer: *mut ffi::Fts5Tokenizer) {
    if !tokenizer.is_null() {
        drop(Box::from_raw(tokenizer.cast::<Tokenizer>()));
    }
}
type Emit = unsafe extern "C" fn(*mut c_void, c_int, *const c_char, c_int, c_int, c_int) -> c_int;
unsafe extern "C" fn tokenize(
    tokenizer: *mut ffi::Fts5Tokenizer,
    context: *mut c_void,
    _: c_int,
    bytes: *const c_char,
    length: c_int,
    emit: Option<Emit>,
) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        if length == 0 {
            return ffi::SQLITE_OK;
        }
        if length < 0 || bytes.is_null() || tokenizer.is_null() {
            return ffi::SQLITE_ERROR;
        }
        let Some(emit) = emit else {
            return ffi::SQLITE_ERROR;
        };
        let Ok(text) =
            std::str::from_utf8(std::slice::from_raw_parts(bytes.cast(), length as usize))
        else {
            return ffi::SQLITE_ERROR;
        };
        let tokenizer = &*tokenizer.cast::<Tokenizer>();
        let segmenter = WordSegmenter::new_dictionary(Default::default());
        let mut start = 0;
        for (end, kind) in segmenter.segment_str(text).iter_with_word_type() {
            if kind.is_word_like() && end > start {
                // Preserve unicode61's punctuation boundaries for filenames,
                // dotted identifiers and snake_case within ICU word segments.
                let mut part_start = start;
                let separator = |c: char| !c.is_alphanumeric() && !is_combining_mark(c);
                for piece in text[start..end].split_inclusive(separator) {
                    let part = piece.trim_end_matches(separator);
                    let part_end = part_start + part.len();
                    let lower = part.to_lowercase();
                    let stem = tokenizer.stemmer.as_ref().map_or_else(
                        || std::borrow::Cow::Borrowed(lower.as_str()),
                        |s| s.stem(&lower),
                    );
                    let token = normalize(&stem);
                    if !token.is_empty() {
                        let result = emit(
                            context,
                            0,
                            token.as_ptr().cast(),
                            token.len() as c_int,
                            part_start as c_int,
                            part_end as c_int,
                        );
                        if result != ffi::SQLITE_OK {
                            return result;
                        }
                    }
                    part_start += piece.len();
                }
            }
            start = end;
        }
        ffi::SQLITE_OK
    }))
    .unwrap_or(ffi::SQLITE_ERROR)
}
pub fn register(db: &Connection) -> rusqlite::Result<()> {
    unsafe {
        let mut api: *mut ffi::fts5_api = ptr::null_mut();
        let mut statement = ptr::null_mut();
        let mut code = ffi::sqlite3_prepare_v2(
            db.handle(),
            c"SELECT fts5(?1)".as_ptr(),
            -1,
            &mut statement,
            ptr::null_mut(),
        );
        if code == ffi::SQLITE_OK {
            code = ffi::sqlite3_bind_pointer(
                statement,
                1,
                (&mut api as *mut *mut ffi::fts5_api).cast(),
                c"fts5_api_ptr".as_ptr(),
                None,
            );
            if code == ffi::SQLITE_OK {
                code = ffi::sqlite3_step(statement);
            }
        }
        ffi::sqlite3_finalize(statement);
        if api.is_null() {
            return Err(rusqlite::Error::SqliteFailure(
                ffi::Error::new(code),
                Some("FTS5 tokenizer API unavailable".into()),
            ));
        }
        let mut tokenizer = ffi::fts5_tokenizer {
            xCreate: Some(create),
            xDelete: Some(delete),
            xTokenize: Some(tokenize),
        };
        let code = (*api).xCreateTokenizer.unwrap()(
            api,
            c"findui".as_ptr(),
            ptr::null_mut(),
            &mut tokenizer,
            None,
        );
        if code != ffi::SQLITE_OK {
            return Err(rusqlite::Error::SqliteFailure(ffi::Error::new(code), None));
        }
    }
    Ok(())
}

/// Existing stored document text is re-tokenized once; source files and readers
/// are not revisited just to upgrade tokenization or add a stemming language.
pub fn prepare(db: &Connection, language: &str) -> rusqlite::Result<()> {
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version < 2 {
        db.execute_batch("BEGIN IMMEDIATE; DROP TRIGGER IF EXISTS insert_words; DROP TRIGGER IF EXISTS delete_words;
            DROP TABLE IF EXISTS word_terms; DROP TABLE IF EXISTS words; DROP TABLE IF EXISTS stems;
            PRAGMA user_version=2;")?;
        create_table(db, "words", "findui")?;
        create_table(db, "stems", "findui en")?;
        db.execute_batch(
            "CREATE VIRTUAL TABLE word_terms USING fts5vocab(words,instance); COMMIT;",
        )?;
    }
    if language != "en" {
        db.execute_batch("BEGIN IMMEDIATE")?;
        create_table(
            db,
            &format!("stems_{language}"),
            &format!("findui {language}"),
        )?;
        db.execute_batch("COMMIT")?;
    }
    Ok(())
}
fn create_table(db: &Connection, table: &str, tokenizer: &str) -> rusqlite::Result<()> {
    let exists: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?)",
        [table],
        |r| r.get(0),
    )?;
    if exists {
        return Ok(());
    }
    db.execute_batch(&format!("CREATE VIRTUAL TABLE {table} USING fts5(body,title,author,member,content='documents',content_rowid='id',tokenize='{tokenizer}');
        INSERT INTO {table}({table}) VALUES('rebuild');
        CREATE TRIGGER insert_{table} AFTER INSERT ON documents BEGIN
            INSERT INTO {table}(rowid,body,title,author,member) VALUES(new.id,new.body,new.title,new.author,new.member); END;
        CREATE TRIGGER delete_{table} AFTER DELETE ON documents BEGIN
            INSERT INTO {table}({table},rowid,body,title,author,member) VALUES('delete',old.id,old.body,old.title,old.author,old.member); END;"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dictionary_boundaries_stems_and_original_offsets() {
        let db = Connection::open_in_memory().unwrap();
        register(&db).unwrap();
        db.execute_batch(
            "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='findui fr');
            INSERT INTO t VALUES('Éléphants mangent. 中文搜索测试 ภาษาไทย');",
        )
        .unwrap();
        let highlighted: String = db
            .query_row(
                "SELECT highlight(t,0,'[',']') FROM t WHERE t MATCH ?",
                ["éléphant"],
                |r| r.get(0),
            )
            .unwrap();
        assert!(highlighted.starts_with("[Éléphants]"), "{highlighted}");
        let terms: i64 = db
            .query_row("SELECT count(*) FROM t WHERE t MATCH ?", ["搜索"], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(terms, 1);
    }
}

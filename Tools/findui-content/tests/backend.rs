use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
fn plan() -> Value {
    json!({"leaves":[{"pattern":"needle"}],"tree":{"leaf":0},"positive":[0],"stats":true})
}
fn tool(name: &str) -> Option<PathBuf> {
    let mut directories: Vec<_> =
        std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
    directories.extend([
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
    ]);
    let result = directories
        .into_iter()
        .map(|p| p.join(name))
        .find(|p| p.is_file());
    if result.is_none() {
        eprintln!("SKIP optional tool: {name}");
    }
    result
}
fn extraction(root: &Path, documents: bool, archives: bool) -> Value {
    json!({"documents":documents,"archives":archives,"cacheDirectory":root.join("cache"),"maxDepth":5,"maxMegabytes":8,"timeoutSeconds":10})
}
fn search(paths: &[&Path], plan: &Value) -> (i32, Vec<Value>, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .arg("--plan")
        .arg(plan.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut input = child.stdin.take().unwrap();
        for path in paths {
            input
                .write_all(path.as_os_str().as_encoded_bytes())
                .unwrap();
            input.write_all(&[0]).unwrap();
        }
    }
    let result = child.wait_with_output().unwrap();
    (
        result.status.code().unwrap_or(-1),
        String::from_utf8(result.stdout)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect(),
        String::from_utf8(result.stderr).unwrap(),
    )
}
fn statistics(log: &str) -> Value {
    serde_json::from_str(
        log.lines()
            .find_map(|l| l.strip_prefix("findui-stats: "))
            .unwrap(),
    )
    .unwrap()
}
fn zip(root: &Path, name: &str, files: &[&str]) -> std::path::PathBuf {
    let path = root.join(name);
    assert!(Command::new("/usr/bin/zip")
        .current_dir(root)
        .args(["-q", name])
        .args(files)
        .status()
        .unwrap()
        .success());
    path
}

#[test]
fn member_conversions_are_bounded_parallel_and_retry_only_failures() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let reader = root.path().join("reader");
    let script = format!(
        r##"#!/usr/bin/ruby
require 'json'
root = {root:?}
name = File.read(ARGV.last).include?('flaky') ? 'flaky' : 'good'
def update(root)
  File.open(File.join(root,'calls'), File::RDWR|File::CREAT, 0600) do |f|
    f.flock(File::LOCK_EX)
    raw=f.read; value=raw.empty? ? {{'active'=>0,'max'=>0,'good'=>0,'flaky'=>0}} : JSON.parse(raw)
    yield value
    f.rewind; f.truncate(0); f.write(JSON.generate(value))
  end
end
update(root) {{ |v| v[name]+=1; v['active']+=1; v['max']=[v['max'],v['active']].max }}
sleep 0.15
update(root) {{ |v| v['active']-=1 }}
exit 2 if name=='flaky' && !File.exist?(File.join(root,'ready'))
puts 'needle café'
"##,
        root = root.path().to_str().unwrap()
    );
    fs::write(&reader, script).unwrap();
    fs::set_permissions(&reader, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(root.path().join("good.html"), "<html>good</html>").unwrap();
    fs::write(root.path().join("flaky.html"), "<html>flaky</html>").unwrap();
    let archive = zip(root.path(), "source.zip", &["good.html", "flaky.html"]);
    let mut query = plan();
    query["threads"] = json!(2);
    query["encoding"] = json!("windows-1252");
    query["extraction"] = extraction(root.path(), true, true);
    query["extraction"]["pandoc"] = json!(reader);
    let (code, rows, _) = search(&[&archive], &query);
    assert_eq!(code, 2);
    assert_eq!(rows.len(), 1);
    assert!(rows[0]["data"]["lines"]["text"]
        .as_str()
        .unwrap()
        .contains("café"));
    let calls: Value =
        serde_json::from_slice(&fs::read(root.path().join("calls")).unwrap()).unwrap();
    assert_eq!(calls["max"], 2);
    fs::write(root.path().join("ready"), "").unwrap();
    let (code, rows, log) = search(&[&archive], &query);
    assert_eq!(code, 2, "{log}");
    assert_eq!(rows.len(), 1);
    assert!(log.contains("remembered failure"));
    let retry = std::process::Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .arg("--cache-retry")
        .arg(root.path().join("cache"))
        .output()
        .unwrap();
    assert!(
        retry.status.success(),
        "{}",
        String::from_utf8_lossy(&retry.stderr)
    );
    let (code, rows, log) = search(&[&archive], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2);
    let (code, rows, log) = search(&[&archive], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2);
    assert_eq!(statistics(&log)["documentsConverted"], 0);
    let calls: Value =
        serde_json::from_slice(&fs::read(root.path().join("calls")).unwrap()).unwrap();
    assert_eq!(calls["good"], 1);
    assert_eq!(calls["flaky"], 2);
    query["threads"] = json!(1);
    query["extraction"]
        .as_object_mut()
        .unwrap()
        .remove("cacheDirectory");
    fs::remove_file(root.path().join("calls")).unwrap();
    assert_eq!(search(&[&archive], &query).0, 0);
    let calls: Value =
        serde_json::from_slice(&fs::read(root.path().join("calls")).unwrap()).unwrap();
    assert_eq!(calls["max"], 1);
}

#[test]
fn word_boolean_file_and_document_units_remain_distinct() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("one.txt"), "alpha\n").unwrap();
    fs::write(root.path().join("two.txt"), "beta\n").unwrap();
    let archive = zip(root.path(), "source.zip", &["one.txt", "two.txt"]);
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    query["extraction"] = extraction(root.path(), false, true);
    assert_eq!(action("--prepare-words", &[&archive], &query).0, 0);
    query["leaves"] = json!([{"pattern":"alpha"},{"pattern":"beta"}]);
    query["positive"] = json!([0, 1]);
    query["tree"] = json!({"all":[{"leaf":0},{"leaf":1}]});
    query["fileUnit"] = json!(true);
    query["documentUnit"] = json!(true);
    assert!(action("--word-matches", &[], &query).1.is_empty());
    query["documentUnit"] = json!(false);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2);
    query["tree"] = json!({"all":[{"leaf":0},{"none":[{"leaf":1}]}]});
    query["positive"] = json!([0]);
    assert!(action("--word-matches", &[], &query).1.is_empty());
    query["documentUnit"] = json!(true);
    assert_eq!(action("--word-matches", &[], &query).1.len(), 1);
    query["extraction"]["archives"] = json!(false);
    assert!(action("--word-matches", &[], &query).1.is_empty());
}
#[test]
fn binary_members_do_not_poison_successful_cache() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("text.txt"), "needle\n").unwrap();
    fs::write(root.path().join("binary.bin"), b"\0binary").unwrap();
    let archive = zip(root.path(), "source.zip", &["text.txt", "binary.bin"]);
    let mut query = plan();
    query["extraction"] = extraction(root.path(), false, true);
    for iteration in 0..3 {
        let (code, rows, log) = search(&[&archive], &query);
        assert_eq!(code, 0, "{log}");
        assert_eq!(rows.len(), 1);
        if iteration > 0 {
            assert_eq!(statistics(&log)["documentsConverted"], 0);
            assert_eq!(statistics(&log)["documentCacheHits"], 1);
        }
    }
}
#[test]
fn member_predicates_skip_irrelevant_expansion_and_keep_disguised_containers() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("large.txt"), vec![b'x'; 2 * 1024 * 1024]).unwrap();
    fs::write(root.path().join("wanted.txt"), "needle\n").unwrap();
    let inner = zip(root.path(), "inner.zip", &["wanted.txt"]);
    fs::rename(inner, root.path().join("payload.bin")).unwrap();
    let archive = zip(
        root.path(),
        "source.zip",
        &["large.txt", "payload.bin", "wanted.txt"],
    );
    let mut query = plan();
    query["extraction"] = extraction(root.path(), false, true);
    query["extraction"]["maxMegabytes"] = json!(1);
    query["leaves"] = json!([{"pattern":"needle"},{"field":"member","pattern":"wanted.txt"}]);
    query["tree"] = json!({"all":[{"leaf":0},{"leaf":1}]});
    query["documentUnit"] = json!(true);
    query["fileUnit"] = json!(true);
    let (code, rows, log) = search(&[&archive], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2, "{rows:?}");
}
#[test]
fn emails_decode_charsets_and_keep_attachments_opt_in() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("message");
    fs::write(&path,b"From: Sender <sender@example.org>\r\nSubject: =?UTF-8?Q?caf=C3=A9?=\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=X\r\n\r\n--X\r\nContent-Type: text/plain; charset=windows-1252\r\n\r\nneedle caf\xe9\r\n--X\r\nContent-Type: text/plain\r\nContent-Disposition: attachment; filename=notes.txt\r\nContent-Transfer-Encoding: base64\r\n\r\nc2VjcmV0IG5lZWRsZQo=\r\n--X--\r\n").unwrap();
    let mut query = plan();
    query["extraction"] = extraction(root.path(), true, false);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert!(rows[0]["data"]["lines"]["text"]
        .as_str()
        .unwrap()
        .contains("café"));
    query["extraction"]["archives"] = json!(true);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2);
    assert!(rows
        .iter()
        .any(|r| r["data"]["findui_origin"]["members"][0]["kind"] == "mail"));
}
#[test]
fn sqlite_tables_have_provenance_and_wal_changes_invalidate_cache() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("records.txt");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE notes(id INTEGER PRIMARY KEY,body TEXT); INSERT INTO notes VALUES(1,'needle first'); CREATE VIEW unsafe_view AS SELECT randomblob(1000000000);").unwrap();
    let before = fs::read(&path).unwrap();
    let mut query = plan();
    query["extraction"] = extraction(root.path(), true, false);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["data"]["findui_origin"]["table"], "notes");
    assert_eq!(rows[0]["data"]["findui_origin"]["row"], "1");
    assert_eq!(fs::read(&path).unwrap(), before);
    db.execute("UPDATE notes SET body='needle changed'", [])
        .unwrap();
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert!(rows[0]["data"]["lines"]["text"]
        .as_str()
        .unwrap()
        .contains("changed"));
    assert_eq!(statistics(&log)["documentsConverted"], 1);
}
#[test]
fn explicit_encoding_and_typo_search_preserve_match_offsets() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("old.txt");
    fs::write(&path, b"caf\xe9 needl\n").unwrap();
    let mut query = plan();
    query["encoding"] = json!("windows-1252");
    query["typoTolerance"] = json!(1);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["data"]["lines"]["text"], "café needl\n");
    assert_eq!(rows[0]["data"]["submatches"][0]["start"], 6);
}

#[test]
fn context_uses_the_search_decoder_for_legacy_text_and_unicode_boms() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("old.txt");
    fs::write(&path, b"before\ncaf\xe9 needle\nafter\n").unwrap();
    let query = json!({"path":path,"line":2,"context":1,"encoding":"windows-1252","expectedSnippet":"café needle"});
    let (code, rows, log) = action("--text-preview", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows[0]["lines"][1]["text"], "café needle");
    assert!(rows[0]["warning"].is_null());
    let mut bytes = vec![0xff, 0xfe];
    for unit in "before\ncafé needle\nafter\n".encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    fs::write(&path, bytes).unwrap();
    let mut query = query;
    query["encoding"] = Value::Null;
    let (code, rows, log) = action("--text-preview", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows[0]["lines"][1]["text"], "café needle");
    assert!(rows[0]["warning"].is_null());
}
#[test]
fn whole_file_boolean_early_exit_waits_for_negative_evidence() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("large.txt");
    let mut bytes = b"alpha beta\n".to_vec();
    bytes.extend(vec![b'x'; 2 * 1024 * 1024]);
    bytes.extend_from_slice(b"\nforbidden\n");
    fs::write(&path, bytes).unwrap();
    let mut query = plan();
    query["fileUnit"] = json!(true);
    query["documentUnit"] = json!(true);
    query["leaves"] = json!([{"pattern":"alpha"},{"pattern":"beta"}]);
    query["tree"] = json!({"all":[{"leaf":0},{"leaf":1}]});
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert!(statistics(&log)["bytesSearched"].as_u64().unwrap() < 1024);
    query["leaves"] = json!([{"pattern":"alpha"},{"pattern":"forbidden"}]);
    query["tree"] = json!({"all":[{"leaf":0},{"none":[{"leaf":1}]}]});
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert!(rows.is_empty());
}
fn action(action: &str, paths: &[&Path], query: &Value) -> (i32, Vec<Value>, String) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .arg(action)
        .arg(query.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        for path in paths {
            stdin
                .write_all(path.as_os_str().as_encoded_bytes())
                .unwrap();
            stdin.write_all(&[0]).unwrap();
        }
    }
    let result = child.wait_with_output().unwrap();
    (
        result.status.code().unwrap_or(-1),
        String::from_utf8(result.stdout)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect(),
        String::from_utf8(result.stderr).unwrap(),
    )
}
#[test]
fn indexed_content_does_not_implicitly_search_member_names() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("needle.txt"), "Haystack only.\n").unwrap();
    let archive = zip(root.path(), "source.zip", &["needle.txt"]);
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    query["extraction"] = extraction(root.path(), false, true);
    assert_eq!(action("--prepare-words", &[&archive], &query).0, 0);
    assert!(search(&[&archive], &query).1.is_empty());
    assert!(action("--word-matches", &[], &query).1.is_empty());
    query["leaves"][0]["field"] = json!("member");
    assert_eq!(action("--word-matches", &[], &query).1.len(), 1);
}

#[test]
fn indexed_highlights_preserve_control_bytes_and_source_offsets() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("control.txt");
    // Include both the old marker bytes and the longer fallback prefix.
    let body = "before\u{1}after needle tail\u{2} \u{1}findui:0:open\u{2}\n";
    fs::write(&path, body).unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    assert_eq!(action("--prepare-words", &[&path], &query).0, 0);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows[0]["data"]["lines"]["text"], body);
    assert_eq!(
        rows[0]["data"]["submatches"][0]["start"],
        body.find("needle").unwrap()
    );
    query["tree"] = json!({"none":[{"leaf":0}]});
    query["leaves"][0]["pattern"] = json!("absent");
    query["positive"] = json!([]);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows[0]["data"]["lines"]["text"], body);
    assert_eq!(rows[0]["data"]["submatches"], json!([]));
}

#[test]
fn concurrent_word_preparations_reuse_the_committed_source() {
    use std::{
        os::unix::fs::PermissionsExt,
        time::{Duration, Instant},
    };
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("source.html");
    fs::write(&path, "<html>needle</html>").unwrap();
    let reader = root.path().join("reader");
    let started = root.path().join("started");
    fs::write(
        &reader,
        format!(
            "#!/bin/sh\ntouch '{}'\nsleep 1\nprintf 'needle\\n'\n",
            started.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&reader, fs::Permissions::from_mode(0o700)).unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    query["extraction"] = extraction(root.path(), true, false);
    query["extraction"]["pandoc"] = json!(reader);
    // Initialize the schema before testing contention on the same source.
    assert_eq!(action("--prepare-words", &[], &query).0, 0);
    std::thread::scope(|scope| {
        let first = scope.spawn(|| action("--prepare-words", &[&path], &query));
        let deadline = Instant::now() + Duration::from_secs(10);
        while !started.exists() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        let second = action("--prepare-words", &[&path], &query);
        let first = first.join().unwrap();
        assert_eq!(first.0, 0, "{}", first.2);
        assert_eq!(second.0, 0, "{}", second.2);
        let stats = [statistics(&first.2), statistics(&second.2)];
        assert_eq!(
            stats
                .iter()
                .map(|s| s["indexesUpdated"].as_u64().unwrap())
                .sum::<u64>(),
            1
        );
        assert_eq!(
            stats
                .iter()
                .map(|s| s["filesSkippedByIndex"].as_u64().unwrap())
                .sum::<u64>(),
            1
        );
    });
}
#[test]
fn prepared_words_are_explicit_ranked_stemmed_and_updated_incrementally() {
    let root = tempfile::tempdir().unwrap();
    let strong = root.path().join("strong.txt");
    let weak = root.path().join("weak.txt");
    fs::write(&strong, "connecting needle needle needle\n").unwrap();
    fs::write(&weak, format!("needle {}\n", "irrelevant ".repeat(150))).unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    let (code, _, _) = action("--word-matches", &[], &query);
    assert_eq!(code, 2);
    let (code, _, log) = action("--prepare-words", &[&strong, &weak], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(statistics(&log)["indexesUpdated"], 2);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["data"]["path"]["text"], strong.to_str().unwrap());
    let (code, _, log) = action("--prepare-words", &[&strong, &weak], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(statistics(&log)["filesSkippedByIndex"], 2);
    query["leaves"] = json!([{"pattern":"connect"}]);
    assert!(action("--word-matches", &[], &query).1.is_empty());
    query["stemWords"] = json!(true);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0]["data"]["submatches"][0]["match"]["text"],
        "connecting"
    );
    fs::write(&strong, "needle changed\n").unwrap();
    assert!(action("--word-matches", &[], &query).1.is_empty());
    let (code, _, log) = action("--prepare-words", &[&strong, &weak], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(statistics(&log)["indexesUpdated"], 1);
    assert_eq!(statistics(&log)["filesSkippedByIndex"], 1);
}
#[test]
fn word_indexes_never_enable_previously_cached_attachments() {
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("text.txt"), "needle\n").unwrap();
    let archive = zip(root.path(), "source.zip", &["text.txt"]);
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    query["extraction"] = extraction(root.path(), false, true);
    let (code, _, log) = action("--prepare-words", &[&archive], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(action("--word-matches", &[], &query).1.len(), 1);
    query.as_object_mut().unwrap().remove("extraction");
    assert!(action("--word-matches", &[], &query).1.is_empty());
}

#[test]
fn prepared_words_push_scope_into_sql_before_reading_other_sources() {
    let root = tempfile::tempdir().unwrap();
    let folder = root.path().join("docs");
    let other = root.path().join("docs-other");
    fs::create_dir(&folder).unwrap();
    fs::create_dir(&other).unwrap();
    let one = folder.join("one.txt");
    let two = other.join("two.txt");
    fs::write(&one, "needle\n").unwrap();
    fs::write(&two, "needle\n").unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    assert_eq!(action("--prepare-words", &[&one, &two], &query).0, 0);
    fs::remove_file(&two).unwrap();
    query["wordRoots"] = json!([folder]);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert!(
        !log.contains("changed or missing"),
        "Out-of-scope files should not be inspected: {log}"
    );
}
#[test]
fn pdf_attachments_are_explicit_and_can_be_materialized() {
    let Some(detach) = tool("pdfdetach") else {
        return;
    };
    let Some(pdftotext) = tool("pdftotext") else {
        return;
    };
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("attachment.pdf");
    let payload = "needle in attachment\n";
    let objects=vec!["<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(notes.txt) 5 0 R] >> >> >>".to_string(),
        "<< /Type /Pages /Count 1 /Kids [3 0 R] >>".into(),"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>".into(),
        "<< /Length 0 >>\nstream\n\nendstream".into(),"<< /Type /Filespec /F (notes.txt) /EF << /F 6 0 R >> >>".into(),format!("<< /Type /EmbeddedFile /Length {} >>\nstream\n{payload}endstream",payload.len())];
    let mut pdf = b"%PDF-1.7\n".to_vec();
    let mut offsets = Vec::new();
    for (i, object) in objects.iter().enumerate() {
        offsets.push(pdf.len());
        pdf.extend_from_slice(format!("{} 0 obj\n{object}\nendobj\n", i + 1).as_bytes());
    }
    let xref = pdf.len();
    pdf.extend_from_slice(
        format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).as_bytes(),
    );
    for offset in offsets {
        pdf.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
    }
    pdf.extend_from_slice(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .as_bytes(),
    );
    fs::write(&path, pdf).unwrap();
    let mut query = plan();
    query["extraction"] = extraction(root.path(), false, true);
    query["extraction"]["pdfdetach"] = json!(detach);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    let origin = &rows[0]["data"]["findui_origin"];
    assert_eq!(origin["members"][0]["kind"], "pdf");
    let request = json!({"path":path,"origin":origin,"extraction":query["extraction"]});
    let (code, files, log) = action("--materialize-member", &[], &request);
    assert_eq!(code, 0, "{log}");
    let materialized = PathBuf::from(files[0]["path"].as_str().unwrap());
    assert_eq!(fs::read_to_string(&materialized).unwrap(), payload);
    fs::remove_file(materialized).unwrap();
    query["extraction"]["documents"] = json!(true);
    query["extraction"]["archives"] = json!(false);
    query["extraction"]["pdftotext"] = json!(pdftotext);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert!(rows.is_empty());
}

#[test]
fn fuzzy_session_preserves_ranking_and_invalidates_input_changes() {
    let Ok(which) = Command::new("/usr/bin/which").arg("fzf").output() else {
        return;
    };
    if !which.status.success() {
        return;
    }
    let fzf = String::from_utf8(which.stdout).unwrap().trim().to_string();
    let root = tempfile::tempdir().unwrap();
    let cache = root.path().join("fuzzy");
    let input = b"/files/alpha-beta.txt\0/files/abacus.txt\0/files/other.txt\0/files/alpha-ball.txt\0/files/ABC.txt\0";
    let execute = |exe: &str, args: &[String], input: &[u8]| {
        let mut child = Command::new(exe)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let result = child.wait_with_output().unwrap();
        assert!(
            matches!(result.status.code(), Some(0 | 1)),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        result.stdout
    };
    for candidate_input in [
        input.as_slice(),
        b"/files/new-abc.txt\0/files/alpha-ball.txt\0/files/abacus.txt\0",
    ] {
        for query in ["a", "ab", "abc", "ab", "ab c", "other", ""] {
            for basename in [true, false] {
                let config = json!({"executable":fzf,"query":query,"basename":basename,"caseSensitive":false,"cacheDirectory":cache});
                let cached = execute(
                    env!("CARGO_BIN_EXE_findui-content"),
                    &["--fuzzy".into(), config.to_string()],
                    candidate_input,
                );
                let mut args = vec![
                    "--read0",
                    "--print0",
                    "--no-extended",
                    "--literal",
                    "--scheme=path",
                    "--algo=v2",
                    "--ignore-case",
                    "--filter",
                    query,
                ];
                if basename {
                    args.extend(["--delimiter", "/", "--nth", "-1"]);
                }
                let direct = execute(
                    &fzf,
                    &args.into_iter().map(str::to_owned).collect::<Vec<_>>(),
                    candidate_input,
                );
                assert_eq!(cached, direct, "{query}, basename {basename}");
            }
        }
    }
}

#[test]
fn word_candidates_render_only_selected_bodies_and_reject_changed_generations() {
    let root = tempfile::tempdir().unwrap();
    let one = root.path().join("one.txt");
    let two = root.path().join("two.txt");
    fs::write(&one, "needle one\n").unwrap();
    fs::write(&two, "needle two\n".repeat(10000)).unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    assert_eq!(action("--prepare-words", &[&one, &two], &query).0, 0);
    let (code, rows, log) = action("--word-candidates", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 2);
    assert!(!rows
        .iter()
        .any(|r| r["data"]["lines"]["text"].as_str().is_some()));
    let spool = root.path().join("candidates.json");
    fs::write(
        &spool,
        rows.iter().map(|r| format!("{r}\n")).collect::<String>(),
    )
    .unwrap();
    let render = || {
        let mut child = Command::new(env!("CARGO_BIN_EXE_findui-content"))
            .args([
                "--word-render",
                &query.to_string(),
                spool.to_str().unwrap(),
                "rank",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        input.write_all(one.as_os_str().as_encoded_bytes()).unwrap();
        input.write_all(&[0]).unwrap();
        drop(input);
        child.wait_with_output().unwrap()
    };
    let rendered = render();
    assert!(
        rendered.status.success(),
        "{}",
        String::from_utf8_lossy(&rendered.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&rendered.stdout).lines().count(), 1);
    assert_eq!(
        statistics(&String::from_utf8_lossy(&rendered.stderr))["wordSnippets"],
        1
    );
    fs::write(&two, "needle changed\n").unwrap();
    assert_eq!(action("--prepare-words", &[&two], &query).0, 0);
    let changed = render();
    assert!(!changed.status.success());
    assert!(changed.stdout.is_empty());
    assert!(String::from_utf8_lossy(&changed.stderr).contains("changed"));
}

#[test]
fn fuzzy_cache_failure_keeps_results_and_errors_propagate() {
    let Some(fzf) = tool("fzf") else {
        return;
    };
    let root = tempfile::tempdir().unwrap();
    let blocked = root.path().join("not-a-directory");
    fs::write(&blocked, "occupied").unwrap();
    let query = json!({"executable":fzf,"query":"abc","basename":false,"caseSensitive":false,"cacheDirectory":blocked});
    let mut child = Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .args(["--fuzzy", &query.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"/file/abc.txt\0/other.txt\0")
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(result.status.success());
    assert_eq!(result.stdout, b"/file/abc.txt\0");
    assert_eq!(fs::read(&blocked).unwrap(), b"occupied");
    let mut invalid = query;
    invalid["executable"] = json!("/missing-findui-fzf");
    assert!(!Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .args(["--fuzzy", &invalid.to_string()])
        .status()
        .unwrap()
        .success());
}

#[test]
fn multiline_regex_and_preview_preserve_original_lines() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("multi.txt");
    fs::write(&path, "before\nalpha café\nbeta 🙂\nafter\n").unwrap();
    let mut query = plan();
    query["multiline"] = json!(true);
    query["leaves"] = json!([{"pattern":"alpha[^\\n]*\\nbeta", "regex":true}]);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["data"]["line_number"], 2);
    assert_eq!(
        rows[0]["data"]["submatches"][0]["match"]["text"],
        "alpha café\nbeta"
    );
    let expected = rows[0]["data"]["lines"]["text"]
        .as_str()
        .unwrap()
        .trim_end_matches('\n');
    let result = Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .arg("--text-preview")
        .arg(json!({"path":path,"line":2,"context":1,"expectedSnippet":expected}).to_string())
        .output()
        .unwrap();
    assert!(result.status.success());
    let preview: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert!(preview["warning"].is_null(), "{preview}");
    assert_eq!(
        preview["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["number"].as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![1, 2, 4]
    );
    query["multiline"] = json!(false);
    assert_ne!(search(&[&path], &query).0, 0);
}

#[test]
fn language_preparation_reuses_text_and_keeps_unicode_highlights() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("text.txt");
    fs::write(&path, "Éléphants mangent. 中文搜索测试 snake_case.txt\n").unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    query["wordLanguage"] = json!("fr");
    query["stemWords"] = json!(true);
    let (code, _, log) = action("--prepare-words", &[&path], &query);
    assert_eq!(code, 0, "{log}");
    query["leaves"] = json!([{"pattern":"éléphant"}]);
    let (code, rows, log) = action("--word-matches", &[], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0]["data"]["submatches"][0]["match"]["text"],
        "Éléphants"
    );
    query["wordLanguage"] = json!("de");
    let missing = Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .args(["--word-status", &query.to_string()])
        .output()
        .unwrap();
    assert!(missing.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&missing.stdout).unwrap()["state"],
        "needsUpdate"
    );
    let (code, _, log) = action("--prepare-words", &[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(statistics(&log)["filesSkippedByIndex"], 1);
    assert_eq!(statistics(&log)["indexesUpdated"], 0);
    query["stemWords"] = json!(false);
    for token in ["搜索", "snake", "case", "txt"] {
        query["leaves"] = json!([{"pattern":token}]);
        assert_eq!(action("--word-matches", &[], &query).1.len(), 1, "{token}");
    }
}

#[test]
fn custom_readers_keep_argv_literal_cache_identity_and_opt_in_words() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("a $(touch unsafe).custom");
    fs::write(&path, "opaque").unwrap();
    let reader = root.path().join("reader");
    fs::write(
        &reader,
        "#!/bin/sh\nprintf '%s\\n' \"$1\"\nprintf 'needle\\n'\n",
    )
    .unwrap();
    fs::set_permissions(&reader, fs::Permissions::from_mode(0o700)).unwrap();
    let mut query = plan();
    query["indexDirectory"] = json!(root.path().join("cache"));
    query["extraction"] = extraction(root.path(), false, false);
    query["extraction"]["adapters"] = json!([{"id":"fixture","title":"Fixture reader","extensions":["custom"],"executable":reader,"arguments":["{path}"]}]);
    let (code, rows, log) = search(&[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["data"]["findui_origin"]["reader"], "Fixture reader");
    assert!(!root.path().join("unsafe").exists());
    assert_eq!(
        statistics(&search(&[&path], &query).2)["documentsConverted"],
        0
    );
    let (code, _, log) = action("--prepare-words", &[&path], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(action("--word-matches", &[], &query).1.len(), 1);
    let mut disabled = query.clone();
    disabled.as_object_mut().unwrap().remove("extraction");
    assert!(action("--word-matches", &[], &disabled).1.is_empty());
    fs::write(&reader, "#!/bin/sh\nprintf 'different text\\n'\n").unwrap();
    assert!(search(&[&path], &query).1.is_empty());
}

#[test]
fn converted_multiline_text_has_the_same_matching_blocks_as_plain_text() {
    let root = tempfile::tempdir().unwrap();
    let plain = root.path().join("source.txt");
    let custom = root.path().join("source.custom");
    let text = "before\nalpha\nbeta\nafter\nseparate\nalpha\nbeta\nlast\n";
    fs::write(&plain, text).unwrap();
    fs::write(&custom, text).unwrap();
    let mut query = plan();
    query["multiline"] = json!(true);
    query["leaves"] = json!([{"pattern":"alpha\\nbeta","regex":true}]);
    let original = search(&[&plain], &query);
    assert_eq!(original.0, 0, "{}", original.2);
    assert_eq!(original.1.len(), 2);
    query["extraction"] = extraction(root.path(), false, false);
    query["extraction"]["adapters"] = json!([{"id":"plain","title":"Plain text fixture","extensions":["custom"],"executable":"/bin/cat","arguments":["{path}"]}]);
    let converted = search(&[&custom], &query);
    assert_eq!(converted.0, 0, "{}", converted.2);
    let snippets = |rows: &Vec<Value>| {
        rows.iter()
            .map(|r| r["data"]["lines"].clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(snippets(&converted.1), snippets(&original.1));
    assert_eq!(converted.1[0]["data"]["findui_origin"]["line"], 2);
    assert_eq!(converted.1[1]["data"]["findui_origin"]["line"], 6);
}

#[test]
fn media_subtitles_are_explicit_cached_and_keep_timecodes() {
    let (Some(ffmpeg), Some(ffprobe)) = (tool("ffmpeg"), tool("ffprobe")) else {
        return;
    };
    let root = tempfile::tempdir().unwrap();
    let subtitle = root.path().join("text.srt");
    fs::write(
        &subtitle,
        "1\n00:00:01,000 --> 00:00:02,000\nneedle café\n\n",
    )
    .unwrap();
    let media = root.path().join("fixture.mkv");
    let make = Command::new(&ffmpeg)
        .args(["-v", "error", "-i"])
        .arg(&subtitle)
        .args(["-c:s", "srt"])
        .arg(&media)
        .output()
        .unwrap();
    assert!(
        make.status.success(),
        "{}",
        String::from_utf8_lossy(&make.stderr)
    );
    let mut query = plan();
    query["extraction"] = extraction(root.path(), false, false);
    query["extraction"]["media"] = json!(true);
    query["extraction"]["ffmpeg"] = json!(ffmpeg);
    query["extraction"]["ffprobe"] = json!(ffprobe);
    let (code, rows, log) = search(&[&media], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["data"]["findui_origin"]["timecode"], "00:00:01,000");
    assert_eq!(
        statistics(&search(&[&media], &query).2)["documentsConverted"],
        0
    );
    query["indexDirectory"] = json!(root.path().join("cache"));
    let (code, _, log) = action("--prepare-words", &[&media], &query);
    assert_eq!(code, 0, "{log}");
    assert_eq!(action("--word-matches", &[], &query).1.len(), 1);
    query["extraction"]["media"] = json!(false);
    query["extraction"]["documents"] = json!(true);
    assert!(action("--word-matches", &[], &query).1.is_empty());
    assert!(search(&[&media], &query).1.is_empty());
}

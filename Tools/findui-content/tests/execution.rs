use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    fs,
    process::{Command, Output},
};
fn request(root: &std::path::Path) -> Value {
    json!({"version":1,"source":{"kind":"live"},"traversal":{"roots":[root],"hidden":true,"ignored":false,"ignorePolicy":"ripgrep","follow":false,"minimumDepth":1,"packages":true,"kind":"f"},
        "action":"search","unit":"line","output":"matches","budget":{"workers":4,"conversionWorkers":4,"memoryBytes":67108864},
        "content":{"tree":{"leaf":0},"leaves":[{"pattern":"alpha"}],"positive":[0],"threads":4,"stats":true}})
}
fn run(plan: &Value) -> Output {
    Command::new(env!("CARGO_BIN_EXE_findui-content"))
        .args(["--execute", &plan.to_string()])
        .output()
        .unwrap()
}
fn lines(output: &Output) -> Vec<Value> {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout.clone())
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}
fn completion(output: &Output) -> Value {
    serde_json::from_str(
        String::from_utf8_lossy(&output.stderr)
            .lines()
            .find_map(|l| l.strip_prefix("findui-completion: "))
            .expect("completion record"),
    )
    .unwrap()
}
fn paths(output: &Output) -> BTreeSet<String> {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout.clone())
        .unwrap()
        .split('\0')
        .filter(|p| !p.is_empty())
        .map(str::to_owned)
        .collect()
}
#[test]
fn fused_boolean_scan_opens_each_selected_file_once_and_reports_completion() {
    let root = tempfile::tempdir().unwrap();
    for i in 0..24 {
        fs::write(
            root.path().join(format!("{i}.txt")),
            "alpha beta\nalpha banned\nbeta\n",
        )
        .unwrap();
    }
    let mut plan = request(root.path());
    plan["content"]["leaves"] =
        json!([{"pattern":"alpha"},{"pattern":"alpha"},{"pattern":"beta"},{"pattern":"banned"}]);
    plan["content"]["tree"] =
        json!({"all":[{"any":[{"leaf":0},{"leaf":1}]},{"leaf":2},{"none":[{"leaf":3}]}]});
    plan["content"]["positive"] = json!([0, 1, 2]);
    let result = run(&plan);
    let rows = lines(&result);
    assert_eq!(rows.len(), 24);
    assert!(rows
        .iter()
        .all(|r| r["data"]["lines"]["text"] == "alpha beta\n"));
    let stderr = String::from_utf8_lossy(&result.stderr);
    let stats: Value = serde_json::from_str(
        stderr
            .lines()
            .find_map(|l| l.strip_prefix("findui-stats: "))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(stats["filesOpened"], 24);
    assert_eq!(stats["uniqueMatchers"], 3);
    assert_eq!(stats["workers"], 4);
    assert_eq!(completion(&result)["status"], "complete");
}
#[test]
fn boolean_unit_and_negation_match_an_independent_oracle() {
    let root = tempfile::tempdir().unwrap();
    let fixtures = [
        ("both.txt", "alpha beta\n"),
        ("split.txt", "alpha\nbeta\n"),
        ("alpha.txt", "alpha\n"),
        ("neither.txt", "gamma\n"),
    ];
    for (name, body) in fixtures {
        fs::write(root.path().join(name), body).unwrap();
    }
    for workers in [1, 4] {
        for tree in [
            json!({"all":[{"leaf":0},{"leaf":1}]}),
            json!({"any":[{"leaf":0},{"leaf":1}]}),
            json!({"all":[{"leaf":0},{"none":[{"leaf":1}]}]}),
        ] {
            for unit in ["line", "file"] {
                let mut plan = request(root.path());
                plan["budget"]["workers"] = json!(workers);
                plan["content"]["leaves"] = json!([{"pattern":"alpha"},{"pattern":"beta"}]);
                plan["content"]["tree"] = tree.clone();
                plan["unit"] = json!(unit);
                plan["content"]["fileUnit"] = json!(unit == "file");
                plan["content"]["filesOnly"] = json!(true);
                plan["output"] = json!("paths");
                let expected: BTreeSet<_> = fixtures
                    .iter()
                    .filter(|(_, body)| {
                        let predicate = |s: &str| {
                            if tree.get("any").is_some() {
                                s.contains("alpha") || s.contains("beta")
                            } else if tree["all"][1].get("none").is_some() {
                                s.contains("alpha") && !s.contains("beta")
                            } else {
                                s.contains("alpha") && s.contains("beta")
                            }
                        };
                        if unit == "file" {
                            predicate(body)
                        } else {
                            body.lines().any(predicate)
                        }
                    })
                    .map(|(name, _)| root.path().join(name).to_string_lossy().into_owned())
                    .collect();
                assert_eq!(
                    paths(&run(&plan)),
                    expected,
                    "{tree}, {unit}, workers {workers}"
                );
            }
        }
    }
}
#[test]
fn explicit_ignore_policy_is_stable_when_adding_file_predicates() {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join(".git")).unwrap();
    for name in ["fd-only.txt", "rg-only.txt", "git-only.txt", "allowed.txt"] {
        fs::write(root.path().join(name), "alpha\n").unwrap();
    }
    fs::write(root.path().join(".gitignore"), "git-only.txt\n").unwrap();
    fs::write(root.path().join(".fdignore"), "fd-only.txt\n").unwrap();
    fs::write(root.path().join(".rgignore"), "rg-only.txt\n").unwrap();
    for policy in ["fd", "ripgrep"] {
        let mut plan = request(root.path());
        plan["traversal"]["ignorePolicy"] = json!(policy);
        plan["paths"] = json!({"roots":[root.path()],"hidden":true,"packages":true,"type":"f","minimumDepth":1,"semantics":"native","conditions":[{"field":"name","value":"\\.txt\\z","regex":true}]});
        let rows = lines(&run(&plan));
        let actual: BTreeSet<_> = rows
            .iter()
            .map(|r| {
                std::path::Path::new(r["data"]["path"]["text"].as_str().unwrap())
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        assert_eq!(
            actual,
            [
                "allowed.txt",
                if policy == "fd" {
                    "rg-only.txt"
                } else {
                    "fd-only.txt"
                }
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
    }
}
#[test]
fn versions_units_and_unknown_outer_fields_fail_loudly() {
    let root = tempfile::tempdir().unwrap();
    for mutation in ["version", "unit", "typo"] {
        let mut plan = request(root.path());
        match mutation {
            "version" => plan["version"] = json!(99),
            "unit" => plan["unit"] = json!("file"),
            _ => plan["silentTypo"] = json!(true),
        }
        let output = run(&plan);
        assert!(!output.status.success());
        assert_eq!(completion(&output)["status"], "failed");
        assert!(output.stdout.is_empty());
    }
}

#[test]
fn contradictory_tree_operators_and_unknown_content_fields_are_rejected() {
    let root = tempfile::tempdir().unwrap();
    for tree in [
        json!({"leaf":0,"none":[]}),
        json!({"all":[],"any":[]}),
        json!({"leaf":0,"typo":true}),
    ] {
        let mut plan = request(root.path());
        plan["content"]["tree"] = tree;
        let out = run(&plan);
        assert!(!out.status.success());
        assert_eq!(completion(&out)["status"], "failed");
    }
    let mut plan = request(root.path());
    plan["content"]["caseSensitiv"] = json!(true);
    assert!(!run(&plan).status.success());
}

#[test]
fn overlapping_root_aliases_do_not_repeat_body_work() {
    let root = tempfile::tempdir().unwrap();
    let nested = root.path().join("nested");
    fs::create_dir(&nested).unwrap();
    fs::write(nested.join("a.txt"), "alpha\n").unwrap();
    let alias = root.path().with_extension("alias");
    std::os::unix::fs::symlink(root.path(), &alias).unwrap();
    let mut plan = request(root.path());
    plan["traversal"]["roots"] = json!([root.path(), nested, alias]);
    let result = run(&plan);
    fs::remove_file(alias).unwrap();
    assert_eq!(lines(&result).len(), 1);
}

#[test]
fn manifest_root_aliases_and_repeated_frozen_records_are_deduplicated() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("a.txt");
    fs::write(&file, "alpha\n").unwrap();
    let alias = root.path().join("alias");
    std::os::unix::fs::symlink(root.path(), &alias).unwrap();
    let list = root.path().join("paths");
    fs::write(
        &list,
        format!(
            "{}\0{}\0{}\0",
            file.display(),
            alias.join("a.txt").display(),
            file.display()
        ),
    )
    .unwrap();
    let mut plan = request(&alias);
    plan["source"] = json!({"kind":"manifest","path":list});
    let result = run(&plan);
    assert_eq!(lines(&result).len(), 1);
    let stderr = String::from_utf8_lossy(&result.stderr);
    let stats: Value = serde_json::from_str(
        stderr
            .lines()
            .find_map(|l| l.strip_prefix("findui-stats: "))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(stats["filesOpened"], 1);

    let record =
        json!({"path":file,"directory":false,"size":6,"modified":null,"created":null,"tags":[]});
    // Different JSON encodings of the same frozen path must not repeat it.
    fs::write(
        &list,
        format!(
            "{}\0{}\0",
            record,
            serde_json::to_string_pretty(&record).unwrap()
        ),
    )
    .unwrap();
    plan["source"]["kind"] = json!("records");
    plan["output"] = json!("paths");
    plan.as_object_mut().unwrap().remove("content");
    let result = run(&plan);
    assert!(result.status.success());
    assert_eq!(
        result
            .stdout
            .split(|b| *b == 0)
            .filter(|p| !p.is_empty())
            .count(),
        1
    );
}

#[test]
fn malformed_frozen_records_report_partial_and_keep_other_results() {
    let root = tempfile::tempdir().unwrap();
    let list = root.path().join("records");
    let record = json!({"path":root.path().join("visible.txt"),"directory":false,"size":10,"modified":null,"created":null,"tags":[]});
    fs::write(&list, format!("invalid\0{record}\0")).unwrap();
    let plan = json!({"version":1,"source":{"kind":"records","path":list},"action":"search","unit":"line","output":"paths",
        "budget":{"workers":4,"conversionWorkers":4,"memoryBytes":67108864},
        "paths":{"roots":[root.path()],"hidden":true,"packages":true,"type":"f","minimumDepth":1,"semantics":"native","tree":{"all":[]},"leaves":[]}});
    let result = run(&plan);
    assert!(!result.status.success());
    assert_eq!(completion(&result)["status"], "partial");
    assert_eq!(completion(&result)["skipped"], 1);
    assert!(String::from_utf8(result.stdout)
        .unwrap()
        .ends_with("visible.txt\0"));
}

#[cfg(target_os = "macos")]
#[test]
fn word_freshness_replays_changes_and_recovers_from_missing_checkpoint() {
    let temporary = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(temporary.path()).unwrap();
    let files = root.join("files");
    fs::create_dir(&files).unwrap();
    let source = files.join("source.txt");
    fs::write(&source, "alpha\n").unwrap();
    let mut plan = request(&files);
    plan["action"] = json!("prepareWords");
    plan["content"]["indexDirectory"] = json!(root.join("cache"));
    plan["content"]["wordRoots"] = json!([files]);
    plan["content"]["wordScope"] = json!({"unfiltered":true,"traversal":{"follow":false}});
    let output = run(&plan);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let status = || {
        let output = Command::new(env!("CARGO_BIN_EXE_findui-content"))
            .env("FINDUI_WORD_FRESHNESS", "events")
            .args(["--word-status", &plan["content"].to_string()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Value>(&output.stdout).unwrap()
    };
    assert_eq!(status()["state"], "updated");
    let warm = status();
    assert_eq!(warm["state"], "updated");
    // Some CI sandboxes do not grant event replay; conservative metadata checks
    // are valid there. Both routes must notice mutations immediately.
    assert!(["metadata", "filesystemEvents"].contains(&warm["verification"].as_str().unwrap()));
    fs::write(&source, "beta changed\n").unwrap();
    assert_eq!(status()["state"], "needsUpdate");
    assert!(run(&plan).status.success());
    assert_eq!(status()["state"], "updated");
    fs::write(files.join("new.txt"), "gamma").unwrap();
    assert_eq!(status()["state"], "needsUpdate");
    assert!(run(&plan).status.success());
    assert_eq!(status()["state"], "updated");
    fs::remove_dir_all(root.join("cache/freshness-v1")).unwrap();
    let recovered = status();
    assert_eq!(recovered["state"], "updated");
    assert_eq!(recovered["verification"], "metadata");
    let outside = root.join("outside.txt");
    fs::hard_link(&source, &outside).unwrap();
    assert!(run(&plan).status.success());
    assert_eq!(status()["verification"], "metadata");
    fs::write(&outside, "changed through a hard link").unwrap();
    assert_eq!(status()["state"], "needsUpdate");
}

#[test]
fn word_freshness_narrows_prepared_parents_and_preserves_component_boundaries() {
    let temporary = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(temporary.path()).unwrap();
    let files = root.join("files");
    let selected = files.join("selected");
    let sibling = files.join("selected-backup");
    fs::create_dir_all(&selected).unwrap();
    fs::create_dir_all(&sibling).unwrap();
    fs::write(selected.join("one.txt"), "alpha\n").unwrap();
    fs::write(sibling.join("two.txt"), "alpha\n").unwrap();
    let mut plan = request(&files);
    plan["action"] = json!("prepareWords");
    plan["content"]["indexDirectory"] = json!(root.join("cache"));
    plan["content"]["wordRoots"] = json!([files]);
    plan["content"]["wordScope"] = json!({"unfiltered":true,"traversal":{"follow":false}});
    assert!(run(&plan).status.success());
    plan["content"]["wordRoots"] = json!([selected]);
    let status = |plan: &Value| {
        let output = Command::new(env!("CARGO_BIN_EXE_findui-content"))
            .env("FINDUI_WORD_FRESHNESS", "metadata")
            .args(["--word-status", &plan["content"].to_string()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice::<Value>(&output.stdout).unwrap()
    };
    assert_eq!(status(&plan)["sources"], 1);
    fs::write(sibling.join("two.txt"), "changed outside requested folder").unwrap();
    assert_eq!(status(&plan)["state"], "updated");
    // A large root list must not exceed SQLite's expression-depth limit.
    plan["content"]["wordRoots"] = json!(vec![selected.clone(); 1024]);
    assert_eq!(status(&plan)["sources"], 1);
    assert_eq!(status(&plan)["state"], "updated");
    // Invalid folder scopes retain their existing unavailable diagnosis and
    // source count, including a root that names a prepared file itself.
    plan["content"]["wordRoots"] = json!([selected.join("one.txt")]);
    assert_eq!(status(&plan)["sources"], 1);
    assert_eq!(status(&plan)["state"], "unavailable");
    plan["content"]["wordRoots"] = json!([selected]);
    // A scope without a matching run uses the same path bounds and reports
    // partial preparation rather than silently treating other files as covered.
    plan["content"]["wordScope"] = json!({"unfiltered":false,"traversal":{"follow":true}});
    assert_eq!(status(&plan)["sources"], 1);
    assert_eq!(status(&plan)["state"], "partial");
    fs::write(selected.join("one.txt"), "changed within requested folder").unwrap();
    assert_eq!(status(&plan)["state"], "needsUpdate");
}

#[test]
fn empty_word_candidates_skip_ranking_but_still_check_freshness() {
    let temporary = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(temporary.path()).unwrap();
    let files = root.join("files");
    fs::create_dir(&files).unwrap();
    let source = files.join("source.txt");
    fs::write(&source, "alpha\n").unwrap();
    let mut plan = request(&files);
    plan["action"] = json!("prepareWords");
    plan["content"]["indexDirectory"] = json!(root.join("cache"));
    plan["content"]["wordRoots"] = json!([files]);
    plan["content"]["wordScope"] = json!({"unfiltered":true,"traversal":{"follow":false}});
    assert!(run(&plan).status.success());
    plan["action"] = json!("wordSearch");
    plan["content"]["leaves"] = json!([{"pattern":"absentfixtureterm"}]);
    plan["selection"] = json!({"predicates":{"roots":[files],"tree":{"leaf":0},"leaves":[{}]},
        "fuzzies":[{"leaf":0,"invocation":{"executable":"/usr/bin/false","arguments":[],"environment":{},"unsetEnvironment":[],"emptyExitCodes":[]}}]});
    for expected in ["updated", "needsUpdate"] {
        if expected == "needsUpdate" {
            fs::write(&source, "different source contents\n").unwrap();
        }
        let result = run(&plan);
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(result.stdout.is_empty());
        assert_eq!(completion(&result)["status"], "complete");
        let diagnostics = String::from_utf8_lossy(&result.stderr);
        let status: Value = serde_json::from_str(
            diagnostics
                .lines()
                .find_map(|line| line.strip_prefix("findui-word-status: "))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(status["state"], expected);
    }
}

#[test]
fn mixed_file_content_groups_match_truth_table_and_short_circuit_file_branches() {
    let root = tempfile::tempdir().unwrap();
    let mut expected = BTreeSet::new();
    for bits in 0..32 {
        let (a, b, c, d, e) = (
            bits & 1 != 0,
            bits & 2 != 0,
            bits & 4 != 0,
            bits & 8 != 0,
            bits & 16 != 0,
        );
        let name = format!(
            "{}{}{}-{bits}.txt",
            if a { "A" } else { "X" },
            if c { "C" } else { "Y" },
            if e { "E" } else { "Z" }
        );
        let path = root.path().join(name);
        fs::write(
            &path,
            format!(
                "{} {}\n",
                if b { "bravo" } else { "quiet" },
                if d { "delta" } else { "quiet" }
            ),
        )
        .unwrap();
        if ((a && b) || (c && d)) && e {
            expected.insert(path.to_str().unwrap().to_owned());
        }
    }
    let mut plan = request(root.path());
    plan["output"] = json!("paths");
    plan["content"]["filesOnly"] = json!(true);
    plan["content"]["useIndex"] = json!(false);
    plan["content"]["leaves"] = json!([{"fileIndex":0},{"pattern":"bravo"},{"fileIndex":1},{"pattern":"delta"},{"fileIndex":2}]);
    plan["content"]["positive"] = json!([1, 3]);
    plan["content"]["tree"] = json!({"all":[{"any":[{"all":[{"leaf":0},{"leaf":1}]},{"all":[{"leaf":2},{"leaf":3}]}]},{"leaf":4}]});
    plan["content"]["filePredicates"] = json!({"roots":[root.path()],"type":"f","hidden":true,"packages":true,"minimumDepth":1,
        "tree":{"all":[]},"leaves":[
            {"conditions":[{"field":"name","value":"A","regex":false}],"caseSensitive":true},
            {"conditions":[{"field":"name","value":"C","regex":false}],"caseSensitive":true},
            {"conditions":[{"field":"name","value":"E","regex":false}],"caseSensitive":true}]});
    let result = run(&plan);
    assert_eq!(paths(&result), expected);
    let stderr = String::from_utf8_lossy(&result.stderr);
    let stats: Value = serde_json::from_str(
        stderr
            .lines()
            .find_map(|l| l.strip_prefix("findui-stats: "))
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        stats["filesOpened"], 12,
        "files ruled out by A/C/E must not be read"
    );
    assert_eq!(completion(&result)["status"], "complete");
    // NOT must complement the full mixed group, including on an empty file.
    fs::write(root.path().join("empty"), "").unwrap();
    plan["content"]["tree"] = json!({"none":[{"all":[{"leaf":0},{"leaf":1}]}]});
    plan["unit"] = json!("file");
    plan["content"]["fileUnit"] = json!(true);
    assert!(paths(&run(&plan)).contains(root.path().join("empty").to_str().unwrap()));
    plan["content"]["leaves"][0]["fileIndex"] = json!(50);
    let invalid = run(&plan);
    assert!(!invalid.status.success());
    assert_eq!(completion(&invalid)["status"], "failed");
}

#[test]
fn hidden_policy_defeats_ignore_whitelists_for_walk_and_manifest() {
    let root = tempfile::tempdir().unwrap();
    fs::create_dir(root.path().join(".hidden")).unwrap();
    for file in ["visible.txt", ".hidden.txt", ".hidden/child.txt"] {
        fs::write(root.path().join(file), "alpha\n").unwrap();
    }
    fs::write(root.path().join(".ignore"), "!.hidden.txt\n!.hidden/\n").unwrap();
    let mut plan = request(root.path());
    plan["output"] = json!("paths");
    plan["content"]["filesOnly"] = json!(true);
    plan["traversal"]["hidden"] = json!(false);
    let expected = BTreeSet::from([root.path().join("visible.txt").to_str().unwrap().to_owned()]);
    assert_eq!(paths(&run(&plan)), expected);
    let manifest = tempfile::NamedTempFile::new().unwrap();
    fs::write(
        manifest.path(),
        ["visible.txt", ".hidden.txt", ".hidden/child.txt"]
            .map(|s| format!("{}\0", root.path().join(s).display()))
            .concat(),
    )
    .unwrap();
    plan["source"] = json!({"kind":"manifest", "path":manifest.path()});
    assert_eq!(paths(&run(&plan)), expected);
}

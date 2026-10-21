use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use doc_testkit::{mutate, required_files, run_limited, Failure, Limits, Rng};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Scratch(std::path::PathBuf);

impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("doc_testkit_{}_{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) { fs::remove_dir_all(&self.0).unwrap(); }
}

#[test]
fn fixed_seed_is_reproducible_and_zero_does_not_stall() {
    assert_eq!(Rng::new(1).next(), 1_082_269_761);
    let original = b"<root count='1'>seed</root>";
    let mut a = Rng::new(42);
    let mut b = Rng::new(42);
    let mut changed = 0;
    for _ in 0..10_000 {
        let left = mutate(&mut a, original, b"other");
        assert_eq!(left, mutate(&mut b, original, b"other"));
        assert!(left.len() <= original.len() + 2052);
        changed += usize::from(left != original);
    }
    assert!(changed > 9000);
    assert_ne!(Rng::new(0).next(), 0);
    assert_eq!(Rng::new(1).below(0), 0);
}

#[test]
fn a_successful_worker_really_runs() {
    let report = run_limited("a_successful_worker_really_runs", Limits::new(Duration::from_secs(5)), || {
        assert_eq!(std::thread::current().name(), None);
        assert_eq!(2 + 2, 4);
    }).unwrap();
    assert!(report.elapsed < Duration::from_secs(5));
}

#[test]
fn a_panicking_worker_is_not_success() {
    let result = run_limited("a_panicking_worker_is_not_success", Limits::new(Duration::from_secs(5)), || {
        panic!("intentional harness panic");
    });
    assert!(matches!(result, Err(Failure::Panic)), "{result:?}");
}

#[test]
fn a_missing_exact_test_is_not_success() {
    let result = run_limited("there_is_no_test_with_this_name", Limits::new(Duration::from_secs(5)), || {});
    assert!(matches!(result, Err(Failure::Protocol(_))), "{result:?}");
}

#[test]
fn a_timeout_kills_and_reaps_the_worker() {
    let owner = std::env::var("DOC_TESTKIT_PARENT_PID").unwrap_or_else(|_| std::process::id().to_string());
    let ready = std::env::temp_dir().join(format!("doc_testkit_ready_{owner}"));
    let late = std::env::temp_dir().join(format!("doc_testkit_late_{owner}"));
    let child_ready = ready.clone();
    let child_late = late.clone();
    let start = Instant::now();
    let result = run_limited("a_timeout_kills_and_reaps_the_worker", Limits::new(Duration::from_millis(500)), move || {
        fs::File::create_new(child_ready).unwrap();
        std::thread::sleep(Duration::from_millis(1400));
        fs::File::create_new(child_late).unwrap();
        loop { std::thread::sleep(Duration::from_secs(1)); }
    });
    assert!(matches!(result, Err(Failure::Timeout(_))), "{result:?}");
    assert!(start.elapsed() < Duration::from_secs(3));
    assert!(ready.exists(), "worker did not start; timeout coverage is inconclusive");
    std::thread::sleep(Duration::from_millis(1500));
    assert!(!late.exists(), "timed-out worker was left running");
    fs::remove_file(ready).unwrap();
}

#[test]
fn missing_empty_and_wrong_extension_corpora_fail() {
    let root = Scratch::new();
    let required: &[(&str, &[&str])] = &[("office/docx", &["docx"])];
    let missing = required_files(&root.0, required).unwrap_err().to_string();
    assert!(missing.contains("MISSING_CORPUS"), "{missing}");
    fs::create_dir_all(root.0.join("office/docx")).unwrap();
    assert!(required_files(&root.0, required).unwrap_err().to_string().contains("EMPTY_CORPUS"));
    fs::write(root.0.join("office/docx/README.txt"), b"not a document").unwrap();
    fs::write(root.0.join("office/docx/empty.docx"), b"").unwrap();
    assert!(required_files(&root.0, required).is_err());
    fs::write(root.0.join("office/docx/a.DOCX"), b"nonempty").unwrap();
    assert_eq!(required_files(&root.0, required).unwrap().len(), 1);
    assert!(required_files(&root.0, &[]).is_err());
}

#[test]
fn zero_limits_are_rejected() {
    assert!(matches!(run_limited("zero_limits_are_rejected", Limits::new(Duration::ZERO), || {}), Err(Failure::Protocol(_))));
}

#[cfg(not(target_os = "linux"))]
#[test]
fn unsupported_rss_is_not_reported_as_zero_or_success() {
    let limits = Limits { rss_bytes: Some(512 << 20), ..Limits::new(Duration::from_secs(5)) };
    assert!(matches!(run_limited("unsupported_rss_is_not_reported_as_zero_or_success", limits, || {}), Err(Failure::Unsupported(_))));
    assert!(matches!(doc_testkit::rss_bytes(std::process::id()), Err(Failure::Unsupported(_))));
}

#[cfg(target_os = "linux")]
#[test]
fn rss_limit_really_fails() {
    let limits = Limits { rss_bytes: Some(1), ..Limits::new(Duration::from_secs(5)) };
    let result = run_limited("rss_limit_really_fails", limits, || {
        let bytes = vec![1u8; 8 << 20];
        std::hint::black_box(&bytes);
        std::thread::sleep(Duration::from_millis(200));
    });
    assert!(matches!(result, Err(Failure::MemoryLimit { .. })), "{result:?}");
}

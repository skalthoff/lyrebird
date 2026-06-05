use super::*;

#[test]
fn image_url_primary_is_backwards_compatible() {
    let client = mock_client("https://example.com");
    let url = client.image_url("item-1", Some("tag-1"), 400).unwrap();
    let s = url.as_str();
    assert!(
        s.contains("/Items/item-1/Images/Primary"),
        "url missing Primary path: {s}"
    );
    assert!(s.contains("maxWidth=400"), "url missing maxWidth: {s}");
    assert!(s.contains("quality=90"), "url missing quality: {s}");
    assert!(s.contains("tag=tag-1"), "url missing tag: {s}");
    // No index segment when index is omitted.
    assert!(
        !s.contains("/Images/Primary/"),
        "unexpected index segment: {s}"
    );
}

#[test]
fn image_url_of_type_primary_matches_legacy_shape() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type(
            "item-1",
            ImageType::Primary,
            None,
            Some("tag-1"),
            Some(400),
            None,
        )
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("/Items/item-1/Images/Primary"), "url: {s}");
    assert!(s.contains("maxWidth=400"), "url: {s}");
    assert!(s.contains("tag=tag-1"), "url: {s}");
    // Neither index nor maxHeight should leak in when not provided.
    assert!(!s.contains("maxHeight="), "url: {s}");
}

#[test]
fn image_url_of_type_backdrop_includes_index_segment() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type(
            "item-2",
            ImageType::Backdrop,
            Some(1),
            Some("bd-tag"),
            Some(1600),
            Some(900),
        )
        .unwrap();
    let s = url.as_str();
    assert!(
        s.contains("/Items/item-2/Images/Backdrop/1"),
        "url missing Backdrop/1: {s}"
    );
    assert!(s.contains("maxWidth=1600"), "url: {s}");
    assert!(s.contains("maxHeight=900"), "url: {s}");
    assert!(s.contains("tag=bd-tag"), "url: {s}");
}

#[test]
fn image_url_of_type_thumb_without_index_or_sizes() {
    let client = mock_client("https://example.com");
    let url = client
        .image_url_of_type("item-3", ImageType::Thumb, None, None, None, None)
        .unwrap();
    let s = url.as_str();
    assert!(s.contains("/Items/item-3/Images/Thumb"), "url: {s}");
    assert!(!s.contains("/Thumb/"), "url should not have index: {s}");
    assert!(!s.contains("maxWidth="), "url: {s}");
    assert!(!s.contains("maxHeight="), "url: {s}");
    assert!(!s.contains("tag="), "url: {s}");
    assert!(s.contains("quality=90"), "url: {s}");
}

#[test]
fn database_roundtrips_settings() {
    let db = Database::in_memory().unwrap();
    db.set_setting("foo", "bar").unwrap();
    assert_eq!(db.get_setting("foo").unwrap().as_deref(), Some("bar"));
    db.set_setting("foo", "baz").unwrap();
    assert_eq!(db.get_setting("foo").unwrap().as_deref(), Some("baz"));
    assert_eq!(db.get_setting("missing").unwrap(), None);
}

// ---------------------------------------------------------------------------
// Shuffle + repeat persistence — round-trip tests (#583)
// ---------------------------------------------------------------------------

/// Fresh database returns the safe defaults (shuffle off, repeat off) so a
/// first launch does not accidentally start in an unexpected mode.
#[test]
fn shuffle_repeat_defaults_on_empty_db() {
    let db = Database::in_memory().expect("in-memory db");
    let (shuffle, repeat) = db.load_shuffle_repeat().unwrap();
    assert!(!shuffle, "default shuffle should be off");
    assert_eq!(repeat, RepeatMode::Off, "default repeat should be Off");
}

/// Every `(shuffle, RepeatMode)` combination round-trips correctly through the
/// key-value store. We create a second `Database` instance open on the same
/// file to verify the values are actually persisted rather than just cached in
/// memory.
#[test]
fn shuffle_repeat_round_trips_all_variants() {
    // RAII temp dir: cleanup runs unconditionally on drop even if an
    // assertion below panics, so a failing case can't leak the db file
    // (matches the rest of the suite). The TempDir gives a private directory,
    // so parallel runs don't collide either.
    let tmpdir = tempfile::TempDir::new().expect("temp dir");
    let tmp = tmpdir.path().join("sr.db");

    let cases: &[(bool, RepeatMode)] = &[
        (true, RepeatMode::Off),
        (false, RepeatMode::One),
        (true, RepeatMode::All),
        (false, RepeatMode::Off),
        (true, RepeatMode::One),
        (false, RepeatMode::All),
    ];

    for &(shuffle, repeat) in cases {
        // Write via one Database handle.
        {
            let db = Database::open(&tmp).expect("open db for write");
            db.save_shuffle_repeat(shuffle, repeat)
                .expect("save_shuffle_repeat");
        }
        // Read back via a fresh Database handle — exercises the actual SQLite
        // persistence path rather than any in-process cache.
        {
            let db = Database::open(&tmp).expect("open db for read");
            let (got_shuffle, got_repeat) = db.load_shuffle_repeat().expect("load_shuffle_repeat");
            assert_eq!(
                got_shuffle, shuffle,
                "shuffle mismatch for case ({shuffle}, {repeat:?})"
            );
            assert_eq!(
                got_repeat, repeat,
                "repeat mismatch for case ({shuffle}, {repeat:?})"
            );
        }
    }
    // `tmpdir` drops here, removing the db file (and on early panic too).
}

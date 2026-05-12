// LyrebirdCore — Swift wrapper around the Rust core.
//
// The actual API lives in `Generated/lyrebird_core.swift`, produced by
// `uniffi-bindgen` during `Scripts/build-core.sh`. This file re-exports the
// generated symbols and adds any Swift-side ergonomics.

@_exported import Foundation

// Re-export the generated types and entry point.
// `LyrebirdCore`, `CoreConfig`, `Server`, `User`, etc. are defined in the
// generated file and participate in this module automatically.

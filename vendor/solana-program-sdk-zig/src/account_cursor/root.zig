//! Remaining-account cursor and window helpers.
//!
//! This module layers a small stateful walker on top of the runtime's
//! serialized remaining-account region:
//!
//! - `AccountCursor` incrementally resolves accounts from the loader buffer.
//! - `AccountWindow` exposes stable ordered slices over dynamic account groups.
//! - `DuplicatePolicy` makes duplicate handling explicit for router-style flows.
//!
//! Physical layout:
//! - `shared.zig` — imports, aliases, and pointer-alignment helper
//! - `window.zig` — `DuplicatePolicy` plus `AccountWindow`
//! - `cursor.zig` — `AccountCursor` state machine and duplicate-aware advance logic
//!
//! The public API stays flattened as `sol.account_cursor.*`, with the
//! top-level aliases `sol.AccountCursor`, `sol.AccountWindow`, and
//! `sol.DuplicatePolicy` preserved at `src/root.zig`.

const window_mod = @import("window.zig");
const cursor_mod = @import("cursor.zig");

/// Explicit duplicate-account handling modes for dynamic account walks.
pub const DuplicatePolicy = window_mod.DuplicatePolicy;

/// Stable ordered views over cursor-produced account groups.
pub const AccountWindow = window_mod.AccountWindow;

/// Stateful parser over the serialized remaining-account buffer.
pub const AccountCursor = cursor_mod.AccountCursor;

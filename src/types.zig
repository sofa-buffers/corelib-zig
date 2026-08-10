//! Shared types and wire constants (see the SofaBuffers documentation:
//! <https://github.com/sofa-buffers/documentation>).

/// SofaBuffers wire/API version implemented by this library.
///
/// Normative per the architecture spec (`API_VERSION == 1`).
pub const API_VERSION: u32 = 1;

/// Field identifier type. Application-assigned; need not be contiguous.
pub const Id = u32;

/// Largest valid field id (`INT32_MAX`), matching `SOFAB_ID_MAX` in C.
pub const ID_MAX: Id = 0x7FFF_FFFF;

/// Unsigned value type used by the scalar API — always 64-bit (this build
/// targets fast 64-bit hosts and does not trade range for footprint).
pub const Unsigned = u64;
/// Signed value type used by the scalar API — always 64-bit.
pub const Signed = i64;

/// Maximum number of elements in an array (`INT32_MAX`).
pub const ARRAY_MAX: u64 = 0x7FFF_FFFF;

/// Maximum number of bytes in a fixlen field / per fixlen-array element
/// (`INT32_MAX`).
pub const FIXLEN_MAX: u64 = 0x7FFF_FFFF;

/// Smallest **streaming** output buffer the encoder accepts, in usable bytes
/// (CORELIB_PLAN §5.1). This port splits every atomic unit across a flush — a
/// field header, a `fixlen_word`, an element count, a scalar varint and a float
/// payload all fall back to a byte-at-a-time writer that drains between bytes —
/// so it declares the smallest value §5.1 admits. A caller therefore never has
/// to reserve headroom: any non-empty buffer streams a message of any size, and
/// the bytes are identical to the one-shot path.
///
/// **It binds a buffer installed together with a flush sink**, and only such a
/// buffer: `buffer.len - offset >= MIN_OUTPUT_BUFFER` is checked where the
/// buffer is handed over — `OStream.initFlush` / `OStream.bufferSet` and their
/// `…Checked` forms — and never partway through a message. A buffer installed
/// **without** a sink is subject to no minimum at all (no flush can occur, so
/// no atomic unit can be split): it either holds the message or reports
/// `error.BufferFull`, and a two-byte message still encodes into two bytes.
pub const MIN_OUTPUT_BUFFER: usize = 1;

/// Maximum nested-sequence depth. An encoder must not open more than this many
/// nested sequences, and a decoder rejects a message that nests deeper with
/// `error.InvalidMessage` (normative per the architecture spec, §6.2).
pub const MAX_DEPTH: u32 = 255;

/// Errors returned by the encoder and decoder. The names follow the canonical
/// baseline codes of the architecture spec (§6.3); `OK` is modeled as a
/// non-error return.
pub const Error = error{
    /// Invalid caller argument (e.g. a field id greater than `ID_MAX`, a
    /// length/count above the maximum, or more than `MAX_DEPTH` nested
    /// sequences). Corresponds to `SOFAB_RET_E_ARGUMENT`.
    InvalidArgument,

    /// The output buffer is full and no flush sink is available.
    /// Corresponds to `SOFAB_RET_E_BUFFER_FULL`.
    BufferFull,

    /// The input bytes are not a valid Sofab message *regardless of what may
    /// follow* (varint overflow, bad type tag, oversized length/count, dangling
    /// sequence end, nesting past `MAX_DEPTH`, invalid UTF-8, …).
    /// Corresponds to `SOFAB_RET_E_INVALID_MSG`.
    InvalidMessage,

    /// A decoded dynamic field exceeded a **receiver-configured** decode limit
    /// on an unbounded field — one whose schema declares no `count`/`maxlen`
    /// (`max_dyn_array_count`, `max_dyn_string_len`, `max_dyn_blob_len`). The
    /// bytes are a well-formed Sofab message; whether they are *accepted*
    /// depends on the receiver's policy, so this is deliberately **distinct
    /// from `InvalidMessage`**: a limit violation is policy, not wire
    /// malformation. Keeping the two apart lets a differential fuzzer (Crucible)
    /// avoid reading two backends' differing configured limits as a
    /// wire-conformance divergence.
    ///
    /// A limit violation is always a hard decode error (never clamp, never
    /// truncate), raised **before** any allocation for the offending field.
    ///
    /// This corelib neither enforces these limits nor defines any default
    /// values: the caps come from the sofabgen config and the enforcement lives
    /// in generated decode code, which raises this category uniformly. See
    /// sofa-buffers/generator#102; mirrors corelib-go's `ErrLimitExceeded`.
    LimitExceeded,
};

// --- 3-bit wire field type tags (low 3 bits of the field header varint) ------
pub const T_VARINT_UNSIGNED: u3 = 0x0;
pub const T_VARINT_SIGNED: u3 = 0x1;
pub const T_FIXLEN: u3 = 0x2;
pub const T_VARINTARRAY_UNSIGNED: u3 = 0x3;
pub const T_VARINTARRAY_SIGNED: u3 = 0x4;
pub const T_FIXLENARRAY: u3 = 0x5;
pub const T_SEQUENCE_START: u3 = 0x6;
pub const T_SEQUENCE_END: u3 = 0x7;

/// Sub-type of a fixed-length field (the 3-bit tag inside the fixlen header).
pub const FixlenType = enum(u3) {
    /// 32-bit IEEE-754 float, little-endian on the wire.
    fp32 = 0x0,
    /// 64-bit IEEE-754 double, little-endian on the wire.
    fp64 = 0x1,
    /// UTF-8 / raw text (no NUL on the wire).
    string = 0x2,
    /// Arbitrary raw bytes.
    blob = 0x3,

    /// Decode a 3-bit fixlen tag from the wire, rejecting reserved subtypes.
    pub fn fromRaw(raw: u3) Error!FixlenType {
        if (raw > 0x3) return Error.InvalidMessage;
        return @enumFromInt(raw);
    }
};

/// Element category of an array, reported to a visitor's `arrayBegin` at the
/// start of an array field.
///
/// A fixlen array names its **element subtype** here (`fp32` / `fp64`), not
/// merely "some fixlen array": the receiver must be able to tell whether the
/// array that arrived is the declared field's value *before* it applies any
/// schema bound to `count` (CORELIB_PLAN §4.8 step 3, MESSAGE_SPEC §7.3).
/// The hook therefore fires only once the `fixlen_word` has been read and
/// validated. Ordinals are fixed across the family.
pub const ArrayKind = enum(u2) {
    /// Unsigned-integer elements (delivered via the `unsigned` callback).
    unsigned = 0,
    /// Signed-integer elements (delivered via the `signed` callback).
    signed = 1,
    /// 32-bit float elements (delivered via the `fp32` callback).
    fp32 = 2,
    /// 64-bit float elements (delivered via the `fp64` callback).
    fp64 = 3,
};

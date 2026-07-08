//! Conformance test root: aggregates the shared-vector suite and the
//! malformed / roundtrip / API scenarios required by ARCHITECTURE §7.

test {
    _ = @import("vectors_tests.zig");
    _ = @import("roundtrip_tests.zig");
    _ = @import("malformed_tests.zig");
    _ = @import("api_tests.zig");
}

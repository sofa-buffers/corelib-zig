//! Conformance test root: aggregates the shared-vector suite and the
//! malformed / roundtrip / API scenarios required by ARCHITECTURE §7.

test {
    _ = @import("vectors_tests.zig");
    _ = @import("roundtrip_tests.zig");
    _ = @import("malformed_tests.zig");
    _ = @import("fixlen_array_kind_tests.zig");
    _ = @import("sequence_skip_tests.zig");
    _ = @import("api_tests.zig");
    _ = @import("readme_generated_example.zig");
    _ = @import("readme_tests.zig");
    _ = @import("devcontainer_tests.zig");
}

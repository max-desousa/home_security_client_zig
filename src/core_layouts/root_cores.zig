const single = @import("single_core_layout.zig");
const restricted = @import("restricted_core_layout.zig");
const perfect = @import("perfect_core_layout.zig");
const two = @import("two_core_layout.zig");

pub const single_core_layout = single.single_core_layout;
pub const two_core_layout = two.two_core_layout;
pub const restricted_core_layout = restricted.restricted_core_layout;
pub const perfect_core_layout = perfect.perfect_core_layout;

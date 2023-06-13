const std = @import("std");
const assert = std.debug.assert;
const solomon_reed = @import("solomon_reed.zig");

pub fn main() void {
    const data_shard_count = 4;
    const parity_shard_count = 2;
    const Encoder = solomon_reed.Encoder(data_shard_count, parity_shard_count);

    var encoder: Encoder = undefined;
    encoder.init();

    std.log.info("Encoder value: {d}", .{Encoder.encoding_matrix[4]});
}

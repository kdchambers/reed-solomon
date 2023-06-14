const std = @import("std");
const assert = std.debug.assert;
const solomon_reed = @import("solomon_reed.zig");

pub fn main() void {
    const data_shard_count = 4;
    const parity_shard_count = 2;
    const total_shard_count = data_shard_count + parity_shard_count;

    const Encoder = solomon_reed.Encoder(data_shard_count, parity_shard_count);

    const input_size_bytes: usize = 64;
    const input_data = generateTestData(input_size_bytes);
    //
    // TODO: We're doing an even division just for simplicity but in the case
    //       it doesn't divide evenly we have to round up
    //
    const data_shard_size = @divExact(input_size_bytes, data_shard_count);

    //
    // Size of each shard when we include the parity shards
    //
    const total_shard_size = @divExact(data_shard_size, data_shard_count) * total_shard_count;
    assert(total_shard_size == 24);

    const output_size_bytes = total_shard_size * data_shard_count;
    assert(output_size_bytes == 96);
    var output_buffer = [1]u8{0} ** output_size_bytes;

    //
    // Copy the input data into our output buffer leaving space for the
    // parity shards are the end of each data shard
    //
    for (0..data_shard_count) |i| {
        const src_index: usize = i * data_shard_size;
        const dst_index: usize = i * total_shard_count;
        @memcpy(
            output_buffer[dst_index .. dst_index + data_shard_size],
            input_data[src_index .. src_index + data_shard_size],
        );
    }

    var encoder: Encoder = undefined;
    encoder.init();
    encoder.encode(&output_buffer);

    std.log.info("Encoder value: {d}", .{Encoder.encoding_matrix.buffer[4]});
}

fn generateTestData(comptime size: usize) [size]u8 {
    var out_buffer: [size]u8 = undefined;
    for (0..size) |i| {
        out_buffer[i] = @intCast(u8, @mod((size - i) * i, 255));
    }
    return out_buffer;
}

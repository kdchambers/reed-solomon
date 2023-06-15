const std = @import("std");
const assert = std.debug.assert;
const rs = @import("reedsolomon");
const BitSet = rs.BitSet;

test "recompute missing shards" {
    const expect = std.testing.expect;
    const data_shard_count = 4;
    const parity_shard_count = 2;
    const total_shard_count = data_shard_count + parity_shard_count;

    const Encoder = rs.Encoder(data_shard_count, parity_shard_count);

    const input_size_bytes: usize = 64;
    const input_data = generateTestData(input_size_bytes);

    //
    // Size of each shard when we include the parity shards
    //
    const shard_size = @divExact(input_size_bytes, data_shard_count);
    assert(shard_size == 16);

    const shard_buffer_size = shard_size * total_shard_count;

    var input_buffer = [1]u8{0} ** shard_buffer_size;
    var shard_buffer = rs.ShardBuffer{
        .count = total_shard_count,
        .shard_size = shard_size,
        .buffer = &input_buffer,
    };
    assert(shard_buffer.buffer.len == (shard_buffer.count * shard_buffer.shard_size));

    //
    // Copy the input data into our output buffer leaving space for the
    // parity shards are the end of each data shard
    //
    for (0..data_shard_count) |i| {
        const src_index: usize = i * shard_size;
        @memcpy(
            shard_buffer.getShardMut(i),
            input_data[src_index .. src_index + shard_size],
        );
    }

    var encoder: Encoder = undefined;

    encoder.init();
    encoder.encode(&shard_buffer);

    var temp_parity_shard_buffer: [shard_size * parity_shard_count]u8 = undefined;
    var temp_parity_shards = rs.ShardBuffer{
        .count = parity_shard_count,
        .shard_size = shard_size,
        .buffer = &temp_parity_shard_buffer,
    };

    //
    // Parity should be correct
    //
    try expect(encoder.verifyParity(&shard_buffer, &temp_parity_shards));

    var shards_copy_buffer: [shard_buffer_size]u8 = undefined;
    var shards_copy = rs.ShardBuffer{
        .shard_size = shard_buffer.shard_size,
        .count = shard_buffer.count,
        .buffer = &shards_copy_buffer,
    };
    @memcpy(shards_copy.buffer, shard_buffer.buffer);

    var missing_bitset = BitSet(u64).init;
    missing_bitset.set(1);
    @memset(shards_copy.buffer[shard_size .. shard_size * 2], 0);

    //
    // Assert our copy of the shard buffer has been modified
    //
    assert(!std.mem.eql(u8, shards_copy.buffer, shard_buffer.buffer));

    //
    // Reconstruct the data and parity shards
    //
    try encoder.reconstruct(&shards_copy, missing_bitset);

    try expect(std.mem.eql(u8, shards_copy.buffer, shard_buffer.buffer));
}

fn generateTestData(comptime size: usize) [size]u8 {
    var out_buffer: [size]u8 = undefined;
    for (0..size) |i| {
        out_buffer[i] = @intCast(u8, i * 2);
    }
    return out_buffer;
}

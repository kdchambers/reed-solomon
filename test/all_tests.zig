const std = @import("std");
const assert = std.debug.assert;
const rs = @import("reedsolomon");
const BitSet = rs.BitSet;
const expect = std.testing.expect;
const testing_allocator = std.testing.allocator;

fn testReconstruction(
    comptime data_shard_count: usize,
    comptime parity_shard_count: usize,
    comptime shard_loss_count: usize,
    input_bytes: []const u8,
) !void {
    assert(input_bytes.len >= data_shard_count);
    //
    // It's only possible to recover up to `parity_shard_count` corrupted shards
    //
    assert(shard_loss_count <= parity_shard_count);

    const total_shard_count = data_shard_count + parity_shard_count;
    //
    // We have to split our input data into `data_shard_count` data shards of the same size
    // Therefore we round up the size of out input bytes and 0 pad the last data shard
    //
    const required_padding: usize = blk: {
        const overshoot: usize = input_bytes.len % data_shard_count;
        break :blk if (overshoot == 0) 0 else (data_shard_count - overshoot);
    };

    const padded_input_size: usize = input_bytes.len + required_padding;
    assert(padded_input_size % data_shard_count == 0);

    const shard_size = @divExact(padded_input_size, data_shard_count);
    const output_buffer_size: usize = shard_size * total_shard_count;

    var output_bytes = try testing_allocator.alloc(u8, output_buffer_size);
    defer testing_allocator.free(output_bytes);

    @memset(output_bytes, 0);
    @memcpy(output_bytes[0..input_bytes.len], input_bytes);

    var shard_buffer = rs.ShardBuffer{
        .count = total_shard_count,
        .shard_size = shard_size,
        .buffer = output_bytes,
    };

    const Encoder = rs.Encoder(data_shard_count, parity_shard_count);
    var encoder: Encoder = undefined;

    encoder.init();
    encoder.encode(&shard_buffer);

    {
        //
        // Parity should be correct
        //
        var temp_parity_shard_buffer = try testing_allocator.alloc(u8, shard_size * parity_shard_count);
        defer testing_allocator.free(temp_parity_shard_buffer);
        var temp_parity_shards = rs.ShardBuffer{
            .count = parity_shard_count,
            .shard_size = shard_size,
            .buffer = temp_parity_shard_buffer,
        };
        try expect(encoder.verifyParity(&shard_buffer, &temp_parity_shards));
    }

    var shards_copy_buffer_raw = try testing_allocator.dupe(u8, output_bytes);
    defer testing_allocator.free(shards_copy_buffer_raw);

    var shards_copy = rs.ShardBuffer{
        .shard_size = shard_buffer.shard_size,
        .count = shard_buffer.count,
        .buffer = shards_copy_buffer_raw,
    };
    @memcpy(shards_copy.buffer, shard_buffer.buffer);

    var missing_bitset = BitSet(u64).init;

    const rng_seed = @intCast(u64, std.time.milliTimestamp());
    var default_rng = std.rand.DefaultPrng.init(rng_seed);
    var rng = default_rng.random();

    for (0..shard_loss_count) |_| {
        const max_search_iters: usize = 1000;
        const shard_to_corrupt_index: usize = blk: {
            for (0..max_search_iters) |_| {
                const potential_index: usize = rng.int(usize) % total_shard_count;
                if (!missing_bitset.isSet(potential_index))
                    break :blk potential_index;
            }
            //
            // For some reason we didn't manage to find a random index to corrupt, just take the next
            // non-corrupted index from the start
            //
            for (0..total_shard_count) |shard_i| {
                if (missing_bitset.isSet(shard_i))
                    break :blk shard_i;
            }
            //
            // We assert `shard_loss_count` <= `parity_shard_count`
            //
            unreachable;
        };

        assert(shard_to_corrupt_index < total_shard_count);
        missing_bitset.set(shard_to_corrupt_index);
        const corrupted_shard_begin: usize = shard_size * shard_to_corrupt_index;
        const corrupted_shard_end: usize = corrupted_shard_begin + shard_size;
        var shard_to_corrupt = shards_copy.buffer[corrupted_shard_begin..corrupted_shard_end];
        //
        // Negate the bits for some byte in the middle of the shard to corrupt
        //
        const byte_to_corrupt_index: usize = @divTrunc(shard_to_corrupt.len, 2);
        shard_to_corrupt[byte_to_corrupt_index] = ~shard_to_corrupt[byte_to_corrupt_index];
        var non_corrupted_shard = shard_buffer.buffer[corrupted_shard_begin..corrupted_shard_end];
        //
        // Assert that we have corrupted the shard and they are no longer equal
        //
        assert(!std.mem.eql(u8, shard_to_corrupt, non_corrupted_shard));
    }

    //
    // Reconstruct the data and parity shards
    //
    try encoder.reconstruct(&shards_copy, missing_bitset);

    //
    // We've only reconstructed the data shards, check it against the original data
    // NOTE: The parity shards may still be corrupted
    //
    const data_bytes_size: usize = shard_size * data_shard_count;
    try expect(std.mem.eql(u8, shards_copy.buffer[0..data_bytes_size], shard_buffer.buffer[0..data_bytes_size]));
}

test "recompute missing shards" {
    const rng_seed = @intCast(u64, std.time.milliTimestamp());
    var default_rng = std.rand.DefaultPrng.init(rng_seed);
    var rng = default_rng.random();
    {
        const data_shard_count = 4;
        const parity_shard_count = 2;
        const shard_loss_count = 1;
        const input_data_size = 64;
        var input_data_bytes = try testing_allocator.alloc(u8, input_data_size);
        defer testing_allocator.free(input_data_bytes);
        rng.bytes(input_data_bytes[0..input_data_size]);
        try testReconstruction(data_shard_count, parity_shard_count, shard_loss_count, input_data_bytes);
    }
    {
        const data_shard_count = 17;
        const parity_shard_count = 3;
        const shard_loss_count = 1;
        const input_data_size = 128;
        var input_data_bytes = try testing_allocator.alloc(u8, input_data_size);
        defer testing_allocator.free(input_data_bytes);
        rng.bytes(input_data_bytes[0..input_data_size]);
        try testReconstruction(data_shard_count, parity_shard_count, shard_loss_count, input_data_bytes);
    }
    {
        const data_shard_count = 8;
        const parity_shard_count = 8;
        const shard_loss_count = 8;
        const input_data_size = 256;
        var input_data_bytes = try testing_allocator.alloc(u8, input_data_size);
        defer testing_allocator.free(input_data_bytes);
        rng.bytes(input_data_bytes[0..input_data_size]);
        try testReconstruction(data_shard_count, parity_shard_count, shard_loss_count, input_data_bytes);
    }
    {
        const data_shard_count = 7;
        const parity_shard_count = 3;
        const shard_loss_count = 2;
        //
        // Input data will need to be padded to multiple of `data_shard_count`
        //
        const input_data_size = 1234;
        var input_data_bytes = try testing_allocator.alloc(u8, input_data_size);
        defer testing_allocator.free(input_data_bytes);
        rng.bytes(input_data_bytes[0..input_data_size]);
        try testReconstruction(data_shard_count, parity_shard_count, shard_loss_count, input_data_bytes);
    }
    {
        const data_shard_count = 5;
        const parity_shard_count = 5;
        const shard_loss_count = 5;
        //
        // Input data will need to be padded to multiple of `data_shard_count`
        //
        const input_data_size = 2347;
        var input_data_bytes = try testing_allocator.alloc(u8, input_data_size);
        defer testing_allocator.free(input_data_bytes);
        rng.bytes(input_data_bytes[0..input_data_size]);
        try testReconstruction(data_shard_count, parity_shard_count, shard_loss_count, input_data_bytes);
    }
}

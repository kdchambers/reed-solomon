const std = @import("std");
const assert = std.debug.assert;
const galois = @import("galois.zig");
const matrix = @import("matrix.zig");
const Matrix = matrix.Matrix;

pub fn BitSet(comptime IntType: type) type {
    return packed struct {
        bits: IntType,

        pub const init = @This(){ .bits = 0 };

        pub inline fn isSet(self: @This(), index: usize) bool {
            assert(index < @bitSizeOf(IntType));
            return (self.bits & (@as(usize, 1) << @intCast(u6, index))) != 0;
        }

        pub inline fn set(self: *@This(), index: usize) void {
            assert(index < @bitSizeOf(IntType));
            self.bits |= (@as(usize, 1) << @intCast(u6, index));
        }

        pub inline fn noneSet(self: @This()) bool {
            return self.bits == 0;
        }
    };
}

test "bitset" {
    const expect = std.testing.expect;
    var bitset = BitSet(u64).init;
    for (0..64) |i| {
        try expect(!bitset.isSet(i));
    }

    for (0..64) |i| {
        if (i % 2 == 0)
            bitset.set(i);
    }

    for (0..64) |i| {
        if (i % 2 == 0)
            try expect(bitset.isSet(i))
        else
            try expect(!bitset.isSet(i));
    }
}

pub const ShardBuffer = struct {
    shard_size: usize,
    count: usize,
    buffer: []u8,

    pub inline fn getShardMut(self: *@This(), index: usize) []u8 {
        assert(index < self.count);
        const shard_begin: usize = self.shard_size * index;
        const shard_end: usize = shard_begin + self.shard_size;
        return self.buffer[shard_begin..shard_end];
    }

    pub inline fn getShard(self: @This(), index: usize) []const u8 {
        assert(index < self.count);
        const shard_begin: usize = self.shard_size * index;
        const shard_end: usize = shard_begin + self.shard_size;
        return self.buffer[shard_begin..shard_end];
    }
};

pub fn Encoder(comptime data_shard_count: u32, comptime parity_shard_count: u32) type {
    const total_shard_count = data_shard_count + parity_shard_count;
    assert(total_shard_count < 256);
    return struct {
        pub const encoding_matrix = generateEncodingMatrix(data_shard_count, total_shard_count);
        const mult_table = galois.generateMultiplicationTable(256);

        parity_rows: [parity_shard_count][]const u8,

        pub fn init(self: *@This()) void {
            for (&self.parity_rows, 0..) |*row, i| {
                const row_start = (data_shard_count + i) * data_shard_count;
                const row_end = row_start + data_shard_count;
                row.* = encoding_matrix.buffer[row_start..row_end];
            }
        }

        ///
        /// Converts a buffer in the form of [d d d d x x] to [d d d d p p]
        /// where d=data shard, x=undefined, p=parity shard assuming 4 data shards + 2 parity shards
        ///
        /// `inout_buffer` contains the data shards and enough space to write the parity shards
        ///
        pub fn encode(self: *@This(), shard_buffer: *ShardBuffer) void {
            _ = self;
            {
                const data_i: usize = 0;
                const input_shard = shard_buffer.getShard(data_i);
                for (0..parity_shard_count) |parity_i| {
                    var parity_shard = shard_buffer.getShardMut(data_shard_count + parity_i);
                    const encoding_matrix_parity_row = encoding_matrix.buffer[(data_shard_count + parity_i) * data_shard_count .. ((data_shard_count + parity_i) * data_shard_count) + data_shard_count];
                    const mult_table_index: usize = encoding_matrix_parity_row[0] * @as(usize, 256);
                    const mult_table_row = mult_table[mult_table_index .. mult_table_index + @as(usize, 256)];
                    for (0..shard_buffer.shard_size) |i| {
                        parity_shard[i] = mult_table_row[input_shard[i]];
                    }
                }
            }
            {
                for (1..data_shard_count) |data_i| {
                    const input_shard = shard_buffer.getShard(data_i);
                    for (0..parity_shard_count) |parity_i| {
                        var parity_shard = shard_buffer.getShardMut(data_shard_count + parity_i);
                        const encoding_matrix_parity_row = encoding_matrix.buffer[(data_shard_count + parity_i) * data_shard_count .. ((data_shard_count + parity_i) * data_shard_count) + data_shard_count];
                        const mult_table_row_index: usize = encoding_matrix_parity_row[data_i];
                        const columns_per_table: usize = 256;
                        const mult_table_index: usize = mult_table_row_index * columns_per_table;
                        const mult_table_row = mult_table[mult_table_index .. mult_table_index + columns_per_table];
                        for (0..shard_buffer.shard_size) |i| {
                            parity_shard[i] ^= mult_table_row[input_shard[i]];
                        }
                    }
                }
            }
        }

        /// Recalculates the parity shards based on the valid data shards given in `shard_buffer`,
        /// then compares the recalculated parity shards with those in `shard_buffer`. Will return
        /// true if the parity shards match, otherwise false
        /// `shard_buffer`: Contains both valid data and parity shards in form [d .. d p .. p] according
        ///                 to `data_shard_count` and `parity_shard_count` for this Encoder.
        /// `temp_buffer`: A buffer with enough space to hold a single shard. I.e (data_bytes / total_shard_count)
        ///                The buffers contents may be uninitialized
        pub fn verifyParity(self: *@This(), shard_buffer: *const ShardBuffer, temp_buffer: []u8) bool {
            @setEvalBranchQuota(20_000);

            const shard_size = shard_buffer.shard_size;
            const data_shards_size: usize = shard_size * data_shard_count;
            _ = data_shards_size;

            assert(parity_shard_count == 2);
            var parity_shards: [parity_shard_count][]const u8 = blk: {
                var result: [parity_shard_count][]const u8 = undefined;
                inline for (0..parity_shard_count) |parity_i| {
                    result[parity_i] = shard_buffer.getShard(data_shard_count + parity_i);
                }
                break :blk result;
            };
            assert(parity_shards[0].len == shard_size);

            var recalculated_parity_shards: [parity_shard_count][]u8 = blk: {
                var result: [parity_shard_count][]u8 = undefined;
                inline for (0..parity_shard_count) |parity_i| {
                    assert(parity_i < parity_shard_count);
                    const index: usize = shard_size * parity_i;
                    result[parity_i] = temp_buffer[index .. index + shard_size];
                }
                break :blk result;
            };
            assert(recalculated_parity_shards[0].len == shard_size);

            const data_shards: [data_shard_count][]const u8 = blk: {
                var result: [data_shard_count][]const u8 = undefined;
                inline for (0..data_shard_count) |data_i| {
                    result[data_i] = shard_buffer.getShard(data_i);
                }
                break :blk result;
            };
            assert(data_shards[0].len == shard_size);

            inline for (&recalculated_parity_shards, 0..) |*recalc_parity_shard, parity_i| {
                const parity_row: []const u8 = self.parity_rows[parity_i];
                {
                    const mult_table_row = mult_table[parity_row[0] .. parity_row[0] + @as(usize, 256)];
                    for (0..shard_size) |byte_i| {
                        recalc_parity_shard.*[byte_i] = mult_table_row[data_shards[0][byte_i]];
                    }
                }
                inline for (data_shards[1..], 1..) |data_shard, data_i| {
                    const mult_table_row = mult_table[parity_row[data_i] .. parity_row[data_i] + @as(usize, 256)];
                    for (0..shard_size) |byte_i| {
                        recalc_parity_shard.*[byte_i] ^= mult_table_row[data_shard[byte_i]];
                    }
                }
                //
                // Check whether the parity shard we just calculated matches what already
                // exists in `shard_buffer`.
                //
                if (!std.mem.eql(u8, recalc_parity_shard.*, parity_shards[parity_i])) {
                    return false;
                }
            }
            return true;
        }
    };
}

fn generateEncodingMatrix(comptime data_shard_count: comptime_int, comptime total_shard_count: comptime_int) Matrix(total_shard_count, data_shard_count) {
    const vandermonde_matrix = matrix.generateVanderMondeMatrix(total_shard_count, data_shard_count);
    const matrix_top = vandermonde_matrix.truncateRows(data_shard_count);
    const matrix_top_inverted = matrix.inverseOf(data_shard_count, matrix_top);
    return matrix.multiply(vandermonde_matrix, matrix_top_inverted);
}

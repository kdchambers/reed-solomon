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

pub fn Encoder(comptime data_shard_count: u32, comptime parity_shard_count: u32) type {
    const total_shard_count = data_shard_count + parity_shard_count;
    assert(total_shard_count < 256);
    return struct {
        pub const encoding_matrix = generateEncodingMatrix(data_shard_count, total_shard_count);

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
        pub fn encode(self: *@This(), inout_buffer: []u8) void {
            @setEvalBranchQuota(20_000);
            //
            // Data and Parity shards are the same size in bytes, we simply take the length
            // of the buffer and divide it by the total number of shards that the Encoder was
            // configured to use
            //
            const shard_size = @divExact(inout_buffer.len, total_shard_count);
            const data_shards_size: usize = shard_size * data_shard_count;
            //
            // Parity shards are stored at the end of the buffer, after all of the data shards
            //
            const parity_offset = data_shards_size;
            const mult_table = galois.generateMultiplicationTable(256);

            //
            // For ease of use, create an array of slices to the last `parity_shard_count`
            // shards in inout_buffer. These correspond to the parity shards to be computed
            //
            assert(parity_shard_count == 2);
            var parity_shards: [parity_shard_count][]u8 = blk: {
                var result: [parity_shard_count][]u8 = undefined;
                inline for (0..parity_shard_count) |parity_i| {
                    assert(parity_i < parity_shard_count);
                    const index: usize = parity_offset + (shard_size * parity_i);
                    result[parity_i] = inout_buffer[index .. index + shard_size];
                }
                break :blk result;
            };
            assert(parity_shards[0].len == shard_size);

            //
            // Do the same with the data shards
            //
            const data_shards: [data_shard_count][]const u8 = blk: {
                var result: [data_shard_count][]u8 = undefined;
                inline for (0..data_shard_count) |data_i| {
                    const index: usize = shard_size * data_i;
                    result[data_i] = inout_buffer[index .. index + shard_size];
                }
                break :blk result;
            };
            assert(data_shards[0].len == shard_size);

            //
            // Loop on each parity shard that we need to calculate the value for
            //
            inline for (&parity_shards, 0..) |*parity_shard, parity_i| {
                const parity_row: []const u8 = self.parity_rows[parity_i];
                {
                    const mult_table_row = mult_table[parity_row[0] .. parity_row[0] + @as(usize, 256)];
                    for (0..shard_size) |byte_i| {
                        parity_shard.*[byte_i] = mult_table_row[data_shards[0][byte_i]];
                    }
                }
                inline for (data_shards[1..], 1..) |data_shard, data_i| {
                    const mult_table_row = mult_table[parity_row[data_i] .. parity_row[data_i] + @as(usize, 256)];
                    for (0..shard_size) |byte_i| {
                        parity_shard.*[byte_i] ^= mult_table_row[data_shard[byte_i]];
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
        pub fn verifyParity(self: *@This(), shard_buffer: []const u8, temp_buffer: []u8) bool {
            @setEvalBranchQuota(20_000);

            const shard_size = @divExact(shard_buffer.len, total_shard_count);
            const data_shards_size: usize = shard_size * data_shard_count;
            const parity_offset = data_shards_size;
            const mult_table = galois.generateMultiplicationTable(256);

            assert(parity_shard_count == 2);
            var parity_shards: [parity_shard_count][]const u8 = blk: {
                var result: [parity_shard_count][]const u8 = undefined;
                inline for (0..parity_shard_count) |parity_i| {
                    assert(parity_i < parity_shard_count);
                    const index: usize = parity_offset + (shard_size * parity_i);
                    result[parity_i] = shard_buffer[index .. index + shard_size];
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
                    const index: usize = shard_size * data_i;
                    result[data_i] = shard_buffer[index .. index + shard_size];
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
    return matrix.multArray(
        total_shard_count,
        data_shard_count,
        data_shard_count,
        data_shard_count,
        vandermonde_matrix,
        matrix_top_inverted,
    );
}

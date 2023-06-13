const std = @import("std");
const assert = std.debug.assert;
const galois = @import("galois.zig");

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
                row.* = encoding_matrix[row_start..row_end];
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
    };
}

fn generateEncodingMatrix(comptime data_shard_count: comptime_int, comptime total_shard_count: comptime_int) [total_shard_count * data_shard_count]u8 {
    const vandermonde_matrix = generateVanderMondeMatrix(total_shard_count, data_shard_count);
    const matrix_top = vandermonde_matrix[0 .. data_shard_count * data_shard_count];
    const matrix_top_inverted = matrix.invert(data_shard_count, matrix_top.*);
    return matrix.multArray(
        total_shard_count,
        data_shard_count,
        data_shard_count,
        data_shard_count,
        vandermonde_matrix,
        matrix_top_inverted,
    );
}

fn generateVanderMondeMatrix(comptime row_count: comptime_int, comptime col_count: comptime_int) [row_count * col_count]u8 {
    var out_matrix: [row_count * col_count]u8 = undefined;
    inline for (0..row_count) |r| {
        inline for (0..col_count) |c| {
            const matrix_index = r * col_count + c;
            out_matrix[matrix_index] = galois.exp(r, c);
        }
    }
    return out_matrix;
}

const matrix = struct {
    pub inline fn logArray(
        comptime row_count: usize,
        comptime col_count: usize,
        in_matrix: [row_count * col_count]u8,
    ) void {
        const print = std.debug.print;
        print("\n", .{});
        inline for (0..row_count) |r| {
            inline for (0..col_count) |c| {
                print("{d} ", .{in_matrix[r * col_count + c]});
            }
            print("\n", .{});
        }
    }

    pub inline fn identity(comptime size: comptime_int) [size * size]u8 {
        const element_count = size * size;
        var out_matrix = [1]u8{0} ** element_count;
        inline for (0..size) |i| {
            const index = (i * size) + i;
            out_matrix[index] = 1;
        }
        return out_matrix;
    }

    pub inline fn swapRows(
        comptime row_count: usize,
        comptime col_count: usize,
        inout_matrix: *[row_count * col_count]u8,
        row_index_a: usize,
        row_index_b: usize,
    ) void {
        assert(row_index_a < row_count);
        assert(row_index_b < row_count);
        assert(row_count > 0);
        assert(col_count > 0);

        if (row_index_a == row_index_b)
            return;

        var temp: [col_count]u8 = undefined;
        {
            //
            // Copy row a into temp
            //
            const src_index: usize = row_index_a * col_count;
            for (&temp, inout_matrix[src_index .. src_index + col_count]) |*dst, src|
                dst.* = src;
        }
        {
            //
            // Copy row b into row a
            //
            const src_index: usize = row_index_b * col_count;
            const dst_index: usize = row_index_a * col_count;
            for (inout_matrix[dst_index .. dst_index + col_count], inout_matrix[src_index .. src_index + col_count]) |*dst, src|
                dst.* = src;
        }
        {
            //
            // Copy temp into row b
            //
            const dst_index: usize = row_index_b * col_count;
            for (inout_matrix[dst_index .. dst_index + col_count], &temp) |*dst, src|
                dst.* = src;
        }
    }

    pub inline fn gaussianEliminationArray(comptime row_count: usize, comptime col_count: usize, inout_matrix: *[row_count * col_count]u8) void {
        @setEvalBranchQuota(20_000);
        assert(col_count >= row_count);
        for (0..row_count) |r| {
            const diagnal_index: usize = r * col_count + r;
            if (inout_matrix[diagnal_index] == 0) {
                inner: for (r + 1..row_count) |row_below| {
                    if (inout_matrix[row_below * col_count + r] != 0) {
                        swapRows(row_count, col_count, inout_matrix, r, row_below);
                        break :inner;
                    }
                }
            }
            assert(inout_matrix[diagnal_index] != 0);
            if (inout_matrix[diagnal_index] != 1) {
                const scale = galois.divide(1, inout_matrix[diagnal_index]);
                inline for (0..col_count) |c| {
                    const index: usize = r * col_count + c;
                    inout_matrix[index] = galois.mult(inout_matrix[index], scale);
                }
            }
            for (r + 1..row_count) |row_below| {
                assert(row_below < row_count);
                const index: usize = row_below * col_count + r;
                if (inout_matrix[index] != 0) {
                    const scale = inout_matrix[index];
                    inline for (0..col_count) |c| {
                        inout_matrix[row_below * col_count + c] ^= galois.mult(scale, inout_matrix[r * col_count + c]);
                    }
                }
            }
        }

        for (0..row_count) |d| {
            for (0..d) |row_above| {
                const index = row_above * col_count + d;
                if (inout_matrix[index] != 0) {
                    const scale = inout_matrix[index];
                    for (0..col_count) |c| {
                        inout_matrix[row_above * col_count + c] ^= galois.mult(scale, inout_matrix[d * col_count + c]);
                    }
                }
            }
        }
    }

    pub inline fn augment(
        comptime row_count: comptime_int,
        comptime left_col_count: comptime_int,
        comptime right_col_count: comptime_int,
        left: [row_count * left_col_count]u8,
        right: [row_count * right_col_count]u8,
    ) [row_count * (left_col_count + right_col_count)]u8 {
        @setEvalBranchQuota(5_000);
        const col_count = left_col_count + right_col_count;
        var out: [row_count * (left_col_count + right_col_count)]u8 = undefined;
        inline for (0..row_count) |r| {
            inline for (0..left_col_count) |c| {
                const dst_index = r * col_count + c;
                const src_index = r * left_col_count + c;
                out[dst_index] = left[src_index];
            }
            inline for (0..right_col_count) |c| {
                const dst_index = (r * col_count) + (left_col_count + c);
                const src_index = r * right_col_count + c;
                out[dst_index] = right[src_index];
            }
        }
        return out;
    }

    pub inline fn invert(
        comptime size: comptime_int,
        in_matrix: [size * size]u8,
    ) [size * size]u8 {
        const identity_matrix = identity(size);
        var working_matrix = matrix.augment(size, size, size, in_matrix, identity_matrix);
        matrix.gaussianEliminationArray(size, size * 2, &working_matrix);
        var out_matrix: [size * size]u8 = undefined;
        inline for (0..size) |r| {
            const dst_index = r * size;
            const src_index = r * size * 2;
            @memcpy(out_matrix[dst_index .. dst_index + size], working_matrix[src_index .. src_index + size]);
        }
        return out_matrix;
    }

    pub inline fn multArray(
        comptime left_row_count: comptime_int,
        comptime left_col_count: comptime_int,
        comptime right_row_count: comptime_int,
        comptime right_col_count: comptime_int,
        left: [left_row_count * right_col_count]u8,
        right: [right_row_count * right_col_count]u8,
    ) [left_row_count * right_col_count]u8 {
        assert(left_col_count == right_row_count);
        var out: [left_row_count * right_col_count]u8 = left;
        inline for (0..left_row_count) |r| {
            inline for (0..right_col_count) |c| {
                var accum: u8 = 0;
                inline for (0..left_col_count) |i| {
                    const left_index = r * left_col_count + i;
                    const right_index = i * right_col_count + c;
                    accum ^= galois.mult(left[left_index], right[right_index]);
                }
            }
        }
        return out;
    }
};

test "identity matrix" {
    const expect = std.testing.expect;
    const eql = std.mem.eql;
    {
        const expected = [4]u8{
            1, 0,
            0, 1,
        };
        const actual = matrix.identity(2);
        try expect(eql(u8, &expected, &actual));
    }
    {
        const expected = [9]u8{
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        };
        const actual = matrix.identity(3);
        try expect(eql(u8, &expected, &actual));
    }
    {
        const expected = [16]u8{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        };
        const actual = matrix.identity(4);
        try expect(eql(u8, &expected, &actual));
    }
}

test "swap rows" {
    const expect = std.testing.expect;
    const eql = std.mem.eql;

    {
        //
        // Swap the same rows, this should have no effect
        //
        var before = [16]u8{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        };
        matrix.swapRows(4, 4, &before, 2, 2);
        const after = [16]u8{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        };
        try expect(eql(u8, &after, &before));
    }

    {
        var before = [16]u8{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        };
        matrix.swapRows(4, 4, &before, 0, 3);
        const after = [16]u8{
            13, 14, 15, 16,
            5,  6,  7,  8,
            9,  10, 11, 12,
            1,  2,  3,  4,
        };
        try expect(eql(u8, &after, &before));
    }

    {
        var before = [16]u8{
            1, 2,  3,  4,  5,  6,  7,  8,
            9, 10, 11, 12, 13, 14, 15, 16,
        };
        matrix.swapRows(2, 8, &before, 0, 1);
        const after = [16]u8{
            9, 10, 11, 12, 13, 14, 15, 16,
            1, 2,  3,  4,  5,  6,  7,  8,
        };
        try expect(eql(u8, &after, &before));
    }
}

test "augment matrix array" {
    const expect = std.testing.expect;
    const eql = std.mem.eql;

    {
        const left = [16]u8{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        };
        const right = [8]u8{
            1, 2,
            3, 4,
            5, 6,
            7, 8,
        };
        const actual = matrix.augment(4, 4, 2, left, right);
        const expected = [24]u8{
            1,  2,  3,  4,  1, 2,
            5,  6,  7,  8,  3, 4,
            9,  10, 11, 12, 5, 6,
            13, 14, 15, 16, 7, 8,
        };
        try expect(eql(u8, &actual, &expected));
    }

    {
        const left = [5]u8{
            1,
            2,
            3,
            4,
            5,
        };
        const right = [20]u8{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
            17, 18, 19, 20,
        };
        const actual = matrix.augment(5, 1, 4, left, right);
        const expected = [25]u8{
            1, 1,  2,  3,  4,
            2, 5,  6,  7,  8,
            3, 9,  10, 11, 12,
            4, 13, 14, 15, 16,
            5, 17, 18, 19, 20,
        };
        try expect(eql(u8, &actual, &expected));
    }
}

test "vandermonde matrix" {
    const expect = std.testing.expect;
    const eql = std.mem.eql;
    const actual = generateVanderMondeMatrix(6, 4);
    const expected = [_]u8{
        1, 0, 0,  0,
        1, 1, 1,  1,
        1, 2, 4,  8,
        1, 3, 5,  15,
        1, 4, 16, 64,
        1, 5, 17, 85,
    };
    try expect(eql(u8, &expected, &actual));
}

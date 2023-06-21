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

        /// Given the size of an input buffer, calculate what size each shard should be
        /// for this encoder
        pub inline fn calculateShardSize(data_size: usize) usize {
            const required_padding: usize = blk: {
                const overshoot: usize = data_size % data_shard_count;
                break :blk if (overshoot == 0) 0 else (data_shard_count - overshoot);
            };
            const padded_input_size: usize = data_size + required_padding;
            assert(padded_input_size % data_shard_count == 0);
            return @divExact(padded_input_size, data_shard_count);
        }

        pub fn init(self: *@This()) void {
            for (&self.parity_rows, 0..) |*row, i| {
                const row_start = (data_shard_count + i) * data_shard_count;
                const row_end = row_start + data_shard_count;
                row.* = encoding_matrix.buffer[row_start..row_end];
            }
        }

        /// Converts an input buffer into a ShardBuffer with enough space for the parity shards#
        /// The ShardBuffer returned will be allocated and owned by the caller
        pub fn split(allocator: std.mem.Allocator, input_buffer: []const u8) !ShardBuffer {
            const shard_size = @This().calculateShardSize(input_buffer.len);
            // TODO: Allocating a new buffer and copying everything across is awful and unneccesary.
            //       This needs to be removed when I get to optimizing
            const new_shard_buffer_size: usize = shard_size * total_shard_count;
            var new_shard_buffer = try allocator.alloc(u8, new_shard_buffer_size);
            @memcpy(new_shard_buffer[0..input_buffer.len], input_buffer);
            return ShardBuffer{
                .shard_size = shard_size,
                .count = total_shard_count,
                .buffer = new_shard_buffer,
            };
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
        /// `parity_shard_buffer`: A buffer with enough space to hold `parity_shard_count` which will be
        ///                        used to store the recomputed parity shards
        pub fn verifyParity(self: *@This(), shard_buffer: *const ShardBuffer, parity_shard_buffer: *ShardBuffer) bool {
            _ = self;
            {
                const data_i: usize = 0;
                const input_shard = shard_buffer.getShard(data_i);
                for (0..parity_shard_count) |parity_i| {
                    var parity_shard = parity_shard_buffer.getShardMut(parity_i);
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
                        var parity_shard = parity_shard_buffer.getShardMut(parity_i);
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

            //
            // Compare the parity shards we were given with the ones we just (re) calculated
            //
            inline for (0..parity_shard_count) |parity_i| {
                const parity_shard = shard_buffer.getShard(data_shard_count + parity_i);
                const recalculated_parity_shard = parity_shard_buffer.getShard(parity_i);
                if (!std.mem.eql(u8, parity_shard, recalculated_parity_shard)) {
                    return false;
                }
            }

            return true;
        }

        pub fn reconstruct(self: *@This(), shard_buffer: *ShardBuffer, missing: BitSet(u64)) !void {
            _ = self;
            if (missing.noneSet()) {
                //
                // No shards marked as missing, nothing to do
                //
                return;
            }

            var sub_matrix: Matrix(data_shard_count, data_shard_count) = undefined;
            var sub_shards: [data_shard_count][]const u8 = undefined;
            {
                var sub_matrix_row: usize = 0;
                var matrix_row: usize = 0;
                while (matrix_row < total_shard_count and sub_matrix_row < data_shard_count) {
                    if (!missing.isSet(matrix_row)) {
                        for (0..data_shard_count) |c| {
                            sub_matrix.set(sub_matrix_row, c, encoding_matrix.get(matrix_row, c));
                        }
                        const shard_begin: usize = shard_buffer.shard_size * matrix_row;
                        const shard_end: usize = shard_begin + shard_buffer.shard_size;
                        sub_shards[sub_matrix_row] = shard_buffer.buffer[shard_begin..shard_end];
                        assert(sub_shards[sub_matrix_row].len == shard_buffer.shard_size);
                        sub_matrix_row += 1;
                    }
                    matrix_row += 1;
                }
                assert(sub_matrix_row > 0);
            }

            const data_decode_matrix = matrix.inverseOf(data_shard_count, sub_matrix);

            var missing_data_shards: [parity_shard_count][]u8 = undefined;
            var parity_rows: [parity_shard_count][]const u8 = undefined;
            var output_count: usize = 0;
            for (0..data_shard_count) |input_i| {
                if (missing.isSet(input_i)) {
                    const shard_begin: usize = shard_buffer.shard_size * input_i;
                    const shard_end: usize = shard_begin + shard_buffer.shard_size;
                    missing_data_shards[output_count] = shard_buffer.buffer[shard_begin..shard_end];
                    const parity_row_begin: usize = input_i * @TypeOf(data_decode_matrix).col_count;
                    const parity_row_end: usize = parity_row_begin + @TypeOf(data_decode_matrix).col_count;
                    parity_rows[output_count] = data_decode_matrix.buffer[parity_row_begin..parity_row_end];
                    output_count += 1;
                }
            }

            for (missing_data_shards[0..output_count], 0..) |*output_shard, output_i| {
                {
                    const data_i: usize = 0;
                    const encoding_matrix_parity_row = parity_rows[output_i];
                    const mult_table_index: usize = encoding_matrix_parity_row[data_i] * @as(usize, 256);
                    const mult_table_row = mult_table[mult_table_index .. mult_table_index + @as(usize, 256)];
                    for (0..shard_buffer.shard_size) |byte_i| {
                        const lookup_index = sub_shards[0][byte_i];
                        output_shard.*[byte_i] = mult_table_row[lookup_index];
                    }
                }
                inline for (sub_shards[1..], 1..) |data_shard, data_i| {
                    const encoding_matrix_parity_row = parity_rows[output_i];
                    const mult_table_index: usize = encoding_matrix_parity_row[data_i] * @as(usize, 256);
                    const mult_table_row = mult_table[mult_table_index .. mult_table_index + @as(usize, 256)];
                    for (0..shard_buffer.shard_size) |byte_i| {
                        output_shard.*[byte_i] ^= mult_table_row[data_shard[byte_i]];
                    }
                }
            }
        }
    };
}

fn generateEncodingMatrix(comptime data_shard_count: comptime_int, comptime total_shard_count: comptime_int) Matrix(total_shard_count, data_shard_count) {
    const vandermonde_matrix = matrix.generateVanderMondeMatrix(total_shard_count, data_shard_count);
    const matrix_top = vandermonde_matrix.truncateRows(data_shard_count);
    const matrix_top_inverted = matrix.inverseOf(data_shard_count, matrix_top);
    return matrix.multiply(vandermonde_matrix, matrix_top_inverted);
}

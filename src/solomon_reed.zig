const std = @import("std");
const assert = std.debug.assert;
const galois = @import("galois.zig");
const matrix = @import("matrix.zig");
const Matrix = matrix.Matrix;

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
    };
}

fn generateEncodingMatrix(comptime data_shard_count: comptime_int, comptime total_shard_count: comptime_int) Matrix(total_shard_count, data_shard_count) {
    const vandermonde_matrix = matrix.generateVanderMondeMatrix(total_shard_count, data_shard_count);
    const matrix_top = vandermonde_matrix.truncateRows(data_shard_count);
    // const matrix_top = vandermonde_matrix[0 .. data_shard_count * data_shard_count];
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

const std = @import("std");
const assert = std.debug.assert;
const galois = @import("galois.zig");

pub fn Matrix(comptime rows: usize, comptime cols: usize) type {
    return struct {
        const row_count = rows;
        const col_count = cols;

        buffer: [row_count * col_count]u8,

        pub inline fn get(self: @This(), row_index: usize, col_index: usize) u8 {
            return self.buffer[row_index * col_count + col_index];
        }

        pub inline fn set(self: *@This(), row_index: usize, col_index: usize, value: u8) void {
            self.buffer[row_index * col_count + col_index] = value;
        }

        pub fn truncateRows(self: @This(), comptime new_row_count: usize) Matrix(new_row_count, col_count) {
            return .{ .buffer = self.buffer[0 .. new_row_count * col_count].* };
        }

        pub inline fn swapRows(
            self: *@This(),
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
                for (&temp, self.buffer[src_index .. src_index + col_count]) |*dst, src|
                    dst.* = src;
            }
            {
                //
                // Copy row b into row a
                //
                const src_index: usize = row_index_b * col_count;
                const dst_index: usize = row_index_a * col_count;
                for (self.buffer[dst_index .. dst_index + col_count], self.buffer[src_index .. src_index + col_count]) |*dst, src|
                    dst.* = src;
            }
            {
                //
                // Copy temp into row b
                //
                const dst_index: usize = row_index_b * col_count;
                for (self.buffer[dst_index .. dst_index + col_count], &temp) |*dst, src|
                    dst.* = src;
            }
        }

        pub inline fn gaussianEliminationArray(self: *@This()) void {
            @setEvalBranchQuota(20_000);
            assert(col_count >= row_count);
            for (0..row_count) |r| {
                const diagnal_index: usize = r * col_count + r;
                if (self.buffer[diagnal_index] == 0) {
                    inner: for (r + 1..row_count) |row_below| {
                        if (self.buffer[row_below * col_count + r] != 0) {
                            swapRows(row_count, col_count, self.buffer, r, row_below);
                            break :inner;
                        }
                    }
                }
                assert(self.buffer[diagnal_index] != 0);
                if (self.buffer[diagnal_index] != 1) {
                    const scale = galois.divide(1, self.buffer[diagnal_index]);
                    inline for (0..col_count) |c| {
                        const index: usize = r * col_count + c;
                        self.buffer[index] = galois.mult(self.buffer[index], scale);
                    }
                }
                for (r + 1..row_count) |row_below| {
                    assert(row_below < row_count);
                    const index: usize = row_below * col_count + r;
                    if (self.buffer[index] != 0) {
                        const scale = self.buffer[index];
                        inline for (0..col_count) |c| {
                            self.buffer[row_below * col_count + c] ^= galois.mult(scale, self.buffer[r * col_count + c]);
                        }
                    }
                }
            }

            for (0..row_count) |d| {
                for (0..d) |row_above| {
                    const index = row_above * col_count + d;
                    if (self.buffer[index] != 0) {
                        const scale = self.buffer[index];
                        for (0..col_count) |c| {
                            self.buffer[row_above * col_count + c] ^= galois.mult(scale, self.buffer[d * col_count + c]);
                        }
                    }
                }
            }
        }

        pub fn log(self: @This()) void {
            const print = std.debug.print;
            print("\n", .{});
            inline for (0..row_count) |r| {
                inline for (0..col_count) |c| {
                    print("{d} ", .{self.buffer[r * col_count + c]});
                }
                print("\n", .{});
            }
        }
    };
}

pub inline fn identity(comptime size: comptime_int) Matrix(size, size) {
    const element_count = size * size;
    var out_matrix = Matrix(size, size){
        .buffer = [1]u8{0} ** element_count,
    };
    inline for (0..size) |i| {
        const index = (i * size) + i;
        out_matrix.buffer[index] = 1;
    }
    return out_matrix;
}

pub inline fn augment(
    comptime row_count: comptime_int,
    comptime left_col_count: comptime_int,
    comptime right_col_count: comptime_int,
    left: Matrix(row_count, left_col_count),
    right: Matrix(row_count, right_col_count),
) Matrix(row_count, left_col_count + right_col_count) {
    @setEvalBranchQuota(5_000);
    const col_count = left_col_count + right_col_count;
    var out_matrix: Matrix(row_count, col_count) = undefined;
    inline for (0..row_count) |r| {
        inline for (0..left_col_count) |c| {
            const dst_index = r * col_count + c;
            const src_index = r * left_col_count + c;
            out_matrix.buffer[dst_index] = left.buffer[src_index];
        }
        inline for (0..right_col_count) |c| {
            const dst_index = (r * col_count) + (left_col_count + c);
            const src_index = r * right_col_count + c;
            out_matrix.buffer[dst_index] = right.buffer[src_index];
        }
    }
    return out_matrix;
}

pub inline fn inverseOf(
    comptime size: comptime_int,
    in_matrix: Matrix(size, size),
) Matrix(size, size) {
    const identity_matrix: Matrix(size, size) = identity(size);
    var working_matrix: Matrix(size, size * 2) = augment(
        size,
        size,
        size,
        in_matrix,
        identity_matrix,
    );
    working_matrix.gaussianEliminationArray();
    var out_matrix: Matrix(size, size) = undefined;
    inline for (0..size) |r| {
        const dst_index = r * size;
        const src_index = r * size * 2;
        @memcpy(out_matrix.buffer[dst_index .. dst_index + size], working_matrix.buffer[src_index .. src_index + size]);
    }
    return out_matrix;
}

pub inline fn multArray(
    comptime left_row_count: comptime_int,
    comptime left_col_count: comptime_int,
    comptime right_row_count: comptime_int,
    comptime right_col_count: comptime_int,
    left: Matrix(left_row_count, left_col_count),
    right: Matrix(right_row_count, right_col_count),
) Matrix(left_row_count, right_col_count) {
    assert(left_col_count == right_row_count);
    var out_matrix: Matrix(left_row_count, left_col_count) = left;
    inline for (0..left_row_count) |r| {
        inline for (0..right_col_count) |c| {
            var accum: u8 = 0;
            inline for (0..left_col_count) |i| {
                const left_index = r * left_col_count + i;
                const right_index = i * right_col_count + c;
                accum ^= galois.mult(left.buffer[left_index], right.buffer[right_index]);
            }
            out_matrix.set(r, c, accum);
        }
    }
    return out_matrix;
}

pub fn generateVanderMondeMatrix(comptime row_count: comptime_int, comptime col_count: comptime_int) Matrix(row_count, col_count) {
    var out_matrix: Matrix(row_count, col_count) = undefined;
    inline for (0..row_count) |r| {
        inline for (0..col_count) |c| {
            const matrix_index = r * col_count + c;
            out_matrix.buffer[matrix_index] = galois.exp(r, c);
        }
    }
    return out_matrix;
}

fn equals(left: anytype, right: anytype) bool {
    const Type = @TypeOf(left);
    assert(Type == @TypeOf(right));
    assert(Type.row_count == Type.row_count);
    assert(Type.col_count == Type.col_count);
    return std.mem.eql(u8, &left.buffer, &right.buffer);
}

test "identity matrix" {
    const expect = std.testing.expect;
    {
        const expected = Matrix(2, 2){ .buffer = .{
            1, 0,
            0, 1,
        } };
        const actual = identity(2);
        try expect(equals(expected, actual));
    }
    {
        const expected = Matrix(3, 3){ .buffer = .{
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        } };
        const actual = identity(3);
        try expect(equals(expected, actual));
    }
    {
        const expected = Matrix(4, 4){ .buffer = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
        const actual = identity(4);
        try expect(equals(expected, actual));
    }
}

test "swap rows" {
    const expect = std.testing.expect;
    {
        //
        // Swap the same rows, this should have no effect
        //
        var before = Matrix(4, 4){
            .buffer = .{
                1,  2,  3,  4,
                5,  6,  7,  8,
                9,  10, 11, 12,
                13, 14, 15, 16,
            },
        };
        before.swapRows(2, 2);
        const after = Matrix(4, 4){ .buffer = .{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        } };
        try expect(equals(before, after));
    }

    {
        var before = Matrix(4, 4){ .buffer = .{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        } };
        before.swapRows(0, 3);
        const after = Matrix(4, 4){ .buffer = .{
            13, 14, 15, 16,
            5,  6,  7,  8,
            9,  10, 11, 12,
            1,  2,  3,  4,
        } };
        try expect(equals(before, after));
    }

    {
        var before = Matrix(2, 8){ .buffer = .{
            1, 2,  3,  4,  5,  6,  7,  8,
            9, 10, 11, 12, 13, 14, 15, 16,
        } };
        before.swapRows(0, 1);
        const after = Matrix(2, 8){ .buffer = .{
            9, 10, 11, 12, 13, 14, 15, 16,
            1, 2,  3,  4,  5,  6,  7,  8,
        } };
        try expect(equals(before, after));
    }
}

test "augment matrix array" {
    const expect = std.testing.expect;
    {
        const left = Matrix(4, 4){ .buffer = .{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
        } };
        const right = Matrix(4, 2){ .buffer = .{
            1, 2,
            3, 4,
            5, 6,
            7, 8,
        } };
        const actual = augment(4, 4, 2, left, right);
        const expected = Matrix(4, 6){ .buffer = .{
            1,  2,  3,  4,  1, 2,
            5,  6,  7,  8,  3, 4,
            9,  10, 11, 12, 5, 6,
            13, 14, 15, 16, 7, 8,
        } };
        try expect(equals(expected, actual));
    }

    {
        const left = Matrix(5, 1){ .buffer = .{
            1,
            2,
            3,
            4,
            5,
        } };
        const right = Matrix(5, 4){ .buffer = .{
            1,  2,  3,  4,
            5,  6,  7,  8,
            9,  10, 11, 12,
            13, 14, 15, 16,
            17, 18, 19, 20,
        } };
        const actual = augment(5, 1, 4, left, right);
        const expected = Matrix(5, 5){ .buffer = .{
            1, 1,  2,  3,  4,
            2, 5,  6,  7,  8,
            3, 9,  10, 11, 12,
            4, 13, 14, 15, 16,
            5, 17, 18, 19, 20,
        } };
        try expect(equals(expected, actual));
    }
}

test "vandermonde matrix" {
    const expect = std.testing.expect;
    const actual = generateVanderMondeMatrix(6, 4);
    const expected = Matrix(6, 4){ .buffer = .{
        1, 0, 0,  0,
        1, 1, 1,  1,
        1, 2, 4,  8,
        1, 3, 5,  15,
        1, 4, 16, 64,
        1, 5, 17, 85,
    } };
    try expect(equals(expected, actual));
}

const std = @import("std");
const assert = std.debug.assert;
const rs = @import("reedsolomon.zig");
const print = std.debug.print;

const data_shard_count = 17;
const parity_shard_count = 3;
const total_shard_count = data_shard_count + parity_shard_count;

const block_size: usize = 200 * 1000;
const processor_cache_size = 10 * 1024 * 1024;
const shard_buffer_count: usize = ((processor_cache_size * 2) / data_shard_count) / (block_size + 1);
const run_count: usize = 8;

var shard_buffer: [shard_buffer_count]rs.ShardBuffer = undefined;

pub fn main() !void {
    try runBenchmark();
}

fn runBenchmark() !void {
    const Encoder = rs.Encoder(data_shard_count, parity_shard_count);
    var encoder: Encoder = undefined;

    const allocator = std.heap.c_allocator;
    var shard_buffer_raw: []u8 = try allocator.alloc(u8, shard_buffer_count * block_size);

    const rng_seed = @intCast(u64, std.time.milliTimestamp());
    var default_rng = std.rand.DefaultPrng.init(rng_seed);
    var rng = default_rng.random();
    rng.bytes(shard_buffer_raw);

    for (0..shard_buffer_count) |i| {
        const buffer_offset_start: usize = i * block_size;
        const buffer_offset_end: usize = buffer_offset_start + block_size;
        shard_buffer[i] = rs.ShardBuffer{
            .shard_size = @divExact(block_size, total_shard_count),
            .count = total_shard_count,
            .buffer = shard_buffer_raw[buffer_offset_start..buffer_offset_end],
        };
    }

    var buffer_index: usize = 0;

    const bytes_per_kib = 1024;
    const bytes_per_mib = bytes_per_kib * 1024;
    const bytes_per_gib = bytes_per_mib * 1024;
    const max_run_duration_s = 2;
    const max_run_duration = max_run_duration_s * std.time.ns_per_s;

    for (0..run_count) |run_i| {
        var time_encoding: u64 = 0;
        var bytes_processed_count: u64 = 0;
        while (time_encoding <= max_run_duration) {
            const run_start_ns = std.time.nanoTimestamp();
            encoder.encode(&shard_buffer[buffer_index]);
            const run_end_ns = std.time.nanoTimestamp();

            time_encoding += @intCast(u64, run_end_ns - run_start_ns);

            buffer_index = @mod(buffer_index + 1, shard_buffer_count);
            bytes_processed_count += block_size;
        }

        if (bytes_processed_count >= bytes_per_gib) {
            const gib_per_sec: f64 = (@intToFloat(f64, bytes_processed_count) / bytes_per_gib) / max_run_duration_s;
            print("Run {d:1} :: {d:.2} Gib / sec\n", .{ run_i, gib_per_sec });
        } else if (bytes_processed_count >= bytes_per_mib) {
            const mib_per_sec: f64 = (@intToFloat(f64, bytes_processed_count) / bytes_per_mib) / max_run_duration_s;
            print("Run {d:2} :: {d:.2} Mib / sec\n", .{ run_i, mib_per_sec });
        } else if (bytes_processed_count >= bytes_per_kib) {
            const kib_per_sec: f64 = (@intToFloat(f64, bytes_processed_count) / bytes_per_kib) / max_run_duration_s;
            print("Run {d:2} :: {d:.2} Kib / sec\n", .{ run_i, kib_per_sec });
        } else {
            const kib_per_sec: f64 = @intToFloat(f64, bytes_processed_count) / max_run_duration_s;
            print("Run {d:2} :: {d:.2} bytes / sec\n", .{ run_i, kib_per_sec });
        }
    }
}

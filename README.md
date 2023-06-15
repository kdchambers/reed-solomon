# reed-solomon

Implementation of [reed-solomon](https://en.wikipedia.org/wiki/Reed%E2%80%93Solomon_error_correction) erasure codes in [zig](https://ziglang.org/).

## Benchmarks

```sh
$ zig build benchmark -Doptimize=ReleaseSafe
Benchmark: Parity Calculation
  Unique data:   1171 Kib
  Data shards:   17
  Parity shards: 3
  Run count:     8
  Run duration:  2 secs
Run 0 :: 1.05 Gib / sec
Run 1 :: 1.05 Gib / sec
Run 2 :: 1.06 Gib / sec
Run 3 :: 1.06 Gib / sec
Run 4 :: 1.06 Gib / sec
Run 5 :: 1.06 Gib / sec
Run 6 :: 1.06 Gib / sec
Run 7 :: 1.06 Gib / sec
```
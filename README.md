# hnsw

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A standalone Zig library for HNSW (Hierarchical Navigable Small World) approximate nearest-neighbor search.

## Features

- **Multiple Distance Metrics**: Euclidean, Cosine, Dot Product, Manhattan
- **Zero Dependencies**: Pure Zig standard library only
- **Memory Safe**: Allocator-backed lifecycle with no hidden allocations
- **Optional Persistence**: Binary snapshot save/load
- **Cross-Platform**: Linux, macOS, Windows support

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .hnsw = .{
        .url = "https://gitlab.com/devnw/zig/hnsw/-/archive/v0.1.0/hnsw-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const hnsw = b.dependency("hnsw", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hnsw", hnsw.module("hnsw"));
```

## Quick Start

```zig
const std = @import("std");
const hnsw = @import("hnsw");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a 3-dimensional index with Euclidean distance
    var index = try hnsw.Hnsw.init(allocator, 3, .euclidean, .{});
    defer index.deinit();

    // Insert vectors
    try index.insert(1, &[_]f32{ 1.0, 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0, 0.0 });
    try index.insert(3, &[_]f32{ 0.5, 0.5, 0.0 });

    // Find 2 nearest neighbors
    const results = try index.knnSearch(&[_]f32{ 0.6, 0.4, 0.0 }, 2);
    defer allocator.free(results);

    for (results) |r| {
        // r.id, r.distance
    }
```

## Distance Metrics

| Metric | Description | Range |
|--------|-------------|-------|
| `euclidean` | L2 distance | [0, +inf) |
| `cosine` | 1 - cosine similarity | [0, 2] |
| `dot_product` | Negated dot product (higher similarity = lower value) | (-inf, +inf) |
| `manhattan` | L1 distance | [0, +inf) |

All metrics follow the convention: **lower distance = more similar**.

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `m` | 16 | Max bi-directional connections per node per layer |
| `ef_construction` | 200 | Beam width during index construction |
| `ef_search` | 50 | Beam width during search |
| `max_layers` | 16 | Maximum graph layers |
| `seed` | 42 | Random seed for reproducible level assignment |

Higher `m` and `ef_construction` improve recall at the cost of memory and build time. Higher `ef_search` improves recall at the cost of query latency.

## Persistence

Persistence is **optional** and provided through the `persist` sub-module. Snapshots use a compact binary format with little-endian integers and native-endian floats.

```zig
const hnsw = @import("hnsw");

// Save
var file = try std.fs.cwd().createFile("index.hnsw", .{});
defer file.close();
var buf: [8192]u8 = undefined;
var writer = file.writer(&buf);
try hnsw.persist.save(&index, &writer.interface);

// Load
var loaded = try hnsw.persist.load(allocator, reader);
defer loaded.deinit();
```

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
make build

# Run unit tests
make test-unit

# Run integration tests
make test-integration

# Run all tests
make test

# Build and run the example
zig build example

# Quick development iteration
make dev

# Full CI pipeline
make ci
```

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

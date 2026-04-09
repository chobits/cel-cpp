# Benchmark Notes

## Background

This benchmark compares four paths for simple boolean matching: `cel-cpp` through a shared C API, `cel-rust` through a Rust `cdylib` C ABI, ATC Router through its Lua wrapper, and plain Lua as a minimal baseline. The goal is to compare realistic per-request cost against a lower-bound execution-only number and to understand where the steady-state gap comes from.

In an HTTP request path, values such as `path`, `host`, and `port` change for every request, so `bind+exec` is the realistic number. `exec-only` is only a lower-bound microbenchmark after inputs have already been prepared.

Benchmark driver: [tools/test.lua](tools/test.lua)

CEL C wrapper: [tools/cel_c_api.cc](tools/cel_c_api.cc), [tools/cel_c_api.h](tools/cel_c_api.h)

Rust C wrapper: `/Users/xc/work/cel-rust/cel_capi/src/lib.rs`


## Results

The table below summarizes the average latency per operation for each benchmark case from the latest local run. All boolean results matched the expected outcome in the raw run.

| Case | C++ `bind+exec` | C++ `exec-only` | Rust `bind+exec` | Rust `exec-only` | ATC | Lua |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `list membership` | `5.378` | `3.216` | `0.739` | `0.055` | `1.401` | `0.000` |
| `uri matching` | `9.595` | `5.507` | `0.789` | `0.435` | `1.369` | `0.000` |
| `uri exact matching` | `9.231` | `5.118` | `0.467` | `0.117` | `1.357` | `0.001` |
| `host and uri matching` | `9.787` | `5.589` | `0.981` | `0.462` | `1.512` | `0.000` |
| `uri miss` | `7.569` | `3.552` | `0.812` | `0.441` | `1.135` | `0.000` |

All values in the table are `us/op`.

For the exact CEL, ATC, and Lua expressions used in each case, see the `Raw results` section below.


## `bind+exec` and `exec-only`

`bind+exec` means that for each evaluation, we first bind request data into CEL variables such as `path`, `host`, and `port`, and then execute the expression.

`exec-only` means the variables have already been bound once, and we only measure the cost of running the expression itself repeatedly with the same bound values.

In an HTTP request scenario, `bind+exec` is the realistic number because request values change on every request. `exec-only` is only a lower-bound microbenchmark that isolates evaluation after inputs have already been prepared.

## Fairness Note

This benchmark is useful for comparing the end-to-end local embedding paths used here, but it is not a strict interpreter-core comparison between `cel-cpp` and `cel-rust`.

`cel-cpp` goes through a heavier compiler/runtime stack and evaluates through generic runtime objects such as `Activation`, protobuf `Arena`, and CEL `Value`. `cel-rust` exposes a thinner path with a long-lived `Context` and direct expression resolution. So the practical takeaway is: in this Lua FFI setup, the `cel-rust` path is much lighter than the `cel-cpp` path. It should not be read as proof that the two projects are identical in semantics and implementation layers, with Rust simply being faster.

## Why `cel-cpp` Is Slower In This Benchmark

1. The `cel-cpp` execution path is still much heavier than the `cel-rust` execution path.

	The current results still show a large steady-state gap after values are already bound. For `uri matching`, `cel-cpp(exec-only)` is `5.507 us/op`, while `cel-rust(exec-only)` is `0.435 us/op`. So the biggest difference is not only request-time binding, but the execution path itself.

2. `cel-cpp` evaluates through a generic runtime with more value plumbing and bookkeeping.

	On the C++ side, the benchmark path goes through generic CEL runtime objects such as `Activation`, protobuf `Arena`, `Value`, and, for list cases, a custom `CustomListValue` implementation. That adds flexibility, but it also means more dispatch, wrapping, and runtime bookkeeping per evaluation.

3. The Rust path keeps a long-lived context and a thinner execution model.

	The Rust wrapper keeps a long-lived `Context` and updates it in place. Its public `Program` is also thin: compile is basically parse, and execute is basically resolve against the stored expression and context. That reduces both binding overhead and per-evaluation runtime work.

4. ATC is still faster for route-style matching because it is specialized.

	Even with `cel-rust` in the mix, ATC remains the best reference point for narrow route-matching logic because its DSL and runtime are specialized for prefix, equality, and field-match operations instead of general-purpose expression evaluation.

5. This benchmark excludes parse and compile cost from the hot loop.

	The hot loop reuses pre-created programs in both CEL implementations. So the numbers above mostly describe request-time binding and steady-state execution, not one-time setup.

## Build

1. Build `cel-cpp`:

	```bash
	bazel build //:cel_cpp_shared
	```

2. Build the CEL C wrapper:

	```bash
	bazel build //tools:cel_c_api_shared
	```

3. Build the Rust C wrapper:

	```bash
	cd /Users/xc/work/cel-rust
	cargo build -p cel_capi --release
	```

4. Build and wire in ATC Router:

	```bash
	cd /Users/xc/work/dev/atc-router
	make build
	```

	The benchmark script expects the local ATC Router checkout at `/Users/xc/work/dev/atc-router` by default, and loads its Lua wrapper from `lib/resty/router` plus the shared library from `target/release`.

5. Run the benchmark:

	```bash
	luajit tools/test.lua
	```


## Raw results


```text
$ luajit tools/test.lua
gc[before_setup]: 93.60 KB
gc[after_setup]: 114.41 KB
1. list membership
cel-cpp: "\"foo\" in a" => true
cel-rust: "\"foo\" in a" => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: contains(a, "foo") => true
cel-cpp(bind+exec): 1.075557 s total, 5.378 us/op
cel-cpp(exec-only): 0.643296 s total, 3.216 us/op
cel-rust(bind+exec): 0.147847 s total, 0.739 us/op
cel-rust(exec-only): 0.010988 s total, 0.055 us/op
atc: 0.280284 s total, 1.401 us/op
lua: 0.000094 s total, 0.000 us/op

2. uri matching
cel-cpp: path.startsWith("/foo") && port == 80 => true
cel-rust: path.startsWith("/foo") && port == 80 => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => true
cel-cpp(bind+exec): 1.919056 s total, 9.595 us/op
cel-cpp(exec-only): 1.101344 s total, 5.507 us/op
cel-rust(bind+exec): 0.157782 s total, 0.789 us/op
cel-rust(exec-only): 0.087037 s total, 0.435 us/op
atc: 0.273834 s total, 1.369 us/op
lua: 0.000098 s total, 0.000 us/op

3. uri exact matching
cel-cpp: path == "/foo/bar" && port == 80 => true
cel-rust: path == "/foo/bar" && port == 80 => true
atc: http.path == "/foo/bar" && tcp.port == 80 => true
lua: path == "/foo/bar" and port == 80 => true
cel-cpp(bind+exec): 1.846179 s total, 9.231 us/op
cel-cpp(exec-only): 1.023547 s total, 5.118 us/op
cel-rust(bind+exec): 0.093310 s total, 0.467 us/op
cel-rust(exec-only): 0.023306 s total, 0.117 us/op
atc: 0.271392 s total, 1.357 us/op
lua: 0.000101 s total, 0.001 us/op

4. host and uri matching
cel-cpp: host == "example.com" && path.startsWith("/api") => true
cel-rust: host == "example.com" && path.startsWith("/api") => true
atc: http.host == "example.com" && http.path ^= "/api" => true
lua: host == "example.com" and path:sub(1, #"/api") == "/api" => true
cel-cpp(bind+exec): 1.957418 s total, 9.787 us/op
cel-cpp(exec-only): 1.117819 s total, 5.589 us/op
cel-rust(bind+exec): 0.196212 s total, 0.981 us/op
cel-rust(exec-only): 0.092369 s total, 0.462 us/op
atc: 0.302471 s total, 1.512 us/op
lua: 0.000095 s total, 0.000 us/op

5. uri miss
cel-cpp: path.startsWith("/foo") && port == 80 => false
cel-rust: path.startsWith("/foo") && port == 80 => false
atc: http.path ^= "/foo" && tcp.port == 80 => false
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => false
cel-cpp(bind+exec): 1.513736 s total, 7.569 us/op
cel-cpp(exec-only): 0.710423 s total, 3.552 us/op
cel-rust(bind+exec): 0.162457 s total, 0.812 us/op
cel-rust(exec-only): 0.088172 s total, 0.441 us/op
atc: 0.226971 s total, 1.135 us/op
lua: 0.000097 s total, 0.000 us/op
gc[after_benchmark]: 198.30 KB
gc[after_destroy]: 198.23 KB
```

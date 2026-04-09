# Benchmark Notes

## Background

This benchmark compares four paths for simple boolean matching: `cel-cpp` through a shared C API, `cel-rust` through a Rust `cdylib` C ABI, ATC Router through its Lua wrapper, and plain Lua as a minimal baseline. The goal is to compare realistic per-request cost against lower-bound execution-only numbers and to understand where the steady-state gap comes from.

In an HTTP request path, values such as `path`, `host`, and `port` change for every request, so `bind+exec` is the realistic number. `exec-only` is only a lower-bound microbenchmark after inputs have already been prepared.

Benchmark driver: [tools/test.lua](tools/test.lua)

CEL C wrapper: [tools/cel_c_api.cc](tools/cel_c_api.cc), [tools/cel_c_api.h](tools/cel_c_api.h)

Rust C wrapper: `/Users/xc/work/cel-rust/cel_capi/src/lib.rs`


## Results

The table below summarizes the average latency per operation for each benchmark case from the latest local run. All boolean results matched the expected outcome in the raw run.

| Case | C++ `bind+exec` | C++ `exec-only` | Rust `bind+exec` | Rust `exec-only` | ATC `bind+exec` | ATC `exec-only` | Lua |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `list membership` | `5.529` | `3.146` | `0.724` | `0.054` | `1.331` | `0.227` | `0.000` |
| `uri matching` | `9.746` | `5.535` | `0.824` | `0.460` | `1.349` | `0.224` | `0.001` |
| `uri exact matching` | `9.180` | `5.091` | `0.486` | `0.116` | `1.384` | `0.230` | `0.000` |
| `host and uri matching` | `9.847` | `5.571` | `0.942` | `0.441` | `1.479` | `0.269` | `0.001` |
| `uri miss` | `7.635` | `3.573` | `0.785` | `0.419` | `1.143` | `0.071` | `0.001` |

All values in the table are `us/op`, which means microseconds per operation.  Very small Lua results may appear as `0.000` in the table because they are rounded to three decimal places, not because the work literally took zero time.

For the exact CEL, ATC, and Lua expressions used in each case, see the `Raw results` section below.

### Results Summary

- In this Lua FFI setup, `cel-rust` is much lighter than `cel-cpp` in both `bind+exec` and `exec-only`.
- `cel-cpp` remains the slowest CEL path because it goes through a heavier generic compiler/runtime stack, including CEL runtime objects such as `Activation` and `Value`, protobuf `Arena` management, and more general-purpose bookkeeping than the thinner `cel-rust` path.
- After splitting ATC into `bind+exec` and `exec-only`, it becomes clear that much of the ATC cost is in Lua-side context reset and field insertion, not in the matcher core itself.
- For route-style prefix matching, `atc(exec-only)` is faster than `cel-rust(exec-only)`, so ATC's matcher core is still very competitive.


## `bind+exec` and `exec-only`

`bind+exec` means that for each evaluation, we first bind request data into CEL variables or matcher context, and then execute the expression.

`exec-only` means the variables have already been bound once, and we only measure the cost of running the expression itself repeatedly with the same bound values.

In an HTTP request scenario, `bind+exec` is the realistic number because request values change on every request. `exec-only` is only a lower-bound microbenchmark that isolates evaluation after inputs have already been prepared.

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
gc[before_setup]: 94.51 KB
gc[after_setup]: 115.32 KB
1. list membership
cel-cpp: "\"foo\" in a" => true
cel-rust: "\"foo\" in a" => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: contains(a, "foo") => true
cel-cpp(bind+exec): 1.105900 s total, 5.529 us/op
cel-cpp(exec-only): 0.629142 s total, 3.146 us/op
cel-rust(bind+exec): 0.144808 s total, 0.724 us/op
cel-rust(exec-only): 0.010787 s total, 0.054 us/op
atc(bind+exec): 0.266156 s total, 1.331 us/op
atc(exec-only): 0.045427 s total, 0.227 us/op
lua: 0.000093 s total, 0.000 us/op

2. uri matching
cel-cpp: path.startsWith("/foo") && port == 80 => true
cel-rust: path.startsWith("/foo") && port == 80 => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => true
cel-cpp(bind+exec): 1.949159 s total, 9.746 us/op
cel-cpp(exec-only): 1.106958 s total, 5.535 us/op
cel-rust(bind+exec): 0.164743 s total, 0.824 us/op
cel-rust(exec-only): 0.091928 s total, 0.460 us/op
atc(bind+exec): 0.269723 s total, 1.349 us/op
atc(exec-only): 0.044705 s total, 0.224 us/op
lua: 0.000100 s total, 0.001 us/op

3. uri exact matching
cel-cpp: path == "/foo/bar" && port == 80 => true
cel-rust: path == "/foo/bar" && port == 80 => true
atc: http.path == "/foo/bar" && tcp.port == 80 => true
lua: path == "/foo/bar" and port == 80 => true
cel-cpp(bind+exec): 1.835900 s total, 9.180 us/op
cel-cpp(exec-only): 1.018183 s total, 5.091 us/op
cel-rust(bind+exec): 0.097277 s total, 0.486 us/op
cel-rust(exec-only): 0.023113 s total, 0.116 us/op
atc(bind+exec): 0.276742 s total, 1.384 us/op
atc(exec-only): 0.046014 s total, 0.230 us/op
lua: 0.000098 s total, 0.000 us/op

4. host and uri matching
cel-cpp: host == "example.com" && path.startsWith("/api") => true
cel-rust: host == "example.com" && path.startsWith("/api") => true
atc: http.host == "example.com" && http.path ^= "/api" => true
lua: host == "example.com" and path:sub(1, #"/api") == "/api" => true
cel-cpp(bind+exec): 1.969385 s total, 9.847 us/op
cel-cpp(exec-only): 1.114290 s total, 5.571 us/op
cel-rust(bind+exec): 0.188328 s total, 0.942 us/op
cel-rust(exec-only): 0.088209 s total, 0.441 us/op
atc(bind+exec): 0.295856 s total, 1.479 us/op
atc(exec-only): 0.053865 s total, 0.269 us/op
lua: 0.000106 s total, 0.001 us/op

5. uri miss
cel-cpp: path.startsWith("/foo") && port == 80 => false
cel-rust: path.startsWith("/foo") && port == 80 => false
atc: http.path ^= "/foo" && tcp.port == 80 => false
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => false
cel-cpp(bind+exec): 1.526934 s total, 7.635 us/op
cel-cpp(exec-only): 0.714621 s total, 3.573 us/op
cel-rust(bind+exec): 0.157029 s total, 0.785 us/op
cel-rust(exec-only): 0.083827 s total, 0.419 us/op
atc(bind+exec): 0.228538 s total, 1.143 us/op
atc(exec-only): 0.014225 s total, 0.071 us/op
lua: 0.000120 s total, 0.001 us/op
gc[after_benchmark]: 202.59 KB
gc[after_destroy]: 202.53 KB
```

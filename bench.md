# Benchmark Notes

## Background

This benchmark compares three ways to evaluate simple expressions: CEL through the shared C API, ATC Router through its Lua wrapper, and plain Lua as a minimal baseline. The goal is to understand the rough performance gap and to separate CEL input binding cost from CEL execution cost. In an HTTP request path, values such as `path`, `host`, and `port` change for every request, so `bind+exec` is the realistic number, while `exec-only` is only a lower-bound microbenchmark after inputs have already been prepared.

Benchmark driver: [tools/test_cel_lua_atc.lua](tools/test_cel_lua_atc.lua)

CEL C wrapper: [tools/cel_c_api.cc](tools/cel_c_api.cc), [tools/cel_c_api.h](tools/cel_c_api.h)

## Build

1. Build `cel-cpp`:

	```bash
	bazel build //:cel_cpp_shared
	```

2. Build the CEL C wrapper:

	```bash
	bazel build //tools:cel_c_api_shared
	```

3. Build and wire in ATC Router:

	```bash
	cd /Users/xc/work/dev/atc-router
	make build
	```

	The benchmark script expects the local ATC Router checkout at `/Users/xc/work/dev/atc-router` by default, and loads its Lua wrapper from `lib/resty/router` plus the shared library from `target/release`. Let test_cel_lua_atc.lua find the right path of atc router lib: [link](https://github.com/chobits/cel-cpp/blob/master/tools/test_cel_lua_atc.lua#L37).

## Results

Each result block has two parts. The first three lines show whether CEL, ATC, and plain Lua all produced the expected boolean result for that case. The timing lines below show the average cost per operation. For example, in `ffi membership`, all three implementations return `true`, which means they all agree that the test condition matches. 

The numbers that follow show that plain Lua is the fastest baseline, for example: `cel(bind+exec): 0.005862 s total, 5.862 us/op`. Here, `cel(bind+exec)` is the benchmark mode, `0.005862 s total` is the total wall-clock time for the whole benchmark loop, and `5.862 us/op` means the average time per operation in microseconds. In other words, this line says that the CEL bind-and-execute path took about 5.862 microseconds for each evaluation on average.

```text
$ luajit tools/test.lua
gc[before_setup]: 83.50 KB
gc[after_setup]: 104.31 KB
1. ffi membership
cel: "\"foo\" in a" => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: contains(a, "foo") => true
cel(bind+exec): 0.005862 s total, 5.862 us/op
cel(exec-only): 0.003230 s total, 3.230 us/op
atc: 0.001781 s total, 1.781 us/op
lua: 0.000042 s total, 0.042 us/op

2. uri matching
cel: path.startsWith("/foo") && port == 80 => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => true
cel(bind+exec): 0.010322 s total, 10.322 us/op
cel(exec-only): 0.005856 s total, 5.856 us/op
atc: 0.002368 s total, 2.368 us/op
lua: 0.000029 s total, 0.029 us/op

3. uri exact matching
cel: path == "/foo/bar" && port == 80 => true
atc: http.path == "/foo/bar" && tcp.port == 80 => true
lua: path == "/foo/bar" and port == 80 => true
cel(bind+exec): 0.011096 s total, 11.096 us/op
cel(exec-only): 0.005062 s total, 5.062 us/op
atc: 0.001568 s total, 1.568 us/op
lua: 0.000012 s total, 0.012 us/op

4. host and uri matching
cel: host == "example.com" && path.startsWith("/api") => true
atc: http.host == "example.com" && http.path ^= "/api" => true
lua: host == "example.com" and path:sub(1, #"/api") == "/api" => true
cel(bind+exec): 0.009885 s total, 9.885 us/op
cel(exec-only): 0.005567 s total, 5.567 us/op
atc: 0.001683 s total, 1.683 us/op
lua: 0.000022 s total, 0.022 us/op

5. uri miss
cel: path.startsWith("/foo") && port == 80 => false
atc: http.path ^= "/foo" && tcp.port == 80 => false
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => false
cel(bind+exec): 0.007797 s total, 7.797 us/op
cel(exec-only): 0.003632 s total, 3.632 us/op
atc: 0.001269 s total, 1.269 us/op
lua: 0.000024 s total, 0.024 us/op
gc[after_benchmark]: 168.90 KB
gc[after_destroy]: 168.83 KB
```
## CEL: `bind+exec` vs `exec-only`

`bind+exec` means that for each evaluation, we first bind request data into CEL variables such as `path`, `host`, and `port`, and then execute the expression.

`exec-only` means the variables have already been bound once, and we only measure the cost of running the expression itself repeatedly with the same bound values.

In an HTTP request scenario, `bind+exec` is the realistic number. Each incoming request usually carries different values for `path`, `host`, headers, method, port, and other attributes, so those variables must be rebound for every request. Because of that, `exec-only` is not a realistic end-to-end per-request latency for normal request matching. It is only a lower-bound microbenchmark that isolates the cost of CEL evaluation after input preparation has already been done.

So, for real request matching:

- `bind+exec` is the meaningful latency number.
- `exec-only` is a diagnostic number that shows how much of the total cost comes from variable binding versus expression execution.

## Why The Four Results Differ

`Lua` is fastest because it is just running direct native Lua string and integer checks, such as prefix comparison or equality, with almost no abstraction overhead.

`ATC` is much faster than CEL because it is a specialized routing engine. Its DSL and execution model are designed specifically for route matching, so it avoids much of the general-purpose machinery that CEL uses.

`CEL (exec-only)` is slower than ATC because CEL is a general expression engine. Even after variables are already bound, it still needs to execute through a generic runtime, resolve values, dispatch operators and functions like `startsWith`, and materialize the result.

`CEL (bind+exec)` is the slowest CEL mode because it includes both the general CEL execution cost and the additional per-request variable binding cost. That binding step means taking request values and inserting them into the CEL activation before evaluation.

A simple summary is:

- `Lua`: minimal handwritten logic with almost no framework overhead.
- `ATC`: specialized native matcher for routing.
- `CEL (exec-only)`: generic expression runtime only.
- `CEL (bind+exec)`: generic expression runtime plus per-request input binding.


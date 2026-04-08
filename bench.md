# Benchmark Notes

## Background

This benchmark compares three ways to evaluate simple expressions: CEL through the shared C API, ATC Router through its Lua wrapper, and plain Lua as a minimal baseline. The goal is to understand the rough performance gap and to separate CEL input binding cost from CEL execution cost. In an HTTP request path, values such as `path`, `host`, and `port` change for every request, so `bind+exec` is the realistic number, while `exec-only` is only a lower-bound microbenchmark after inputs have already been prepared.

Benchmark driver: [tools/test_cel_lua_atc.lua](tools/test_cel_lua_atc.lua)
CEL C wrapper: [tools/cel_c_api.cc](tools/cel_c_api.cc), [tools/cel_c_api.h](tools/cel_c_api.h)

## Results

```text
$ luajit tools/test_cel_lua_atc.lua
gc[before_setup]: 78.51 KB
gc[after_setup]: 104.29 KB
1. ffi membership
cel: "\"foo\" in a" => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: contains(a, "foo") => true
cel: 0.178113 s total, 5.937 us/op
atc: 0.043045 s total, 1.435 us/op
lua: 0.000042 s total, 0.001 us/op

2. uri matching
cel: path.startsWith("/foo") && port == 80 => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => true
cel(bind+exec): 0.285014 s total, 9.500 us/op
cel(exec-only): 0.164688 s total, 5.490 us/op
atc: 0.042591 s total, 1.420 us/op
lua: 0.000041 s total, 0.001 us/op

3. uri exact matching
cel: path == "/foo/bar" && port == 80 => true
atc: http.path == "/foo/bar" && tcp.port == 80 => true
lua: path == "/foo/bar" and port == 80 => true
cel(bind+exec): 0.273828 s total, 9.128 us/op
cel(exec-only): 0.152969 s total, 5.099 us/op
atc: 0.043358 s total, 1.445 us/op
lua: 0.000038 s total, 0.001 us/op

4. host and uri matching
cel: host == "example.com" && path.startsWith("/api") => true
atc: http.host == "example.com" && http.path ^= "/api" => true
lua: host == "example.com" and path:sub(1, #"/api") == "/api" => true
cel(bind+exec): 0.291965 s total, 9.732 us/op
cel(exec-only): 0.166853 s total, 5.562 us/op
atc: 0.046070 s total, 1.536 us/op
lua: 0.000050 s total, 0.002 us/op

5. uri miss
cel: path.startsWith("/foo") && port == 80 => false
atc: http.path ^= "/foo" && tcp.port == 80 => false
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => false
cel(bind+exec): 0.226151 s total, 7.538 us/op
cel(exec-only): 0.104598 s total, 3.487 us/op
atc: 0.035057 s total, 1.169 us/op
lua: 0.000042 s total, 0.001 us/op
gc[after_benchmark]: 166.38 KB
gc[after_destroy]: 166.32 KB
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


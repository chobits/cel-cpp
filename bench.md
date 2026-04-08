# Benchmark Notes

## Background

This benchmark compares three ways to evaluate simple expressions: CEL through the shared C API, ATC Router through its Lua wrapper, and plain Lua as a minimal baseline. The goal is to understand the rough performance gap and to separate CEL input binding cost from CEL execution cost. In an HTTP request path, values such as `path`, `host`, and `port` change for every request, so `bind+exec` is the realistic number, while `exec-only` is only a lower-bound microbenchmark after inputs have already been prepared.

Benchmark driver: [tools/test_cel_lua_atc.lua](tools/test_cel_lua_atc.lua)

CEL C wrapper: [tools/cel_c_api.cc](tools/cel_c_api.cc), [tools/cel_c_api.h](tools/cel_c_api.h)


## Results

The table below summarizes the average latency per operation for each benchmark case. All boolean results matched the expected outcome in the raw run.

| Case | CEL `bind+exec` | CEL `exec-only` | ATC | Lua |
| --- | ---: | ---: | ---: | ---: |
| `list membership` | `5.862 us/op` | `3.230 us/op` | `1.781 us/op` | `0.042 us/op` |
| `uri matching` | `10.322 us/op` | `5.856 us/op` | `2.368 us/op` | `0.029 us/op` |
| `uri exact matching` | `11.096 us/op` | `5.062 us/op` | `1.568 us/op` | `0.012 us/op` |
| `host and uri matching` | `9.885 us/op` | `5.567 us/op` | `1.683 us/op` | `0.022 us/op` |
| `uri miss` | `7.797 us/op` | `3.632 us/op` | `1.269 us/op` | `0.024 us/op` |

For Case name (`list membership`), if you want to see the exact CEL, ATC, and Lua expressions used in the benchmark, see the `Raw results` section below.

`bind+exec` is the more realistic per-request number for HTTP-style matching, because request values such as `path`, `host`, and `port` usually need to be rebound for every request. `exec-only` is a lower-bound number that isolates expression execution after inputs have already been prepared.


## CEL: `bind+exec` vs `exec-only`

`bind+exec` means that for each evaluation, we first bind request data into CEL variables such as `path`, `host`, and `port`, and then execute the expression.

`exec-only` means the variables have already been bound once, and we only measure the cost of running the expression itself repeatedly with the same bound values.

In an HTTP request scenario, `bind+exec` is the realistic number. Each incoming request usually carries different values for `path`, `host`, headers, method, port, and other attributes, so those variables must be rebound for every request. Because of that, `exec-only` is not a realistic end-to-end per-request latency for normal request matching. It is only a lower-bound microbenchmark that isolates the cost of CEL evaluation after input preparation has already been done.

So, for real request matching:

- `bind+exec` is the meaningful latency number.
- `exec-only` is a diagnostic number that shows how much of the total cost comes from variable binding versus expression execution.

## Why CEL Is Slower Than ATC Router

1. CEL is a general-purpose expression engine, while ATC Router is a routing-specific matcher.

	In this benchmark, CEL is evaluating expressions such as `path.startsWith("/foo") && port == 80` through a generic runtime. That runtime is designed to support many kinds of expressions, types, operators, and functions, not just route matching. ATC Router does not need that level of generality. Its DSL is much narrower, so its execution path can stay closer to a direct route-matching engine.

	More concretely, CEL is built like a reusable expression runtime. Before it can answer one simple route-style question, it still has to go through the same machinery it would use for many other kinds of expressions. ATC Router can skip much of that because it is not trying to be a general expression system.

2. CEL pays more runtime dispatch cost for every evaluation.

	Even in `exec-only` mode, CEL still has to resolve variables, evaluate the expression tree, dispatch operators or functions such as `startsWith`, and materialize the boolean result. In other words, the runtime must decide which generic operation implementation to call and then execute it. ATC Router does much less of this generic dispatch work because its operations are specialized for routing semantics such as prefix match and equality match.

	A simpler way to think about `dispatch cost` is this: CEL first has to figure out what operation is being requested, find the corresponding implementation, and then run it. So a call like `path.startsWith("/foo")` is not just a direct prefix check. The runtime must resolve `path`, confirm it is a string, route the call to the generic `startsWith` implementation, and then wrap the answer back into a CEL boolean value. ATC Router can stay closer to a dedicated prefix-match path, so it does less indirection.

3. CEL has explicit input binding overhead in the realistic request path.

	In `bind+exec`, each request value such as `path`, `host`, or `port` is inserted into the CEL activation before evaluation. That cost is visible in the gap between `bind+exec` and `exec-only`. For HTTP-style matching, this binding cost is real, because request inputs usually change for every request. ATC Router also consumes request inputs, but in this benchmark it stays within a more specialized context model and avoids part of CEL's general-purpose value binding overhead.

	A simpler description of `binding overhead` is: before CEL can run the expression, the wrapper has to take request data and load it into CEL's variable environment. That means steps like "take the request path string, create a CEL string value, store it under the variable name `path`, take the request port, create a CEL int value, store it under `port`". Those steps are small, but they happen on every request in the realistic path.

4. CEL uses more generic value representations and bookkeeping.

	The wrapper code binds inputs through CEL value objects and a reusable activation, and evaluation runs through the generic CEL runtime. That means more abstraction layers, more type handling, and more runtime bookkeeping than a specialized matcher needs. ATC Router can keep its internal representation closer to the specific data it matches, which reduces overhead.

	Here `bookkeeping` means the extra internal management work needed by a generic runtime. For example, the runtime may need to keep track of values in a generic container, preserve type information, pass data through runtime helper objects, and return results in a generic CEL value form rather than a raw native boolean. A specialized matcher can often work more directly on the original request fields with fewer conversions.

5. This benchmark already excludes some costs, so the remaining CEL gap is mostly execution-path overhead.

	The benchmark reuses compiled CEL programs and does not include parse or compile time inside the hot loop. That means the measured gap is not mainly coming from repeated compilation. The remaining difference is mostly from per-request binding cost plus the runtime cost of evaluating a general expression engine versus a specialized route matcher.

	This matters because it rules out an easy explanation. The benchmark is not repeatedly parsing or compiling the CEL expression inside the loop. So when `cel(exec-only)` is still slower than ATC, that remaining gap is mostly the steady-state cost of CEL evaluation itself, not one-time setup work.

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


## Raw results


```text
$ luajit tools/test.lua
gc[before_setup]: 83.50 KB
gc[after_setup]: 104.31 KB
1. list membership
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

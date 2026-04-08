## Build a shared library

On macOS you can build a dynamic library with Bazel via:

```sh
bazel build //:cel_cpp_shared
```

The resulting artifact is written to `bazel-bin/libcel_cpp.dylib`.


# test

```
cel-cpp $ luajit tools/test.lua bazel-bin/tools/libcel_c_api.dylib '"foo" in a' 50000
gc[before_setup]: 57.83 KB
gc[after_setup]: 58.00 KB
library: bazel-bin/tools/libcel_c_api.dylib
expression: "foo" in a
lua table a: { "foo", "bar" }
cel result: true
cel ffi membership: 0.254876 s total, 5.098 us/op
lua ipairs membership: 0.000072 s total, 0.001 us/op
gc[after_benchmark]: 62.98 KB
gc[after_destroy]: 62.99 KB
```

# benchmark results between lua, cel and atc

```
xc cel-cpp $ luajit tools/test.lua bazel-bin/tools/libcel_c_api.dylib '"foo" in a' 30000$ luajit tools/test.lua bazel-bin/tools/libcel_c_api.dylib '"foo" in a' 30000
gc[before_setup]: 76.63 KB
gc[after_setup]: 102.40 KB
1. ffi membership
cel: "\"foo\" in a" => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: contains(a, "foo") => true
cel: 0.159923 s total, 5.331 us/op
atc: 0.042689 s total, 1.423 us/op
lua: 0.000040 s total, 0.001 us/op

2. uri matching
cel: path.startsWith("/foo") && port == 80 => true
atc: http.path ^= "/foo" && tcp.port == 80 => true
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => true
cel: 0.281144 s total, 9.371 us/op
atc: 0.043273 s total, 1.442 us/op
lua: 0.000042 s total, 0.001 us/op

3. uri exact matching
cel: path == "/foo/bar" && port == 80 => true
atc: http.path == "/foo/bar" && tcp.port == 80 => true
lua: path == "/foo/bar" and port == 80 => true
cel: 0.273896 s total, 9.130 us/op
atc: 0.043247 s total, 1.442 us/op
lua: 0.000050 s total, 0.002 us/op

4. host and uri matching
cel: host == "example.com" && path.startsWith("/api") => true
atc: http.host == "example.com" && http.path ^= "/api" => true
lua: host == "example.com" and path:sub(1, #"/api") == "/api" => true
cel: 0.291840 s total, 9.728 us/op
atc: 0.046514 s total, 1.550 us/op
lua: 0.000063 s total, 0.002 us/op

5. uri miss
cel: path.startsWith("/foo") && port == 80 => false
atc: http.path ^= "/foo" && tcp.port == 80 => false
lua: path:sub(1, #"/foo") == "/foo" and port == 80 => false
cel: 0.223392 s total, 7.446 us/op
atc: 0.035427 s total, 1.181 us/op
lua: 0.000049 s total, 0.002 us/op
gc[after_benchmark]: 163.07 KB
gc[after_destroy]: 163.01 KB
xc cel-cpp $ 
```

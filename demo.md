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

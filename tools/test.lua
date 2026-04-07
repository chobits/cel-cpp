local ffi = require("ffi")

ffi.cdef[[
int cel_eval_int64(const char* expression, long long* result,
                   char* error_buffer, size_t error_buffer_size);
typedef struct cel_program cel_program;
cel_program* cel_create_string_list_bool_program(const char* expression,
                                                 const char* variable_name,
                                                 char* error_buffer,
                                                 size_t error_buffer_size);
int cel_eval_string_list_bool_program(const cel_program* program,
                                      const char* const* items,
                                      size_t item_count, int* result,
                                      char* error_buffer,
                                      size_t error_buffer_size);
void cel_destroy_program(cel_program* program);
]]

local lib_path = arg[1] or "bazel-bin/tools/libcel_c_api.dylib"
local cel_expression = arg[2] or [["foo" in a]]

local cel = ffi.load(lib_path)
local error_buffer = ffi.new("char[1024]")
local a = { "foo", "bar" }

local function force_gc(tag)
  collectgarbage("collect")
  collectgarbage("collect")
  print(string.format("gc[%s]: %.2f KB", tag, collectgarbage("count")))
end

local function ffi_string_array(values)
  local items = ffi.new("const char *[?]", #values)
  for i, value in ipairs(values) do
    items[i - 1] = value
  end
  return items
end

local function lua_list_contains(values, needle)
  for _, value in ipairs(values) do
    if value == needle then
      return true
    end
  end
  return false
end

local function benchmark(name, iterations, fn)
  local start_time = os.clock()
  for _ = 1, iterations do
    fn()
  end
  local elapsed = os.clock() - start_time
  print(string.format(
      "%s: %.6f s total, %.3f us/op",
      name, elapsed, elapsed * 1000000 / iterations))
end

force_gc("before_setup")

local program = cel.cel_create_string_list_bool_program(
    cel_expression, "a", error_buffer, 1024)
if program == nil then
  error("CEL program creation failed: " .. ffi.string(error_buffer))
end

local items = ffi_string_array(a)
local bool_result = ffi.new("int[1]")
local rc = cel.cel_eval_string_list_bool_program(
    program, items, #a, bool_result, error_buffer, 1024)
if rc ~= 0 then
  cel.cel_destroy_program(program)
  error("CEL evaluation failed: " .. ffi.string(error_buffer))
end

force_gc("after_setup")

print("library: " .. lib_path)
print("expression: " .. cel_expression)
print("lua table a: { \"foo\", \"bar\" }")
print("cel result: " .. tostring(bool_result[0] ~= 0))

if bool_result[0] == 0 then
  cel.cel_destroy_program(program)
  error("unexpected CEL result: false")
end

local iterations = tonumber(arg[3]) or 200000
benchmark("cel ffi membership", iterations, function()
  local bench_result = ffi.new("int[1]")
  local bench_rc = cel.cel_eval_string_list_bool_program(
      program, items, #a, bench_result, error_buffer, 1024)
  if bench_rc ~= 0 then
    error("CEL benchmark failed: " .. ffi.string(error_buffer))
  end
end)

benchmark("lua ipairs membership", iterations, function()
  local found = lua_list_contains(a, "foo")
  if not found then
    error("Lua benchmark failed: false")
  end
end)

force_gc("after_benchmark")

cel.cel_destroy_program(program)
program = nil
items = nil

force_gc("after_destroy")
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
cel_program* cel_create_scalar_bool_program(const char* expression,
                                            const char* const* string_variable_names,
                                            size_t string_variable_count,
                                            const char* const* int_variable_names,
                                            size_t int_variable_count,
                                            char* error_buffer,
                                            size_t error_buffer_size);
int cel_eval_scalar_bool_program(const cel_program* program,
                                 const char* const* string_values,
                                 size_t string_value_count,
                                 const long long* int_values,
                                 size_t int_value_count,
                                 int* result,
                                 char* error_buffer,
                                 size_t error_buffer_size);
int cel_bind_scalar_values(cel_program* program,
                           const char* const* string_values,
                           size_t string_value_count,
                           const long long* int_values,
                           size_t int_value_count,
                           char* error_buffer,
                           size_t error_buffer_size);
int cel_eval_bound_bool_program(cel_program* program,
                                int* result,
                                char* error_buffer,
                                size_t error_buffer_size);
void cel_destroy_program(cel_program* program);
]]

local lib_path = arg[1] or "bazel-bin/tools/libcel_c_api.dylib"
local cel_expression = arg[2] or [["foo" in a]]
local iterations = tonumber(arg[3]) or 200000
local atc_root = arg[4] or "/Users/xc/work/dev/atc-router"

local cel = ffi.load(lib_path)
local error_buffer = ffi.new("char[1024]")
local a = { "foo", "bar" }

local function prepend_package_path(path)
  package.path = path .. ";" .. package.path
end

local function prepend_package_cpath(path)
  package.cpath = path .. ";" .. package.cpath
end

local function install_atc_router_shims()
  package.preload["resty.core.base"] = function()
    return {
      get_string_buf = function(size)
        return ffi.new("uint8_t[?]", size)
      end,
      get_size_ptr = function()
        return ffi.new("uintptr_t[1]")
      end,
    }
  end
end

local function force_gc(tag)
  collectgarbage("collect")
  collectgarbage("collect")
  print(string.format("gc[%s]: %.2f KB", tag, collectgarbage("count")))
end

local function print_section(index, title)
  print(string.format("%d. %s", index, title))
end

local function print_expression_line(name, expression, result)
  print(string.format("%s: %s => %s", name, expression, tostring(result)))
end

local function print_note_line(name, note)
  print(string.format("%s: %s", name, note))
end

local function print_perf_line(name, elapsed, count)
  print(string.format(
      "%s: %.6f s total, %.3f us/op",
      name, elapsed, elapsed * 1000000 / count))
end

local function print_blank_line()
  print("")
end

local function ffi_string_array(values)
  local items = ffi.new("const char *[?]", #values)
  for i, value in ipairs(values) do
    items[i - 1] = value
  end
  return items
end

local function ffi_int64_array(values)
  local items = ffi.new("int64_t[?]", #values)
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

local function benchmark(iterations, fn)
  local start_time = os.clock()
  for _ = 1, iterations do
    fn()
  end
  local elapsed = os.clock() - start_time
  return elapsed
end

local function setup_atc_router()
  prepend_package_path(atc_root .. "/lib/?.lua")
  prepend_package_path(atc_root .. "/lib/?/init.lua")
  prepend_package_cpath(atc_root .. "/target/release/?.dylib")
  install_atc_router_shims()

  local schema = require("resty.router.schema")
  local router = require("resty.router.router")
  local context = require("resty.router.context")

  return {
    schema = schema,
    router = router,
    context = context,
  }
end

local function build_atc_case(modules, matcher_expr, values, matched_field)
  local s = modules.schema.new()
  assert(s:add_field("http.path", "String"))
  assert(s:add_field("http.host", "String"))
  assert(s:add_field("tcp.port", "Int"))

  local r = modules.router.new(s, 1)
  local matcher_uuid = "a921a9aa-ec0e-4cf3-a6cc-1aa5583d150c"
  local ok, err = r:add_matcher(
      0, matcher_uuid, matcher_expr)
  if not ok then
    error("ATC matcher creation failed: " .. err)
  end

  local c = modules.context.new(s)

  local function populate_context()
    c:reset()
    for field, value in pairs(values) do
      local add_ok, add_err = c:add_value(field, value)
      if not add_ok then
        error("ATC context add failed for " .. field .. ": " .. add_err)
      end
    end
  end

  populate_context()

  local matched = r:execute(c)
  local uuid, matched_value = c:get_result(matched_field)

  return {
    expression = matcher_expr,
    matched = matched,
    uuid = uuid,
    matched_value = matched_value,
    benchmark = function(expected_match)
      return benchmark(iterations, function()
        populate_context()
        local bench_matched = r:execute(c)
        if bench_matched ~= expected_match then
          error("ATC benchmark produced unexpected result")
        end
      end)
    end,
  }
end

local function run_lua_case(iterations, fn, expected_result)
  local result = fn()
  if result ~= expected_result then
    error("Lua test produced unexpected result")
  end

  return {
    result = result,
    elapsed = benchmark(iterations, function()
      if fn() ~= expected_result then
        error("Lua benchmark produced unexpected result")
      end
    end),
  }
end

local function run_cel_scalar_case(iterations, expression, string_variables,
                                   int_variables, expected_result)
  local string_names = {}
  local string_values = {}
  for _, variable in ipairs(string_variables) do
    string_names[#string_names + 1] = variable.name
    string_values[#string_values + 1] = variable.value
  end

  local int_names = {}
  local int_values = {}
  for _, variable in ipairs(int_variables) do
    int_names[#int_names + 1] = variable.name
    int_values[#int_values + 1] = variable.value
  end

  local name_array_strings = ffi_string_array(string_names)
  local name_array_ints = ffi_string_array(int_names)
  local program = cel.cel_create_scalar_bool_program(
      expression,
      #string_names > 0 and name_array_strings or nil,
      #string_names,
      #int_names > 0 and name_array_ints or nil,
      #int_names,
      error_buffer,
      1024)
  if program == nil then
    error("CEL scalar program creation failed: " .. ffi.string(error_buffer))
  end

  local value_array_strings = ffi_string_array(string_values)
  local value_array_ints = ffi_int64_array(int_values)
  local bool_result = ffi.new("int[1]")
  local rc = cel.cel_eval_scalar_bool_program(
      program,
      #string_values > 0 and value_array_strings or nil,
      #string_values,
      #int_values > 0 and value_array_ints or nil,
      #int_values,
      bool_result,
      error_buffer,
      1024)
  if rc ~= 0 then
    cel.cel_destroy_program(program)
    error("CEL scalar evaluation failed: " .. ffi.string(error_buffer))
  end

  local result = bool_result[0] ~= 0
  if result ~= expected_result then
    cel.cel_destroy_program(program)
    error("CEL scalar test produced unexpected result")
  end

  local bind_exec_elapsed = benchmark(iterations, function()
    local bench_rc = cel.cel_eval_scalar_bool_program(
        program,
        #string_values > 0 and value_array_strings or nil,
        #string_values,
        #int_values > 0 and value_array_ints or nil,
        #int_values,
        bool_result,
        error_buffer,
        1024)
    if bench_rc ~= 0 then
      error("CEL scalar benchmark failed: " .. ffi.string(error_buffer))
    end
    if (bool_result[0] ~= 0) ~= expected_result then
      error("CEL scalar benchmark produced unexpected result")
    end
  end)

  local bind_rc = cel.cel_bind_scalar_values(
      program,
      #string_values > 0 and value_array_strings or nil,
      #string_values,
      #int_values > 0 and value_array_ints or nil,
      #int_values,
      error_buffer,
      1024)
  if bind_rc ~= 0 then
    cel.cel_destroy_program(program)
    error("CEL scalar bind failed: " .. ffi.string(error_buffer))
  end

  local exec_only_elapsed = benchmark(iterations, function()
    local bench_rc = cel.cel_eval_bound_bool_program(
        program,
        bool_result,
        error_buffer,
        1024)
    if bench_rc ~= 0 then
      error("CEL scalar execute-only benchmark failed: " .. ffi.string(error_buffer))
    end
    if (bool_result[0] ~= 0) ~= expected_result then
      error("CEL scalar execute-only benchmark produced unexpected result")
    end
  end)

  cel.cel_destroy_program(program)
  return {
    result = result,
    bind_exec_elapsed = bind_exec_elapsed,
    exec_only_elapsed = exec_only_elapsed,
  }
end

local function lua_path_prefix_match(path, prefix, port, expected_port)
  return path:sub(1, #prefix) == prefix and port == expected_port
end

local function lua_path_exact_match(path, target, port, expected_port)
  return path == target and port == expected_port
end

local function lua_host_and_path_match(host, expected_host, path, prefix)
  return host == expected_host and path:sub(1, #prefix) == prefix
end

force_gc("before_setup")

local atc_modules = setup_atc_router()

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

if bool_result[0] == 0 then
  cel.cel_destroy_program(program)
  error("unexpected CEL result: false")
end

local bench_result = ffi.new("int[1]")
local cel_membership_elapsed = benchmark(iterations, function()
  local bench_rc = cel.cel_eval_string_list_bool_program(
      program, items, #a, bench_result, error_buffer, 1024)
  if bench_rc ~= 0 then
    error("CEL benchmark failed: " .. ffi.string(error_buffer))
  end
end)

local atc_membership_case = build_atc_case(
    atc_modules,
    'http.path ^= "/foo" && tcp.port == 80',
    { ["http.path"] = "/foo/bar", ["tcp.port"] = 80 },
    "http.path")
if not atc_membership_case.matched or
    atc_membership_case.uuid ~= "a921a9aa-ec0e-4cf3-a6cc-1aa5583d150c" or
    atc_membership_case.matched_value ~= "/foo" then
  error("unexpected ATC membership smoke result")
end

local lua_membership_case = run_lua_case(iterations, function()
  return lua_list_contains(a, "foo")
end, true)

print_section(1, "ffi membership")
print_expression_line("cel", string.format("%q", cel_expression), bool_result[0] ~= 0)
print_expression_line("atc", 'http.path ^= "/foo" && tcp.port == 80', atc_membership_case.matched)
print_expression_line("lua", 'contains(a, "foo")', lua_membership_case.result)
print_perf_line("cel", cel_membership_elapsed, iterations)
print_perf_line("atc", atc_membership_case.benchmark(true), iterations)
print_perf_line("lua", lua_membership_case.elapsed, iterations)
print_blank_line()

local atc_uri_prefix_case = build_atc_case(
    atc_modules,
    'http.path ^= "/foo" && tcp.port == 80',
    { ["http.path"] = "/foo/bar", ["tcp.port"] = 80 },
    "http.path")
local cel_uri_prefix_case = run_cel_scalar_case(
    iterations,
    'path.startsWith("/foo") && port == 80',
    {
      { name = "path", value = "/foo/bar" },
    },
    {
      { name = "port", value = 80 },
    },
    true)
local lua_uri_prefix_case = run_lua_case(iterations, function()
  return lua_path_prefix_match("/foo/bar", "/foo", 80, 80)
end, true)

print_section(2, "uri matching")
print_expression_line("cel", 'path.startsWith("/foo") && port == 80', cel_uri_prefix_case.result)
print_expression_line("atc", 'http.path ^= "/foo" && tcp.port == 80', atc_uri_prefix_case.matched)
print_expression_line("lua", 'path:sub(1, #"/foo") == "/foo" and port == 80', lua_uri_prefix_case.result)
print_perf_line("cel(bind+exec)", cel_uri_prefix_case.bind_exec_elapsed, iterations)
print_perf_line("cel(exec-only)", cel_uri_prefix_case.exec_only_elapsed, iterations)
print_perf_line("atc", atc_uri_prefix_case.benchmark(true), iterations)
print_perf_line("lua", lua_uri_prefix_case.elapsed, iterations)
print_blank_line()

local atc_uri_exact_case = build_atc_case(
    atc_modules,
    'http.path == "/foo/bar" && tcp.port == 80',
    { ["http.path"] = "/foo/bar", ["tcp.port"] = 80 },
    "http.path")
local cel_uri_exact_case = run_cel_scalar_case(
    iterations,
    'path == "/foo/bar" && port == 80',
    {
      { name = "path", value = "/foo/bar" },
    },
    {
      { name = "port", value = 80 },
    },
    true)
local lua_uri_exact_case = run_lua_case(iterations, function()
  return lua_path_exact_match("/foo/bar", "/foo/bar", 80, 80)
end, true)

print_section(3, "uri exact matching")
print_expression_line("cel", 'path == "/foo/bar" && port == 80', cel_uri_exact_case.result)
print_expression_line("atc", 'http.path == "/foo/bar" && tcp.port == 80', atc_uri_exact_case.matched)
print_expression_line("lua", 'path == "/foo/bar" and port == 80', lua_uri_exact_case.result)
print_perf_line("cel(bind+exec)", cel_uri_exact_case.bind_exec_elapsed, iterations)
print_perf_line("cel(exec-only)", cel_uri_exact_case.exec_only_elapsed, iterations)
print_perf_line("atc", atc_uri_exact_case.benchmark(true), iterations)
print_perf_line("lua", lua_uri_exact_case.elapsed, iterations)
print_blank_line()

local atc_host_path_case = build_atc_case(
    atc_modules,
    'http.host == "example.com" && http.path ^= "/api"',
    { ["http.host"] = "example.com", ["http.path"] = "/api/v1/users" },
    "http.path")
local cel_host_path_case = run_cel_scalar_case(
    iterations,
    'host == "example.com" && path.startsWith("/api")',
    {
      { name = "host", value = "example.com" },
      { name = "path", value = "/api/v1/users" },
    },
    {},
    true)
local lua_host_path_case = run_lua_case(iterations, function()
  return lua_host_and_path_match("example.com", "example.com", "/api/v1/users", "/api")
end, true)

print_section(4, "host and uri matching")
print_expression_line("cel", 'host == "example.com" && path.startsWith("/api")', cel_host_path_case.result)
print_expression_line("atc", 'http.host == "example.com" && http.path ^= "/api"', atc_host_path_case.matched)
print_expression_line("lua", 'host == "example.com" and path:sub(1, #"/api") == "/api"', lua_host_path_case.result)
print_perf_line("cel(bind+exec)", cel_host_path_case.bind_exec_elapsed, iterations)
print_perf_line("cel(exec-only)", cel_host_path_case.exec_only_elapsed, iterations)
print_perf_line("atc", atc_host_path_case.benchmark(true), iterations)
print_perf_line("lua", lua_host_path_case.elapsed, iterations)
print_blank_line()

local atc_miss_case = build_atc_case(
    atc_modules,
    'http.path ^= "/foo" && tcp.port == 80',
    { ["http.path"] = "/bar", ["tcp.port"] = 81 },
    "http.path")
local cel_miss_case = run_cel_scalar_case(
    iterations,
    'path.startsWith("/foo") && port == 80',
    {
      { name = "path", value = "/bar" },
    },
    {
      { name = "port", value = 81 },
    },
    false)
local lua_miss_case = run_lua_case(iterations, function()
  return lua_path_prefix_match("/bar", "/foo", 81, 80)
end, false)

print_section(5, "uri miss")
print_expression_line("cel", 'path.startsWith("/foo") && port == 80', cel_miss_case.result)
print_expression_line("atc", 'http.path ^= "/foo" && tcp.port == 80', atc_miss_case.matched)
print_expression_line("lua", 'path:sub(1, #"/foo") == "/foo" and port == 80', lua_miss_case.result)
print_perf_line("cel(bind+exec)", cel_miss_case.bind_exec_elapsed, iterations)
print_perf_line("cel(exec-only)", cel_miss_case.exec_only_elapsed, iterations)
print_perf_line("atc", atc_miss_case.benchmark(false), iterations)
print_perf_line("lua", lua_miss_case.elapsed, iterations)

force_gc("after_benchmark")

cel.cel_destroy_program(program)
program = nil
items = nil

force_gc("after_destroy")

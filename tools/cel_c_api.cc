#include "tools/cel_c_api.h"

#include <stddef.h>
#include <stdint.h>

#include <cstddef>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "checker/type_checker_builder.h"
#include "checker/validation_result.h"
#include "common/ast.h"
#include "common/decl.h"
#include "common/type.h"
#include "common/value.h"
#include "compiler/compiler.h"
#include "compiler/compiler_factory.h"
#include "compiler/standard_library.h"
#include "internal/status_macros.h"
#include "runtime/activation.h"
#include "runtime/runtime.h"
#include "runtime/runtime_builder.h"
#include "runtime/runtime_options.h"
#include "runtime/standard_runtime_builder_factory.h"
#include "common/typeinfo.h"
#include "common/values/custom_list_value.h"
#include "common/values/list_value.h"
#include "common/values/string_value.h"
#include "google/protobuf/arena.h"
#include "google/protobuf/descriptor.h"
#include "google/protobuf/message.h"

struct cel_program {
  std::string list_variable_name;
  std::vector<std::string> string_variable_names;
  std::vector<std::string> int_variable_names;
  std::unique_ptr<cel::Runtime> runtime;
  std::unique_ptr<cel::Program> program;
};

namespace {

class NativeStringListValue final : public cel::CustomListValueInterface {
 public:
  explicit NativeStringListValue(std::vector<std::string> values)
      : values_(std::move(values)) {}

 private:
  std::string DebugString() const override { return "native_string_list"; }

  absl::Status ConvertToJsonArray(
      const google::protobuf::DescriptorPool*,
      google::protobuf::MessageFactory*,
      google::protobuf::Message*) const override {
    return absl::UnimplementedError("JSON conversion is not implemented");
  }

  size_t Size() const override { return values_.size(); }

  absl::Status Get(size_t index,
                   const google::protobuf::DescriptorPool*,
                   google::protobuf::MessageFactory*,
                   google::protobuf::Arena*, cel::Value* result) const override {
    if (index >= values_.size()) {
      return absl::OutOfRangeError("list index out of range");
    }
    *result = cel::StringValue(values_[index]);
    return absl::OkStatus();
  }

  cel::CustomListValue Clone(google::protobuf::Arena* arena) const override {
    auto* cloned =
        google::protobuf::Arena::Create<NativeStringListValue>(arena, values_);
    return cel::CustomListValue(cloned, arena);
  }

  cel::TypeInfo GetNativeTypeId() const override {
    return cel::TypeId<NativeStringListValue>();
  }

  std::vector<std::string> values_;
};

void WriteError(const std::string& message, char* error_buffer,
                size_t error_buffer_size) {
  if (error_buffer == nullptr || error_buffer_size == 0) {
    return;
  }
  size_t copy_size = message.size();
  if (copy_size >= error_buffer_size) {
    copy_size = error_buffer_size - 1;
  }
  message.copy(error_buffer, copy_size);
  error_buffer[copy_size] = '\0';
}

int Fail(const std::string& message, char* error_buffer,
         size_t error_buffer_size) {
  WriteError(message, error_buffer, error_buffer_size);
  return 1;
}

int FailStatus(const absl::Status& status, char* error_buffer,
               size_t error_buffer_size) {
  return Fail(std::string(status.message()), error_buffer, error_buffer_size);
}

absl::StatusOr<cel_program*> CreateStringListBoolProgram(
    const char* expression, const char* variable_name) {
  if (expression == nullptr) {
    return absl::InvalidArgumentError("expression must not be null");
  }
  if (variable_name == nullptr) {
    return absl::InvalidArgumentError("variable_name must not be null");
  }

  const auto* descriptor_pool = google::protobuf::DescriptorPool::generated_pool();

  CEL_ASSIGN_OR_RETURN(auto compiler_builder,
                       cel::NewCompilerBuilder(descriptor_pool));
  CEL_RETURN_IF_ERROR(
      compiler_builder->AddLibrary(cel::StandardCompilerLibrary()));
  auto& checker_builder = compiler_builder->GetCheckerBuilder();
  CEL_RETURN_IF_ERROR(checker_builder.AddVariable(cel::MakeVariableDecl(
      variable_name,
      cel::ListType(checker_builder.arena(), cel::StringType()))));

  CEL_ASSIGN_OR_RETURN(auto compiler, compiler_builder->Build());
  CEL_ASSIGN_OR_RETURN(auto validation_result,
                       compiler->Compile(expression, "test.lua"));
  if (!validation_result.IsValid()) {
    return absl::InvalidArgumentError(validation_result.FormatError());
  }
  CEL_ASSIGN_OR_RETURN(auto ast, validation_result.ReleaseAst());

  cel::RuntimeOptions runtime_options;
  CEL_ASSIGN_OR_RETURN(auto runtime_builder,
                       cel::CreateStandardRuntimeBuilder(descriptor_pool,
                                                         runtime_options));
  CEL_ASSIGN_OR_RETURN(auto runtime, std::move(runtime_builder).Build());
  CEL_ASSIGN_OR_RETURN(auto program, runtime->CreateProgram(std::move(ast)));

  auto* handle = new cel_program{
      .list_variable_name = std::string(variable_name),
      .runtime = std::move(runtime),
      .program = std::move(program),
  };
  return handle;
}

absl::Status ValidateNames(const char* const* names, size_t count,
                           const char* label) {
  if (names == nullptr && count != 0) {
    return absl::InvalidArgumentError(std::string(label) +
                                      " must not be null when count > 0");
  }
  for (size_t index = 0; index < count; ++index) {
    if (names[index] == nullptr || names[index][0] == '\0') {
      return absl::InvalidArgumentError(std::string(label) +
                                        " entries must not be null or empty");
    }
  }
  return absl::OkStatus();
}

absl::StatusOr<cel_program*> CreateScalarBoolProgram(
    const char* expression, const char* const* string_variable_names,
    size_t string_variable_count, const char* const* int_variable_names,
    size_t int_variable_count) {
  if (expression == nullptr) {
    return absl::InvalidArgumentError("expression must not be null");
  }
  CEL_RETURN_IF_ERROR(
      ValidateNames(string_variable_names, string_variable_count,
                    "string_variable_names"));
  CEL_RETURN_IF_ERROR(
      ValidateNames(int_variable_names, int_variable_count,
                    "int_variable_names"));

  const auto* descriptor_pool = google::protobuf::DescriptorPool::generated_pool();

  CEL_ASSIGN_OR_RETURN(auto compiler_builder,
                       cel::NewCompilerBuilder(descriptor_pool));
  CEL_RETURN_IF_ERROR(
      compiler_builder->AddLibrary(cel::StandardCompilerLibrary()));

  auto& checker_builder = compiler_builder->GetCheckerBuilder();
  for (size_t index = 0; index < string_variable_count; ++index) {
    CEL_RETURN_IF_ERROR(checker_builder.AddVariable(cel::MakeVariableDecl(
        string_variable_names[index], cel::StringType())));
  }
  for (size_t index = 0; index < int_variable_count; ++index) {
    CEL_RETURN_IF_ERROR(checker_builder.AddVariable(
        cel::MakeVariableDecl(int_variable_names[index], cel::IntType())));
  }

  CEL_ASSIGN_OR_RETURN(auto compiler, compiler_builder->Build());
  CEL_ASSIGN_OR_RETURN(auto validation_result,
                       compiler->Compile(expression, "test.lua"));
  if (!validation_result.IsValid()) {
    return absl::InvalidArgumentError(validation_result.FormatError());
  }
  CEL_ASSIGN_OR_RETURN(auto ast, validation_result.ReleaseAst());

  cel::RuntimeOptions runtime_options;
  CEL_ASSIGN_OR_RETURN(auto runtime_builder,
                       cel::CreateStandardRuntimeBuilder(descriptor_pool,
                                                         runtime_options));
  CEL_ASSIGN_OR_RETURN(auto runtime, std::move(runtime_builder).Build());
  CEL_ASSIGN_OR_RETURN(auto program, runtime->CreateProgram(std::move(ast)));

  auto* handle = new cel_program{
      .string_variable_names = std::vector<std::string>(
          string_variable_names, string_variable_names + string_variable_count),
      .int_variable_names =
          std::vector<std::string>(int_variable_names,
                                   int_variable_names + int_variable_count),
      .runtime = std::move(runtime),
      .program = std::move(program),
  };
  return handle;
}

absl::StatusOr<bool> EvalStringListBoolProgram(const cel_program& program,
                                               const char* const* items,
                                               size_t item_count) {
  if (items == nullptr && item_count != 0) {
    return absl::InvalidArgumentError("items must not be null when item_count > 0");
  }

  std::vector<std::string> values;
  values.reserve(item_count);
  for (size_t index = 0; index < item_count; ++index) {
    if (items[index] == nullptr) {
      return absl::InvalidArgumentError("items entries must not be null");
    }
    values.emplace_back(items[index]);
  }

  google::protobuf::Arena arena;
  auto* list_impl =
      google::protobuf::Arena::Create<NativeStringListValue>(&arena, std::move(values));
  cel::Activation activation;
  activation.InsertOrAssignValue(
      program.list_variable_name,
      cel::ListValue(cel::CustomListValue(list_impl, &arena)));

  CEL_ASSIGN_OR_RETURN(auto value, program.program->Evaluate(&arena, activation));
  if (!value.IsBool()) {
    return absl::InvalidArgumentError("expression result is not a bool");
  }
  return value.GetBool().NativeValue();
}

absl::StatusOr<bool> EvalScalarBoolProgram(const cel_program& program,
                                           const char* const* string_values,
                                           size_t string_value_count,
                                           const int64_t* int_values,
                                           size_t int_value_count) {
  if (string_value_count != program.string_variable_names.size()) {
    return absl::InvalidArgumentError(
        "string value count does not match declared string variable count");
  }
  if (int_value_count != program.int_variable_names.size()) {
    return absl::InvalidArgumentError(
        "int value count does not match declared int variable count");
  }
  if (string_values == nullptr && string_value_count != 0) {
    return absl::InvalidArgumentError(
        "string_values must not be null when string_value_count > 0");
  }
  if (int_values == nullptr && int_value_count != 0) {
    return absl::InvalidArgumentError(
        "int_values must not be null when int_value_count > 0");
  }

  google::protobuf::Arena arena;
  cel::Activation activation;
  for (size_t index = 0; index < string_value_count; ++index) {
    if (string_values[index] == nullptr) {
      return absl::InvalidArgumentError(
          "string_values entries must not be null");
    }
    activation.InsertOrAssignValue(program.string_variable_names[index],
                                   cel::StringValue(string_values[index]));
  }
  for (size_t index = 0; index < int_value_count; ++index) {
    activation.InsertOrAssignValue(program.int_variable_names[index],
                                   cel::IntValue(int_values[index]));
  }

  CEL_ASSIGN_OR_RETURN(auto value, program.program->Evaluate(&arena, activation));
  if (!value.IsBool()) {
    return absl::InvalidArgumentError("expression result is not a bool");
  }
  return value.GetBool().NativeValue();
}

}  // namespace

extern "C" int cel_eval_int64(const char* expression, int64_t* result,
                               char* error_buffer,
                               size_t error_buffer_size) {
  if (expression == nullptr) {
    return Fail("expression must not be null", error_buffer,
                error_buffer_size);
  }
  if (result == nullptr) {
    return Fail("result must not be null", error_buffer, error_buffer_size);
  }

  const auto* descriptor_pool = google::protobuf::DescriptorPool::generated_pool();

  auto compiler_builder = cel::NewCompilerBuilder(descriptor_pool);
  if (!compiler_builder.ok()) {
    return Fail(std::string(compiler_builder.status().message()), error_buffer,
                error_buffer_size);
  }

  absl::Status add_library_status =
      (*compiler_builder)->AddLibrary(cel::StandardCompilerLibrary());
  if (!add_library_status.ok()) {
    return Fail(std::string(add_library_status.message()), error_buffer,
                error_buffer_size);
  }

  auto compiler = (*compiler_builder)->Build();
  if (!compiler.ok()) {
    return Fail(std::string(compiler.status().message()), error_buffer,
                error_buffer_size);
  }

  auto validation_result = (*compiler)->Compile(expression, "test.c");
  if (!validation_result.ok()) {
    return Fail(std::string(validation_result.status().message()), error_buffer,
                error_buffer_size);
  }

  if (!validation_result->IsValid()) {
    return Fail(validation_result->FormatError(), error_buffer,
                error_buffer_size);
  }

  auto ast = validation_result->ReleaseAst();
  if (!ast.ok()) {
    return Fail(std::string(ast.status().message()), error_buffer,
                error_buffer_size);
  }

  cel::RuntimeOptions runtime_options;
  auto runtime_builder =
      cel::CreateStandardRuntimeBuilder(descriptor_pool, runtime_options);
  if (!runtime_builder.ok()) {
    return Fail(std::string(runtime_builder.status().message()), error_buffer,
                error_buffer_size);
  }

  auto runtime = std::move(*runtime_builder).Build();
  if (!runtime.ok()) {
    return Fail(std::string(runtime.status().message()), error_buffer,
                error_buffer_size);
  }

  auto program = (*runtime)->CreateProgram(std::move(*ast));
  if (!program.ok()) {
    return Fail(std::string(program.status().message()), error_buffer,
                error_buffer_size);
  }

  google::protobuf::Arena arena;
  cel::Activation activation;
  auto value = (*program)->Evaluate(&arena, activation);
  if (!value.ok()) {
    return Fail(std::string(value.status().message()), error_buffer,
                error_buffer_size);
  }

  if (!value->IsInt()) {
    return Fail("expression result is not an int64", error_buffer,
                error_buffer_size);
  }

  *result = value->GetInt().NativeValue();
  WriteError("", error_buffer, error_buffer_size);
  return 0;
}

extern "C" cel_program* cel_create_string_list_bool_program(
    const char* expression, const char* variable_name, char* error_buffer,
    size_t error_buffer_size) {
  auto program = CreateStringListBoolProgram(expression, variable_name);
  if (!program.ok()) {
    FailStatus(program.status(), error_buffer, error_buffer_size);
    return nullptr;
  }
  WriteError("", error_buffer, error_buffer_size);
  return *program;
}

extern "C" int cel_eval_string_list_bool_program(
    const cel_program* program, const char* const* items, size_t item_count,
    int* result, char* error_buffer, size_t error_buffer_size) {
  if (program == nullptr) {
    return Fail("program must not be null", error_buffer, error_buffer_size);
  }
  if (result == nullptr) {
    return Fail("result must not be null", error_buffer, error_buffer_size);
  }

  auto evaluation = EvalStringListBoolProgram(*program, items, item_count);
  if (!evaluation.ok()) {
    return FailStatus(evaluation.status(), error_buffer, error_buffer_size);
  }

  *result = *evaluation ? 1 : 0;
  WriteError("", error_buffer, error_buffer_size);
  return 0;
}

extern "C" cel_program* cel_create_scalar_bool_program(
    const char* expression, const char* const* string_variable_names,
    size_t string_variable_count, const char* const* int_variable_names,
    size_t int_variable_count, char* error_buffer, size_t error_buffer_size) {
  auto program = CreateScalarBoolProgram(expression, string_variable_names,
                                         string_variable_count,
                                         int_variable_names, int_variable_count);
  if (!program.ok()) {
    FailStatus(program.status(), error_buffer, error_buffer_size);
    return nullptr;
  }
  WriteError("", error_buffer, error_buffer_size);
  return *program;
}

extern "C" int cel_eval_scalar_bool_program(
    const cel_program* program, const char* const* string_values,
    size_t string_value_count, const int64_t* int_values,
    size_t int_value_count, int* result, char* error_buffer,
    size_t error_buffer_size) {
  if (program == nullptr) {
    return Fail("program must not be null", error_buffer, error_buffer_size);
  }
  if (result == nullptr) {
    return Fail("result must not be null", error_buffer, error_buffer_size);
  }

  auto evaluation = EvalScalarBoolProgram(*program, string_values,
                                          string_value_count, int_values,
                                          int_value_count);
  if (!evaluation.ok()) {
    return FailStatus(evaluation.status(), error_buffer, error_buffer_size);
  }

  *result = *evaluation ? 1 : 0;
  WriteError("", error_buffer, error_buffer_size);
  return 0;
}

extern "C" void cel_destroy_program(cel_program* program) { delete program; }
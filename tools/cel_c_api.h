#ifndef THIRD_PARTY_CEL_CPP_TOOLS_CEL_C_API_H_
#define THIRD_PARTY_CEL_CPP_TOOLS_CEL_C_API_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cel_program cel_program;

// Evaluates a CEL expression and returns its int64 result.
//
// Returns 0 on success. On failure, returns non-zero and writes a readable
// error message into error_buffer when provided.
int cel_eval_int64(const char* expression, int64_t* result,
                   char* error_buffer, size_t error_buffer_size);

// Creates a reusable CEL program for a boolean expression over a list<string>
// variable, for example '"foo" in a'.
cel_program* cel_create_string_list_bool_program(const char* expression,
                                                 const char* variable_name,
                                                 char* error_buffer,
                                                 size_t error_buffer_size);

// Evaluates a previously created CEL program with a list<string> bound to the
// declared variable.
int cel_eval_string_list_bool_program(const cel_program* program,
                                      const char* const* items,
                                      size_t item_count, int* result,
                                      char* error_buffer,
                                      size_t error_buffer_size);

// Binds a list<string> value to a previously created CEL program.
int cel_bind_string_list_values(cel_program* program,
                                const char* const* items,
                                size_t item_count,
                                char* error_buffer,
                                size_t error_buffer_size);

// Creates a reusable CEL program for a boolean expression over scalar string
// and int64 variables, for example 'path.startsWith("/foo") && port == 80'.
cel_program* cel_create_scalar_bool_program(
    const char* expression, const char* const* string_variable_names,
    size_t string_variable_count, const char* const* int_variable_names,
    size_t int_variable_count, char* error_buffer, size_t error_buffer_size);

// Evaluates a previously created scalar CEL program with string and int64
// variables bound in the same order used at creation time.
int cel_eval_scalar_bool_program(const cel_program* program,
                                 const char* const* string_values,
                                 size_t string_value_count,
                                 const int64_t* int_values,
                                 size_t int_value_count, int* result,
                                 char* error_buffer,
                                 size_t error_buffer_size);

// Binds scalar values to a previously created scalar CEL program. The order
// of values must match the variable declaration order passed during creation.
int cel_bind_scalar_values(cel_program* program,
                           const char* const* string_values,
                           size_t string_value_count,
                           const int64_t* int_values,
                           size_t int_value_count, char* error_buffer,
                           size_t error_buffer_size);

// Evaluates a scalar CEL program using the values most recently bound via
// cel_bind_scalar_values().
int cel_eval_bound_bool_program(cel_program* program, int* result,
                                char* error_buffer,
                                size_t error_buffer_size);

void cel_destroy_program(cel_program* program);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // THIRD_PARTY_CEL_CPP_TOOLS_CEL_C_API_H_
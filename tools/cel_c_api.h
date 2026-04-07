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

void cel_destroy_program(cel_program* program);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // THIRD_PARTY_CEL_CPP_TOOLS_CEL_C_API_H_
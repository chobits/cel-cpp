#include "tools/cel_c_api.h"

#include <stdint.h>
#include <stdio.h>

int main(void) {
  const char* expression = "1 + 2 * 3";
  int64_t result = 0;
  char error[1024];

  if (cel_eval_int64(expression, &result, error, sizeof(error)) != 0) {
    fprintf(stderr, "CEL evaluation failed: %s\n", error);
    return 1;
  }

  printf("expression: %s\n", expression);
  printf("result: %lld\n", (long long)result);

  if (result != 7) {
    fprintf(stderr, "unexpected result: %lld\n", (long long)result);
    return 2;
  }

  return 0;
}
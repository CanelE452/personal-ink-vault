#ifndef INK_VAULT_NATIVE_H
#define INK_VAULT_NATIVE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Input is borrowed UTF-8 JSON, NUL-terminated. Null returns a JSON error.
 * The response is owned by Rust; pass it once, unchanged, to ink_vault_free. */
char *ink_vault_request(const char *request);
void ink_vault_free(char *response);

/* The version pointer is static. Do not modify or free it. */
const char *ink_vault_version(void);

#ifdef __cplusplus
}
#endif

#endif

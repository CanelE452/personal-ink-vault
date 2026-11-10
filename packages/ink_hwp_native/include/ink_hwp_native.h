#ifndef INK_HWP_NATIVE_H
#define INK_HWP_NATIVE_H
#ifdef __cplusplus
extern "C" {
#endif
/* UTF-8 JSON input. Returned JSON is owned by this library; free exactly once. */
char *ink_hwp_request(const char *request_json);
void ink_hwp_free(char *response_json);
/* Static storage; do not modify or free. */
const char *ink_hwp_version(void);
#ifdef __cplusplus
}
#endif
#endif

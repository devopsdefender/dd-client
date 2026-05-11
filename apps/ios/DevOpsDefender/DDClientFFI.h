#ifndef DD_CLIENT_FFI_H
#define DD_CLIENT_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*dd_client_stream_callback)(uint64_t handle, const char *event_json, void *context);

char *dd_client_import_key(const char *key_path, const char *key_content);
char *dd_client_replay_session(const char *request_json);
uint64_t dd_client_attach_stream_start(const char *request_json, dd_client_stream_callback callback, void *context);
void dd_client_attach_stream_stop(uint64_t handle);
bool dd_client_attach_stream_send(uint64_t handle, const uint8_t *bytes, size_t len);
void dd_client_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

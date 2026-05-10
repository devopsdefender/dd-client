#ifndef DD_CLIENT_FFI_H
#define DD_CLIENT_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

char *dd_client_keygen(const char *key_path, const char *cp_url, const char *label);
char *dd_client_agent_request(const char *request_json);
void dd_client_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

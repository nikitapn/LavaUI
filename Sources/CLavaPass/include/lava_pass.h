#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// This schema is separate from the explorer's network passwords.
char *lava_pass_keyring_lookup(const char *vault, int *failed);
int lava_pass_keyring_store(const char *vault, const char *password);
int lava_pass_keyring_forget(const char *vault);
void lava_pass_keyring_free(char *password);
#ifdef __cplusplus
}
#endif

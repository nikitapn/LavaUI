#include "lava_pass.h"
#include <libsecret/secret.h>

static const SecretSchema schema = {
    .name = "org.lavaui.LavaPass.MasterPassword",
    .flags = SECRET_SCHEMA_NONE,
    .attributes = {{"vault", SECRET_SCHEMA_ATTRIBUTE_STRING}, {NULL, 0}},
};
char *lava_pass_keyring_lookup(const char *vault, int *failed) {
    GError *error = NULL;
    char *password = secret_password_lookup_nonpageable_sync(&schema, NULL, &error, "vault", vault, NULL);
    *failed = error != NULL;
    g_clear_error(&error);
    return password;
}
int lava_pass_keyring_store(const char *vault, const char *password) {
    GError *error = NULL;
    gboolean result = secret_password_store_sync(&schema, SECRET_COLLECTION_DEFAULT,
        "LavaPass vault unlock", password, NULL, &error, "vault", vault, NULL);
    g_clear_error(&error);
    return result;
}
int lava_pass_keyring_forget(const char *vault) {
    GError *error = NULL;
    secret_password_clear_sync(&schema, NULL, &error, "vault", vault, NULL);
    int success = error == NULL;
    g_clear_error(&error);
    return success;
}
void lava_pass_keyring_free(char *password) { secret_password_free(password); }

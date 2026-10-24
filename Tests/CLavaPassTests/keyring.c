// Public test credentials only. The runner gives this a private Secret Service.
#include "lava_pass.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *vault = "/lavapass-tests/fixture.kdbx";
    int failed = 0;
    if (!lava_pass_keyring_store(vault, "public-test-password")) return 1;
    char *password = lava_pass_keyring_lookup(vault, &failed);
    if (!password || failed || strcmp(password, "public-test-password")) return 2;
    lava_pass_keyring_free(password);
    if (!lava_pass_keyring_forget(vault)) return 3;
    password = lava_pass_keyring_lookup(vault, &failed);
    if (password || failed) return 4;
    if (!lava_pass_keyring_forget(vault)) return 5;
    puts("Private keyring: store, lookup, forget, and absent-item cleanup passed");
    return 0;
}

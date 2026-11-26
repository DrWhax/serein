#pragma once
#include <ptrcheck.h>
#include <stddef.h>
#include <stdint.h>

enum SereinKeyStatus { SereinKeyOK, SereinKeyUnavailable, SereinKeyCorrupt, SereinKeyBusy, SereinKeyInvalid };
// The load operation fills exactly 32 bytes. Delete uses the same service/account serialization.
enum SereinKeyStatus serein_database_key(
    const uint8_t * __counted_by(service_size) service __attribute__((noescape)), size_t service_size,
    const uint8_t * __counted_by(account_size) account __attribute__((noescape)), size_t account_size,
    uint8_t * __counted_by(key_size) key __attribute__((noescape)), size_t key_size, int remove_key);

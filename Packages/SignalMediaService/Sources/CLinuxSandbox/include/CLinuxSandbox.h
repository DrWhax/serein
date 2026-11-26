#pragma once

// Applies a synchronized kernel allowlist to all threads. Returns 1 only
// after the entire process is restricted.
int serein_confine_memory_worker(void);
int serein_is_memory_worker_confined(void);

int serein_confine_call_worker(void);
int serein_confine_call_broker(void);
int serein_is_call_worker_confined(void);

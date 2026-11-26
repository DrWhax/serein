#pragma once
enum WorkerRole { MemoryWorker, CallingWorker, CallingBroker };
int serein_install_worker_filter(enum WorkerRole role);

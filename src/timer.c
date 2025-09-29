#define _POSIX_C_SOURCE 200809L
#include "timer.h"
#include <time.h>
#include <stdint.h>

// Funciones para obtener tiempo monotónico en nanosegundos
static inline uint64_t ns_now(void) {
#if defined(CLOCK_MONOTONIC)
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#else
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

// almacena el tiempo de inicio (t0) en el timer mono.
void timer_start(timer_mono_t *t) { t->t0_ns = ns_now(); }
// almacena el tiempo de fin (t1) en el timer mono.
void timer_stop (timer_mono_t *t) { t->t1_ns = ns_now(); }

// retorna la diferencia (t1 - t0) en segundos como double.
double timer_seconds(const timer_mono_t *t) {
    return (double)(t->t1_ns - t->t0_ns) / 1e9;
}

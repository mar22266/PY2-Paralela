#ifndef timer_h
#define timer_h

#include <stdint.h>

/*
define la estructura y funciones para medir tiempo de ejecución
*/
typedef struct {
    uint64_t t0_ns;
    uint64_t t1_ns;
} timer_mono_t;

void timer_start(timer_mono_t *t);
void timer_stop(timer_mono_t *t);
double timer_seconds(const timer_mono_t *t);
#endif

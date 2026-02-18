/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * timing.h — Memory barrier and busy-wait helpers for MMIO GPIO access
 */

#ifndef TIMING_H
#define TIMING_H

#include <time.h>

/*
 * Data memory barrier.  Ensures all prior memory writes (GPIO register stores)
 * are visible to the peripheral before subsequent writes proceed.
 *
 * On ARMv7/ARMv8, a DMB instruction is the correct barrier for MMIO.
 * On x86 (for compilation-testing only), a compiler barrier suffices.
 */
#if defined(__aarch64__) || defined(__arm__)
static inline void dmb(void)
{
    __asm__ __volatile__("dmb sy" ::: "memory");
}
#else
static inline void dmb(void)
{
    __asm__ __volatile__("" ::: "memory");
}
#endif

/*
 * Busy-wait for at least `ns` nanoseconds.
 * Uses clock_gettime(CLOCK_MONOTONIC) for a tight spin loop.
 * Suitable for very short delays (< 1 µs) where nanosleep() overhead
 * would dominate.
 */
static inline void ndelay(unsigned int ns)
{
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);

    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000000000L
                     + (now.tv_nsec - start.tv_nsec);
        if (elapsed >= (long)ns)
            break;
    }
}

#endif /* TIMING_H */

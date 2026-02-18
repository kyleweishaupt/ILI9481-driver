/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * uinput_touch.h — uinput virtual touchscreen device API
 *
 * Only compiled when ENABLE_TOUCH=1.
 */

#ifndef UINPUT_TOUCH_H
#define UINPUT_TOUCH_H

#ifdef ENABLE_TOUCH

#include <stdint.h>

/* Opaque uinput touch device handle */
struct uinput_touch;

/*
 * uinput_touch_create() — Create a uinput device with ABS_X, ABS_Y,
 *                          and BTN_TOUCH capabilities.
 *
 * `max_x` and `max_y` are the screen dimensions.
 */
struct uinput_touch *uinput_touch_create(int max_x, int max_y);

/*
 * uinput_touch_report() — Emit a touch event.
 *
 * If `down` is non-zero, emits ABS_X, ABS_Y, BTN_TOUCH=1.
 * If `down` is zero, emits BTN_TOUCH=0.
 * Followed by EV_SYN in both cases.
 */
void uinput_touch_report(struct uinput_touch *ut, int down, int x, int y);

/*
 * uinput_touch_destroy() — Remove device and free.
 */
void uinput_touch_destroy(struct uinput_touch *ut);

#endif /* ENABLE_TOUCH */

#endif /* UINPUT_TOUCH_H */

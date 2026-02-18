/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * uinput_touch.c — uinput virtual touchscreen: ABS_X/ABS_Y/BTN_TOUCH
 *
 * Only compiled when ENABLE_TOUCH=1.
 */

#ifdef ENABLE_TOUCH

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <linux/uinput.h>

#include "uinput_touch.h"
#include "../core/logging.h"

/* ------------------------------------------------------------------ */
/* Internal state                                                     */
/* ------------------------------------------------------------------ */

struct uinput_touch {
    int fd;
};

/* ------------------------------------------------------------------ */
/* Helper: emit a single input event                                  */
/* ------------------------------------------------------------------ */

static void emit(int fd, uint16_t type, uint16_t code, int32_t value)
{
    struct input_event ev = {
        .type  = type,
        .code  = code,
        .value = value,
    };
    /* Best effort — ignore write failures */
    (void)write(fd, &ev, sizeof(ev));
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

struct uinput_touch *uinput_touch_create(int max_x, int max_y)
{
    struct uinput_touch *ut = calloc(1, sizeof(*ut));
    if (!ut)
        return NULL;

    ut->fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ut->fd < 0) {
        log_error("Cannot open /dev/uinput: %s", strerror(errno));
        free(ut);
        return NULL;
    }

    /* Enable event types */
    ioctl(ut->fd, UI_SET_EVBIT, EV_KEY);
    ioctl(ut->fd, UI_SET_EVBIT, EV_ABS);
    ioctl(ut->fd, UI_SET_EVBIT, EV_SYN);

    /* Enable BTN_TOUCH */
    ioctl(ut->fd, UI_SET_KEYBIT, BTN_TOUCH);

    /* Configure ABS_X */
    struct uinput_abs_setup abs_x = {
        .code = ABS_X,
        .absinfo = {
            .minimum = 0,
            .maximum = max_x - 1,
            .fuzz = 0,
            .flat = 0,
        },
    };
    ioctl(ut->fd, UI_ABS_SETUP, &abs_x);

    /* Configure ABS_Y */
    struct uinput_abs_setup abs_y = {
        .code = ABS_Y,
        .absinfo = {
            .minimum = 0,
            .maximum = max_y - 1,
            .fuzz = 0,
            .flat = 0,
        },
    };
    ioctl(ut->fd, UI_ABS_SETUP, &abs_y);

    /* Create the device */
    struct uinput_setup setup = {
        .id = {
            .bustype = BUS_VIRTUAL,
            .vendor  = 0x1234,
            .product = 0x9481,
            .version = 1,
        },
    };
    strncpy(setup.name, "ILI9481 Touch", sizeof(setup.name) - 1);

    if (ioctl(ut->fd, UI_DEV_SETUP, &setup) < 0 ||
        ioctl(ut->fd, UI_DEV_CREATE) < 0) {
        log_error("uinput device creation failed: %s", strerror(errno));
        close(ut->fd);
        free(ut);
        return NULL;
    }

    /* Brief delay for udev to process the new device */
    usleep(100000);

    log_info("uinput touch device created (%dx%d)", max_x, max_y);
    return ut;
}

void uinput_touch_report(struct uinput_touch *ut, int down, int x, int y)
{
    if (!ut)
        return;

    if (down) {
        emit(ut->fd, EV_ABS, ABS_X, x);
        emit(ut->fd, EV_ABS, ABS_Y, y);
        emit(ut->fd, EV_KEY, BTN_TOUCH, 1);
    } else {
        emit(ut->fd, EV_KEY, BTN_TOUCH, 0);
    }

    emit(ut->fd, EV_SYN, SYN_REPORT, 0);
}

void uinput_touch_destroy(struct uinput_touch *ut)
{
    if (!ut)
        return;

    ioctl(ut->fd, UI_DEV_DESTROY);
    close(ut->fd);
    free(ut);
}

#endif /* ENABLE_TOUCH */

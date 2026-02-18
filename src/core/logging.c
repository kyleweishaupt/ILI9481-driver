/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * logging.c — Combined stderr + syslog logging
 */

#include <stdio.h>
#include <stdarg.h>
#include <syslog.h>
#include <string.h>

#include "logging.h"

static int log_opened = 0;

void log_init(const char *ident)
{
    openlog(ident, LOG_PID | LOG_NDELAY, LOG_DAEMON);
    log_opened = 1;
}

void log_close(void)
{
    if (log_opened) {
        closelog();
        log_opened = 0;
    }
}

static void log_msg(int priority, const char *prefix, const char *fmt, va_list ap)
{
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, ap);

    /* Always write to stderr (systemd captures this via journal) */
    fprintf(stderr, "%s: %s\n", prefix, buf);

    /* Also send to syslog if initialised */
    if (log_opened)
        syslog(priority, "%s", buf);
}

void log_info(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_msg(LOG_INFO, "INFO", fmt, ap);
    va_end(ap);
}

void log_warn(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_msg(LOG_WARNING, "WARN", fmt, ap);
    va_end(ap);
}

void log_error(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_msg(LOG_ERR, "ERROR", fmt, ap);
    va_end(ap);
}

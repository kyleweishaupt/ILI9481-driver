/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * logging.h — Logging to stderr and syslog
 */

#ifndef LOGGING_H
#define LOGGING_H

/*
 * log_init() — Open syslog with the given ident string.
 *              Also directs log output to stderr until daemonised.
 */
void log_init(const char *ident);

/*
 * log_close() — Close syslog.
 */
void log_close(void);

/* Log at various severity levels (printf-style format) */
void log_info(const char *fmt, ...)  __attribute__((format(printf, 1, 2)));
void log_warn(const char *fmt, ...)  __attribute__((format(printf, 1, 2)));
void log_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif /* LOGGING_H */

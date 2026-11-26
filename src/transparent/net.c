#define _GNU_SOURCE
#include "tpd.h"
#include "compat.h"
#include "tp_platform.h"

#include <stdio.h>
#include <string.h>

/* Why the last tpd_connect of this thread failed, for the "[fail]" log
 * line: a connection's attempts all run on the thread that handles it. */
static __thread char	g_connect_error[128];

const char	*tpd_connect_error(void)
{
	return (g_connect_error[0] ? g_connect_error : "unknown");
}

/* One try; -2 if the local port/4-tuple was in use (worth retrying
 * with a new socket, which the platform layer gives a new port). */
static int	try_connect(const struct sockaddr *addr, socklen_t addr_len,
	int timeout_ms)
{
	int	fd;
	int	busy;
	int	w;
	int	err;

	fd = (int)socket(addr->sa_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
	{
		snprintf(g_connect_error, sizeof(g_connect_error), "socket: %s",
			compat_sock_strerror());
		return (-1);
	}
	/* an unprepared socket would be intercepted straight back to us */
	if (tpp_prepare_socket(fd, addr->sa_family) != 0)
	{
		snprintf(g_connect_error, sizeof(g_connect_error),
			"no free local port: %s", compat_sock_strerror());
		compat_close(fd);
		return (-1);
	}
	compat_setsockopt_int(fd, IPPROTO_TCP, TCP_NODELAY, 1);
	compat_set_nonblocking(fd, 1);
	if (connect(fd, addr, addr_len) < 0 && !compat_connect_pending())
	{
		busy = compat_addr_in_use();
		snprintf(g_connect_error, sizeof(g_connect_error), "connect: %s",
			compat_sock_strerror());
		compat_close(fd);
		return (busy ? -2 : -1);
	}
	w = compat_wait(fd, POLLOUT, timeout_ms);
	err = (w > 0) ? compat_so_error(fd) : 0;
	if (w <= 0 || err != 0)
	{
		if (w == 0)
			snprintf(g_connect_error, sizeof(g_connect_error),
				"no answer within %d ms", timeout_ms);
		else if (w < 0)
			snprintf(g_connect_error, sizeof(g_connect_error), "wait: %s",
				compat_sock_strerror());
		else
			snprintf(g_connect_error, sizeof(g_connect_error),
				"connect: socket error %d", err);
		compat_close(fd);
		return (-1);
	}
	compat_set_nonblocking(fd, 0);
	return (fd);
}

int	tpd_connect(const struct sockaddr *addr, socklen_t addr_len,
	int timeout_ms)
{
	int	fd;
	int	tries;

	tries = 0;
	do
		fd = try_connect(addr, addr_len, timeout_ms);
	while (fd == -2 && ++tries < 8);
	return (fd < 0 ? -1 : fd);
}

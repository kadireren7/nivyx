/* tpd_connect (src/transparent/net.c): a connection whose local port +
 * remote address 4-tuple is still in TIME_WAIT must be retried from
 * another local port, however the system reports the clash.
 *
 * Windows reports it for a non-blocking connect only later, through
 * SO_ERROR = WSAEADDRINUSE (10048); that path used to end the attempt
 * ("connect-fail - connect: socket error 10048", CI run 45780449466,
 * finding W8) while only a synchronous WSAEADDRINUSE was retried.
 * The test makes the clash on purpose: a connection from local port P
 * to a loopback listener is closed by the client (TIME_WAIT on P), then
 * the engine's connect is made to start from P. */
/* NET_C: CI's control build compiles this test against the code from
 * before the fix, which must fail it on Windows */
#ifndef NET_C
# define NET_C "../../src/transparent/net.c"
#endif
#include NET_C

#include <assert.h>
#include <stdlib.h>
#include <time.h>
#ifdef _WIN32
# include <winsock2.h>
# include <ws2tcpip.h>
#else
# include <arpa/inet.h>
# include <netinet/in.h>
# include <sys/socket.h>
# include <unistd.h>
#endif

#ifdef _WIN32
# define SOCKET_T SOCKET
# define CLOSE_S closesocket
#else
# define SOCKET_T int
# define CLOSE_S close
#endif

static int	g_port0;
static int	g_calls;

/* the platform layer's own-port binding, made deterministic: the first
 * socket gets g_port0, every later one the next port */
int	tpp_prepare_socket(int fd, int family)
{
	struct sockaddr_in	a;
	int					one;

	(void)family;
	one = 1;
#ifndef _WIN32
	/* Linux refuses bind() on a TIME_WAIT port without it (Windows does
	 * not; and there SO_REUSEADDR would mean something else) */
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
#else
	(void)one;
#endif
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)(g_port0 + g_calls));
	g_calls++;
	return (bind((SOCKET_T)fd, (struct sockaddr *)&a, sizeof(a)) == 0 ? 0 : -1);
}


int	main(void)
{
	struct sockaddr_in	srv;
	socklen_t			slen;
	SOCKET_T			l;
	SOCKET_T			c;
	SOCKET_T			s;
	int					fd;
	int					rc;

#ifdef _WIN32
	WSADATA	wsa;

	assert(WSAStartup(MAKEWORD(2, 2), &wsa) == 0);
#endif
	l = socket(AF_INET, SOCK_STREAM, 0);
	memset(&srv, 0, sizeof(srv));
	srv.sin_family = AF_INET;
	srv.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	assert(bind(l, (struct sockaddr *)&srv, sizeof(srv)) == 0);
	assert(listen(l, 8) == 0);
	slen = sizeof(srv);
	assert(getsockname(l, (struct sockaddr *)&srv, &slen) == 0);

	/* a local port in the engines' own-port style, with its 4-tuple to
	 * the listener left in TIME_WAIT by an active close */
	g_port0 = 45000 + (int)((unsigned)time(NULL) % 900);
	g_calls = 0;
	c = socket(AF_INET, SOCK_STREAM, 0);
	assert(tpp_prepare_socket((int)c, AF_INET) == 0);
	assert(connect(c, (struct sockaddr *)&srv, sizeof(srv)) == 0);
	s = accept(l, NULL, NULL);
	CLOSE_S(c);		/* client closes first: TIME_WAIT on g_port0 */
	{
		char	b;

		(void)recv(s, &b, 1, 0);
	}
	CLOSE_S(s);

	/* one attempt from the same port: either refused at once or later
	 * through SO_ERROR - both must count as "in use, retry" (-2), or
	 * the system lets the port be reused (Linux on loopback may) */
	g_calls = 0;
	rc = try_connect((struct sockaddr *)&srv, sizeof(srv), 2000);
	printf("test_connect_retry: same 4-tuple: %s (%s)\n",
		rc >= 0 ? "connected" : rc == -2 ? "in use, retryable" : "failed",
		rc >= 0 ? "port reuse allowed" : tpd_connect_error());
	if (rc >= 0)
		compat_close(rc);
	assert(rc != -1);

	/* the full connect: from the clashing port first, then the next one */
	g_calls = 0;
	fd = tpd_connect((struct sockaddr *)&srv, sizeof(srv), 2000);
	assert(fd >= 0);
	compat_close(fd);
	s = accept(l, NULL, NULL);
	CLOSE_S(s);
	CLOSE_S(l);
	printf("test_connect_retry: OK (%d socket(s) used)\n", g_calls);
	return (0);
}

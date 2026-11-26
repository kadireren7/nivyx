/*
 * Certificate and hostname verification of src/tlsclient.c (the client
 * behind DNS-over-HTTPS and the bypass verifier) against controlled local
 * endpoints. Run by scripts/tls-verify-test.sh, which creates the
 * certificates, starts the servers and points OpenSSL's default trust
 * (SSL_CERT_FILE / SSL_CERT_DIR) at a test CA only.
 *
 *   tlsc_test cases GOOD_PORT EXPIRED_PORT ROGUE_PORT
 *   tlsc_test concurrent GOOD_PORT THREADS ROUNDS
 *   tlsc_test failclosed GOOD_PORT     (built with -Wl,--wrap=..., below)
 *
 * GOOD serves good.test signed by the test CA, EXPIRED the same name with
 * an expired certificate from that CA, ROGUE good.test signed by a CA that
 * is not trusted.
 */
#include "tlsclient.h"
#include "compat.h"
#include "relay.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/opensslv.h>
#include <openssl/ssl.h>

static int	g_failed;

static int	connect_port(int port)
{
	struct sockaddr_in	a;
	int					fd;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return (-1);
	memset(&a, 0, sizeof(a));
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0)
	{
		close(fd);
		return (-1);
	}
	return (fd);
}

/* one handshake; also a request/response round trip when it verified */
static t_tlsc_result	run_one(void *ctx, int port, const char *host,
	int require_valid, int *returned_session)
{
	t_tlsc_result	res;
	t_tlsc			*t;
	int				fd;
	char			buf[256];
	const char		*req = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";

	*returned_session = 0;
	fd = connect_port(port);
	if (fd < 0)
	{
		fprintf(stderr, "cannot connect to 127.0.0.1:%d\n", port);
		return (TLSC_FAILED);
	}
	t = tlsc_handshake(ctx, fd, host, RELAY_SPLIT_NONE,
			compat_now_ms() + 10000, require_valid, &res);
	if (t == NULL)
		return (res);
	*returned_session = 1;
	if (res == TLSC_OK)
	{
		if (tlsc_write(t, req, strlen(req), compat_now_ms() + 10000) != 0
			|| tlsc_read(t, buf, sizeof(buf), compat_now_ms() + 10000) <= 0)
			res = TLSC_FAILED;
	}
	tlsc_free(t);
	return (res);
}

static void	expect(void *ctx, const char *what, int port, const char *host,
	t_tlsc_result want)
{
	t_tlsc_result	got;
	int				session;

	got = run_one(ctx, port, host, 0, &session);
	printf("%-44s -> %-20s %s\n", what, tlsc_result_name(got),
		got == want ? "ok" : "WRONG");
	if (got != want)
		g_failed = 1;
	/* with require_valid, anything but a verified certificate yields no
	 * session at all */
	got = run_one(ctx, port, host, 1, &session);
	if ((want == TLSC_OK) != (session == 1))
	{
		printf("%-44s    require_valid: session %s  WRONG\n", what,
			session ? "returned" : "refused");
		g_failed = 1;
	}
}

typedef struct s_job
{
	void	*ctx;
	int		port;
	int		rounds;
	int		bad;
}	t_job;

static void	*worker(void *arg)
{
	t_job			*j;
	int				i;
	int				session;
	t_tlsc_result	r;

	j = arg;
	for (i = 0; i < j->rounds; i++)
	{
		/* mostly the right name, every third one a wrong name: both the
		 * success and the rejection paths run concurrently */
		if (i % 3 == 2)
			r = run_one(j->ctx, j->port, "other.test", 0, &session);
		else
			r = run_one(j->ctx, j->port, "good.test", 0, &session);
		if (r != (i % 3 == 2 ? TLSC_BAD_CERT : TLSC_OK))
			j->bad++;
	}
	return (NULL);
}

#ifdef TLSC_TEST_WRAP
/* Linked with -Wl,--wrap=<the hostname setter>: setting the expected
 * name fails, as it would on allocation failure. */
# if OPENSSL_VERSION_MAJOR >= 4
int	__real_SSL_set1_dnsname(SSL *s, const char *name);
int	__wrap_SSL_set1_dnsname(SSL *s, const char *name)
{
	(void)s;
	(void)name;
	return (0);
}
# else
int	__real_SSL_set1_host(SSL *s, const char *name);
int	__wrap_SSL_set1_host(SSL *s, const char *name)
{
	(void)s;
	(void)name;
	return (0);
}
# endif
#endif

int	main(int argc, char **argv)
{
	void	*ctx;

	if (argc < 3)
		return (2);
	ctx = tlsc_ctx_new(NULL);
	if (ctx == NULL)
	{
		fprintf(stderr, "tlsc_ctx_new failed\n");
		return (1);
	}
	if (strcmp(argv[1], "cases") == 0 && argc == 5)
	{
		expect(ctx, "trusted CA, right name (good.test)", atoi(argv[2]),
			"good.test", TLSC_OK);
		expect(ctx, "trusted CA, wrong name (other.test)", atoi(argv[2]),
			"other.test", TLSC_BAD_CERT);
		expect(ctx, "trusted CA, name is a suffix (test)", atoi(argv[2]),
			"test", TLSC_BAD_CERT);
		expect(ctx, "trusted CA, expired certificate", atoi(argv[3]),
			"good.test", TLSC_BAD_CERT);
		expect(ctx, "untrusted CA, right name", atoi(argv[4]),
			"good.test", TLSC_BAD_CERT);
	}
	else if (strcmp(argv[1], "failclosed") == 0)
	{
		int				session;
		t_tlsc_result	r;

		r = run_one(ctx, atoi(argv[2]), "good.test", 0, &session);
		printf("%-44s -> %-20s %s\n", "hostname cannot be set (fail closed)",
			tlsc_result_name(r),
			(r == TLSC_FAILED && !session) ? "ok" : "WRONG");
		if (r != TLSC_FAILED || session)
			g_failed = 1;
	}
	else if (strcmp(argv[1], "concurrent") == 0 && argc == 5)
	{
		int			n;
		int			i;
		int			bad;
		pthread_t	th[64];
		t_job		jobs[64];

		n = atoi(argv[3]);
		if (n < 1 || n > 64)
			return (2);
		for (i = 0; i < n; i++)
		{
			jobs[i] = (t_job){ctx, atoi(argv[2]), atoi(argv[4]), 0};
			pthread_create(&th[i], NULL, worker, &jobs[i]);
		}
		bad = 0;
		for (i = 0; i < n; i++)
		{
			pthread_join(th[i], NULL);
			bad += jobs[i].bad;
		}
		printf("concurrent: %d threads x %d handshakes on one SSL_CTX: %d wrong\n",
			n, atoi(argv[4]), bad);
		if (bad)
			g_failed = 1;
	}
	else
		return (2);
	tlsc_ctx_free(ctx);
	return (g_failed);
}

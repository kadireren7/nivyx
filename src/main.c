#include "capabilities.h"
#ifdef HAVE_TRANSPARENT
# include "release_verify.h"
#endif
#include "common.h"
#include "platform.h"
#include "socks.h"
#ifdef HAVE_TRANSPARENT
# include "tp_sys.h"
# ifdef __APPLE__
#  include "tp.h"
# endif
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
# include <windows.h>
#elif defined(__APPLE__)
# include <unistd.h>
#endif

#ifndef DPI_PROXY_VERSION
# define DPI_PROXY_VERSION "0.0.0-dev"
#endif

#ifdef _WIN32
/*
 * dpi-proxy.exe is Nivyx's internal engine: the installed service runs
 * it with --service. Double-clicked in Explorer (no arguments, a console
 * window created just for it), the default SOCKS5 mode would leave a
 * window with one line in it and no visible effect. In that one case
 * explain what to run instead and wait for a key, so the window does not
 * vanish. Started from a terminal, a script or with any option, the
 * behaviour is unchanged.
 */
static int	launched_from_explorer(void)
{
	DWORD	pids[2];
	HWND	win;
	DWORD	mode;

	if (GetConsoleProcessList(pids, 2) != 1)
		return (0);
	win = GetConsoleWindow();
	if (win == NULL || !IsWindowVisible(win))
		return (0);
	return (GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode)
		&& GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode));
}

static int	explain_engine_and_wait(void)
{
	printf("Nivyx %s - internal engine (dpi-proxy.exe)\n"
		"\n"
		"This file is not meant to be opened directly. It is the engine\n"
		"that the Nivyx Windows service runs in the background.\n"
		"\n"
		"  To install Nivyx:  double-click \"Install Nivyx.cmd\"\n"
		"                     in the folder you extracted from the ZIP.\n"
		"  Already installed: open PowerShell and run  nivyx status\n"
		"  To remove it:      double-click \"Uninstall Nivyx.cmd\".\n"
		"\n"
		"Nothing was started or changed.\n"
		"(Advanced: run it from a terminal with options, see --help.)\n"
		"\n"
		"Press Enter to close this window.\n", DPI_PROXY_VERSION);
	fflush(stdout);
	(void)getchar();
	return (2);
}
#endif

static void	print_usage(const char *argv0)
{
	printf("Usage: %s [options]\n"
		"\n"
		"A general-purpose local SOCKS5 proxy. With no options, listens\n"
		"on 127.0.0.1:%d.\n"
		"\n"
		"Options:\n"
		"  --listen HOST:PORT   bind address (default 127.0.0.1:%d)\n"
		"  --mode proxy         SOCKS5 proxy (default)\n"
		"  --mode transparent   Linux / macOS (root), Windows\n"
		"                       (administrator): intercept outgoing\n"
		"                       HTTPS and DNS system-wide (nftables /\n"
		"                       PF / WinDivert) and bypass DPI\n"
		"                       automatically (normally run by the\n"
		"                       installed service)\n"
		"                       — see docs/transparent-mode.md\n"
		"  --service            Windows: run as the \"dpi-proxy\" service\n"
		"  --port PORT          transparent listener port (default %d)\n"
		"  --debug              transparent mode: log every connection\n"
		"  --log-level LEVEL    error|info (default: info) — \"error\"\n"
		"                       suppresses the per-connection \"request:\n"
		"                       host:port\" line\n"
		"  --capabilities       print a platform/capability report and exit\n"
		"  --version            print the version and exit\n"
		"  --help               print this message and exit\n"
		"\n"
		"Example:\n"
		"  %s --listen 127.0.0.1:1081\n",
		argv0, DPI_PROXY_PORT, DPI_PROXY_PORT, 1091, argv0);
}

static void	print_capabilities(void)
{
	int	net_admin;
	int	net_raw;
	int	raw_socket;

	capabilities_probe_linux(&net_admin, &net_raw, &raw_socket);
	printf("platform: %s\n", capabilities_platform());
	printf("proxy_mode: supported\n");
#ifdef HAVE_TRANSPARENT
	printf("transparent_mode: supported (--mode transparent)\n");
#else
	printf("transparent_mode: not built into this binary\n");
#endif
	printf("packet_mode: not built into this binary "
		"(see dpi-proxy-packet, Linux only)\n");
	printf("ipv4: yes\n");
	printf("ipv6: yes (SOCKS5 ATYP 0x04)\n");
	printf("tls_split: yes (DPI_PROXY_SPLIT_TLS=1 or =record in proxy mode; "
		"automatic in transparent mode)\n");
	if (strcmp(capabilities_platform(), "linux") == 0)
	{
		printf("raw_socket: %s (irrelevant to this binary; shown for "
			"reference)\n", raw_socket ? "yes" : "no");
	}
}

static int	parse_listen(const char *arg, char *host_out, size_t host_out_size,
	int *port_out)
{
	const char	*colon;
	size_t		host_len;

	colon = strrchr(arg, ':');
	if (colon == NULL || colon == arg)
		return (-1);

	host_len = (size_t)(colon - arg);
	if (host_len >= host_out_size)
		return (-1);

	memcpy(host_out, arg, host_len);
	host_out[host_len] = '\0';

	*port_out = atoi(colon + 1);
	if (*port_out <= 0 || *port_out > 65535)
		return (-1);

	return (0);
}

int	main(int argc, char **argv)
{
	int		i;
	int		rc;
	const char	*host;
	int			port;
	char		host_buf[256];
	int			transparent;
	int			tp_port;
	int			tp_debug;
	int			tp_service;

	host = NULL;
	port = DPI_PROXY_PORT;
	transparent = 0;
	tp_port = 0;
	tp_debug = 0;
	tp_service = 0;

#if defined(HAVE_TRANSPARENT) && defined(__APPLE__)
	/* internal: the fail-open watchdog the transparent daemon spawns */
	if (argc >= 2 && strcmp(argv[1], "--pf-watchdog") == 0)
		return (tp_pf_watchdog_main(argc >= 3 ? argv[2] : NULL));
	/* the PF anchor the daemon would load (checking: pfctl -nf -) */
	if (argc >= 2 && strcmp(argv[1], "--print-pf-rules") == 0)
	{
		char	rules[8192];
		size_t	len;

		len = tp_pf_ruleset(rules, sizeof(rules), 1091, 1, 1053);
		fwrite(rules, 1, len, stdout);
		return (len > 0 ? 0 : 1);
	}
#endif

#ifdef _WIN32
	if (argc == 1 && launched_from_explorer())
		return (explain_engine_and_wait());
#endif

	i = 1;
	while (i < argc)
	{
		if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
		{
			print_usage(argv[0]);
			return (0);
		}
		else if (strcmp(argv[i], "--version") == 0)
		{
			printf("dpi-proxy %s\n", DPI_PROXY_VERSION);
			return (0);
		}
		else if (strcmp(argv[i], "--capabilities") == 0)
		{
			print_capabilities();
			return (0);
		}
#ifdef HAVE_TRANSPARENT
		/* the updaters' signed-manifest check (docs/release-signing.md) */
		else if (strcmp(argv[i], "--verify-release") == 0 && i + 3 < argc)
			return (release_verify_main(argv[i + 1], argv[i + 2], argv[i + 3]));
#endif
		else if (strcmp(argv[i], "--listen") == 0 && i + 1 < argc)
		{
			i++;
			if (parse_listen(argv[i], host_buf, sizeof(host_buf), &port) < 0)
			{
				fprintf(stderr, "invalid --listen value \"%s\", expected "
					"HOST:PORT (e.g. 127.0.0.1:1081)\n", argv[i]);
				return (1);
			}
			host = host_buf;
		}
		else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc)
		{
			i++;
			if (strcmp(argv[i], "transparent") == 0)
				transparent = 1;
			else if (strcmp(argv[i], "proxy") != 0)
			{
				fprintf(stderr, "unknown --mode \"%s\" (proxy or "
					"transparent; for packet mode see dpi-proxy-packet)\n",
					argv[i]);
				return (1);
			}
		}
		else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
		{
			i++;
			tp_port = atoi(argv[i]);
			if (tp_port <= 0 || tp_port > 65535)
			{
				fprintf(stderr, "invalid --port \"%s\"\n", argv[i]);
				return (1);
			}
		}
		else if (strcmp(argv[i], "--debug") == 0)
			tp_debug = 1;
		else if (strcmp(argv[i], "--service") == 0)
			tp_service = 1;
		else if (strcmp(argv[i], "--log-level") == 0 && i + 1 < argc)
		{
			i++;
			if (strcmp(argv[i], "error") == 0)
				g_socks_verbose = 0;
			else if (strcmp(argv[i], "info") != 0)
			{
				fprintf(stderr, "unknown --log-level \"%s\" (expected "
					"error or info)\n", argv[i]);
				return (1);
			}
		}
		else
		{
			fprintf(stderr, "unknown option: %s (see --help)\n", argv[i]);
			return (1);
		}
		i++;
	}

	if (platform_init() != 0)
	{
		fprintf(stderr, "platform init failed\n");
		return (1);
	}

	if (transparent || tp_service)
	{
#ifdef HAVE_TRANSPARENT
		t_tp_options	opt;

		tp_options_default(&opt);
		if (tp_port != 0)
			opt.port = tp_port;
		if (tp_debug)
			opt.debug = 1;
# ifdef _WIN32
		setvbuf(stderr, NULL, _IONBF, 0);
# else
		setvbuf(stderr, NULL, _IOLBF, 0);
# endif
# ifdef _WIN32
		if (tp_service)
		{
			rc = tp_windows_service_run(&opt);
			if (rc < 0 && GetLastError()
				== ERROR_FAILED_SERVICE_CONTROLLER_CONNECT)
			{
				fprintf(stderr, "--service: this is how the Windows "
					"service manager starts the Nivyx engine; it cannot "
					"be used from a terminal.\nInstall with \"Install "
					"Nivyx.cmd\", then control it with: nivyx status | "
					"start | stop\n");
				platform_cleanup();
				return (ERROR_FAILED_SERVICE_CONTROLLER_CONNECT);
			}
		}
		else
# endif
			rc = run_transparent_server(&opt);
		platform_cleanup();
		return (rc < 0 ? 1 : 0);
#else
		(void)tp_port;
		(void)tp_debug;
		fprintf(stderr, "--mode transparent is not available in this "
			"build (Linux, macOS and Windows only); use the SOCKS5 proxy (the "
			"default mode)\n");
		return (1);
#endif
	}

	printf("dpi-proxy — general-purpose SOCKS5 proxy\n");
#ifdef _WIN32
	if (argc == 1)
		fprintf(stderr, "note: plain SOCKS5 proxy only; this does not "
			"protect the system by itself. For Nivyx's system-wide "
			"mode run \"Install Nivyx.cmd\" (status: nivyx status).\n");
#elif defined(__APPLE__)
	/* opened from Finder, this lands in a Terminal window: say what it is
	 * (the SOCKS5 proxy itself starts as before) */
	if (argc == 1 && isatty(STDERR_FILENO))
		fprintf(stderr, "note: this is Nivyx's internal engine. Without "
			"options it is only a plain SOCKS5 proxy and does not "
			"protect the system.\nTo install Nivyx, double-click "
			"\"Install Nivyx.command\"; if it is installed: nivyx "
			"status. Press Ctrl-C to quit.\n");
#endif

	rc = run_socks_server(host, port);
	if (rc < 0 && host != NULL)
		fprintf(stderr, "note: could not bind %s:%d — if the address is "
			"already in use, another process (or another dpi-proxy) is "
			"probably listening there already\n", host, port);

	platform_cleanup();

	return (rc < 0 ? 1 : 0);
}

#include "release_verify.h"

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RV_MAX_MANIFEST	(1024 * 1024)
#define RV_MAX_SMALL	(64 * 1024)
#define RV_MAX_KEYS		16
#define RV_PUB_LEN		32
#define RV_SIG_LEN		64
#define RV_ID_LEN		16

typedef struct s_rv_key
{
	unsigned char	raw[RV_PUB_LEN];
	char			id[RV_ID_LEN + 1];
}	t_rv_key;

/* Whole file into a NUL-terminated buffer; -1 if unreadable or > max. */
static int	read_file(const char *path, unsigned char **out, size_t *len,
		size_t max)
{
	FILE			*f;
	unsigned char	*buf;
	size_t			n;

	f = fopen(path, "rb");
	if (f == NULL)
		return (-1);
	buf = malloc(max + 2);
	if (buf == NULL)
	{
		fclose(f);
		return (-1);
	}
	n = fread(buf, 1, max + 1, f);
	if (ferror(f) || n > max)
	{
		fclose(f);
		free(buf);
		return (-1);
	}
	fclose(f);
	buf[n] = '\0';
	*out = buf;
	*len = n;
	return (0);
}

/* Strict base64 (no whitespace, padded) of exactly `want` bytes. */
static int	b64_exact(const char *s, unsigned char *out, size_t want)
{
	unsigned char	tmp[RV_SIG_LEN + 3];
	size_t			slen;
	size_t			pad;
	int				n;

	slen = strlen(s);
	if (slen == 0 || slen % 4 != 0 || slen / 4 * 3 > sizeof(tmp))
		return (-1);
	pad = 0;
	if (s[slen - 1] == '=')
		pad++;
	if (slen > 1 && s[slen - 2] == '=')
		pad++;
	n = EVP_DecodeBlock(tmp, (const unsigned char *)s, (int)slen);
	if (n < 0 || (size_t)n < pad || (size_t)n - pad != want)
		return (-1);
	memcpy(out, tmp, want);
	return (0);
}

static void	key_id(const unsigned char *raw, char *id)
{
	unsigned char	md[EVP_MAX_MD_SIZE];
	unsigned int	mdlen;
	int				i;

	mdlen = 0;
	if (EVP_Digest(raw, RV_PUB_LEN, md, &mdlen, EVP_sha256(), NULL) != 1
		|| mdlen < RV_ID_LEN / 2)
	{
		id[0] = '\0';
		return ;
	}
	i = 0;
	while (i < RV_ID_LEN / 2)
	{
		snprintf(id + i * 2, 3, "%02x", md[i]);
		i++;
	}
	id[RV_ID_LEN] = '\0';
}

/* Next line of buf (modified in place), CR/LF stripped; NULL at end. */
static char	*next_line(char **cur)
{
	char	*line;
	char	*nl;
	size_t	len;

	if (*cur == NULL || **cur == '\0')
		return (NULL);
	line = *cur;
	nl = strchr(line, '\n');
	if (nl != NULL)
	{
		*nl = '\0';
		*cur = nl + 1;
	}
	else
		*cur = NULL;
	len = strlen(line);
	if (len > 0 && line[len - 1] == '\r')
		line[len - 1] = '\0';
	return (line);
}

/* Splits a line into at most 3 space/tab separated fields. */
static int	fields(char *line, char **f, int max)
{
	int		n;
	char	*p;

	n = 0;
	p = line;
	while (*p != '\0' && n < max)
	{
		while (*p == ' ' || *p == '\t')
			p++;
		if (*p == '\0')
			break ;
		f[n++] = p;
		while (*p != '\0' && *p != ' ' && *p != '\t')
			p++;
		if (*p != '\0')
			*p++ = '\0';
	}
	return (n);
}

static int	load_keys(char *text, t_rv_key *keys)
{
	char	*cur;
	char	*line;
	char	*f[3];
	int		n;
	int		nk;

	nk = 0;
	cur = text;
	while ((line = next_line(&cur)) != NULL)
	{
		n = fields(line, f, 3);
		if (n == 0 || f[0][0] == '#')
			continue ;
		if (n < 2 || strcmp(f[0], "ed25519") != 0 || nk >= RV_MAX_KEYS
			|| b64_exact(f[1], keys[nk].raw, RV_PUB_LEN) != 0)
		{
			fprintf(stderr, "verify-release: malformed keyring line\n");
			return (-1);
		}
		key_id(keys[nk].raw, keys[nk].id);
		if (keys[nk].id[0] == '\0')
			return (-1);
		nk++;
	}
	return (nk);
}

static int	verify_one(const t_rv_key *key, const unsigned char *sig,
		const unsigned char *msg, size_t len)
{
	EVP_PKEY	*pkey;
	EVP_MD_CTX	*ctx;
	int			ok;

	ok = 0;
	pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, key->raw,
			RV_PUB_LEN);
	ctx = EVP_MD_CTX_new();
	if (pkey != NULL && ctx != NULL
		&& EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, pkey) == 1
		&& EVP_DigestVerify(ctx, sig, RV_SIG_LEN, msg, len) == 1)
		ok = 1;
	EVP_MD_CTX_free(ctx);
	EVP_PKEY_free(pkey);
	return (ok);
}

static int	check_signatures(char *sigtext, const t_rv_key *keys, int nk,
		const unsigned char *msg, size_t len)
{
	char			*cur;
	char			*line;
	char			*f[3];
	unsigned char	sig[RV_SIG_LEN];
	int				i;
	int				seen;

	seen = 0;
	cur = sigtext;
	while ((line = next_line(&cur)) != NULL)
	{
		if (fields(line, f, 3) != 3 || strcmp(f[0], "ed25519") != 0
			|| b64_exact(f[2], sig, RV_SIG_LEN) != 0)
			continue ;
		seen++;
		i = 0;
		while (i < nk)
		{
			if (strcmp(f[1], keys[i].id) == 0 && verify_one(&keys[i], sig,
					msg, len))
			{
				printf("verified: ed25519 key %s\n", keys[i].id);
				return (0);
			}
			i++;
		}
	}
	if (seen == 0)
		fprintf(stderr, "verify-release: no signature in the signature file\n");
	else
		fprintf(stderr, "verify-release: no valid signature by a trusted key\n");
	return (1);
}

int	release_verify_main(const char *keyring, const char *manifest,
		const char *signature)
{
	unsigned char	*ktext;
	unsigned char	*stext;
	unsigned char	*mtext;
	size_t			klen;
	size_t			slen;
	size_t			mlen;
	t_rv_key		keys[RV_MAX_KEYS];
	int				nk;
	int				rc;

	/* nothing from the environment or a configuration file may change
	 * how this check is done (a configuration can load providers) */
	if (OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL) != 1)
		return (2);
	ktext = NULL;
	stext = NULL;
	mtext = NULL;
	if (read_file(keyring, &ktext, &klen, RV_MAX_SMALL) != 0
		|| read_file(signature, &stext, &slen, RV_MAX_SMALL) != 0
		|| read_file(manifest, &mtext, &mlen, RV_MAX_MANIFEST) != 0)
	{
		fprintf(stderr, "verify-release: cannot read an input file\n");
		free(ktext);
		free(stext);
		free(mtext);
		return (2);
	}
	nk = load_keys((char *)ktext, keys);
	if (nk == 0)
		fprintf(stderr, "verify-release: no key in the keyring\n");
	rc = 1;
	if (nk > 0)
		rc = check_signatures((char *)stext, keys, nk, mtext, mlen);
	free(ktext);
	free(stext);
	free(mtext);
	return (rc);
}

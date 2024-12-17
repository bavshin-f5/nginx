#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Aleksei Bavshin
# (C) Nginx, Inc.

# Tests for http ssl module, loading "provider:..." keys.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

plan(skip_all => 'win32') if $^O eq 'MSWin32';

plan(skip_all => 'may not work, leaves coredump')
	unless $ENV{TEST_NGINX_UNSAFE};

my $t = Test::Nginx->new()->has(qw/http proxy http_ssl/)->has_daemon('openssl')
	->has_daemon('softhsm2-util')->has_daemon('pkcs11-tool');

plan(skip_all => 'no OSSL_PROVIDER_load_ex')
	unless $t->has_feature('openssl:3.2.0');

my $libsofthsm2_path;
my @so_paths = (
	'/usr/lib/softhsm',		# Debian-based
	'/usr/local/lib/softhsm',	# FreeBSD
	'/opt/local/lib/softhsm',	# MacPorts
	'/lib64',			# RHEL-based
	split /:/, $ENV{TEST_NGINX_SOFTHSM} || ''
);

for my $so_path (@so_paths) {
	$so_path .= '/libsofthsm2.so';
	if (-e $so_path) {
		$libsofthsm2_path = $so_path;
		last;
	}
};

plan(skip_all => "libsofthsm2.so not found") unless $libsofthsm2_path;

$t->write_file_expand('nginx.conf', <<EOF);

%%TEST_GLOBALS%%

daemon off;

events {
}

env SOFTHSM2_CONF;

ssl_provider default;
ssl_provider pkcs11
             pkcs11-module-path=$libsofthsm2_path
             pkcs11-module-token-pin=file:%%TESTDIR%%/pin.txt
             "pkcs11-module-quirks=no-deinit no-operation-state";

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8081 ssl;
        listen       127.0.0.1:8080;
        server_name  localhost;

        ssl_certificate localhost.crt;
        ssl_certificate_key "store:pkcs11:token=NginxZero;object=nx_key_0";

        location / {
            # index index.html by default
        }

        location /proxy {
            proxy_pass https://127.0.0.1:8081/;
        }

        location /var {
            proxy_pass https://127.0.0.1:8082/;
            proxy_ssl_name localhost;
            proxy_ssl_server_name on;
        }
    }

    server {
        listen       127.0.0.1:8082 ssl;
        server_name  localhost;

        ssl_certificate \$ssl_server_name.crt;
        ssl_certificate_key "store:pkcs11:token=NginxZero;object=nx_key_0";

        location / {
            # index index.html by default
        }
    }
}

EOF

my $d = $t->testdir();

$t->write_file('openssl.conf', <<EOF);
openssl_conf = openssl_def

[openssl_def]
providers = provider_sect

[provider_sect]
default = default_sect
pkcs11 = pkcs11_sect

[default_sect]
activate = 1

[pkcs11_sect]
pkcs11-module-path = $libsofthsm2_path
pkcs11-module-token-pin = file:$d/pin.txt
# https://github.com/latchset/pkcs11-provider/commit/ab6370fd
pkcs11-module-quirks = no-deinit no-operation-state
activate = 1

[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

$t->write_file('pin.txt', '1234');

$t->write_file('softhsm2.conf', <<EOF);
directories.tokendir = $d/tokens/
objectstore.backend = file
EOF

mkdir($d . '/tokens');

$ENV{SOFTHSM2_CONF} = "$d/softhsm2.conf";
$ENV{OPENSSL_CONF} = "$d/openssl.conf";

foreach my $name ('localhost') {
	system('softhsm2-util --init-token --slot 0 --label NginxZero '
		. '--pin 1234 --so-pin 1234 '
		. ">>$d/openssl.out 2>&1");

	system("pkcs11-tool --module=$libsofthsm2_path "
		. '-p 1234 -l -k -d 0 -a nx_key_0 --key-type rsa:2048 '
		. ">>$d/openssl.out 2>&1");

	system('openssl req -x509 -new '
		. "-subj /CN=$name/ -out $d/$name.crt -text "
		. "-key 'pkcs11:token=NginxZero;object=nx_key_0' "
		. ">>$d/openssl.out 2>&1") == 0
		or plan(skip_all => "missing provider");
}

$ENV{OPENSSL_CONF} = undef;

$t->run()->plan(2);

$t->write_file('index.html', '');

###############################################################################

like(http_get('/proxy'), qr/200 OK/, 'ssl provider keys');
like(http_get('/var'), qr/200 OK/, 'ssl_certificate with variable');

###############################################################################

#! /usr/bin/perl

use 5.026;
use strict;
use autodie qw( :all );
use warnings qw( all );
no warnings qw( experimental::smartmatch );
use Data::Dumper::Simple;
$Data::Dumper::Useqq = 1;
$Data::Dumper::Sortkeys = 1;
#$Data::Dumper::Deepcopy = 1;
$| = 1;

use Carp qw(cluck confess);
$SIG{__DIE__} = \&confess;
$SIG{__WARN__} = \&cluck;

use Config::IniFiles;
use IO::Tee;
use Net::DNS;
use NetAddr::IP;
use NetAddr::IP::Util qw(:all);

# network.ini Format:
#

use constant EXTERN => 'EXTERN';
use constant members => 'members';

sub addv4($$)
{
	my ($a, $b) = @_;
	my $aa = unpack "N", $a;
	my $bb = unpack "N", $b;
	my $cc = $aa + $bb;
	my $c = pack "N", $cc;
	#printf "%08x = %08x + %08x\n", $cc, $bb, $aa;
	return $c;
};

sub shiftv4($$)
{
	my ($a, $b) = @_;
	my $aa = unpack "N", $a;
	my $cc = $aa << $b;
	my $c = pack "N", $cc;
	#printf "%08x = %08x + %08x\n", $cc, $b, $aa;
	return $c;
};

my $network = Config::IniFiles->new(-file => "network.ini", -allowcontinue => 1, -nomultiline => 1) or die +Dumper(@Config::IniFiles::errors)." ";

# Rewrite in canonical format
for my $s ($network->Sections) {
	for my $p ($network->Parameters($s)) {
		my @vals = $network->val($s, $p);
		$network->newval($s, $p, map { split } @vals);
	};
};

$network->RewriteConfig;

# Retrieve into a more convenient datastructure
my %network;
my %many;
for my $s ($network->Sections) {
	for my $p ($network->Parameters($s)) {
		my @vals = $network->val($s, $p);
		$network{$s}{$p} = [ @vals ];
		if (2 <= @vals) {
			$many{$p}++;
		};
	};
};

# Build network objects
my %hosts;
for my $h (keys %{$network{hosts}}) {
	$hosts{$h}{num} = $network{hosts}{$h}[0] + 0;
	$hosts{$h}{num4} = inet_aton($hosts{$h}{num});
};
my %subnets;
for my $s (keys %{$network{subnets}}) {
	my $v = $network{subnets}{$s}[0];
	if ($v eq EXTERN) {
		my %vt;
		for my $p (keys %{$network{$s}}) {
			if ($p eq members) {
				$vt{$p} = [ @{$network{$s}{$p}} ];
			}
			else {
				$vt{$p} = $network{$s}{$p}[0];
			};
		};
		$subnets{$s} = { %vt };
	}
	else {
		$subnets{$s}{num} = $v + 0;
		#print Dumper($s,$v);
		my $mems = $network{$s}{+members};
		$subnets{$s}{+members} = [ $mems? @{$mems}: () ];
		$subnets{$s}{num4} = shiftv4(inet_aton($subnets{$s}{num}), 8);
	};
};
my @external_domains = @{$network{domains}{extern}};
my %external_domains = map { ($_ => 1 ) } @external_domains;
my %externally_visible = map { /=/? ( split /=/, $_, 2 ): ( $_ => 0 ) } @{$network{domains}{visible}};
my %pick = map { ( split /=/, $_, 2 ) } @{$network{domains}{pick}};
my $internal_domain = $network{domains}{intern}[0];
my $ipv4base = $network{networks}{ipv4}[0];
my $ipv4base4 = inet_aton($ipv4base);
my $responsible = $network{networks}{admin}[0];
$responsible =~ tr/\@/./;
my @nse = @{$network{networks}{ns_extern}};
my $master = $network{networks}{ns_intern_master}[0];
my $slave = $network{networks}{ns_intern_slave}[0];
my @nsi = ($master, $slave);

my %external_subnets;
for my $s (keys %subnets) {
	my $thisnet;
	if (exists $subnets{$s}{num4}) {
		$thisnet = addv4 $subnets{$s}{num4}, $ipv4base4;
	};
	for my $h (@{$subnets{$s}{+members}}) {
		if (defined $thisnet) {
			$hosts{$h}{net4}{$s} = addv4 $thisnet, $hosts{$h}{num4};
		}
		else {
			$hosts{$h}{net4}{$s} = inet_aton($subnets{$s}{$h}) if exists $subnets{$s}{$h};
			$external_subnets{$s}{$h}++;
		};
	};
};

# print Dumper(%network, %many, %hosts, %subnets, @external_domains, @externally_visible, $internal_domain, $ipv4base);
print Dumper(%network, %hosts, %subnets, @external_domains, %externally_visible, $internal_domain, $ipv4base, $ipv4base4, %external_subnets);

my %output;

sub add_more($$$)
{
	my ($name, $origin, $ext) = @_;
	for my $r (@{$network{more}{records}}) {
		my $data = $network{more}{$r};
		my @data = split /:/, $data->[0];
		if ($ext) {
			@data = map { s/\$/$origin/g; $_ } @data;
		}
		else {
			@data = map { s/\$/$internal_domain/g; $_ } @data;
		};
		#print Dumper($data, @data);
		my $rr = new Net::DNS::RR(join(' ', $name, $r, @data));
		$rr->ttl(60*60*24);
		$output{$origin}{$rr->string}++;
	};
};

my @priv = (
	new NetAddr::IP('10/8'),
	new NetAddr::IP('172.16/12')->split(16),
	new NetAddr::IP('192.168/16'),
	#new NetAddr::IP('127/8'),
);

sub is_priv($) {
	my $ip = shift;
	my $ipo = new NetAddr::IP $ip;
	for my $p (@priv) {
		if ($ipo->within($p)) {
			my $adr = $p->addr;
			my $q = new Net::DNS::Question $adr;
			my $rev = $q->name;
			$rev =~ s/^(0\.)*//;
			return $rev;
		};
	};
	return undef;
};

my %a;

for my $h (sort keys %hosts) {
	for my $s (sort keys %{$hosts{$h}{net4}}) {
		my $ip = inet_ntoa($hosts{$h}{net4}{$s});
		my $rr = new Net::DNS::RR(
			owner	=> "$h.$s.$internal_domain",
			ttl	=> 60*60*24,
			type	=> 'A',
			address	=> $ip,
		);
		$a{$rr->owner} = $rr->address;
		$output{"$internal_domain"}{$rr->string}++;
		add_more "$h.$s.$internal_domain", "$internal_domain", 0;
		my $q = new Net::DNS::Question($ip);
		$rr = new Net::DNS::RR(
			ptrdname	=> "$h.$s.$internal_domain",
			ttl	=> 60*60*24,
			type	=> 'PTR',
			owner	=> $q->name,
		);
		my $rdom = $rr->owner;
		my $prv = is_priv $ip;
		if (defined $prv) {
			#print __LINE__, "\n", Dumper($rr->owner, $prv);
			$output{$prv}{$rr->string}++;
		}
		else {
			# not on our servers
			# $rdom =~ s/^[^.]+\.//;
			# #print __LINE__, "\n", Dumper($rr->owner, $rdom);
			# $output{$rdom}{$rr->string}++;
		};
		#my $nip = NetAddr::IP->new_from_aton($hosts{$h}{net4}{$s});
		#print "RFC 1918: ", $nip->is_rfc1918? "yes": "no", "\n";
		#print Dumper($h, %externally_visible) if not $prv;
		if (not exists $subnets{$s}{num} and not defined $prv and exists $externally_visible{$h}) {
			for my $d (@external_domains) {
				my $rr = new Net::DNS::RR(
					owner	=> "$h.$d",
					ttl	=> 60*60*24,
					type	=> 'A',
					address	=> $ip,
				);
				$a{$rr->owner} = $rr->address;
				$output{$d}{$rr->string}++;
				add_more "$h.$d", $d, 1;
				if (1) {
					my $q = new Net::DNS::Question($ip);
					$rr = new Net::DNS::RR(
						ptrdname	=> "$h.$d",
						ttl	=> 60*60*24,
						type	=> 'PTR',
						owner	=> $q->name,
					);
					my $rdom = $rr->owner;
					my $prv = is_priv $ip;
					if (defined $prv) {
						#print __LINE__, "\n", Dumper($rr->owner, $prv);
						$output{$prv}{$rr->string}++;
					}
					else {
						# not on our servers
						# $rdom =~ s/^[^.]+\.//;
						# #print __LINE__, "\n", Dumper($rr->owner, $rdom);
						# $output{$rdom}{$rr->string}++;
					};
				};
				for my $c (keys %externally_visible) {
					my $t = $externally_visible{$c};
					if ($t) {
						if ($t eq $h) {
							if (0) {
								$rr = new Net::DNS::RR(
									name	=> "$c.$d",
									ttl	=> 60*60*24,
									type	=> 'CNAME',
									cname	=> "$h.$d",
								);
								$a{$rr->owner} = $a{$rr->cname};
								$output{$d}{$rr->string}++;
							};
							$rr = new Net::DNS::RR(
								owner	=> "$c.$d",
								ttl	=> 60*60*24,
								type	=> 'A',
								address	=> $ip,
							);
							$a{$rr->owner} = $rr->address;
							$output{$d}{$rr->string}++;
							add_more "$c.$d", $d, 1;
						};
						#my $x = $t ^ $h;
						#print Dumper($h, $c, $t, $x);
					};
				};
			};
		};
	};
};
for my $p (keys %pick) {
	my $s = $pick{$p};
	if (0) {
		my $rr = new Net::DNS::RR(
			name	=> "$p.$internal_domain",
			ttl	=> 60*60*24,
			type	=> 'CNAME',
			cname	=> "$p.$s.$internal_domain",
		);
		$a{$rr->owner} = $a{$rr->cname};
		$output{$internal_domain}{$rr->string}++;
	};
	my $rr = new Net::DNS::RR(
		owner	=> "$p.$internal_domain",
		ttl	=> 60*60*24,
		type	=> 'A',
		address	=> $a{"$p.$s.$internal_domain"},
	);
	$a{$rr->owner} = $rr->address;
	$output{$internal_domain}{$rr->string}++;
	add_more "$p.$internal_domain", $internal_domain, 1;
};
print Dumper(%output, %a);

sub bind_list(@) {
	my $str = join('; ', sort(@_), '');
	return "{ $str};";
};

my $confm = "$internal_domain-zones.conf";
open CONFMASTER, '>', $confm or die "$confm: $!";
my @files_master = $confm;
my $confs = "$confm.tmp";
open CONFSLAVE, '>', $confs or die "$confs: $!";
my @files_slave = $confs;
my $CONF = IO::Tee->new(\*CONFMASTER, \*CONFSLAVE);

my %own;
for my $a (values %a) {
	$own{$a}++;
};
my @own = map { new NetAddr::IP($_) } keys %own;
my $priv = bind_list @priv, new NetAddr::IP('127/8'), @own;
my $ext = bind_list qw( 0.0.0.0/0 );
print $CONF <<EOF;

acl internal $priv
acl external $ext

EOF
$CONF->flush;
my $res   = Net::DNS::Resolver->new;
$res->debug(1);
for my $z (map { scalar reverse } sort map { scalar reverse } keys %output) {
	my $zone = "$z.zone";
	print "# $zone ";
	open ZONE, '>', $zone or die "$zone: $!";
	push @files_master, $zone;
	print ZONE "; $zone\n";
	my $serial;
	my $reply = $res->query($z.'.', 'SOA');
	if ($reply) {
		foreach my $rr ($reply->answer) {
			$serial = $rr->serial;
			print "serial=$serial\n";
			print "mname=", $rr->mname, "\n";
			print "rname=", $rr->rname, "\n";
		}
	} else {
		my $msg = "query ($z SOA [serial]) failed: " . $res->errorstring . "\nLast answer from " . $res->answerfrom . "\n" . $res->string;
		#$msg =~ tr/\n / /s;
		print $msg, ' ';
	}	
	my $rr = new Net::DNS::RR(
		mname	=> $nse[0],
		rname	=> $responsible,
		serial	=> $serial,
		ttl	=> 60*60*24,
		refresh	=> 60*60*24/2,
		retry	=> 60*60*2,
		expire	=> 60*60*24*28,
		minimum	=> 60*60*24,
		type	=> 'SOA',
		owner	=> $z,
	);
	$rr->serial($rr->serial(YYYYMMDDxx));
	print "new serial=", $rr->serial, "\n";
	#$output{$z}{$rr->string}++;
	print ZONE "\n";
	print ZONE $rr->string, "\n";
	my @z = split /\./, $z;
	my $top = pop @z;
	print Dumper($z, @z, $top, $internal_domain);
	my @ns;
	if ($top eq $internal_domain or $top eq 'arpa') {
		@ns = @nsi;
	}
	else {
		@ns = @nse;
	};
	print Dumper(@ns);
	for my $ns (@ns) {
		my $rr = new Net::DNS::RR(
			nsdname => $ns,
			type    => 'NS',
			owner   => $z,
		);
		#$output{$z}{$rr->string}++;
		print ZONE $rr->string, "\n";
	};
	for my $rr (sort keys %{$output{$z}}) {
		print ZONE $rr, "\n";
	};
	print ZONE "\n";
	close ZONE or die "$zone: $!";
	my @aq = qw( internal );
	push @aq, qw( external ) if $external_domains{$z};
	my $aq = bind_list @aq;
	my $an = bind_list ($a{$slave});
	print Dumper($an);
	print CONFMASTER <<EOF;

zone "$z" {
	type master;
	notify explicit;
	also-notify $an
	file "/etc/bind/$zone";
	allow-query $aq
};

EOF
	my $ns = bind_list ($a{$master});
	my $noti = $external_domains{$z}? 'yes': 'no';
	my @nsa;
	for my $ns (@ns) {
		if (defined $a{$_}) {
			push @nsa, $a{$_};
		}
		else {
			my $r = $res->query($ns.'.', 'A');
			if ($r) {
				foreach my $rr ($r->answer) {
					my $a = $rr->address;
					push @nsa, $a;
				};
			} else {
				my $msg = "query ($ns A [transfer]) failed: " . $res->errorstring . "\nLast answer from " . $res->answerfrom . "\n" . $res->string;
				#$msg =~ tr/\n / /s;
				print $msg, ' ';
			};	
		};
	};
	my $at = bind_list qw( internal ), @nsa;
	print CONFSLAVE <<EOF;

zone "$z" {
	type slave;
	notify $noti;
	masters $ns
	file "slave.$z";
	allow-query $aq
	allow-transfer $at
};

EOF
	print ".\n";
};
for my $s (@{$network{slaves}{zone}}) {
	my $reply = $res->query($s.'.', 'NS');
	my @ns;
	if ($reply) {
		foreach my $rr ($reply->answer) {
			my $n = $rr->nsdname;
			my $r2 = $res->query($n.'.', 'A');
			if ($r2) {
				foreach my $rr2 ($r2->answer) {
					given ($rr2->type) {
						when ('A') {
							my $a = $rr2->address;
							push @ns, $a;
						};
						when ('CNAME') {
							my $r3 = $res->query($rr2->cname.'.', 'A');
							foreach my $rr3 ($r3->answer) {
								given ($rr3->type) {
									when ('A') {
										my $a = $rr3->address;
										push @ns, $a;
									};
									default {
										die "Bad type '$_'";
									}
								};
							};
						};
						default {
							die "Bad type '$_'";
						}
					};
				}
			} else {
				my $msg = "query ($n A [masters]) failed: " . $res->errorstring . "\nLast answer from " . $res->answerfrom . "\n" . $res->string;
				#$msg =~ tr/\n / /s;
				print $msg, ' ';
			}	
		}
	} else {
		my $msg = "query ($s NS [masters]) failed: " . $res->errorstring . "\nLast answer from " . $res->answerfrom . "\n" . $res->string;
		#$msg =~ tr/\n / /s;
		print $msg, ' ';
	}
	my $ns = bind_list @ns;
	print $CONF <<EOF;

zone "$s" {
	type slave;
	notify no;
	masters $ns
	file "slave.$s";
};

EOF
};
for my $p (@priv) {
	my $prv = is_priv $p->addr;
	unless (exists $output{$prv}) {
		my @def = (
			q{type master},
			q{file "/etc/bind/db.empty"},
		);
		my $def = bind_list @def;
		print $CONF <<EOF;
zone "$prv"  $def
EOF
	};
};
$CONF->flush;
close CONFMASTER or die "$confm: $!";
close CONFSLAVE or die "$confs: $!";
#close $CONF or die "Tee: $!";
print "\n";
print "master <- ", join(' ', @files_master), "\n";
if (1) {
	system(qw(cp -av), @files_master, qw(..)) == 0 or die "cp: !=$! ?=$?";
	system(qw(systemctl restart bind9));
	system(qw(systemctl status bind9));
	print "slave <- ", join(' ', @files_slave), "\n";
	system(qw(scp -pr), @files_slave, "$a{$slave}:/etc/bind/");
	system(qw(ssh), $a{$slave}, qw(cmp -s), "/etc/bind/$confs", "/etc/bind/$confm", qw(|| mv -v --backup=numbered), "/etc/bind/$confs", "/etc/bind/$confm");
	system(qw(ssh), $a{$slave}, qw(systemctl restart bind9));
	system(qw(ssh), $a{$slave}, qw(systemctl status bind9));
};
__END__
# khms1.de                IN SOA  ns0.khms.eu. root.khms1.de. (
# 2018012806 ; serial
# 1d         ; refresh
# 3h         ; retry
# 1000h      ; expire
# 1d         ; minimum
# )
# NS      ns0.khms.eu.
# NS      ns1.first-ns.de.
# NS      robotns2.second-ns.de.
# # 
#+++ AAAA
# address
#+++ AFSDB
# hostname
# subtype
#+++ APL
# address
# aplist
# family
# negate
# prefix
# string
#+++ A
# address
#+++ CAA
# critical
# flags
# tag
# value
#+++ CDNSKEY
# algorithm
# key
#+++ CDS
# algorithm
# digest
# digtype
#+++ CERT
# algorithm
# cert
# certbin
# certificate
# certtype
# format
# keytag
# tag
#+++ CNAME
# cname
#+++ CSYNC
# SOAserial
# flags
# immediate
# soaminimum
# soaserial
# typelist
#+++ DHCID
# digest
# digesttype
# identifiertype
#+++ DLV
#+++ DNAME
# dname
# target
#+++ DNSKEY
# algorithm
# flags
# key
# keybin
# keylength
# keytag
# privatekeyname
# protocol
# revoke
# sep
# signame
# zone
#+++ DS
# algorithm
# babble
# create
# digest
# digestbin
# digtype
# keytag
# verify
#+++ EUI48
# address
#+++ EUI64
# address
#+++ GPOS
# altitude
# latitude
# longitude
#+++ HINFO
# cpu
# os
#+++ HIP
# hit
# hitbin
# key
# keybin
# pkalgorithm
# pubkey
# rendezvousservers
# servers
#+++ IPSECKEY
# algorithm
# gatetype
# gateway
# key
# keybin
# precedence
# pubkey
#+++ ISDN
# ISDNaddress
# address
# sa
#+++ KEY
#+++ KX
# exchange
# preference
#+++ L32
# locator32
# preference
#+++ L64
# locator64
# preference
#+++ LOC
# altitude
# hp
# latitude
# latlon
# longitude
# size
# version
# vp
#+++ LP
# FQDN
# fqdn
# preference
# target
#+++ MB
# madname
#+++ MG
# mgmname
#+++ MINFO
# emailbx
# rmailbx
#+++ MR
# newname
#+++ MX
# exchange
# preference
#+++ NAPTR
# flags
# order
# preference
# regexp
# replacement
# service
#+++ NID
# nodeid
# preference
#+++ NSEC3PARAM
# algorithm
# flags
# hashalgo
# iterations
# salt
# saltbin
#+++ NSEC3
# algorithm
# covered
# flags
# hashalgo
# hnxtname
# iterations
# match
# optout
# salt
# saltbin
#+++ NSEC
# nxtdname
# typebm
# typelist
#+++ NS
# nsdname
#+++ NULL
#+++ OPENPGPKEY
# key
# keybin
#+++ OPT
# class
# encode
# flags
# option
# options
# rcode
# size
# string
# ttl
# version
#+++ PTR
# ptrdname
#+++ PX
# map822
# mapx400
# preference
#+++ RP
# mbox
# txtdname
#+++ RRSIG
# algorithm
# create
# keytag
# labels
# orgttl
# sig
# sigbin
# sigex
# sigexpiration
# sigin
# siginception
# signame
# signature
# sigval
# typecovered
# verify
# vrfyerrstr
#+++ RT
# intermediate
# preference
#+++ SIG
# UNITCHECK
# algorithm
# create
# keytag
# labels
# orgttl
# sig
# sigbin
# sigex
# sigexpiration
# sigin
# siginception
# signame
# signature
# sigval
# typecovered
# verify
# vrfyerrstr
#+++ SMIMEA
# babble
# cert
# certbin
# certificate
# matchingtype
# selector
# usage
#+++ SOA
# expire
# minimum
# mname
# refresh
# retry
# rname
# serial
#+++ SPF
# spfdata
# txtdata
#+++ SRV
# port
# priority
# target
# weight
#+++ SSHFP
# algorithm
# babble
# fingerprint
# fp
# fpbin
# fptype
#+++ TKEY
# algorithm
# class
# encode
# error
# expiration
# inception
# key
# mode
# other
#+++ TLSA
# babble
# cert
# certbin
# certificate
# matchingtype
# selector
# usage
#+++ TSIG
# create
# encode
# error
# fudge
# key
# mac
# macbin
# other
# string
# verify
# vrfyerrstr
#+++ TXT
# txtdata
#+++ URI
# priority
# target
# weight
#+++ X25
# PSDNaddress
# address

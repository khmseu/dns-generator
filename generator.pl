#! /usr/bin/perl

=head1 NAME

generator - BIND DNS zone file and configuration generator

=head1 DESCRIPTION

Generates BIND DNS zone files and configuration from network.ini.
Processes host and subnet definitions to create A, AAAA, PTR, CNAME, SOA, and NS records.

=cut

use 5.026;
use strict;
use autodie  qw( :all );
use warnings qw( all );
no warnings qw( experimental::signatures );
no warnings qw( experimental::smartmatch );
use Data::Dumper::Simple;
$Data::Dumper::Useqq    = 1;
$Data::Dumper::Sortkeys = 1;

#$Data::Dumper::Deepcopy = 1;
$| = 1;

use Carp qw(cluck confess);
$SIG{__DIE__}  = \&confess;
$SIG{__WARN__} = \&cluck;

use Config::IniFiles;
use IO::Tee;
use Net::DNS;
use NetAddr::IP;
use NetAddr::IP::Util qw(:all);

# ============================================================================
# Constants and configuration
# ============================================================================

use constant EXTERN  => 'EXTERN';
use constant members => 'members';

# ============================================================================
# IPv4 Utility Functions
# ============================================================================

sub addv4($$) {
    my ( $addr_left, $addr_right ) = @_;
    my $val_left  = unpack "N", $addr_left;
    my $val_right = unpack "N", $addr_right;
    my $sum       = $val_left + $val_right;
    my $result    = pack "N", $sum;

    #printf "%08x = %08x + %08x\n", $sum, $val_right, $val_left;
    return $result;
}

sub shiftv4($$) {
    my ( $addr_value, $shift_bits ) = @_;
    my $val_unpacked = unpack "N", $addr_value;
    my $shifted      = $val_unpacked << $shift_bits;
    my $result       = pack "N", $shifted;

    #printf "%08x = %08x + %08x\n", $shifted, $shift_bits, $val_unpacked;
    return $result;
}

my $network =
  Config::IniFiles->new( -file => "network.ini", -allowcontinue => 1, -nomultiline => 1, -allowedcommentchars => '#' )
  or die +Dumper(@Config::IniFiles::errors) . " ";

# ============================================================================
# Load and parse network.ini configuration
# ============================================================================



# ============================================================================
# Transform configuration into convenient data structures
# ============================================================================

# Parse into nested hash for easier access
my %network;
my %many;
for my $section_name ( $network->Sections ) {
    for my $param_name ( $network->Parameters($section_name) ) {
        my @param_values = $network->val( $section_name, $param_name );
        $network{$section_name}{$param_name} = [@param_values];
        if ( 2 <= @param_values ) {
            $many{$param_name}++;
        }
    }
}

# ============================================================================
# Build network and host objects
# ============================================================================

my %hosts;
for my $hostname ( keys %{ $network{hosts} } ) {
    $hosts{$hostname}{num}  = $network{hosts}{$hostname}[0] + 0;
    $hosts{$hostname}{num4} = inet_aton( $hosts{$hostname}{num} );
}
my %subnets;
for my $subnet_name ( keys %{ $network{subnets} } ) {
    my $subnet_value = $network{subnets}{$subnet_name}[0];
    if ( $subnet_value eq EXTERN ) {
        my %subnet_temp;
        for my $param_name ( keys %{ $network{$subnet_name} } ) {
            if ( $param_name eq members ) {
                $subnet_temp{$param_name} = [ @{ $network{$subnet_name}{$param_name} } ];
            }
            else {
                $subnet_temp{$param_name} = $network{$subnet_name}{$param_name}[0];
            }
        }
        $subnets{$subnet_name} = {%subnet_temp};
    }
    else {
        $subnets{$subnet_name}{num} = $subnet_value + 0;

        #print Dumper($subnet_name,$subnet_value);
        my $members_list = $network{$subnet_name}{ +members };
        $subnets{$subnet_name}{ +members } = [ $members_list ? @{$members_list} : () ];
        $subnets{$subnet_name}{num4} = shiftv4( inet_aton( $subnets{$subnet_name}{num} ), 8 );
    }
}
my @external_domains   = @{ $network{domains}{extern} };
my %external_domains   = map { ( $_ => 1 ) } @external_domains;
my %externally_visible = map { /=/ ? ( split /=/, $_, 2 ) : ( $_ => 0 ) } @{ $network{domains}{visible} };
my %pick               = map { ( split /=/, $_, 2 ) } @{ $network{domains}{pick} };
my $internal_domain    = $network{domains}{intern}[0];
my $ipv4base           = $network{networks}{ipv4}[0];
my $ipv4base4          = inet_aton($ipv4base);
my $responsible        = $network{networks}{admin}[0];
$responsible =~ tr/\@/./;
my @external_nameservers = @{ $network{networks}{ns_extern} };
my $master               = $network{networks}{ns_intern_master}[0];
my $slave                = $network{networks}{ns_intern_slave}[0];
my @internal_nameservers = ( $master, $slave );

my %external_subnets;
for my $subnet_name ( keys %subnets ) {
    my $current_net;
    if ( exists $subnets{$subnet_name}{num4} ) {
        $current_net = addv4 $subnets{$subnet_name}{num4}, $ipv4base4;
    }
    for my $hostname ( @{ $subnets{$subnet_name}{ +members } } ) {
        if ( defined $current_net ) {
            $hosts{$hostname}{net4}{$subnet_name} = addv4 $current_net, $hosts{$hostname}{num4};
        }
        else {
            $hosts{$hostname}{net4}{$subnet_name} = inet_aton( $subnets{$subnet_name}{$hostname} )
              if exists $subnets{$subnet_name}{$hostname};
            $external_subnets{$subnet_name}{$hostname}++;
        }
    }
}

# print Dumper(%network, %many, %hosts, %subnets, @external_domains, @externally_visible, $internal_domain, $ipv4base);
print Dumper(
    %network,         %hosts,    %subnets,   @external_domains, %externally_visible,
    $internal_domain, $ipv4base, $ipv4base4, %external_subnets
);

# ============================================================================
# DNS record generation
# ============================================================================

my %output;    # Hash to store generated DNS records organized by zone

sub add_more($$$) {

    # Add additional DNS records from the 'more' section of config
    # $name: record name, $origin: zone origin, $is_external: external flag
    my ( $name, $origin, $is_external ) = @_;
    for my $record_type ( @{ $network{more}{records} } ) {
        my $record_data = $network{more}{$record_type};
        my @data_fields = split /:/, $record_data->[0];
        if ($is_external) {
            @data_fields = map { my $field = $_; $field =~ s/\$/$origin/g; $field } @data_fields;
        }
        else {
            @data_fields = map { my $field = $_; $field =~ s/\$/$internal_domain/g; $field } @data_fields;
        }

        #print Dumper($record_data, @data_fields);
        my $record_obj = Net::DNS::RR->new( join( ' ', $name, $record_type, @data_fields ) );
        $record_obj->ttl( 60 * 60 * 24 );
        $output{$origin}{ $record_obj->string }++;
    }
}

sub add_zone_records($) {

    # Add zone-level DNS records from the 'zone_records' section of config.
    # Unlike add_more (which stamps a record onto every host), this adds one
    # record per zone at a fixed owner name (zone apex or a named prefix).
    #
    # Format in network.ini:
    #   [zone_records]
    #   records=spf dmarc dkim_sel1
    #   spf=ext|@|TXT|v=spf1 mx -all
    #   dmarc=ext|_dmarc|TXT|v=DMARC1; p=none; rua=mailto:dmarc@$
    #   dkim_sel1=ext|sel1._domainkey|TXT|v=DKIM1; k=rsa; p=MIIB...
    #
    # scope:  ext  => external domains only (@external_domains)
    #         int  => internal domain only  ($internal_domain)
    #         all  => every zone including reverse
    # owner:  @    => zone apex
    #         else => prefix prepended to zone name
    # type:   any DNS record type (TXT, CAA, SSHFP, ...)
    # rdata:  record data; $ expands to the zone name

    my ($zone_name) = @_;
    return unless exists $network{zone_records};
    return unless exists $network{zone_records}{records};

    my $zone_is_external = exists $external_domains{$zone_name};
    my $zone_is_internal = ( $zone_name eq $internal_domain );

    for my $record_key ( @{ $network{zone_records}{records} } ) {
        next unless exists $network{zone_records}{$record_key};

        my ( $scope, $owner_prefix, $rtype, $rdata ) =
          split /\|/, $network{zone_records}{$record_key}[0], 4;

        next if $scope eq 'ext' && !$zone_is_external;
        next if $scope eq 'int' && !$zone_is_internal;

        $rdata =~ s/\$/$zone_name/g;

        my $full_owner = ( $owner_prefix eq '@' ) ? $zone_name : "$owner_prefix.$zone_name";

        my $record_obj =
          ( $rtype eq 'TXT' )
          ? Net::DNS::RR->new(qq{$full_owner $rtype "$rdata"})
          : Net::DNS::RR->new("$full_owner $rtype $rdata");

        $record_obj->ttl( 60 * 60 * 24 );
        $output{$zone_name}{ $record_obj->string }++;
    }
}

my @priv = (
    NetAddr::IP->new('10/8'),
    NetAddr::IP->new('172.16/12')->split(16),
    NetAddr::IP->new('192.168/16'),

    #NetAddr::IP->new('127/8'),
);

sub is_priv($) {
    my $ip_address = shift;
    my $ip_object  = NetAddr::IP->new($ip_address);
    for my $priv_net (@priv) {
        if ( $ip_object->within($priv_net) ) {
            my $net_addr     = $priv_net->addr;
            my $dns_question = Net::DNS::Question->new($net_addr);
            my $reverse_zone = $dns_question->name;
            $reverse_zone =~ s/^(0\.)*//;
            return $reverse_zone;
        }
    }
    return undef;
}

my %addr_map;

for my $hostname ( sort keys %hosts ) {
    for my $subnet_name ( sort keys %{ $hosts{$hostname}{net4} } ) {
        my $ip_address = inet_ntoa( $hosts{$hostname}{net4}{$subnet_name} );
        my $record_obj = Net::DNS::RR->new(
            owner   => "$hostname.$subnet_name.$internal_domain",
            ttl     => 60 * 60 * 24,
            type    => 'A',
            address => $ip_address,
        );
        $addr_map{ $record_obj->owner } = $record_obj->address;
        $output{"$internal_domain"}{ $record_obj->string }++;
        add_more "$hostname.$subnet_name.$internal_domain", "$internal_domain", 0;
        my $dns_question = Net::DNS::Question->new($ip_address);
        $record_obj = Net::DNS::RR->new(
            ptrdname => "$hostname.$subnet_name.$internal_domain",
            ttl      => 60 * 60 * 24,
            type     => 'PTR',
            owner    => $dns_question->name,
        );
        my $reverse_domain = $record_obj->owner;
        my $private_zone   = is_priv $ip_address;

        if ( defined $private_zone ) {

            #print __LINE__, "\n", Dumper($record_obj->owner, $private_zone);
            $output{$private_zone}{ $record_obj->string }++;
        }
        else {
            # not on our servers
            # $rdom =~ s/^[^.]+\.//;
            # #print __LINE__, "\n", Dumper($rr->owner, $rdom);
            # $output{$rdom}{$rr->string}++;
        }

        #my $nip = NetAddr::IP->new_from_aton($hosts{$hostname}{net4}{$subnet_name});
        #print "RFC 1918: ", $nip->is_rfc1918? "yes": "no", "\n";
        #print Dumper($hostname, %externally_visible) if not $private_zone;
        if (    not exists $subnets{$subnet_name}{num}
            and not defined $private_zone
            and exists $externally_visible{$hostname} )
        {
            for my $domain_name (@external_domains) {
                my $record_obj = Net::DNS::RR->new(
                    owner   => "$hostname.$domain_name",
                    ttl     => 60 * 60 * 24,
                    type    => 'A',
                    address => $ip_address,
                );
                $addr_map{ $record_obj->owner } = $record_obj->address;
                $output{$domain_name}{ $record_obj->string }++;
                add_more "$hostname.$domain_name", $domain_name, 1;
                if (1) {
                    my $dns_question = Net::DNS::Question->new($ip_address);
                    $record_obj = Net::DNS::RR->new(
                        ptrdname => "$hostname.$domain_name",
                        ttl      => 60 * 60 * 24,
                        type     => 'PTR',
                        owner    => $dns_question->name,
                    );
                    my $reverse_domain = $record_obj->owner;
                    my $private_zone   = is_priv $ip_address;
                    if ( defined $private_zone ) {

                        #print __LINE__, "\n", Dumper($record_obj->owner, $private_zone);
                        $output{$private_zone}{ $record_obj->string }++;
                    }
                    else {
                        # not on our servers
                        # $reverse_domain =~ s/^[^.]+\.//;
                        # #print __LINE__, "\n", Dumper($record_obj->owner, $reverse_domain);
                        # $output{$reverse_domain}{$record_obj->string}++;
                    }
                }
                for my $alias_name ( keys %externally_visible ) {
                    my $target_host = $externally_visible{$alias_name};
                    if ($target_host) {
                        if ( $target_host eq $hostname ) {
                            if (0) {
                                $record_obj = Net::DNS::RR->new(
                                    name  => "$alias_name.$domain_name",
                                    ttl   => 60 * 60 * 24,
                                    type  => 'CNAME',
                                    cname => "$hostname.$domain_name",
                                );
                                $addr_map{ $record_obj->owner } = $addr_map{ $record_obj->cname };
                                $output{$domain_name}{ $record_obj->string }++;
                            }
                            $record_obj = Net::DNS::RR->new(
                                owner   => "$alias_name.$domain_name",
                                ttl     => 60 * 60 * 24,
                                type    => 'A',
                                address => $ip_address,
                            );
                            $addr_map{ $record_obj->owner } = $record_obj->address;
                            $output{$domain_name}{ $record_obj->string }++;
                            add_more "$alias_name.$domain_name", $domain_name, 1;
                        }

                        #my $x = $target_host ^ $hostname;
                        #print Dumper($hostname, $alias_name, $target_host, $x);
                    }
                }
            }
        }
    }
}
for my $pick_alias ( keys %pick ) {
    my $target_subnet = $pick{$pick_alias};
    if (0) {
        my $record_obj = Net::DNS::RR->new(
            name  => "$pick_alias.$internal_domain",
            ttl   => 60 * 60 * 24,
            type  => 'CNAME',
            cname => "$pick_alias.$target_subnet.$internal_domain",
        );
        $addr_map{ $record_obj->owner } = $addr_map{ $record_obj->cname };
        $output{$internal_domain}{ $record_obj->string }++;
    }
    my $record_obj = Net::DNS::RR->new(
        owner   => "$pick_alias.$internal_domain",
        ttl     => 60 * 60 * 24,
        type    => 'A',
        address => $addr_map{"$pick_alias.$target_subnet.$internal_domain"},
    );
    $addr_map{ $record_obj->owner } = $record_obj->address;
    $output{$internal_domain}{ $record_obj->string }++;
    add_more "$pick_alias.$internal_domain", $internal_domain, 1;
}

# ============================================================================
# Zone-level record generation (SPF, DKIM, DMARC, etc.)
# ============================================================================

for my $zone_name ( keys %output ) {
    add_zone_records $zone_name;
}

print Dumper( %output, %addr_map );

# ============================================================================
# BIND configuration output
# ============================================================================

sub bind_list(@) {

    # Format IP list for BIND ACL syntax
    my $str = join( '; ', sort(@_), '' );
    return "{ $str};";
}

# Create BIND configuration files
my $confm = "$internal_domain-zones.conf";
open my $CONFMASTER, '>', $confm or die "$confm: $!";
my @files_master = $confm;
my $confs        = "$confm.tmp";
open my $CONFSLAVE, '>', $confs or die "$confs: $!";
my @files_slave = $confs;
my $CONF        = IO::Tee->new( $CONFMASTER, $CONFSLAVE );

my %own;
for my $ip_addr ( values %addr_map ) {
    $own{$ip_addr}++;
}
my @own          = map { NetAddr::IP->new($_) } keys %own;
my $private_acl  = bind_list @priv, NetAddr::IP->new('127/8'), @own;
my $external_acl = bind_list qw( 0.0.0.0/0 );
print $CONF <<EOF;

acl internal $private_acl
acl external $external_acl

EOF
$CONF->flush;
my $res = Net::DNS::Resolver->new;
$res->debug(1);

# ============================================================================
# Zone file generation and serial number management
# ============================================================================

for my $zone_name ( map { scalar reverse } sort map { scalar reverse } keys %output ) {
    my $zone_filename = "$zone_name.zone";
    print "# $zone_filename ";
    open my $ZONE, '>', $zone_filename or die "$zone_filename: $!";
    push @files_master, $zone_filename;
    print $ZONE "; $zone_filename\n";

    # Query existing SOA record to preserve and increment serial number
    my $zone_serial;
    my $dns_reply = $res->query( $zone_name . '.', 'SOA' );
    if ($dns_reply) {

        # Extract serial from existing SOA record
        foreach my $record_obj ( $dns_reply->answer ) {
            $zone_serial = $record_obj->serial;
            print "serial=$zone_serial\n";
            print "mname=", $record_obj->mname, "\n";
            print "rname=", $record_obj->rname, "\n";
        }
    }
    else {    # SOA query failed - log the error
        my $msg =
            "query ($zone_name SOA [serial]) failed: "
          . $res->errorstring
          . "\nLast answer from "
          . $res->answerfrom . "\n"
          . $res->string;

        #$msg =~ tr/\n / /s;
        print $msg, ' ';
    }
    my $record_obj = Net::DNS::RR->new(
        mname   => $external_nameservers[0],
        rname   => $responsible,
        serial  => $zone_serial,
        ttl     => 60 * 60 * 24,
        refresh => 60 * 60 * 24 / 2,
        retry   => 60 * 60 * 2,
        expire  => 60 * 60 * 24 * 28,
        minimum => 60 * 60 * 24,
        type    => 'SOA',
        owner   => $zone_name,
    );
    $record_obj->serial( $record_obj->serial(YYYYMMDDxx) );
    print "serial->new=", $record_obj->serial, "\n";

    #$output{$zone_name}{$record_obj->string}++;
    print $ZONE "\n";
    print $ZONE $record_obj->string, "\n";

    # Determine which nameservers to use (internal or external)
    my @zone_parts = split /\./, $zone_name;
    my $zone_tld   = pop @zone_parts;
    print Dumper( $zone_name, @zone_parts, $zone_tld, $internal_domain );
    my @nameserver_list;
    if ( $zone_tld eq $internal_domain or $zone_tld eq 'arpa' ) {

        # Use internal nameservers for internal zones
        @nameserver_list = @internal_nameservers;
    }
    else {
        # Use external nameservers for external zones
        @nameserver_list = @external_nameservers;
    }
    print Dumper(@nameserver_list);
    for my $nameserver (@nameserver_list) {
        my $record_obj = Net::DNS::RR->new(
            nsdname => $nameserver,
            type    => 'NS',
            owner   => $zone_name,
        );

        #$output{$zone_name}{$record_obj->string}++;
        print $ZONE $record_obj->string, "\n";
    }
    for my $record_str ( sort keys %{ $output{$zone_name} } ) {
        print $ZONE $record_str, "\n";
    }
    print $ZONE "\n";
    close $ZONE or die "$zone_filename: $!";

    # Configure zone for both master and slave servers
    my @access_queries = qw( internal );
    push @access_queries, qw( external ) if $external_domains{$zone_name};
    my $access_queries_acl = bind_list @access_queries;
    my $notify_acl         = bind_list( $addr_map{$slave} );
    print Dumper($notify_acl);
    print $CONFMASTER <<EOF;

zone "$zone_name" {
	type master;
	notify explicit;
	also-notify $notify_acl
	file "/etc/bind/$zone_filename";
	allow-query $access_queries_acl
};

EOF
    my $master_acl  = bind_list( $addr_map{$master} );
    my $notify_flag = $external_domains{$zone_name} ? 'yes' : 'no';
    my @nameserver_addresses;

    for my $nameserver (@nameserver_list) {
        if ( defined $addr_map{$_} ) {
            push @nameserver_addresses, $addr_map{$_};
        }
        else {
            my $dns_query_result = $res->query( $nameserver . '.', 'A' );
            if ($dns_query_result) {
                foreach my $record_obj ( $dns_query_result->answer ) {
                    my $ip_addr = $record_obj->address;
                    push @nameserver_addresses, $ip_addr;
                }
            }
            else {
                my $msg =
                    "query ($nameserver A [transfer]) failed: "
                  . $res->errorstring
                  . "\nLast answer from "
                  . $res->answerfrom . "\n"
                  . $res->string;

                #$msg =~ tr/\n / /s;
                print $msg, ' ';
            }
        }
    }
    my $transfer_acl = bind_list qw( internal ), @nameserver_addresses;
    print $CONFSLAVE <<EOF;

zone "$zone_name" {
	type slave;
	notify $notify_flag;
	masters $master_acl
	file "slave.$zone_name";
	allow-query $access_queries_acl
	allow-transfer $transfer_acl
};

EOF
    print ".\n";
}
for my $slave_server ( @{ $network{slaves}{zone} } ) {
    my $dns_reply = $res->query( $slave_server . '.', 'NS' );
    my @ns_addresses;
    if ($dns_reply) {
        foreach my $record_obj ( $dns_reply->answer ) {
            my $ns_name        = $record_obj->nsdname;
            my $a_query_result = $res->query( $ns_name . '.', 'A' );
            if ($a_query_result) {
                foreach my $a_record ( $a_query_result->answer ) {
                    my $record_type = $a_record->type;
                    if ( $record_type eq 'A' ) {
                        my $ip_addr = $a_record->address;
                        push @ns_addresses, $ip_addr;
                    }
                    elsif ( $record_type eq 'CNAME' ) {
                        my $cname_query = $res->query( $a_record->cname . '.', 'A' );
                        foreach my $cname_a_record ( $cname_query->answer ) {
                            my $cname_type = $cname_a_record->type;
                            if ( $cname_type eq 'A' ) {
                                my $ip_addr = $cname_a_record->address;
                                push @ns_addresses, $ip_addr;
                            }
                            else {
                                die "Bad type '$cname_type'";
                            }
                        }
                    }
                    else {
                        die "Bad type '$record_type'";
                    }
                }
            }
            else {
                my $msg =
                    "query ($ns_name A [masters]) failed: "
                  . $res->errorstring
                  . "\nLast answer from "
                  . $res->answerfrom . "\n"
                  . $res->string;

                #$msg =~ tr/\n / /s;
                print $msg, ' ';
            }
        }
    }
    else {
        my $msg =
            "query ($slave_server NS [masters]) failed: "
          . $res->errorstring
          . "\nLast answer from "
          . $res->answerfrom . "\n"
          . $res->string;

        #$msg =~ tr/\n / /s;
        print $msg, ' ';
    }
    my $slave_ns_acl = bind_list @ns_addresses;
    print $CONF <<EOF;

zone "$slave_server" {
	type slave;
	notify no;
	masters $slave_ns_acl
	file "slave.$slave_server";
};

EOF
}
for my $priv_network (@priv) {
    my $private_zone_name = is_priv $priv_network->addr;
    unless ( exists $output{$private_zone_name} ) {
        my @default_zone_def = ( q{type master}, q{file "/etc/bind/db.empty"}, );
        my $default_zone_str = bind_list @default_zone_def;
        print $CONF <<EOF;
zone "$private_zone_name"  $default_zone_str
EOF
    }
}
$CONF->flush;
close $CONFMASTER or die "$confm: $!";
close $CONFSLAVE  or die "$confs: $!";

#close $CONF or die "Tee: $!";
print "\n";
print "master <- ", join( ' ', @files_master ), "\n";
if (1) {
    system( qw(cp -av), @files_master, qw(..) ) == 0 or die "cp: !=$! ?=$?";
    system(qw(systemctl restart bind9));
    system(qw(systemctl status bind9));
    print "slave <- ", join( ' ', @files_slave ), "\n";
    system( qw(scp -pr), @files_slave, "$addr_map{$slave}:/etc/bind/" );
    system( qw(ssh), $addr_map{$slave}, qw(cmp -s), "/etc/bind/$confs", "/etc/bind/$confm",
        qw(|| mv -v --backup=numbered),
        "/etc/bind/$confs", "/etc/bind/$confm" );
    system( qw(ssh), $addr_map{$slave}, qw(systemctl restart bind9) );
    system( qw(ssh), $addr_map{$slave}, qw(systemctl status bind9) );
}
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

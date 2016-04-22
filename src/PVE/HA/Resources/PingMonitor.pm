package PVE::HA::Resources::PingMonitor;

use strict;
use warnings;

use PVE::Network;
use PVE::Tools;
use PVE::JSONSchema;

use base qw(PVE::HA::Resources);

sub type {
    return 'pingmon';
}

sub verify_name {
    my ($class, $name) = @_;

    # TODO allo port configuration
    die "invalid ip '$name'\n" if !PVE::JSONSchema::pve_verify_address($name);
}

sub exists {
    my ($class) = @_;

    return 1;
}
sub options {
    return {
	state => { optional => 1 },
	group => { optional => 1 },
	node => { optional => 1 },
	comment => { optional => 1 },
	monitor => { optional => 0, default => 1 },
    };
}

# a monitor can only run or not
sub check_running {
    my ($class, $haenv, $id) = @_;

    # TODO allow timeout and different port!
    return PVE::Network::tcp_ping($id);
}

1;

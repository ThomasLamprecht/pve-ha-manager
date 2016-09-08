package PVE::HA::Resources::PVECT;

use strict;
use warnings;

use PVE::HA::Tools;

use PVE::LXC;
use PVE::LXC::Config;
use PVE::API2::LXC;
use PVE::API2::LXC::Status;

use base qw(PVE::HA::Resources);

sub type {
    return 'ct';
}

sub verify_name {
    my ($class, $name) = @_;

    die "invalid VMID\n" if $name !~ m/^[1-9][0-9]+$/;
}

sub options {
    return {
	state => { optional => 1 },
	group => { optional => 1 },
	comment => { optional => 1 },
	max_restart => { optional => 1 },
	max_relocate => { optional => 1 },
    };
}

sub config_file {
    my ($class, $vmid, $nodename) = @_;

    return PVE::LXC::Config->config_file($vmid, $nodename);
}

sub exists {
    my ($class, $vmid, $noerr) = @_;

    my $vmlist = PVE::Cluster::get_vmlist();

    if(!defined($vmlist->{ids}->{$vmid})) {
	die "resource 'ct:$vmid' does not exists in cluster\n" if !$noerr;
	return undef;
    } else {
	return 1;
    }
}

sub start {
    my ($class, $haenv, $id) = @_;

    my $nodename = $haenv->nodename();

    my $params = {
	node => $nodename,
	vmid => $id
    };

    my $upid = PVE::API2::LXC::Status->vm_start($params);
    PVE::HA::Tools::upid_wait($upid, $haenv);
}

sub shutdown {
    my ($class, $haenv, $id) = @_;

    my $nodename = $haenv->nodename();
    my $shutdown_timeout = 60; # fixme: make this configurable

    my $params = {
	node => $nodename,
	vmid => $id,
	timeout => $shutdown_timeout,
	forceStop => 1,
    };

    my $upid = PVE::API2::LXC::Status->vm_shutdown($params);
    PVE::HA::Tools::upid_wait($upid, $haenv);
}

sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    my $nodename = $haenv->nodename();

    my $params = {
	node => $nodename,
	vmid => $id,
	target => $target,
	online => 0, # we cannot migrate CT (yet) online, only relocate
    };

    # always relocate container for now
    if ($class->check_running($haenv, $id)) {
	$class->shutdown($haenv, $id);
    }

    my $oldconfig = $class->config_file($id, $nodename);

    my $upid = PVE::API2::LXC->migrate_vm($params);
    PVE::HA::Tools::upid_wait($upid, $haenv);

    # check if vm really moved
    return !(-f $oldconfig);
}

sub check_running {
    my ($class, $haenv, $vmid) = @_;

    return PVE::LXC::check_running($vmid);
}

sub check_service_is_relocatable {
    my ($self, $haenv, $id, $service_node, $nonstrict, $noerr) = @_;

    my $conf = PVE::LXC::Config->load_config($id, $service_node);

    # check for blocking locks, when doing recovery allow safe-to-delete locks
    my $lock = $conf->{lock};
    if ($lock && !($nonstrict && ($lock eq 'backup' || $lock eq 'mounted'))) {
	die "service is locked with lock '$lock'" if !$noerr;
	return undef;
    }

    # TODO: check more (e.g. storage availability)

    return 1;
}

sub remove_locks {
    my ($self, $haenv, $id, $locks, $service_node) = @_;

    $service_node = $service_node || $haenv->nodename();

    my $conf = PVE::LXC::Config->load_config($id, $service_node);

    return undef if !defined($conf->{lock});

    foreach my $lock (@$locks) {
	if ($conf->{lock} eq $lock) {
	    delete $conf->{lock};

	    my $cfspath = PVE::LXC::Config->cfs_config_path($id, $service_node);
	    PVE::Cluster::cfs_write_file($cfspath, $conf);

	    return $lock;
	}
    }

    return undef;
}

1;

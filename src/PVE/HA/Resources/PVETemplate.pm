package PVE::HA::Resources::PVETemplate;

use strict;
use warnings;

use PVE::HA::Tools;

use PVE::Cluster;

use PVE::AbstractConfig;
use PVE::QemuConfig;
use PVE::LXC::Config;

use base qw(PVE::HA::Resources);

sub type {
    return 'template';
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

my $get_template_type = sub {
    my ($vmid, $nodename) = @_;

    my $vmlist = PVE::Cluster::get_vmlist();

    return $vmlist->{ids}->{$vmid}->{type};
};

sub config_file {
    my ($class, $vmid, $nodename) = @_;

    my $type = &$get_template_type($vmid, $nodename);

    if ($type eq 'qemu') {
	return PVE::QemuConfig->config_file($vmid, $nodename);
    } elsif ($type eq 'lxc') {
	return PVE::LXC::Config->config_file($vmid, $nodename);
    } else {
	die "unknown template type '$type'!";
    }
}

sub exists {
    my ($class, $vmid, $noerr) = @_;

    my $vmlist = PVE::Cluster::get_vmlist();

    if(!defined($vmlist->{ids}->{$vmid})) {
	die "resource 'template:$vmid' does not exists in cluster\n" if !$noerr;
	return undef;
    } else {
	return 1;
    }
}

sub start {
    my ($class, $haenv, $id) = @_;
    # do nothing, templates cannot start
}

sub shutdown {
    my ($class, $haenv, $id) = @_;
    # do nothing, templates cannot start
}

sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    my $nodename = $haenv->nodename();

    my $params = {
	node => $nodename,
	vmid => $id,
	target => $target,
	online => 0, # templates are never online.
    };

    my $oldconfig = $class->config_file($id, $nodename);

    my $upid;

    my $type = &$get_template_type($id, $nodename);
    if ($type eq 'qemu') {
	$upid = PVE::API2::Qemu->migrate_vm($params);
    } elsif ($type eq 'lxc') {
	$upid = PVE::API2::LXC->migrate_vm($params);
    } else {
	die "unknown template type '$type'!";
    }

    PVE::HA::Tools::upid_wait($upid, $haenv);

    # check if vm really moved
    return !(-f $oldconfig);
}

sub check_running {
    my ($class, $haenv, $id) = @_;

    my $conf = $haenv->read_service_config();

    # always tell the lrm what he wants to hear as template cannot be started
    if ($conf->{"template:$id"}->{state} eq 'enabled') {
	return 1;
    } else {
	return 0;
    }
}

sub remove_locks {
    my ($self, $haenv, $id, $locks, $service_node) = @_;

    return undef;
}

1;

package PVE::HA::Sim::Resources;

use strict;
use warnings;

use base qw(PVE::HA::Resources);

# provides some base methods for virtual resources (used in simulation/testing).
# reduces code reuse and it's targeted for the main PVE service types, namely
# virtual machines (VM) and container (CT)

sub verify_name {
    my ($class, $id) = @_;

    die "invalid VMID '$id'\n" if $id !~ m/^[1-9][0-9]+$/;
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
    my ($class, $id, $nodename) = @_;

    my $service_type = $class->type();

    # virtual path
    return "$nodename/$service_type:$id";
}

sub start {
    my ($class, $haenv, $id) = @_;

    my $sid = $class->type() . ":$id";
    my $nodename = $haenv->nodename();
    my $hardware = $haenv->hardware();
    my $ss = $hardware->read_service_status($nodename);

    if (my $lock = $hardware->service_has_lock($sid)) {
	$haenv->log('err', "service '$sid' locked ($lock), unable to start!");
	return;
    }

    $haenv->sleep(2);

    $ss->{$sid} = 1;

    $hardware->write_service_status($nodename, $ss);

}

sub shutdown {
    my ($class, $haenv, $id) = @_;

    my $sid = $class->type() . ":$id";
    my $nodename = $haenv->nodename();
    my $hardware = $haenv->hardware();
    my $ss = $hardware->read_service_status($nodename);

    if (my $lock = $hardware->service_has_lock($sid)) {
	$haenv->log('err', "service '$sid' locked ($lock), unable to shutdown!");
	return;
    }

    $haenv->sleep(2);

    $ss->{$sid} = 0;

    $hardware->write_service_status($nodename, $ss);
}

sub check_running {
    my ($class, $haenv, $id) = @_;

    my $service_type = $class->type();
    my $nodename = $haenv->nodename();
    my $hardware = $haenv->hardware();

    my $ss = $hardware->read_service_status($nodename);

    return ($ss->{"$service_type:$id"}) ? 1 : 0;
}


sub migrate {
    my ($class, $haenv, $id, $target, $online) = @_;

    my $sid = $class->type() . ":$id";
    my $nodename = $haenv->nodename();
    my $hardware = $haenv->hardware();
    my $ss = $hardware->read_service_status($nodename);

    my $cmd = $online ? "migrate" : "relocate";
    $haenv->log("info", "service $sid - start $cmd to node '$target'");

    if (my $lock = $hardware->service_has_lock($sid)) {
	$haenv->log('err', "service '$sid' locked ($lock), unable to $cmd!");
	return;
    }

    # explicitly shutdown if $online isn't true (relocate)
    if (!$online && $class->check_running($haenv, $id)) {
	$haenv->log("info", "stopping service $sid (relocate)");
	$class->shutdown($haenv, $id);
	$haenv->log("info", "service status $sid stopped");
    } else {
	$haenv->sleep(2); # (live) migration time
    }

    $hardware->change_service_location($sid, $nodename, $target);
    $haenv->log("info", "service $sid - end $cmd to node '$target'");
    # ensure that the old node doesn't has the service anymore
    delete $ss->{$sid};
    $hardware->write_service_status($nodename, $ss);

    # check if resource really moved
    return defined($ss->{$sid}) ? 0 : 1;
}

sub check_service_is_relocatable {
    my ($self, $haenv, $id, $service_node, $nonstrict, $noerr) = @_;

    my $sid = $self->type() . ":$id";
    my $hardware = $haenv->hardware();

    my $conf = $hardware->read_service_config();

    # check for blocking locks, when doing recovery allow safe-to-delete locks
    my $lock = $conf->{$sid}->{lock};
    if ($lock && !($nonstrict && ($lock eq 'backup' || $lock eq 'mounted'))) {
	die "service is locked with lock '$lock'\n" if !$noerr;
	return undef;
    }

    return 1;
}

sub remove_locks {
    my ($self, $haenv, $id, $locks, $service_node) = @_;

    my $sid = $self->type() . ":$id";
    my $hardware = $haenv->hardware();

    foreach my $lock (@$locks) {
	if (my $removed_lock = $hardware->unlock_service($sid, $lock)) {
	    return $removed_lock;
	}
    }

    return undef;
}

1;

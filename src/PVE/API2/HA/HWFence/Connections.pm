package PVE::API2::HA::HWFence::Connections;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster;
use PVE::HA::Config;
use PVE::HA::FenceConfig;
use PVE::HA::Fence;
use HTTP::Status qw(:constants);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use Data::Dumper;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    permissions => { user => 'all' },
    description => "Directory index.",
    parameters => {
	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{name}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $result = [
	    { name => 'list' },
	    { name => 'verify' },
	    { name => 'update' },
	    #{ name => 'fence' }, # manual fence
	    ];

	return $result;
    }});

__PACKAGE__->register_method ({
    name => 'list',
    path => '{node}',
    method => 'GET',
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    description => "List configured fence devices.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    connections => {
		description => "List also the node => device connections configured",
		type => 'boolean',
		default => 1,
		optional => 1,
	    },
	    verbose => {
		description => "Print all available infos not only device, agent, node",
		type => 'boolean',
		default => 0,
		optional => 1,
	    },
	},
    },
    returns => { type => 'array' },
    code => sub {
	my ($param) = @_;

	$param->{connections} = 1 if !defined($param->{connections});

	my $cfg = PVE::HA::Config::read_fence_config();

	my $res = [];

	foreach my $dev_name (sort keys %$cfg) {
	my $d = $cfg->{$dev_name}->{sub_devs};

	foreach my $sub_dev_nr (sort keys %$d) { # {$a <=> $b}
	    my $sub_dev = $d->{$sub_dev_nr};
	    my $dev_arg_str = join (' ', @{$sub_dev->{args}});

	    my $device = {
		id => "$dev_name:$sub_dev_nr",
		agent => $sub_dev->{agent},
		args => '',
		connections => [],
	    };
	    $device->{args} = $dev_arg_str if $param->{verbose};

	    if ($param->{connections}) {
		foreach my $node (sort keys %{$sub_dev->{node_args}}) {
		    my $node_arg_str = join (' ', @{$sub_dev->{node_args}->{$node}});

		    my $connection = {
			node => $node,
			args => '',
		    };

		    $connection->{args} = $node_arg_str if $param->{verbose};

		    push @{$device->{connections}}, $connection;
		}
	    }

	    push @$res, $device;
	}
    }
	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    permissions => {
	check => ['perm', '/', [ 'Sys.Console' ]],
    },
    description => "Create a new HA resource.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node',
				       { completion => \&PVE::Cluster::get_nodelist }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	# create /etc/pve/ha directory
	PVE::Cluster::check_cfs_quorum();
	mkdir("/etc/pve/ha");

	my ($sid, $type, $name) = PVE::HA::Tools::parse_sid(extract_param($param, 'sid'));

	if (my $param_type = extract_param($param, 'type')) {
	    # useless, but do it anyway
	    die "types does not match\n" if $param_type ne $type;
	}


	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '',
    method => 'PUT',
    description => "Update resource configuration.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Console' ]],
    },
	parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node',
				       { completion => \&PVE::Cluster::get_nodelist }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');

	my ($sid, $type, $name) = PVE::HA::Tools::parse_sid(extract_param($param, 'sid'));

	if (my $param_type = extract_param($param, 'type')) {
	    # useless, but do it anyway
	    die "types does not match\n" if $param_type ne $type;
	}

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '',
    method => 'DELETE',
    description => "Delete resource configuration.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Console' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    sid => get_standard_option('pve-ha-resource-or-vm-id',
				      { completion => \&PVE::HA::Tools::complete_sid }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	return undef;
    }});

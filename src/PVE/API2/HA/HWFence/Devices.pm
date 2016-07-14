package PVE::API2::HA::HWFence::Devices;

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

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);


__PACKAGE__->register_method ({
    name => 'index',
    path => '',
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
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { dev_id => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{dev_id}" } ],
    },
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
		dev_id => "$dev_name:$sub_dev_nr",
		agent => $sub_dev->{agent},
	    };
	    $device->{args} = $dev_arg_str if $param->{verbose};

	    if ($param->{connections}) {
		$device->{connections} = [];

		foreach my $node (sort keys %{$sub_dev->{node_args}}) {
		    my $node_arg_str = join (' ', @{$sub_dev->{node_args}->{$node}});

		    my $connection = {
			node => $node,
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
    description => "Create a new HA fence device.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    dev_id => get_standard_option('pve-ha-fence-device-id'),
	    priority => {
		description => 'The relative priority against other fence devices.' .
		  'Optional if this is a sub devices of parallel devices.',
		type => 'integer',
		optional => 1,
	    },
	    agent => {
		description => 'The fence agent to use for this devices.',
		type => 'string',
		pattern => '\S+',
		typetext => '<non-whitespace>+',
	    },
	    args => get_standard_option('pve-ha-fence-agent-arg-list', {optional => 1}),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::HA::Config::read_fence_config();

	my ($dev_name, $dev_number, $dev_id) = PVE::HA::FenceConfig::parse_dev_id($param->{dev_id});

	die "device '$dev_id' already registered\n"
	  if $cfg->{$dev_name}->{sub_devs}->{$dev_number};

	my $priority = $param->{priority};

	die "Priority is not optional if not already set in parent device!\n"
	  if !defined($priority) && !defined($cfg->{$dev_name}->{priority});

	$cfg->{$dev_name}->{priority} = $priority if defined($priority);

	$cfg->{$dev_name}->{sub_devs}->{$dev_number}->{args} = PVE::Tools::split_list($param->{args}) || [];
	$cfg->{$dev_name}->{sub_devs}->{$dev_number}->{agent} = $param->{agent};

	PVE::HA::Config::write_fence_config($cfg);

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{dev_id}',
    method => 'GET',
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    description => "Read resource configuration.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    dev_id => get_standard_option('pve-ha-fence-device-id'),
	},
    },
    returns => {},
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::HA::Config::read_fence_config();

	my ($dev_name, $dev_number) = PVE::HA::FenceConfig::parse_dev_id($param->{dev_id});

	my $d = $cfg->{$dev_name}->{sub_devs}; # TODO

	return $d;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{dev_id}',
    method => 'PUT',
    description => "Update resource configuration.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Console' ]],
    },
	parameters => {
	additionalProperties => 0,
	properties => {
	    dev_id => get_standard_option('pve-ha-fence-device-id'),
	    delete => {
		type => 'string', format => 'pve-configid-list',
		description => "A list of settings you want to delete.",
		maxLength => 4096,
		optional => 1,
	    }
	    digest => get_standard_option('pve-config-digest');
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');

	my $cfg = PVE::HA::Config::read_fence_config();


	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{dev_id}',
    method => 'DELETE',
    description => "Delete fence device configuration. Automatically deletes all its connections!",
    permissions => {
	check => ['perm', '/', [ 'Sys.Console' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    dev_id => get_standard_option('pve-ha-fence-device-id'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::HA::Config::read_fence_config();

	my ($dev_name, $dev_number) = PVE::HA::FenceConfig::parse_dev_id($param->{dev_id});

	delete $cfg->{$dev_name}->{sub_devs}->{$dev_number};

	if (!scalar(%{$cfg->{$dev_name}->{sub_devs}})) {
	    delete $cfg->{$dev_name};
	}

	PVE::HA::Config::write_fence_config($cfg);
	return undef;
    }});

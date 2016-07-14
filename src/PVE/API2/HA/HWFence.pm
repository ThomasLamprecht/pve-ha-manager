package PVE::API2::HA::HWFence;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use HTTP::Status qw(:constants);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::API2::HA::HWFence::Status;
use PVE::API2::HA::HWFence::Devices;
use PVE::API2::HA::HWFence::Connections;

use Data::Dumper;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    subclass => "PVE::API2::HA::HWFence::Status",
    path => 'status',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::HA::HWFence::Devices",
    path => 'devices',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::HA::HWFence::Connections",
    path => 'connections',
});

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => {
	check => ['perm', '/', [ 'Sys.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		id => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{id}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $res = [
	    { id => 'status' },
	    { id => 'devices' },
	    { id => 'connections' }
	];

	return $res;
    }});

1;

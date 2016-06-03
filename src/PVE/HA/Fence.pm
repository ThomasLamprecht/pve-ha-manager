package PVE::HA::Fence;

use strict;
use warnings;

use POSIX qw( WNOHANG );

use PVE::HA::FenceConfig;

sub new {
    my ($this, $haenv) = @_;

    my $class = ref($this) || $this;

    my $self = bless {
	haenv => $haenv,
	workers => {}, # pid's and additional info of fence processes
	results => {}, # fence state of a node
    }, $class;

    return $self;
}


# picks up/checks children and processes exit status
my $check_jobs = sub {
    my ($self) = @_;

    my $haenv = $self->{haenv};
    my $workers = $self->{workers};

    my $succeeded = {};
    my $failed = {};

    my @finished = ();

    if ($haenv->get_max_workers() > 0) {
	# pick up all finished children if we can fork
	foreach my $pid (keys %$workers) {

	    my $waitpid = waitpid($pid, WNOHANG);
	    if (defined($waitpid) && ($waitpid == $pid)) {
		$workers->{$waitpid}->{ec} = $?;
		push @finished, $waitpid;
	    }

	}
    } else {
	# all jobs are already finished when not forking (test framework)
	@finished = keys %$workers;
    }

    foreach my $res (@finished) {
	my $job = $workers->{$res};
	my $node = $job->{node};

	my $status = {
	    exit_code => $job->{ec},
	    cmd => $job->{cmd},
	};

	if ($job->{ec} == 0) {
	    # succeeded jobs doesn't need the status for now
	    $succeeded->{$node} = $succeeded->{$node} || 0;
	    $succeeded->{$node} ++;
	} else {
	    # with parallel device multiple may fail at once, store all
	    if (defined($failed->{$node})) {
		push @{$failed->{$node}->{jobs}}, $status;
	    } else {
		$failed->{$node}->{try} = $job->{try};
		$failed->{$node}->{jobs} = [ $status ];
	    }
	}

	delete $workers->{$res};
    }

    return ($succeeded, $failed);
};

# pick up jobs and process them
my $process_fencing = sub {
    my ($self) = @_;

    my $haenv = $self->{haenv};
    my $results = $self->{results};

    my $fence_cfg = $haenv->read_fence_config();

    my ($succeeded, $failed) = &$check_jobs($self);

    foreach my $node (keys %$succeeded) {
	# count how many fence devices succeeded
	$results->{$node}->{triggered} += $succeeded->{$node};
    }

    # try next device for failed jobs
    foreach my $node (keys %$failed) {
	my @failed_jobs = @{$failed->{$node}->{jobs}};
	my $try = $failed->{$node}->{try};

	foreach my $job (@failed_jobs) {
	    $haenv->log('err', "fence job failed: '$job->{cmd}' returned " .
			"'$job->{exit_code}'");
	}

	# check if any devices are left to try
	while ($try < PVE::HA::FenceConfig::count_devices($node, $fence_cfg)) {
	    # clean up the other parallel jobs, if any, as at least one failed
	    kill_and_cleanup_jobs($haenv, $node);

	    $try++; # try next available device
	    return if start_fencing($node, $try);

	    $haenv->log('warn', "couldn't start fence try '$try'");
	}

	$results->{$node}->{failure} = 1;
	$haenv->log('err', "tried all fence devices for node '$node'");
    }
};

sub has_fencing_job {
    my ($self, $node) = @_;

    my $workers = $self->{workers};

    foreach my $job (values %$workers) {
	return 1 if ($job->{node} eq $node);
    }
    return undef;
}

my $virtual_pid = 0; # hack for test framework

sub run_fence_jobs {
    my ($self, $node, $try) = @_;

    my $haenv = $self->{haenv};
    my $workers = $self->{workers};
    my $results = $self->{results};

    if (!$self->has_fencing_job($node)) {
	# start new fencing job(s)
	$try = 0 if !defined($try) || ($try < 0);

	my $fence_cfg = $haenv->read_fence_config();
	my $commands = PVE::HA::FenceConfig::get_commands($node, $try, $fence_cfg);

	if (!$commands) {
	    $haenv->log('err', "no fence commands for node '$node'");
	    $results->{$node}->{failure} = 1;
	    return 0;
	}

	$haenv->log('notice', "Start fencing node '$node'");

	my $can_fork = ($haenv->get_max_workers() > 0) ? 1 : 0;

	# when parallel devices are configured all must succeed
	$results->{$node}->{needed} = scalar(@$commands);
	$results->{$node}->{triggered} = 0;

	for my $cmd (@$commands) {
	    my $cmd_str = "$cmd->{agent} " .
		PVE::HA::FenceConfig::gen_arg_str(@{$cmd->{param}});
	    $haenv->log('notice', "[fence '$node'] execute cmd: $cmd_str");

	    if ($can_fork) {

		my $pid = fork();
		if (!defined($pid)) {
		    $haenv->log('err', "forking fence job failed");
		    return 0;
		} elsif ($pid == 0) {
		    $haenv->after_fork(); # cleanup child

		    $haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		    exit(-1);
		} else {

		    $workers->{$pid} = {
			cmd => $cmd_str,
			node => $node,
			try => $try
		    };

		}

	    } else {
		# for test framework
		my $res = -1;
		eval {
		    $res = $haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		    $res = $res << 8 if $res > 0;
		};
		if (my $err = $@) {
		    $haenv->log('err', $err);
		}

		$virtual_pid++;
		$workers->{$virtual_pid} = {
		    cmd => $cmd_str,
		    node => $node,
		    try => $try,
		    ec => $res,
		};

	    }
	}

	return 1;

    } else {
	# check already deployed fence jobs
	&$process_fencing($self);
    }
}

# if $node is undef we kill and cleanup *all* jobs from all nodes
sub kill_and_cleanup_jobs {
    my ($self, $node) = @_;

    my $haenv = $self->{haenv};
    my $workers = $self->{workers};
    my $results = $self->{results};

    while (my ($pid, $job) = each %$workers) {
	next if defined($node) && $job->{node} ne $node;

	if ($haenv->max_workers() > 0) {
	    kill KILL => $pid;
	    waitpid($pid, 0);
	}
	delete $workers->{$pid};
    }

    if (defined($node) && $results->{$node}) {
	delete $results->{$node};
    } else {
	$self->{results} = {};
	$self->{workers} = {};
    }
};

sub is_node_fenced {
    my ($self, $node) = @_;

    my $state = $self->{results}->{$node};
    return 0 if !$state;

    return -1 if $state->{failure} && $state->{failure} == 1;

    return ($state->{needed} && $state->{triggered} &&
	    $state->{triggered} >= $state->{needed}) ? 1 : 0;
}

1;

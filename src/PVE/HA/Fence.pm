package PVE::HA::Fence;

use strict;
use warnings;
use POSIX qw( WNOHANG );
use PVE::HA::FenceConfig;
use Data::Dumper;

# pid's and additional info of fence processes
my $fence_jobs = {};

# fence state of a node
my $fenced_nodes = {};

# picks up/checks children and processes exit status
my $check_jobs = sub {
    my ($haenv) = @_;

    my $succeeded = {};
    my $failed = {};

    my @finished = ();

    if ($haenv->get_max_workers() > 0) {
	# pick up all finished children if we can fork
	foreach my $pid (keys %$fence_jobs) {

	    my $waitpid = waitpid($pid, WNOHANG);
	    if (defined($waitpid) && ($waitpid == $pid)) {
		$fence_jobs->{$waitpid}->{ec} = $? if $fence_jobs->{$waitpid};
		push @finished, $waitpid;
	    }

	}
    } else {
	# else all jobs are already finished
	@finished = keys %$fence_jobs;
    }

    foreach my $res (@finished) {
	my $job = $fence_jobs->{$res};
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
	    # failed jobs per node have the same try value, store only one
	    if (defined($failed->{$node})) {
		push @{$failed->{$node}->{jobs}}, $status;
	    } else {
		$failed->{$node}->{try} = $job->{try};
		$failed->{$node}->{jobs} = [ $status ];
	    }
	}

	delete $fence_jobs->{$res};
    }

    return ($succeeded, $failed);
};

# pick up jobs and process them
my $process_fencing = sub {
    my ($haenv) = @_;

    my $fence_cfg = $haenv->read_fence_config();

    my ($succeeded, $failed) = &$check_jobs($haenv);

    foreach my $node (keys %$succeeded) {
	# count how many fence devices succeeded
	$fenced_nodes->{$node}->{triggered} += $succeeded->{$node};
    }

    # notify admin for failed jobs
    my $email_text = '';

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

	$haenv->log('err', "tried all fence devices for node '$node'");
    }
};

sub has_fencing_job {
    my ($node) = @_;

    foreach my $job (values %$fence_jobs) {
	return 1 if ($job->{node} eq $node);
    }
    return undef;
}

my $virtual_pid = 0; # hack for test framework

sub run_fence_jobs {
    my ($haenv, $node, $try) = @_;

    if (defined($node) && !has_fencing_job($node)) {
	# start new fencing job(s)
	$try = 0 if !defined($try) || ($try < 0);

	my $fence_cfg = $haenv->read_fence_config();
	my $commands = PVE::HA::FenceConfig::get_commands($node, $try, $fence_cfg);

	if (!$commands) {
	    $haenv->log('err', "no fence commands for node '$node'");
	    $fenced_nodes->{$node}->{failure} = 1;
	    return 0;
	}

	$haenv->log('notice', "Start fencing node '$node'");

	my $can_fork = ($haenv->get_max_workers() > 0) ? 1 : 0;

	# when parallel devices are configured all must succeed
	$fenced_nodes->{$node}->{needed} = scalar(@$commands);
	$fenced_nodes->{$node}->{triggered} = 0;

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

		    $fence_jobs->{$pid} = {
			cmd => $cmd_str,
			node => $node,
			try => $try
		    };

		}
	    } else { # for test framework
		my $res = -1;
		eval {
		    $res = $haenv->exec_fence_agent($cmd->{agent}, $node, @{$cmd->{param}});
		    $res = $res << 8 if $res > 0;
		};
		if (my $err = $@) {
		    $haenv->log('err', $err);
		}

		$virtual_pid++;
		$fence_jobs->{$virtual_pid} = {
		    cmd => $cmd_str,
		    node => $node,
		    try => $try,
		    ec => $res,
		};
	    }
	}

	return 1;

    } else {
	# node has already fence jobs deployed, collect finished jobs
	# and check their result
	&$process_fencing($haenv);

    }
}

# if $node is undef we kill and cleanup *all* jobs from all nodes
sub kill_and_cleanup_jobs {
    my ($haenv, $node) = @_;

    while (my ($pid, $job) = each %$fence_jobs) {
	next if defined($node) && $job->{node} ne $node;

	if ($haenv->max_workers() > 0) {
	    kill KILL => $pid;
	    # fixme maybe use an timeout even if kill should not hang?
	    waitpid($pid, 0);
	}
	delete $fence_jobs->{$pid};
    }

    if (defined($node) && $fenced_nodes->{$node}) {
	delete $fenced_nodes->{$node};
    } else {
	$fenced_nodes = {};
	$fence_jobs = {};
    }
};

sub is_node_fenced {
    my ($node) = @_;

    my $state = $fenced_nodes->{$node};
    return 0 if !$state;

    return -1 if $state->{failure} && $state->{failure} == 1;

    return ($state->{needed} && $state->{triggered} &&
	    $state->{triggered} >= $state->{needed}) ? 1 : 0;
}

1;

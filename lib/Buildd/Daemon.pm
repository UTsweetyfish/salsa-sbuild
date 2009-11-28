# buildd: daemon to automatically build packages
# Copyright © 1998 Roman Hodek <Roman.Hodek@informatik.uni-erlangen.de>
# Copyright © 2009 Roger Leigh <rleigh@debian.org>
# Copyright © 2005 Ryan Murray <rmurray@debian.org>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
#######################################################################

package Buildd::Daemon;

use strict;
use warnings;

use POSIX;
use Buildd qw(isin lock_file unlock_file send_mail exitstatus close_log);
use Buildd::Conf;
use Buildd::Base;
use Sbuild qw($devnull df);
use Sbuild::Sysconfig;
use Sbuild::ChrootRoot;
use Sbuild::DB::Client;
use Cwd;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Buildd::Base);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;

    my $self = $class->SUPER::new($conf);
    bless($self, $class);

    $self->set('Daemon', 0);

    return $self;
}

sub ST_MTIME () { 9 }

sub run {
    my $self = shift;

    my $host = Sbuild::ChrootRoot->new($self->get('Config'));
    $host->set('Log Stream', $self->get('Log Stream'));
    $self->set('Host', $host);

    my $my_binary = $0;
    $my_binary = cwd . "/" . $my_binary if $my_binary !~ m,^/,;
    $self->set('MY_BINARY', $my_binary);

    my @bin_stats = stat( $my_binary );
    die "Cannot stat $my_binary: $!\n" if !@bin_stats;
    $self->set('MY_BINARY_TIME', $bin_stats[ST_MTIME]);

    chdir( $self->get_conf('HOME') . "/build" )
	or die "Can't cd to " . $self->get_conf('HOME') . "/build: $!\n";

    open( STDIN, "</dev/null" )
	or die "$0: can't redirect stdin to /dev/null: $!\n";

    if (open( PID, "<" . $self->get_conf('PIDFILE') )) {
	my $pid = <PID>;
	close( PID );
	$pid =~ /^[[:space:]]*(\d+)/; $pid = $1;
	if (!$pid || (kill( 0, $pid ) == 0 && $! == ESRCH)) {
	    warn "Removing stale pid file (process $pid dead)\n";
	}
	else {
	    die "Another buildd (pid $pid) is already running.\n";
	}
    }

    if (!@{$self->get_conf('DISTRIBUTIONS')}) {
	die "distribution list is empty, aborting.";
    }

    if (!$self->get_conf('NO_DETACH')) {
	defined(my $pid = fork) or die "can't fork: $!\n";
	exit if $pid; # parent exits
	setsid or die "can't start a new session: $!\n";
    }

    $self->set('PID', $$); # Needed for cleanup
    $self->set('Daemon', 1);

    open( PID, ">" . $self->get_conf('PIDFILE') )
	or die "can't create " . $self->get_conf('PIDFILE') . ": $!\n";
    printf PID "%5d\n", $self->get('PID');
    close( PID );

    $self->log("Daemon started. (pid=$$)\n");

    undef $ENV{'DISPLAY'};

# the main loop
  MAINLOOP:
    while( 1 ) {
	$self->check_restart();
	$self->read_config();
	$self->check_ssh_master();

	my $done = 0;
	my $thisdone;
	my %binNMUlog;
	do {
	    $thisdone = 0;
	    foreach my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
		$self->check_restart();
		$self->read_config();
		my @redo = $self->get_from_REDO( $dist_config, \%binNMUlog );
		next if !@redo;
		$self->do_build( $dist_config, \%binNMUlog, @redo );
		++$done;
		++$thisdone;
	    }
	} while( $thisdone );

	foreach my $dist_config (@{$self->get_conf('DISTRIBUTIONS')}) {
	    $self->check_restart();
	    $self->read_config();
	    my $dist_name = $dist_config->get('DIST_NAME');
	    my %givenback = $self->read_givenback();
		my $db = $self->get_db_handle($dist_config);
	    my $pipe = $db->pipe_query(
		'--list=needs-build',
		'--dist=' . $dist_name);
	    if (!$pipe) {
		$self->log("Can't spawn wanna-build --list=needs-build: $!\n");
		next MAINLOOP;
	    }

	    my(@todo, $total, $nonex, @lowprio_todo, $max_build);
	    $max_build = $self->get_conf('MAX_BUILD');
	    while( <$pipe> ) {
		my $socket = $dist_config->get('WANNA_BUILD_SSH_SOCKET');
		if ($socket &&
		    (/^Couldn't connect to $socket: Connection refused[\r]?$/ ||
		     /^Control socket connect\($socket\): Connection refused[\r]?$/)) {
		    unlink($socket);
		    $self->check_ssh_master();
		}
		elsif (/^Total (\d+) package/) {
		    $total = $1;
		    next;
		}
		elsif (/^Database for \S+ doesn.t exist/) {
		    $nonex = 1;
		}
		next if $nonex;
		next if @todo >= $max_build;
		my @line = (split( /\s+/, $_));
		my $pv = $line[0];
		my $no_build_regex = $dist_config->get('NO_BUILD_REGEX');
		my $build_regex = $dist_config->get('BUILD_REGEX');
		next if $no_build_regex && $pv =~ m,$no_build_regex,;
		next if $build_regex && $pv !~ m,$build_regex,;
		$pv =~ s,^.*/,,;
		my $p;
		($p = $pv) =~ s/_.*$//;
		next if isin( $p, @{$dist_config->get('NO_AUTO_BUILD')} );
		next if $givenback{$pv};
		if (isin( $p, @{$dist_config->get('WEAK_NO_AUTO_BUILD')} )) {
		    push( @lowprio_todo, $pv );
		    next;
		}
		if ($line[1] =~ /:binNMU/) {
		    $max_build = 1;
		    @todo = ();
		}
		push( @todo, $pv );
	    }
	    close( $pipe );
	    next if $nonex;
	    if ($?) {
		$self->log("wanna-build --list=needs-build --dist=${dist_name} failed; status ",
			   exitstatus($?), "\n");
		next;
	    }
	    $self->log("${dist_name}: total $total packages to build.\n") if defined($total);

	    # Build weak_no_auto packages before the next dist
	    if (!@todo && @lowprio_todo) {
		push ( @todo, @lowprio_todo );
	    }

	    next if !@todo;
	    @todo = $self->do_wanna_build( $dist_config, \%binNMUlog, @todo );
	    next if !@todo;
	    $self->do_build( $dist_config, \%binNMUlog, @todo );
	    ++$done;
	    last;
	}

	# sleep a little bit if there was nothing to do this time
	if (!$done) {
	    $self->log("Nothing to do -- sleeping " .
		       $self->get_conf('IDLE_SLEEP_TIME') . " seconds\n");
	    my $idle_start_time = time;
	    sleep( $self->get_conf('IDLE_SLEEP_TIME') );
	    my $idle_end_time = time;
	    $self->write_stats("idle-time", $idle_end_time - $idle_start_time);
	}
    }

    return 0;
}

sub get_from_REDO {
    my $self = shift;
    my $wanted_dist_config = shift;
    my $binNMUlog = shift;
    my @redo = ();
    local( *F );

    lock_file( "REDO" );
    goto end if ! -f "REDO";
    if (!open( F, "<REDO" )) {
	$self->log("File REDO exists, but can't open it: $!\n");
	goto end;
    }
    my @lines = <F>;
    close( F );

    $self->block_signals();
    if (!open( F, ">REDO" )) {
	$self->log("Can't open REDO for writing: $!\n",
		   "Raw contents:\n@lines\n");
	goto end;
    }
    my $max_build = $self->get_conf('MAX_BUILD');
    foreach (@lines) {
	if (!/^(\S+)\s+(\S+)(?:\s*|\s+(\d+)\s+(\S.*))?$/) {
	    $self->log("Ignoring/deleting bad line in REDO: $_");
	    next;
	}
	my($pkg, $dist, $binNMUver, $changelog) = ($1, $2, $3, $4);
	if ($dist eq $wanted_dist_config->get('DIST_NAME') && @redo < $max_build) {
	    if (defined $binNMUver) {
		if (scalar(@redo) == 0) {
		    $binNMUlog->{$pkg} = $changelog;
		    push( @redo, "!$binNMUver!$pkg" );
		} else {
		    print F $_;
		}
		$max_build = scalar(@redo);
	    } else {
		push( @redo, $pkg );
	    }
	}
	else {
	    print F $_;
	}
    }
    close( F );

  end:
    unlock_file( "REDO" );
    $self->unblock_signals();
    return @redo;
}

sub read_givenback {
    my $self = shift;

    my %gb;
    my $now = time;
    local( *F );

    lock_file( "SBUILD-GIVEN-BACK" );

    if (open( F, "<SBUILD-GIVEN-BACK" )) {
	%gb = map { split } <F>;
	close( F );
    }

    if (open( F, ">SBUILD-GIVEN-BACK" )) {
	foreach (keys %gb) {
	    if ($now - $gb{$_} > $self->get_conf('DELAY_AFTER_GIVE_BACK') *60) {
		delete $gb{$_};
	    }
	    else {
		print F "$_ $gb{$_}\n";
	    }
	}
	close( F );
    }
    else {
	$self->log("Can't open SBUILD-GIVEN-BACK: $!\n");
    }

  unlock:
    unlock_file( "SBUILD-GIVEN-BACK" );
    return %gb;
}

sub do_wanna_build {
    my $self = shift;

    my $dist_config = shift;
    my $binNMUlog = shift;
    my @output = ();
    my $n = 0;

    $self->block_signals();

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query(
	'-v', 
	'--dist=' . $dist_config->get('DIST_NAME'),
       	@_);
    if ($pipe) {
	while( <$pipe> ) {
	    next if /^wanna-build Revision/;
	    if (/^(\S+):\s*ok/) {
		my $pkg = $1;
		push( @output, grep( /^\Q$pkg\E_/, @_ ) );
		++$n;
	    }
	    elsif (/^(\S+):.*NOT OK/) {
		my $pkg = $1;
		my $nextline = <$pipe>;
		chomp( $nextline );
		$nextline =~ s/^\s+//;
		$self->log("Can't take $pkg: $nextline\n");
	    }
	    elsif (/^(\S+):.*previous version failed/i) {
		my $pkg = $1;
		++$n;
		if ($self->get_conf('SHOULD_BUILD_MSGS')) {
		    $self->handle_prevfailed( $dist_config, grep( /^\Q$pkg\E_/, @_ ) );
		} else {
		    push( @output, grep( /^\Q$pkg\E_/, @_ ) );
		}
		# skip until ok line
		while( <$pipe> ) {
		    last if /^\Q$pkg\E:\s*ok/;
		}
	    }
	    elsif (/^(\S+):.*needs binary NMU (\d+)/) {
		my $pkg = $1;
		my $binNMUver = $2;
		chop (my $changelog = <$pipe>);
		my $newpkg;
		++$n;

		push( @output, grep( /^\Q$pkg\E_/, @_ ) );
		$binNMUlog->{$output[$#output]} = $changelog;
		$output[$#output] = "!$binNMUver!" . $output[$#output];
		# skip until ok line
		while( <$pipe> ) {
		    last if /^\Q$pkg\E:\s*aok/;
		}
	    }
	}
	close( $pipe );
	$self->unblock_signals();
	$self->write_stats("taken", $n) if $n;
	return @output;
    }
    else {
	$self->unblock_signals();
	$self->log("Can't spawn wanna-build: $!\n");
	return ();
    }
}

sub do_build {
    my $self = shift;
    my $dist_config = shift;
    my $binNMUlog = shift;

    return if !@_;
    my $free_space;

    while (($free_space = df(".")) < $self->get_conf('MIN_FREE_SPACE')) {
	$self->log("Delaying build, because free space is low ($free_space KB)\n");
	my $idle_start_time = time;
	sleep( 10*60 );
	my $idle_end_time = time;
	$self->write_stats("idle-time", $idle_end_time - $idle_start_time);
    }

    $self->log("Starting build (dist=" . $dist_config->get('DIST_NAME') . ") of:\n@_\n");
    $self->write_stats("builds", scalar(@_));
    my $binNMUver;

    my @sbuild_args = ( 'nice', '-n', $self->get_conf('NICE_LEVEL'), 'sbuild',
			'--apt-update',
			'--batch',
			"--stats-dir=" . $self->get_conf('HOME') . "/stats",
			"--dist=" . $dist_config->get('DIST_NAME') );
    my $sbuild_gb = '--auto-give-back';
    if ($dist_config->get('WANNA_BUILD_SSH_CMD')) {
	$sbuild_gb .= "=";
	$sbuild_gb .= $dist_config->get('WANNA_BUILD_SSH_SOCKET') . "\@"
	    if $dist_config->get('WANNA_BUILD_SSH_SOCKET');
	$sbuild_gb .= $dist_config->get('WANNA_BUILD_DB_USER') . "\@"
	    if $dist_config->get('WANNA_BUILD_DB_USER');
	$sbuild_gb .= $dist_config->get('WANNA_BUILD_SSH_USER') ."\@" 
	    if $dist_config->get('WANNA_BUILD_SSH_USER');
	$sbuild_gb .= $dist_config->get('WANNA_BUILD_SSH_HOST');
    } else {
	# Otherwise newer sbuild will take the package name as an --auto-give-back
	# parameter (changed from regexp to GetOpt::Long parsing)
	$sbuild_gb .= "=yes"
    }
    push ( @sbuild_args, $sbuild_gb );
    #multi-archive-buildd keeps the mailto configuration in the builddrc, so
    #this needs to be passed over to sbuild. If the buildd config doesn't have
    #it, we hope that the address is configured in .sbuildrc and the right one:
    if ($dist_config->get('LOGS_MAILED_TO')) {
	push @sbuild_args, '--mail-log-to=' . $dist_config->get('LOGS_MAILED_TO');
    }
    push ( @sbuild_args, "--database=" . $dist_config->get('WANNA_BUILD_DB_NAME') )
	if $dist_config->get('WANNA_BUILD_DB_NAME');

    if (scalar(@_) == 1 and $_[0] =~ s/^!(\d+)!//) {
	$binNMUver = $1;

	push ( @sbuild_args, "--binNMU=$binNMUver", "--make-binNMU=" . $binNMUlog->{$_[0]});
    }
    $self->log("command line: @sbuild_args @_\n");

    if (($main::sbuild_pid = fork) == 0) {
	{ exec (@sbuild_args, @_) };
	$self->log("Cannot execute sbuild: $!\n");
	exit(64);
    }

    if (!defined $main::sbuild_pid) {
	$self->log("Cannot fork for sbuild: $!\n");
	goto failed;
    }
    my $rc;
    while (($rc = wait) != $main::sbuild_pid) {
	if ($rc == -1) {
	    last if $! == ECHILD;
	    next if $! == EINTR;
	    $self->log("wait for sbuild: $!; continuing to wait\n");
	} elsif ($rc != $main::sbuild_pid) {
	    $self->log("wait for sbuild: returned unexpected pid $rc\n");
	}
    }
    undef $main::sbuild_pid;

    if ($?) {
	$self->log("sbuild failed with status ".exitstatus($?)."\n");
      failed:
	if (-f "SBUILD-REDO-DUMPED") {
	    $self->log("Found SBUILD-REDO-DUMPED; sbuild already dumped ",
		       "pkgs which need rebuiling/\n");
	    local( *F );
	    my $n = 0;
	    open( F, "<REDO" );
	    while( <F> ) { ++$n; }
	    close( F );
	    $self->write_stats("builds", -$n);
	}
	elsif (-f "SBUILD-FINISHED") {
	    my @finished = $self->read_FINISHED();
	    $self->log("sbuild has already finished:\n@finished\n");
	    my @unfinished;
	    for (@_) {
		push( @unfinished, $_ ) if !isin( $_, @finished );
	    }
	    $self->log("Adding rest to REDO:\n@unfinished\n");
	    $self->append_to_REDO( $dist_config, '', @unfinished );
	    $self->write_stats("builds", -scalar(@unfinished));
	}
	else {
	    if (defined $binNMUver) {
		$self->log("Assuming binNMU failed and adding to REDO:\n@_\n");
		$self->append_to_REDO( $dist_config, "$binNMUver $binNMUlog->{$_[0]}", @_ );
	    } else {
		$self->log("Assuming all packages unbuilt and adding to REDO:\n@_\n");
		$self->append_to_REDO( $dist_config, '', @_ );
	    }
	    $self->write_stats("builds", -scalar(@_));
	}

	delete $binNMUlog->{$_[0]} if defined $binNMUver;

	if (++$main::sbuild_fails > 2) {
	    $self->log("sbuild now failed $main::sbuild_fails times in ".
		       "a row; going to sleep\n");
	    send_mail( $self->get_conf('ADMIN_MAIL'),
		       "Repeated mess with sbuild",
		       <<EOF );
The execution of sbuild now failed for $main::sbuild_fails times.
Something must be wrong here...

The daemon is going to sleep for 1 hour, or can be restarted with SIGUSR2.
EOF
            my $oldsig;
	    eval <<'EOF';
$oldsig = $SIG{'USR2'};
$SIG{'USR2'} = sub ($) { die "signal\n" };
my $idle_start_time = time;
sleep( 60*60 );
my $idle_end_time = time;
$SIG{'USR2'} = $oldsig;
$self->write_stats("idle-time", $idle_end_time - $idle_start_time);
EOF
	}
    }
    else {
	$main::sbuild_fails = 0;
    }
    unlink "SBUILD-REDO-DUMPED" if -f "SBUILD-REDO-DUMPED";
    $self->log("Build finished.\n");
}

sub handle_prevfailed {
    my $self = shift;
    my $dist_config = shift;
    my $pkgv = shift;

    my $dist_name = $dist_config->get('DIST_NAME');
    my( $pkg, $fail_msg, $changelog);

    $self->log("$pkgv previously failed -- asking admin first\n");
    ($pkg = $pkgv) =~ s/_.*$//;

    my $db = $self->get_db_handle($dist_config);
    my $pipe = $db->pipe_query(
	'--info',
       	'--dist=' . $dist_name,
       	$pkg);
    if (!$pipe) {
	$self->log("Can't run wanna-build: $!\n");
	return;
    }

    $fail_msg = <$pipe>;

    close($pipe);
    if ($?) {
	$self->log("wanna-build exited with error $?\n");
	return;
    }

    {
	local $SIG{'ALRM'} = sub ($) { die "Timeout!\n" };
	eval { $changelog = $self->get_changelog( $dist_config, $pkgv ) };
    }
    $changelog = "ERROR: FTP timeout" if $@;

    send_mail( $self->get_conf('ADMIN_MAIL'),
	       "Should I build $pkgv (dist=${dist_name})?",
	       "The package $pkg failed to build in a previous version. ".
	       "The fail\n".
	       "messages are:\n\n$fail_msg\n".
	       ($changelog !~ /^ERROR/ ?
		"The changelog entry for the newest version is:\n\n".
		"$changelog\n" :
		"Sorry, the last changelog entry could not be extracted:\n".
		"$changelog\n\n").
	       "Should buildd try to build the new version, or should it ".
	       "fail with the\n".
	       "same messages again.? Please answer with 'build' (or 'ok'), ".
	       "or 'fail'.\n" );
}

sub get_changelog {
    my $self = shift;
    my $dist_config = shift;
    my $pkg = shift;

    my $dist_name = $dist_config->get('DIST_NAME');
    my $changelog = "";
    my $analyze = "";
    my $chroot_apt_options;
    my $file;
    my $retried = 0;

    $pkg =~ /^([\w\d.+-]+)_([\w\d:.~+-]+)/;
    my ($n, $v) = ($1, $2);
    (my $v_ne = $v) =~ s/^\d+://;
    my $pkg_ne = "${n}_${v_ne}";

retry:
    my @schroot = ($self->get_conf('SCHROOT'), '-c',
		   $dist_name . '-' . $self->get_conf('ARCH') . '-sbuild', '--');
    my @schroot_root = ($self->get_conf('SCHROOT'), '-c',
			$dist_name . '-' . $self->get_conf('ARCH') . '-sbuild',
			'-u', 'root', '--');
    my $apt_get = $self->get_conf('APT_GET');

    my $pipe = $self->get('Host')->pipe_command(
	{ COMMAND => [@schroot,
		      "$apt_get", '-q', '-d',
		      '--diff-only', 'source', "$n=$v"],
	  USER => $self->get_conf('USERNAME'),
	  CHROOT => 1,
	  PRIORITY => 0,
	});
    if (!$pipe) {
	$self->log("Can't run schroot: $!\n");
	return;
    }

    my $msg = <$pipe>;

    close($pipe);

    if ($? == 0 && $msg !~ /get 0B/) {
	$analyze = "diff";
	$file = "${n}_${v_ne}.diff.gz";
    }

    if (!$analyze) {
	my $pipe2 = $self->get('Host')->pipe_command(
	    { COMMAND => [@schroot,
			  "$apt_get", '-q', '-d',
			  '--tar-only', 'source', "$n=$v"],
	      USER => $self->get_conf('USERNAME'),
	      CHROOT => 1,
	      PRIORITY => 0,
	    });
	if (!$pipe2) {
	    $self->log("Can't run schroot: $!\n");
	    return;
	}

	my $msg = <$pipe2>;

	close($pipe2);

	if ($? == 0 && $msg !~ /get 0B/) {
	    $analyze = "tar";
	    $file = "${n}_${v_ne}.tar.gz";
	}
    }

    if (!$analyze && !$retried) {
	$self->get('Host')->run_command(
	    { COMMAND => [@schroot_root,
			  $apt_get, '-qq',
			  'update'],
	      USER => $self->get_conf('USERNAME'),
	      CHROOT => 1,
	      PRIORITY => 0,
	      STREAMOUT => $devnull
	    });

	$retried = 1;
	goto retry;
    }

    return "ERROR: cannot find any source" if !$analyze;

    if ($analyze eq "diff") {
	if (!open( F, "gzip -dc '$file' 2>/dev/null |" )) {
	    return "ERROR: Cannot spawn gzip to zcat $file: $!";
	}
	while( <F> ) {
	    # look for header line of a file */debian/changelog
	    last if m,^\+\+\+\s+[^/]+/debian/changelog(\s+|$),;
	}
	while( <F> ) {
	    last if /^---/; # end of control changelog patch
	    next if /^\@\@/;
	    $changelog .= "$1\n" if /^\+(.*)$/;
	    last if /^\+\s+--\s+/;
	}
	while( <F> ) { } # read to end of file to avoid broken pipe
	close( F );
	if ($?) {
	    return "ERROR: error status ".exitstatus($?)." from gzip on $file";
	}
	unlink( $file );
    }
    elsif ($analyze eq "tar") {
	if (!open( F, "tar -xzOf '$file' '*/debian/changelog' ".
		   "2>/dev/null |" )) {
	    return "ERROR: Cannot spawn tar for $file: $!";
	}
	while( <F> ) {
	    $changelog .= $_;
	    last if /^\s+--\s+/;
	}
	while( <F> ) { } # read to end of file to avoid broken pipe
	close( F );
	if ($?) {
	    return "ERROR: error status ".exitstatus($?)." from tar on $file";
	}
	unlink( $file );
    }

    return $changelog;
}

sub append_to_REDO {
    my $self = shift;
    my $dist_config = shift;
    my $postfix = shift;

    my @npkgs = @_;
    my @pkgs = ();
    my $pkg;
    local( *F );

    $self->block_signals();
    lock_file( "REDO" );

    if (open( F, "REDO" )) {
	@pkgs = <F>;
	close( F );
    }

    if (open( F, ">>REDO" )) {
	foreach $pkg (@npkgs) {
	    next if grep( /^\Q$pkg\E\s/, @pkgs );
	    print F "$pkg " . $dist_config->get('DIST_NAME') . $postfix . "\n";
	}
	close( F );
    }
    else {
	$self->log("Can't open REDO: $!\n");
    }

  unlock:
    unlock_file( "REDO" );
    $self->unblock_signals();
}

sub read_FINISHED {
    my $self = shift;

    local( *F );
    my @pkgs;

    if (!open( F, "<SBUILD-FINISHED" )) {
	$self->log("Can't open SBUILD-FINISHED: $!\n");
	return ();
    }
    chomp( @pkgs = <F> );
    close( F );
    unlink( "SBUILD-FINISHED" );
    return @pkgs;
}

sub check_restart {
    my $self = shift;
    my @stats = stat( $self->get('MY_BINARY') );

    if (@stats && $self->get('MY_BINARY_TIME') != $stats[ST_MTIME]) {
	$self->log("My binary has been updated -- restarting myself (pid=$$)\n");
	unlink( $self->get_conf('PIDFILE') );
	kill ( 15, $main::ssh_pid ) if $main::ssh_pid;
	exec $self->get('MY_BINARY');
    }

    if ( -f $self->get_conf('HOME') . "/EXIT-DAEMON-PLEASE" ) {
	unlink($self->get_conf('HOME') . "/EXIT-DAEMON-PLEASE");
	$self->shutdown("NONE (flag file exit)");
    }
}

sub block_signals {
    my $self = shift;

    POSIX::sigprocmask( SIG_BLOCK, $main::block_sigset );
}

sub unblock_signals {
    my $self = shift;

    POSIX::sigprocmask( SIG_UNBLOCK, $main::block_sigset );
}

sub check_ssh_master {
    my $self = shift;

    return 1 if (!$self->get_conf('WANNA_BUILD_SSH_SOCKET'));
    return 1 if ( -S $self->get_conf('WANNA_BUILD_SSH_SOCKET') );

    if ($main::ssh_pid)
    {
	my $wpid = waitpid ( $main::ssh_pid, WNOHANG );
	return 1 if ($wpid != -1 and $wpid != $main::ssh_pid);
    }

    ($main::ssh_pid = fork)
	or exec (@{$self->get_conf('WANNA_BUILD_SSH_CMD')}, "-MN");

    if (!defined $main::ssh_pid) {
	$self->log("Cannot fork for ssh master: $!\n");
	return 0;
    }

    while ( ! -S $self->get_conf('WANNA_BUILD_SSH_SOCKET') )
    {
	sleep 1;
	my $wpid = waitpid ( $main::ssh_pid, WNOHANG );
	return 0 if ($wpid == -1 or $wpid == $main::ssh_pid);
    }
    return 1;
}

sub read_config {
    my $self = shift;

    $self->get('Config')->read_config();
}

sub shutdown {
    my $self = shift;
    my $signame = shift;

    $self->log("buildd ($$) received SIG$signame -- shutting down\n");

    if (defined $main::ssh_pid) {
	kill ( 15, $main::ssh_pid );
    }
    if (defined $main::sbuild_pid) {
	$self->log("Killing sbuild (pid=$main::sbuild_pid)\n");
	kill( 15, $main::sbuild_pid );
	$self->log("Waiting max. 2 minutes for sbuild to finish\n");
	$SIG{'ALRM'} = sub ($) { die "timeout\n"; };
	alarm( 120 );
	eval "waitpid( $main::sbuild_pid, 0 )";
	alarm( 0 );
	if ($@) {
	    $self->log("sbuild did not die!");
	}
	else {
	    $self->log("sbuild died normally");
	}
	unlink( "SBUILD-REDO-DUMPED" );
    }
    unlink( $self->get('Config')->get('PIDFILE') );
    $self->log("exiting now\n");
    close_log($self->get('Config'));
    exit 1;
}

1;

#
# ChrootUnshare.pm: chroot library for sbuild
# Copyright © 2018      Johannes Schauer <josch@debian.org>
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

package Sbuild::ChrootUnshare;

use strict;
use warnings;

use English;
use Sbuild::Utility;
use File::Temp qw(mkdtemp);

BEGIN {
    use Exporter ();
    use Sbuild::Chroot;
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter Sbuild::Chroot);

    @EXPORT = qw();
}

sub new {
    my $class = shift;
    my $conf = shift;
    my $chroot_id = shift;

    my $self = $class->SUPER::new($conf, $chroot_id);
    bless($self, $class);

    return $self;
}

sub begin_session {
    my $self = shift;

    my @idmap = read_subuid_subgid;

    # sanity check
    if (scalar(@idmap) != 2 || $idmap[0][0] ne 'u' || $idmap[1][0] ne 'g') {
	printf STDERR "invalid idmap\n";
	return 0;
    }

    $self->set('Uid Gid Map', \@idmap);

    my @cmd;
    my $exit;

    if(!test_unshare) {
	print STDERR "E: unable to to unshare\n";
	return 0;
    }

    my @unshare_cmd = get_unshare_cmd({IDMAP => \@idmap});

    my $rootdir = mkdtemp($self->get_conf('UNSHARE_TMPDIR_TEMPLATE'));

    # $REAL_GROUP_ID is a space separated list of all groups the current user
    # is in with the first group being the result of getgid(). We reduce the
    # list to the first group by forcing it to be numeric
    my $outer_gid = $REAL_GROUP_ID+0;
    @cmd = (get_unshare_cmd({
		IDMAP => [['u', '0', $REAL_USER_ID, '1'],
		    ['g', '0', $outer_gid, '1'],
		    ['u', '1', $idmap[0][2], '1'],
		    ['g', '1', $idmap[1][2], '1'],
		]
	    }), 'chown', '1:1', $rootdir);
    if ($self->get_conf('DEBUG')) {
	printf STDERR "running @cmd\n";
    }
    system(@cmd);
    $exit = $? >> 8;
    if ($exit) {
	print STDERR "bad exit status ($exit): @cmd\n";
	return 0;
    }

    my $tarball = $self->get_conf('UNSHARE_TARBALL');

    if (! -e $tarball) {
	print STDERR "$tarball does not exist, check \$unshare_tarball config option\n";
	return 0;
    }

    if (! -r $tarball) {
	print STDERR "$tarball is not readable\n";
	return 0;
    }

    print STDOUT "Unpacking $tarball to $rootdir...\n";
    @cmd = (@unshare_cmd, 'tar',
	'--exclude=./dev/urandom',
	'--exclude=./dev/random',
	'--exclude=./dev/full',
	'--exclude=./dev/null',
	'--exclude=./dev/zero',
	'--exclude=./dev/tty',
	'--exclude=./dev/ptmx',
	'--directory', $rootdir,
	'--extract', '--file', $tarball
    );
    if ($self->get_conf('DEBUG')) {
	printf STDERR "running @cmd\n";
    }
    system(@cmd);
    $exit = $? >> 8;
    if ($exit) {
	print STDERR "bad exit status ($exit): @cmd\n";
	return 0;
    }

    $self->set('Session ID', $rootdir);

    $self->set('Location', '/sbuild-unshare-dummy-location');

    $self->set('Session Purged', 1);

    return 0 if !$self->_setup_options();

    return 1;
}

sub end_session {
    my $self = shift;

    return if $self->get('Session ID') eq "";

    print STDERR "Cleaning up chroot (session id " . $self->get('Session ID') . ")\n"
    if $self->get_conf('DEBUG');

    # this looks like a recipe for disaster, but since we execute "rm -rf" with
    # lxc-usernsexec, we only have permission to delete the files that were
    # created with the fake root user
    my @cmd = (get_unshare_cmd({IDMAP => $self->get('Uid Gid Map')}), 'rm', '-rf', $self->get('Session ID'));
    if ($self->get_conf('DEBUG')) {
	printf STDERR "running @cmd\n";
    }
    system(@cmd);
    # we ignore the exit status, because the command will fail to remove the
    # unpack directory itself because of insufficient permissions

    if(!rmdir($self->get('Session ID'))) {
	print STDERR "unable to remove " . $self->get('Session ID') . "\n";
	$self->set('Session ID', "");
	return 0;
    }

    $self->set('Session ID', "");

    return 1;
}

sub get_command_internal {
    my $self = shift;
    my $options = shift;

    # Command to run. If I have a string, use it. Otherwise use the list-ref
    my $command = $options->{'INTCOMMAND_STR'} // $options->{'INTCOMMAND'};

    my $user = $options->{'USER'};          # User to run command under
    my $dir;                                # Directory to use (optional)
    $dir = $self->get('Defaults')->{'DIR'} if
    (defined($self->get('Defaults')) &&
	defined($self->get('Defaults')->{'DIR'}));
    $dir = $options->{'DIR'} if
    defined($options->{'DIR'}) && $options->{'DIR'};

    if (!defined $user || $user eq "") {
	$user = $self->get_conf('USERNAME');
    }

    my @cmdline = ();

    if (!defined($dir)) {
	$dir = '/';
    }

    my $network_setup = 'cat /etc/resolv.conf > "$rootdir/etc/resolv.conf";';
    my $unshare = CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWIPC;
    if (defined($options->{'DISABLE_NETWORK'}) && $options->{'DISABLE_NETWORK'}) {
	$unshare |= CLONE_NEWNET;
	$network_setup = 'ip link set lo up;> "$rootdir/etc/resolv.conf";';
    }

    @cmdline = (
	'env', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin',
	get_unshare_cmd({UNSHARE_FLAGS => $unshare, FORK => 1, IDMAP => $self->get('Uid Gid Map')}), 'sh', '-c', "
	rootdir=\"\$1\"; shift;
	user=\"\$1\"; shift;
	dir=\"\$1\"; shift;
	hostname sbuild;
	$network_setup
	mkdir -p \"\$rootdir/dev\";
	for f in null zero full random urandom tty; do
	    touch \"\$rootdir/dev/\$f\";
	    chmod -rwx \"\$rootdir/dev/\$f\";
	    mount -o bind \"/dev/\$f\" \"\$rootdir/dev/\$f\";
	done;
	mkdir -p \"\$rootdir/sys\";
	mount -o rbind /sys \"\$rootdir/sys\";
	mkdir -p \"\$rootdir/proc\";
	mount -t proc proc \"\$rootdir/proc\";
	/usr/sbin/chroot \"\$rootdir\" sh -c \"id -u \\\"\$user\\\">/dev/null 2>&1 || adduser --system --quiet --group --no-create-home --home /nonexistent --disabled-login --disabled-password \\\"\$user\\\"\";
	exec /usr/sbin/chroot \"\$rootdir\" /sbin/runuser -u \"\$user\" -- sh -c \"cd \\\"\\\$1\\\" && shift && \\\"\\\$@\\\"\" -- \"\$dir\" \"\$@\";
	", '--', $self->get('Session ID'), $user, $dir
    );
    if (ref $command) {
	push @cmdline, @$command;
    } else {
	push @cmdline, ('/bin/sh', '-c', $command);
	$command = [split(/\s+/, $command)];
    }
    $options->{'USER'} = $user;
    $options->{'COMMAND'} = $command;
    $options->{'EXPCOMMAND'} = \@cmdline;
    $options->{'CHDIR'} = undef;
    $options->{'DIR'} = $dir;
}

1;
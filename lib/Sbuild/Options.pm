#
# Options.pm: options parser for sbuild
# Copyright © 2005      Ryan Murray <rmurray@debian.org>
# Copyright © 2005-2006 Roger Leigh <rleigh@debian.org>
# Copyright © 2008      Simon McVittie <smcv@debian.org>
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

package Sbuild::Options;

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case auto_abbrev gnu_getopt);
use Sbuild::Conf;

BEGIN {
    use Exporter ();
    our (@ISA, @EXPORT);

    @ISA = qw(Exporter);

    @EXPORT = qw();
}

sub new ();
sub get (\%$);
sub set (\%$$);
sub parse_options (\%);

sub new () {
    my $self  = {};
    bless($self);

    $self->{'User Arch'} = '';
    $self->{'Build Arch All'} = 0;
    $self->{'Auto Giveback'} = 0;
    $self->{'Auto Giveback Host'} = 0;
    $self->{'Auto Giveback Socket'} = 0;
    $self->{'Auto Giveback User'} = 0;
    $self->{'Auto Giveback WannaBuild User'} = 0;
    $self->{'Manual Srcdeps'} = [];
    $self->{'Batch Mode'} = 0;
    $self->{'WannaBuild Database'} = 0;
    $self->{'Build Source'} = 0;
    $self->{'Distribution'} = 'unstable';
    $self->{'Override Distribution'} = 0;
    $self->{'binNMU'} = undef;
    $self->{'binNMU Version'} = undef;
    $self->{'Chroot'} = undef;
    $self->{'LD_LIBRARY_PATH'} = undef;
    $self->{'GCC Snapshot'} = 0;

    if (!$self->parse_options()) {
	return undef;
    }
    return $self;
}

sub get (\%$) {
    my $self = shift;
    my $key = shift;

    return $self->{$key};
}

sub set (\%$$) {
    my $self = shift;
    my $key = shift;
    my $value = shift;

# TODO: Check if key exists before setting it.

    return $self->{$key} = $value;
}

sub parse_options (\%) {
    my $self = shift;

    return GetOptions ("arch=s" => \$self->{'User Arch'},
		       "A|arch-all" => sub {
			   $self->set('Build Arch All', 1);
		       },
		       "auto-give-back=s" => sub {
			   $self->set('Auto Giveback', 1);
			   if ($_[1]) {
			       my @parts = split( '@', $_[1] );
			       $self->set('Auto Giveback Socket',
					  $parts[$#parts-3])
				   if @parts > 3;
			       $self->set('Auto Giveback WannaBuild User',
					  $parts[$#parts-2])
				   if @parts > 2;
			       $self->set('Auto Giveback User',
					  $parts[$#parts-1])
				   if @parts > 1;
			       $self->set('Auto Giveback Host',
					  $parts[$#parts]);
			   }
		       },
		       "f|force-depends=s" => sub {
			   push( @{$self->get('Manual Srcdeps')}, "f".$_[1] );
		       },
		       "a|add-depends=s" => sub {
			   push( @{$self->get('Manual Srcdeps')}, "a".$_[1] );
		       },
		       "check-depends-algorithm=s" => sub {
			   die "Bad build dependency check algorithm\n"
			       if( ! ($_[1] eq "first-only" 
				      || $_[1] eq "alternatives") );
			   $Sbuild::Conf::check_depends_algorithm = $_[1];
		       },
		       "b|batch" => sub {
			   $self->set('Batch Mode', 1);
		       },
		       "make-binNMU=s" => sub {
			   $self->set('binNMU', $_[1]);
			   $self->set('binNMU Version',
				      $self->get('binNMU Version') ||= 1);
		       },
		       "binNMU=i" => sub {
			   $self->set('binNMU Version', $_[1]);
		       },
		       "c|chroot=s" => sub {
			   $self->set('Chroot', $_[1]);
		       },
		       "database=s" => sub {
			   $self->set('WannaBuild Database', $_[1]);
		       },
		       "D|debug+" => \$Sbuild::Conf::debug,
		       "apt-update" => \$Sbuild::Conf::apt_update,
		       "d|dist=s" => sub {
			   $self->set('Distribution', $_[1]);
			   $self->set('Distribution', "oldstable")
			       if $self->{'Distribution'} eq "o";
			   $self->set('Distribution', "stable")
			       if $self->{'Distribution'} eq "s";
			   $self->set('Distribution', "testing")
			       if $self->{'Distribution'} eq "t";
			   $self->set('Distribution', "unstable")
			       if $self->{'Distribution'} eq "u";
			   $self->set('Distribution', "experimental")
			       if $self->{'Distribution'} eq "e";
			   $self->set('Override Distribution', 1);
		       },
		       "force-orig-source" => \$Sbuild::Conf::force_orig_source,
		       "m|maintainer=s" => \$Sbuild::Conf::maintainer_name,
		       "k|keyid=s" => \$Sbuild::Conf::key_id,
		       "e|uploader=s" => \$Sbuild::Conf::uploader_name,
		       "n|nolog" => \$Sbuild::Conf::nolog,
		       "purge=s" => sub {
			   $Sbuild::Conf::purge_build_directory = $_[1];
			   die "Bad purge mode\n"
			       if !isin($Sbuild::Conf::purge_build_directory,
					qw(always successful never));
		       },
		       "s|source" => sub {
			   $self->set('Build Source', 1);
		       },
		       "stats-dir=s" => \$Sbuild::Conf::stats_dir,
		       "use-snapshot" => sub {
			   $self->set('GCC Snapshot', 1);
			   $self->set('LD_LIBRARY_PATH',
				      "/usr/lib/gcc-snapshot/lib");
			   $Sbuild::Conf::path =
			       "/usr/lib/gcc-snapshot/bin:$Sbuild::Conf::path";
		       },
		       "v|verbose+" => \$Sbuild::Sbuild::Conf::verbose,
		       "q|quiet" => sub {
			   $Sbuild::Sbuild::Conf::verbose-- if $Sbuild::Conf::verbose;
		       },
	);
}

1;
package ORAC::Calib::SCUBA;

=head1 NAME

ORAC::Calib::SCUBA - SCUBA calibration object

=head1 SYNOPSIS

  use ORAC::Calib::SCUBA;

  $Cal = new ORAC::Calib::SCUBA;

  $gain = $Cal->gain($filter);
  $tau  = $Cal->tau($filter);
  @badbols = $Cal->badbols;

=head1 DESCRIPTION

This module returns (and can be used to set) calibration information
for SCUBA. SCUBA calibrations are used for extinction correction
(the sky opacity) and conversion of volts to Janskys.

It can also be used to set and retrieve lists of bad bolometers generated
by noise observations.

This class does inherit from B<ORAC::Calib> although nearly all the
methods in the base class are irrelevant to SCUBA (this class only
uses the thing() method).

=cut


# Calibration object for the ORAC pipeline

use strict;
use Carp;
use vars qw/$VERSION %DEFAULT_FCFS %PHOTFLUXES @PLANETS $DEBUG/;

use Cwd;          # Directory change
use File::Path;   # rmtree function

# Derive from standard Calib class (even though nothing in common
# for now)
use ORAC::Calib;  # We are a Calib class
use ORAC::Index;  # Use index file
use ORAC::Print;  # Standardised printing
use ORAC::Constants; # ORAC__OK

use ORAC::Msg::ADAM::Control;  # For fluxes monolith - messaging
use ORAC::Msg::ADAM::Task;     # For fluxes monolith


# External modules

use JCMT::Tau;         # Tau conversion
use JCMT::Tau::CsoFit; # Fits to CSO data

use Starlink::Config;  # Need to know where fluxes is


'$Revision$ ' =~ /.*:\s(.*)\s\$/ && ($VERSION = $1);

# Let the object know that it is derived from ORAC::Frame;
#@ORAC::Calib::SCUBA::ISA = qw/ORAC::Calib/;
use base qw/ORAC::Calib/;

$DEBUG = 0; # Turn off debugging mode

# Define default SCUBA gains
# These vary with a number of things including filter, and observing
# mode. Map calibration can also be done using Jy/arcsec2 or Jy/beam.
# Additionally there is the possibility of time dependent changes
# due to improvements in throughput (not necessarily a change in filter)

# These are currently photometry Jy/beam/V FCFs

%DEFAULT_FCFS = (
		 BEAM => {
			  '2000' => 650,
			  '1350' => 130,
			  '1100' => 1,  # This filter has never worked
			  '850'  => 240,
			  '750'  => 310,
			  '450'  => 800,
			  '350'  => 1200,
			  '850N' => 240,
			  '450N' => 800,
			  '850W' => 197,
			  '450W' => 384,
			 },
		 ARCSEC => {
			    '450W' => 2.6,
			    '850W' => 0.80,
			    '850N' => 1.00,
			   }
		);

# Should probably put calibrator flux information in a different
# file

# Need to store fluxes for each filter
# Use Jy
# Note that the 350/750 fluxes are MADE UP NUMBERS using
# extrapolation from 450/850


%PHOTFLUXES = (
#	       'IRC+10216' => {
#			       '850' => 6.12,
#			       '750' => 7.11,
#			       '450' => 13.1,
#			       '350' => 17.7,
#			      },
	       'HLTAU' => {
			   '850' => 2.32,
			   '450' => 10.4,
			  },
	       'CRL618' => {
			    '850' => 4.57,
			    '450' => 11.9,
			   },
	       'CRL2688' => {
			     '850' => 5.88,
			     '450' => 24.8,
			    },
	       '16293-2422' => {
				'850' => 16.3,
				'450' => 78.1,
			       },
	       'OH231.8' => {
			     '850' => 2.52,
			     '450' => 10.53,
			    }
	      );


# The planets that we can retrieve fluxes for
@PLANETS = qw/ MARS JUPITER SATURN URANUS NEPTUNE /;


# Setup the object structure

=head1 PUBLIC METHODS

The following methods are available in this class.
These are in addition to the methods inherited from B<ORAC::Calib>.

=head2 Constructor

=over 4

=item B<new>

Create a new instance of a ORAC::Calib::SCUBA object.
The object identifier is returned.

  $Cal = new ORAC::Calib::SCUBA;

=cut

# NEW - create new instance of Calib

sub new {

  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $obj = {
	     AMS => undef,           # ADAM messaging object
	     BadBols => undef,       # Bad bolometers
	     BadBolsNoUpdate => 0,
	     FluxesObj => undef,     # Fluxes monolith
	     FluxesTmpDir => undef,
	     Gains => undef,         # Gains (flux conversion factors)
	     GainsIndex => undef,
	     GainsNoUpdate => 0,
	     SkydipIndex => undef,
	     TauSys => undef,        # Tau system
	     TauSysNoUpdate => 0,
             TauCache => {},         # Cache for tau result
	     Thing => {},            # Header of current frame
	     CsoFit => undef,        # Polynomial tau fits
	    };

  bless($obj, $class);

  # Take no arguments at present
  return $obj;

}

=back

=head2 Accessor Methods

=over 4

=item B<badbols>

Set or retrieve the name of the system to be used for bad bolometer
determination. Allowed values are:

=over 8

=item * index

Use an index file generated by noise observations
using the reflector blade. The bolometers stored in this
file are those that were above the noise threshold in 
the _REDUCE_NOISE_ primitive. The index file is generated
by the _REDUCE_NOISE_ primitive

=item * file

Uses the contents of the file F<badbol.lis> (contains a space
separated list of bolometer names in the first line). This
file is in ORAC_DATA_OUT. If the file is not found, no
bolometers will be flagged.

=item * 'list'

A colon-separated list of bolometer names can be supplied.
If badbols=h7:i12:g4,... then this list will be used
as the bad bolometers throughout the reduction.

=back

Default is to use the 'file' method.
The value is always upper-cased.

=cut

sub badbols {
  my $self = shift;
  if (@_) { $self->{BadBols} = uc(shift) unless $self->badbolsnoupdate; }
  $self->{BadBols} = 'FILE' unless (defined $self->{BadBols});
  return $self->{BadBols};
}

=item B<badbolsindex>

Return (or set) the index object associated with the bad bolometers
index file. This index file is used if badbols() is set to index.

=cut

sub badbolsindex {

  my $self = shift;
  if (@_) { $self->{BadBolsIndex} = shift; }

  unless (defined $self->{BadBolsIndex}) {
    my $indexfile = $ENV{ORAC_DATA_OUT}."/index.badbols";
    my $rulesfile = $ENV{ORAC_DATA_CAL}."/rules.badbols";
    $self->{BadBolsIndex} = new ORAC::Index($indexfile,$rulesfile);
  };

  return $self->{BadBolsIndex};
}


=item B<badbolsnoupdate>

Flag to prevent the badbols system from being modified during data
processing.

=cut

sub badbolsnoupdate {
  my $self = shift;
  if (@_) { $self->{BadBolsNoUpdate} = shift };
  return $self->{BadBolsNoUpdate};
}

=item B<fluxes_mon>

Retrieves the ORAC::Msg::ADAM::Task object associated with
the Starlink fluxes monolith.

A new object is created if the value is undefined.

Relies on the Adam messaging system being available.
ADAM messaging is initialised if not present.

Currently this routine also assumes that no other fluxes
objects are started by this process (since there are a number
of things that must be configured before starting the monolith).

=cut

sub fluxes_mon {
  my $self = shift;
  my $status;

  unless (defined $self->{FluxesObj}) {
    # Start AMS
    $self->{AMS} = new ORAC::Msg::ADAM::Control;
    $status = $self->{AMS}->init;
    croak 'ORAC::Calib::SCUBA::fluxes_mon: Error starting ADAM messaging system'
      unless $status == ORAC__OK;

    # Start FLUXES - this requires some environment variables to be defined
    # This should use a $FLUXES_DIR env variable
    unless (exists $ENV{FLUXES}) {
	$ENV{FLUXES} = $StarConfig{Star_Bin} ."/fluxes";
    }

    # Should chdir to /tmp, create the soft link, launch fluxes
    # and then chdir back to wherever we happen to be.

    my $cwd = cwd; # Store current dir

    # Create temp directory - this is needed in case another
    # oracdr is running fluxes and we want to make sure that
    # the JPLEPH file is not removed when THAT oracdr finishes!
    my $tmpdir = "/tmp/fluxes_$$";
    mkdir $tmpdir,0777 || croak "Could not make directory $tmpdir: $!";

    chdir($tmpdir) || croak "Could not change directory to $tmpdir: $!";

    # Hard-wire in the location of JPLEPH
    # Probably could do with $JPL_DIR as well.
    # Create soft link to JPLEPH

    # If the JPLEPH file is there already then assume it is okay
    unless (-f "JPLEPH") {
      unlink "JPLEPH";
      symlink $StarConfig{Star}."/etc/jpl/jpleph.dat", "JPLEPH"
	or croak "Could not create link to JPL ephemeris";
    }

    # Set FLUXPWD variable
    $ENV{'FLUXPWD'} = cwd;

    # Now we can try and launch fluxes
    my $obj = new ORAC::Msg::ADAM::Task("fluxes_$$",
				       "$ENV{FLUXES}/fluxes");

    # Now we can chdir back to our real working directory
    chdir $cwd || croak "Could not change back to $cwd: $!";

    # Wait and See if we can contact
    if ($obj->contactw) {
      # Store the object
      $self->{FluxesObj} = $obj;
      $self->fluxes_tmp_dir($tmpdir);
    } else {
      croak 'Error launching fluxes monolith. Aborting.';
    }

  }

  return $self->{FluxesObj};

}


=item B<fluxes_tmp_dir>

Name of temporary directory created for the fluxes monolith.
(set or retrieve)

=cut

sub fluxes_tmp_dir {
  my $self = shift;
  if (@_) { $self->{FluxesTmpDir} = shift; }
  return $self->{FluxesTmpDir};
}


=item B<gains>

Determines whether gains are derived from the default values
(DEFAULT) or from the index files (INDEX). Default is to
use the default gains. The value is upper-cased.

=cut

sub gains {
  my $self = shift;
  if (@_) { $self->{Gains} = uc(shift) unless $self->gainsnoupdate; }
  $self->{Gains} = 'DEFAULT' unless (defined $self->{Gains});
  return $self->{Gains};
}

=item B<gainsindex>

Return (or set) the index object associated with the gains
index file. This index file is used if gains() is set to INDEX.

=cut

sub gainsindex {

  my $self = shift;
  if (@_) { $self->{GainsIndex} = shift; }

  unless (defined $self->{GainsIndex}) {
    my $indexfile = $ENV{ORAC_DATA_OUT}."/index.gains";
    my $rulesfile = $ENV{ORAC_DATA_CAL}."/rules.gains";
    $self->{GainsIndex} = new ORAC::Index($indexfile,$rulesfile);
  };

  return $self->{GainsIndex};
}

=item B<gainsnoupdate>

Flag to prevent the gains selection from being modified during data
processing.

=cut

sub gainsnoupdate {
  my $self = shift;
  if (@_) { $self->{GainsNoUpdate} = shift };
  return $self->{GainsNoUpdate};
}


=item B<skydipindex>

Return (or set) the index object associated with the skydip
index file. This index file is used if tausys() is set to skydip.

=cut

sub skydipindex {

  my $self = shift;
  if (@_) { $self->{SkydipIndex} = shift; }

  unless (defined $self->{SkydipIndex}) {
    my $indexfile = $ENV{ORAC_DATA_OUT}."/index.skydip";
    my $rulesfile = $ENV{ORAC_DATA_CAL}."/rules.skydip";
    $self->{SkydipIndex} = new ORAC::Index($indexfile,$rulesfile);
  };

  return $self->{SkydipIndex};
}


=item B<tausys>

Set (or retrieve) the name of the system to be used for
tau determination. Allowed values are 'CSO', 'SKYDIP',
'850SKYDIP' or a number. Currently the number is assumed to be the 
CSO tau since this number is independent of wavelength.
'INDEX' is an allowed synonym for 'SKYDIP'. '850SKYDIP'
mode uses the results of 850 micron skydips from index
files to derive the opacity for the requested wavelength.

Additionally, modes 'DIPINTERP' and '850DIPINTERP' can be 
used to interpolate the current tau from skydips taken
either side of the current observation.

Currently there is no way to specify an actual 850 micron
tau value (the number is treated as a CSO value). In the future
this may change (or a tausys of 850=value will be used??)

If tausys has not been set it defaults to '850SKYDIP'

=cut

sub tausys {
  my $self = shift;
  if (@_) { $self->{TauSys} = uc(shift) unless $self->tausysnoupdate; }
  $self->{TauSys} = '850SKYDIP' unless (defined $self->{TauSys});
  return $self->{TauSys};
}

=item B<tausysnoupdate>

Flag to prevent the tau system from being modified during data
processing.

=cut

sub tausysnoupdate {
  my $self = shift;
  if (@_) { $self->{TauSysNoUpdate} = shift };
  return $self->{TauSysNoUpdate};
}

=item B<taucache>

Internal cache providing access to previously calculated tau values.
This is a reference to a hash of hashes with keys of uppercased
C<tausys()>, ORACTIME and filter name.

 $cacheref = $Cal->taucache;

 $tau = $Cal->taucache->{TAUSYS}->{'19980515.453'}->{$filter};

Returns a hash reference.

=cut

sub taucache {
  my $self = shift;
  return $self->{TauCache};
}

=item B<csofit>

Object containing all the tau fitting information.
The object is configured the first time the information
is requested. The fitting data are located in
C<ORAC_DATA_CAL/csofit.dat>

=cut

sub csofit {
  my $self = shift;
  if (@_) { $self->{CsoFit} = shift; }

  unless (defined $self->{CsoFit}) {
    my $file = $ENV{ORAC_DATA_CAL}."/csofit.dat";
    $self->{CsoFit} = new JCMT::Tau::CsoFit($file);
  };

  return $self->{CsoFit};
}


=back

=head2 General methods

=over 4

=item B<badbol_list>

Returns list of bolometer names that should be turned off for the
current observation. The source of this list depends on the setting
of the badbols() parameter (controlled by the user).
Can be one of 'index', 'file' or actual bolometer list. See the
badbols() method documentation for more information.

=cut

sub badbol_list {
  my $self = shift;

  # Retrieve the badbols query system
  my $sys = $self->badbols;

  # Array to store the bad bolometers
  my @badbols = ();

  # Check system
  if ($sys eq 'INDEX') {
    # Look for bolometers in index file

    # look in the index file
    # and retrieve the closest in time that agrees with the rules
    my $best = $self->badbolsindex->choosebydt('ORACTIME', $self->thing,0);

    # Now retrieve the entry
    if (defined $best) {
      my $entref = $self->badbolsindex->indexentry($best);
      if (defined $entref) {
	my $list = $entref->{BADBOLS};
	@badbols = split(",",$list);
      } else {
	orac_err("Error reading entry $best from BadBols index");
      }
    }


  } elsif ($sys eq 'FILE') {
    # Look for bolometers in badbol.lis file
    my $file = "$ENV{ORAC_DATA_OUT}/badbol.lis";
    if (-e $file) {
      my $fh = new IO::File("< $file");

      if (defined $fh) {
	# read first line
	my $list = <$fh>;
	# close the file
	close $fh;
	# Split on spaces
	@badbols = split(/\s+/,$list);
      }

    }

  } else {
    # Look for bolometers in $sys itself
    # Split on colons - for now do not check whether the names
    # are sensible. If we were to do that we should do the check
    # outside this 'if' and before we return the list
    # Currently this check is done in the primitive at the same time
    # as the bolometer list is compared to the valid bolometers
    # stored in the Frame itself

    @badbols = split(/:/,$sys);

  }

  # Return the list
  return @badbols;

}



=item B<fluxcal>

Return the flux of a calibrator source

  $flux = $Cal->fluxcal("sourcename", "filter", $ismap);

The optional third argument is used to specify whether a map
flux (ie total integrated flux) is required (true), or 
simply a flux in beam (used for photometry). Default is to
return flux in beam. This should return the same answer if the
calibrator is a point source.

Currently, all secondary calibrators are assumed to be point like.

Returns undef if the flux could not be determined.

=cut

sub fluxcal {

  my $self = shift;
  my $source = uc(shift);
  my $filter = shift;
  my $ismap = shift;

  # Fluxes requires that the filter name does not include any non
  # numbers
  $filter =~ s/\D+//g;


  # Start off being pessimistic
  my $flux = undef;

  # Check in the fluxes hash for a value
  if (exists $PHOTFLUXES{$source}) {
    # Source exists in calibrator list

    if (exists $PHOTFLUXES{$source}{$filter}) {
      $flux = $PHOTFLUXES{$source}{$filter};
    }

  } elsif ( grep(/$source/, @PLANETS) ) {
    # Else if we have a planet name

    # Construct argument string for fluxes
    my $hidden = "pos=n flu=y screen=n ofl=n msg_filter=quiet outfile=fluxes.dat apass=n now=n";

    # Now we need to know the date for fluxes (the time is pretty
    # immaterial for the flux)
    # FLUXES needs the date in DD MM YY format
    # of course SCUBA uses YYYY:MM:DD format
    my $scudate = $self->thing->{'UTDATE'}; # the thing method is the header

    if (defined $scudate) {
      my ($y,$m,$d) = split(/:/, $scudate);
      $y = substr($y,2);
      $scudate = "$d $m $y";

    } else {
      $scudate = '0 1 1';
    }

    # Get the time as well - I'm pretty sure that the flux will hardly
    # change when I change the ut time
    my $scutime = $self->thing->{'UTSTART'};

    if (defined $scutime) {
      $scutime =~ tr/:/ /; # Translate colon to space
    } else {
      $scutime = '0 0 0';
    }

    my $status = $self->fluxes_mon->obeyw("","$hidden planet=$source date='$scudate' time='$scutime' filter=$filter");

    if ($status != ORAC__OK) {
      orac_err "The FLUXES program did not run successfully\n";
      return undef;
    }

    # At this point we dont know whether we want the flux in the beam
    # or the total flux

    if (defined $ismap && $ismap) {
      ($status, $flux) = $self->fluxes_mon->get("","F_TOTAL");
    } else {
      ($status, $flux) = $self->fluxes_mon->get("","F_BEAM");
    }
    if ($status != ORAC__OK || $flux == -1) {
      orac_err "Error retrieving flux for filter $filter and planet $source\n";
      return undef;
    }

  }

  return $flux;


}



=item B<gain>

Method to return the current gain (aka 'flux conversion factor') 
for the specified filter that is usable for the current frame.

C<undef> is returned if no gain can be determined.

  $gain = $Cal->gain($filter, $units);

The units must be either BEAM (for Jy/beam/V) or ARCSEC (for
Jy/arcsec**2/V). If no units are supplied the default is BEAM.

If gains() is set to DEFAULT then this method will simply return
the current canonical gain for this filter (first trying a specific
filter [eg C<450w>] then trying a generic filter name [eg C<450>]).
This value will not take into account observing mode (eg scan map
gain is lower than jiggle map gain).

If gains() is set to INDEX the index will be searched for a calibration
observation that matches the observation mode (ie Chop throw, sample
mode, observing mode agree). 

The current index system refuses to continue if a calibration can
not be found. In future this may well be changed so that the
DEFAULT values are used if no calibration is available.

It may also be useful if the gains either side of current observation
are retrieved so that the gain can be interpolated (as for tau
calculation).

=cut

sub gain {
  my $self = shift;

  croak 'Usage: gain(filter,[units])'
    if (scalar(@_) != 1 && scalar(@_) != 2);

  # Get the filter (this could be sub-instrument but it is probably
  # easier to use filter than to query the header for the sub name).
  my $filt = uc(shift);

  # Get the units if there
  my $units = ( @_ ? uc(shift) : 'BEAM');

  # Check units
  if ($units ne 'BEAM' && $units ne 'ARCSEC') {
    croak "Units must be BEAM or ARCSEC, not '$units'\n";
  }

  # Query the gain system to use
  my $sys = $self->gains;

  my $gain;

  if ($sys eq 'DEFAULT') {

    # Generate the generic filter name from the specific (eg 450w)
    # filter name in case one has not been specified.
    my $generic;
    ($generic = $filt ) =~ s/\D+$//;

    if (exists $DEFAULT_FCFS{$units}{$filt}) {
      $gain = $DEFAULT_FCFS{$units}{$filt};
    } elsif (exists $DEFAULT_FCFS{$units}{$generic}) {
      $gain = $DEFAULT_FCFS{$units}{$generic};
    } else {
      orac_err "No gain exists for the specified filter ($filt)\n";
      $gain = undef;
    }

  } elsif ($sys eq 'INDEX') {

    # Now look in the index file

    # We are going to modify the header so take a copy
    my %hdr = %{ $self->thing };

    # Set search parameters
    $hdr{FILTER} = $filt;
    $hdr{UNITS}  = $units;

    # Now ask for the 'best' gain observation
    # This means closest in time
    my $best = $self->gainsindex->choosebydt('ORACTIME', \%hdr, 0);

    unless (defined $best) {
      orac_err "No suitable gain calibration could be found for filter $filt ($units)\n";
      croak 'Aborting...';
    }

    # Now retrieve the entry itself
    my $entref = $self->gainsindex->indexentry($best);

    if (defined $entref) {
      $gain = $entref->{GAIN};
    } else {
      orac_err("Error reading entry $best from Gains index");
      $gain = undef;
    }

  } else {
    orac_err("Gains system non standard ($sys)\n");
    $gain = undef;
  }

  # Return the gain
  return $gain;

}


=item B<iscalsource>

Given the source name and filter, work out whether we have calibration
information on this source (ie we know the flux for this filter). If
information is availble return true (1) else return (0).

  $yesno = $Cal->iscalsource("source_name","filter");

If filter is not supplied, it is assumed we are simply asking
whether the source is a calibrator independent of whether we
actually have a calibration value for it....

=cut

# Can not yet handle planets or differing observing modes.

sub iscalsource {
  my $self = shift;
  my $source = uc(shift);
  my $filter = shift;

  # If we match a planet straightaway then it is a calibrator
  # regardless of filter (unless the filter is not available in fluxes)

  return 1 if grep /$source/, @PLANETS;


  # Start off being pessimistic
  my $iscal = 0;
  if (exists $PHOTFLUXES{$source}) {
    # Source exists in calibrator list

    # If filter is defined check that it is in the list
    # if it is not defined simply return true
    if (!defined($filter) || exists $PHOTFLUXES{$source}{$filter}) {
      $iscal = 1;
    }

  }

  return $iscal;

}


=item B<tau>

Returns the tau associated with the supplied filter.

  $tau = $Cal->tau($filter);

This routine works as follows. First tausys() is queried to determine
the system to use to calculate the tau. If this is CSO, the current
frame is queried for the CSO tau value stored and the tau calculated
for FILTER. If tausys() returns a number it is assumed
to be the actual CSO tau to use. If it is set to Skydip (or index) then
the selected wavelength is updated in the frame header (Key=FILTER)
and the skydip index is queried for the skydip that matched the criterion
and is closest in time.

The tausys='850SKYDIP' mode uses the results of 850 micron skydips
from index files to derive the opacity for the requested wavelength.

Additionally, modes 'DIPINTERP' and '850DIPINTERP' can be used to
interpolate the current tau from skydips taken either side of the
current observation.

The skydip modes will default to using CSO if a suitable
skydip can not be found. Also, a warning is raised if a skydip
is found but was takan more than 3 hours before or after the
current observation.

undef is returned if an error occurred [eg the CSO is so high that the
tau can not be calculated using the linear relationship].

The value is cached for a given tausys and observation (ORACTIME is
used for uniqueness) to prevent delays in searching for a tau when the
observation has not changed. It is very unlikely that a tau calibration
will change during a data reduction of a single frame (and, in reality
it is required that if you use a particular tau for extinction correction
that you can retrieve the exact same tau that was used at a later date).
The tau value is not cached if it can not be determined.

=cut

sub tau {
  my $self = shift;

  croak 'Usage: tau(filter)' if (scalar(@_) != 1);

  # Get the filter name for this sub-instrument
  my $filt = uc(shift);

  # Declare local variables
  my ($tau, $status);

  # Now query tausys
  my $sys = $self->tausys;

  # Check to see whether the value is already cached.
  my $oractime = $self->thing->{'ORACTIME'};
  return $self->taucache->{$sys}->{$oractime}->{$filt}
    if exists $self->taucache->{$sys}->{$oractime}->{$filt};

  # Check tausys
  if ($sys eq 'CSO') {

    # Read the value from the header of thing
    my $csotau = $self->thing->{'TAU_225'};

    ($tau, $status) = get_tau($filt, 'CSO', $csotau);

    if ($status == -1) {
      orac_warn("Error converting a CSO tau of $csotau to an opacity for filter $filt\n");
      orac_warn("Setting tau to 0\n");
      $tau = 0.0;
    }


  } elsif ($sys =~ /^\d+\.?\d*$/) {
    # We check for a number - note that this pattern does not match
    # numbers that start with a decimal point.
    # This number is a specific CSO tau
    ($tau, $status) = get_tau($filt, 'CSO', $sys);

    # Check status
    if ($status == -1) {
      orac_warn("Error converting a CSO tau of $sys to an opacity for filter $filt\n");
      orac_warn("Setting tau to 0\n");
      $tau = 0.0;
    }

  } elsif ($sys =~ /DIP/ || $sys eq 'INDEX') {

    # Skydips have been selected (using index files)

    # We always have to ask for the nearest skydip from the index
    # file. If one is not available, revert to CSO tau
    # If sys=850SKYDIP we derive the tau from nearest 850 skydip

    # First tak a copy of the header (we will need to change
    # this when looking for 850 skydips
    my %hdr = %{$self->thing};

    # Now set the filter name in this hash so that
    # we know what filter we are searching for
    # Special case for a 850 skydip only search
    # but we don't know whether we should be searching for 850W
    # or 850N
    if ($sys =~ /850/) {
      $hdr{FILTER} = '850W';
    } else {
      $hdr{FILTER} = $filt;
    }

    # Now we have to ask for the 'best' skydip matching these
    # criterion. For interpolation schemes we need to ask for
    # the nearest skydips either side in time from the current
    # frame. For normal querying we simply ask for the closest
    # in time.

    # ASIDE: Note that in the 850skydip case, querying the complete
    # index file is inefficient since the chances are quite good
    # that a verification of the current skydip alone would be okay

    # This variable sets the threshold value for age
    my $too_old = 3.0/24.0; # 3 hours as a day fraction

    # Check that SYS matches 'interp' (interpolation)
    # and ask for two index searches [inefficient???]
    # Might want to use a index routine that searches for high and
    # low at the same time
    if ($sys =~ /INTERP/) {
      my $high = $self->skydipindex->chooseby_positivedt('ORACTIME', \%hdr, 0);
      my $low  = $self->skydipindex->chooseby_negativedt('ORACTIME', \%hdr, 0);

      # Check to see
      # Now retrieve the actual entries
      my ($high_ent, $low_ent);
      $high_ent = $self->skydipindex->indexentry($high) if defined $high;
      $low_ent  = $self->skydipindex->indexentry($low) if defined $low;

      # The possibilities are:
      # - low and high are found, we interpolate
      # - low and high are found but some are older than 3 hours, warn
      #   and interpolate
      # - only high is found - use it [warn if too new]
      # - only low is found - use it [warn if too old]
      # - nothing found - revert to using CSO tau

      # Check the HIGH
      if (defined $high_ent) {
	# Okay - see how old it is
	my $age = abs($high_ent->{ORACTIME} - $hdr{ORACTIME});
        if ($age > $too_old) {
	  orac_warn(" the closest skydip (from above: $high) was too new [".sprintf('%5.2f',$age*24.0)." hours]\nUsing this value anyway...\n");
	}
      }

      # Check the LOW
      if (defined $low_ent) {
	# Okay - see how old it is
	my $age = abs($low_ent->{ORACTIME} - $hdr{ORACTIME});
        if ($age > $too_old) {
	  orac_warn(" the closest skydip (from below: $low) was too old [".sprintf('%5.2f',$age*24.0)." hours]\nUsing this value anyway...\n");
	}
      }

      # Now look for the tau values
      if (defined $low_ent && defined $high_ent) {
	# Interpolate TAU value

	# Find taus for each time
	my $highz = $high_ent->{TAUZ};
	my $hight = $high_ent->{ORACTIME};
	my $lowz  = $low_ent->{TAUZ};
	my $lowt  = $low_ent->{ORACTIME};

	my $framet = $hdr{ORACTIME};

#	print "HIGH: $highz @ $hight\n";
#	print "LOW: $lowz  @ $lowt\n";
#	print "Now:  $framet\n";

	# Calculate tau at time $framet
	# This is not as good as returning both tau values
        # and times to the caller

	orac_print "Calculating interpolated tau value....\n";

	$tau = $lowz + ($framet - $lowt) * ($highz-$lowz) / ($hight - $lowt);

      } else {

	orac_warn "Cannot interpolate - can not find suitable skydips on both sides of this observation\nUsing a single value...\n";
	
	# If only one is defined, use that tau
	$tau = undef;
	$tau = $low_ent->{TAUZ} if defined $low_ent;
	$tau = $high_ent->{TAUZ} if defined $high_ent;

	# If none are defined - tau is undef anyway
	
      }


    } else {

      # Retrieve the closest in time
      my $nearest = $self->skydipindex->choosebydt('ORACTIME', \%hdr,0);

      # Check return value
      if (defined $nearest) {

	# Now retrieve the entry
	my $entref = $self->skydipindex->indexentry($nearest);

	# Possibilities are:
	# - something found, use it, report if it is too old.
	# - nothing found - revert to using CSO tau

	# Check age
	if (defined $entref) {
	  my $age = abs($entref->{ORACTIME} - $hdr{ORACTIME});
	  orac_warn("Skydip $nearest was taken ".sprintf('%5.2f',$age*24.0)." hours from this frame\nUsing this value anyway...\n")
	    if $age > $too_old;

	  $tau = $entref->{TAUZ};

	} else {
	  orac_warn "Error reading index entry $nearest\n";
	}
      }

    }

    # If we have a tau value AND we are using a 850->filter conversion
    # We should convert here

    if (defined $tau && $sys =~ /850/) {

      orac_print "Using 850W tau of ".sprintf("%6.3f",$tau)." to generate tau for filter $filt\n";

      # Now convert this tau to the requested filter
      # This must be changed to work for 850N as well
      ($tau, $status) = get_tau($filt, '850W', $tau);

      # On error - report conversion error then set tau to undef
      # so that we can try to adopt a CSO value
      if ($status == -1) {
	orac_warn("Error converting a 850 tau to an opacity for filter $filt\n");
	$tau = undef;
      }

    }

    # Need to configure the fallback options to enable the
    # adoption of a CSO tau to be optional
    # If $tau has not yet been set (ie the index lookup failed)
    # revert to a CSO tau lookup
    unless (defined $tau) {

      orac_print "No suitable skydip found - converting from CSO tau\n";
      # Find CSO
      my $csotau = $self->thing->{'TAU_225'};

      ($tau, $status) = get_tau($filt, 'CSO', $csotau);

      if ($status == -1) {
	orac_warn("Error converting a CSO tau of $csotau to an opacity for filter $filt\n");
	$tau = undef;
      }
    }
  } elsif ($sys eq 'CSOFIT') {

    # Retrieve the tau for the required time
    my $csotau = $self->csofit->tau( $self->thing->{ORACTIME});

    if (defined $csotau) {

      # Convert it to the required filter
      ($tau, $status) = get_tau($filt, 'CSO', $csotau);

      if ($status == -1) {
	orac_warn("Error converting a CSO tau of $csotau to an opacity for filter $filt\n");
	$tau = undef;
      }

    } else {
      orac_warn "No fit present for this date\n";
      $tau = undef;
    }

  } else {
    orac_err(" tausys is non-standard ($sys)\n");
    $tau = undef;
  }

  # Cache the result if it is defined
  $self->taucache->{$sys}->{$oractime}->{$filt} = $tau if defined $tau;

  # Now we have a tau value so return it
  return $tau;

}


=back

=head2 Destructor

=over 4

=item B<DESTROY>

Removes any directories that may have been created by this
calibration class (eg by starting fluxes).

Assumes that only this object is interested in the fluxes monolith
associated with this object since we are about to remove the
temporary directory containing the JPL ephemeris file.

=cut

sub DESTROY {
  my $self = shift;
  if ($self->fluxes_tmp_dir) {
    rmtree $self->fluxes_tmp_dir;    
    orac_print "Removing temporary directory containing JPLEPH\n"
      if $DEBUG;
  }
}



=back

=head1 SEE ALSO

L<ORAC::Calib> 

=head1 REVISION

$Id$

=head1 AUTHORS

Tim Jenness (t.jenness@jach.hawaii.edu)

=head1 COPYRIGHT

Copyright (C) 1998-2000 Particle Physics and Astronomy Research
Council. All Rights Reserved.


=cut

1;
